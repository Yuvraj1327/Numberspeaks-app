import 'package:flutter/material.dart';

/// Numberspeaks brand theme — a premium fintech/analytics palette taken
/// from the app logo: deep navy, a royal/bright blue, cyan, and a
/// teal-green, on white. Token *names* below (`primary`, `success`,
/// `danger`, `warning`, `surfaceMuted`) are unchanged from the previous
/// theme on purpose — every existing screen already references them, so
/// retuning their values here re-skins the whole app without touching
/// screen code. Light theme only, by design (see README).
class AppTheme {
  AppTheme._();

  // --- Brand palette (from the logo) ---------------------------------
  static const Color navy = Color(0xFF0A1B33); // logo background
  static const Color navySoft = Color(0xFF14294B); // secondary dark surface
  static const Color blue = Color(0xFF2F6FEA); // the "N" glyph / primary actions
  static const Color cyan = Color(0xFF2FC4DE); // chart accent / active states
  static const Color teal = Color(0xFF14B893); // chart accent / positive values

  // --- Semantic tokens used throughout the app ------------------------
  static const Color primary = blue;
  static const Color primaryDark = navy;
  static const Color success = teal;
  static const Color danger = Color(0xFFD64545);
  static const Color warning = Color(0xFFC98A1D);
  static const Color surfaceMuted = Color(0xFFEEF2FA); // faint navy-tinted neutral
  static const Color background = Color(0xFFF5F7FC); // off-white page background
  static const Color textMuted = Color(0xFF64708A); // secondary labels
  static const Color hairline = Color(0xFFE3E8F2); // card borders / dividers

  // A near-black rather than pure-black text color reads as more "premium
  // fintech" than default Material black87, and is used as the default
  // body/heading color everywhere below for stronger contrast/readability.
  static const Color textStrong = Color(0xFF0F1A30);

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: blue,
        primary: blue,
        secondary: teal,
        tertiary: cyan,
        error: danger,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: background,
    );

    // Bolder, higher-contrast type scale — headings and card values read
    // clearly at a glance, per the "highly readable" brief. Every screen
    // already pulls its text styles from Theme.of(context).textTheme, so
    // this alone re-weights the whole app without per-screen edits.
    final textTheme = base.textTheme
        .apply(bodyColor: textStrong, displayColor: textStrong)
        .copyWith(
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
              fontSize: 30, fontWeight: FontWeight.w800, color: textStrong, letterSpacing: -0.5),
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
              fontSize: 26, fontWeight: FontWeight.w800, color: textStrong, letterSpacing: -0.4),
          titleLarge: base.textTheme.titleLarge?.copyWith(
              fontSize: 22, fontWeight: FontWeight.w800, color: textStrong),
          titleMedium: base.textTheme.titleMedium?.copyWith(
              fontSize: 17, fontWeight: FontWeight.w700, color: textStrong),
          titleSmall: base.textTheme.titleSmall?.copyWith(
              fontSize: 15, fontWeight: FontWeight.w700, color: textStrong),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
              fontSize: 16, fontWeight: FontWeight.w600, color: textStrong),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
              fontSize: 15, fontWeight: FontWeight.w600, color: textStrong),
          bodySmall: base.textTheme.bodySmall?.copyWith(
              fontSize: 13, fontWeight: FontWeight.w500, color: textMuted),
          labelSmall: base.textTheme.labelSmall?.copyWith(
              fontSize: 12, fontWeight: FontWeight.w600, color: textMuted),
        );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: navy,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: navy,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
        iconTheme: IconThemeData(color: navy),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: navy.withOpacity(0.25),
        indicatorColor: blue.withOpacity(0.12),
        indicatorShape: const StadiumBorder(),
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        // Bold labels at both states so every tab stays clearly legible;
        // the selected one is heavier and picks up the brand blue.
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
            color: selected ? navy : textMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? navy : textMuted, size: 26);
        }),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: blue,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(54),
          elevation: 0,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: hairline, width: 1.4),
          foregroundColor: blue,
          backgroundColor: Colors.white,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: blue,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        hintStyle: const TextStyle(color: textMuted, fontWeight: FontWeight.w600),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: blue, width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: CardThemeData(
        // Soft, wide, low-opacity shadow + hairline border: reads as a
        // clean floating card on the off-white page.
        elevation: 3,
        shadowColor: navy.withOpacity(0.10),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: hairline),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        side: const BorderSide(color: hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: const TextStyle(
            color: textStrong, fontSize: 20, fontWeight: FontWeight.w800),
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1, color: hairline),
      listTileTheme: ListTileThemeData(
        iconColor: navy,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

/// A softer, larger drop shadow than the default CardTheme elevation, for
/// the rare surface that wants to lift further off the page than an
/// ordinary card (e.g. a modal-like emphasized container).
class AppShadows {
  AppShadows._();
  static List<BoxShadow> soft = [
    BoxShadow(
      color: AppTheme.navy.withOpacity(0.08),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];
}
