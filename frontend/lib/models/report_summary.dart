import 'bonus_result.dart' show toDoubleOrNull, toInt;

/// Mirrors `ReportSummary` (app/schemas/report.py) — one row of this admin's
/// report history (`GET /api/v1/reports`). Stored in Supabase by the backend,
/// so the same list appears on every device the admin logs in from.
class ReportSummary {
  final String reportId;
  final String fileName;

  /// uploaded | processing | validated | completed | failed
  final String status;
  final DateTime? uploadedAt;
  final DateTime? calculatedAt;
  final int userCount;
  final int payableUserCount;
  final double? totalPayable;

  const ReportSummary({
    required this.reportId,
    required this.fileName,
    required this.status,
    required this.uploadedAt,
    required this.calculatedAt,
    required this.userCount,
    required this.payableUserCount,
    required this.totalPayable,
  });

  bool get isCompleted => status == 'completed';

  factory ReportSummary.fromJson(Map<String, dynamic> json) {
    return ReportSummary(
      reportId: json['report_id'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      uploadedAt: DateTime.tryParse(json['uploaded_at'] as String? ?? '')?.toLocal(),
      calculatedAt: DateTime.tryParse(json['calculated_at'] as String? ?? '')?.toLocal(),
      userCount: toInt(json['user_count']),
      payableUserCount: toInt(json['payable_user_count']),
      totalPayable: toDoubleOrNull(json['total_payable']),
    );
  }
}
