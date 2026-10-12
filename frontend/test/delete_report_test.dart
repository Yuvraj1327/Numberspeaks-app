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

// Reports tab: the history comes from the backend, a report can be deleted
// after confirming (and only then), failures keep the report, and a failed
// load can be retried.
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
  int deleteStatus = 204;
  final methods = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? r, Future<void>? c) async {
    methods.add(o.method);
    if (o.method == 'DELETE') {
      if (deleteStatus == 204) reports.removeWhere((r) => o.path.endsWith('/${r['report_id']}'));
      return ResponseBody.fromString(
        deleteStatus == 204 ? '' : jsonEncode({'detail': 'A newer report has already been calculated.'}),
        deleteStatus,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
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

  testWidgets('cancelling the confirmation deletes nothing', (tester) async {
    await pumpTab(tester);
    await tester.tap(find.byTooltip('Delete report'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this report?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('bonus.pdf'), findsOneWidget);
    expect(backend.methods, everyElement('GET'));
  });

  testWidgets('confirming deletes the report and removes it immediately', (tester) async {
    await pumpTab(tester);
    await tester.tap(find.byTooltip('Delete report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(backend.methods, contains('DELETE'));
    expect(find.text('bonus.pdf'), findsNothing);
    expect(find.text('Report deleted.'), findsOneWidget);
  });

  testWidgets('a refused deletion keeps the report and says why', (tester) async {
    backend.deleteStatus = 409;
    await pumpTab(tester);
    await tester.tap(find.byTooltip('Delete report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('bonus.pdf'), findsOneWidget);
    expect(find.textContaining('A newer report has already been calculated'), findsOneWidget);
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
