import 'package:intl/intl.dart';

/// Shared number/date formatting so every screen displays amounts and
/// points the same way.
class Formatters {
  Formatters._();

  static final NumberFormat _number = NumberFormat.decimalPattern();
  static final NumberFormat _amount = NumberFormat.currency(symbol: '', decimalDigits: 2);

  static String points(double value) => _number.format(value);

  /// A plain amount with two decimals and thousands separators, no symbol.
  static String amount(double value) => _amount.format(value);

  static String? amountOrNull(double? value) => value == null ? null : amount(value);

  /// An amount in rupees, e.g. `₹1,250.00` or `-₹300.00`.
  static String rupees(double value) {
    final sign = value < 0 ? '-' : '';
    return '$sign₹${_amount.format(value.abs())}';
  }

  /// An adjustment with an explicit sign, e.g. `+30.00` / `-300.00` / `0.00`.
  static String signed(double value) {
    final text = _amount.format(value.abs());
    if (value > 0) return '+$text';
    if (value < 0) return '-$text';
    return text;
  }

  /// A rate stored as a fraction, shown as a percentage: 0.03 -> `3%`,
  /// 0.075 -> `7.5%`.
  static String percent(double fraction) {
    final p = fraction * 100;
    if ((p - p.roundToDouble()).abs() < 1e-9) return '${p.round()}%';
    var text = p.toStringAsFixed(2);
    while (text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    return '$text%';
  }

  /// YYYY-MM-DD, the format the backend expects for a period.
  static String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  /// A week as `5–11 Oct 2026` (or `28 Sep – 4 Oct 2026` / across years).
  /// Falls back to a dash for reports imported before periods existed.
  static String periodLabel(String? start, String? end) {
    final s = start == null ? null : DateTime.tryParse(start);
    final e = end == null ? null : DateTime.tryParse(end);
    if (s == null || e == null) return '—';
    if (s.year != e.year) {
      return '${DateFormat('d MMM y').format(s)} – ${DateFormat('d MMM y').format(e)}';
    }
    if (s.month != e.month) {
      return '${DateFormat('d MMM').format(s)} – ${DateFormat('d MMM y').format(e)}';
    }
    if (s.day == e.day) return DateFormat('d MMM y').format(e);
    return '${s.day}–${DateFormat('d MMM y').format(e)}';
  }

  static String dateTime(DateTime? value) {
    if (value == null) return '—';
    return DateFormat.yMMMd().add_jm().format(value);
  }
}
