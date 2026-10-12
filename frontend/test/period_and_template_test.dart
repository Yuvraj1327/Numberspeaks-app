import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/formatters.dart';
import 'package:numberspeaks_app/core/whatsapp_link.dart';
import 'package:numberspeaks_app/models/referral_entry.dart';
import 'package:numberspeaks_app/models/report_summary.dart';

void main() {
  group('periodLabel', () {
    test('same month', () => expect(Formatters.periodLabel('2026-10-05', '2026-10-11'), '5–11 Oct 2026'));
    test('across months', () => expect(Formatters.periodLabel('2026-09-28', '2026-10-04'), '28 Sep – 4 Oct 2026'));
    test('across years', () => expect(Formatters.periodLabel('2026-12-28', '2027-01-03'), '28 Dec 2026 – 3 Jan 2027'));
    test('missing period', () => expect(Formatters.periodLabel(null, null), '—'));
  });

  test('report title prefers the week, falls back to file name', () {
    final withPeriod = ReportSummary.fromJson({
      'report_id': 'r', 'file_name': 'a.pdf', 'status': 'completed',
      'period_start': '2026-10-05', 'period_end': '2026-10-11',
    });
    final legacy = ReportSummary.fromJson({'report_id': 'r2', 'file_name': 'old.pdf', 'status': 'completed'});
    expect(withPeriod.title, '5–11 Oct 2026');
    expect(legacy.title, 'old.pdf');
  });

  test('WhatsApp template placeholders are all filled', () {
    final text = WhatsAppLink.render(
      '{User ID}|{Name}|{Bonus Amount}|{Personal Bonus}|{Referral Bonus}|{Carried Balance}|{Week}|{Other}',
      userId: 'u1', name: 'Amy', payableBonus: 270, personalBonus: 300, referralBonus: -30,
      carriedBalance: 0, week: '5–11 Oct 2026',
    );
    expect(text, 'u1|Amy|270.00|300.00|-30.00|0.00|5–11 Oct 2026|{Other}');
  });

  test('wa.me link is prefilled and url-encoded', () {
    final uri = WhatsAppLink.build(number: '+91 98765 43210', message: 'Hi Amy, ₹300 bonus');
    expect(uri.toString(), startsWith('https://wa.me/919876543210?text='));
    expect(Uri.decodeComponent(uri.query.substring(5)), 'Hi Amy, ₹300 bonus');
  });

  test('referral entry and referrer parse the new fields', () {
    final e = ReferralEntry.fromJson({
      'entry_id': 'e', 'report_id': 'r', 'referrer_user_id': 'a', 'referred_user_id': 'b', 'rate': 0.1,
      'amount': -5000, 'adjustment': 500, 'amount_source': 'manual', 'note': 'n',
      'period_start': '2026-10-05', 'period_end': '2026-10-11',
    });
    expect(e.isManual, isTrue);
    expect(e.periodStart, '2026-10-05');
    final r = Referrer.fromJson({'referrer_id': 'x', 'user_id': 'a', 'default_rate': 0.05, 'referred_count': 2, 'total_adjustment': 12.5});
    expect(r.defaultRate, 0.05);
    expect(r.referredCount, 2);
  });
}
