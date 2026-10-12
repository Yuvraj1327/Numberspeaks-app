import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Width-based sizing helpers shared by the screens, so phones of different
/// sizes, tablets and desktop windows are handled in one place.
class Responsive {
  Responsive._();

  /// Phones narrower than this (e.g. 320-pt devices) get tighter spacing.
  static const double compactWidth = 360;

  /// Tablet / desktop: page content stops growing and is centred.
  static const double maxContentWidth = 1200;

  static bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidth;

  /// Horizontal/vertical page padding: 12 on very small phones, 16 on phones,
  /// 24 on tablets and wider.
  static double pagePadding(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < compactWidth) return AppSpacing.md - 4;
    if (width >= 600) return AppSpacing.lg;
    return AppSpacing.md;
  }

  static EdgeInsets pageInsets(BuildContext context) => EdgeInsets.all(pagePadding(context));

  /// A body shorter than this (landscape phone, or a small phone with the
  /// keyboard up) drops its optional notes/summary so the list keeps room.
  static const double shortBodyHeight = 420;

  /// A table row height that grows with the user's font size, so enlarged
  /// text is never clipped inside a fixed-height row.
  static double rowHeight(BuildContext context, double base) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    return base * scale;
  }
}
