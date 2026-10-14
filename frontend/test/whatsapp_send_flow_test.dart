import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/api_client.dart';
import 'package:numberspeaks_app/core/app_theme.dart';
import 'package:numberspeaks_app/models/bonus_result.dart';
import 'package:numberspeaks_app/repositories/report_repository.dart';
import 'package:numberspeaks_app/services/bonus_api_service.dart';
import 'package:numberspeaks_app/services/referrals_api_service.dart';
import 'package:numberspeaks_app/services/reports_api_service.dart';
import 'package:numberspeaks_app/services/settings_api_service.dart';
import 'package:numberspeaks_app/services/users_api_service.dart';
import 'package:numberspeaks_app/services/whatsapp_api_service.dart';
import 'package:numberspeaks_app/widgets/whatsapp_bulk_dialog.dart';
import 'package:numberspeaks_app/widgets/whatsapp_message_dialog.dart';
import 'package:provider/provider.dart';

/// Records every request so the tests can prove nothing is sent before the
/// admin confirms.
class _Backend implements HttpClientAdapter {
  final List<String> calls = [];
  bool testPassed = false;
  int bulkPolls = 0;

  /// What the mocked provider reports for a single send.
  String sendStatus = 'sent';
  String? sendError;
  bool sendTimesOut = false;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    final path = o.uri.path;
    calls.add('${o.method} $path');
    Object body = {'detail': 'Not Found'};
    var status = 404;
    if (path.endsWith('/settings')) {
      status = 200;
      body = {'personal_rate': 0.03, 'referral_rate': 0.1, 'whatsapp_template': null};
    } else if (path.endsWith('/whatsapp/test-status')) {
      status = 200;
      body = {'tested': testPassed, 'provider_available': true};
    } else if (path.endsWith('/whatsapp/test-send')) {
      status = 200;
      testPassed = true;
      body = {'status': 'sent', 'error': null};
    } else if (o.method == 'POST' && path.endsWith('/whatsapp-bulk')) {
      status = 200;
      body = _progress('running', sent: 0);
    } else if (path.contains('/whatsapp-bulk/')) {
      status = 200;
      bulkPolls++;
      body = _progress('completed', sent: 1, failed: 1);
    } else if (o.method == 'POST' && path.endsWith('/whatsapp-send')) {
      if (sendTimesOut) {
        throw DioException(requestOptions: o, type: DioExceptionType.receiveTimeout);
      }
      status = 200;
      body = {
        'bonus_result_id': 'b1',
        'send_status': sendStatus,
        'send_error': sendError,
        'sent_at': sendStatus == 'sent' ? '2026-10-12T10:00:00+00:00' : null,
      };
    } else if (RegExp(r'/reports/[^/]+$').hasMatch(path)) {
      status = 200;
      body = {
        'report_id': 'r1',
        'file_name': 'r1.pdf',
        'status': 'completed',
        'total_records': 2,
        'calculated_count': 2,
        'failed_count': 0,
        'uploaded_at': '2026-10-02T10:00:00+00:00',
        'updated_at': '2026-10-02T10:00:05+00:00',
      };
    }
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }

  Map<String, dynamic> _progress(String st, {int sent = 0, int failed = 0}) => {
        'batch_id': 'batch1',
        'status': st,
        'total_selected': 2,
        'queued': 2,
        'sent': 0,
        'provider_queued': sent,
        'failed': failed,
        'unknown': 0,
        'pending': 2 - sent - failed,
        'skipped': <Object>[],
        'items': failed == 0
            ? <Object>[]
            : [
                {
                  'bonus_result_id': 'b2',
                  'user_name': 'Bo',
                  'send_status': 'failed',
                  'send_error': 'bad number'
                }
              ],
      };

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _rawResult(String id, String name) => {
      'bonus_result_id': id,
      'report_id': 'r1',
      'user_id': 'u-$id',
      'user_name': name,
      'whatsapp_number': '91900000000$id'.substring(0, 12),
      'casino_pts': 0,
      'sport_pts': 0,
      'third_party_pts': 0,
      'profit_loss': -1000,
      'bonus_amount': 30,
      'payable_bonus': 30,
      'calculation_status': 'calculated',
      'send_status': 'pending',
    };

