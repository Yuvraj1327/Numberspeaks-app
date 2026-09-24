import 'package:intl/intl.dart';

/// Shared number/date formatting so every screen displays bonus amounts and
/// points the same way.
class Formatters {
  Formatters._();

  static final NumberFormat _number = NumberFormat.decimalPattern();
  static final NumberFormat _amount = NumberFormat.currency(symbol: '', decimalDigits: 2);

  static String points(double value) => _number.format(value);

  /// Formats a bonus/currency amount. The symbol is intentionally omitted
  /// since the backend does not specify a currency — showing one would be
  /// an invented detail.
  static String amount(double value) => _amount.format(value);

  static String? amountOrNull(double? value) => value == null ? null : amount(value);
}
