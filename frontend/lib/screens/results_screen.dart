import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/responsive.dart';
import '../core/formatters.dart';
import '../core/whatsapp_link.dart';
import '../models/bonus_result.dart';
import '../models/report_status.dart';
import '../models/report_summary.dart';
import '../repositories/report_repository.dart';
import '../routing/app_router.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/grid_table.dart';
import '../widgets/loading_view.dart';
import '../widgets/screen_header.dart';
import '../widgets/status_pill.dart';
import '../widgets/whatsapp_bulk_dialog.dart';
import '../widgets/whatsapp_message_dialog.dart';
import '../widgets/whatsapp_number_dialog.dart';

enum _SortOption { nameAsc, nameDesc, payableHighLow, payableLowHigh }

/// Filters over the table. Each one is derived straight from the row's own
/// saved figures — nothing is inferred beyond that.
enum _FilterOption { all, payable, noPayable, carried, profit, loss, noNumber }

extension on _FilterOption {
  String get label {
    switch (this) {
      case _FilterOption.all:
        return 'All';
      case _FilterOption.payable:
        return 'Payable';
      case _FilterOption.noPayable:
        return 'Nothing payable';
      case _FilterOption.carried:
        return 'Carried forward';
      case _FilterOption.profit:
        return 'Profit';
      case _FilterOption.loss:
        return 'Loss';
      case _FilterOption.noNumber:
        return 'No number';
    }
  }

  bool matches(BonusResult r) {
    switch (this) {
      case _FilterOption.all:
        return true;
      case _FilterOption.payable:
        return r.hasPayableBonus;
      case _FilterOption.noPayable:
        return r.isCalculated && r.payable <= 0;
      case _FilterOption.carried:
        return (r.carryForwardBalance ?? 0) < 0;
      case _FilterOption.profit:
        return r.profitLoss > 0;
      case _FilterOption.loss:
        return r.profitLoss < 0;
      case _FilterOption.noNumber:
        return !r.hasWhatsAppNumber;
    }
  }
}

/// A pushed Results screen for one specific report (for example straight
/// after calculating, or from the Reports tab).
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

const _tabHeader = Padding(
  padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
  child: ScreenHeader(eyebrow: 'Bonus calculation', title: 'Results'),
);

/// Results tab (inside [MainShell]): a picker over this admin's report
/// history (loaded from the backend, so it is the same on every device),
/// and the results table of the selected report.
class ResultsTab extends StatefulWidget {
  const ResultsTab({super.key});

  @override
  State<ResultsTab> createState() => _ResultsTabState();
}

class _ResultsTabState extends State<ResultsTab> {
  bool _loading = true;
  String? _errorMessage;
  List<ReportSummary> _reports = [];
  String? _selectedId;
  int _seenRevision = -1;
  // The revision the results table was last told to refresh for. It only
  // advances once the report list has been reloaded, so a report that was just
  // deleted is never fetched (404) before the selection moves off it.
  int _bodyRevision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision = context.watch<ReportRepository>().structureRevision;
    if (revision != _seenRevision) {
      final first = _seenRevision == -1;
      _seenRevision = revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadReports(silent: !first);
      });
    }
  }

  Future<void> _loadReports({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final reports = await context.read<ReportRepository>().listReports();
      if (!mounted) return;
      String? selected = _selectedId;
      if (selected == null || !reports.any((r) => r.reportId == selected)) {
        // Newest completed report if there is one, else simply the newest.
        final completed = reports.where((r) => r.isCompleted);
        selected = completed.isNotEmpty
            ? completed.first.reportId
            : (reports.isEmpty ? null : reports.first.reportId);
      }
      setState(() {
        _reports = reports;
        _selectedId = selected;
        _bodyRevision = _seenRevision;
        _loading = false;
        _errorMessage = null;
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
    if (_loading || _errorMessage != null) {
      return Column(
        children: [
          _tabHeader,
          Expanded(
            child: _loading
                ? const LoadingView()
                : ErrorView(message: _errorMessage!, onRetry: _loadReports),
          ),
        ],
      );
    }
    if (_selectedId == null) {
      return RefreshIndicator(
        onRefresh: _loadReports,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            _tabHeader,
            SizedBox(height: 100),
            EmptyView(
              icon: Icons.bar_chart_outlined,
              message: 'No results yet.\nUpload and process a report to see bonus results here.',
            ),
          ],
        ),
      );
    }

    final revision = _bodyRevision;
    return Column(
      children: [
        _tabHeader,
        _ReportPicker(
          reports: _reports,
          selectedId: _selectedId!,
          onSelected: (id) => setState(() => _selectedId = id),
        ),
        Expanded(
          child: _ResultsBody(
            key: ValueKey(_selectedId),
            reportId: _selectedId!,
            refreshToken: revision,
          ),
        ),
      ],
    );
  }
}

