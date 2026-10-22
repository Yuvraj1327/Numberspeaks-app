import 'dart:ui' show FontFeature;

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
import '../widgets/figures.dart';
import '../widgets/user_whatsapp_button.dart';
import '../widgets/whatsapp_bulk_dialog.dart';
import '../widgets/whatsapp_manual_dialog.dart';
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
  padding: EdgeInsets.fromLTRB(
      AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
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
              message:
                  'No results yet.\nUpload and process a report to see bonus results here.',
            ),
          ],
        ),
      );
    }

    final revision = _bodyRevision;
    return Column(
      children: [
        _tabHeader,
        Expanded(
          child: _ResultsBody(
            key: ValueKey(_selectedId),
            reportId: _selectedId!,
            refreshToken: revision,
            reportPicker: _ReportPicker(
              reports: _reports,
              selectedId: _selectedId!,
              onSelected: (id) => setState(() => _selectedId = id),
            ),
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
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
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
                          style: const TextStyle(
                              fontSize: 11.5, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  StatusPill.forReportStatus(
                      ReportStatus.fromString(report.status)),
                ],
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 10),
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
                      style: const TextStyle(
                          fontSize: 11.5, color: Colors.black54),
                    ),
                  ],
                ),
              ),
              StatusPill.forReportStatus(
                  ReportStatus.fromString(selected.status)),
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

  /// The report selector (Results tab only); shown inside the options panel.
  final Widget? reportPicker;

  const _ResultsBody(
      {super.key,
      required this.reportId,
      this.refreshToken = 0,
      this.reportPicker});

  @override
  State<_ResultsBody> createState() => _ResultsBodyState();
}

class _ResultsBodyState extends State<_ResultsBody> {
  static const _columns = [
    GridColumn('User ID / Name', 210),
    GridColumn('Week', 120),
    GridColumn('Previous report total', 120, numeric: true),
    GridColumn('Current report total', 120, numeric: true),
    GridColumn("This week's win / loss", 140, numeric: true),
    GridColumn('Bonus basis', 110, numeric: true),
    GridColumn('Personal bonus / adjustment', 130, numeric: true),
    GridColumn('Referral bonus / adjustment', 130, numeric: true),
    GridColumn('Previous balance', 120, numeric: true),
    GridColumn('Final payable', 140, numeric: true),
    GridColumn('WhatsApp number', 190),
    GridColumn('WhatsApp send', 190),
    GridColumn('Edit', 90),
  ];

