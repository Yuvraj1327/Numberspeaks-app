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
      case ReportStatus.uploaded:
        color = AppTheme.warning;
        break;
      case ReportStatus.unknown:
        color = Colors.black54;
        break;
    }
    return StatusPill(label: status.label, color: color);
  }

  /// For a raw WhatsApp message status string ("sent" | "failed" |
  /// "skipped_already_sent" | "skipped_no_number"), taken verbatim from the
  /// backend and only re-labeled for readability, never reinterpreted.
  factory StatusPill.forWhatsAppStatus(String status) {
    switch (status) {
      case 'sent':
        return const StatusPill(label: 'Sent', color: AppTheme.success);
      case 'skipped_already_sent':
        return const StatusPill(label: 'Already sent', color: AppTheme.success);
      case 'failed':
        return const StatusPill(label: 'Failed', color: AppTheme.danger);
      case 'skipped_no_number':
        return const StatusPill(label: 'No WhatsApp number', color: AppTheme.warning);
      default:
        return StatusPill(label: status, color: Colors.black54);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}
