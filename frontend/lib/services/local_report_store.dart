import 'package:shared_preferences/shared_preferences.dart';

/// On-device only storage of "the last report this device uploaded".
///
/// This exists solely because the backend has no "list reports" / "latest
/// report" endpoint (a disclosed Step 8 gap — see README). It never stores
/// bonus amounts, user data, or anything else from the server — only a
/// report id and file name, purely as a local convenience so the Dashboard
/// has something to show without inventing backend behavior.
class LocalReportStore {
  static const _lastReportIdKey = 'last_report_id';
  static const _lastReportFileNameKey = 'last_report_file_name';
  static const _lastReportStatusKey = 'last_report_status';

  Future<void> saveLastReport({required String reportId, required String fileName}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastReportIdKey, reportId);
    await prefs.setString(_lastReportFileNameKey, fileName);
  }

  /// Remembers the `status` field from the most recent real backend
  /// response for this report (upload/validate/calculate-bonus). This is
  /// the ONLY source for "current report status" shown on the Dashboard,
  /// since the backend has no GET /reports/{id} status-lookup endpoint —
  /// it is never guessed or inferred, only copied from an actual response.
  Future<void> saveLastReportStatus(String status) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastReportStatusKey, status);
  }

  Future<String?> getLastReportId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastReportIdKey);
  }

  Future<String?> getLastReportFileName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastReportFileNameKey);
  }

  Future<String?> getLastReportStatus() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastReportStatusKey);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastReportIdKey);
    await prefs.remove(_lastReportFileNameKey);
    await prefs.remove(_lastReportStatusKey);
  }
}
