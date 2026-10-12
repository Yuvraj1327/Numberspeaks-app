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

  // --- Referral ledger (all weeks) ---------------------------------------

  /// GET /api/v1/referral-ledger
  Future<List<ReferralEntry>> ledger() async {
    final data = await _client.getList('/referral-ledger');
    return data.map((e) => ReferralEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// POST /api/v1/referral-ledger — manual referral activity for one week.
  /// [amount] is the referred user's profit/loss (loss negative); omit it to
  /// use their figure from the week's report.
  Future<ReferralEntry> addToLedger({
    required String reportId,
    required String referrerUserId,
    required String referredUserId,
    double? rate,
    double? amount,
    String? note,
  }) async {
    final json = await _client.post(
      '/referral-ledger',
      body: {
        'report_id': reportId,
        'referrer_user_id': referrerUserId,
        'referred_user_id': referredUserId,
        if (rate != null) 'rate': rate,
        if (amount != null) 'amount': amount,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    );
    return ReferralEntry.fromJson(json);
  }

  /// PATCH /api/v1/referral-ledger/{entry_id}
  Future<ReferralEntry> updateLedgerEntry(String entryId, Map<String, dynamic> changes) async {
    final json = await _client.patch('/referral-ledger/$entryId', body: changes);
    return ReferralEntry.fromJson(json);
  }

  /// DELETE /api/v1/referral-ledger/{entry_id}
  Future<void> deleteLedgerEntry(String entryId) => _client.delete('/referral-ledger/$entryId');

  // --- Referrers ----------------------------------------------------------

  Future<List<Referrer>> referrers() async {
    final data = await _client.getList('/referrers');
    return data.map((e) => Referrer.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Referrer> addReferrer(Map<String, dynamic> body) async {
    return Referrer.fromJson(await _client.post('/referrers', body: body));
  }

  Future<Referrer> updateReferrer(String id, Map<String, dynamic> changes) async {
    return Referrer.fromJson(await _client.patch('/referrers/$id', body: changes));
  }

  Future<void> deleteReferrer(String id) => _client.delete('/referrers/$id');

  /// DELETE /api/v1/reports/{report_id}/referrals/{entry_id}
  Future<void> remove(String reportId, String entryId) {
    return _client.delete('/reports/$reportId/referrals/$entryId');
  }

  // --- Export / backup -------------------------------------------------------

  /// GET any export path (CSV or /backup) as raw bytes.
  Future<List<int>> download(String path) => _client.getBytes(path);

  /// POST /api/v1/restore — merges a backup file into this account.
  Future<Map<String, dynamic>> restore(Map<String, dynamic> backup) => _client.post('/restore', body: backup);
}
