import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/api_client.dart';
import 'package:numberspeaks_app/core/app_theme.dart';
import 'package:numberspeaks_app/repositories/report_repository.dart';
import 'package:numberspeaks_app/screens/reports_screen.dart';
import 'package:numberspeaks_app/services/bonus_api_service.dart';
import 'package:numberspeaks_app/services/referrals_api_service.dart';
import 'package:numberspeaks_app/services/reports_api_service.dart';
import 'package:numberspeaks_app/services/settings_api_service.dart';
import 'package:numberspeaks_app/services/users_api_service.dart';
import 'package:numberspeaks_app/services/whatsapp_api_service.dart';
import 'package:provider/provider.dart';

// Report deletion was retired in the "Complete Bonus Management" update (the
// backend has no DELETE /reports endpoint and the Reports tab has no delete
// button). This file now covers the Reports tab's current behaviour: the
// history comes from the backend, shows no delete control, and a failed load
// can be retried.
class _FakeBackend implements HttpClientAdapter {
  final reports = <Map<String, dynamic>>[
    {
      'report_id': 'r1',
      'file_name': 'bonus.pdf',
      'status': 'completed',
      'user_count': 2,
      'uploaded_at': '2026-10-02T10:00:00+00:00',
      'calculated_at': '2026-10-02T10:00:05+00:00',
    },
  ];
  bool failing = false;
  final methods = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? r, Future<void>? c) async {
    methods.add(o.method);
    if (failing) {
      return ResponseBody.fromString(
        jsonEncode({'detail': 'Something went wrong.'}),
        500,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    return ResponseBody.fromString(jsonEncode(reports), 200,
        headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeBackend backend;
  late ReportRepository repo;

  setUp(() {
    dotenv.testLoad(fileInput: '');
    backend = _FakeBackend();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = backend);
    repo = ReportRepository(
      reportsApi: ReportsApiService(api),
      bonusApi: BonusApiService(api),
      referralsApi: ReferralsApiService(api),
      usersApi: UsersApiService(api),
      settingsApi: SettingsApiService(api),
      whatsappApi: WhatsAppApiService(api),
    );
  });

  Future<void> pumpTab(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<ReportRepository>.value(
      value: repo,
      child: MaterialApp(theme: AppTheme.light, home: const Scaffold(body: ReportsTab())),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the Reports tab lists the backend reports', (tester) async {
    await pumpTab(tester);
    expect(find.text('bonus.pdf'), findsOneWidget);
  });

  testWidgets('reports cannot be deleted from the Reports tab', (tester) async {
    await pumpTab(tester);
    expect(find.byTooltip('Delete report'), findsNothing);
    expect(backend.methods, everyElement('GET'));
  });

  testWidgets('a failed load shows an error and "Try again" recovers', (tester) async {
    backend.failing = true;
    await pumpTab(tester);
    expect(find.text('bonus.pdf'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);

    backend.failing = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('bonus.pdf'), findsOneWidget);
  });
}
