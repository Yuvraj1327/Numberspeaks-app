import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Central, environment-driven configuration — reads a real `.env` file at
/// startup via `flutter_dotenv` (loaded once in `main.dart` before
/// `runApp`), mirroring the backend's own `python-dotenv`-based
/// `app/core/config.py`. Nothing here is hardcoded to a real value; see
/// `.env.example` for the exact keys expected.
///
/// Note (unlike the backend): `.env` is bundled into the compiled app as an
/// asset, so it ships inside the built APK/IPA and can be extracted from
/// it. That's an accepted tradeoff for a backend URL and a Supabase
/// *anon* key (which is public-safe by design), but never put a secret
/// that must stay private — like the backend's service-role key — into
/// this file.
class AppConfig {
  AppConfig._();

  /// Base URL of the FastAPI backend, e.g. https://numberspeaks.up.railway.app
  /// Must NOT include the trailing /api/v1 — that is appended by ApiClient.
  static String get apiBaseUrl =>
      dotenv.env['API_BASE_URL'] ?? 'http://10.0.2.2:8000';

  /// Supabase project URL. Used for Auth (login/session) as before, and —
  /// as of the "final user result flow" round — also for direct,
  /// owner-scoped table/storage access (see SupabaseReportStore), which
  /// durably persists uploaded reports/results per account. All bonus
  /// *calculation* still happens only via the FastAPI backend; Supabase is
  /// a persistence layer on top, never a second place business logic runs.
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';

  /// Supabase anon (public) key. Never the service-role key — that stays
  /// server-side only, in the backend's own .env.
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  static const Duration apiConnectTimeout = Duration(seconds: 15);
  static const Duration apiReceiveTimeout = Duration(seconds: 30);
  // Upload can take longer: PDFs may be large and extraction runs server-side
  // before the response is returned.
  static const Duration apiUploadTimeout = Duration(seconds: 120);

  static bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
