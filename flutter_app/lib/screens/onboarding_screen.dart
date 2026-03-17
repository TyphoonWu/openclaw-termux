import 'package:flutter/material.dart';

import '../services/preferences_service.dart';
import 'dashboard_screen.dart';
import 'terminal_base_screen.dart';

/// Runs `openclaw onboard` in a terminal so the user can configure
/// API keys and select loopback binding. Shown after first-time setup
/// and accessible from the dashboard for re-configuration.
class OnboardingScreen extends TerminalBaseScreen {
  /// If true, shows a "Go to Dashboard" button when onboarding exits.
  /// Used after first-time setup. If false, just pops back.
  final bool isFirstRun;

  const OnboardingScreen({super.key, this.isFirstRun = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends TerminalBaseScreenState<OnboardingScreen> {
  bool _finished = false;

  static final _tokenUrlRegex =
      RegExp(r'https?://(?:localhost|127\.0\.0\.1):18789/#token=[0-9a-f]+');

  String _outputBuffer = '';

  @override
  String get appBarTitle => 'OpenClaw Onboarding';

  @override
  String get loadingText => 'Starting onboarding...';

  @override
  String get startErrorPrefix => 'Failed to start onboarding: ';

  @override
  bool get enableTapToOpenUrl => true;

  @override
  String? get screenshotPrefix => 'onboarding';

  @override
  List<String> buildPtyArguments({
    required Map<String, String> config,
    required List<String> baseArgs,
  }) {
    // Replace the login shell with a command that runs onboarding.
    // buildProotArgs ends with [..., '/bin/bash', '-l']
    // Replace with [..., '/bin/bash', '-lc', 'openclaw onboard']
    final onboardingArgs = List<String>.from(baseArgs);
    onboardingArgs.removeLast(); // remove '-l'
    onboardingArgs.removeLast(); // remove '/bin/bash'
    onboardingArgs.addAll([
      '/bin/bash',
      '-lc',
      'echo "=== OpenClaw Onboarding ===" && '
          'echo "Configure your API keys and binding settings." && '
          'echo "TIP: Select Loopback (127.0.0.1) when asked for binding!" && '
          'echo "" && '
          'openclaw onboard; '
          'echo "" && echo "Onboarding complete! You can close this screen."',
    ]);
    return onboardingArgs;
  }

  @override
  void onPtyOutput(String text) {
    // Scan output for token URL (e.g. http://localhost:18789/#token=...)
    _outputBuffer += text;
    if (_outputBuffer.length > 4096) {
      _outputBuffer = _outputBuffer.substring(_outputBuffer.length - 2048);
    }

    final cleanText = _outputBuffer.replaceAll(terminalAnsiEscape, '');

    final cleanForUrl = cleanText
        .replaceAll(TerminalBaseScreenState.boxDrawing, '')
        .replaceAll(RegExp(r'\s+'), '');

    final tokenMatch = _tokenUrlRegex.firstMatch(cleanForUrl);
    if (tokenMatch != null) {
      _saveTokenUrl(tokenMatch.group(0)!);
    }

    if (!_finished && terminalCompletionPattern.hasMatch(cleanText)) {
      if (mounted) setState(() => _finished = true);
    }
  }

  @override
  void onPtyExit(int code) {
    terminal.write('\r\n[Onboarding exited with code $code]\r\n');
    if (mounted) setState(() => _finished = true);
  }

  Future<void> _saveTokenUrl(String url) async {
    final prefs = PreferencesService();
    await prefs.init();
    prefs.dashboardUrl = url;
  }

  Future<void> _goToDashboard() async {
    final navigator = Navigator.of(context);
    final prefs = PreferencesService();
    await prefs.init();
    prefs.setupComplete = true;
    prefs.isFirstRun = false;

    if (mounted) {
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const DashboardScreen()),
      );
    }
  }

  @override
  List<Widget>? buildAppBarActions(BuildContext context) {
    // Keep onboarding behavior: no restart button (old screen didn't have it).
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenClaw Onboarding'),
        leading: widget.isFirstRun
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
        automaticallyImplyLeading: false,
        actions: buildAppBarActions(context),
      ),
      body: Column(
        children: [
          Expanded(child: buildTerminalBody()),
          if (_finished)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: widget.isFirstRun
                        ? _goToDashboard
                        : () => Navigator.of(context).pop(),
                    icon: Icon(
                        widget.isFirstRun ? Icons.arrow_forward : Icons.check),
                    label: Text(widget.isFirstRun ? 'Go to Dashboard' : 'Done'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
