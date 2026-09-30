import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_theme.dart';
import '../core/logout_helper.dart';
import '../repositories/auth_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/screen_header.dart';

/// Kept in sync with `pubspec.yaml`'s `version:` field by hand — adding a
/// package just to read it back at runtime (`package_info_plus`) would be
/// a new dependency for one static string this project already declares.
const String _appVersion = '1.0.0+1';

/// Settings tab (embedded inside [MainShell]).
///
/// A plain grouped list — Account, Theme, App information, Terms &
/// Conditions, Logout — per the spec. Theme and App information are
/// informational only (this app ships light-theme-only, and there is no
/// backend "about" content to show), never a toggle or content that isn't
/// real.
class SettingsTab extends StatelessWidget {
  final VoidCallback onOpenAccount;

  const SettingsTab({super.key, required this.onOpenAccount});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository>();

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        const ScreenHeader(eyebrow: 'Preferences', title: 'Settings'),
        const SizedBox(height: AppSpacing.lg),
        _SettingsGroup(
          children: [
            _SettingsTile(
              icon: Icons.person_outline,
              title: 'Account',
              subtitle: auth.userEmail,
              onTap: onOpenAccount,
            ),
            _SettingsTile(
              icon: Icons.palette_outlined,
              title: 'Theme',
              subtitle: 'Light (default)',
              onTap: () => _showThemeInfo(context),
            ),
            _SettingsTile(
              icon: Icons.info_outline,
              title: 'App Information',
              subtitle: 'Version, about Numberspeaks',
              onTap: () => _showAppInfo(context),
            ),
            _SettingsTile(
              icon: Icons.description_outlined,
              title: 'Terms & Conditions',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.terms),
              showDivider: false,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _SettingsGroup(
          children: [
            _SettingsTile(
              icon: Icons.logout,
              title: 'Logout',
              iconColor: AppTheme.danger,
              titleColor: AppTheme.danger,
              onTap: () => confirmAndLogout(context, auth),
              showDivider: false,
            ),
          ],
        ),
      ],
    );
  }

  void _showThemeInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Theme'),
        content: const Text(
          'Numberspeaks currently uses a light theme only. Dark theme '
          'support may be added in a future update.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  void _showAppInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About Numberspeaks'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Numberspeaks — Bonus Calculation App'),
            SizedBox(height: AppSpacing.sm),
            Text('Version $_appVersion'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;

  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? titleColor;
  final bool showDivider;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.iconColor,
    this.titleColor,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 4),
          leading: IconBadge(icon: icon, color: iconColor ?? AppTheme.primary, size: 44),
          title: Text(
            title,
            style: TextStyle(
              color: titleColor ?? AppTheme.navy,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          subtitle: subtitle != null
              ? Text(subtitle!,
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 13.5, fontWeight: FontWeight.w600))
              : null,
          trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 26),
          onTap: onTap,
        ),
        if (showDivider) const Divider(height: 1, indent: 76, endIndent: AppSpacing.md),
      ],
    );
  }
}
