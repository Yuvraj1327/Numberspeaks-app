// THROWAWAY verification harness (deleted after use) — mounts the real
// ResultsScreen + repository over a fake HTTP adapter so the screen can be
// looked at on Chrome / Android without real credentials.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
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

class _Fake implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? r, Future<void>? c) async {
    final rows = [
      for (var i = 0; i < 8; i++)
        {
          'bonus_result_id': 'b$i', 'report_id': 'r1', 'user_id': 'u$i',
          'user_name': ['Alice', 'Bob', 'Carol', 'Dave', 'Erin', 'Frank', 'Grace', 'Heidi'][i],
          'whatsapp_number': i == 0 ? '919800000000' : null, 'level': 'Gold',
          'casino_pts': 100.0 * i, 'sport_pts': 20.5, 'third_party_pts': 0,
          'profit_loss': i.isEven ? -1000.0 * (i + 1) : 500.0 * i,
          'ptype': 'Credit', 'bonus_amount': i.isEven ? 30.0 * (i + 1) : 0,
          'calculation_status': 'calculated', 'whatsapp_status': 'not_sent',
          'created_at': '2026-10-02T10:00:00+00:00',
        }
    ];
    return ResponseBody.fromString(jsonEncode(rows), 200,
        headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  dotenv.testLoad(fileInput: '');
  final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = _Fake());
  final repo = ReportRepository(
    reportsApi: ReportsApiService(api), bonusApi: BonusApiService(api),
    whatsappApi: WhatsAppApiService(api),
    localStore: LocalReportStore(userId: () => 'preview'),
    activityLog: ActivityLogStore(userId: () => 'preview'),
    currentUserId: () => 'preview', supabaseStore: SupabaseReportStore(),
  );
  runApp(ChangeNotifierProvider<ReportRepository>.value(
    value: repo,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const ResultsScreen(reportId: 'r1'),
    ),
  ));
}
