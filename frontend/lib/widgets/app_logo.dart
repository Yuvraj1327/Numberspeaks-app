import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// The Numberspeaks logo — used in the top navbar and the login screen.
/// Falls back to a drawn icon in the same brand colors if the asset can't
/// be loaded (e.g. a build that ran before `flutter pub get` picked up the
/// new asset entry), so a missing image file never crashes the app.
class AppLogo extends StatelessWidget {
  final double size;

  /// Adds a soft brand-colored shadow under the icon (used on the login
  /// screen where the logo is large and stands on its own).
  final bool elevated;

  const AppLogo({super.key, this.size = 32, this.elevated = false});

  // The PNG is 512x512 with the rounded-square icon occupying roughly the
  // middle 402px (transparent margin around it). Scaling the image up by
  // 512/402 and clipping to the icon's own corner radius makes the visible
  // icon fill exactly [size] x [size] instead of floating in empty space.
  static const double _contentScale = 512 / 402;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.23);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: AppTheme.navy.withOpacity(0.28),
                  blurRadius: size * 0.3,
                  offset: Offset(0, size * 0.1),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Transform.scale(
          scale: _contentScale,
          child: Image.asset(
            'assets/images/numberspeaks_logo.png',
            width: size,
            height: size,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (context, error, stackTrace) => Container(
              width: size,
              height: size,
              color: AppTheme.navy,
              child: Icon(Icons.show_chart_rounded, color: AppTheme.cyan, size: size * 0.6 / _contentScale),
            ),
          ),
        ),
      ),
    );
  }
}
