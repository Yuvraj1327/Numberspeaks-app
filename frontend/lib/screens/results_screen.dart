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
import '../widgets/screen_header.dart';
import '../widgets/status_pill.dart';

enum _SortOption { nameAsc, nameDesc, bonusHighLow, bonusLowHigh }

/// The four filters asked for in the UI brief. "Bonus" / "No Bonus" filter
/// on whether a bonus amount was actually calculated and owed; "Profit" /
/// "Loss" filter on the sign of the real `profit_loss` figure — both
/// derived straight from each row's own data, nothing inferred beyond that.
enum _FilterOption { all, bonus, noBonus, profit, loss }

extension on _FilterOption {
  String get label {
    switch (this) {
      case _FilterOption.all:
        return 'All';
      case _FilterOption.bonus:
        return 'Bonus';
      case _FilterOption.noBonus:
        return 'No Bonus';
      case _FilterOption.profit:
        return 'Profit';
      case _FilterOption.loss:
        return 'Loss';
    }
  }

  bool matches(BonusResult r) {
    switch (this) {
      case _FilterOption.all:
        return true;
      case _FilterOption.bonus:
        return r.bonusAmount != null && r.bonusAmount! > 0;
      case _FilterOption.noBonus:
        return r.bonusAmount == null || r.bonusAmount == 0;
      case _FilterOption.profit:
        return r.profitLoss > 0;
      case _FilterOption.loss:
        return r.profitLoss < 0;
    }
  }
}

/// Screen 5 — Bonus Results, as a full pushed screen for a specific report
/// (e.g. from the Reports tab's history, or right after processing).
/// The Results *tab* wraps the same [_ResultsBody] — see [ResultsTab] below
/// — so the search/sort/send-WhatsApp logic exists in exactly one place.
class ResultsScreen extends StatelessWidget {
  final String reportId;

  const ResultsScreen({super.key, required this.reportId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bonus Results')),
      body: _ResultsBody(reportId: reportId),
    );
  }
}

/// Results tab (embedded inside [MainShell]) — shows results for this
/// device's most recently touched report (see LocalReportStore/README:
/// there is no "list all reports" backend endpoint), with an honest empty
/// state when nothing has been uploaded yet rather than showing nothing.
class ResultsTab extends StatefulWidget {
  const ResultsTab({super.key});

  @override
  State<ResultsTab> createState() => _ResultsTabState();
}

class _ResultsTabState extends State<ResultsTab> {
  bool _loading = true;
  String? _reportId;

  @override
  void initState() {
    super.initState();
    _resolveReport();
  }

  Future<void> _resolveReport() async {
    setState(() => _loading = true);
    final reportId = await context.read<ReportRepository>().getLastReportId();
    if (!mounted) return;
    setState(() {
      _reportId = reportId;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_reportId == null) {
      return RefreshIndicator(
        onRefresh: _resolveReport,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: const [
            ScreenHeader(eyebrow: 'Bonus overview', title: 'Results'),
            SizedBox(height: 80),
            EmptyView(
              icon: Icons.bar_chart_outlined,
              message: 'No results yet.\nUpload and process a report to see bonus results here.',
            ),
          ],
        ),
      );
    }
    return _ResultsBody(reportId: _reportId!, showHeader: true);
  }
}

class _ResultsBody extends StatefulWidget {
  final String reportId;

  /// True when embedded as the Results tab (which has no AppBar of its own).
  final bool showHeader;

  const _ResultsBody({required this.reportId, this.showHeader = false});

  @override
  State<_ResultsBody> createState() => _ResultsBodyState();
}