BonusResult _result(String id, String name) => BonusResult.fromJson(_rawResult(id, name));

void main() {
  late _Backend backend;
  late ReportRepository repo;

  setUp(() {
    dotenv.testLoad(fileInput: '');
    backend = _Backend();
    final api = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = backend);
    repo = ReportRepository(
      reportsApi: ReportsApiService(api),
      bonusApi: BonusApiService(api),
      referralsApi: ReferralsApiService(api),
      usersApi: UsersApiService(api),
      settingsApi: SettingsApiService(api),
      whatsappApi: WhatsAppApiService(api),
    );
  });

  Widget host(Widget Function(BuildContext) button) =>
      ChangeNotifierProvider<ReportRepository>.value(
        value: repo,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: Builder(builder: (c) => Center(child: button(c)))),
        ),
      );

  void bigSurface(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
  }

  testWidgets('single send: nothing is posted until Confirm & Send is pressed', (tester) async {
    bigSurface(tester);
    await tester.pumpWidget(host((c) => ElevatedButton(
          onPressed: () => showWhatsAppMessageDialog(c, result: _result('1', 'Amy')),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm WhatsApp message'), findsOneWidget);
    expect(find.textContaining('Amy'), findsWidgets);
    expect(backend.calls.where((c) => c.contains('whatsapp-send')), isEmpty);

    await tester.tap(find.text('Confirm & Send'));
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c == 'POST /api/v1/reports/r1/results/1/whatsapp-send'),
        hasLength(1));
    expect(find.textContaining('Success'), findsOneWidget);
    // Resend stays available: each intentional send is a separate message.
    expect(find.text('Resend'), findsOneWidget);
  });

  Future<void> openDialog(WidgetTester tester, {BonusResult? result}) async {
    bigSurface(tester);
    await tester.pumpWidget(host((c) => ElevatedButton(
          onPressed: () =>
              showWhatsAppMessageDialog(c, result: result ?? _result('1', 'Amy')),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  int sendCalls() => backend.calls.where((c) => c.endsWith('/whatsapp-send')).length;

  testWidgets('queued is pending: loading text, never Success, and Resend stays available',
      (tester) async {
    backend.sendStatus = 'queued';
    await openDialog(tester);
    await tester.tap(find.text('Confirm & Send'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // the spinner never settles
    }
    expect(find.text('Sending WhatsApp message...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.textContaining('Success'), findsNothing);
    expect(find.textContaining('Queued with No1API'), findsNothing);
    expect(find.text('Resend'), findsOneWidget);
    expect(sendCalls(), 1); // no automatic retry
  });

  testWidgets('failed shows the reason in red', (tester) async {
    backend.sendStatus = 'failed';
    backend.sendError = 'This number could not receive the message.';
    await openDialog(tester);
    await tester.tap(find.text('Confirm & Send'));
    await tester.pumpAndSettle();
    final failed = tester.widget<Text>(find.textContaining('Failed: This number could not'));
    expect(failed.style?.color, AppTheme.danger);
    expect(find.textContaining('Success'), findsNothing);
  });

  testWidgets('a timeout is not Success or Failed, and is not retried automatically',
      (tester) async {
    backend.sendTimesOut = true;
    await openDialog(tester);
    await tester.tap(find.text('Confirm & Send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('may or may not have been'), findsOneWidget);
    expect(find.textContaining('Success'), findsNothing);
    expect(find.textContaining('Failed:'), findsNothing);
    expect(sendCalls(), 1);
    expect(find.text('Retry send'), findsOneWidget); // manual retry still offered
  });

  testWidgets('the same number can be sent several different messages', (tester) async {
    await openDialog(tester);
    await tester.enterText(find.byType(TextField), 'first message');
    await tester.tap(find.text('Confirm & Send'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'second message');
    await tester.tap(find.text('Resend'));
    await tester.pumpAndSettle();
    expect(sendCalls(), 2);
  });

  testWidgets('bulk: locked until test passed and messages reviewed; then shows progress + summary',
      (tester) async {
    bigSurface(tester);
    await tester.pumpWidget(host((c) => ElevatedButton(
          onPressed: () => showWhatsAppBulkDialog(
            c,
            reportId: 'r1',
            title: 'Send All Eligible',
            targets: [_result('1', 'Amy'), _result('2', 'Bo')],
            skipped: const [BulkSkipPreview('Cy', 'No WhatsApp number saved.')],
          ),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('2 recipient(s) will be messaged.'), findsOneWidget);
    expect(find.textContaining('1 skipped'), findsOneWidget);

    Finder confirmFinder() => find.ancestor(
        of: find.text('Confirm & Send 2'), matching: find.bySubtype<ButtonStyleButton>());
    ButtonStyleButton confirm() => tester.widget<ButtonStyleButton>(confirmFinder());
    expect(confirm().onPressed, isNull); // test not passed, not reviewed

    // Review the messages: still locked because no test message was accepted.
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pump();
    expect(confirm().onPressed, isNull);

    // Test message to an authorized number.
    await tester.enterText(find.byType(TextField), '919000099999');
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.tap(find.text('Send test message'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('POST /api/v1/whatsapp/test-send'));
    expect(confirm().onPressed, isNotNull);
    expect(backend.calls.where((c) => c.endsWith('/whatsapp-bulk')), isEmpty); // not started yet

    await tester.tap(confirmFinder());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3)); // one poll
    await tester.pump();

    expect(backend.calls.where((c) => c == 'POST /api/v1/reports/r1/whatsapp-bulk'), hasLength(1));
    expect(find.textContaining('Finished: 2 of 2 processed'), findsOneWidget);
    expect(find.text('Queued: 1'), findsOneWidget);
    expect(find.text('Failed: 1'), findsOneWidget);
    expect(find.textContaining('bad number'), findsOneWidget);
  });

  testWidgets('an Unknown message needs an explicit "I checked" before it can be re-sent',
      (tester) async {
    bigSurface(tester);
    final unknown = BonusResult.fromJson({
      ..._rawResult('1', 'Amy'),
      'send_status': 'unknown',
      'send_error': 'No1API answered HTTP 200: {} (no message id found)',
    });
    await tester.pumpWidget(host((c) => ElevatedButton(
          onPressed: () => showWhatsAppMessageDialog(c, result: unknown),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    Finder send() =>
        find.ancestor(of: find.text('Retry send'), matching: find.bySubtype<ButtonStyleButton>());
    expect(find.textContaining('may already have been'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(send()).onPressed, isNull);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(send()).onPressed, isNotNull);
    await tester.tap(send());
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c.endsWith('/whatsapp-send')), hasLength(1));
  });

  test('Unknown is shown as Unknown, never as Pending', () {
    final r = BonusResult.fromJson({..._rawResult('1', 'Amy'), 'send_status': 'unknown'});
    expect(r.isSendUnknown, isTrue);
    expect(r.canRetrySend, isTrue);
    expect(r.isSent, isFalse);
  });

  test('Queued is its own status: accepted but not "sent", and it can be resent', () {
    final r = BonusResult.fromJson({..._rawResult('1', 'Amy'), 'send_status': 'queued'});
    expect(r.isQueued, isTrue);
    expect(r.isSent, isFalse);
    expect(r.isAccepted, isTrue);
    expect(r.canRetrySend, isFalse);
    expect(r.isPendingDelivery, isTrue);
  });
}
