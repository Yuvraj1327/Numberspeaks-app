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

  /// Supabase project URL, used only for Auth (login/session), never for
  /// direct table access — all report/bonus/WhatsApp data goes through the
  /// FastAPI backend, never directly from Flutter to Supabase tables.
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
