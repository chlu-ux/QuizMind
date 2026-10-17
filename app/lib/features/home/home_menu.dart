import 'package:flutter/material.dart';

/// The top-level destinations of the home screen, in order.
const homeDestinations = [
  (icon: Icons.menu_book_outlined, selected: Icons.menu_book, label: '题库'),
  (icon: Icons.error_outline, selected: Icons.error, label: '错题本'),
  (
    icon: Icons.auto_awesome_outlined,
    selected: Icons.auto_awesome,
    label: 'AI',
  ),
  (icon: Icons.star_border, selected: Icons.star, label: '收藏'),
  (icon: Icons.settings_outlined, selected: Icons.settings, label: '设置'),
];

const homeAiIndex = 2;
const homeSettingsIndex = 4;

/// The home screen's menu around [body]: a rail on wide windows (macOS), a bottom bar on phones.
/// [hideBar] leaves out the bottom bar, for a page that needs the height (the rail takes width, not height).
Widget homeChrome({
  required BuildContext context,
  required int selected,
  required ValueChanged<int> onSelect,
  required Widget body,
  bool hideBar = false,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  if (wide) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selected,
            onDestinationSelected: onSelect,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in homeDestinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
  return Scaffold(
    body: body,
    bottomNavigationBar: hideBar
        ? null
        : NavigationBar(
            selectedIndex: selected,
            onDestinationSelected: onSelect,
            destinations: [
              for (final d in homeDestinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: d.label,
                ),
            ],
          ),
  );
}
