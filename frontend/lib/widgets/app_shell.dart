import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../screens/account_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/results_screen.dart';
import '../screens/settings_screen.dart';
import 'app_logo.dart';

/// The app's single root layout once logged in: a slim brand top bar plus
/// Dashboard / Reports / Results / Account / Settings navigation — a
/// bottom bar on phones, a side rail on wide (web/desktop) windows. Each
/// tab keeps its state via [IndexedStack] while switching.
class AppShell extends StatefulWidget {
  final int initialTabIndex;

  const AppShell({super.key, this.initialTabIndex = 0});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem({required this.icon, required this.activeIcon, required this.label});
}

const _navItems = [
  _NavItem(icon: Icons.dashboard_outlined, activeIcon: Icons.dashboard, label: 'Dashboard'),
  _NavItem(icon: Icons.description_outlined, activeIcon: Icons.description, label: 'Reports'),
  _NavItem(icon: Icons.fact_check_outlined, activeIcon: Icons.fact_check, label: 'Results'),
  _NavItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'Account'),
  _NavItem(icon: Icons.settings_outlined, activeIcon: Icons.settings, label: 'Settings'),
];

/// Windows at least this wide switch from a bottom bar to a side rail —
/// roughly "tablet landscape and up", which covers typical Chrome/Mac
/// windows while phones (portrait or landscape) stay on the bottom bar.
const double _wideLayoutBreakpoint = 900;

class _AppShellState extends State<AppShell> {
  late int _index = widget.initialTabIndex;

  void _switchTab(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint;

    final tabs = <Widget>[
      DashboardScreen(onSwitchTab: _switchTab),
      ReportsScreen(onSwitchTab: _switchTab),
      ResultsScreen(onSwitchTab: _switchTab),
      const AccountScreen(),
      const SettingsScreen(),
    ];

    final body = SafeArea(
      top: false,
      bottom: !isWide,
      child: IndexedStack(index: _index, children: tabs),
    );

    return Scaffold(
      appBar: const _TopBar(),
      body: isWide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _switchTab,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final item in _navItems)
                      NavigationRailDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.activeIcon),
                        label: Text(item.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: body,
                    ),
                  ),
                ),
              ],
            )
          : body,
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _switchTab,
              destinations: [
                for (final item in _navItems)
                  NavigationDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.activeIcon),
                    label: item.label,
                  ),
              ],
            ),
    );
  }
}

/// Slim brand bar — logo + "Numberspeaks" only. No page title, no actions
/// (log out lives on the Account tab instead).
class _TopBar extends StatelessWidget implements PreferredSizeWidget {
  const _TopBar();

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.brandGradient),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: preferredSize.height,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                AppLogo(size: 30),
                SizedBox(width: AppSpacing.sm),
                Text(
                  'Numberspeaks',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
