import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import 'app_logo.dart';

/// The shared header at the top of every main tab: a small muted eyebrow
/// line, a large bold title, and the Numberspeaks logo on the right.
class ScreenHeader extends StatelessWidget {
  final String eyebrow;
  final String title;
  final Widget? trailing;

  const ScreenHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.navy,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        trailing ?? const AppLogo(size: 48),
      ],
    );
  }
}

/// Bold section label ("Quick Actions", "Recent activity", …).
class SectionTitle extends StatelessWidget {
  final String text;

  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppTheme.navy,
          ),
    );
  }
}

/// Rounded tinted square holding an icon — the leading badge used on
/// summary tiles, list rows and settings tiles.
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const IconBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: Icon(icon, size: size * 0.52, color: color),
    );
  }
}
