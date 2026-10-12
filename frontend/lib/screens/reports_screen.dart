import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/responsive.dart';
import '../core/formatters.dart';
import '../core/report_actions.dart';
import '../models/report_status.dart';
import '../models/report_summary.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/screen_header.dart';
import '../widgets/status_pill.dart';

/// Reports tab (embedded inside [MainShell]): the full report history of the
/// logged-in admin. It is loaded from the backend (stored in Supabase), so
/// it is the same after a refresh, after logging out and in again, and on
/// any other device.
class ReportsTab extends StatefulWidget {
  const ReportsTab({super.key});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  bool _loading = true;
  String? _errorMessage;
  List<ReportSummary> _reports = [];
  int _seenRevision = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision = context.watch<ReportRepository>().revision;
    if (revision != _seenRevision) {
      final first = _seenRevision == -1;
      _seenRevision = revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(silent: !first);
      });
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final reports = await context.read<ReportRepository>().listReports();
      if (!mounted) return;
      setState(() {
        _reports = reports;
        _loading = false;
        _errorMessage = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (!silent || _reports.isEmpty) _errorMessage = e.userMessage;
        _loading = false;
      });
    }
  }

  final Set<String> _deleting = {};

  Future<void> _confirmDelete(ReportSummary report) async {
    final name = report.fileName.isNotEmpty ? report.fileName : 'this report';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Delete this report?'),
        content: Text(
          '"$name" will be permanently deleted together with its extracted rows, '
          'bonus results, referral entries, calculation history and the stored PDF. '
          'This cannot be undone. Your other reports are not affected.',
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _deleting.contains(report.reportId)) return;

    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<ReportRepository>();
    setState(() => _deleting.add(report.reportId));
    String? failure;
    var gone = false;
    try {
      await repo.deleteReport(report.reportId);
      gone = true;
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) {
        gone = true; // already deleted elsewhere
      } else if (e.kind == ApiErrorKind.timeout) {
        // No answer is not a failure: check whether it went through.
        try {
          final remaining = await repo.listReports();
          gone = !remaining.any((r) => r.reportId == report.reportId);
        } on ApiException {
          // Still unknown.
        }
        if (!gone) failure = 'Could not confirm the deletion in time. Refresh to check, then try again.';
      } else {
        failure = e.userMessage;
      }
    }
    if (!mounted) return;
    setState(() {
      _deleting.remove(report.reportId);
      if (gone) _reports = _reports.where((r) => r.reportId != report.reportId).toList();
    });
    messenger.showSnackBar(SnackBar(
      content: Text(gone ? 'Report deleted.' : 'Could not delete the report. ${failure ?? ''}'.trim()),
    ));
  }

  Future<void> _openUpload() async {
    await Navigator.of(context).pushNamed(AppRoutes.upload);
    if (mounted) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: Responsive.pageInsets(context),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const ScreenHeader(eyebrow: 'Your uploads', title: 'Reports'),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _openUpload,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Upload Report'),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionTitle('Report history'),
          const SizedBox(height: AppSpacing.sm + 4),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: LoadingView(),
            )
          else if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.lg),
              child: ErrorView(message: _errorMessage!, onRetry: _load),
            )
          else if (_reports.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: EmptyView(
                icon: Icons.folder_open_outlined,
                message: 'No reports uploaded yet.\nUpload a PDF report to get started.',
              ),
            )
          else
            for (final report in _reports)
              ReportCard(
                report: report,
                deleting: _deleting.contains(report.reportId),
                onDelete: () => _confirmDelete(report),
              ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

/// One report in the history. Also used by the Dashboard's recent list.
class ReportCard extends StatelessWidget {
  final ReportSummary report;

  /// When set, a Delete button is shown (Reports tab). [deleting] disables
  /// the card's buttons while the request is running.
  final VoidCallback? onDelete;
  final bool deleting;

  const ReportCard({super.key, required this.report, this.onDelete, this.deleting = false});

  @override
  Widget build(BuildContext context) {
    final action = resolveNextAction(report.status);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm + 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconBadge(icon: Icons.picture_as_pdf_outlined, color: AppTheme.blue),
                  const SizedBox(width: AppSpacing.sm + 4),
                  Expanded(
                    child: Text(
                      report.title,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  StatusPill.forReportStatus(ReportStatus.fromString(report.status)),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      Formatters.dateTime(report.uploadedAt),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (report.userCount > 0) ...[
                    const SizedBox(width: AppSpacing.sm),
                    const Text('•', style: TextStyle(color: AppTheme.textMuted)),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '${report.userCount} user(s)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
              if (report.isCompleted && report.totalPayable != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppTheme.teal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${report.payableUserCount} of ${report.userCount} user(s) payable • '
                    '${Formatters.rupees(report.totalPayable!)} total payable',
                    style: const TextStyle(color: AppTheme.teal, fontWeight: FontWeight.w600, fontSize: 12.5),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onDelete != null) ...[
                    deleting
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            tooltip: 'Delete report',
                            icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
                            onPressed: onDelete,
                          ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  // Expanded: the theme's buttons are full-width, which a Row needs bounded.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: deleting
                            ? null
                            : () => Navigator.of(context).pushNamed(action.route, arguments: report.reportId),
                        icon: Icon(action.icon, size: 18),
                        label: Text(action.label),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
