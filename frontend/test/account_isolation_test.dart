import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/services/activity_log_store.dart';
import 'package:numberspeaks_app/services/local_report_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late String? signedInUser;

  setUp(() {
    signedInUser = null;
    SharedPreferences.setMockInitialValues({
      // What older builds left behind: one list for the whole device.
      'recent_reports_v1': '[{"report_id":"old-report","file_name":"x.pdf","status":"completed"}]',
      'activity_log_v1': '[{"type":"reportUploaded","report_id":"old-report"}]',
    });
  });

  test('reports are kept per signed-in account', () async {
    final store = LocalReportStore(userId: () => signedInUser);

    signedInUser = 'user-a';
    await store.upsertReport(reportId: 'report-a', fileName: 'a.pdf', status: 'completed');
    expect(await store.getLastReportId(), 'report-a');

    // Logged out, then a different account logs in on the same device.
    signedInUser = null;
    expect(await store.getRecentReports(), isEmpty);
    signedInUser = 'user-b';
    expect(await store.getRecentReports(), isEmpty);
    expect(await store.getLastReportId(), isNull);

    await store.upsertReport(reportId: 'report-b', fileName: 'b.pdf', status: 'completed');
    expect((await store.getRecentReports()).map((e) => e.reportId), ['report-b']);

    signedInUser = 'user-a';
    expect((await store.getRecentReports()).map((e) => e.reportId), ['report-a']);
  });

  test('nothing is written while signed out', () async {
    final store = LocalReportStore(userId: () => signedInUser);
    await store.upsertReport(reportId: 'r', fileName: 'r.pdf', status: 'uploaded');
    signedInUser = 'user-a';
    expect(await store.getRecentReports(), isEmpty);
  });

  test('the old un-scoped history is not shown to anyone and is deleted', () async {
    final store = LocalReportStore(userId: () => 'user-a');
    expect(await store.getRecentReports(), isEmpty);
    expect((await SharedPreferences.getInstance()).containsKey('recent_reports_v1'), isFalse);
  });

  test('a report the backend no longer has can be dropped from the list', () async {
    final store = LocalReportStore(userId: () => 'user-a');
    await store.upsertReport(reportId: 'gone', fileName: 'g.pdf', status: 'completed');
    await store.upsertReport(reportId: 'kept', fileName: 'k.pdf', status: 'completed');
    await store.removeReport('kept');
    expect(await store.getLastReportId(), 'gone');
  });

  test('activity log is per account too', () async {
    final log = ActivityLogStore(userId: () => signedInUser);
    signedInUser = 'user-a';
    await log.log(type: ActivityType.reportUploaded, reportId: 'report-a');
    expect(await log.getRecent(), hasLength(1));
    signedInUser = 'user-b';
    expect(await log.getRecent(), isEmpty);
    signedInUser = null;
    expect(await log.getRecent(), isEmpty);
    expect((await SharedPreferences.getInstance()).containsKey('activity_log_v1'), isFalse);
  });
}
