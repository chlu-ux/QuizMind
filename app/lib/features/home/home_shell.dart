import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../agent/agent_tab.dart';
import '../settings/settings_page.dart';
import 'banks_page.dart';
import 'home_menu.dart';
import 'question_list_page.dart';

/// Top-level navigation: a rail on wide windows (macOS), a bottom bar on phones.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  late int _index;

  /// The tab the assistant's back arrow returns to: the one the learner came from.
  int _previous = 0;

  /// The assistant tab is built when first opened, not at start-up, so it asks the server nothing
  /// until the learner wants it.
  bool _aiOpened = false;

  @override
  void initState() {
    super.initState();
    final configured = ref.read(settingsProvider).configured;
    _index = configured ? 0 : homeSettingsIndex; // first run: go straight to the server settings
    if (configured) Future.microtask(() => ref.read(syncProvider.notifier).run());
  }

  void _select(int i) {
    if (i == homeAiIndex) {
      // A notice left over from another tab would sit on the assistant's input box.
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    setState(() {
      if (i != _index && _index != homeAiIndex) _previous = _index;
      _index = i;
      if (i == homeAiIndex) _aiOpened = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final pages = [
      const BanksPage(),
      const QuestionListPage(kind: QuestionListKind.wrongBook),
      _aiOpened ? AgentTab(onBack: wide ? null : () => _select(_previous)) : const SizedBox.shrink(),
      const QuestionListPage(kind: QuestionListKind.favorites),
      const SettingsPage(),
    ];
    return homeChrome(
      context: context,
      selected: _index,
      onSelect: _select,
      // The assistant gets the whole height; its back arrow leads out.
      hideBar: _index == homeAiIndex,
      body: IndexedStack(index: _index, children: pages),
    );
  }
}
