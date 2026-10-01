import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One report this device has uploaded, as tracked locally — see
/// [LocalReportStore]'s own doc comment for why this exists and what it
/// deliberately does NOT store.
///
/// [userCount], [bonusEligibleCount] and [totalBonus] are optional —
/// they're filled in from the real validate/calculate-bonus responses at
/// the moment those calls happen (never invented or estimated), purely so
/// the Reports tab can show "12 users" / a completed-report summary
/// without an extra network call for every card in the list. They stay
/// null until this device has actually seen that data.
class LocalReportEntry {
  final String reportId;
  final String fileName;
  final String status;
  final DateTime updatedAt;
  final int? userCount;
  final int? bonusEligibleCount;
  final double? totalBonus;

  const LocalReportEntry({
    required this.reportId,
    required this.fileName,
    required this.status,
    required this.updatedAt,
    this.userCount,
    this.bonusEligibleCount,
    this.totalBonus,
  });

  Map<String, dynamic> toJson() => {
        'report_id': reportId,
        'file_name': fileName,
        'status': status,
        'updated_at': updatedAt.toIso8601String(),
        'user_count': userCount,
        'bonus_eligible_count': bonusEligibleCount,
        'total_bonus': totalBonus,
      };

  factory LocalReportEntry.fromJson(Map<String, dynamic> json) {
    return LocalReportEntry(
      reportId: json['report_id'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      userCount: json['user_count'] as int?,
      bonusEligibleCount: json['bonus_eligible_count'] as int?,
      totalBonus: (json['total_bonus'] as num?)?.toDouble(),
    );
  }
}

/// On-device only storage of the reports this device has uploaded.
///
/// This exists solely because the backend has no "list reports" / "latest
/// report" endpoint (a disclosed gap — see README). It never stores bonus
/// amounts, user data, or anything else from the server beyond the small
/// aggregate counts described on [LocalReportEntry] — only each report's
/// id, file name, and the `status` field from an actual backend response
/// (upload/validate/calculate-bonus), purely as a local convenience so the
/// Dashboard and Reports tab have something real to show without inventing
/// backend behavior.
///
/// Keeps a bounded history (most-recently-touched report first) instead of
/// just a single "last report" pointer, so the Reports tab can show
/// several recent uploads — still nothing more than a local receipt of
/// uploads this device actually made.
///
/// Everything is stored under the signed-in account's id (see [_userId]), so
/// one account can never read — or open by id — another account's reports
/// on a shared device. With nobody signed in, reads are empty and writes are
/// ignored. The old un-scoped list (written before this, with no way to tell
/// whose reports it held) is deleted the first time the store is used.
class LocalReportStore {
  LocalReportStore({required String? Function() userId}) : _userId = userId;

  /// The id of whoever is signed in right now (null when signed out) —
  /// looked up on every call rather than remembered, so a store can never
  /// act for a previous account.
  final String? Function() _userId;

  static const _legacyKey = 'recent_reports_v1';
  static const _recentReportsKey = 'recent_reports_v2';
  static const _maxHistory = 10;

  String? get _key {
    final id = _userId();
    return id == null || id.isEmpty ? null : '$_recentReportsKey:$id';
  }

  /// Creates or updates one report's entry and moves it to the front of
  /// the history (most-recently-touched first). `fileName` can be omitted
  /// when only the status changed (validate/calculate-bonus responses
  /// don't carry a file name) — the existing file name is kept in that
  /// case. [userCount]/[bonusEligibleCount]/[totalBonus] are only updated
  /// when explicitly passed (from a real API response) — omitting them
  /// keeps whatever this device already knew.
  Future<void> upsertReport({
    required String reportId,
    String? fileName,
    required String status,
    int? userCount,
    int? bonusEligibleCount,
    double? totalBonus,
  }) async {
    final key = _key;
    if (key == null) return;
    final prefs = await _prefs();
    final list = await _readList(prefs, key);

    final existingIndex = list.indexWhere((e) => e.reportId == reportId);
    final existing = existingIndex >= 0 ? list[existingIndex] : null;
    final resolvedFileName = fileName ?? existing?.fileName ?? '';
    if (existingIndex >= 0) list.removeAt(existingIndex);

    list.insert(
      0,
      LocalReportEntry(
        reportId: reportId,
        fileName: resolvedFileName,
        status: status,
        updatedAt: DateTime.now(),
        userCount: userCount ?? existing?.userCount,
        bonusEligibleCount: bonusEligibleCount ?? existing?.bonusEligibleCount,
        totalBonus: totalBonus ?? existing?.totalBonus,
      ),
    );
    if (list.length > _maxHistory) list.removeRange(_maxHistory, list.length);

    await _writeList(prefs, key, list);
  }

  /// Forgets a report the backend says no longer exists (or is not this
  /// account's), so the app stops offering to open it.
  Future<void> removeReport(String reportId) async {
    final key = _key;
    if (key == null) return;
    final prefs = await _prefs();
    final list = await _readList(prefs, key);
    final kept = list.where((e) => e.reportId != reportId).toList();
    if (kept.length != list.length) await _writeList(prefs, key, kept);
  }

  /// Every tracked report of the signed-in account, most-recently-touched first.
  Future<List<LocalReportEntry>> getRecentReports() async {
    final key = _key;
    if (key == null) return [];
    final prefs = await _prefs();
    return _readList(prefs, key);
  }

  /// The most recently touched report's id, if any — used wherever the
  /// app needs "the current report" (Dashboard, Results tab).
  Future<String?> getLastReportId() async {
    final list = await getRecentReports();
    return list.isEmpty ? null : list.first.reportId;
  }

  Future<String?> getLastReportFileName() async {
    final list = await getRecentReports();
    return list.isEmpty ? null : list.first.fileName;
  }

  Future<String?> getLastReportStatus() async {
    final list = await getRecentReports();
    return list.isEmpty ? null : list.first.status;
  }

  Future<void> clear() async {
    final key = _key;
    if (key == null) return;
    final prefs = await _prefs();
    await prefs.remove(key);
  }

  Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_legacyKey)) await prefs.remove(_legacyKey);
    return prefs;
  }

  Future<List<LocalReportEntry>> _readList(SharedPreferences prefs, String key) async {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => LocalReportEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupted/old-format local data should never crash the app —
      // treat it as "no history yet" rather than surfacing an error for
      // something that isn't server data.
      return [];
    }
  }

  Future<void> _writeList(SharedPreferences prefs, String key, List<LocalReportEntry> list) async {
    final raw = jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(key, raw);
  }
}
