import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../core/app_config.dart';
import '../models/bonus_result.dart';

/// Durable, per-admin persistence for uploaded reports and their calculated
/// bonus results — layered on top of the real FastAPI backend calls the
/// same way [LocalReportStore]/[ActivityLogStore] already are (see those
/// files), except this store is *account*-scoped (Supabase, keyed by the
/// signed-in admin's `auth.uid()`) rather than device-scoped, so results —
/// and any WhatsApp number an admin types in for a row — survive a
/// refresh, a logout/login, or opening the app on a different device for
/// the same account, per this round's "DATA STORAGE" brief.
///
/// Schema + RLS: see `supabase/numberspeaks_results_schema.sql` in the
/// project root — run it once in your Supabase project's SQL editor
/// before this store can do anything real.
///
/// Every method below is deliberately fail-soft: if the tables/bucket
/// don't exist yet (the SQL script hasn't been run), Supabase isn't
/// configured, or nobody is signed in, a call logs a warning via
/// [debugPrint] and returns harmlessly instead of throwing. This is a
/// durability *addition* on top of the real upload/validate/
/// calculate-bonus flow the FastAPI backend already owns — it must never
/// block or break that flow.
class SupabaseReportStore {
  SupabaseReportStore({supa.SupabaseClient? client}) : _clientOverride = client;

  final supa.SupabaseClient? _clientOverride;

  // Deliberately NOT named "reports"/"bonus_results" — this Supabase
  // project's Postgres database already has its own tables with those
  // exact names, owned by the FastAPI backend (different schema: it has
  // `user_id`, no `owner_id`). Reusing those names caused the SQL script
  // to silently skip table creation and then fail on the RLS policies —
  // see supabase/numberspeaks_results_schema.sql. These prefixed names
  // are this app's own, never shared with the backend's tables.
  static const _reportsTable = 'ns_reports';
  static const _resultsTable = 'ns_bonus_results';
  static const _pdfBucket = 'report-pdfs';

  supa.SupabaseClient? get _client {
    if (!AppConfig.isSupabaseConfigured) return null;
    try {
      return _clientOverride ?? supa.Supabase.instance.client;
    } catch (_) {
      // Supabase.initialize() was never called (e.g. isSupabaseConfigured
      // was false at startup) — treat exactly like "not configured".
      return null;
    }
  }

  String? get _ownerId => _client?.auth.currentUser?.id;

