import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/report_actions.dart';
import '../models/bonus_result.dart';
import '../models/report_status.dart';
import '../repositories/auth_repository.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../services/activity_log_store.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/screen_header.dart';
import '../widgets/status_pill.dart';

/// Dashboard tab (embedded inside [MainShell] — no Scaffold/AppBar of its
/// own, those are shared across every tab).
///
/// Two kinds of data feed this screen, both real:
///  - The device's own upload history ([LocalReportStore]) — how many
///    reports this device has uploaded ("Total Reports") and its activity
///    log ("Recent activity"). See README for why this is on-device only
///    (no backend "list reports" endpoint).
///  - The most recently touched report's actual results (a real
///    `GET /results` call) — everything else (Users Processed, Total
///    Loss, Total Bonus, WhatsApp Sent/Pending) is computed from that
///    report's real rows, never invented or estimated.
class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  bool _loading = true;
  String? _errorMessage;

  String? _reportId;
  String? _fileName;
  String? _status;
  List<BonusResult> _results = [];
  int _totalReports = 0;
  List<ActivityEntry> _activity = [];

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

  /// A report finished or was uploaded elsewhere in the app: reload.
  void _onRepoChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final repo = context.read<ReportRepository>();
    try {
      // The newest report that the backend still has for this account. A
      // report it says doesn't exist is dropped from the list by the
      // repository, so the next pass moves on to the following one.
      var reports = await repo.getRecentReports();
      List<BonusResult> results = [];
      while (reports.isNotEmpty) {
        try {
          results = await repo.getResults(reports.first.reportId);
          break;
        } on ApiException catch (e) {
          if (e.kind == ApiErrorKind.notFound) {
            final before = reports.length;
            reports = await repo.getRecentReports();
            if (reports.length < before) continue; // the missing one was dropped
          }
          // The report may not have any results yet (e.g. upload
          // succeeded but validation hasn't run) — that's not a
          // dashboard-level error, just an empty summary.
          results = [];
          break;
        }
      }
      final activity = await repo.getRecentActivity(limit: 5);
      final reportId = reports.isEmpty ? null : reports.first.reportId;
      final fileName = reports.isEmpty ? null : reports.first.fileName;
      final status = reports.isEmpty ? null : reports.first.status;

      if (!mounted) return;
      setState(() {
        _reportId = reportId;
        _fileName = fileName;
        _status = status;
        _results = results;
        _totalReports = reports.length;
        _activity = activity;
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

    // --- Figures derived from the latest report's real results ----------
    final usersProcessed = _results.length;
    final totalLoss = _results
        .where((r) => r.profitLoss < 0)
        .fold<double>(0, (sum, r) => sum + r.profitLoss.abs());
    final totalBonus = _results.fold<double>(0, (sum, r) => sum + (r.bonusAmount ?? 0));
    final bonusEligible = _results.where((r) => r.bonusAmount != null).toList();
    final whatsAppSent = bonusEligible.where((r) {
      final status = _resolveWhatsAppStatus(context, r);
      return status == 'sent' || status == 'skipped_already_sent';
    }).length;
    final whatsAppPending = bonusEligible.length - whatsAppSent;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.lg),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ScreenHeader(
            eyebrow: 'Hello 👋',
            title: _displayName(auth.userEmail),
          ),
          const SizedBox(height: AppSpacing.lg),

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
                  value: '$_totalReports',
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
                  label: 'Total Bonus',
                  value: Formatters.amount(totalBonus),
                  icon: Icons.savings_outlined,
                  color: AppTheme.teal,
                ),
                _SummaryTile(
                  label: 'WhatsApp Sent',
                  value: '$whatsAppSent',
                  icon: Icons.chat_bubble_outline,
                  color: AppTheme.success,
                ),
                _SummaryTile(
                  label: 'WhatsApp Pending',
                  value: '$whatsAppPending',
                  icon: Icons.schedule_outlined,
                  color: AppTheme.warning,
                ),
              ];
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 1.08,
                children: tiles,
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),

          // --- Quick Upload action -----------------------------------
          const SectionTitle('Quick Actions'),
          const SizedBox(height: AppSpacing.md),
          _QuickUploadCard(onTap: () => Navigator.of(context).pushNamed(AppRoutes.upload)),
          const SizedBox(height: AppSpacing.md),

          if (_reportId == null)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.md + 4),
                child: const EmptyView(
                  icon: Icons.description_outlined,
                  message: 'No report uploaded yet on this device.\nUpload a PDF report to get started.',
                ),
              ),
            )
          else
            // --- Latest report + current processing status ------------
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg - 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('LATEST REPORT',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                    const SizedBox(height: AppSpacing.sm + 2),
                    Row(
                      children: [
                        const IconBadge(icon: Icons.description_outlined, color: AppTheme.primary),
                        const SizedBox(width: AppSpacing.md - 2),
                        Expanded(
                          child: Text(
                            _fileName?.isNotEmpty == true ? _fileName! : 'Latest report',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_status != null)
                          StatusPill.forReportStatus(ReportStatus.fromString(_status)),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _buildActionButton(context),
                  ],
                ),
              ),
            ),

          const SizedBox(height: AppSpacing.md),
          const SectionTitle('Recent activity'),
          const SizedBox(height: AppSpacing.md),
          if (_activity.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.md + 4),
                child: const EmptyView(
                  icon: Icons.history,
                  message: 'Actions you take — uploading, processing, calculating '
                      'bonuses, sending WhatsApp messages — will show up here.',
                ),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < _activity.length; i++)
                    _ActivityLogRow(
                      entry: _activity[i],
                      isLast: i == _activity.length - 1,
                    ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  String _resolveWhatsAppStatus(BuildContext context, BonusResult result) {
    final raw = context.read<ReportRepository>().sessionWhatsAppStatusFor(_reportId!, result.bonusResultId) ??
        result.whatsappStatus;
    return result.displayWhatsAppStatus(raw);
  }

  /// Friendly display name from the login email ("driver2@x.com" -> "driver2").
  String _displayName(String? email) {
    if (email == null || email.isEmpty) return 'Welcome';
    final at = email.indexOf('@');
    return at > 0 ? email.substring(0, at) : email;
  }

  Widget _buildActionButton(BuildContext context) {
    final action = resolveNextAction(_status);
    return OutlinedButton.icon(
      onPressed: () => Navigator.of(context).pushNamed(action.route, arguments: _reportId),
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
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg - 4),
          child: Row(
            children: [
              const IconBadge(icon: Icons.upload_file_outlined, color: AppTheme.blue, size: 56),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Upload Report',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontSize: 19, fontWeight: FontWeight.w900, color: AppTheme.navy),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Upload a PDF report to calculate bonuses',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, color: AppTheme.blue, size: 26),
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
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconBadge(icon: icon, color: color, size: 42),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.navy,
                    ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 14, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the "Recent activity" feed — a real action this device took
/// (see [ActivityLogStore]), not a per-user list.
class _ActivityLogRow extends StatelessWidget {
  final ActivityEntry entry;
  final bool isLast;

  const _ActivityLogRow({required this.entry, required this.isLast});

  IconData get _icon {
    switch (entry.type) {
      case ActivityType.reportUploaded:
        return Icons.upload_file_outlined;
      case ActivityType.reportProcessed:
        return Icons.fact_check_outlined;
      case ActivityType.bonusCalculated:
        return Icons.savings_outlined;
      case ActivityType.whatsappSent:
        return Icons.chat_bubble_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeLabel = DateFormat.MMMd().add_jm().format(entry.timestamp);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md - 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(icon: _icon, color: AppTheme.primary, size: 40),
              const SizedBox(width: AppSpacing.md - 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.type.label,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Text(
                          timeLabel,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                    if (entry.fileName != null && entry.fileName!.isNotEmpty)
                      Text(
                        entry.fileName!,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (entry.detail != null && entry.detail!.isNotEmpty)
                      Text(
                        entry.detail!,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1),
      ],
    );
  }
}
