/// Message template and number helpers for the WhatsApp send flow. The
/// message is only *built* here; it is sent by the backend after the admin
/// confirms (see lib/widgets/whatsapp_message_dialog.dart).
///
/// Pure functions only (no Flutter imports), so they can be unit-tested
/// without a device — see test/whatsapp_link_test.dart.
class WhatsAppLink {
  WhatsAppLink._();

  /// The default message. `{User ID}` and `{Bonus Amount}` are replaced; the
  /// admin can edit the whole text before confirming the send.
  static const String defaultTemplate =
      "Hi {User ID}, you've got ₹{Bonus Amount} bonus. Please enjoy your game!";

  /// The number as digits only, country code first.
  static String digitsOnly(String number) => number.replaceAll(RegExp(r'[^0-9]'), '');

  /// The country code the backend adds to a bare 10-digit number when sending
  /// (backend setting DEFAULT_COUNTRY_CODE). Used only to SHOW where a message
  /// will go; the backend is the one that applies it.
  static const String defaultCountryCode = '91';

  /// The number WhatsApp will actually be given: country code first, no "+".
  /// Mirrors backend `to_international`.
  static String international(String number, {String countryCode = defaultCountryCode}) {
    final text = number.trim();
    var digits = digitsOnly(text);
    if (countryCode.isEmpty || text.startsWith('+')) return digits;
    if (digits.length == 11 && digits.startsWith('0')) digits = digits.substring(1);
    return digits.length == 10 ? '$countryCode$digits' : digits;
  }

  /// The same range the backend accepts (7–15 digits).
  static bool isUsableNumber(String number) {
    final digits = digitsOnly(number);
    return digits.length >= 7 && digits.length <= 15;
  }

  /// The payable bonus as it appears in the message, e.g. `30.00`. Always
  /// the amount actually owed (never a negative adjustment) — the caller
  /// only builds a message for a user whose payable bonus is above zero.
  static String formatBonusAmount(double payableBonus) => payableBonus.toStringAsFixed(2);

  static String defaultMessage({required String userId, required double payableBonus}) {
    return defaultTemplate
        .replaceAll('{User ID}', userId)
        .replaceAll('{Bonus Amount}', formatBonusAmount(payableBonus));
  }

  /// Every placeholder a template may use, with what it stands for.
  static const Map<String, String> placeholders = {
    '{User ID}': 'the user\'s User ID',
    '{Name}': 'the user\'s name',
    '{Bonus Amount}': 'final payable bonus',
    '{Personal Bonus}': 'personal adjustment',
    '{Referral Bonus}': 'referral adjustment',
    '{Carried Balance}': 'balance carried from the previous week',
    '{Week}': 'the week, e.g. 5–11 Oct 2026',
  };

  /// Fills a template. Unknown `{...}` text is left untouched; amounts are
  /// plain two-decimal numbers (adjustments keep their sign).
  static String render(
    String template, {
    required String userId,
    required String name,
    required double payableBonus,
    double personalBonus = 0,
    double referralBonus = 0,
    double carriedBalance = 0,
    String week = '',
  }) {
    final values = <String, String>{
      '{User ID}': userId,
      '{Name}': name,
      '{Bonus Amount}': formatBonusAmount(payableBonus),
      '{Personal Bonus}': personalBonus.toStringAsFixed(2),
      '{Referral Bonus}': referralBonus.toStringAsFixed(2),
      '{Carried Balance}': carriedBalance.toStringAsFixed(2),
      '{Week}': week,
    };
    var out = template;
    values.forEach((key, value) => out = out.replaceAll(key, value));
    return out;
  }
}
