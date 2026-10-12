import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/formatters.dart';

void main() {
  group('Formatters', () {
    test('signed shows an explicit sign', () {
      expect(Formatters.signed(30), '+30.00');
      expect(Formatters.signed(-300), '-300.00');
      expect(Formatters.signed(0), '0.00');
    });

    test('rupees formats positive and negative amounts', () {
      expect(Formatters.rupees(1250), '₹1,250.00');
      expect(Formatters.rupees(-300), '-₹300.00');
    });

    test('percent shows stored fractions as percentages', () {
      expect(Formatters.percent(0.03), '3%');
      expect(Formatters.percent(0.10), '10%');
      expect(Formatters.percent(0.075), '7.5%');
    });
  });
}
