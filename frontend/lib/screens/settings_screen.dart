import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_theme.dart';
import '../repositories/report_repository.dart';

/// Settings tab — local app preferences only. No backend/API behavior
/// lives here.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmClearLocalData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear local data?'),
        content: const Text(
          "This removes this device's remembered \"last report\" only. "
          'Nothing is deleted on the server.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await context.read<ReportRepository>().clearLocalData();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Local data cleared.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text(
          'Settings',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SectionLabel('Data'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.delete_outline, color: AppTheme.primary),
            title: const Text('Clear local data'),
            subtitle: const Text('Forgets this device\'s last uploaded report'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _confirmClearLocalData(context),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SectionLabel('About'),
        const Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.info_outline, color: AppTheme.primary),
                title: Text('Numberspeaks'),
                subtitle: Text('Version 1.0.0'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.description_outlined, color: AppTheme.primary),
                title: Text('Bonus Calculation App'),
                subtitle: Text('Frontend for the Numberspeaks backend'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: AppSpacing.xs),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
