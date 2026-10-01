import 'package:flutter/foundation.dart';

import '../core/api_exception.dart';
import '../models/bonus_calculation_summary.dart';
import '../models/bonus_result.dart';
import '../models/report_progress.dart';
import '../models/upload_report_response.dart';
import '../models/validation_summary.dart';
import '../models/whatsapp_send_summary.dart';
import '../services/activity_log_store.dart';
import '../services/bonus_api_service.dart';
import '../services/local_report_store.dart';
import '../services/reports_api_service.dart';
import '../services/whatsapp_api_service.dart';

/// Single point of access for everything report/bonus/WhatsApp related.
/// Screens depend on this, never on the API services directly — this is
/// where the "which backend endpoint does this call" decision lives, and
/// where the local "last report" convenience (see LocalReportStore) and
/// the local activity log (see ActivityLogStore) are layered on top of the
/// real backend calls.
class ReportRepository extends ChangeNotifier {
  ReportRepository({
    required ReportsApiService reportsApi,
    required BonusApiService bonusApi,
    required WhatsAppApiService whatsappApi,
    required LocalReportStore localStore,
    required ActivityLogStore activityLog,
    required String? Function() currentUserId,
  })  : _reportsApi = reportsApi,
        _bonusApi = bonusApi,
        _whatsappApi = whatsappApi,
        _localStore = localStore,
        _activityLog = activityLog,
        _currentUserId = currentUserId;

  final ReportsApiService _reportsApi;
  final BonusApiService _bonusApi;
  final WhatsAppApiService _whatsappApi;
  final LocalReportStore _localStore;
  final ActivityLogStore _activityLog;
  final String? Function() _currentUserId;

  /// Report ids for which a WhatsApp send has completed in this session —
  /// used only to know when to show WhatsApp status alongside results
  /// (see WhatsAppSendSummary, which is never persisted by the backend
  /// in a way this app can query later — see README "known gaps").
  /// Belongs to [_sessionOwner] only; see [_sessionSummaries].
  final Map<String, WhatsAppSendSummary> _sessionWhatsAppSummaries = {};
  String? _sessionOwner;

  /// The in-memory summaries, emptied whenever the signed-in account is not
  /// the one they were recorded for (logout, or a different login), so a
  /// send done by one account is never shown to the next.
  Map<String, WhatsAppSendSummary> get _sessionSummaries {
    final user = _currentUserId();
    if (user != _sessionOwner) {
      _sessionWhatsAppSummaries.clear();
      _sessionOwner = user;
    }
    return _sessionWhatsAppSummaries;
  }

