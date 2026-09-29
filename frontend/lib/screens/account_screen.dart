import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_theme.dart';
import '../repositories/auth_repository.dart';

/// Account tab — who's signed in and the sign-out action (moved here from
/// the old Dashboard app bar icon).
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository>();
    final email = auth.userEmail ?? 'Signed in';
    final initial = email.isNotEmpty ? email[0].toUpperCase() : '?';

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text(
          'Account',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    gradient: AppTheme.brandGradient,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  email,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Signed in with Supabase',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: ListTile(
            leading: const Icon(Icons.logout, color: AppTheme.danger),
            title: const Text('Log out'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => auth.logout(),
          ),
        ),
      ],
    );
  }
}
