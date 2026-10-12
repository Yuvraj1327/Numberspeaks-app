import 'package:flutter/material.dart';

import '../models/bonus_result.dart';
import '../screens/login_screen.dart';
import '../screens/main_shell.dart';
import '../screens/rates_screen.dart';
import '../screens/referrals_screen.dart';
import '../screens/report_processing_screen.dart';
import '../screens/report_review_screen.dart';
import '../screens/report_upload_screen.dart';
import '../screens/results_screen.dart';
import '../screens/terms_screen.dart';
import '../screens/user_detail_screen.dart';
import '../screens/users_screen.dart';
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

      case AppRoutes.home:
        return MaterialPageRoute(builder: (_) => const MainShell(), settings: settings);

      case AppRoutes.upload:
        return MaterialPageRoute(builder: (_) => const ReportUploadScreen(), settings: settings);

      case AppRoutes.review:
        final args = settings.arguments;
        final reviewArgs = args is ReviewArgs ? args : ReviewArgs(reportId: args as String);
        return MaterialPageRoute(
          builder: (_) => ReportReviewScreen(reportId: reviewArgs.reportId, warnings: reviewArgs.warnings),
          settings: settings,
        );

      case AppRoutes.processing:
        final reportId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ReportProcessingScreen(reportId: reportId),
          settings: settings,
        );

      case AppRoutes.results:
        final reportId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ResultsScreen(reportId: reportId),
          settings: settings,
        );

      case AppRoutes.userDetail:
        final args = settings.arguments as UserDetailArgs;
        return MaterialPageRoute(
          builder: (_) => UserDetailScreen(args: args),
          settings: settings,
        );

      case AppRoutes.referrals:
        final reportId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ReferralsScreen(reportId: reportId),
          settings: settings,
        );

      case AppRoutes.users:
        return MaterialPageRoute(builder: (_) => const UsersScreen(), settings: settings);

      case AppRoutes.rates:
        return MaterialPageRoute(builder: (_) => const RatesScreen(), settings: settings);

      case AppRoutes.terms:
        return MaterialPageRoute(builder: (_) => const TermsScreen(), settings: settings);

      default:
        return MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(child: Text('Unknown route: ${settings.name}')),
          ),
        );
    }
  }
}

/// Arguments for [ReportReviewScreen]: the report, plus any warnings the
/// extraction produced (shown at the top of the review).
class ReviewArgs {
  final String reportId;
  final List<String> warnings;

  const ReviewArgs({required this.reportId, this.warnings = const []});
}

/// Arguments for [UserDetailScreen].
///
/// With a [reportId] the screen shows that report's calculation breakdown
/// for the user (and the Send WhatsApp action). Without one (opened from the
/// Users list) it shows the user's profile, carried balance and full
/// calculation history only.
class UserDetailArgs {
  final String userId;
  final String userName;
  final String? reportId;

  /// The row already loaded by the Results screen, so the detail screen can
  /// render instantly and refresh in the background.
  final BonusResult? initialResult;

  const UserDetailArgs({
    required this.userId,
    required this.userName,
    this.reportId,
    this.initialResult,
  });
}
