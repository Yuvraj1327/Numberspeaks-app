import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../models/report_status.dart';

/// Small colored label used for report status and WhatsApp status,
/// wherever they appear (Dashboard, Reports, Results, User Detail).
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
        color = Colors.black54;
        break;
    }
    return StatusPill(label: status.label, color: color);
  }

  /// WhatsApp status of one result. The app never sends a message itself, so
  /// the only states are: not opened yet, or "Opened" (the admin opened
  /// WhatsApp with the message pre-filled). Nothing here ever says "Sent" or
  /// "Delivered" — that cannot be known.
  factory StatusPill.forWhatsApp({required bool opened}) {
    return opened
        ? const StatusPill(label: 'Opened', color: AppTheme.blue)
        : const StatusPill(label: 'Not opened', color: Colors.black54);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}