  bool _optionsOpen = false;
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
        list.sort((a, b) =>
            a.userName.toLowerCase().compareTo(b.userName.toLowerCase()));
        break;
      case _SortOption.nameDesc:
        list.sort((a, b) =>
            b.userName.toLowerCase().compareTo(a.userName.toLowerCase()));
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
    final index =
        _results.indexWhere((r) => r.bonusResultId == updated.bonusResultId);
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
      _replace(result.copyWith(
          whatsappNumber: saved, clearWhatsAppNumber: saved.isEmpty));
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(saved.isEmpty
              ? 'WhatsApp number removed.'
              : 'WhatsApp number saved.')),
    );
  }

  Future<void> _sendWhatsApp(BonusResult result) async {
    final outcome = await showWhatsAppMessageDialog(
      context,
      result: result,
      onUpdated: (updated) {
        if (mounted) setState(() => _replace(updated));
      },
    );
    if (outcome == null || !mounted) return;
    if (outcome.result != null) setState(() => _replace(outcome.result!));
    // The server may know better than the screen (e.g. a send already in flight).
    if (outcome.refresh) _load(silent: true);
  }

  /// Can be picked for a bulk send: payable, has a usable number, and not
  /// already Sent / being sent. Failed ones are picked on purpose to retry them;
  /// Unknown ones may already be delivered, so they are retried one by one only.
  bool _selectable(BonusResult r) =>
      r.hasPayableBonus &&
      WhatsAppLink.isUsableNumber(r.whatsappNumber ?? '') &&
      !r.isAccepted &&
      !r.isSending &&
      !r.isSendUnknown;

  List<BonusResult> get _selectedResults => _results
      .where((r) => _selected.contains(r.bonusResultId) && _selectable(r))
      .toList();

  /// "All eligible" = never attempted. Failed/Unknown are never swept in
  /// automatically: they are retried only by selecting them.
  List<BonusResult> get _allEligible => _results
      .where((r) => _selectable(r) && r.sendStatus == 'pending')
      .toList();

  List<BulkSkipPreview> _skippedPreview(Iterable<BonusResult> pool) {
    final out = <BulkSkipPreview>[];
    for (final r in pool) {
      if (!r.hasPayableBonus || r.isAccepted) continue;
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
    final skipped = _skippedPreview(all
        ? _results
        : _results.where((r) => _selected.contains(r.bonusResultId)));
    final reportId = _results.isEmpty ? null : _results.first.reportId;
    if (reportId == null) return;
    final mode = await _chooseMode(targets.length);
    if (mode == null || !mounted) return;
    if (mode == WhatsAppMode.manual) {
      final ctx = await loadMessageContext(context, reportId);
      if (!mounted) return;
      await showWhatsAppManualDialog(
        context,
        targets: targets,
        template: ctx.template,
        week: ctx.week,
        title: all ? 'Manual: All Eligible' : 'Manual: Selected',
      );
      if (mounted) setState(_selected.clear);
      return;
    }
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

  Future<WhatsAppMode?> _chooseMode(int count) {
    return showDialog<WhatsAppMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Send to $count user${count == 1 ? '' : 's'}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(WhatsAppMode.auto),
            child: const ListTile(
              leading: Icon(Icons.bolt_outlined),
              title: Text('Auto Send'),
              subtitle:
                  Text('Sent by the server, one at a time, with a status'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(WhatsAppMode.manual),
            child: const ListTile(
              leading: Icon(Icons.open_in_new),
              title: Text('Manual Send'),
              subtitle: Text('Open each WhatsApp chat yourself, one by one'),
            ),
          ),
        ],
      ),
    );
  }

  /// Search stays on screen; the toggle next to it opens the options panel.
  Widget _searchRow() {
    final active = _filter != _FilterOption.all || _selected.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
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
          const SizedBox(width: AppSpacing.xs),
          Tooltip(
            message: _optionsOpen ? 'Hide options' : 'Show options',
            child: Material(
              color: _optionsOpen
                  ? AppTheme.blue.withValues(alpha: 0.12)
                  : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: AppTheme.hairline),
              ),
              child: InkWell(
                key: const Key('results-options-toggle'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _optionsOpen = !_optionsOpen),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        _optionsOpen ? Icons.expand_less : Icons.tune,
                        color: AppTheme.blue,
                      ),
                      if (active && !_optionsOpen)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: const BoxDecoration(
                                color: AppTheme.danger, shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Everything that used to crowd the top of the page: report selector,
  /// summary, Sort / Referral / Recalculate, bulk send and filters. Collapsed
  /// by default so the user cards get the screen; when open it scrolls inside
  /// a capped height so the cards are never pushed off entirely.
  Widget _optionsPanel(bool calculated) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.42;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.topCenter,
      child: !_optionsOpen
          ? const SizedBox(width: double.infinity)
          : ConstrainedBox(
              key: const Key('results-options-panel'),
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.reportPicker != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: widget.reportPicker!,
                      ),
                    _SummaryStrip(results: _results),
                    _toolbar(calculated),
                    if (calculated) _bulkBar(),
                    _filterChips(),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _filterChips() {
    return SizedBox(
      height: 40,
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
    );
  }

  /// Sort / Referral / Recalculate as one tidy row of equal-height buttons.
  Widget _toolbar(bool calculated) {
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      visualDensity: VisualDensity.compact,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PopupMenuButton<_SortOption>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (value) => setState(() => _sort = value),
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: _SortOption.nameAsc, child: Text('Name (A-Z)')),
              PopupMenuItem(
                  value: _SortOption.nameDesc, child: Text('Name (Z-A)')),
              PopupMenuItem(
                  value: _SortOption.payableHighLow,
                  child: Text('Payable (high-low)')),
              PopupMenuItem(
                  value: _SortOption.payableLowHigh,
                  child: Text('Payable (low-high)')),
            ],
            child: IgnorePointer(
              child: OutlinedButton.icon(
                style: style,
                onPressed: () {},
                icon: const Icon(Icons.sort, size: 18),
                label: const Text('Sort'),
              ),
            ),
          ),
          OutlinedButton.icon(
            style: style,
            onPressed: _openReferrals,
            icon: const Icon(Icons.group_add_outlined, size: 18),
            label: const Text('Referral'),
          ),
          if (calculated)
            OutlinedButton.icon(
              style: style,
              onPressed: _recalculate,
              icon: const Icon(Icons.calculate_outlined, size: 18),
              label: const Text('Recalculate'),
            ),
        ],
      ),
    );
  }

  Widget _bulkBar() {
    final selected = _selectedResults.length;
    final eligible = _allEligible.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: selected == 0 ? null : () => _bulkSend(all: false),
                  icon: const Icon(Icons.checklist, size: 18),
                  label: Text('Send Selected ($selected)',
                      overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: eligible == 0 ? null : () => _bulkSend(all: true),
                  icon: const Icon(Icons.send_and_archive_outlined, size: 18),
                  label: Text('Send All Eligible ($eligible)',
                      overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
          if (_selected.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: () => setState(_selected.clear),
                  child: const Text('Clear selection')),
            ),
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
    await Navigator.of(context)
        .pushNamed(AppRoutes.referrals, arguments: widget.reportId);
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
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Recalculate')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await Navigator.of(context)
        .pushNamed(AppRoutes.processing, arguments: widget.reportId);
    if (mounted) _load(silent: true);
  }

  Future<void> _openReview() async {
    await Navigator.of(context)
        .pushNamed(AppRoutes.review, arguments: widget.reportId);
    if (mounted) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null)
      return ErrorView(message: _errorMessage!, onRetry: _load);
    if (_results.isEmpty) {
      final String message;
      switch (ReportStatus.fromString(_report?.status)) {
        case ReportStatus.uploaded:
        case ReportStatus.processing:
        case ReportStatus.validating:
        case ReportStatus.calculating:
          message =
              'This report is still being processed.\nPull down to refresh.';
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
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
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
                    TextButton(
                        onPressed: _openReview,
                        child: const Text('Review & calculate')),
                  ],
                ),
              ),
            ),
          _searchRow(),
          if (!keyboardOpen) _optionsPanel(calculated),
          Expanded(
            child: visible.isEmpty
                ? const EmptyView(
                    message: 'No users match your search.',
                    icon: Icons.search_off)
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
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (context, index) =>
                                _resultCard(visible[index]),
                          ),
                        );
                      }
                      return RefreshIndicator(
                        onRefresh: _load,
                        // The table's rows scroll inside a horizontal scroller, so
                        // the vertical list is one level deeper than the default.
                        notificationPredicate: (notification) =>
                            notification.depth == 1,
                        child: GridTable(
                          columns: _columns,
                          itemCount: visible.length,
                          rowHeight: Responsive.rowHeight(context, 80),
                          onRowTap: (index) => _openDetail(visible[index]),
                          cellsBuilder: (context, index) =>
                              _cells(visible[index]),
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
    // Column order: 0 name, 1 week, 2 previous total, 3 current total, 4 this week's
    // win/loss, 5 bonus basis, 6 personal, 7 referral, 8 previous balance,
    // 9 final payable, 10 number, 11 WhatsApp, 12 edit.
    Widget tile(String label, double? value, Widget figure) {
      final tint = value == null ? Colors.black38 : Figure.signColor(value);
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 2),
              FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: figure),
            ],
          ),
        ),
      );
    }

    final carry = r.carryForwardBalance ?? 0;
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
                  Expanded(flex: 3, child: cells[0]),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    flex: 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topRight,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text(
                            'PAYABLE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                              color: AppTheme.textMuted,
                            ),
                          ),
                          if (r.isCalculated)
                            Figure.payable(r.payable, size: 18)
                          else
                            cells[9],
                          if (carry < 0)
                            Text(
                              'carry ${Formatters.signed(carry)}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.danger,
                                  fontWeight: FontWeight.w600),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              cells[1],
              const SizedBox(height: AppSpacing.sm),
              Row(children: [
                tile('Previous total', r.previousReportTotal, cells[2]),
                const SizedBox(width: AppSpacing.xs),
                tile('Current total', r.currentReportTotal ?? r.profitLoss, cells[3]),
              ]),
              const SizedBox(height: AppSpacing.xs),
              _weeklyHighlight(r),
              const SizedBox(height: AppSpacing.xs),
              Row(children: [
                tile('Bonus basis', r.bonusBasis, cells[5]),
                const SizedBox(width: AppSpacing.xs),
                tile('Previous balance', r.previousBalance, cells[8]),
              ]),
              const SizedBox(height: AppSpacing.xs),
              Row(children: [
                tile('Personal bonus', r.personalAdjustment, cells[6]),
                const SizedBox(width: AppSpacing.xs),
                tile('Referral bonus', r.referralAdjustment, cells[7]),
              ]),
              const Divider(height: AppSpacing.lg),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [cells[10], cells[11], cells[12]],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The week's actual win/loss, full width and tinted so it stands out on a phone.
  Widget _weeklyHighlight(BonusResult r) {
    final change = r.weeklyChange;
    final tint = change == null ? Colors.black38 : Figure.signColor(change);
    final caption = change == null
        ? ''
        : (change < 0 ? 'LOSS THIS WEEK' : (change > 0 ? 'WIN THIS WEEK' : 'NO CHANGE THIS WEEK'));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tint.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              change == null ? "THIS WEEK'S WIN / LOSS" : caption,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.3, color: tint),
            ),
          ),
          Figure.signedBig(change),
        ],
      ),
    );
  }

  /// "5–11 Oct 2026" for this report's week (the same for every row).
  String get _weekLabel => _report?.periodLabel ?? '—';

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
            style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.blue,
                fontWeight: FontWeight.w600),
          ),
        if (r.referredCount > 0)
          Text(
            'Referrer · ${r.referredCount} referred',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.success,
                fontWeight: FontWeight.w600),
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
      // Week start–end
      Text(_weekLabel,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
      // Previous report total (cumulative)
      r.previousReportTotal == null
          ? Figure.signed(null)
          : Figure.profitLoss(r.previousReportTotal!),
      // Current report total (cumulative)
      Figure.profitLoss(r.currentReportTotal ?? r.profitLoss),
      // This week's actual win / loss
      Figure.signedBig(r.weeklyChange),
      // Bonus calculation basis
      Figure.signed(r.bonusBasis),
      // Personal bonus / adjustment
      Figure.signed(r.personalAdjustment),
      // Referral bonus / adjustment
      Figure.signed(r.referralAdjustment),
      // Previous balance
      Figure.signed(r.previousBalance),
      // Final payable bonus
      r.isCalculated
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Figure.payable(r.payable, size: 15),
                if (carry < 0)
                  Text(
                    'carry ${Formatters.signed(carry)}',
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.danger,
                        fontWeight: FontWeight.w600),
                  ),
              ],
            )
          : const Text('—', style: TextStyle(color: Colors.black38)),
      // WhatsApp number
      r.hasWhatsAppNumber
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                    child: Text(r.whatsappNumber!,
                        overflow: TextOverflow.ellipsis)),
                IconButton(
                  tooltip: 'Edit number',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.edit_outlined,
                      size: 18, color: AppTheme.blue),
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
        style:
            const TextStyle(color: Colors.black38, fontWeight: FontWeight.w600),
      );
    }
    // 'sending' that survives a reload means a send never finished: it may be
    // retried (the server still refuses a duplicate while one is truly in flight).
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        WhatsAppMenuButton(
          compact: true,
          enabled: r.hasWhatsAppNumber,
          onSelected: (mode) => mode == WhatsAppMode.auto
              ? _sendWhatsApp(r)
              : startManualSend(context, r),
        ),
        const SizedBox(height: 2),
        if (!r.hasWhatsAppNumber)
          const Text('Add a number first',
              style: TextStyle(fontSize: 10.5, color: Colors.black45))
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
    final totalPayable =
        payableRows.fold<double>(0, (sum, r) => sum + r.payable);
    final carried =
        results.where((r) => (r.carryForwardBalance ?? 0) < 0).length;

    final chips = [
      _SummaryChip(
          label: 'Users',
          value: '${results.length}',
          icon: Icons.groups_outlined),
      _SummaryChip(
        label: 'Payable users',
        value: '${payableRows.length}',
        icon: Icons.person_outline,
      ),
      _SummaryChip(
        label: 'Total payable',
        value: Formatters.rupees(totalPayable),
        icon: Icons.payments_outlined,
        color: AppTheme.success,
      ),
      _SummaryChip(
        label: 'Carried forward',
        value: '$carried',
        icon: Icons.redo,
        color: carried > 0 ? AppTheme.danger : null,
      ),
    ];
    final padding = Responsive.pagePadding(context);

    // Phones: a 2 x 2 grid (everything visible, nothing to swipe); wider
    // screens: one row of four equal cards.
    return Padding(
      padding:
          EdgeInsets.fromLTRB(padding, AppSpacing.md, padding, AppSpacing.sm),
      child: LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth < 600 ? 2 : 4;
        const gap = AppSpacing.sm;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final c in chips) SizedBox(width: width, child: c)],
        );
      }),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  const _SummaryChip(
      {required this.label,
      required this.value,
      required this.icon,
      this.color});

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppTheme.blue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppTheme.hairline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: AppTheme.textMuted,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: color ?? AppTheme.textStrong,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
