import 'bonus_result.dart' show toDouble, toDoubleOrNull;

/// Mirrors `ReferralEntry` (app/schemas/referral.py): the referrer, the
/// referred user, the rate, and — once the report has been calculated — the
/// referred user's profit/loss and the resulting adjustment.
class ReferralEntry {
  final String entryId;
  final String reportId;
  final String referrerUserId;
  final String? referrerName;
  final String referredUserId;
  final String? referredName;

  /// A fraction, e.g. 0.10 for 10%.
  final double rate;

  /// The referred user's profit/loss used for the calculation (null until
  /// the report is calculated).
  final double? amount;

  /// + if the referred user lost, - if they won (null until calculated).
  final double? adjustment;
  final String? calculatedAt;
  final String? createdAt;

  const ReferralEntry({
    required this.entryId,
    required this.reportId,
    required this.referrerUserId,
    required this.referrerName,
    required this.referredUserId,
    required this.referredName,
    required this.rate,
    required this.amount,
    required this.adjustment,
    required this.calculatedAt,
    required this.createdAt,
  });

  bool get isCalculated => adjustment != null;

  factory ReferralEntry.fromJson(Map<String, dynamic> json) {
    return ReferralEntry(
      entryId: json['entry_id'] as String? ?? '',
      reportId: json['report_id'] as String? ?? '',
      referrerUserId: json['referrer_user_id'] as String? ?? '',
      referrerName: json['referrer_name'] as String?,
      referredUserId: json['referred_user_id'] as String? ?? '',
      referredName: json['referred_name'] as String?,
      rate: toDouble(json['rate']),
      amount: toDoubleOrNull(json['amount']),
      adjustment: toDoubleOrNull(json['adjustment']),
      calculatedAt: json['calculated_at'] as String?,
      createdAt: json['created_at'] as String?,
    );
  }
}
