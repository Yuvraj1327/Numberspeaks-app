import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/api_client.dart';
import 'package:numberspeaks_app/core/api_exception.dart';
import 'package:numberspeaks_app/repositories/report_repository.dart';
import 'package:numberspeaks_app/services/bonus_api_service.dart';
import 'package:numberspeaks_app/services/referrals_api_service.dart';
import 'package:numberspeaks_app/services/reports_api_service.dart';
import 'package:numberspeaks_app/services/settings_api_service.dart';
import 'package:numberspeaks_app/services/users_api_service.dart';
import 'package:numberspeaks_app/services/whatsapp_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Account isolation now lives in the backend: it derives the owner from the
/// bearer token alone and returns only that admin's rows. This fake behaves
/// the same way, so these tests check that the app (a) only ever identifies
/// the account through the token, and (b) keeps nothing on the device that
/// could leak one account's data to the next.
class _FakeBackend implements HttpClientAdapter {
  final byToken = <String, List<Map<String, dynamic>>>{
    'token-a': [_report('report-a', 'a.pdf')],
    'token-b': [_report('report-b', 'b.pdf')],
  };
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? r, Future<void>? c) async {
    requests.add(o);
    final auth = o.headers['Authorization'] as String?;
    final rows = auth == null ? null : byToken[auth.replaceFirst('Bearer ', '')];
    if (rows == null) {
      return ResponseBody.fromString(jsonEncode({'detail': 'Not authenticated'}), 401,
          headers: {Headers.contentTypeHeader: ['application/json']});
    }
    return ResponseBody.fromString(jsonEncode(rows), 200,
        headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _report(String id, String name) => {
      'report_id': id,
      'file_name': name,
      'status': 'completed',
      'uploaded_at': '2026-10-02T10:00:00+00:00',
    };

ReportRepository _repoFor(ApiClient api) => ReportRepository(
      reportsApi: ReportsApiService(api),
      bonusApi: BonusApiService(api),
      referralsApi: ReferralsApiService(api),
      usersApi: UsersApiService(api),
      settingsApi: SettingsApiService(api),
      whatsappApi: WhatsAppApiService(api),
    );

void main() {
  late _FakeBackend backend;
  late ApiClient api;
  late ReportRepository repo;

  setUp(() {
    dotenv.testLoad(fileInput: '');
    SharedPreferences.setMockInitialValues({
      // What older builds left behind: one list for the whole device.
      'recent_reports_v1': '[{"report_id":"old-report","file_name":"x.pdf","status":"completed"}]',
      'activity_log_v1': '[{"type":"reportUploaded","report_id":"old-report"}]',
    });
    backend = _FakeBackend();
    api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = backend);
    repo = _repoFor(api);
  });

  test('reports follow the signed-in account', () async {
    api.setAuthToken('token-a');
    expect((await repo.listReports()).map((e) => e.reportId), ['report-a']);

    // Logged out, then a different account logs in on the same device.
    api.setAuthToken(null);
    await expectLater(
      repo.listReports(),
      throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.unauthorized)),
    );
    api.setAuthToken('token-b');
    expect((await repo.listReports()).map((e) => e.reportId), ['report-b']);

    api.setAuthToken('token-a');
    expect((await repo.listReports()).map((e) => e.reportId), ['report-a']);
  });

  test('nothing is returned while signed out', () async {
    await expectLater(repo.listReports(), throwsA(isA<ApiException>()));
  });

  test('the old on-device history is never shown to anyone', () async {
    api.setAuthToken('token-a');
    final ids = (await repo.listReports()).map((e) => e.reportId);
    expect(ids, isNot(contains('old-report')));
  });

  test('the account is identified only by the token, never by an owner id', () async {
    api.setAuthToken('token-a');
    await repo.listReports();
    for (final request in backend.requests) {
      expect(request.queryParameters, isEmpty);
      expect(request.data, isNull);
      expect(request.uri.path, isNot(contains('token-a')));
      expect(request.uri.path, isNot(contains('user-a')));
    }
  });

  test('a fresh device sees the same list for the same account', () async {
    api.setAuthToken('token-a');
    final first = (await repo.listReports()).map((e) => e.reportId).toList();

    SharedPreferences.setMockInitialValues({});
    final freshApi = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = backend)
      ..setAuthToken('token-a');
    final fresh = _repoFor(freshApi);
    expect((await fresh.listReports()).map((e) => e.reportId), first);
  });
}
