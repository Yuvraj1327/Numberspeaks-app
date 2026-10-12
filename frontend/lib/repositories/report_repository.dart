import 'package:flutter/foundation.dart';

import '../models/bonus_calculation_summary.dart';
import '../models/bonus_result.dart';
import '../models/bonus_settings.dart';
import '../models/referral_entry.dart';
import '../models/report_summary.dart';
import '../models/upload_report_response.dart';
import '../models/user_profile.dart';
import '../models/validation_summary.dart';
import '../services/bonus_api_service.dart';
import '../services/referrals_api_service.dart';
import '../services/reports_api_service.dart';
import '../services/settings_api_service.dart';
import '../services/users_api_service.dart';
import '../services/whatsapp_api_service.dart';

/// Single point of access for everything report / bonus / user / referral /
/// settings / WhatsApp related. Screens depend on this, never on the API
/// services directly.
///
/// Nothing is cached or stored on the device: every list comes from the
/// backend (which keeps it in Supabase, scoped to the logged-in admin), so
/// it is identical after a refresh, a logout/login, or on another device.
class ReportRepository extends ChangeNotifier {
  ReportRepository({
    required ReportsApiService reportsApi,
    required BonusApiService bonusApi,
    required ReferralsApiService referralsApi,
    required UsersApiService usersApi,
    required SettingsApiService settingsApi,
    required WhatsAppApiService whatsappApi,
  })  : _reportsApi = reportsApi,
        _bonusApi = bonusApi,
        _referralsApi = referralsApi,
        _usersApi = usersApi,
        _settingsApi = settingsApi,
        _whatsappApi = whatsappApi;

  final ReportsApiService _reportsApi;
  final BonusApiService _bonusApi;
  final ReferralsApiService _referralsApi;
  final UsersApiService _usersApi;
  final SettingsApiService _settingsApi;
  final WhatsAppApiService _whatsappApi;

  int _revision = 0;
  int _structureRevision = 0;

  /// Bumps on every change made through this repository. Tabs compare it to
  /// the value they last loaded with, to know when to reload.
  int get revision => _revision;

  /// Bumps only when report data / calculations / referrals / rates change
  /// (not for a saved WhatsApp number or a WhatsApp "opened" record, which
  /// the screens already apply locally).
  int get structureRevision => _structureRevision;

  void _changed({bool structural = true}) {
    _revision++;
    if (structural) _structureRevision++;
    notifyListeners();
  }

  // --- Reports ----------------------------------------------------------

  Future<List<ReportSummary>> listReports() => _reportsApi.listReports();

  Future<ReportSummary> getReport(String reportId) => _reportsApi.getReport(reportId);

  /// Deletes a report on the backend (ownership is enforced there). Throws an
  /// [ApiException] if it could not be deleted — callers must then keep it.
  Future<void> deleteReport(String reportId) async {
    await _reportsApi.deleteReport(reportId);
    _changed();
  }

  Future<UploadReportResponse> uploadReport({
    required List<int> fileBytes,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    final response = await _reportsApi.uploadReport(
      fileBytes: fileBytes,
      fileName: fileName,
      onProgress: onProgress,
    );
    _changed();
    return response;
  }

  /// Extracted rows (before calculation) or calculated results (after) —
  /// the same endpoint serves both.
  Future<List<BonusResult>> getResults(String reportId) async {
    final results = await _bonusApi.getResults(reportId);
    results.sort((a, b) => a.userName.toLowerCase().compareTo(b.userName.toLowerCase()));
    return results;
  }

  Future<BonusResult> getUserResult(String reportId, String userId) =>
      _bonusApi.getUserResult(reportId, userId);

  /// Saves admin corrections to one extracted row. Only the keys in
  /// [changes] are sent.
  Future<BonusResult> correctRow(
    String reportId,
    String bonusResultId,
    Map<String, dynamic> changes,
  ) async {
    final row = await _reportsApi.correctRow(reportId, bonusResultId, changes);
    _changed();
    return row;
  }

  Future<ValidationSummary> validateReport(String reportId) async {
    final summary = await _reportsApi.validateReport(reportId);
    _changed();
    return summary;
  }

  Future<BonusCalculationSummary> calculateBonus(String reportId) async {
    final summary = await _bonusApi.calculateBonus(reportId);
    _changed();
    return summary;
  }

  // --- Referrals --------------------------------------------------------

  Future<List<ReferralEntry>> listReferrals(String reportId) => _referralsApi.list(reportId);

  Future<ReferralEntry> addReferral(
    String reportId, {
    required String referrerUserId,
    required String referredUserId,
    double? rate,
  }) async {
    final entry = await _referralsApi.add(
      reportId,
      referrerUserId: referrerUserId,
      referredUserId: referredUserId,
      rate: rate,
    );
    _changed();
    return entry;
  }

  Future<void> removeReferral(String reportId, String entryId) async {
    await _referralsApi.remove(reportId, entryId);
    _changed();
  }

  // --- Users ------------------------------------------------------------

  Future<List<UserProfile>> listUsers({String? query}) => _usersApi.list(query: query);

  Future<UserProfile> getUser(String userId) => _usersApi.get(userId);

  Future<UserHistory> getUserHistory(String userId) => _usersApi.history(userId);

  /// Saves the WhatsApp number permanently (an empty string clears it).
  /// Throws an [ApiException] if it is not a valid number or could not be
  /// saved — callers must not show it as saved in that case.
  Future<UserProfile> saveWhatsAppNumber(String userId, String number) async {
    final user = await _usersApi.saveWhatsAppNumber(userId, number);
    _changed(structural: false);
    return user;
  }

  // --- Settings ---------------------------------------------------------

  Future<BonusSettings> getSettings() => _settingsApi.get();

  Future<BonusSettings> saveSettings({
    required double personalRate,
    required double referralRate,
  }) async {
    final settings = await _settingsApi.save(personalRate: personalRate, referralRate: referralRate);
    _changed();
    return settings;
  }

  // --- WhatsApp ---------------------------------------------------------

  /// Records that WhatsApp was opened for this result. Call this only after
  /// the `wa.me` link was actually launched.
  Future<WhatsAppOpenedRecord> recordWhatsAppOpened({
    required String reportId,
    required String bonusResultId,
    required String whatsappNumber,
    required String message,
  }) async {
    final record = await _whatsappApi.recordOpened(
      reportId: reportId,
      bonusResultId: bonusResultId,
      whatsappNumber: whatsappNumber,
      message: message,
    );
    _changed(structural: false);
    return record;
  }
}
