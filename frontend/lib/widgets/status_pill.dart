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

  /// WhatsApp send status of one result: Pending, Sending, Sent, Failed or Unknown.
  /// "Sent" only ever appears once the backend recorded the provider's
  /// confirmation.
  factory StatusPill.forSend(String sendStatus) {
    switch (sendStatus) {
      case 'sent':
        return const StatusPill(label: 'Sent', color: AppTheme.success);
      case 'sending':
        return const StatusPill(label: 'Sending', color: AppTheme.blue);
      case 'failed':
        return const StatusPill(label: 'Failed', color: AppTheme.danger);
      case 'unknown':
        return const StatusPill(label: 'Unknown', color: AppTheme.warning);
      default:
        return const StatusPill(label: 'Pending', color: Colors.black54);
    }
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
