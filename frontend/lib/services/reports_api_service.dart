import '../core/api_client.dart';
import '../models/bonus_result.dart';
import '../models/report_summary.dart';
import '../models/upload_report_response.dart';
import '../models/validation_summary.dart';

/// Talks to the /reports endpoints: history, upload, review/correction and
/// validation. One method per endpoint, no business logic — just request
/// shaping and response parsing. Which admin's data is returned is decided
/// by the backend from the login token, never by anything sent here.
class ReportsApiService {
  ReportsApiService(this._client);

  final ApiClient _client;

  /// GET /api/v1/reports — this admin's report history, newest first.
  Future<List<ReportSummary>> listReports() async {
    final list = await _client.getList('/reports');
    return list.map((e) => ReportSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// GET /api/v1/reports/{report_id}
  Future<ReportSummary> getReport(String reportId) async {
    final json = await _client.get('/reports/$reportId');
    return ReportSummary.fromJson(json);
  }

  /// POST /api/v1/reports/upload
  Future<UploadReportResponse> uploadReport({
    required List<int> fileBytes,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    final json = await _client.uploadPdf(
      '/reports/upload',
      fileBytes: fileBytes,
      fileName: fileName,
      onProgress: onProgress,
    );
    return UploadReportResponse.fromJson(json);
  }

  /// PATCH /api/v1/reports/{report_id}/rows/{bonus_result_id} — corrects a
  /// misread value. Only the keys present in [changes] are sent/changed.
  Future<BonusResult> correctRow(
    String reportId,
    String bonusResultId,
    Map<String, dynamic> changes,
  ) async {
    final json = await _client.patch('/reports/$reportId/rows/$bonusResultId', body: changes);
    return BonusResult.fromJson(json);
  }

  /// POST /api/v1/reports/{report_id}/validate
  Future<ValidationSummary> validateReport(String reportId) async {
    final json = await _client.post('/reports/$reportId/validate');
    return ValidationSummary.fromJson(json);
  }
}
