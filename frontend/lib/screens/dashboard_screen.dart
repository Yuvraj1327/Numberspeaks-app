import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../models/bonus_result.dart';
import '../models/report_status.dart';
import '../repositories/auth_repository.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/status_pill.dart';

/// Screen 2 — Dashboard.
///
/// Shows the latest report this device uploaded (see LocalReportStore /
/// README for why "latest" is tracked on-device rather than fetched from
/// the backend — there is no list/latest-report endpoint), its last known
/// status, and how many of its rows have a calculated bonus so far —
/// derived from a real GET /results call, never invented.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String? _errorMessage;

  String? _reportId;
  String? _fileName;
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
      final fileName = await repo.getLastReportFileName();
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
        _fileName = fileName;
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => auth.logout(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(auth),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).pushNamed(AppRoutes.upload),
        icon: const Icon(Icons.upload_file_outlined),
        label: const Text('Upload Report'),
      ),
    );
  }

  Widget _buildBody(AuthRepository auth) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null) {
      return ErrorView(message: _errorMessage!, onRetry: _load);
    }

    final calculatedCount = _results.where((r) => r.bonusAmount != null).length;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Text(
          'Welcome${auth.userEmail != null ? ', ${auth.userEmail}' : ''}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_reportId == null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: const EmptyView(
                icon: Icons.description_outlined,
                message: 'No report uploaded yet on this device.\nUpload a PDF report to get started.',
              ),
            ),
          )
        else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.description_outlined, color: AppTheme.primary),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _fileName ?? 'Latest report',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_status != null)
                        StatusPill.forReportStatus(ReportStatus.fromString(_status)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: _StatTile(
                          label: 'Records processed',
                          value: '${_results.length}',
                        ),
                      ),
                      Expanded(
                        child: _StatTile(
                          label: 'Bonuses calculated',
                          value: '$calculatedCount',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pushNamed(AppRoutes.results, arguments: _reportId),
                    icon: const Icon(Icons.list_alt_outlined),
                    label: const Text('View Results'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;

  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54)),
      ],
    );
  }
}
