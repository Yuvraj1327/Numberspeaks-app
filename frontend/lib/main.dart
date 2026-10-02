import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import 'core/api_client.dart';
import 'core/app_config.dart';
import 'core/app_theme.dart';
import 'repositories/auth_repository.dart';
import 'repositories/report_repository.dart';
import 'routing/app_router.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'services/activity_log_store.dart';
import 'services/auth_service.dart';
import 'services/bonus_api_service.dart';
import 'services/local_report_store.dart';
import 'services/reports_api_service.dart';
import 'services/supabase_report_store.dart';
import 'services/whatsapp_api_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Requires a real .env next to pubspec.yaml — copy it from
    // .env.example first (see README). If it's missing, the app still
    // starts and shows the "Missing configuration" screen below, instead
    // of crashing on launch.
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // No .env present — AppConfig's getters fall back to empty/default
    // values, which _ConfigurationMissingScreen below handles cleanly.
  }

  if (AppConfig.isSupabaseConfigured) {
    await supa.Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
    );
  }

  runApp(const NumberspeaksApp());
}

class NumberspeaksApp extends StatelessWidget {
  const NumberspeaksApp({super.key});

  @override
  Widget build(BuildContext context) {
    final apiClient = ApiClient();

    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthRepository>(
          create: (_) => AuthRepository(
            authService: AuthService(),
            apiClient: apiClient,
          ),
        ),
        ChangeNotifierProvider<ReportRepository>(
          create: (context) {
            // Everything the report layer keeps on the device is tied to
            // whoever is signed in at the moment it is used.
            final auth = context.read<AuthRepository>();
            String? currentUserId() => auth.userId;
            return ReportRepository(
              reportsApi: ReportsApiService(apiClient),
              bonusApi: BonusApiService(apiClient),
              whatsappApi: WhatsAppApiService(apiClient),
              localStore: LocalReportStore(userId: currentUserId),
              activityLog: ActivityLogStore(userId: currentUserId),
              currentUserId: currentUserId,
              supabaseStore: SupabaseReportStore(),
            );
          },
        ),
      ],
      child: MaterialApp(
        title: 'Numberspeaks',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        onGenerateRoute: AppRouter.onGenerateRoute,
        home: const _AuthGate(),
      ),
    );
  }
}

/// Sends the user to the Dashboard if already logged in (an existing
/// Supabase session), otherwise to the Login screen.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.isSupabaseConfigured) {
      return const _ConfigurationMissingScreen();
    }

    final auth = context.watch<AuthRepository>();
    return auth.isLoggedIn ? const MainShell() : const LoginScreen();
  }
}

/// Shown instead of crashing when SUPABASE_URL / SUPABASE_ANON_KEY were not
/// supplied via --dart-define — see README "Running the app".
class _ConfigurationMissingScreen extends StatelessWidget {
  const _ConfigurationMissingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.settings_outlined, size: 48, color: AppTheme.warning),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Missing configuration',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'SUPABASE_URL and SUPABASE_ANON_KEY must be provided via --dart-define '
                'when running or building this app. See the README.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
