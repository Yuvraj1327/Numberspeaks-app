import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/bonus_result.dart';
import '../repositories/report_repository.dart';
import '../routing/app_router.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/status_pill.dart';

enum _SortOption { nameAsc, nameDesc, bonusHighLow, bonusLowHigh }

/// Results tab — bonus results for the device's latest report (see
/// LocalReportStore/README — the backend has no "list reports" endpoint,
/// only per-report GET /results). Also hosts the report-wide "Send
/// WhatsApp" action (POST /send-whatsapp) — the backend only exposes a
/// per-report send, not a per-user one, so that action lives here rather
/// than on the User Detail screen (see README "known backend gaps").
class ResultsScreen extends StatefulWidget {
  final void Function(int tabIndex) onSwitchTab;

  const ResultsScreen({super.key, required this.onSwitchTab});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  bool _loading = true;
  String? _errorMessage;
  String? _reportId;
  List<BonusResult> _results = [];
  String _query = '';
  _SortOption _sort = _SortOption.nameAsc;
  bool _sendingWhatsApp = false;

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
      List<BonusResult> results = [];
      if (reportId != null) {
        results = await repo.getResults(reportId);
      }
      if (!mounted) return;
      setState(() {
        _reportId = reportId;
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

  List<BonusResult> get _filteredSorted {
    var list = _results.where((r) {
      if (_query.trim().isEmpty) return true;
      return r.userName.toLowerCase().contains(_query.trim().toLowerCase());
    }).toList();

    switch (_sort) {
      case _SortOption.nameAsc:
        list.sort((a, b) => a.userName.toLowerCase().compareTo(b.userName.toLowerCase()));
        break;
      case _SortOption.nameDesc:
        list.sort((a, b) => b.userName.toLowerCase().compareTo(a.userName.toLowerCase()));
        break;
      case _SortOption.bonusHighLow:
        list.sort((a, b) => (b.bonusAmount ?? -1).compareTo(a.bonusAmount ?? -1));
        break;
      case _SortOption.bonusLowHigh:
        list.sort((a, b) => (a.bonusAmount ?? -1).compareTo(b.bonusAmount ?? -1));
        break;
    }
    return list;
  }

  Future<void> _sendWhatsApp() async {
    final reportId = _reportId;
    if (reportId == null) return;

    setState(() => _sendingWhatsApp = true);
    final repo = context.read<ReportRepository>();
    try {
      final summary = await repo.sendWhatsApp(reportId);
      if (!mounted) return;
      setState(() => _sendingWhatsApp = false);
      _showWhatsAppSummary(summary.sentCount, summary.failedCount, summary.skippedCount);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _sendingWhatsApp = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage), backgroundColor: AppTheme.danger),
      );
    }
  }

  void _showWhatsAppSummary(int sent, int failed, int skipped) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('WhatsApp Messages Sent'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sent: $sent', style: const TextStyle(color: AppTheme.success)),
            Text('Failed: $failed', style: const TextStyle(color: AppTheme.danger)),
            Text('Skipped: $skipped', style: const TextStyle(color: AppTheme.warning)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null) {
      return ErrorView(message: _errorMessage!, onRetry: _load);
    }

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
      child: Text(
        'Bonus Results',
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
    );

    if (_reportId == null) {
      return Column(
        children: [
          Align(alignment: Alignment.centerLeft, child: header),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 80),
                  const EmptyView(
                    icon: Icons.fact_check_outlined,
                    message: 'No report uploaded yet.\nUpload a report from the Reports tab to see results here.',
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.md),
                      child: OutlinedButton.icon(
                        onPressed: () => widget.onSwitchTab(1),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Go to Reports'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_results.isEmpty) {
      return Column(
        children: [
          Align(alignment: Alignment.centerLeft, child: header),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  EmptyView(message: 'No bonus results yet for this report.'),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final visible = _filteredSorted;
    final reportId = _reportId!;

    return Column(
      children: [
        Align(alignment: Alignment.centerLeft, child: header),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search by name',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              PopupMenuButton<_SortOption>(
                icon: const Icon(Icons.sort),
                initialValue: _sort,
                onSelected: (value) => setState(() => _sort = value),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: _SortOption.nameAsc, child: Text('Name (A-Z)')),
                  PopupMenuItem(value: _SortOption.nameDesc, child: Text('Name (Z-A)')),
                  PopupMenuItem(value: _SortOption.bonusHighLow, child: Text('Bonus (high-low)')),
                  PopupMenuItem(value: _SortOption.bonusLowHigh, child: Text('Bonus (low-high)')),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _sendingWhatsApp ? null : _sendWhatsApp,
              icon: _sendingWhatsApp
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(_sendingWhatsApp ? 'Sending…' : 'Send Bonus via WhatsApp'),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: visible.isEmpty
              ? const EmptyView(message: 'No users match your search.', icon: Icons.search_off)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) => _ResultCard(
                      result: visible[index],
                      // The session cache (if a send just happened) can be
                      // more specific than the backend's own latest-status
                      // field; otherwise fall back to that durable value
                      // from GET /results, which is always present.
                      whatsAppStatus: context
                              .read<ReportRepository>()
                              .sessionWhatsAppStatusFor(reportId, visible[index].bonusResultId) ??
                          visible[index].whatsappStatus,
                      onTap: () => Navigator.of(context).pushNamed(
                        AppRoutes.userDetail,
                        arguments: UserDetailArgs(
                          reportId: reportId,
                          initialResult: visible[index],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  final BonusResult result;
  final String? whatsAppStatus;
  final VoidCallback onTap;

  const _ResultCard({required this.result, required this.whatsAppStatus, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      result.userName,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (whatsAppStatus != null) StatusPill.forWhatsAppStatus(whatsAppStatus!),
                ],
              ),
              if (result.level != null) ...[
                const SizedBox(height: 2),
                Text(
                  'Level: ${result.level}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                'WhatsApp: ${result.whatsappNumber ?? 'Not on file'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Profit/Loss: ${Formatters.points(result.profitLoss)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    result.bonusAmount != null
                        ? 'Bonus: ${Formatters.amount(result.bonusAmount!)}'
                        : 'Bonus: —',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: result.bonusAmount != null ? AppTheme.success : Colors.black38,
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
