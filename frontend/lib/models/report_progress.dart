/// Mirrors `ReportStatusResponse` (app/schemas/report.py) — the response of
/// GET /api/v1/reports/{report_id}/status, which is what the client polls
/// while the backend processes an uploaded report in the background.
///
/// `status` runs: uploaded -> processing -> validating -> calculating ->
/// completed | failed.
class ReportProgress {
  final String reportId;
  final String fileName;
  final String status;
  final bool isFinal;
  final int pagesProcessed;
  final int totalRecords;
  final int calculatedCount;
  final int failedCount;
  final String? errorMessage;
  final List<String> warnings;

  const ReportProgress({
    required this.reportId,
    required this.fileName,
    required this.status,
    required this.isFinal,
    required this.pagesProcessed,
    required this.totalRecords,
    required this.calculatedCount,
    required this.failedCount,
    required this.errorMessage,
    required this.warnings,
  });

  factory ReportProgress.fromJson(Map<String, dynamic> json) {
    return ReportProgress(
      reportId: json['report_id'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      isFinal: json['is_final'] as bool? ?? false,
      pagesProcessed: (json['pages_processed'] as num?)?.toInt() ?? 0,
      totalRecords: (json['total_records'] as num?)?.toInt() ?? 0,
      calculatedCount: (json['calculated_count'] as num?)?.toInt() ?? 0,
      failedCount: (json['failed_count'] as num?)?.toInt() ?? 0,
      errorMessage: json['error_message'] as String?,
      warnings: (json['warnings'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
    );
  }
}
