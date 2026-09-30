/// Mirrors `BonusResult` (app/schemas/bonus.py) exactly. `bonusAmount` stays
/// nullable end-to-end — the UI must treat null as "not calculated yet",
/// never substitute or compute a value for it.
class BonusResult {
  final String bonusResultId;
  final String reportId;
  final String userId;
  final String userName;
  final String? whatsappNumber;
  final String? level;
  final double casinoPts;
  final double sportPts;
  final double thirdPartyPts;
  final double profitLoss;
  final String? ptype;
  final double? bonusAmount;

  /// 'pending' (not yet calculated), 'calculated', or 'invalid' (row
  /// failed validation and was never calculated). Defaults to 'pending'
  /// if the backend ever omits it, matching the API's own default.
  final String calculationStatus;

  /// Latest WhatsApp send outcome for this user: 'not_sent', 'sent', or
  /// 'failed'. Defaults to 'not_sent', matching the API's own default.
  final String whatsappStatus;

  final String? createdAt;

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
    required this.bonusAmount,
    required this.calculationStatus,
    required this.whatsappStatus,
    required this.createdAt,
  });

  /// Client-side display normalization only (never sent back to the
  /// backend, never changes stored data): if this user has no WhatsApp
  /// number on file at all, the status shown is always "No Number"
  /// regardless of the raw status string, since no message could possibly
  /// have been sent to them. Otherwise the raw status (backend value, or a
  /// same-session send result) is shown as-is.
  String displayWhatsAppStatus(String rawStatus) {
    final hasNumber = whatsappNumber != null && whatsappNumber!.trim().isNotEmpty;
    if (!hasNumber && rawStatus != 'sent' && rawStatus != 'failed') {
      return 'skipped_no_number';
    }
    return rawStatus;
  }

  factory BonusResult.fromJson(Map<String, dynamic> json) {
    return BonusResult(
      bonusResultId: json['bonus_result_id'] as String? ?? '',
      reportId: json['report_id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      userName: json['user_name'] as String? ?? '',
      whatsappNumber: json['whatsapp_number'] as String?,
      level: json['level'] as String?,
      casinoPts: _toDouble(json['casino_pts']),
      sportPts: _toDouble(json['sport_pts']),
      thirdPartyPts: _toDouble(json['third_party_pts']),
      profitLoss: _toDouble(json['profit_loss']),
      ptype: json['ptype'] as String?,
      bonusAmount: json['bonus_amount'] == null ? null : _toDouble(json['bonus_amount']),
      calculationStatus: json['calculation_status'] as String? ?? 'pending',
      whatsappStatus: json['whatsapp_status'] as String? ?? 'not_sent',
      createdAt: json['created_at'] as String?,
    );
  }
}

double _toDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}
