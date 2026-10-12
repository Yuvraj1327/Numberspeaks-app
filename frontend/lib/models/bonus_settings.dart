import 'bonus_result.dart' show toDouble;

/// Mirrors `BonusSettings` (app/schemas/referral.py). Rates are fractions
/// (0.03 = 3%); the UI shows and edits them as percentages.
class BonusSettings {
  final double personalRate;
  final double referralRate;

  /// The admin's WhatsApp message template, or null for the built-in one.
  final String? whatsappTemplate;

  const BonusSettings({required this.personalRate, required this.referralRate, this.whatsappTemplate});

  double get personalPercent => personalRate * 100;
  double get referralPercent => referralRate * 100;

  factory BonusSettings.fromJson(Map<String, dynamic> json) {
    return BonusSettings(
      personalRate: toDouble(json['personal_rate']),
      referralRate: toDouble(json['referral_rate']),
      whatsappTemplate: json['whatsapp_template'] as String?,
    );
  }
}
