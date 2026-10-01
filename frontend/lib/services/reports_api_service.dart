import '../core/api_client.dart';
import '../models/report_progress.dart';
import '../models/upload_report_response.dart';
import '../models/validation_summary.dart';

/// Talks to the /reports upload + validate endpoints (Steps 3-4 of the
/// backend). One method per endpoint, no business logic — just request
/// shaping and response parsing.
class ReportsApiService {
  ReportsApiService(this._client);

  final ApiClient _client;

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

  /// GET /api/v1/reports/{report_id}/status — the background-processing
  /// progress of an uploaded report.
  Future<ReportProgress> getReportStatus(String reportId) async {
    final json = await _client.get('/reports/$reportId/status');
    return ReportProgress.fromJson(json);
  }

  /// POST /api/v1/reports/{report_id}/validate
  Future<ValidationSummary> validateReport(String reportId) async {
    final json = await _client.post('/reports/$reportId/validate');
    return ValidationSummary.fromJson(json);
  }
}
