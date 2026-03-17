import 'package:flutter/material.dart';

import 'terminal_base_screen.dart';

class TerminalScreen extends TerminalBaseScreen {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends TerminalBaseScreenState<TerminalScreen> {
  @override
  String get appBarTitle => 'Terminal';

  @override
  String get loadingText => 'Starting terminal...';

  @override
  String get startErrorPrefix => 'Failed to start terminal: ';

  @override
  bool get enableTapToOpenUrl => true;

  @override
  String? get screenshotPrefix => 'terminal';

  @override
  List<String> buildPtyArguments({
    required Map<String, String> config,
    required List<String> baseArgs,
  }) {
    return baseArgs;
  }
}
