import 'package:flutter/material.dart';

import 'account_screen.dart';
import 'dashboard_screen.dart';
import 'reports_screen.dart';
import 'results_screen.dart';
import 'settings_screen.dart';

/// The app's home — no top navbar (removed per the latest UI round: every
/// tab's content starts right at the top of the screen for a more compact,
/// less chrome-heavy layout), just a fixed bottom navigation bar for the
/// five main features (Dashboard, Reports, Results, Account, Settings).
/// Reached after login (see AppRoutes.home); every other screen (upload,
/// processing, a specific report's results, user detail, terms) is still
/// pushed on top of this via the normal Navigator and keeps its own AppBar
/// — those aren't a persistent "navbar", they're the back-navigation
/// affordance for a screen that isn't one of the five tabs, so removing
/// them would remove real functionality rather than just chrome.
///
/// Tabs are kept alive with [IndexedStack] rather than rebuilt on every
/// switch, so scroll position and in-flight loads survive tapping between
/// tabs.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const _accountIndex = 3;

  int _index = 0;

  void _goToTab(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final tabs = [
      const DashboardTab(),
      const ReportsTab(),
      const ResultsTab(),
      const AccountTab(),
      SettingsTab(onOpenAccount: () => _goToTab(_accountIndex)),
    ];

    return Scaffold(
      // No AppBar here (see class doc) — SafeArea replaces the top inset
      // an AppBar would otherwise have provided, so content never sits
      // under a status bar/notch.
      body: SafeArea(child: IndexedStack(index: _index, children: tabs)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goToTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.description_outlined),
            selectedIcon: Icon(Icons.description),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Results',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Account',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