/// The report history selector: shows the chosen report and opens a list of
/// every report this admin has uploaded.
class _ReportPicker extends StatelessWidget {
  final List<ReportSummary> reports;
  final String selectedId;
  final ValueChanged<String> onSelected;

  const _ReportPicker({
    required this.reports,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final selected = reports.firstWhere(
      (r) => r.reportId == selectedId,
      orElse: () => reports.first,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
      child: PopupMenuButton<String>(
        tooltip: 'Report history',
        onSelected: onSelected,
        position: PopupMenuPosition.under,
        itemBuilder: (context) => [
          for (final report in reports)
            PopupMenuItem<String>(
              value: report.reportId,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          report.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          Formatters.dateTime(report.uploadedAt),
                          style: const TextStyle(fontSize: 11.5, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  StatusPill.forReportStatus(ReportStatus.fromString(report.status)),
                ],
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: AppTheme.hairline),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              const Icon(Icons.history, size: 20, color: AppTheme.blue),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${Formatters.dateTime(selected.uploadedAt)} • ${reports.length} report(s) in history',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: Colors.black54),
                    ),
                  ],
                ),
              ),
              StatusPill.forReportStatus(ReportStatus.fromString(selected.status)),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultsBody extends StatefulWidget {
  final String reportId;

  /// Changes whenever report data was modified elsewhere in the app; the
  /// body then reloads quietly (without a spinner).
  final int refreshToken;

  const _ResultsBody({super.key, required this.reportId, this.refreshToken = 0});

  @override
  State<_ResultsBody> createState() => _ResultsBodyState();
}

class _ResultsBodyState extends State<_ResultsBody> {
  static const _columns = [
    GridColumn('User ID / Name', 210),
    GridColumn('Profit / Loss', 110, numeric: true),
    GridColumn('Personal bonus / adjustment', 130, numeric: true),
    GridColumn('Referral bonus / adjustment', 130, numeric: true),
    GridColumn('Previous balance', 120, numeric: true),
    GridColumn('Final payable bonus', 140, numeric: true),
    GridColumn('WhatsApp number', 190),
    GridColumn('WhatsApp send', 190),
    GridColumn('Edit', 90),
  ];

  bool _loading = true;
  String? _errorMessage;
  List<BonusResult> _results = [];
  ReportSummary? _report;
  String _query = '';
  _SortOption _sort = _SortOption.payableHighLow;
  _FilterOption _filter = _FilterOption.all;
  final Set<String> _selected = {};
  // Only the newest load may update the screen: a slower, older response
  // (e.g. a quiet refresh overtaken by a manual reload) must not overwrite it.
  int _loadId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ResultsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    final loadId = ++_loadId;
    if (!silent) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    final repo = context.read<ReportRepository>();
    try {
      final fetched = await Future.wait([
        repo.getResults(widget.reportId),
        repo.getReport(widget.reportId),
      ]);
      final results = fetched[0] as List<BonusResult>;
      final report = fetched[1] as ReportSummary;
      if (!mounted || loadId != _loadId) return;
      setState(() {
        _results = results;
        _report = report;
        _loading = false;
        _errorMessage = null;
      });
    } on ApiException catch (e) {
      if (!mounted || loadId != _loadId) return;
      setState(() {
        // A failed quiet refresh keeps showing what is already on screen.
        if (!silent || _results.isEmpty) _errorMessage = e.userMessage;
        _loading = false;
      });
    }
  }

  List<BonusResult> get _filteredSorted {
    final q = _query.trim().toLowerCase();
    final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
    final list = _results.where((r) {
      if (!_filter.matches(r)) return false;
      if (q.isEmpty) return true;
      if (r.userName.toLowerCase().contains(q)) return true;
      return digits.isNotEmpty && (r.whatsappNumber ?? '').contains(digits);
    }).toList();

    switch (_sort) {
      case _SortOption.nameAsc:
        list.sort((a, b) => a.userName.toLowerCase().compareTo(b.userName.toLowerCase()));
        break;
      case _SortOption.nameDesc:
        list.sort((a, b) => b.userName.toLowerCase().compareTo(a.userName.toLowerCase()));
        break;
      case _SortOption.payableHighLow:
        list.sort((a, b) => b.payable.compareTo(a.payable));
        break;
      case _SortOption.payableLowHigh:
        list.sort((a, b) => a.payable.compareTo(b.payable));
        break;
    }
    return list;
  }

  void _replace(BonusResult updated) {
    final index = _results.indexWhere((r) => r.bonusResultId == updated.bonusResultId);
    if (index != -1) _results[index] = updated;
  }

  Future<void> _editNumber(BonusResult result) async {
    final repo = context.read<ReportRepository>();
    final saved = await showWhatsAppNumberDialog(
      context,
      userName: result.userName,
      currentNumber: result.whatsappNumber,
      onSave: (number) async {
        final updated = await repo.saveWhatsAppNumber(result.userId, number);
        return updated.whatsappNumber;
      },
    );
    if (saved == null || !mounted) return;
    setState(() {
      _replace(result.copyWith(whatsappNumber: saved, clearWhatsAppNumber: saved.isEmpty));
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(saved.isEmpty ? 'WhatsApp number removed.' : 'WhatsApp number saved.')),
    );
  }

  Future<void> _sendWhatsApp(BonusResult result) async {
    final outcome = await showWhatsAppMessageDialog(context, result: result);
    if (outcome == null || !mounted) return;
    if (outcome.result != null) setState(() => _replace(outcome.result!));
    // The server may know better than the screen (e.g. a send already in flight).
    if (outcome.refresh) _load(silent: true);
  }

  /// Can be picked for a bulk send: payable, has a usable number, and not
  /// already Sent / being sent. (Failed and Unknown ones are picked on purpose
  /// to retry them.)
  bool _selectable(BonusResult r) =>
      r.hasPayableBonus &&
      WhatsAppLink.isUsableNumber(r.whatsappNumber ?? '') &&
      !r.isSent &&
      !r.isSending;

  List<BonusResult> get _selectedResults =>
      _results.where((r) => _selected.contains(r.bonusResultId) && _selectable(r)).toList();

  /// "All eligible" = never attempted. Failed/Unknown are never swept in
  /// automatically: they are retried only by selecting them.
  List<BonusResult> get _allEligible =>
      _results.where((r) => _selectable(r) && r.sendStatus == 'pending').toList();

  List<BulkSkipPreview> _skippedPreview(Iterable<BonusResult> pool) {
    final out = <BulkSkipPreview>[];
    for (final r in pool) {
      if (!r.hasPayableBonus || r.isSent) continue;
      if (!r.hasWhatsAppNumber) {
        out.add(BulkSkipPreview(r.userName, 'No WhatsApp number saved.'));
      } else if (!WhatsAppLink.isUsableNumber(r.whatsappNumber ?? '')) {
        out.add(BulkSkipPreview(r.userName, 'The saved number is not valid.'));
      }
    }
    return out;
  }

  Future<void> _bulkSend({required bool all}) async {
    final targets = all ? _allEligible : _selectedResults;
    final skipped = _skippedPreview(
        all ? _results : _results.where((r) => _selected.contains(r.bonusResultId)));
    final reportId = _results.isEmpty ? null : _results.first.reportId;
    if (reportId == null) return;
    await showWhatsAppBulkDialog(
      context,
      reportId: reportId,
      title: all ? 'Send All Eligible' : 'Send Selected',
      targets: targets,
      skipped: skipped,
    );
    if (!mounted) return;
    setState(_selected.clear);
    _load(silent: true);
  }

  Widget _bulkBar() {
    final selected = _selectedResults.length;
    final eligible = _allEligible.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: selected == 0 ? null : () => _bulkSend(all: false),
            icon: const Icon(Icons.checklist, size: 18),
            label: Text('Send Selected ($selected)'),
          ),
          OutlinedButton.icon(
            onPressed: eligible == 0 ? null : () => _bulkSend(all: true),
            icon: const Icon(Icons.send_and_archive_outlined, size: 18),
            label: Text('Send All Eligible ($eligible)'),
          ),
          if (_selected.isNotEmpty)
            TextButton(
                onPressed: () => setState(_selected.clear), child: const Text('Clear selection')),
        ],
      ),
    );
  }

  Future<void> _openDetail(BonusResult result) async {
    await Navigator.of(context).pushNamed(
      AppRoutes.userDetail,
      arguments: UserDetailArgs(
        userId: result.userId,
        userName: result.userName,
        reportId: widget.reportId,
        initialResult: result,
      ),
    );
    // The detail screen can change the number / WhatsApp record.
    if (mounted) _load(silent: true);
  }

  Future<void> _openReferrals() async {
    await Navigator.of(context).pushNamed(AppRoutes.referrals, arguments: widget.reportId);
    if (mounted) _load(silent: true);
  }

  /// Calculates this report again, e.g. after changing a rate or a
  /// referral. The previous figures of this report are replaced; each run is
  /// kept in the users' calculation history.
  Future<void> _recalculate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Recalculate this report?'),
        content: const Text(
          'Every user is calculated again with your current rates and referral entries. '
          'The figures shown for this report are replaced. Each calculation is kept in the '
          'users\' history.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true), child: const Text('Recalculate')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await Navigator.of(context).pushNamed(AppRoutes.processing, arguments: widget.reportId);
    if (mounted) _load(silent: true);
  }

  Future<void> _openReview() async {
    await Navigator.of(context).pushNamed(AppRoutes.review, arguments: widget.reportId);
    if (mounted) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null) return ErrorView(message: _errorMessage!, onRetry: _load);
    if (_results.isEmpty) {
      final String message;
      switch (ReportStatus.fromString(_report?.status)) {
        case ReportStatus.uploaded:
        case ReportStatus.processing:
        case ReportStatus.validating:
        case ReportStatus.calculating:
          message = 'This report is still being processed.\nPull down to refresh.';
          break;
        case ReportStatus.failed:
          message =
              'Processing this report failed, so there are no results.\nPull down to refresh.';
          break;
        default:
          message = 'No users in this report.';
      }
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 120),
            EmptyView(message: message),
          ],
        ),
      );
    }

    final visible = _filteredSorted;
    final calculated = _report?.status == 'completed';
    // While the keyboard is up (search field) only the search row and the list
    // are kept, so a small phone isn't left with a sliver of results.
    return LayoutBuilder(builder: (context, constraints) {
      final keyboardOpen = constraints.maxHeight < Responsive.shortBodyHeight;

      return Column(
        children: [
          if (!calculated && !keyboardOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: AppTheme.warning),
                    const SizedBox(width: AppSpacing.sm),
                    const Expanded(
                      child: Text(
                        'This report has not been calculated (or was changed since). '
                        'The figures below are not final.',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    TextButton(onPressed: _openReview, child: const Text('Review & calculate')),
                  ],
                ),
              ),
            ),
          if (!keyboardOpen) _SummaryStrip(results: _results),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search by User ID / Name or number',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                PopupMenuButton<_SortOption>(
                  tooltip: 'Sort',
                  icon: const Icon(Icons.sort),
                  initialValue: _sort,
                  onSelected: (value) => setState(() => _sort = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: _SortOption.nameAsc, child: Text('Name (A-Z)')),
                    PopupMenuItem(value: _SortOption.nameDesc, child: Text('Name (Z-A)')),
                    PopupMenuItem(
                        value: _SortOption.payableHighLow, child: Text('Payable (high-low)')),
                    PopupMenuItem(
                        value: _SortOption.payableLowHigh, child: Text('Payable (low-high)')),
                  ],
                ),
                TextButton.icon(
                  onPressed: _openReferrals,
                  icon: const Icon(Icons.group_add_outlined, size: 18),
                  label: const Text('Referral', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                if (calculated)
                  IconButton(
                    tooltip: 'Recalculate this report',
                    icon: const Icon(Icons.calculate_outlined),
                    onPressed: _recalculate,
                  ),
              ],
            ),
          ),
          if (calculated && !keyboardOpen) _bulkBar(),
          if (!keyboardOpen) ...[
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: _FilterOption.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.xs),
                itemBuilder: (context, index) {
                  final option = _FilterOption.values[index];
                  final selected = option == _filter;
                  return ChoiceChip(
                    label: Text(option.label),
                    selected: selected,
                    onSelected: (_) => setState(() => _filter = option),
                    selectedColor: AppTheme.primary.withValues(alpha: 0.16),
                    labelStyle: TextStyle(
                      color: selected ? AppTheme.primary : Colors.black87,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          Expanded(
            child: visible.isEmpty
                ? const EmptyView(message: 'No users match your search.', icon: Icons.search_off)
                : LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < _tableMinWidth) {
                        return RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.md,
                              0,
                              AppSpacing.md,
                              AppSpacing.md,
                            ),
                            itemCount: visible.length,
                            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (context, index) => _resultCard(visible[index]),
                          ),
                        );
                      }
                      return RefreshIndicator(
                        onRefresh: _load,
                        // The table's rows scroll inside a horizontal scroller, so
                        // the vertical list is one level deeper than the default.
                        notificationPredicate: (notification) => notification.depth == 1,
                        child: GridTable(
                          columns: _columns,
                          itemCount: visible.length,
                          rowHeight: Responsive.rowHeight(context, 80),
                          onRowTap: (index) => _openDetail(visible[index]),
                          cellsBuilder: (context, index) => _cells(visible[index]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    });
  }

  /// Below this width the 8-column table would need sideways scrolling to be
  /// read, so each user is shown as a card instead (same cells, same actions).
  static const _tableMinWidth = 760.0;

  Widget _resultCard(BonusResult r) {
    final cells = _cells(r);
    // Column order: 0 name, 1-4 figures, 5 final payable, 6 number, 7 action.
    // Label gets the larger share; a value that still doesn't fit scales down.
    Widget figure(int i) => Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                _columns[i].label,
                style: const TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              flex: 2,
              child: FittedBox(
                  fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: cells[i]),
            ),
          ],
        );

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetail(r),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cells[0]),
                  const SizedBox(width: AppSpacing.sm),
                  cells[5],
                ],
              ),
              const Divider(height: AppSpacing.lg),
              figure(1),
              const SizedBox(height: 4),
              figure(2),
              const SizedBox(height: 4),
              figure(3),
              const SizedBox(height: 4),
              figure(4),
              const Divider(height: AppSpacing.lg),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [cells[6], cells[7]],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _signedText(double? value) {
    if (value == null) return const Text('—', style: TextStyle(color: Colors.black38));
    final color = value > 0 ? AppTheme.success : (value < 0 ? AppTheme.danger : Colors.black54);
    return Text(
      Formatters.signed(value),
      style: TextStyle(fontWeight: FontWeight.w700, color: color),
    );
  }

  Widget _nameCell(BonusResult r) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          r.userName,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        if (r.level != null && r.level!.trim().isNotEmpty)
          Text(
            'Level ${r.level}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Colors.black54),
          ),
        if (r.hasReferrer)
          Text(
            'Referred by ${r.referrerName}',
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(fontSize: 11.5, color: AppTheme.blue, fontWeight: FontWeight.w600),
          ),
        if (r.referredCount > 0)
          Text(
            'Referrer · ${r.referredCount} referred',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 11.5, color: AppTheme.success, fontWeight: FontWeight.w600),
          ),
      ],
    );
  }

  List<Widget> _cells(BonusResult r) {
    final carry = r.carryForwardBalance ?? 0;

    return [
      // User ID / Name (with the bulk-send checkbox)
      Row(children: [
        SizedBox(
          width: 30,
          child: Checkbox(
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            value: _selected.contains(r.bonusResultId),
            onChanged: _selectable(r)
                ? (v) => setState(() {
                      if (v == true) {
                        _selected.add(r.bonusResultId);
                      } else {
                        _selected.remove(r.bonusResultId);
                      }
                    })
                : null,
          ),
        ),
        Expanded(child: _nameCell(r)),
      ]),
      // Profit / Loss
      Text(
        Formatters.points(r.profitLoss),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: r.profitLoss < 0 ? AppTheme.danger : null,
        ),
      ),
      // Personal bonus / adjustment
      _signedText(r.personalAdjustment),
      // Referral bonus / adjustment
      _signedText(r.referralAdjustment),
      // Previous balance
      _signedText(r.previousBalance),
      // Final payable bonus
      r.isCalculated
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Formatters.rupees(r.payable),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: r.payable > 0 ? AppTheme.success : Colors.black45,
                  ),
                ),
                if (carry < 0)
                  Text(
                    'carry ${Formatters.signed(carry)}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.danger, fontWeight: FontWeight.w600),
                  ),
              ],
            )
          : const Text('—', style: TextStyle(color: Colors.black38)),
      // WhatsApp number
      r.hasWhatsAppNumber
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(r.whatsappNumber!, overflow: TextOverflow.ellipsis)),
                IconButton(
                  tooltip: 'Edit number',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.edit_outlined, size: 18, color: AppTheme.blue),
                  onPressed: () => _editNumber(r),
                ),
              ],
            )
          : TextButton.icon(
              onPressed: () => _editNumber(r),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add number'),
            ),
      // WhatsApp action
      _actionCell(r),
      // Edit (opens the user's details: corrections, WhatsApp, referrals)
      TextButton.icon(
        onPressed: () => _openDetail(r),
        icon: const Icon(Icons.edit_outlined, size: 16),
        label: const Text('Edit'),
      ),
    ];
  }

  Widget _actionCell(BonusResult r) {
    if (!r.hasPayableBonus) {
      return Text(
        r.isCalculated ? 'No bonus' : '—',
        style: const TextStyle(color: Colors.black38, fontWeight: FontWeight.w600),
      );
    }
    // 'sending' that survives a reload means a send never finished: it may be
    // retried (the server still refuses a duplicate while one is truly in flight).
    final canSend = r.hasWhatsAppNumber && !r.isSent;
    final label = r.isSent
        ? 'Sent'
        : (r.isSendFailed || r.isSending)
            ? 'Retry send'
            : 'Auto Send WhatsApp';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton.icon(
          onPressed: canSend ? () => _sendWhatsApp(r) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.success,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          icon: Icon(r.isSent ? Icons.check : Icons.send_outlined, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        const SizedBox(height: 2),
        if (!r.hasWhatsAppNumber)
          const Text('Add a number first', style: TextStyle(fontSize: 10.5, color: Colors.black45))
        else
          Tooltip(
            message: r.sendError ?? '',
            child: StatusPill.forSend(r.sendStatus),
          ),
      ],
    );
  }
}

