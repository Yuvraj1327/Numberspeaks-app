import '../core/api_client.dart';
import '../models/bonus_settings.dart';

/// Talks to /settings: this admin's personal and referral rates.
class SettingsApiService {
  SettingsApiService(this._client);

  final ApiClient _client;

  /// GET /api/v1/settings
  Future<BonusSettings> get() async {
    final json = await _client.get('/settings');
    return BonusSettings.fromJson(json);
  }

  /// PUT /api/v1/settings — rates are fractions (0.03 = 3%).
  Future<BonusSettings> save({
    required double personalRate,
    required double referralRate,
    String? whatsappTemplate,
  }) async {
    final json = await _client.put(
      '/settings',
      body: {
        'personal_rate': personalRate,
        'referral_rate': referralRate,
        if (whatsappTemplate != null) 'whatsapp_template': whatsappTemplate,
      },
    );
    return BonusSettings.fromJson(json);
  }
}
