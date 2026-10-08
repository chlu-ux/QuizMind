import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../agent/agent_tab.dart';
import '../settings/settings_page.dart';
import 'banks_page.dart';
import 'question_list_page.dart';

/// Top-level navigation: a rail on wide windows (macOS), a bottom bar on phones.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const _destinations = [
    (icon: Icons.menu_book_outlined, selected: Icons.menu_book, label: '题库'),
    (icon: Icons.error_outline, selected: Icons.error, label: '错题本'),
    (icon: Icons.auto_awesome_outlined, selected: Icons.auto_awesome, label: 'AI'),
    (icon: Icons.star_border, selected: Icons.star, label: '收藏'),
    (icon: Icons.settings_outlined, selected: Icons.settings, label: '设置'),
  ];

  static const _aiIndex = 2;
  static const _settingsIndex = 4;

  late int _index;

  /// The assistant tab is built when first opened, not at start-up, so it asks the server nothing
  /// until the learner wants it.
  bool _aiOpened = false;

  @override
  void initState() {
    super.initState();
    final configured = ref.read(settingsProvider).configured;
    _index = configured ? 0 : _settingsIndex; // first run: go straight to the server settings
    if (configured) Future.microtask(() => ref.read(syncProvider.notifier).run());
  }

  void _select(int i) => setState(() {
    _index = i;
    if (i == _aiIndex) _aiOpened = true;
  });

  @override
  Widget build(BuildContext context) {
    final pages = [
      const BanksPage(),
      const QuestionListPage(kind: QuestionListKind.wrongBook),
      _aiOpened ? const AgentTab() : const SizedBox.shrink(),
      const QuestionListPage(kind: QuestionListKind.favorites),
      const SettingsPage(),
    ];
    final body = IndexedStack(index: _index, children: pages);
    final wide = MediaQuery.sizeOf(context).width >= 700;
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: _select,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label),
        ],
      ),
    );
  }
}
