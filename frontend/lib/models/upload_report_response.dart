import 'extracted_record.dart';

/// Mirrors `UploadReportResponse` (app/schemas/report.py) — the response of
/// POST /api/v1/reports/upload.
class UploadReportResponse {
  final String reportId;
  final String fileName;
  final String status;
  final int pagesProcessed;
  final int totalRecords;
  final List<ExtractedRecord> records;
  final List<String> warnings;

  const UploadReportResponse({
    required this.reportId,
    required this.fileName,
    required this.status,
    required this.pagesProcessed,
    required this.totalRecords,
    required this.records,
    required this.warnings,
  });

  factory UploadReportResponse.fromJson(Map<String, dynamic> json) {
    return UploadReportResponse(
      reportId: json['report_id'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      pagesProcessed: json['pages_processed'] as int? ?? 0,
      totalRecords: json['total_records'] as int? ?? 0,
      records: (json['records'] as List<dynamic>? ?? [])
          .map((e) => ExtractedRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      warnings: (json['warnings'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}
