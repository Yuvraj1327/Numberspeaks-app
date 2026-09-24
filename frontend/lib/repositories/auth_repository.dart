import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../core/api_client.dart';
import '../services/auth_service.dart';

/// Holds the app's current auth/session state and keeps [ApiClient] in sync
/// with it. Screens/routing read [isLoggedIn] instead of talking to
/// Supabase or the API client directly.
class AuthRepository extends ChangeNotifier {
  AuthRepository({required AuthService authService, required ApiClient apiClient})
      : _authService = authService,
        _apiClient = apiClient {
    _session = _authService.currentSession;
    _apiClient.setAuthToken(_session?.accessToken);
    _authStateSubscription = _authService.authStateChanges.listen((state) {
      _session = state.session;
      _apiClient.setAuthToken(_session?.accessToken);
      notifyListeners();
    });
  }

  final AuthService _authService;
  final ApiClient _apiClient;
  late final StreamSubscription<supa.AuthState> _authStateSubscription;

  supa.Session? _session;
  bool isLoading = false;
  String? lastError;

  @override
  void dispose() {
    _authStateSubscription.cancel();
    super.dispose();
  }

  bool get isLoggedIn => _session != null;
  String? get userEmail => _session?.user.email;

  Future<bool> login({required String email, required String password}) async {
    isLoading = true;
    lastError = null;
    notifyListeners();

    try {
      final session = await _authService.signInWithPassword(email: email, password: password);
      _session = session;
      _apiClient.setAuthToken(session.accessToken);
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _authService.signOut();
    _session = null;
    _apiClient.setAuthToken(null);
    notifyListeners();
  }
}
