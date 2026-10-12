import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/report_actions.dart';
import '../models/bonus_result.dart';
import '../models/report_status.dart';
import '../models/report_summary.dart';
import '../repositories/auth_repository.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/status_pill.dart';
import 'reports_screen.dart';

/// Dashboard tab (embedded inside [MainShell] — no Scaffold/AppBar of its
/// own, those are shared across every tab).
///
/// Everything here comes from the backend (Supabase, scoped to the logged-in
/// admin), so it is the same on every device:
///  - the report history ("Total Reports", the latest report, recent reports);
///  - the most recently *calculated* report's real rows, for Total Loss,
///    Total Payable and the WhatsApp counts. Nothing is estimated.
///
/// "WhatsApp Opened" counts users for whom the admin opened WhatsApp with
/// the message pre-filled. It does not mean the message was sent or delivered.
class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  bool _loading = true;
  String? _errorMessage;

  List<ReportSummary> _reports = [];
  ReportSummary? _calculated; // newest completed report
  List<BonusResult> _results = [];
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

    final repo = context.read<ReportRepository>();
    try {
      final reports = await repo.listReports();
      final completed = reports.where((r) => r.isCompleted);
      final calculated = completed.isEmpty ? null : completed.first;

      var results = <BonusResult>[];
      if (calculated != null) {
        try {
          results = await repo.getResults(calculated.reportId);
        } on ApiException {
          // The summary tiles simply stay empty; this is not a
          // dashboard-level failure.
          results = [];
        }
      }

      if (!mounted) return;
      setState(() {
        _reports = reports;
        _calculated = calculated;
        _results = results;
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository>();

    if (_loading) return const LoadingView();
    if (_errorMessage != null) {
      return ErrorView(message: _errorMessage!, onRetry: _load);
    }

    // --- Figures from the newest calculated report's real results -------
    final usersProcessed = _results.length;
    final totalLoss = _results
        .where((r) => r.profitLoss < 0)
        .fold<double>(0, (sum, r) => sum + r.profitLoss.abs());
    final payableRows = _results.where((r) => r.hasPayableBonus).toList();
    final totalPayable = payableRows.fold<double>(0, (sum, r) => sum + r.payable);
    final opened = payableRows.where((r) => r.whatsappInitiated).length;
    final notOpened = payableRows.length - opened;

    final latest = _reports.isEmpty ? null : _reports.first;
    final recent = _reports.skip(1).take(3).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Text(
            'Welcome${auth.userEmail != null ? ', ${auth.userEmail}' : ''}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _calculated == null
                ? 'Upload a report to calculate bonuses.'
                : 'Figures below are from your latest calculated report: ${_calculated!.fileName}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
          const SizedBox(height: AppSpacing.md),

          // --- Summary cards -------------------------------------------
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900
                  ? 6
                  : constraints.maxWidth >= 560
                      ? 3
                      : 2;
              final tiles = [
                _SummaryTile(
                  label: 'Total Reports',
                  value: '${_reports.length}',
                  icon: Icons.folder_copy_outlined,
                  color: AppTheme.navy,
                ),
                _SummaryTile(
                  label: 'Users Processed',
                  value: '$usersProcessed',
                  icon: Icons.groups_outlined,
                  color: AppTheme.blue,
                ),
                _SummaryTile(
                  label: 'Total Loss',
                  value: Formatters.points(totalLoss),
                  icon: Icons.trending_down,
                  color: AppTheme.danger,
                ),
                _SummaryTile(
                  label: 'Total Payable',
                  value: Formatters.rupees(totalPayable),
                  icon: Icons.savings_outlined,
                  color: AppTheme.teal,
                ),
                _SummaryTile(
                  label: 'WhatsApp Opened',
                  value: '$opened',
                  icon: Icons.chat_bubble_outline,
                  color: AppTheme.success,
                ),
                _SummaryTile(
                  label: 'WhatsApp Pending',
                  value: '$notOpened',
                  icon: Icons.schedule_outlined,
                  color: AppTheme.warning,
                ),
              ];
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 1.3,
                children: tiles,
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),

          // --- Quick Upload action -----------------------------------
          _QuickUploadCard(onTap: () => Navigator.of(context).pushNamed(AppRoutes.upload)),
          const SizedBox(height: AppSpacing.md),

          if (latest == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.md + 4),
                child: EmptyView(
                  icon: Icons.description_outlined,
                  message: 'No report uploaded yet.\nUpload a PDF report to get started.',
                ),
              ),
            )
          else
            // --- Latest report + what to do next ----------------------
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Latest report',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.black45)),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        const Icon(Icons.description_outlined, color: AppTheme.primary),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            latest.fileName.isNotEmpty ? latest.fileName : 'Latest report',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        StatusPill.forReportStatus(ReportStatus.fromString(latest.status)),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _buildActionButton(context, latest),
                  ],
                ),
              ),
            ),

          if (recent.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text('Recent reports', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            for (final report in recent) ReportCard(report: report),
          ],
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  Widget _buildActionButton(BuildContext context, ReportSummary report) {
    final action = resolveNextAction(report.status);
    return OutlinedButton.icon(
      onPressed: () => Navigator.of(context).pushNamed(action.route, arguments: report.reportId),
      icon: Icon(action.icon),
      label: Text(action.label),
    );
  }
}

class _QuickUploadCard extends StatelessWidget {
  final VoidCallback onTap;

  const _QuickUploadCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppTheme.navy,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.upload_file_outlined, color: AppTheme.cyan),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Upload Report',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Upload a PDF report to calculate bonuses',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// One summary card in the Dashboard's overview grid. Compact by design so
/// six of them tile without leaving large empty gaps on any screen size.
class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm + 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const Spacer(),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
