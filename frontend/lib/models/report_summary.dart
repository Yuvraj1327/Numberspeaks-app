import '../core/formatters.dart';
import 'bonus_result.dart' show toDoubleOrNull, toInt;

/// Mirrors `ReportSummary` (app/schemas/report.py) — one row of this admin's
/// report history (`GET /api/v1/reports`). Stored in Supabase by the backend,
/// so the same list appears on every device the admin logs in from.
class ReportSummary {
  final String reportId;
  final String fileName;

  /// uploaded | processing | validated | completed | failed
  final String status;

  /// The week this report covers (YYYY-MM-DD), null for older reports.
  final String? periodStart;
  final String? periodEnd;
  final DateTime? uploadedAt;
  final DateTime? calculatedAt;
  final int userCount;
  final int payableUserCount;
  final double? totalPayable;

  const ReportSummary({
    required this.reportId,
    required this.fileName,
    required this.status,
    this.periodStart,
    this.periodEnd,
    required this.uploadedAt,
    required this.calculatedAt,
    required this.userCount,
    required this.payableUserCount,
    required this.totalPayable,
  });

  bool get isCompleted => status == 'completed';

  /// Headline for lists: the week when known, otherwise the file name.
  String get title =>
      periodStart != null ? periodLabel : (fileName.isNotEmpty ? fileName : 'Report');

  /// e.g. "5–11 Oct 2026", or the file name's upload date for older reports.
  String get periodLabel => Formatters.periodLabel(periodStart, periodEnd);

  factory ReportSummary.fromJson(Map<String, dynamic> json) {
    return ReportSummary(
      reportId: json['report_id'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      periodStart: json['period_start'] as String?,
      periodEnd: json['period_end'] as String?,
      uploadedAt: DateTime.tryParse(json['uploaded_at'] as String? ?? '')?.toLocal(),
      calculatedAt: DateTime.tryParse(json['calculated_at'] as String? ?? '')?.toLocal(),
      userCount: toInt(json['user_count']),
      payableUserCount: toInt(json['payable_user_count']),
      totalPayable: toDoubleOrNull(json['total_payable']),
    );
  }
}
