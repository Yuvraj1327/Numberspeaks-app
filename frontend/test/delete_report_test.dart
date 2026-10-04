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
import 'package:numberspeaks_app/services/activity_log_store.dart';
import 'package:numberspeaks_app/services/bonus_api_service.dart';
import 'package:numberspeaks_app/services/local_report_store.dart';
import 'package:numberspeaks_app/services/reports_api_service.dart';
import 'package:numberspeaks_app/services/supabase_report_store.dart';
import 'package:numberspeaks_app/services/whatsapp_api_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBackend implements HttpClientAdapter {
  final reports = <Map<String, dynamic>>[
    {
      'report_id': 'r1',
      'file_name': 'bonus.pdf',
      'status': 'completed',
      'total_records': 2,
      'calculated_count': 2,
      'failed_count': 0,
      'uploaded_at': '2026-10-02T10:00:00+00:00',
      'updated_at': '2026-10-02T10:00:05+00:00',
    },
  ];
  int deleteStatus = 204;
  final deleted = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? r, Future<void>? c) async {
    if (o.method == 'DELETE') {
      if (deleteStatus == 204) {
        deleted.add(o.uri.pathSegments.last);
        reports.removeWhere((e) => e['report_id'] == o.uri.pathSegments.last);
        return ResponseBody.fromString('', 204);
      }
      return ResponseBody.fromString(
        jsonEncode({'detail': 'This report is still being processed. Wait for it to finish, then delete it.'}),
        deleteStatus,
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
    SharedPreferences.setMockInitialValues({});
    backend = _FakeBackend();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = backend);
    repo = ReportRepository(
      reportsApi: ReportsApiService(api),
      bonusApi: BonusApiService(api),
      whatsappApi: WhatsAppApiService(api),
      localStore: LocalReportStore(userId: () => 'user-a'),
      activityLog: ActivityLogStore(userId: () => 'user-a'),
      currentUserId: () => 'user-a',
      supabaseStore: SupabaseReportStore(),
    );
  });

  Future<void> pumpTab(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<ReportRepository>.value(
      value: repo,
      child: MaterialApp(theme: AppTheme.light, home: const Scaffold(body: ReportsTab())),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('cancelling the confirmation keeps the report', (tester) async {
    await pumpTab(tester);
    await tester.tap(find.byTooltip('Delete report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(backend.deleted, isEmpty);
    expect(find.text('bonus.pdf'), findsOneWidget);
  });

  testWidgets('confirming deletes the report and removes it from the list', (tester) async {
    await pumpTab(tester);
    await tester.tap(find.byTooltip('Delete report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(backend.deleted, ['r1']);
    expect(find.text('bonus.pdf'), findsNothing);
    expect(find.text('Report deleted.'), findsOneWidget);
  });

  testWidgets('a report still processing shows the backend message and stays', (tester) async {
    backend.deleteStatus = 409;
    await pumpTab(tester);
    await tester.tap(find.byTooltip('Delete report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('still being processed'), findsOneWidget);
    expect(find.text('bonus.pdf'), findsOneWidget);
  });
}
