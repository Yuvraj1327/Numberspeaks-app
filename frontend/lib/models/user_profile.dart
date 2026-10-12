import 'bonus_result.dart' show toDouble, toDoubleOrNull;

/// Mirrors `UserProfile` (app/schemas/users.py): a casino user (a bonus
/// recipient — they never log in), with the WhatsApp number the admin saved
/// and the balance currently carried forward for them.
class UserProfile {
  final String userId;
  final String name;
  final String? level;
  final String? whatsappNumber;

  /// Latest carried-forward balance (negative = owed against future
  /// bonuses), or null if no bonus has ever been calculated for them.
  final double? carryForwardBalance;
  final String? createdAt;

  const UserProfile({
    required this.userId,
    required this.name,
    required this.level,
    required this.whatsappNumber,
    required this.carryForwardBalance,
    required this.createdAt,
  });

  bool get hasWhatsAppNumber => whatsappNumber != null && whatsappNumber!.trim().isNotEmpty;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      userId: json['user_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      level: json['level'] as String?,
      whatsappNumber: json['whatsapp_number'] as String?,
      carryForwardBalance: toDoubleOrNull(json['carry_forward_balance']),
      createdAt: json['created_at'] as String?,
    );
  }
}

/// Mirrors `HistoryEntry` (app/schemas/users.py): one saved calculation of
/// one user in one report, with its full breakdown.
class HistoryEntry {
  final String historyId;
  final String runId;
  final String reportId;
  final String? reportFileName;
  final DateTime? calculatedAt;
  final double profitLoss;
  final double personalRate;
  final double personalAdjustment;
  final double referralAdjustment;
  final double previousBalance;
  final double finalBalance;
  final double payableBonus;
  final double carryForwardBalance;

  const HistoryEntry({
    required this.historyId,
    required this.runId,
    required this.reportId,
    required this.reportFileName,
    required this.calculatedAt,
    required this.profitLoss,
    required this.personalRate,
    required this.personalAdjustment,
    required this.referralAdjustment,
    required this.previousBalance,
    required this.finalBalance,
    required this.payableBonus,
    required this.carryForwardBalance,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      historyId: json['history_id'] as String? ?? '',
      runId: json['run_id'] as String? ?? '',
      reportId: json['report_id'] as String? ?? '',
      reportFileName: json['report_file_name'] as String?,
      calculatedAt: DateTime.tryParse(json['calculated_at'] as String? ?? '')?.toLocal(),
      profitLoss: toDouble(json['profit_loss']),
      personalRate: toDouble(json['personal_rate']),
      personalAdjustment: toDouble(json['personal_adjustment']),
      referralAdjustment: toDouble(json['referral_adjustment']),
      previousBalance: toDouble(json['previous_balance']),
      finalBalance: toDouble(json['final_balance']),
      payableBonus: toDouble(json['payable_bonus']),
      carryForwardBalance: toDouble(json['carry_forward_balance']),
    );
  }
}

/// Mirrors `UserHistory` (app/schemas/users.py).
class UserHistory {
  final UserProfile user;
  final List<HistoryEntry> history;

  const UserHistory({required this.user, required this.history});

  factory UserHistory.fromJson(Map<String, dynamic> json) {
    return UserHistory(
      user: UserProfile.fromJson(json['user'] as Map<String, dynamic>? ?? const {}),
      history: (json['history'] as List<dynamic>? ?? [])
          .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
