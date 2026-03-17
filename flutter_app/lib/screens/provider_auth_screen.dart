import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/preferences_service.dart';
import 'dashboard_screen.dart';
import 'terminal_base_screen.dart';

/// Runs `openclaw onboard --auth-choice qwen-portal ...` in a terminal so the user can
/// authenticate via provider portal flow (Qwen). Output is shown in an embedded terminal.
class ProviderAuthScreen extends TerminalBaseScreen {
  /// If true, shows a "Go to Dashboard" button when onboarding exits.
  /// Used after first-time setup. If false, just pops back.
  final bool isFirstRun;

  const ProviderAuthScreen({super.key, this.isFirstRun = false});

  @override
  State<ProviderAuthScreen> createState() => _ProviderAuthScreenState();
}

class _ProviderAuthScreenState
    extends TerminalBaseScreenState<ProviderAuthScreen> {
  bool _finished = false;

  String _outputBuffer = '';
  String? _detectedUrl;
  bool _urlDismissed = false;

  @override
  String get appBarTitle => 'Provider Auth';

  @override
  String get loadingText => 'Starting provider auth...';

  @override
  String get startErrorPrefix => 'Failed to start provider auth: ';

  @override
  String? get screenshotPrefix => 'provider_auth';

  @override
  bool get showRestartAction => true;

  @override
  List<String> buildPtyArguments({
    required Map<String, String> config,
    required List<String> baseArgs,
  }) {
    // Replace login shell with the provider auth onboarding command.
    final onboardingArgs = List<String>.from(baseArgs);
    onboardingArgs.removeLast(); // remove '-l'
    onboardingArgs.removeLast(); // remove '/bin/bash'

    const enableAuthPlugin = 'openclaw plugins enable qwen-portal-auth';
    const authLogin =
        'openclaw models auth login --provider qwen-portal --set-default';

    onboardingArgs.addAll([
      '/bin/bash',
      '-lc',
      'echo "=== Provider Auth (Qwen Portal) ===" && '
          'echo "" && '
          '$enableAuthPlugin && '
          '$authLogin && '
          'echo "" && echo "Provider auth flow complete! You can close this screen."',
    ]);

    return onboardingArgs;
  }

  @override
  String? extractUrl(String text) {
    // Same as base, but trim the special OpenClaw marker to avoid trailing junk.
    final url = super.extractUrl(text);
    if (url == null) return null;

    const marker = 'toapproveaccess.';
    final idx = url.indexOf(marker);
    if (idx > 0) return url.substring(0, idx);

    return url;
  }

  @override
  void onPtyOutput(String text) {
    _outputBuffer += text;
    if (_outputBuffer.length > 8192) {
      _outputBuffer = _outputBuffer.substring(_outputBuffer.length - 4096);
    }

    final cleanText = _outputBuffer.replaceAll(terminalAnsiEscape, '');

    // Detect URLs from terminal output and surface in UI.
    if (!_urlDismissed) {
      final url = extractUrl(cleanText);
      if (url != null && url != _detectedUrl) {
        if (mounted) setState(() => _detectedUrl = url);
      }
    }

    if (!_finished && terminalCompletionPattern.hasMatch(cleanText)) {
      if (mounted) setState(() => _finished = true);
    }
  }

  @override
  void onPtyExit(int code) {
    terminal.write('\r\n[ProviderAuth exited with code $code]\r\n');
    if (mounted) setState(() => _finished = true);
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Provider Auth'),
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
          if (_detectedUrl != null && !_urlDismissed)
            MaterialBanner(
              content: SelectableText(
                _detectedUrl!,
                maxLines: 2,
              ),
              leading: const Icon(Icons.link),
              actions: [
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _detectedUrl!));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('URL copied'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Text('Copy'),
                ),
                FilledButton(
                  onPressed: () {
                    final url = _detectedUrl;
                    if (url != null) {
                      final uri = Uri.tryParse(url);
                      if (uri != null) {
                        setState(() => _urlDismissed = true);
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                        return;
                      }
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Invalid URL'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  onPressed: () {
                    setState(() => _urlDismissed = true);
                  },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
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
                        : () => Navigator.of(context).pop(true),
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
