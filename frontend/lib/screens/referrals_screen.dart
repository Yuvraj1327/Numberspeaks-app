import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/bonus_result.dart';
import '../models/bonus_settings.dart';
import '../models/referral_entry.dart';
import '../models/report_summary.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';

/// Referral entries of one report (period).
///
/// The admin links a referred user to their referrer by hand. When the
/// report is calculated, the referrer gets (referral rate x the referred
/// user's result): a loss adds to the referrer's bonus, a win deducts from
/// it. That figure is kept separate from the referrer's own personal
/// bonus. The backend rejects duplicates and double counting (for example
/// the same user linked to two referrers in one period).
class ReferralsScreen extends StatefulWidget {
  final String reportId;

  const ReferralsScreen({super.key, required this.reportId});

  @override
  State<ReferralsScreen> createState() => _ReferralsScreenState();
}

class _ReferralsScreenState extends State<ReferralsScreen> {
  bool _loading = true;
  String? _errorMessage;
  List<ReferralEntry> _entries = [];
  List<BonusResult> _rows = [];
  ReportSummary? _report;
  BonusSettings? _settings;

  @override
  void initState() {
    super.initState();
    _load();
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
      final entries = await repo.listReferrals(widget.reportId);
      final rows = await repo.getResults(widget.reportId);
      final report = await repo.getReport(widget.reportId);
      final settings = await repo.getSettings();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _rows = rows;
        _report = report;
        _settings = settings;
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

  Future<void> _add() async {
    final added = await showDialog<ReferralEntry>(
      context: context,
      builder: (context) => _AddReferralDialog(
        reportId: widget.reportId,
        rows: _rows,
        defaultRate: _settings?.referralRate ?? 0.10,
      ),
    );
    if (added == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Referral added. It is applied when you calculate.')),
    );
    _load(silent: true);
  }

  Future<void> _remove(ReferralEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Remove referral?'),
        content: Text(
          '${entry.referredName ?? 'This user'} will no longer count towards '
          '${entry.referrerName ?? 'the referrer'}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await context.read<ReportRepository>().removeReferral(widget.reportId, entry.entryId);
      if (!mounted) return;
      _load(silent: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  Future<void> _calculate() async {
    await Navigator.of(context).pushNamed(AppRoutes.processing, arguments: widget.reportId);
    if (mounted) _load(silent: true);
  }

  bool get _needsCalculation => _report != null && _report!.status != 'completed';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Referrals')),
      floatingActionButton: (_loading || _errorMessage != null)
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              backgroundColor: AppTheme.blue,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add referral'),
            ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null) return ErrorView(message: _errorMessage!, onRetry: _load);

    final rate = _settings?.referralRate ?? 0.10;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 96),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppTheme.blue.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Link a referred user to their referrer. The referrer gets '
              '${Formatters.percent(rate)} (your current referral rate) of the referred user\'s '
              'result for this period: a loss adds to the referrer\'s bonus, a win deducts from it. '
              'It is kept separate from the referrer\'s own bonus. A referred user can be linked '
              'to one referrer per period.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_needsCalculation)
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              margin: const EdgeInsets.only(bottom: AppSpacing.md),
              decoration: BoxDecoration(
                color: AppTheme.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Changes are applied when you confirm and calculate.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.warning, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: _calculate,
                    icon: const Icon(Icons.calculate_outlined),
                    label: const Text('Confirm & Calculate'),
                  ),
                ],
              ),
            ),
          if (_entries.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: EmptyView(
                icon: Icons.group_add_outlined,
                message: 'No referrals for this report yet.\nTap "Add referral" to link a user.',
              ),
            )
          else
            for (final entry in _entries)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _ReferralCard(entry: entry, onRemove: () => _remove(entry)),
              ),
        ],
      ),
    );
  }
}

class _ReferralCard extends StatelessWidget {
  final ReferralEntry entry;
  final VoidCallback onRemove;

