import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/bonus_calculation_summary.dart';
import '../models/validation_summary.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';

enum _Step { validating, calculating, completed, failed }

/// Screen 4 — Report Processing.
///
/// The backend has no single "check report status" or progress-polling
/// endpoint (Steps 3-6 only expose the actions themselves), so this screen
/// self-orchestrates the two real calls that turn an uploaded report into
/// calculated results — POST /validate, then POST /calculate-bonus — and
/// shows only states that correspond to an actual in-flight or completed
/// call. Nothing here is a fabricated progress bar.
///
/// "Uploading" (the report file itself) already happened on the previous
/// screen; this screen picks up from there — "Processing" is simply the
/// name for what this screen as a whole is doing (validating, then
/// calculating), not a separate backend call.
///
/// A request that times out is NOT shown as "Failed" — a timeout means the
/// server never told us the outcome, not that the outcome was bad. It gets
/// its own distinct state with its own wording and color, so nobody reads
/// "Failed" for a report that may well have gone through.
class ReportProcessingScreen extends StatefulWidget {
  final String reportId;

  const ReportProcessingScreen({super.key, required this.reportId});

  @override
  State<ReportProcessingScreen> createState() => _ReportProcessingScreenState();
}

class _ReportProcessingScreenState extends State<ReportProcessingScreen> {
  _Step _step = _Step.validating;
  // Which step (validating or calculating) actually failed, so the stage
  // rows can tell "this step failed" apart from "this step never ran" —
  // both would otherwise land under the same `_Step.failed` value.
  _Step? _failedAtStep;
  bool _isTimeout = false;
  String? _errorMessage;
  ValidationSummary? _validationSummary;
  BonusCalculationSummary? _bonusSummary;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _step = _Step.validating;
      _failedAtStep = null;
      _isTimeout = false;
      _errorMessage = null;
    });

    final repo = context.read<ReportRepository>();

    // --- Step 1: validate -------------------------------------------------
    ValidationSummary validation;
    try {
      validation = await repo.validateReport(widget.reportId);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.failed;
        _failedAtStep = _Step.validating;
        _isTimeout = e.kind == ApiErrorKind.timeout;
        _errorMessage = e.userMessage;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _validationSummary = validation);

    if (validation.status != 'validated') {
      // Backend set status to "failed" — e.g. no valid rows in the report.
      // This is a real, confirmed outcome (not a timeout), so it's shown
      // as an actual failure.
      setState(() {
        _step = _Step.failed;
        _failedAtStep = _Step.validating;
        _isTimeout = false;
        _errorMessage = validation.validCount == 0
            ? 'None of the ${validation.totalInputRecords} extracted row(s) passed validation.'
            : 'Validation did not complete successfully.';
      });
      return;
    }

    // --- Step 2: calculate bonus ------------------------------------------
    setState(() => _step = _Step.calculating);

    BonusCalculationSummary bonus;
    try {
      bonus = await repo.calculateBonus(widget.reportId);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.failed;
        _failedAtStep = _Step.calculating;
        _isTimeout = e.kind == ApiErrorKind.timeout;
        _errorMessage = e.userMessage;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _bonusSummary = bonus);

    if (bonus.status != 'completed') {
      setState(() {
        _step = _Step.failed;
        _failedAtStep = _Step.calculating;
        _isTimeout = false;
        _errorMessage = 'Bonus calculation did not complete successfully.';
      });
      return;
    }

    setState(() => _step = _Step.completed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Processing Report')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.lg),
            _StageRow(
              label: 'Validating',
              state: _stateFor(_Step.validating),
            ),
            _StageRow(
              label: 'Calculating',
              state: _stateFor(_Step.calculating),
            ),
            _StageRow(
              label: _stageThreeLabel,
              state: _stageThreeState,
            ),
            const SizedBox(height: AppSpacing.xl),
            if (_step == _Step.failed && _errorMessage != null) ...[
              if (_isTimeout)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.schedule_outlined, color: AppTheme.warning, size: 28),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.warning, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'This does not necessarily mean it failed — the server may still '
                        'be working on it. Try again to check.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                      ),
                    ],
                  ),
                )
              else
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.danger),
                ),
              if (_validationSummary != null && _validationSummary!.invalidCount > 0) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${_validationSummary!.invalidCount} row(s) had validation issues.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton(onPressed: _run, child: const Text('Try Again')),
            ],
            if (_step == _Step.completed) _buildCompletionSummary(context),
          ],
        ),
      ),
    );
  }

  String get _stageThreeLabel {
    if (_step == _Step.failed) return _isTimeout ? 'Timed out' : 'Failed';
    return 'Completed';
  }

  _StageState get _stageThreeState {
    if (_step == _Step.failed) return _isTimeout ? _StageState.timeout : _StageState.error;
    return _stateFor(_Step.completed);
  }

  /// Total users / bonus-eligible users / total bonus / WhatsApp sent /
  /// WhatsApp pending-or-failed — every figure here comes straight out of
  /// the real `calculate-bonus` response (`_bonusSummary`). Right after
  /// calculation, no WhatsApp send has happened yet for this report, so
  /// "sent" is naturally 0 and "pending/failed" is the full eligible
  /// count — that's the real state, not a placeholder.
  Widget _buildCompletionSummary(BuildContext context) {
    final summary = _bonusSummary;
    final results = summary?.results ?? const [];
    final totalUsers = summary?.totalInputRecords ?? results.length;
    // "Bonus-eligible" = has a calculated bonus amount at all (matches the
    // definition used everywhere else in the app — ReportRepository,
    // Dashboard, Reports tab — so the same report shows the same number
    // wherever it's shown).
    final eligible = results.where((r) => r.bonusAmount != null).toList();
    final bonusEligible = eligible.length;
    final totalBonus = results.fold<double>(0, (sum, r) => sum + (r.bonusAmount ?? 0));
    // Scoped to eligible users only, same as the Dashboard's WhatsApp
    // Sent/Pending tiles — a user with no bonus owed will never get a
    // message, so counting them as "pending" would overstate it.
    final whatsAppSent = eligible.where((r) => r.whatsappStatus == 'sent').length;
    final whatsAppPendingOrFailed = bonusEligible - whatsAppSent;

    return Column(
      children: [
        const Icon(Icons.check_circle, color: AppTheme.success, size: 40),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Processing complete',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                _SummaryRow(label: 'Total users', value: '$totalUsers'),
                _SummaryRow(label: 'Bonus-eligible users', value: '$bonusEligible'),
                _SummaryRow(label: 'Total bonus', value: Formatters.amount(totalBonus)),
                _SummaryRow(label: 'WhatsApp sent', value: '$whatsAppSent'),
                _SummaryRow(
                  label: 'WhatsApp pending/failed',
                  value: '$whatsAppPendingOrFailed',
                  isLast: true,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        ElevatedButton.icon(
          onPressed: () => Navigator.of(context).pushReplacementNamed(
            AppRoutes.results,
            arguments: widget.reportId,
          ),
          icon: const Icon(Icons.list_alt_outlined),
          label: const Text('View Results'),
        ),
      ],
    );
  }

  /// State for the Validating/Calculating rows specifically. A plain
  /// index comparison isn't enough once there's a failure: `_Step.failed`
  /// sorts after both, so without checking [_failedAtStep] a validate
  /// failure would make the *never-run* Calculating row show a green
  /// "done" checkmark too. [_failedAtStep] records exactly which step's
  /// own call actually failed, so a step before it reads "done" (it
  /// really did succeed), that step reads error/timeout, and any step
  /// after it correctly reads "pending" (it never ran).
  _StageState _stateFor(_Step step) {
    if (_step == _Step.failed) {
      final failedAt = _failedAtStep;
      if (failedAt == null) return _StageState.pending;
      if (step.index < failedAt.index) return _StageState.done;
      if (step == failedAt) return _isTimeout ? _StageState.timeout : _StageState.error;
      return _StageState.pending;
    }
    if (_step.index > step.index || _step == _Step.completed) {
      return _StageState.done;
    }
    if (_step == step) return _StageState.active;
    return _StageState.pending;
  }
}

enum _StageState { pending, active, done, error, timeout }

class _StageRow extends StatelessWidget {
  final String label;
  final _StageState state;

  const _StageRow({required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    Widget icon;
    Color color;
    switch (state) {
      case _StageState.pending:
        color = Colors.black26;
        icon = Icon(Icons.circle_outlined, color: color);
        break;
      case _StageState.active:
        color = AppTheme.primary;
        icon = const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        break;
      case _StageState.done:
        color = AppTheme.success;
        icon = Icon(Icons.check_circle, color: color);
        break;
      case _StageState.error:
        color = AppTheme.danger;
        icon = Icon(Icons.cancel, color: color);
        break;
      case _StageState.timeout:
        color = AppTheme.warning;
        icon = Icon(Icons.schedule_outlined, color: color);
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(height: 24, width: 24, child: Center(child: icon)),
          const SizedBox(width: AppSpacing.md),
          Text(
            label,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: state == _StageState.pending ? Colors.black45 : Colors.black87,
                  fontWeight: state == _StageState.active ? FontWeight.w600 : FontWeight.normal,
                ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLast;

  const _SummaryRow({required this.label, required this.value, this.isLast = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
              Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1),
      ],
    );
  }
}
