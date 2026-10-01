import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../core/api_exception.dart';

/// Wraps Supabase Auth directly for login/session — the FastAPI backend has
/// no `/auth/login` endpoint of its own (Step 8 gap, disclosed in the
/// README), so this is the "existing authentication/access mechanism"
/// referred to by the spec: Supabase Auth, which the project already uses
/// for the database (Step 2).
///
/// IMPORTANT (also in README): the FastAPI backend does not currently
/// verify this session/token on its endpoints. The access token is still
/// attached to every backend request (via ApiClient.setAuthToken) so the
/// backend can start enforcing it later with zero Flutter-side changes.
class AuthService {
  AuthService({supa.SupabaseClient? client})
      : _client = client ?? supa.Supabase.instance.client;

  final supa.SupabaseClient _client;

  supa.Session? get currentSession => _client.auth.currentSession;

  Stream<supa.AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<supa.Session> signInWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final session = response.session;
      if (session == null) {
        throw const ApiException(
          kind: ApiErrorKind.unauthorized,
          message: 'Invalid email or password.',
        );
      }
      return session;
    } on supa.AuthException catch (e) {
      throw ApiException(
        kind: ApiErrorKind.unauthorized,
        message: e.message.isNotEmpty ? e.message : 'Invalid email or password.',
      );
    } catch (e) {
      throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'Could not reach the login service.',
      );
    }
  }

  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (_) {
      // The server call failed (offline / expired token) and Supabase keeps
      // the persisted session in that case — drop it locally so the user
      // isn't silently logged back in on next launch.
      await _client.auth.signOut(scope: supa.SignOutScope.local);
    }
  }
}
