import '../core/api_client.dart';
import '../models/referral_entry.dart';

/// Talks to the referral-entry endpoints of a report (period).
class ReferralsApiService {
  ReferralsApiService(this._client);

  final ApiClient _client;

  /// GET /api/v1/reports/{report_id}/referrals
  Future<List<ReferralEntry>> list(String reportId) async {
    final data = await _client.getList('/reports/$reportId/referrals');
    return data.map((e) => ReferralEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// POST /api/v1/reports/{report_id}/referrals — [rate] is a fraction
  /// (0.10 = 10%); omit it to use the admin's configured referral rate.
  Future<ReferralEntry> add(
    String reportId, {
    required String referrerUserId,
    required String referredUserId,
    double? rate,
  }) async {
    final json = await _client.post(
      '/reports/$reportId/referrals',
      body: {
        'referrer_user_id': referrerUserId,
        'referred_user_id': referredUserId,
        if (rate != null) 'rate': rate,
      },
    );
    return ReferralEntry.fromJson(json);
  }

  /// DELETE /api/v1/reports/{report_id}/referrals/{entry_id}
  Future<void> remove(String reportId, String entryId) {
    return _client.delete('/reports/$reportId/referrals/$entryId');
  }
}
