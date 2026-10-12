import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/whatsapp_link.dart';

void main() {
  group('WhatsAppLink', () {
    test('default message uses the user id and the payable bonus', () {
      final message = WhatsAppLink.defaultMessage(userId: 'Rahul01', payableBonus: 30);
      expect(message, "Hi Rahul01, you've got ₹30.00 bonus. Please enjoy your game!");
    });

    test('bonus amount keeps two decimals', () {
      expect(WhatsAppLink.formatBonusAmount(1250.5), '1250.50');
      expect(WhatsAppLink.formatBonusAmount(300), '300.00');
    });

    test('digitsOnly strips +, spaces, dashes and brackets', () {
      expect(WhatsAppLink.digitsOnly('+91 98765-43210'), '919876543210');
      expect(WhatsAppLink.digitsOnly('(022) 2345 6789'), '02223456789');
    });

    test('isUsableNumber accepts 7-15 digits only', () {
      expect(WhatsAppLink.isUsableNumber('919876543210'), isTrue);
      expect(WhatsAppLink.isUsableNumber('+91 98765 43210'), isTrue);
      expect(WhatsAppLink.isUsableNumber('12345'), isFalse);
      expect(WhatsAppLink.isUsableNumber(''), isFalse);
      expect(WhatsAppLink.isUsableNumber('1' * 16), isFalse);
    });

    test('build makes a prefilled wa.me link with the saved number', () {
      const message = "Hi Rahul01, you've got ₹30.00 bonus. Please enjoy your game!";
      final uri = WhatsAppLink.build(number: '+91 98765-43210', message: message);

      expect(uri.scheme, 'https');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/919876543210');
      // The text round-trips exactly, including the rupee sign and apostrophe.
      expect(uri.queryParameters['text'], message);
      // Spaces are %20 (not +), the rupee sign is UTF-8 percent-encoded.
      expect(uri.toString(), contains('%20'));
      expect(uri.toString(), contains('%E2%82%B9'));
      expect(uri.toString(), isNot(contains('+')));
    });

    test('an edited message is what ends up in the link', () {
      final uri = WhatsAppLink.build(number: '919876543210', message: 'Edited by the admin & sent');
      expect(uri.queryParameters['text'], 'Edited by the admin & sent');
    });
  });
}
