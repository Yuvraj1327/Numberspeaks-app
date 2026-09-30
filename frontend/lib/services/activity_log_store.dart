import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One real action this device took, for the Dashboard's "Recent activity"
/// feed. Every entry is logged at the exact moment a real backend call
/// (upload / validate / calculate-bonus / send-whatsapp) returns — never
/// synthesized or guessed. Purely on-device, same disclosure pattern as
/// [LocalReportStore]: this is a receipt of what *this device* did, not a
/// backend audit log (the backend has none to query).
enum ActivityType { reportUploaded, reportProcessed, bonusCalculated, whatsappSent }

extension ActivityTypeLabel on ActivityType {
  String get label {
    switch (this) {
      case ActivityType.reportUploaded:
        return 'Report uploaded';
      case ActivityType.reportProcessed:
        return 'Report processed';
      case ActivityType.bonusCalculated:
        return 'Bonus calculated';
      case ActivityType.whatsappSent:
        return 'WhatsApp messages sent';
    }
  }
}

class ActivityEntry {
  final ActivityType type;
  final String reportId;
  final String? fileName;
  final String? detail;
  final DateTime timestamp;

  const ActivityEntry({
    required this.type,
    required this.reportId,
    this.fileName,
    this.detail,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'report_id': reportId,
        'file_name': fileName,
        'detail': detail,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ActivityEntry.fromJson(Map<String, dynamic> json) {
    return ActivityEntry(
      type: ActivityType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => ActivityType.reportUploaded,
      ),
      reportId: json['report_id'] as String? ?? '',
      fileName: json['file_name'] as String?,
      detail: json['detail'] as String?,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// On-device only log of real actions taken in this app (see [ActivityEntry]
/// doc comment). Bounded so it never grows unbounded on a device that's
/// been used for a long time.
class ActivityLogStore {
  static const _key = 'activity_log_v1';
  static const _maxEntries = 30;

  Future<void> log({
    required ActivityType type,
    required String reportId,
    String? fileName,
    String? detail,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _readList(prefs);
    list.insert(
      0,
      ActivityEntry(
        type: type,
        reportId: reportId,
        fileName: fileName,
        detail: detail,
        timestamp: DateTime.now(),
      ),
    );
    if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
    await _writeList(prefs, list);
  }

  /// Most recent entries first, capped at [limit].
  Future<List<ActivityEntry>> getRecent({int limit = 5}) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _readList(prefs);
    return list.take(limit).toList();
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<List<ActivityEntry>> _readList(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => ActivityEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeList(SharedPreferences prefs, List<ActivityEntry> list) async {
    final raw = jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(_key, raw);
  }
}
