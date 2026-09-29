import 'package:flutter/material.dart';

import '../models/bonus_result.dart';
import '../screens/login_screen.dart';
import '../screens/report_processing_screen.dart';
import '../screens/report_upload_screen.dart';
import '../screens/user_detail_screen.dart';
import '../widgets/app_shell.dart';
import 'app_routes.dart';

/// Central `onGenerateRoute` — every screen is reached only through here, so
/// the navigation graph (and what arguments each screen expects) is visible
/// in one place instead of scattered across `Navigator.push` calls.
class AppRouter {
  AppRouter._();

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.login:
        return MaterialPageRoute(builder: (_) => const LoginScreen(), settings: settings);

      case AppRoutes.dashboard:
        // Optional int argument selects which bottom-nav tab to land on
        // (e.g. jumping straight to Results after processing completes).
        final initialTab = settings.arguments is int ? settings.arguments as int : 0;
        return MaterialPageRoute(
          builder: (_) => AppShell(initialTabIndex: initialTab),
          settings: settings,
        );

      case AppRoutes.upload:
        return MaterialPageRoute(builder: (_) => const ReportUploadScreen(), settings: settings);

      case AppRoutes.processing:
        final reportId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ReportProcessingScreen(reportId: reportId),
          settings: settings,
        );

      case AppRoutes.userDetail:
        final args = settings.arguments as UserDetailArgs;
        return MaterialPageRoute(
          builder: (_) => UserDetailScreen(args: args),
          settings: settings,
        );

      default:
        return MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(child: Text('Unknown route: ${settings.name}')),
          ),
        );
    }
  }
}

/// Arguments for [UserDetailScreen] — the report id (for the WhatsApp/
/// results API calls) plus the [BonusResult] already fetched on the Results
/// screen, so the detail screen can render instantly and simply refresh in
/// the background rather than reshowing a full loading state.
class UserDetailArgs {
  final String reportId;
  final BonusResult initialResult;

  const UserDetailArgs({required this.reportId, required this.initialResult});
}