  /// Upserts this report's metadata (id, file name, status, the small
  /// aggregate counts already computed from a real backend response).
  /// Pass only the fields you actually have from the response that just
  /// came back — omitted ones keep whatever was saved before.
  Future<void> saveReportMeta({
    required String reportId,
    String? fileName,
    required String status,
    int? totalRecords,
    int? bonusEligibleCount,
    double? totalBonus,
  }) async {
    final client = _client;
    final owner = _ownerId;
    if (client == null || owner == null) return;
    try {
      await client.from(_reportsTable).upsert({
        'owner_id': owner,
        'report_id': reportId,
        if (fileName != null) 'file_name': fileName,
        'status': status,
        if (totalRecords != null) 'total_records': totalRecords,
        if (bonusEligibleCount != null) 'bonus_eligible_count': bonusEligibleCount,
        if (totalBonus != null) 'total_bonus': totalBonus,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'owner_id,report_id');
    } catch (e) {
      debugPrint('SupabaseReportStore.saveReportMeta failed (non-fatal): $e');
    }
  }

  /// Uploads the actual PDF bytes to Supabase Storage (private bucket,
  /// path-scoped to this owner) and records the path on the report row.
  /// Called right after a real upload succeeds — never blocks or retries
  /// the upload flow itself if this fails.
  Future<void> uploadReportPdf({
    required String reportId,
    required String fileName,
    required List<int> fileBytes,
  }) async {
    final client = _client;
    final owner = _ownerId;
    if (client == null || owner == null) return;
    try {
      final path = '$owner/$reportId/$fileName';
      await client.storage.from(_pdfBucket).uploadBinary(
            path,
            Uint8List.fromList(fileBytes),
            fileOptions: const supa.FileOptions(
              upsert: true,
              contentType: 'application/pdf',
            ),
          );
      await client.from(_reportsTable).upsert({
        'owner_id': owner,
        'report_id': reportId,
        'pdf_storage_path': path,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'owner_id,report_id');
    } catch (e) {
      debugPrint('SupabaseReportStore.uploadReportPdf failed (non-fatal): $e');
    }
  }

  /// Upserts every row of a real calculate-bonus/get-results response.
  Future<void> saveResults(String reportId, List<BonusResult> results) async {
    final client = _client;
    final owner = _ownerId;
    if (client == null || owner == null || results.isEmpty) return;
    try {
      final rows = results.map((r) => _toRow(owner, reportId, r)).toList();
      await client.from(_resultsTable).upsert(rows, onConflict: 'owner_id,report_id,bonus_result_id');
    } catch (e) {
      debugPrint('SupabaseReportStore.saveResults failed (non-fatal): $e');
    }
  }

  /// Overlays each result's `whatsappNumber` with an admin-entered number
  /// saved earlier for that same row, but only when the row itself doesn't
  /// already have one — a number actually present in the PDF/backend data
  /// always wins; a prior manual entry just fills the gap otherwise. Never
  /// throws; returns [results] unchanged if anything goes wrong or nothing
  /// has been saved yet.
  Future<List<BonusResult>> mergeWhatsAppNumbers(
    String reportId,
    List<BonusResult> results,
  ) async {
    final client = _client;
    final owner = _ownerId;
    if (client == null || owner == null || results.isEmpty) return results;
    try {
      final rows = await client
          .from(_resultsTable)
          .select('bonus_result_id, whatsapp_number')
          .eq('owner_id', owner)
          .eq('report_id', reportId);
      final saved = <String, String?>{
        for (final row in rows as List<dynamic>)
          (row['bonus_result_id'] as String? ?? ''): row['whatsapp_number'] as String?,
      };
      return results.map((r) {
        final hasNumber = r.whatsappNumber != null && r.whatsappNumber!.trim().isNotEmpty;
        if (hasNumber) return r;
        final override = saved[r.bonusResultId];
        if (override == null || override.trim().isEmpty) return r;
        return r.copyWith(whatsappNumber: override);
      }).toList();
    } catch (e) {
      debugPrint('SupabaseReportStore.mergeWhatsAppNumbers failed (non-fatal): $e');
      return results;
    }
  }

  /// The durable fallback read used when the FastAPI backend itself can't
  /// be reached (see `ReportRepository.getResults`) — this is what keeps
  /// results "available ... after refresh/logout-login" true even without
  /// a live backend connection, for whatever this account already saved.
  Future<List<BonusResult>> getCachedResults(String reportId) async {
    final client = _client;
    final owner = _ownerId;
    if (client == null || owner == null) return const [];
    try {
      final rows = await client
          .from(_resultsTable)
          .select()
          .eq('owner_id', owner)
          .eq('report_id', reportId)
          .order('user_name');
      return (rows as List<dynamic>).map((row) => _fromRow(row as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('SupabaseReportStore.getCachedResults failed (non-fatal): $e');
      return const [];
    }
  }

  /// Saves just the WhatsApp number an admin typed in for one row, as its
  /// own small upsert — so it's kept even if a full [saveResults] for this
  /// report hasn't run since (e.g. the number was filled in on a later
  /// visit to the Results screen, after the report was already saved).
  Future<void> updateWhatsAppNumber({
    required String reportId,
    required BonusResult result,
    required String whatsappNumber,
  }) async {
    final client = _client;
    final owner = _ownerId;
    if (client == null || owner == null) return;
    try {
      final row = _toRow(owner, reportId, result);
      row['whatsapp_number'] = whatsappNumber;
      await client.from(_resultsTable).upsert(row, onConflict: 'owner_id,report_id,bonus_result_id');
    } catch (e) {
      debugPrint('SupabaseReportStore.updateWhatsAppNumber failed (non-fatal): $e');
    }
  }

  Map<String, dynamic> _toRow(String owner, String reportId, BonusResult r) {
    return {
      'owner_id': owner,
      'report_id': reportId,
      'bonus_result_id': r.bonusResultId,
      'user_id': r.userId,
      'user_name': r.userName,
      'level': r.level,
      'casino_pts': r.casinoPts,
      'sport_pts': r.sportPts,
      'third_party_pts': r.thirdPartyPts,
      'profit_loss': r.profitLoss,
      'ptype': r.ptype,
      'bonus_amount': r.bonusAmount,
      'calculation_status': r.calculationStatus,
      'whatsapp_status': r.whatsappStatus,
      'whatsapp_number': r.whatsappNumber,
      'updated_at': DateTime.now().toIso8601String(),
    };
  }

  BonusResult _fromRow(Map<String, dynamic> row) {
    return BonusResult(
      bonusResultId: row['bonus_result_id'] as String? ?? '',
      reportId: row['report_id'] as String? ?? '',
      userId: row['user_id'] as String? ?? '',
      userName: row['user_name'] as String? ?? '',
      whatsappNumber: row['whatsapp_number'] as String?,
      level: row['level'] as String?,
      casinoPts: (row['casino_pts'] as num?)?.toDouble() ?? 0,
      sportPts: (row['sport_pts'] as num?)?.toDouble() ?? 0,
      thirdPartyPts: (row['third_party_pts'] as num?)?.toDouble() ?? 0,
      profitLoss: (row['profit_loss'] as num?)?.toDouble() ?? 0,
      ptype: row['ptype'] as String?,
      bonusAmount: (row['bonus_amount'] as num?)?.toDouble(),
      calculationStatus: row['calculation_status'] as String? ?? 'pending',
      whatsappStatus: row['whatsapp_status'] as String? ?? 'not_sent',
      createdAt: row['created_at'] as String?,
    );
  }
}
