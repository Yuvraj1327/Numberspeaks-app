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

    test('international adds the country code to a bare 10-digit number (mirrors the backend)', () {
      expect(WhatsAppLink.international('7354182970'), '917354182970');
      expect(WhatsAppLink.international('07354182970'), '917354182970');
      expect(WhatsAppLink.international('+917354182970'), '917354182970');
      expect(WhatsAppLink.international('917354182970'), '917354182970');
      expect(WhatsAppLink.international('+1 415 555 0123'), '14155550123');
      expect(WhatsAppLink.international('7354182970', countryCode: ''), '7354182970');
    });
  });
}