  /// Runs a call that reads one report from the backend. If the backend
  /// says that report does not exist for this account (deleted, or another
  /// account's), it is dropped from the on-device history so the app stops
  /// offering it — a stale id must not be retried forever. The error is
  /// still thrown for the caller to handle. (FastAPI's bare "Not Found" is
  /// a missing route on an older server, not a missing report, so it is
  /// ignored here.)
  Future<T> _forgetReportIfNotFound<T>(String reportId, Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound && e.message != 'Not Found') {
        await _localStore.removeReport(reportId);
      }
      rethrow;
    }
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
    await _localStore.upsertReport(
      reportId: response.reportId,
      fileName: response.fileName,
      status: response.status,
      userCount: response.totalRecords,
    );
    await _activityLog.log(
      type: ActivityType.reportUploaded,
      reportId: response.reportId,
      fileName: response.fileName,
      detail: '${response.totalRecords} record(s) extracted from '
          '${response.pagesProcessed} page(s)',
    );
    notifyListeners();
    return response;
  }

  /// Live backend status of a report being processed in the background.
  Future<ReportProgress> getReportStatus(String reportId) async {
    final progress =
        await _forgetReportIfNotFound(reportId, () => _reportsApi.getReportStatus(reportId));
    // Keep the on-device history in step with what the backend really says,
    // so the Reports/Dashboard cards show the current status.
    await _localStore.upsertReport(
      reportId: reportId,
      status: progress.status,
      userCount: progress.totalRecords > 0 ? progress.totalRecords : null,
    );
    // The Dashboard / Reports / Results tabs reload when told a report has
    // finished, so its results show up without a manual refresh.
    if (progress.isFinal) notifyListeners();
    return progress;
  }

  /// Called once the backend has finished a background run: records the
  /// final figures (from the real results) exactly as [calculateBonus]
  /// does for the manual flow, so history and activity stay consistent.
  Future<void> recordBackgroundRunFinished(
    String reportId, {
    required String status,
    required List<BonusResult> results,
  }) async {
    final bonusEligible = results.where((r) => r.bonusAmount != null).length;
    final totalBonus = results.fold<double>(0, (sum, r) => sum + (r.bonusAmount ?? 0));
    await _localStore.upsertReport(
      reportId: reportId,
      status: status,
      userCount: results.length,
      bonusEligibleCount: bonusEligible,
      totalBonus: totalBonus,
    );
    await _activityLog.log(
      type: ActivityType.bonusCalculated,
      reportId: reportId,
      detail: status == 'completed'
          ? '$bonusEligible bonus(es) calculated'
          : 'Bonus calculation did not complete successfully',
    );
    notifyListeners();
  }

  /// Permanently deletes a report (and its PDF and results) from the
  /// account, then drops it from the on-device list. A report the backend
  /// no longer has counts as already deleted.
  Future<void> deleteReport(String reportId) async {
    try {
      await _reportsApi.deleteReport(reportId);
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.notFound) rethrow;
    }
    await _localStore.removeReport(reportId);
    _sessionWhatsAppSummaries.remove(reportId);
    notifyListeners();
  }

  Future<ValidationSummary> validateReport(String reportId) async {
    final summary = await _reportsApi.validateReport(reportId);
    // Scoped to this specific reportId (not just "whatever was last
    // touched") — matters once more than one report is tracked, e.g.
    // continuing an older report from the Reports tab.
    await _localStore.upsertReport(
      reportId: reportId,
      status: summary.status,
      userCount: summary.totalInputRecords,
    );
    await _activityLog.log(
      type: ActivityType.reportProcessed,
      reportId: reportId,
      detail: summary.status == 'validated'
          ? '${summary.validCount}/${summary.totalInputRecords} row(s) valid'
          : 'Validation did not complete (${summary.invalidCount} invalid row(s))',
    );
    notifyListeners();
    return summary;
  }

  Future<BonusCalculationSummary> calculateBonus(String reportId) async {
    final summary = await _bonusApi.calculateBonus(reportId);
    final bonusEligible = summary.results.where((r) => r.bonusAmount != null).length;
    final totalBonus =
        summary.results.fold<double>(0, (sum, r) => sum + (r.bonusAmount ?? 0));
    await _localStore.upsertReport(
      reportId: reportId,
      status: summary.status,
      userCount: summary.totalInputRecords,
      bonusEligibleCount: bonusEligible,
      totalBonus: totalBonus,
    );
    await _activityLog.log(
      type: ActivityType.bonusCalculated,
      reportId: reportId,
      detail: summary.status == 'completed'
          ? '${summary.calculatedCount} bonus(es) calculated'
          : 'Bonus calculation did not complete successfully',
    );
    notifyListeners();
    return summary;
  }

  Future<List<BonusResult>> getResults(String reportId) {
    return _forgetReportIfNotFound(reportId, () => _bonusApi.getResults(reportId));
  }

  Future<BonusResult> getUserResult(String reportId, String userId) {
    return _bonusApi.getUserResult(reportId, userId);
  }

  Future<WhatsAppSendSummary> sendWhatsApp(String reportId, {bool force = false}) async {
    final summary = await _whatsappApi.sendWhatsAppForReport(reportId, force: force);
    _sessionSummaries[reportId] = summary;
    await _activityLog.log(
      type: ActivityType.whatsappSent,
      reportId: reportId,
      detail: '${summary.sentCount} sent, ${summary.failedCount} failed, '
          '${summary.skippedCount} skipped',
    );
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
    final summary = _sessionSummaries[reportId];
    if (summary == null) return null;
    for (final result in summary.results) {
      if (result.bonusResultId == bonusResultId) return result.status;
    }
    return null;
  }

  WhatsAppSendSummary? sessionWhatsAppSummaryFor(String reportId) => _sessionSummaries[reportId];

  Future<String?> getLastReportId() async {
    final reports = await getRecentReports();
    return reports.isEmpty ? null : reports.first.reportId;
  }

  Future<String?> getLastReportFileName() async {
    final reports = await getRecentReports();
    return reports.isEmpty ? null : reports.first.fileName;
  }

  Future<String?> getLastReportStatus() async {
    final reports = await getRecentReports();
    return reports.isEmpty ? null : reports.first.status;
  }

  /// The signed-in account's reports, newest first — powers the Reports
  /// tab. The backend's list for the account is the source of truth, so
  /// they are all there again after logging out and back in (or on a new
  /// device). The on-device copy ([LocalReportStore]) is refreshed from it
  /// and only used as-is when the list can't be fetched (offline, or an
  /// older server without the endpoint).
  Future<List<LocalReportEntry>> getRecentReports() async {
    try {
      await _localStore.syncWithServer(await _reportsApi.listReports());
    } on ApiException {
      // Fall through to the last known list.
    }
    return _localStore.getRecentReports();
  }

  /// Recent real actions this device has taken (upload/validate/calculate/
  /// send), most recent first — powers the Dashboard's activity feed. See
  /// [ActivityLogStore] for exactly what this does and doesn't store.
  Future<List<ActivityEntry>> getRecentActivity({int limit = 5}) =>
      _activityLog.getRecent(limit: limit);
}
