import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/file_download.dart';
import '../repositories/report_repository.dart';
import '../core/responsive.dart';
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
/// A plain grouped list — Account, Casino users, Bonus rates, Theme, App
/// information, Terms & Conditions, Logout. Theme and App information are
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
      padding: Responsive.pageInsets(context),
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
              icon: Icons.groups_outlined,
              title: 'Casino users',
              subtitle: 'WhatsApp numbers, carried balances and history',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.users),
            ),
            _SettingsTile(
              icon: Icons.share_outlined,
              title: 'Referrals',
              subtitle: 'Users, referrers and the referral ledger',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.referralHub),
            ),
            _SettingsTile(
              icon: Icons.tune_outlined,
              title: 'Rates & WhatsApp message',
              subtitle: 'Personal / referral percentages and the message template',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.rates),
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
              icon: Icons.download_outlined,
              title: 'Export users (CSV)',
              onTap: () => downloadAndSave(context,
                  apiPath: '/export/users.csv', fileName: 'users.csv', allowedExtension: 'csv'),
            ),
            _SettingsTile(
              icon: Icons.table_view_outlined,
              title: 'Export referral ledger (CSV)',
              onTap: () => downloadAndSave(context,
                  apiPath: '/export/referrals.csv', fileName: 'referral-ledger.csv', allowedExtension: 'csv'),
            ),
            _SettingsTile(
              icon: Icons.backup_outlined,
              title: 'Back up all data',
              subtitle: 'Downloads one JSON file of users, weeks, referrals and settings',
              onTap: () => downloadAndSave(context,
                  apiPath: '/backup', fileName: 'numberspeaks-backup.json', allowedExtension: 'json'),
            ),
            _SettingsTile(
              icon: Icons.restore_outlined,
              title: 'Restore from backup',
              subtitle: 'Merges a backup file into this account',
              onTap: () => _restoreBackup(context),
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

  Future<void> _restoreBackup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<ReportRepository>();
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final bytes = picked?.files.single.bytes;
    if (bytes == null || !context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Restore this backup?'),
        content: const Text(
          'Rows in the file are added to this account, and rows that already exist are set back to the '
          'backed-up values. Nothing is deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException('not an object');
      final result = await repo.restoreBackup(decoded);
      final counts = (result['restored'] as Map?)?.entries.map((e) => '${e.value} ${e.key}').join(', ') ?? '';
      messenger.showSnackBar(SnackBar(content: Text('Restored: $counts')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } on FormatException {
      messenger.showSnackBar(const SnackBar(content: Text('That file is not a valid Numberspeaks backup.')));
    }
  }

  void _showThemeInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
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
        scrollable: true,
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
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
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
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 2),
          leading: IconBadge(icon: icon, color: iconColor ?? AppTheme.blue, size: 40),
          title: Text(title,
              style: TextStyle(color: titleColor, fontSize: 15, fontWeight: FontWeight.w500)),
          subtitle: subtitle != null
              ? Text(subtitle!, style: Theme.of(context).textTheme.bodySmall)
              : null,
          trailing: const Icon(Icons.chevron_right, color: AppTheme.textMuted),
          onTap: onTap,
        ),
        if (showDivider) const Divider(height: 1, indent: 72, endIndent: AppSpacing.md),
      ],
    );
  }
}
