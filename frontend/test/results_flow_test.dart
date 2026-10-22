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
import 'package:numberspeaks_app/services/bonus_api_service.dart';
import 'package:numberspeaks_app/services/referrals_api_service.dart';
import 'package:numberspeaks_app/services/reports_api_service.dart';
import 'package:numberspeaks_app/services/settings_api_service.dart';
import 'package:numberspeaks_app/services/users_api_service.dart';
import 'package:numberspeaks_app/services/whatsapp_api_service.dart';
import 'package:provider/provider.dart';

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
    final reportMatch = RegExp(r'/reports/([^/]+)$').firstMatch(path);
    final calculateMatch = RegExp(r'/reports/([^/]+)/calculate-bonus$').firstMatch(path);
    if (options.method == 'POST' && calculateMatch != null) {
      body = {
        'report_id': calculateMatch.group(1),
        'status': 'completed',
        'total_input_records': 1,
        'calculated_count': 1,
        'failed_count': 0,
        'total_payable': 30,
        'payable_user_count': 1,
        'results': <Object>[],
        'errors': <Object>[],
      };
    } else if (path.endsWith('/reports')) {
      body = reports;
    } else if (resultsMatch != null) {
      final rows = results[resultsMatch.group(1)];
      if (rows == null) {
        status = 404;
        body = {'detail': 'No report found with id ${resultsMatch.group(1)}'};
      } else {
        body = rows;
      }
    } else if (reportMatch != null &&
        reports.any((e) => e['report_id'] == reportMatch.group(1))) {
      body = reports.firstWhere((e) => e['report_id'] == reportMatch.group(1));
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
      'send_status': 'pending',
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

  setUp(() {
    dotenv.testLoad(fileInput: '');
    backend = _FakeBackend();
    final dio = Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = backend;
    final api = ApiClient(dio: dio);
    repo = ReportRepository(
      reportsApi: ReportsApiService(api),
      bonusApi: BonusApiService(api),
      referralsApi: ReferralsApiService(api),
      usersApi: UsersApiService(api),
      settingsApi: SettingsApiService(api),
      whatsappApi: WhatsAppApiService(api),
    );
  });

  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  // The tab keeps a frame scheduled after loading, so pumpAndSettle would
  // never return; pump a bounded amount of time instead.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget host(Widget child) => ChangeNotifierProvider<ReportRepository>.value(
        value: repo,
        child: MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
      );

  testWidgets('a pushed Results screen lists the backend results', (tester) async {
    useDesktopSurface(tester);
    backend.results['r1'] = [
      _row('1', 'r1', 'Alice', -1000, 30),
      _row('2', 'r1', 'Bob', 500, 0),
    ];
    backend.reports = [_report('r1', 'completed')];
    await tester.pumpWidget(host(const ResultsScreen(reportId: 'r1')));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('the Results tab shows a report that finishes after the tab loaded', (tester) async {
    useDesktopSurface(tester);
    // The tab is built at login, before anything has been uploaded.
    await tester.pumpWidget(host(const ResultsTab()));
    await settle(tester);
    expect(find.textContaining('No results yet'), findsOneWidget);

    // The user uploads a PDF; its bonus calculation finishes.
    backend.reports = [_report('r1', 'completed')];
    backend.results['r1'] = [_row('1', 'r1', 'Alice', -1000, 30)];
    final finished = repo.calculateBonus('r1');
    await settle(tester);
    await finished;

    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('a saved number stays on its own user when the list is re-sorted', (tester) async {
    // The number is now added through a dialog and saved on the backend, so
    // the table shows it from the row's own data; re-sorting must keep it
    // beside the same user.
    useDesktopSurface(tester);
    backend.reports = [_report('r1', 'completed')];
    backend.results['r1'] = [
      {..._row('1', 'r1', 'Alice', -1000, 30), 'whatsapp_number': '911111111111'},
      _row('2', 'r1', 'Bob', -2000, 60),
    ];
    await tester.pumpWidget(host(const ResultsScreen(reportId: 'r1')));
    await tester.pumpAndSettle();

    double rowGap(String name) =>
        (tester.getCenter(find.text(name)).dy - tester.getCenter(find.text('911111111111')).dy).abs();

    expect(rowGap('Alice'), lessThan(30));
    expect(rowGap('Bob'), greaterThan(30));

    await tester.tap(find.byKey(const Key('results-options-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (Z-A)'));
    await tester.pumpAndSettle();

    expect(rowGap('Alice'), lessThan(30));
    expect(rowGap('Bob'), greaterThan(30));
    expect(find.text('Add number'), findsOneWidget);
  });

  testWidgets('options are collapsed by default and all remain usable when expanded', (tester) async {
    useDesktopSurface(tester);
    backend.reports = [_report('r1', 'completed')];
    backend.results['r1'] = [
      _row('1', 'r1', 'Alice', -1000, 30),
      _row('2', 'r1', 'Bob', 500, 0),
    ];
    await tester.pumpWidget(host(const ResultsScreen(reportId: 'r1')));
    await tester.pumpAndSettle();

    // Collapsed: search and the user rows are visible; the option controls are not.
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.text('Sort'), findsNothing);
    expect(find.text('Total payable'.toUpperCase()), findsNothing);
    expect(find.text('Send All Eligible (2)'), findsNothing);

    await tester.tap(find.byKey(const Key('results-options-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Sort'), findsOneWidget);
    expect(find.text('Referral'), findsOneWidget);
    expect(find.text('Recalculate'), findsOneWidget);
    expect(find.text('TOTAL PAYABLE'), findsOneWidget);
    expect(find.textContaining('Send Selected'), findsOneWidget);
    expect(find.textContaining('Send All Eligible'), findsOneWidget);
    expect(find.text('Loss'), findsOneWidget); // filter chip

    // Collapse again.
    await tester.tap(find.byKey(const Key('results-options-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Sort'), findsNothing);
  });

  testWidgets('expanded options fit a small phone with no overflow and cards stay reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 568 * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    backend.reports = [_report('r1', 'completed')];
    backend.results['r1'] = [
      for (var i = 0; i < 6; i++) _row('$i', 'r1', 'User$i', -1000, 30),
    ];
    await tester.pumpWidget(host(const ResultsScreen(reportId: 'r1')));
    await tester.pumpAndSettle();
    expect(find.text('User0'), findsOneWidget); // collapsed: first card immediately visible

    await tester.tap(find.byKey(const Key('results-options-toggle')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // the panel is height-capped, so the list is still on screen below it
    final panel = tester.getRect(find.byKey(const Key('results-options-panel')));
    expect(panel.height, lessThanOrEqualTo(568 * 0.42 + 0.5));
    expect(find.text('User0'), findsOneWidget);
  });

  testWidgets('moving a mouse over the results does not throw', (tester) async {
    useDesktopSurface(tester);
    backend.results['r1'] = [
      _row('1', 'r1', 'Alice', -1000, 30),
      _row('2', 'r1', 'Bob', 500, 0),
    ];
    backend.reports = [_report('r1', 'completed')];
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
    await tester.tap(find.byKey(const Key('results-options-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (Z-A)'));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text('Bob')));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
