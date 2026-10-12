import '../core/api_client.dart';
import '../models/user_profile.dart';

/// Talks to the /users endpoints: the casino users of this admin (bonus
/// recipients — they never log in), their saved WhatsApp numbers, carried
/// balances and calculation history.
class UsersApiService {
  UsersApiService(this._client);

  final ApiClient _client;

  /// GET /api/v1/users?q=
  Future<List<UserProfile>> list({String? query}) async {
    final trimmed = query?.trim() ?? '';
    final data = await _client.getList(
      '/users',
      query: trimmed.isEmpty ? null : {'q': trimmed},
    );
    return data.map((e) => UserProfile.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// GET /api/v1/users/{user_id}
  Future<UserProfile> get(String userId) async {
    final json = await _client.get('/users/$userId');
    return UserProfile.fromJson(json);
  }

  /// PATCH /api/v1/users/{user_id} — saves (or, with an empty string,
  /// clears) the WhatsApp number permanently.
  Future<UserProfile> saveWhatsAppNumber(String userId, String number) async {
    final json = await _client.patch('/users/$userId', body: {'whatsapp_number': number});
    return UserProfile.fromJson(json);
  }

  /// GET /api/v1/users/{user_id}/history
  Future<UserHistory> history(String userId) async {
    final json = await _client.get('/users/$userId/history');
    return UserHistory.fromJson(json);
  }
}
