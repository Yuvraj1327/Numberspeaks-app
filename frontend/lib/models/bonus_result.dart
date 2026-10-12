/// Mirrors `BonusResult` (app/schemas/bonus.py) exactly.
///
/// The calculation fields are all null until the admin has confirmed the
/// calculation — the UI treats null as "not calculated yet" and never
/// substitutes or computes a value for it.
///
/// `payableBonus` is the amount actually owed (never negative). It is the
/// same number the backend also returns as `bonus_amount`.
class BonusResult {
  final String bonusResultId;
  final String reportId;
  final String userId;

  /// The casino user's User ID / Name, as it appears in the report.
  final String userName;
  final String? whatsappNumber;
  final String? level;
  final double casinoPts;
  final double sportPts;
  final double thirdPartyPts;
  final double profitLoss;
  final String? ptype;

  /// 'pending' (not yet calculated), 'calculated', or 'invalid' (row failed
  /// validation and was not calculated).
  final String calculationStatus;

  // --- Calculation breakdown (null until calculated) -------------------
  final double? personalRateUsed;
  final double? personalAdjustment;
  final double? referralAdjustment;
  final double? previousBalance;
  final double? finalBalance;
  final double? payableBonus;
  final double? carryForwardBalance;
  final String? calculatedAt;

  /// 'not_sent' or 'initiated'. 'initiated' only means the admin opened
  /// WhatsApp with the message pre-filled — it is never "sent"/"delivered".
  final String whatsappStatus;
  final String? whatsappInitiatedAt;
  final int whatsappInitiatedCount;

  final String? createdAt;

  /// Who referred this user in this period, and how many users they referred.
  final String? referrerUserId;
  final String? referrerName;
  final int referredCount;

  const BonusResult({
    required this.bonusResultId,
    required this.reportId,
    required this.userId,
    required this.userName,
    required this.whatsappNumber,
    required this.level,
    required this.casinoPts,
    required this.sportPts,
    required this.thirdPartyPts,
    required this.profitLoss,
    required this.ptype,
    required this.calculationStatus,
    required this.personalRateUsed,
    required this.personalAdjustment,
    required this.referralAdjustment,
    required this.previousBalance,
    required this.finalBalance,
    required this.payableBonus,
    required this.carryForwardBalance,
    required this.calculatedAt,
    required this.whatsappStatus,
    required this.whatsappInitiatedAt,
    required this.whatsappInitiatedCount,
    required this.createdAt,
    this.referrerUserId,
    this.referrerName,
    this.referredCount = 0,
  });

  bool get hasReferrer => referrerName != null && referrerName!.isNotEmpty;

  bool get isCalculated => calculationStatus == 'calculated';

  /// The bonus actually owed (0 when nothing is owed or not calculated yet).
  double get payable => payableBonus ?? 0;

  bool get hasPayableBonus => isCalculated && payable > 0;

  bool get hasWhatsAppNumber => whatsappNumber != null && whatsappNumber!.trim().isNotEmpty;

  bool get whatsappInitiated => whatsappStatus == 'initiated' || whatsappInitiatedCount > 0;

  /// A copy with the fields the app changes locally after a successful save
  /// (a new WhatsApp number, or a WhatsApp "opened" record). Everything else
  /// is carried over unchanged. [clearWhatsAppNumber] sets the number to null
  /// (a null [whatsappNumber] argument means "leave as is").
  BonusResult copyWith({
    String? whatsappNumber,
    bool clearWhatsAppNumber = false,
    String? whatsappStatus,
    String? whatsappInitiatedAt,
    int? whatsappInitiatedCount,
  }) {
    return BonusResult(
      bonusResultId: bonusResultId,
      reportId: reportId,
      userId: userId,
      userName: userName,
      whatsappNumber: clearWhatsAppNumber ? null : (whatsappNumber ?? this.whatsappNumber),
      level: level,
      casinoPts: casinoPts,
      sportPts: sportPts,
      thirdPartyPts: thirdPartyPts,
      profitLoss: profitLoss,
      ptype: ptype,
      calculationStatus: calculationStatus,
      personalRateUsed: personalRateUsed,
      personalAdjustment: personalAdjustment,
      referralAdjustment: referralAdjustment,
      previousBalance: previousBalance,
      finalBalance: finalBalance,
      payableBonus: payableBonus,
      carryForwardBalance: carryForwardBalance,
      calculatedAt: calculatedAt,
      whatsappStatus: whatsappStatus ?? this.whatsappStatus,
      whatsappInitiatedAt: whatsappInitiatedAt ?? this.whatsappInitiatedAt,
      whatsappInitiatedCount: whatsappInitiatedCount ?? this.whatsappInitiatedCount,
      createdAt: createdAt,
      referrerUserId: referrerUserId,
      referrerName: referrerName,
      referredCount: referredCount,
    );
  }

  factory BonusResult.fromJson(Map<String, dynamic> json) {
    return BonusResult(
      bonusResultId: json['bonus_result_id'] as String? ?? '',
      reportId: json['report_id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      userName: json['user_name'] as String? ?? '',
      whatsappNumber: json['whatsapp_number'] as String?,
      level: json['level'] as String?,
      casinoPts: toDouble(json['casino_pts']),
      sportPts: toDouble(json['sport_pts']),
      thirdPartyPts: toDouble(json['third_party_pts']),
      profitLoss: toDouble(json['profit_loss']),
      ptype: json['ptype'] as String?,
      calculationStatus: json['calculation_status'] as String? ?? 'pending',
      personalRateUsed: toDoubleOrNull(json['personal_rate_used']),
      personalAdjustment: toDoubleOrNull(json['personal_adjustment']),
      referralAdjustment: toDoubleOrNull(json['referral_adjustment']),
      previousBalance: toDoubleOrNull(json['previous_balance']),
      finalBalance: toDoubleOrNull(json['final_balance']),
      payableBonus: toDoubleOrNull(json['payable_bonus']) ?? toDoubleOrNull(json['bonus_amount']),
      carryForwardBalance: toDoubleOrNull(json['carry_forward_balance']),
      calculatedAt: json['calculated_at'] as String?,
      whatsappStatus: json['whatsapp_status'] as String? ?? 'not_sent',
      whatsappInitiatedAt: json['whatsapp_initiated_at'] as String?,
      whatsappInitiatedCount: toInt(json['whatsapp_initiated_count']),
      createdAt: json['created_at'] as String?,
      referrerUserId: json['referrer_user_id'] as String?,
      referrerName: json['referrer_name'] as String?,
      referredCount: toInt(json['referred_count']),
    );
  }
}

/// JSON numbers may arrive as int or double (or, defensively, a string).
double toDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

double? toDoubleOrNull(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int toInt(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}
