import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/report_actions.dart';
import '../models/report_status.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../services/local_report_store.dart';
import '../widgets/empty_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/screen_header.dart';
import '../widgets/status_pill.dart';

/// Reports tab (embedded inside [MainShell]).
///
/// "Recent uploaded reports" is this device's own upload history (see
/// LocalReportStore — the backend has no list-reports endpoint), each with
/// its last known status and a status-appropriate continue/view action.
class ReportsTab extends StatefulWidget {
  const ReportsTab({super.key});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  bool _loading = true;
  List<LocalReportEntry> _reports = [];

  late final ReportRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = context.read<ReportRepository>()..addListener(_onRepoChanged);
    _load();
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepoChanged);
    super.dispose();
  }

  /// An upload / status change elsewhere in the app: re-read the list.
  void _onRepoChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = context.read<ReportRepository>();
    final reports = await repo.getRecentReports();
    if (!mounted) return;
    setState(() {
      _reports = reports;
      _loading = false;
    });
  }

  Future<void> _openUpload() async {
    await Navigator.of(context).pushNamed(AppRoutes.upload);
    // The upload screen may have created a new report while this tab sat
    // underneath it — refresh the list on return rather than assuming.
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
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
          const SectionTitle('Recent Reports'),
          const SizedBox(height: AppSpacing.md),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: LoadingView(),
            )
          else if (_reports.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: EmptyView(
                icon: Icons.folder_open_outlined,
                message: 'No reports uploaded yet on this device.\nUpload a PDF report to get started.',
              ),
            )
          else
            for (final report in _reports) _ReportCard(report: report),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final LocalReportEntry report;

  const _ReportCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final action = resolveNextAction(report.status);
    final dateLabel = DateFormat.yMMMd().add_jm().format(report.updatedAt);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg - 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconBadge(icon: Icons.picture_as_pdf_outlined, color: AppTheme.primary),
                  const SizedBox(width: AppSpacing.md - 2),
                  Expanded(
                    child: Text(
                      report.fileName.isNotEmpty ? report.fileName : 'Report',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  StatusPill.forReportStatus(ReportStatus.fromString(report.status)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Text(
                    dateLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (report.userCount != null) ...[
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
              if (report.status == 'completed' &&
                  report.bonusEligibleCount != null &&
                  report.totalBonus != null) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md - 2, vertical: AppSpacing.md - 4),
                  decoration: BoxDecoration(
                    color: AppTheme.teal.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '${report.bonusEligibleCount} of ${report.userCount ?? report.bonusEligibleCount} '
                    'user(s) bonus-eligible • ${Formatters.amount(report.totalBonus!)} total bonus',
                    style: const TextStyle(color: AppTheme.teal, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context)
                      .pushNamed(action.route, arguments: report.reportId),
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
