import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/api_client.dart';
import 'package:numberspeaks_app/core/app_theme.dart';
import 'package:numberspeaks_app/repositories/report_repository.dart';
import 'package:numberspeaks_app/screens/results_screen.dart';
import 'package:numberspeaks_app/services/activity_log_store.dart';
import 'package:numberspeaks_app/services/bonus_api_service.dart';
import 'package:numberspeaks_app/services/local_report_store.dart';
import 'package:numberspeaks_app/services/reports_api_service.dart';
import 'package:numberspeaks_app/services/supabase_report_store.dart';
import 'package:numberspeaks_app/services/whatsapp_api_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers the backend's report endpoints from [reports] / [results] with the
/// exact JSON shapes FastAPI returns (app/schemas/*.py), so the real
/// ApiClient -> service -> repository -> screen path is exercised.
class _FakeBackend implements HttpClientAdapter {
  List<Map<String, dynamic>> reports = [];
  Map<String, List<Map<String, dynamic>>> results = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    Object body;
    var status = 200;
    final resultsMatch = RegExp(r'/reports/([^/]+)/results$').firstMatch(path);
    if (path.endsWith('/reports')) {
      body = reports;
    } else if (resultsMatch != null) {
      final rows = results[resultsMatch.group(1)];
      if (rows == null) {
        status = 404;
        body = {'detail': 'No report found with id ${resultsMatch.group(1)}'};
      } else {
        body = rows;
      }
    } else {
      status = 404;
      body = {'detail': 'Not Found'};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _row(String id, String report, String name, double pl, double? bonus) => {
      'bonus_result_id': id,
      'report_id': report,
      'user_id': 'u-$id',
      'user_name': name,
      'whatsapp_number': null,
      'level': 'Gold',
      'casino_pts': 10,
      'sport_pts': 20.5,
      'third_party_pts': 0,
      'profit_loss': pl,
      'ptype': 'Credit',
      'bonus_amount': bonus,
      'calculation_status': 'calculated',
      'whatsapp_status': 'not_sent',
      'created_at': '2026-10-02T10:00:00+00:00',
    };

Map<String, dynamic> _report(String id, String status) => {
      'report_id': id,
      'file_name': '$id.pdf',
      'status': status,
      'total_records': 2,
      'calculated_count': 2,
      'failed_count': 0,
      'uploaded_at': '2026-10-02T10:00:00+00:00',
      'updated_at': '2026-10-02T10:00:05+00:00',
    };

void main() {
  late _FakeBackend backend;
  late ReportRepository repo;
  late String? signedIn;

  setUp(() {
    dotenv.testLoad(fileInput: '');
    SharedPreferences.setMockInitialValues({});
    backend = _FakeBackend();
    signedIn = 'user-a';
    final dio = Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = backend;
    final api = ApiClient(dio: dio);
    repo = ReportRepository(
      reportsApi: ReportsApiService(api),
      bonusApi: BonusApiService(api),
      whatsappApi: WhatsAppApiService(api),
      localStore: LocalReportStore(userId: () => signedIn),
      activityLog: ActivityLogStore(userId: () => signedIn),
      currentUserId: () => signedIn,
      supabaseStore: SupabaseReportStore(),
    );
  });

  Widget host(Widget child) => ChangeNotifierProvider<ReportRepository>.value(
        value: repo,
        child: MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
      );

  testWidgets('a pushed Results screen lists the backend results', (tester) async {
    backend.results['r1'] = [
      _row('1', 'r1', 'Alice', -1000, 30),
      _row('2', 'r1', 'Bob', 500, 0),
    ];
    await tester.pumpWidget(host(const ResultsScreen(reportId: 'r1')));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('the Results tab shows a report that finishes after the tab loaded', (tester) async {
    // The tab is built at login, before anything has been uploaded.
    await tester.pumpWidget(host(const ResultsTab()));
    await tester.pumpAndSettle();
    expect(find.textContaining('No results yet'), findsOneWidget);

    // The user uploads a PDF; it finishes processing in the background.
    backend.reports = [_report('r1', 'completed')];
    backend.results['r1'] = [_row('1', 'r1', 'Alice', -1000, 30)];
    await repo.recordBackgroundRunFinished('r1', status: 'completed', results: const []);
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('a number typed for one user never moves to another when the list is re-sorted',
      (tester) async {
    backend.results['r1'] = [
      _row('1', 'r1', 'Alice', -1000, 30),
      _row('2', 'r1', 'Bob', -2000, 60),
    ];
    await tester.pumpWidget(host(const ResultsScreen(reportId: 'r1')));
    await tester.pumpAndSettle();

    // Alice is first (A-Z). Type a number on her card.
    await tester.tap(find.byType(TextField).at(1)); // a user focuses the field first
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), '911111111111');
    await tester.pump();
    // Re-sort Z-A: Bob is now first.
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (Z-A)'));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    // fields[0] is the search box; fields[1] is Bob's number field now.
    expect(fields[1].controller!.text, isEmpty, reason: "Alice's number must not show on Bob");
    expect(fields[2].controller!.text, '911111111111');
  });

  testWidgets('moving a mouse over the results does not throw', (tester) async {
    backend.results['r1'] = [
      _row('1', 'r1', 'Alice', -1000, 30),
      _row('2', 'r1', 'Bob', 500, 0),
    ];
    await tester.pumpWidget(host(const ResultsScreen(reportId: 'r1')));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final name in ['Alice', 'Bob', 'Alice']) {
      await mouse.moveTo(tester.getCenter(find.text(name)));
      await tester.pump();
    }
    // Hover a card, then replace the list underneath the pointer.
    await mouse.moveTo(tester.getCenter(find.text('Alice')));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (Z-A)'));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text('Bob')));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
