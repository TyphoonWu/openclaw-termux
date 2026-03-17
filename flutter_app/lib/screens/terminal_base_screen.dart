import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';

import '../constants.dart';
import '../services/native_bridge.dart';
import '../services/screenshot_service.dart';
import '../services/terminal_service.dart';
import '../widgets/terminal_toolbar.dart';

/// Shared terminal screen implementation (Terminal + PTY + toolbar + copy/open/paste/screenshot/restart).
///
/// Subclasses only need to provide:
/// - app bar title / actions
/// - how to build PTY arguments (what command to run)
/// - optional output handling (URL detection, completion detection, etc.)
/// - optional bottom area (e.g. "Done" button)
abstract class TerminalBaseScreen extends StatefulWidget {
  const TerminalBaseScreen({super.key});
}

/// Base [State] for terminal-based screens.
///
/// This is intentionally "opinionated" to match existing screens:
/// - start terminal service in [initState]
/// - start PTY after first frame (to get correct terminal size)
/// - ensure DNS/resolv.conf exists before launching proot (#40)
abstract class TerminalBaseScreenState<T extends TerminalBaseScreen>
    extends State<T> {
  late final Terminal terminal;
  late final TerminalController controller;

  Pty? pty;

  bool loading = true;
  String? error;

  final ctrlNotifier = ValueNotifier<bool>(false);
  final altNotifier = ValueNotifier<bool>(false);
  final screenshotKey = GlobalKey();

  /// Regex used by default URL extraction.
  static final anyUrlRegex = RegExp(r'https?://[^\s<>\[\]"' "'" r'\)]+');

  /// Box-drawing and other TUI characters that break URLs when copied.
  static final boxDrawing = RegExp(r'[│┤├┬┴┼╮╯╰╭─╌╴╶┌┐└┘◇◆]+');

  static const fontFallback = [
    'monospace',
    'Noto Sans Mono',
    'Noto Sans Mono CJK SC',
    'Noto Sans Mono CJK TC',
    'Noto Sans Mono CJK JP',
    'Noto Color Emoji',
    'Noto Sans Symbols',
    'Noto Sans Symbols 2',
    'sans-serif',
  ];

  @override
  void initState() {
    super.initState();
    terminal = Terminal(maxLines: 10000);
    controller = TerminalController();
    NativeBridge.startTerminalService();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      startPty();
    });
  }

  @override
  void dispose() {
    ctrlNotifier.dispose();
    altNotifier.dispose();
    controller.dispose();
    pty?.kill();
    NativeBridge.stopTerminalService();
    super.dispose();
  }

  /// Subclass must provide the final arguments passed to [Pty.start].
  ///
  /// [baseArgs] are the proot shell args returned from [TerminalService.buildProotArgs].
  /// Common pattern: modify baseArgs tail to replace `/bin/bash -l` with `/bin/bash -lc <cmd>`.
  List<String> buildPtyArguments({
    required Map<String, String> config,
    required List<String> baseArgs,
  });

  /// Called for every PTY output chunk.
  @protected
  void onPtyOutput(String text) {}

  /// Called when PTY exits.
  @protected
  void onPtyExit(int code) {}

  /// If provided, called to build extra widgets below the terminal view (before toolbar).
  @protected
  List<Widget> buildExtraBottomWidgets() => const [];

  /// If true, include restart action in the default app bar actions.
  @protected
  bool get showRestartAction => true;

  /// Override to customize the app bar title.
  @protected
  String get appBarTitle;

  /// Override if you need custom actions; default provides screenshot/copy/open/paste/(restart).
  @protected
  List<Widget>? buildAppBarActions(BuildContext context) => null;

  /// Override to customize the loading text.
  @protected
  String get loadingText => 'Starting terminal...';

  /// Override to customize the generic error prefix.
  @protected
  String get startErrorPrefix => 'Failed to start terminal: ';

  /// Override to customize screenshot prefix; null uses default behavior from ScreenshotService.
  @protected
  String? get screenshotPrefix => null;

  /// Override to enable tap-to-open URL behavior in the terminal.
  @protected
  bool get enableTapToOpenUrl => false;

  Future<void> startPty() async {
    pty?.kill();
    pty = null;

    try {
      await _ensureDnsReady();

      final config = await TerminalService.getProotShellConfig();
      final args = TerminalService.buildProotArgs(
        config,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      final finalArgs = buildPtyArguments(config: config, baseArgs: args);

      pty = Pty.start(
        config['executable']!,
        arguments: finalArgs,
        environment: TerminalService.buildHostEnv(config),
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      pty!.output.cast<List<int>>().listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        terminal.write(text);
        onPtyOutput(text);
      });

      pty!.exitCode.then((code) {
        onPtyExit(code);
      });

      terminal.onOutput = (data) {
        // Intercept keyboard input when CTRL/ALT toolbar modifiers are active
        if (ctrlNotifier.value && data.length == 1) {
          final code = data.toLowerCase().codeUnitAt(0);
          if (code >= 97 && code <= 122) {
            // Ctrl+a-z → bytes 1-26
            pty?.write(Uint8List.fromList([code - 96]));
            ctrlNotifier.value = false;
            return;
          }
        }
        if (altNotifier.value && data.isNotEmpty) {
          // Alt+key → ESC + key
          pty?.write(utf8.encode('\x1b$data'));
          altNotifier.value = false;
          return;
        }
        pty?.write(utf8.encode(data));
      };

      terminal.onResize = (w, h, pw, ph) {
        pty?.resize(h, w);
      };

      if (mounted) setState(() => loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$startErrorPrefix$e';
        });
      }
    }
  }

  Future<void> _ensureDnsReady() async {
    // Ensure dirs + resolv.conf exist before proot starts (#40).
    try {
      await NativeBridge.setupDirs();
    } catch (_) {}
    try {
      await NativeBridge.writeResolv();
    } catch (_) {}

    // Some devices still miss the file(s), ensure both host-config and rootfs.
    try {
      final filesDir = await NativeBridge.getFilesDir();
      const resolvContent = 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n';

      final resolvFile = File('$filesDir/config/resolv.conf');
      if (!resolvFile.existsSync()) {
        Directory('$filesDir/config').createSync(recursive: true);
        resolvFile.writeAsStringSync(resolvContent);
      }

      final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
      if (!rootfsResolv.existsSync()) {
        rootfsResolv.parent.createSync(recursive: true);
        rootfsResolv.writeAsStringSync(resolvContent);
      }
    } catch (_) {}
  }

  String? getSelectedText() {
    final selection = controller.selection;
    if (selection == null || selection.isCollapsed) return null;

    final range = selection.normalized;
    final sb = StringBuffer();
    for (int y = range.begin.y; y <= range.end.y; y++) {
      if (y >= terminal.buffer.lines.length) break;
      final line = terminal.buffer.lines[y];
      final from = (y == range.begin.y) ? range.begin.x : 0;
      final to = (y == range.end.y) ? range.end.x : null;
      sb.write(line.getText(from, to));
      if (y < range.end.y) sb.writeln();
    }
    final text = sb.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Default URL extraction: strip ANSI/box chars, collapse whitespace, split on http boundaries,
  /// and return the longest match.
  @protected
  String? extractUrl(String text) {
    final clean =
        text.replaceAll(boxDrawing, '').replaceAll(RegExp(r'\s+'), '');
    final parts = clean.split(RegExp(r'(?=https?://)'));
    String? best;
    for (final part in parts) {
      final match = anyUrlRegex.firstMatch(part);
      if (match != null) {
        final url = match.group(0)!;
        if (best == null || url.length > best.length) best = url;
      }
    }
    return best;
  }

  void copySelection() {
    final text = getSelectedText();
    if (text == null) return;

    Clipboard.setData(ClipboardData(text: text));

    final url = extractUrl(text);
    if (url != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Copied to clipboard'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copied to clipboard'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void openSelection() {
    final text = getSelectedText();
    if (text == null) return;

    final url = extractUrl(text);
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No URL found in selection'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      pty?.write(utf8.encode(data.text!));
    }
  }

  Future<void> takeScreenshot() async {
    final path = await ScreenshotService.capture(
      screenshotKey,
      prefix: screenshotPrefix ?? 'terminal',
    );
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(path != null
            ? 'Screenshot saved: ${path.split('/').last}'
            : 'Failed to capture screenshot'),
      ),
    );
  }

  /// Tap to detect/open URL around tapped cell.
  void handleTapToOpenUrl(TapUpDetails details, CellOffset offset) {
    final totalLines = terminal.buffer.lines.length;
    final startRow = (offset.y - 2).clamp(0, totalLines - 1);
    final endRow = (offset.y + 2).clamp(0, totalLines - 1);

    final sb = StringBuffer();
    for (int row = startRow; row <= endRow; row++) {
      sb.write(_getLineText(row).trimRight());
    }
    final url = extractUrl(sb.toString());
    if (url != null) {
      openUrlWithDialog(url);
    }
  }

  String _getLineText(int row) {
    try {
      final line = terminal.buffer.lines[row];
      final sb = StringBuffer();
      for (int i = 0; i < line.length; i++) {
        final char = line.getCodePoint(i);
        if (char != 0) {
          sb.writeCharCode(char);
        }
      }
      return sb.toString();
    } catch (_) {
      return '';
    }
  }

  Future<void> openUrlWithDialog(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open Link'),
        content: Text(url),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Link copied'),
                  duration: Duration(seconds: 1),
                ),
              );
              Navigator.pop(ctx, false);
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open'),
          ),
        ],
      ),
    );

    if (shouldOpen == true) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  List<Widget> _defaultActions() {
    return [
      IconButton(
        icon: const Icon(Icons.camera_alt_outlined),
        tooltip: 'Screenshot',
        onPressed: takeScreenshot,
      ),
      IconButton(
        icon: const Icon(Icons.copy),
        tooltip: 'Copy',
        onPressed: copySelection,
      ),
      IconButton(
        icon: const Icon(Icons.open_in_browser),
        tooltip: 'Open URL',
        onPressed: openSelection,
      ),
      IconButton(
        icon: const Icon(Icons.paste),
        tooltip: 'Paste',
        onPressed: pasteFromClipboard,
      ),
      if (showRestartAction)
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Restart',
          onPressed: () {
            pty?.kill();
            setState(() {
              loading = true;
              error = null;
            });
            startPty();
          },
        ),
    ];
  }

  Widget buildBody({
    required String loadingText,
    required Widget Function() buildReadyBody,
  }) {
    if (loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(loadingText),
          ],
        ),
      );
    }

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    loading = true;
                    error = null;
                  });
                  startPty();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return buildReadyBody();
  }

  Widget buildTerminalWithToolbar() {
    return Column(
      children: [
        Expanded(
          child: RepaintBoundary(
            key: screenshotKey,
            child: TerminalView(
              terminal,
              controller: controller,
              textStyle: const TerminalStyle(
                fontSize: 11,
                height: 1.0,
                fontFamily: 'DejaVuSansMono',
                fontFamilyFallback: fontFallback,
              ),
              onTapUp: enableTapToOpenUrl ? handleTapToOpenUrl : null,
            ),
          ),
        ),
        ...buildExtraBottomWidgets(),
        TerminalToolbar(
          pty: pty,
          ctrlNotifier: ctrlNotifier,
          altNotifier: altNotifier,
        ),
      ],
    );
  }

  /// Build the terminal area (loading/error/terminal) without wrapping in a [Scaffold].
  ///
  /// Subclasses that need a custom scaffold (custom leading, bottom "Done" button, etc.)
  /// can call this and embed the returned widget.
  @protected
  Widget buildTerminalBody() {
    return buildBody(
      loadingText: loadingText,
      buildReadyBody: buildTerminalWithToolbar,
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = buildAppBarActions(context) ?? _defaultActions();

    return Scaffold(
      appBar: AppBar(
        title: Text(appBarTitle),
        actions: actions,
      ),
      body: buildTerminalBody(),
    );
  }
}

/// Shared completion detection regex used by onboarding/provider-auth flows.
final terminalCompletionPattern = RegExp(
  r'onboard(ing)?\s+(is\s+)?complete|successfully\s+onboarded|setup\s+complete',
  caseSensitive: false,
);

/// Shared ANSI escape regex used for output analysis.
final terminalAnsiEscape = AppConstants.ansiEscape;
