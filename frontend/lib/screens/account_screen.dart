import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/app_theme.dart';
import '../core/logout_helper.dart';
import '../repositories/auth_repository.dart';
import '../widgets/screen_header.dart';

/// Account tab (embedded inside [MainShell]) — the logged-in user's own
/// session information. Everything shown here is real Supabase Auth
/// session data (email, user id, token expiry), never invented profile
/// fields the backend doesn't have.
class AccountTab extends StatelessWidget {
  const AccountTab({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository>();
    final email = auth.userEmail ?? 'Unknown';
    final initial = email.isNotEmpty ? email[0].toUpperCase() : '?';

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        const ScreenHeader(eyebrow: 'Your profile', title: 'Account'),
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 68,
                  height: 68,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [AppTheme.blue, AppTheme.navySoft],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Text(
                    initial,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        email,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontSize: 19, fontWeight: FontWeight.w900, color: AppTheme.navy),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Signed in with Supabase Authentication',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Column(
            children: [
              _InfoRow(label: 'Email', value: email, icon: Icons.email_outlined),
              const Divider(height: 1),
              // Supabase Auth (this app's only auth provider — see README)
              // has no role/permission system today, so there is no real
              // "role" to show. "Status" is shown instead, and it's true
              // by construction: reaching this screen means the session
              // is active, never a fabricated value.
              const _InfoRow(
                label: 'Status',
                value: 'Active',
                icon: Icons.verified_user_outlined,
                color: AppTheme.teal,
              ),
              const Divider(height: 1),
              _InfoRow(
                label: 'User ID',
                value: auth.userId ?? '—',
                icon: Icons.badge_outlined,
              ),
              if (auth.sessionExpiresAt != null) ...[
                const Divider(height: 1),
                _InfoRow(
                  label: 'Session expires',
                  value: DateFormat.yMMMd().add_jm().format(auth.sessionExpiresAt!),
                  icon: Icons.schedule_outlined,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          onPressed: () => confirmAndLogout(context, auth),
          icon: const Icon(Icons.logout, color: AppTheme.danger),
          label: const Text('Log Out', style: TextStyle(color: AppTheme.danger)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: AppTheme.danger.withOpacity(0.5), width: 1.4),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _InfoRow({
    required this.label,
    required this.value,
    required this.icon,
    this.color = AppTheme.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md - 2),
      child: Row(
        children: [
          IconBadge(icon: icon, color: color, size: 42),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(value,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.navy)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
