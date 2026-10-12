import 'bonus_result.dart' show toDouble, toDoubleOrNull, toInt;

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

  /// 'report' (the referred user's profit/loss from the PDF) or 'manual'.
  final String amountSource;
  final String? note;
  final String? periodStart;
  final String? periodEnd;

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
    this.amountSource = 'report',
    this.note,
    this.periodStart,
    this.periodEnd,
  });

  bool get isManual => amountSource == 'manual';

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
      amountSource: json['amount_source'] as String? ?? 'report',
      note: json['note'] as String?,
      periodStart: json['period_start'] as String?,
      periodEnd: json['period_end'] as String?,
    );
  }
}

/// Mirrors `Referrer` (app/schemas/referral.py): saved details of a user who
/// refers others, with how many users and what total adjustment they brought.
class Referrer {
  final String referrerId;
  final String userId;
  final String? userName;
  final String? displayName;
  final String? notes;

  /// Fraction (0.10 = 10%); null means "use the global referral rate".
  final double? defaultRate;
  final bool isActive;
  final int referredCount;
  final double totalAdjustment;

  const Referrer({
    required this.referrerId,
    required this.userId,
    required this.userName,
    required this.displayName,
    required this.notes,
    required this.defaultRate,
    required this.isActive,
    required this.referredCount,
    required this.totalAdjustment,
  });

  String get title => (displayName != null && displayName!.isNotEmpty) ? displayName! : (userName ?? userId);

  factory Referrer.fromJson(Map<String, dynamic> json) {
    return Referrer(
      referrerId: json['referrer_id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      userName: json['user_name'] as String?,
      displayName: json['display_name'] as String?,
      notes: json['notes'] as String?,
      defaultRate: toDoubleOrNull(json['default_rate']),
      isActive: json['is_active'] as bool? ?? true,
      referredCount: toInt(json['referred_count']),
      totalAdjustment: toDouble(json['total_adjustment']),
    );
  }
}
