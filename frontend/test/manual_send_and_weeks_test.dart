import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/whatsapp_link.dart';
import 'package:numberspeaks_app/models/bonus_result.dart';
import 'package:numberspeaks_app/models/user_profile.dart';
import 'package:numberspeaks_app/widgets/whatsapp_manual_dialog.dart';

BonusResult result(String name, String number, double payable) => BonusResult.fromJson({
      'bonus_result_id': 'b-$name',
      'report_id': 'r1',
      'user_id': 'u-$name',
      'user_name': name,
      'whatsapp_number': number,
      'calculation_status': 'calculated',
      'payable_bonus': payable,
      'bonus_amount': payable,
    });

void main() {
  group('wa.me link', () {
    test('uses country code, digits only, and encodes the message', () {
      final uri = WhatsAppLink.waMeUri('98765 43210', 'Hi A&B, ₹30.00 bonus');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/919876543210');
      expect(uri.queryParameters['text'], 'Hi A&B, ₹30.00 bonus');
      expect(uri.toString(), contains('text=Hi%20A%26B'));
    });

    test('a number saved with + is not re-prefixed', () {
      expect(WhatsAppLink.waMeUri('+44 7700 900123', 'x').path, '/447700900123');
    });
  });

  group('message content', () {
    test('default message has user id, amount and week dates', () {
      final m = WhatsAppLink.defaultMessage(
          userId: 'Rahul01', payableBonus: 30, week: '5–11 Oct 2026');
      expect(m, contains('Rahul01'));
      expect(m, contains('₹30.00'));
      expect(m, contains('5–11 Oct 2026'));
    });

    test('a custom template without {Week} still states the week', () {
      final m = WhatsAppLink.render('Hi {User ID} ₹{Bonus Amount}',
          userId: 'A', name: 'A', payableBonus: 5, week: '5–11 Oct 2026');
      expect(m, contains('5–11 Oct 2026'));
    });
  });

  test('weekly ledger parses; newest is current', () {
    final w = UserWeeks.fromJson({
      'user': {'user_id': 'u', 'name': 'Amy'},
      'weeks': [
        {
          'report_id': 'r2', 'bonus_result_id': 'b2', 'period_start': '2026-10-12',
          'period_end': '2026-10-18', 'is_current': true, 'profit_loss': -2000,
          'personal_adjustment': 60, 'referral_adjustment': 0, 'previous_balance': 0,
          'final_balance': 60, 'payable_bonus': 60, 'carry_forward_balance': 0,
        },
      ],
    });
    expect(w.current!.weekLabel, '12–18 Oct 2026');
    expect(w.current!.payableBonus, 60);
    expect(w.current!.sendStatus, 'pending');
  });

  group('Manual send dialog', () {
    Future<List<Uri>> pump(WidgetTester tester, List<BonusResult> targets,
        {bool openOk = true}) async {
      final opened = <Uri>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ManualSendDialog(
            targets: targets,
            template: WhatsAppLink.defaultTemplate,
            week: '5–11 Oct 2026',
            title: 'Manual Send',
            opener: (uri) async {
              opened.add(uri);
              return openOk;
            },
          ),
        ),
      ));
      return opened;
    }

    testWidgets('opens the chat with the EDITED message, one recipient at a time',
        (tester) async {
      final opened = await pump(tester, [
        result('Amy', '9876543210', 30),
        result('Bob', '9123456780', 45),
      ]);
      expect(find.text('Manual Send (1 of 2)'), findsOneWidget);
      expect(find.textContaining('5–11 Oct 2026'), findsWidgets);

      await tester.enterText(find.byKey(const Key('manual-message')), 'Custom for Amy ₹30.00');
      await tester.tap(find.byKey(const Key('manual-open')));
      await tester.pump();
      expect(opened.single.path, '/919876543210');
      expect(opened.single.queryParameters['text'], 'Custom for Amy ₹30.00');
      expect(find.textContaining('cannot tell'), findsOneWidget);

      await tester.tap(find.byKey(const Key('manual-skip'))); // Next
      await tester.pump();
      expect(find.text('Manual Send (2 of 2)'), findsOneWidget);
      // the second message is the default for Bob, not Amy's edit
      expect(find.textContaining('Bob'), findsWidgets);
      expect(find.textContaining('Custom for Amy'), findsNothing);

      await tester.tap(find.byKey(const Key('manual-open')));
      await tester.pump();
      expect(opened.length, 2);
      expect(opened.last.path, '/919123456780');
      await tester.tap(find.byKey(const Key('manual-skip'))); // Finish
      await tester.pump();
      expect(find.textContaining('opened for 2 users; 0 skipped'), findsOneWidget);
      expect(find.textContaining('not delivery'), findsOneWidget);
    });

    testWidgets('skipping is counted and nothing is opened', (tester) async {
      final opened = await pump(tester, [result('Amy', '9876543210', 30), result('Bob', '9123456780', 45)]);
      await tester.tap(find.byKey(const Key('manual-skip')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('manual-skip')));
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.textContaining('opened for 0 users; 2 skipped'), findsOneWidget);
    });

    testWidgets('a failed launch is reported honestly, not counted', (tester) async {
      await pump(tester, [result('Amy', '9876543210', 30)], openOk: false);
      await tester.tap(find.byKey(const Key('manual-open')));
      await tester.pump();
      expect(find.text('Could not open WhatsApp on this device.'), findsOneWidget);
      expect(find.textContaining('cannot tell'), findsNothing);
    });

    testWidgets('an invalid number is refused before opening', (tester) async {
      final opened = await pump(tester, [result('Amy', '123', 30)]);
      await tester.tap(find.byKey(const Key('manual-open')));
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.textContaining('does not look valid'), findsOneWidget);
    });
  });
}
