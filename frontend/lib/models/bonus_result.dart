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

  /// Reports are cumulative. `weeklyChange` = `currentReportTotal` -
  /// `previousReportTotal` is this week's actual win (+) / loss (-), and
  /// `bonusBasis` is the amount the bonus % was applied to. All null for a
  /// week calculated before weekly differences existed.
  final double? previousReportTotal;
  final double? currentReportTotal;
  final double? weeklyChange;
  final double? bonusBasis;
  final double? personalRateUsed;
  final double? personalAdjustment;
  final double? referralAdjustment;
  final double? previousBalance;
  final double? finalBalance;
  final double? payableBonus;
  final double? carryForwardBalance;
  final String? calculatedAt;

  /// Latest WhatsApp send attempt: 'pending' (never attempted), 'sending',
  /// 'queued' (accepted into No1API's queue; NOT yet confirmed sent/delivered),
  /// 'sent' (the provider confirmed), 'failed' (rejected; can be retried) or
  /// 'unknown' (may or may not have been delivered; check WhatsApp first).
  final String sendStatus;
  final String? sendError;
  final String? sentAt;

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
    required this.sendStatus,
    required this.sendError,
    required this.sentAt,
    required this.createdAt,
    this.previousReportTotal,
    this.currentReportTotal,
    this.weeklyChange,
    this.bonusBasis,
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

  bool get isSent => sendStatus == 'sent';
  bool get isSending => sendStatus == 'sending';
  bool get isQueued => sendStatus == 'queued';

  /// The provider has accepted the message but has not confirmed delivery.
  bool get isPendingDelivery => isSending || isQueued;

  /// The provider has the message (queued or sent). Bulk runs skip these; a
  /// deliberate single Resend is still allowed.
  bool get isAccepted => isQueued || isSent;
  bool get isSendFailed => sendStatus == 'failed';
  bool get isSendUnknown => sendStatus == 'unknown';

  /// A previous attempt exists that did not succeed, so the button says "Retry send".
  bool get canRetrySend => isSendFailed || isSendUnknown || isSending;

  /// A copy with the fields the app changes locally after a successful save
  /// (a new WhatsApp number, or a new send status). Everything else
  /// is carried over unchanged. [clearWhatsAppNumber] sets the number to null
  /// (a null [whatsappNumber] argument means "leave as is").
  BonusResult copyWith({
    String? whatsappNumber,
    bool clearWhatsAppNumber = false,
    String? sendStatus,
    String? sendError,
    bool clearSendError = false,
    String? sentAt,
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
      previousReportTotal: previousReportTotal,
      currentReportTotal: currentReportTotal,
      weeklyChange: weeklyChange,
      bonusBasis: bonusBasis,
      personalRateUsed: personalRateUsed,
      personalAdjustment: personalAdjustment,
      referralAdjustment: referralAdjustment,
      previousBalance: previousBalance,
      finalBalance: finalBalance,
      payableBonus: payableBonus,
      carryForwardBalance: carryForwardBalance,
      calculatedAt: calculatedAt,
      sendStatus: sendStatus ?? this.sendStatus,
      sendError: clearSendError ? null : (sendError ?? this.sendError),
      sentAt: sentAt ?? this.sentAt,
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
      previousReportTotal: toDoubleOrNull(json['previous_report_total']),
      currentReportTotal: toDoubleOrNull(json['current_report_total']),
      weeklyChange: toDoubleOrNull(json['weekly_change']),
      bonusBasis: toDoubleOrNull(json['bonus_basis']),
      personalRateUsed: toDoubleOrNull(json['personal_rate_used']),
      personalAdjustment: toDoubleOrNull(json['personal_adjustment']),
      referralAdjustment: toDoubleOrNull(json['referral_adjustment']),
      previousBalance: toDoubleOrNull(json['previous_balance']),
      finalBalance: toDoubleOrNull(json['final_balance']),
      payableBonus: toDoubleOrNull(json['payable_bonus']) ?? toDoubleOrNull(json['bonus_amount']),
      carryForwardBalance: toDoubleOrNull(json['carry_forward_balance']),
      calculatedAt: json['calculated_at'] as String?,
      sendStatus: json['send_status'] as String? ?? 'pending',
      sendError: json['send_error'] as String?,
      sentAt: json['sent_at'] as String?,
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