  const _ReferralCard({required this.entry, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final adjustment = entry.adjustment;
    final positive = (adjustment ?? 0) > 0;
    final negative = (adjustment ?? 0) < 0;
    final color = positive ? AppTheme.success : (negative ? AppTheme.danger : Colors.black54);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      Text(
                        entry.referrerName ?? entry.referrerUserId,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const Icon(Icons.arrow_forward, size: 16, color: Colors.black45),
                      Text(
                        entry.referredName ?? entry.referredUserId,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                _Fact(label: 'Rate', value: Formatters.percent(entry.rate)),
                _Fact(
                  label: 'Referred user result',
                  value: entry.amount == null ? 'Not calculated yet' : Formatters.points(entry.amount!),
                ),
                _Fact(
                  label: 'Referral adjustment',
                  value: adjustment == null ? '—' : Formatters.signed(adjustment),
                  valueColor: adjustment == null ? null : color,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _Fact({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
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
    );
  }
}

/// Picks a referrer and a referred user (both must be in this report) and an
/// optional rate, then saves the entry. The dialog only closes when the
/// backend accepted it; a rejection (duplicate, already linked, ...) is shown
/// inside the dialog.
class _AddReferralDialog extends StatefulWidget {
  final String reportId;
  final List<BonusResult> rows;
  final double defaultRate;

  const _AddReferralDialog({
    required this.reportId,
    required this.rows,
    required this.defaultRate,
  });

  @override
  State<_AddReferralDialog> createState() => _AddReferralDialogState();
}

class _AddReferralDialogState extends State<_AddReferralDialog> {
  final TextEditingController _rate = TextEditingController();
  BonusResult? _referrer;
  BonusResult? _referred;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Iterable<BonusResult> _options(String text) {
    final q = text.trim().toLowerCase();
    final matches = q.isEmpty
        ? widget.rows
        : widget.rows.where((r) => r.userName.toLowerCase().contains(q));
    return matches.take(30);
  }

  Widget _picker({
    required String label,
    required BonusResult? selected,
    required ValueChanged<BonusResult?> onChanged,
  }) {
    return Autocomplete<BonusResult>(
      displayStringForOption: (option) => option.userName,
      optionsBuilder: (value) => _options(value.text),
      onSelected: (option) => onChanged(option),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: !_saving,
          decoration: InputDecoration(
            labelText: label,
            hintText: 'Type to search, then pick from the list',
            suffixIcon: selected == null
                ? null
                : const Icon(Icons.check_circle, color: AppTheme.success, size: 20),
          ),
          onChanged: (text) {
            // Typing again after picking invalidates the pick: the admin must
            // choose a user from the list, not type a name that merely looks
            // right.
            if (selected != null && text != selected.userName) onChanged(null);
          },
        );
      },
    );
  }

  Future<void> _save() async {
    final referrer = _referrer;
    final referred = _referred;
    if (referrer == null || referred == null) {
      setState(() => _error = 'Pick both users from the list.');
      return;
    }
    if (referrer.userId == referred.userId) {
      setState(() => _error = 'A user cannot be their own referrer.');
      return;
    }

    double? rate;
    final rateText = _rate.text.trim().replaceAll('%', '');
    if (rateText.isNotEmpty) {
      final percent = double.tryParse(rateText);
      if (percent == null || percent < 0 || percent > 100) {
        setState(() => _error = 'The rate must be a percentage between 0 and 100.');
        return;
      }
      rate = double.parse((percent / 100).toStringAsFixed(6));
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry = await context.read<ReportRepository>().addReferral(
            widget.reportId,
            referrerUserId: referrer.userId,
            referredUserId: referred.userId,
            rate: rate,
          );
      if (!mounted) return;
      Navigator.of(context).pop(entry);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Add referral'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _picker(
                label: 'Referrer (gets the referral bonus)',
                selected: _referrer,
                onChanged: (value) => setState(() => _referrer = value),
              ),
              const SizedBox(height: AppSpacing.md),
              _picker(
                label: 'Referred user',
                selected: _referred,
                onChanged: (value) => setState(() => _referred = value),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _rate,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Rate in % (optional)',
                  hintText: 'Default ${Formatters.percent(widget.defaultRate)}',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: const TextStyle(color: AppTheme.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(minimumSize: const Size(96, 44)),
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}
