import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../repositories/auth_repository.dart';

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
    await auth.logout();
  }
}
