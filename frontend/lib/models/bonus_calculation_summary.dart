import 'bonus_result.dart';

/// Mirrors `BonusCalculationError` (app/schemas/bonus.py).
class BonusCalculationError {
  final String? bonusResultId;
  final String? userName;
  final List<String> issues;

  const BonusCalculationError({
    required this.bonusResultId,
    required this.userName,
    required this.issues,
  });

  factory BonusCalculationError.fromJson(Map<String, dynamic> json) {
    return BonusCalculationError(
      bonusResultId: json['bonus_result_id'] as String?,
      userName: json['user_name'] as String?,
      issues: (json['issues'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
    );
  }
}

/// Mirrors `BonusCalculationSummary` (app/schemas/bonus.py) — the response of
/// POST /api/v1/reports/{report_id}/calculate-bonus.
class BonusCalculationSummary {
  final String reportId;
  final String status;
  final int totalInputRecords;
  final int calculatedCount;
  final int failedCount;
  final List<BonusResult> results;
  final List<BonusCalculationError> errors;

  const BonusCalculationSummary({
    required this.reportId,
    required this.status,
    required this.totalInputRecords,
    required this.calculatedCount,
    required this.failedCount,
    required this.results,
    required this.errors,
  });

  factory BonusCalculationSummary.fromJson(Map<String, dynamic> json) {
    return BonusCalculationSummary(
      reportId: json['report_id'] as String? ?? '',
      status: json['status'] as String? ?? '',
      totalInputRecords: json['total_input_records'] as int? ?? 0,
      calculatedCount: json['calculated_count'] as int? ?? 0,
      failedCount: json['failed_count'] as int? ?? 0,
      results: (json['results'] as List<dynamic>? ?? [])
          .map((e) => BonusResult.fromJson(e as Map<String, dynamic>))
          .toList(),
      errors: (json['errors'] as List<dynamic>? ?? [])
          .map((e) => BonusCalculationError.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
