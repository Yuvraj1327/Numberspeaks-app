/// Builds the `wa.me` link the admin's own device opens. Nothing is sent by
/// this app or the backend: WhatsApp (the app, or WhatsApp Web in a browser)
/// opens with the chat and the message already typed, and the admin presses
/// Send inside WhatsApp themselves.
///
/// Pure functions only (no Flutter imports), so they can be unit-tested
/// without a device — see test/whatsapp_link_test.dart.
class WhatsAppLink {
  WhatsAppLink._();

  /// The default message. `{User ID}` and `{Bonus Amount}` are replaced; the
  /// admin can edit the whole text before opening WhatsApp.
  static const String defaultTemplate =
      "Hi {User ID}, you've got ₹{Bonus Amount} bonus. Please enjoy your game!";

  /// wa.me wants the number as digits only, country code first, with no
  /// "+", spaces, dashes or leading zeros.
  static String digitsOnly(String number) => number.replaceAll(RegExp(r'[^0-9]'), '');

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

  /// `https://wa.me/<digits>?text=<url-encoded message>`. Spaces become
  /// `%20` (not `+`), which WhatsApp reads as a space on both mobile and web.
  static Uri build({required String number, required String message}) {
    return Uri.parse('https://wa.me/${digitsOnly(number)}?text=${Uri.encodeComponent(message)}');
  }
}
