import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/report_actions.dart';
import '../models/report_status.dart';
import '../models/report_summary.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
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

  Future<void> _openUpload() async {
    await Navigator.of(context).pushNamed(AppRoutes.upload);
    if (mounted) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _openUpload,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Upload Report'),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Report history', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
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
            for (final report in _reports) ReportCard(report: report),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

/// One report in the history. Also used by the Dashboard's recent list.
class ReportCard extends StatelessWidget {
  final ReportSummary report;

  const ReportCard({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final action = resolveNextAction(report.status);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceMuted,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.picture_as_pdf_outlined, color: AppTheme.primary),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      report.fileName.isNotEmpty ? report.fileName : 'Report',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                    ),
                  ),
                  if (report.userCount > 0) ...[
                    const SizedBox(width: AppSpacing.sm),
                    const Text('•', style: TextStyle(color: Colors.black38)),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '${report.userCount} user(s)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
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
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${report.payableUserCount} of ${report.userCount} user(s) payable • '
                    '${Formatters.rupees(report.totalPayable!)} total payable',
                    style: const TextStyle(color: AppTheme.teal, fontWeight: FontWeight.w600, fontSize: 12.5),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed(action.route, arguments: report.reportId),
                  icon: Icon(action.icon, size: 18),
                  label: Text(action.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
