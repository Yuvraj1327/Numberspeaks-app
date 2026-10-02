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
import '../widgets/whatsapp_send_field.dart';

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
/// — so the search/sort/filter/WhatsApp logic exists in exactly one place.
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
          children: const [
            SizedBox(height: 120),
            EmptyView(
              icon: Icons.bar_chart_outlined,
              message: 'No results yet.\nUpload and process a report to see bonus results here.',
            ),
          ],
        ),
      );
    }
    return _ResultsBody(reportId: _reportId!);
  }
}

class _ResultsBody extends StatefulWidget {
  final String reportId;

  const _ResultsBody({required this.reportId});

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

  /// Persists an admin-entered WhatsApp number (Supabase — see
  /// ReportRepository.saveWhatsAppNumber) and reflects it locally so the
  /// in-memory list stays consistent with what was just saved.
  Future<void> _saveWhatsAppNumber(BonusResult result, String number) async {
    final repo = context.read<ReportRepository>();
    await repo.saveWhatsAppNumber(widget.reportId, result, number);
    if (!mounted) return;
    setState(() {
      final index = _results.indexWhere((r) => r.bonusResultId == result.bonusResultId);
      if (index != -1) {
        _results[index] = _results[index].copyWith(whatsappNumber: number);
      }
    });
  }

  void _openDetail(BonusResult result) {
    Navigator.of(context).pushNamed(
      AppRoutes.userDetail,
      arguments: UserDetailArgs(reportId: widget.reportId, initialResult: result),
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
          children: const [
            SizedBox(height: 120),
            EmptyView(message: 'No bonus results yet for this report.'),
          ],
        ),
      );
    }

    final visible = _filteredSorted;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
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
                selectedColor: AppTheme.primary.withOpacity(0.16),
                labelStyle: TextStyle(
                  color: selected ? AppTheme.primary : Colors.black87,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: visible.isEmpty
              ? const EmptyView(message: 'No users match your search.', icon: Icons.search_off)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      // Caps card width on tablet/desktop/web so a row of
                      // fields never stretches into an unreadable single
                      // line — still a plain full-width list on phones.
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: ListView.separated(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        itemCount: visible.length,
                        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                        itemBuilder: (context, index) {
                          final result = visible[index];
                          return _ResultCard(
                            result: result,
                            onTap: () => _openDetail(result),
                            onNumberSaved: (number) => _saveWhatsAppNumber(result, number),
                          );
                        },
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// One user's full result row, exactly as the brief lists it: User Name,
/// Level, Casino Pts, Sport Pts, Third Party Pts, Profit/Loss, 3% Bonus,
/// then the WhatsApp number input + Send button. Used for every width —
/// a stacked card reads cleanly at any size, unlike a cramped many-column
/// table. Tapping the header (name/avatar) opens the full user detail
/// screen; the WhatsApp field below is its own tap target so typing a
/// number or pressing Send never triggers navigation.
class _ResultCard extends StatelessWidget {
  final BonusResult result;
  final VoidCallback onTap;
  final ValueChanged<String> onNumberSaved;

  const _ResultCard({
    required this.result,
    required this.onTap,
    required this.onNumberSaved,
  });

  bool get _hasBonus => (result.bonusAmount ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: AppTheme.surfaceMuted,
                    child: Text(
                      result.userName.isNotEmpty ? result.userName[0].toUpperCase() : '?',
                      style: const TextStyle(color: AppTheme.navy, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result.userName,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (result.level != null && result.level!.trim().isNotEmpty)
                          Text(
                            'Level: ${result.level}',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.black54),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _hasBonus
                          ? AppTheme.success.withOpacity(0.12)
                          : AppTheme.surfaceMuted,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'BONUS (3%)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            color: _hasBonus ? AppTheme.success : Colors.black45,
                          ),
                        ),
                        Text(
                          _hasBonus ? Formatters.amount(result.bonusAmount!) : '—',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: _hasBonus ? AppTheme.success : Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, color: Colors.black26),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                _StatChip(label: 'Casino Pts', value: Formatters.points(result.casinoPts)),
                _StatChip(label: 'Sport Pts', value: Formatters.points(result.sportPts)),
                _StatChip(
                    label: 'Third Party Pts', value: Formatters.points(result.thirdPartyPts)),
                _StatChip(
                  label: 'Profit/Loss',
                  value: Formatters.points(result.profitLoss),
                  valueColor: result.profitLoss < 0 ? AppTheme.danger : null,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.sm),
            WhatsAppSendField(result: result, onNumberSaved: onNumberSaved),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatChip({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: Colors.black45,
            ),
          ),
          Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: valueColor)),
        ],
      ),
    );
  }
}
