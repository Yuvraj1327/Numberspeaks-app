import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../models/report_status.dart';

/// Small colored label used for report status and WhatsApp send status,
/// wherever they appear (Dashboard, Results, User Detail).
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const StatusPill({super.key, required this.label, required this.color});

  factory StatusPill.forReportStatus(ReportStatus status) {
    Color color;
    switch (status) {
      case ReportStatus.completed:
      case ReportStatus.validated:
        color = AppTheme.success;
        break;
      case ReportStatus.failed:
        color = AppTheme.danger;
        break;
      case ReportStatus.processing:
      case ReportStatus.validating:
      case ReportStatus.calculating:
      case ReportStatus.uploaded:
        color = AppTheme.warning;
        break;
      case ReportStatus.unknown:
        color = AppTheme.textMuted;
        break;
    }
    return StatusPill(label: status.label, color: color);
  }

  /// For a raw WhatsApp message status string ("sent" | "failed" |
  /// "skipped_already_sent" | "skipped_no_number" | "skipped_no_bonus" |
  /// "not_sent"), taken verbatim from the backend and only re-labeled for
  /// readability, never reinterpreted. Covers both the per-send-attempt
  /// status (WhatsAppMessageResult, from POST /send-whatsapp) and the
  /// simpler latest-status field on a bonus result (BonusResult.
  /// whatsappStatus, shown on the Results/User Detail screens).
  ///
  /// Labels match the four states asked for in the UI brief — Sent /
  /// Pending / Failed / No Number — "Pending" covers "not_sent" (never
  /// attempted) and "No Number" covers "skipped_no_number" (no WhatsApp
  /// number on file, so nothing could be sent).
  factory StatusPill.forWhatsAppStatus(String status) {
    switch (status) {
      case 'sent':
        return const StatusPill(label: 'Sent', color: AppTheme.success);
      case 'skipped_already_sent':
        return const StatusPill(label: 'Already sent', color: AppTheme.success);
      case 'failed':
        return const StatusPill(label: 'Failed', color: AppTheme.danger);
      case 'skipped_no_number':
        return const StatusPill(label: 'No Number', color: AppTheme.warning);
      case 'skipped_no_bonus':
        return const StatusPill(label: 'No bonus owed', color: AppTheme.textMuted);
      case 'not_sent':
        return const StatusPill(label: 'Pending', color: AppTheme.warning);
      default:
        return StatusPill(label: status, color: AppTheme.textMuted);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.13),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5),
      ),
    );
  }
}