/// Totals over the whole report (not just the filtered rows).
class _SummaryStrip extends StatelessWidget {
  final List<BonusResult> results;

  const _SummaryStrip({required this.results});

  @override
  Widget build(BuildContext context) {
    final payableRows = results.where((r) => r.hasPayableBonus);
    final totalPayable = payableRows.fold<double>(0, (sum, r) => sum + r.payable);
    final carried = results.where((r) => (r.carryForwardBalance ?? 0) < 0).length;

    final chips = [
      _SummaryChip(label: 'Users', value: '${results.length}'),
      _SummaryChip(label: 'Payable users', value: '${payableRows.length}'),
      _SummaryChip(
        label: 'Total payable',
        value: Formatters.rupees(totalPayable),
        color: AppTheme.success,
      ),
      _SummaryChip(
        label: 'Carried forward',
        value: '$carried',
        color: carried > 0 ? AppTheme.danger : null,
      ),
    ];
    final padding = Responsive.pagePadding(context);

    // Phones: one swipeable row (a wrapped block of chips would push the
    // results far down the screen); wider screens keep the wrapped layout.
    if (MediaQuery.sizeOf(context).width < 600) {
      return SizedBox(
        height: 76 + (MediaQuery.textScalerOf(context).scale(25) - 25) * 1.4,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: padding, vertical: AppSpacing.sm),
          itemCount: chips.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, index) => chips[index],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(padding, AppSpacing.md, padding, AppSpacing.sm),
      child: Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: chips),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryChip({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppTheme.hairline),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: Colors.black45,
            ),
          ),
          Text(value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: color)),
        ],
      ),
    );
  }
}
