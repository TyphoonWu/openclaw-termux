import 'package:flutter/material.dart';

import '../models/optional_package.dart';
import 'terminal_base_screen.dart';

/// Runs an install or uninstall command for an [OptionalPackage] inside proot.
/// Follows the same terminal pattern as [OnboardingScreen].
class PackageInstallScreen extends TerminalBaseScreen {
  final OptionalPackage package;
  final bool isUninstall;

  const PackageInstallScreen({
    super.key,
    required this.package,
    this.isUninstall = false,
  });

  @override
  State<PackageInstallScreen> createState() => _PackageInstallScreenState();
}

class _PackageInstallScreenState
    extends TerminalBaseScreenState<PackageInstallScreen> {
  bool _finished = false;

  @override
  String get appBarTitle {
    final action = widget.isUninstall ? 'Uninstall' : 'Install';
    return '$action ${widget.package.name}';
  }

  @override
  String get loadingText => 'Starting...';

  @override
  String get startErrorPrefix => 'Failed to start: ';

  @override
  String? get screenshotPrefix => 'package';

  @override
  bool get showRestartAction => false;

  @override
  List<Widget>? buildAppBarActions(BuildContext context) {
    // Keep original behavior: only screenshot + paste
    return [
      IconButton(
        icon: const Icon(Icons.camera_alt_outlined),
        tooltip: 'Screenshot',
        onPressed: takeScreenshot,
      ),
      IconButton(
        icon: const Icon(Icons.paste),
        tooltip: 'Paste',
        onPressed: pasteFromClipboard,
      ),
    ];
  }

  @override
  List<String> buildPtyArguments({
    required Map<String, String> config,
    required List<String> baseArgs,
  }) {
    final command = widget.isUninstall
        ? widget.package.uninstallCommand
        : widget.package.installCommand;

    // Replace login shell with the install/uninstall command
    final cmdArgs = List<String>.from(baseArgs);
    cmdArgs.removeLast(); // remove '-l'
    cmdArgs.removeLast(); // remove '/bin/bash'
    cmdArgs.addAll(['/bin/bash', '-lc', command]);
    return cmdArgs;
  }

  @override
  void onPtyOutput(String text) {
    final sentinel = widget.isUninstall
        ? widget.package.uninstallSentinel
        : widget.package.completionSentinel;

    if (!_finished && text.contains(sentinel)) {
      if (mounted) setState(() => _finished = true);
    }
  }

  @override
  void onPtyExit(int code) {
    terminal.write('\r\n[Process exited with code $code]\r\n');
    if (mounted && !_finished) {
      setState(() => _finished = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(appBarTitle),
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
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.check),
                    label: const Text('Done'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
