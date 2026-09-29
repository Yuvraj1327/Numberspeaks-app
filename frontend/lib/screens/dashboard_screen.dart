import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../models/bonus_result.dart';
import '../models/report_status.dart';
import '../repositories/auth_repository.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/status_pill.dart';

/// Dashboard tab — an at-a-glance overview of the latest report this
/// device uploaded (see LocalReportStore / README for why "latest" is
/// tracked on-device rather than fetched from the backend) plus quick
/// links into the Reports and Results tabs.
class DashboardScreen extends StatefulWidget {
  final void Function(int tabIndex) onSwitchTab;

  const DashboardScreen({super.key, required this.onSwitchTab});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String? _errorMessage;

  String? _reportId;
  String? _status;
  List<BonusResult> _results = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final repo = context.read<ReportRepository>();
    try {
      final reportId = await repo.getLastReportId();
      final status = await repo.getLastReportStatus();

      List<BonusResult> results = [];
      if (reportId != null) {
        try {
          results = await repo.getResults(reportId);
        } on ApiException {
          // The report may not have any results yet (e.g. upload
          // succeeded but validation hasn't run) — that's not a
          // dashboard-level error, just an empty summary.
          results = [];
        }
      }

      if (!mounted) return;
      setState(() {
        _reportId = reportId;
        _status = status;
        _results = results;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.userMessage;
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

    final calculatedCount = _results.where((r) => r.bonusAmount != null).length;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Text(
            'Welcome back${auth.userEmail != null ? ',' : ''}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
          ),
          if (auth.userEmail != null)
            Text(
              auth.userEmail!,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  icon: Icons.description_outlined,
                  color: AppTheme.primary,
                  value: '${_results.length}',
                  label: 'Records processed',
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _MetricCard(
                  icon: Icons.savings_outlined,
                  color: AppTheme.teal,
                  value: '$calculatedCount',
                  label: 'Bonuses calculated',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (_reportId == null)
            _EmptyReportCard(onUpload: () => Navigator.of(context).pushNamed(AppRoutes.upload))
          else
            _LatestReportCard(
              status: _status,
              onViewResults: () => widget.onSwitchTab(2),
              onViewReports: () => widget.onSwitchTab(1),
            ),
          const SizedBox(height: AppSpacing.lg),
          Text('Quick actions', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _QuickAction(
                  icon: Icons.upload_file_outlined,
                  label: 'Upload report',
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.upload),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _QuickAction(
                  icon: Icons.fact_check_outlined,
                  label: 'View results',
                  onTap: () => widget.onSwitchTab(2),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  const _MetricCard({required this.icon, required this.color, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _LatestReportCard extends StatelessWidget {
  final String? status;
  final VoidCallback onViewResults;
  final VoidCallback onViewReports;

  const _LatestReportCard({
    required this.status,
    required this.onViewResults,
    required this.onViewReports,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Latest report',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (status != null) StatusPill.forReportStatus(ReportStatus.fromString(status)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onViewReports,
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Reports'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onViewResults,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Results'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyReportCard extends StatelessWidget {
  final VoidCallback onUpload;

  const _EmptyReportCard({required this.onUpload});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const Icon(Icons.description_outlined, size: 40, color: AppTheme.textSecondary),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No report uploaded yet on this device.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton.icon(
              onPressed: onUpload,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Upload Report'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickAction({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md, horizontal: AppSpacing.sm),
          child: Column(
            children: [
              Icon(icon, color: AppTheme.primary),
              const SizedBox(height: AppSpacing.xs),
              Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
