import 'extracted_record.dart';

/// Mirrors `InvalidRecord` (app/schemas/validation.py).
class InvalidRecord {
  final String rowReference;
  final Map<String, String?> raw;
  final List<String> issues;

  const InvalidRecord({
    required this.rowReference,
    required this.raw,
    required this.issues,
  });

  factory InvalidRecord.fromJson(Map<String, dynamic> json) {
    final rawJson = json['raw'] as Map<String, dynamic>? ?? {};
    return InvalidRecord(
      rowReference: json['row_reference'] as String? ?? '',
      raw: rawJson.map((key, value) => MapEntry(key, value?.toString())),
      issues: (json['issues'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
    );
  }
}

/// Mirrors `ValidationSummary` (app/schemas/validation.py) — the response of
/// POST /api/v1/reports/{report_id}/validate.
class ValidationSummary {
  final String reportId;
  final String status;
  final int totalInputRecords;
  final int validCount;
  final int invalidCount;
  final List<ExtractedRecord> validRecords;
  final List<InvalidRecord> invalidRecords;

  const ValidationSummary({
    required this.reportId,
    required this.status,
    required this.totalInputRecords,
    required this.validCount,
    required this.invalidCount,
    required this.validRecords,
    required this.invalidRecords,
  });

  factory ValidationSummary.fromJson(Map<String, dynamic> json) {
    return ValidationSummary(
      reportId: json['report_id'] as String? ?? '',
      status: json['status'] as String? ?? '',
      totalInputRecords: json['total_input_records'] as int? ?? 0,
      validCount: json['valid_count'] as int? ?? 0,
      invalidCount: json['invalid_count'] as int? ?? 0,
      validRecords: (json['valid_records'] as List<dynamic>? ?? [])
          .map((e) => ExtractedRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      invalidRecords: (json['invalid_records'] as List<dynamic>? ?? [])
          .map((e) => InvalidRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