class _ResultsBodyState extends State<_ResultsBody> {
  bool _loading = true;
  String? _errorMessage;
  List<BonusResult> _results = [];
  String _query = '';
  _SortOption _sort = _SortOption.nameAsc;
  _FilterOption _filter = _FilterOption.all;
  bool _sendingWhatsApp = false;
  bool _retrying = false;

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
      final results = await repo.getResults(widget.reportId);
      if (!mounted) return;
      setState(() {
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
      if (!_filter.matches(r)) return false;
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
    setState(() => _sendingWhatsApp = true);
    final repo = context.read<ReportRepository>();
    try {
      final summary = await repo.sendWhatsApp(widget.reportId);
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

  /// "Retry" for a failed/pending WhatsApp message. There is no per-user
  /// send endpoint (see README "known gaps") — only a report-wide one,
  /// which already skips anyone already sent and only (re)attempts
  /// pending/failed numbers. So Retry calls that same endpoint again; the
  /// snackbar says exactly that rather than implying a single-user resend.
  Future<void> _retryWhatsApp() async {
    setState(() => _retrying = true);
    final repo = context.read<ReportRepository>();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Retrying WhatsApp for pending/failed users on this report…')),
    );
    try {
      final summary = await repo.sendWhatsApp(widget.reportId);
      if (!mounted) return;
      setState(() => _retrying = false);
      _showWhatsAppSummary(summary.sentCount, summary.failedCount, summary.skippedCount);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _retrying = false);
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
    if (_results.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: widget.showHeader ? const EdgeInsets.all(AppSpacing.lg) : EdgeInsets.zero,
          children: [
            if (widget.showHeader)
              const ScreenHeader(eyebrow: 'Bonus overview', title: 'Results'),
            const SizedBox(height: 120),
            const EmptyView(message: 'No bonus results yet for this report.'),
          ],
        ),
      );
    }

    final visible = _filteredSorted;

    return Column(
      children: [
        if (widget.showHeader)
          const Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
            child: ScreenHeader(eyebrow: 'Bonus overview', title: 'Results'),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search by name',
                    prefixIcon: Icon(Icons.search_rounded, color: AppTheme.navy),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              PopupMenuButton<_SortOption>(
                icon: const Icon(Icons.sort_rounded, color: AppTheme.navy, size: 28),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: AppTheme.hairline),
                  fixedSize: const Size(52, 52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
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
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            itemCount: _FilterOption.values.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final option = _FilterOption.values[index];
              final selected = option == _filter;
              return ChoiceChip(
                label: Text(option.label),
                selected: selected,
                onSelected: (_) => setState(() => _filter = option),
                showCheckmark: false,
                selectedColor: AppTheme.navy,
                side: BorderSide(color: selected ? AppTheme.navy : AppTheme.hairline),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                labelStyle: TextStyle(
                  fontSize: 14.5,
                  color: selected ? Colors.white : AppTheme.navy,
                  fontWeight: FontWeight.w800,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
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
        const SizedBox(height: AppSpacing.xs),
        Expanded(
          child: visible.isEmpty
              ? const EmptyView(message: 'No users match your search.', icon: Icons.search_off)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 720;
                    return RefreshIndicator(
                      onRefresh: _load,
                      child: wide
                          ? _ResultsTable(
                              results: visible,
                              reportId: widget.reportId,
                              onTapResult: _openDetail,
                              onRetry: _retrying ? null : _retryWhatsApp,
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.all(AppSpacing.lg),
                              itemCount: visible.length,
                              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
                              itemBuilder: (context, index) => _ResultCard(
                                result: visible[index],
                                whatsAppStatus: _resolveWhatsAppStatus(context, visible[index]),
                                onTap: () => _openDetail(visible[index]),
                                onRetry: _retrying ? null : _retryWhatsApp,
                              ),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// The session cache (if a send just happened) can be more specific than
  /// the backend's own latest-status field; otherwise fall back to that
  /// durable value from GET /results, which is always present. Then
  /// normalized for display (see [BonusResult.displayWhatsAppStatus]) so a
  /// user with no WhatsApp number on file always reads "No Number".
  String _resolveWhatsAppStatus(BuildContext context, BonusResult result) {
    final raw = context
            .read<ReportRepository>()
            .sessionWhatsAppStatusFor(widget.reportId, result.bonusResultId) ??
        result.whatsappStatus;
    return result.displayWhatsAppStatus(raw);
  }

  void _openDetail(BonusResult result) {
    Navigator.of(context).pushNamed(
      AppRoutes.userDetail,
      arguments: UserDetailArgs(reportId: widget.reportId, initialResult: result),
    );
  }
}

/// Compact card layout for narrow (phone) widths — the same
/// "User Name | Profit/Loss | Bonus | WhatsApp Status" fields the wide
/// table shows, stacked instead of columned. A Retry action appears when
/// this user's WhatsApp message is failed or still pending.
class _ResultCard extends StatelessWidget {
  final BonusResult result;
  final String? whatsAppStatus;
  final VoidCallback onTap;
  final VoidCallback? onRetry;

  const _ResultCard({
    required this.result,
    required this.whatsAppStatus,
    required this.onTap,
    this.onRetry,
  });

  bool get _canRetry => whatsAppStatus == 'failed' || whatsAppStatus == 'not_sent';

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg - 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppTheme.blue.withOpacity(0.12),
                    child: Text(
                      result.userName.isNotEmpty ? result.userName[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: AppTheme.blue, fontSize: 18, fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md - 2),
                  Expanded(
                    child: Text(
                      result.userName,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (whatsAppStatus != null) StatusPill.forWhatsAppStatus(whatsAppStatus!),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Profit/Loss', style: Theme.of(context).textTheme.labelSmall),
                      const SizedBox(height: 2),
                      Text(
                        Formatters.points(result.profitLoss),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: result.profitLoss < 0 ? AppTheme.danger : AppTheme.navy,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Bonus', style: Theme.of(context).textTheme.labelSmall),
                      const SizedBox(height: 2),
                      Text(
                        result.bonusAmount != null ? Formatters.amount(result.bonusAmount!) : '—',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                          color: result.bonusAmount != null ? AppTheme.teal : AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (_canRetry && onRetry != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Table layout for wide (tablet/desktop/web) widths — the exact
/// "User Name | Profit/Loss | Bonus | WhatsApp Status" columns asked for,
/// as literal columns rather than a stacked card, plus a Retry action for
/// any row whose WhatsApp message is failed or still pending.
class _ResultsTable extends StatelessWidget {
  final List<BonusResult> results;
  final String reportId;
  final void Function(BonusResult) onTapResult;
  final VoidCallback? onRetry;

  const _ResultsTable({
    required this.results,
    required this.reportId,
    required this.onTapResult,
    this.onRetry,
  });

  static const _nameFlex = 4;
  static const _plFlex = 2;
  static const _bonusFlex = 2;
  static const _statusFlex = 3;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.sm),
            child: Row(
              children: [
                _headerCell('User Name', _nameFlex),
                _headerCell('Profit/Loss', _plFlex),
                _headerCell('Bonus', _bonusFlex),
                _headerCell('WhatsApp Status', _statusFlex),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: results.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final result = results[index];
                final rawStatus = context
                        .read<ReportRepository>()
                        .sessionWhatsAppStatusFor(reportId, result.bonusResultId) ??
                    result.whatsappStatus;
                final whatsAppStatus = result.displayWhatsAppStatus(rawStatus);
                final canRetry = whatsAppStatus == 'failed' || whatsAppStatus == 'not_sent';
                return InkWell(
                  onTap: () => onTapResult(result),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.sm),
                    child: Row(
                      children: [
                        Expanded(
                          flex: _nameFlex,
                          child: Text(
                            result.userName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                          ),
                        ),
                        Expanded(
                          flex: _plFlex,
                          child: Text(
                            Formatters.points(result.profitLoss),
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: result.profitLoss < 0 ? AppTheme.danger : AppTheme.navy,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: _bonusFlex,
                          child: Text(
                            result.bonusAmount != null ? Formatters.amount(result.bonusAmount!) : '—',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w900,
                              color: result.bonusAmount != null ? AppTheme.teal : AppTheme.textMuted,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: _statusFlex,
                          child: Row(
                            children: [
                              StatusPill.forWhatsAppStatus(whatsAppStatus),
                              if (canRetry && onRetry != null) ...[
                                const SizedBox(width: 6),
                                InkWell(
                                  onTap: onRetry,
                                  borderRadius: BorderRadius.circular(20),
                                  child: const Padding(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(Icons.refresh, size: 16, color: AppTheme.primary),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCell(String label, int flex) {
    return Expanded(
      flex: flex,
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: AppTheme.textMuted,
        ),
      ),
    );
  }
}
