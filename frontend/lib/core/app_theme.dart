import 'package:flutter/material.dart';

/// Numberspeaks brand theme — navy/blue/cyan/teal, light fintech look.
/// One theme, used everywhere, so no screen drifts from it.
class AppTheme {
  AppTheme._();

  // Brand palette.
  static const Color navy = Color(0xFF0B2545);
  static const Color navyDark = Color(0xFF071A33);
  static const Color primary = Color(0xFF1668C4);
  static const Color primaryDark = Color(0xFF0F4C8C);
  static const Color teal = Color(0xFF12B5AA);
  static const Color cyan = Color(0xFF35D0D0);

  static const Color success = Color(0xFF15A36E);
  static const Color danger = Color(0xFFDC3E3E);
  static const Color warning = Color(0xFFD98A1F);

  static const Color background = Color(0xFFF5F8FC);
  static const Color surfaceMuted = Color(0xFFEEF3F9);
  static const Color textSecondary = Color(0xFF5B6B82);

  /// Used behind the top nav bar / login header / nav rail.
  static const LinearGradient brandGradient = LinearGradient(
    colors: [navy, primary],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        secondary: teal,
        error: danger,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: background,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: const Color(0xFF15223B),
        displayColor: const Color(0xFF15223B),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: navy,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: primary),
          foregroundColor: primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFE4EAF2)),
        ),
        margin: EdgeInsets.zero,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1, color: Color(0xFFE4EAF2)),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        elevation: 0,
        height: 64,
        indicatorColor: teal.withOpacity(0.15),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? navy : textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? teal : textSecondary);
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: navy,
        indicatorColor: teal.withOpacity(0.25),
        selectedIconTheme: const IconThemeData(color: cyan),
        unselectedIconTheme: const IconThemeData(color: Colors.white70),
        selectedLabelTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: const TextStyle(color: Colors.white70),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? teal : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? teal.withOpacity(0.4) : null,
        ),
      ),
    );
  }
}

/// Consistent spacing scale used across all screens instead of magic numbers.
class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}
