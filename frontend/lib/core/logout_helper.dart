import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../repositories/auth_repository.dart';
import '../routing/app_routes.dart';

/// Shared confirm-then-log-out dialog — used by both the Account and
/// Settings tabs so there's exactly one logout flow, not two slightly
/// different copies of the same dialog.
Future<void> confirmAndLogout(BuildContext context, AuthRepository auth) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Log out?'),
      content: const Text('You will need to sign in again to access your reports.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Log Out', style: TextStyle(color: AppTheme.danger)),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    // Grab the navigator before the await — this context may be gone by then.
    final navigator = Navigator.of(context, rootNavigator: true);
    await auth.logout();
    // Login does pushReplacementNamed(home), so the auth gate is no longer
    // in the route stack to react to the cleared session. Explicitly drop
    // every route (home, plus anything pushed on top) and land on Login.
    navigator.pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
  }
}
