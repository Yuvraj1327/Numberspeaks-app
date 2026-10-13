import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/models/bonus_result.dart';
import 'package:numberspeaks_app/models/referral_entry.dart';
import 'package:numberspeaks_app/models/report_summary.dart';
import 'package:numberspeaks_app/models/user_profile.dart';

Map<String, dynamic> _row({Map<String, dynamic> overrides = const {}}) {
  return {
    'bonus_result_id': 'b1',
    'report_id': 'r1',
    'user_id': 'u1',
    'user_name': 'Rahul01',
    'whatsapp_number': null,
    'level': 'Gold',
    'casino_pts': 10,
    'sport_pts': 5.5,
    'third_party_pts': 1,
    'profit_loss': -1000,
    'ptype': 'User',
    'bonus_amount': 30,
    'calculation_status': 'calculated',
    'personal_rate_used': 0.03,
    'personal_adjustment': 30,
    'referral_adjustment': 0,
    'previous_balance': 0,
    'final_balance': 30,
    'payable_bonus': 30,
    'carry_forward_balance': 0,
    'send_status': 'pending',
    ...overrides,
  };
}

void main() {
  group('BonusResult', () {
    test('parses a calculated row with its full breakdown', () {
      final r = BonusResult.fromJson(_row());
      expect(r.userName, 'Rahul01');
      expect(r.profitLoss, -1000);
      expect(r.sportPts, 5.5);
      expect(r.isCalculated, isTrue);
      expect(r.personalAdjustment, 30);
      expect(r.referralAdjustment, 0);
      expect(r.finalBalance, 30);
      expect(r.payable, 30);
      expect(r.hasPayableBonus, isTrue);
      expect(r.hasWhatsAppNumber, isFalse);
      expect(r.sendStatus, 'pending');
      expect(r.isSent, isFalse);
    });

    test('a negative balance has nothing payable and is carried forward', () {
      final r = BonusResult.fromJson(_row(overrides: {
        'profit_loss': 10000,
        'personal_adjustment': -300,
        'final_balance': -300,
        'payable_bonus': 0,
        'bonus_amount': 0,
        'carry_forward_balance': -300,
      }));
      expect(r.hasPayableBonus, isFalse);
      expect(r.payable, 0);
      expect(r.carryForwardBalance, -300);
    });

    test('a row that has not been calculated has no figures', () {
      final r = BonusResult.fromJson({
        'bonus_result_id': 'b2',
        'report_id': 'r1',
        'user_id': 'u2',
        'user_name': 'Priya',
        'casino_pts': 0,
        'sport_pts': 0,
        'third_party_pts': 0,
        'profit_loss': 500,
        'calculation_status': 'pending',
      });
      expect(r.isCalculated, isFalse);
      expect(r.payableBonus, isNull);
      expect(r.personalAdjustment, isNull);
      expect(r.payable, 0);
      expect(r.hasPayableBonus, isFalse);
    });

    test('send status, error and time come from the backend', () {
      final r = BonusResult.fromJson(_row(overrides: {
        'send_status': 'failed',
        'send_error': 'provider said no',
      }));
      expect(r.isSendFailed, isTrue);
      expect(r.isSent, isFalse);
      expect(r.sendError, 'provider said no');

      final sent = BonusResult.fromJson(_row(overrides: {
        'send_status': 'sent',
        'sent_at': '2026-10-12T10:00:00+00:00',
      }));
      expect(sent.isSent, isTrue);
      expect(sent.sentAt, '2026-10-12T10:00:00+00:00');
      expect(sent.copyWith(sendStatus: 'failed', sendError: 'x').sendError, 'x');
      expect(sent.copyWith(clearSendError: true).sendError, isNull);
    });

    test('copyWith sets and clears the WhatsApp number', () {
      final r = BonusResult.fromJson(_row());
      final withNumber = r.copyWith(whatsappNumber: '919876543210');
      expect(withNumber.whatsappNumber, '919876543210');
      expect(withNumber.hasWhatsAppNumber, isTrue);
      expect(withNumber.payable, 30); // nothing else changed

      final cleared = withNumber.copyWith(clearWhatsAppNumber: true);
      expect(cleared.whatsappNumber, isNull);
      expect(cleared.hasWhatsAppNumber, isFalse);
    });
  });

  test('ReportSummary parses totals', () {
    final s = ReportSummary.fromJson({
      'report_id': 'r1',
      'file_name': 'week.pdf',
      'status': 'completed',
      'uploaded_at': '2026-10-12T10:00:00+00:00',
      'user_count': 3,
      'payable_user_count': 2,
      'total_payable': 330,
    });
    expect(s.isCompleted, isTrue);
    expect(s.userCount, 3);
    expect(s.payableUserCount, 2);
    expect(s.totalPayable, 330);
  });

  test('ReferralEntry is not calculated until it has an adjustment', () {
    final pending = ReferralEntry.fromJson({
      'entry_id': 'e1',
      'report_id': 'r1',
      'referrer_user_id': 'u1',
      'referred_user_id': 'u2',
      'rate': 0.1,
    });
    expect(pending.isCalculated, isFalse);
    expect(pending.rate, 0.1);

    final done = ReferralEntry.fromJson({
      'entry_id': 'e1',
      'report_id': 'r1',
      'referrer_user_id': 'u1',
      'referred_user_id': 'u2',
      'rate': 0.1,
      'amount': -10000,
      'adjustment': 1000,
    });
    expect(done.isCalculated, isTrue);
    expect(done.adjustment, 1000);
  });

  test('UserHistory parses entries newest first as sent', () {
    final h = UserHistory.fromJson({
      'user': {'user_id': 'u1', 'name': 'Sam', 'carry_forward_balance': -150},
      'history': [
        {
          'history_id': 'h2',
          'run_id': 'x',
          'report_id': 'r2',
          'calculated_at': '2026-10-12T10:00:00+00:00',
          'profit_loss': -5000,
          'personal_rate': 0.03,
          'personal_adjustment': 150,
          'referral_adjustment': 0,
          'previous_balance': -300,
          'final_balance': -150,
          'payable_bonus': 0,
          'carry_forward_balance': -150,
        },
      ],
    });
    expect(h.user.name, 'Sam');
    expect(h.user.carryForwardBalance, -150);
    expect(h.history.single.previousBalance, -300);
    expect(h.history.single.payableBonus, 0);
  });
}
