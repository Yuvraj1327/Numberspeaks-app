import 'package:flutter/foundation.dart';

import '../models/bonus_calculation_summary.dart';
import '../models/bonus_result.dart';
import '../models/upload_report_response.dart';
import '../models/validation_summary.dart';
import '../models/whatsapp_send_summary.dart';
import '../services/bonus_api_service.dart';
import '../services/local_report_store.dart';
import '../services/reports_api_service.dart';
import '../services/whatsapp_api_service.dart';

/// Single point of access for everything report/bonus/WhatsApp related.
/// Screens depend on this, never on the API services directly — this is
/// where the "which backend endpoint does this call" decision lives, and
/// where the local "last report" convenience (see LocalReportStore) is
/// layered on top of the real backend calls.
class ReportRepository extends ChangeNotifier {
  ReportRepository({
    required ReportsApiService reportsApi,
    required BonusApiService bonusApi,
    required WhatsAppApiService whatsappApi,
    required LocalReportStore localStore,
  })  : _reportsApi = reportsApi,
        _bonusApi = bonusApi,
        _whatsappApi = whatsappApi,
        _localStore = localStore;

  final ReportsApiService _reportsApi;
  final BonusApiService _bonusApi;
  final WhatsAppApiService _whatsappApi;
  final LocalReportStore _localStore;

  /// Report ids for which a WhatsApp send has completed in this session —
  /// used only to know when to show WhatsApp status alongside results
  /// (see WhatsAppSendSummary, which is never persisted by the backend
  /// in a way this app can query later — see README "known gaps").
  final Map<String, WhatsAppSendSummary> _sessionWhatsAppSummaries = {};

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
    await _localStore.saveLastReport(reportId: response.reportId, fileName: response.fileName);
    await _localStore.saveLastReportStatus(response.status);
    notifyListeners();
    return response;
  }

  Future<ValidationSummary> validateReport(String reportId) async {
    final summary = await _reportsApi.validateReport(reportId);
    await _localStore.saveLastReportStatus(summary.status);
    return summary;
  }

  Future<BonusCalculationSummary> calculateBonus(String reportId) async {
    final summary = await _bonusApi.calculateBonus(reportId);
    await _localStore.saveLastReportStatus(summary.status);
    return summary;
  }

  Future<List<BonusResult>> getResults(String reportId) {
    return _bonusApi.getResults(reportId);
  }

  Future<BonusResult> getUserResult(String reportId, String userId) {
    return _bonusApi.getUserResult(reportId, userId);
  }

  Future<WhatsAppSendSummary> sendWhatsApp(String reportId, {bool force = false}) async {
    final summary = await _whatsappApi.sendWhatsAppForReport(reportId, force: force);
    _sessionWhatsAppSummaries[reportId] = summary;
    notifyListeners();
    return summary;
  }

  /// Status for one user's WhatsApp message from a send that happened
  /// during this app session for this report, if any. Null means "no send
  /// happened this session" — callers should fall back to the durable
  /// `BonusResult.whatsappStatus` from GET /results in that case (this
  /// session-only value is kept because it can be more specific right
  /// after a send, e.g. distinguishing "skipped_already_sent" from a
  /// plain "not_sent").
  String? sessionWhatsAppStatusFor(String reportId, String bonusResultId) {
    final summary = _sessionWhatsAppSummaries[reportId];
    if (summary == null) return null;
    for (final result in summary.results) {
      if (result.bonusResultId == bonusResultId) return result.status;
    }
    return null;
  }

  WhatsAppSendSummary? sessionWhatsAppSummaryFor(String reportId) => _sessionWhatsAppSummaries[reportId];

  Future<String?> getLastReportId() => _localStore.getLastReportId();

  Future<String?> getLastReportFileName() => _localStore.getLastReportFileName();

  Future<String?> getLastReportStatus() => _localStore.getLastReportStatus();

  /// Clears the on-device "last report" convenience only — never touches
  /// the backend. Used by the Settings screen's "Clear local data" action.
  Future<void> clearLocalData() async {
    await _localStore.clear();
    notifyListeners();
  }
}
