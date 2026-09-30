import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// A simple static screen for Terms & Conditions.
///
/// No terms content has been provided by the client, so this deliberately
/// shows an honest placeholder rather than inventing legal text — the same
/// "don't guess at business rules" principle this project has followed
/// throughout applies here too. Replace [_placeholderText] with the real
/// terms once they're provided.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const String _placeholderText =
      'Terms & Conditions for Numberspeaks have not been provided yet. '
      'This screen will show the official terms once they are supplied.\n\n'
      'This app is used to upload bonus reports, calculate bonuses, and '
      'notify users via WhatsApp on behalf of your organization. By using '
      'this app, you agree to use it only for its intended purpose within '
      'your organization.';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms & Conditions')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, color: AppTheme.warning, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Placeholder content',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: AppTheme.warning, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              _placeholderText,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
