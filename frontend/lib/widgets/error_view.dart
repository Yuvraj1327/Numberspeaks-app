import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// A single, consistent error state with an optional retry action. Always
/// shows [message] as-is — callers are expected to pass
/// `ApiException.userMessage`, never a raw exception's `toString()`.
class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorView({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.danger.withOpacity(0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.error_outline, color: AppTheme.danger, size: 34),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w400),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: 180,
                child: OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
