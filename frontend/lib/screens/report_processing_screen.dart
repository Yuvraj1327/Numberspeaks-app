import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
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
class ReportProcessingScreen extends StatefulWidget {
  final String reportId;

  const ReportProcessingScreen({super.key, required this.reportId});

  @override
  State<ReportProcessingScreen> createState() => _ReportProcessingScreenState();
}

class _ReportProcessingScreenState extends State<ReportProcessingScreen> {
  _Step _step = _Step.validating;
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
        _errorMessage = e.userMessage;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _validationSummary = validation);

    if (validation.status != 'validated') {
      // Backend set status to "failed" — e.g. no valid rows in the report.
      setState(() {
        _step = _Step.failed;
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
        _errorMessage = e.userMessage;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _bonusSummary = bonus);

    if (bonus.status != 'completed') {
      setState(() {
        _step = _Step.failed;
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
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.lg),
            _StageRow(
              label: 'Validating extracted data',
              state: _stateFor(_Step.validating),
            ),
            _StageRow(
              label: 'Calculating bonuses',
              state: _stateFor(_Step.calculating),
            ),
            _StageRow(
              label: _step == _Step.failed ? 'Failed' : 'Completed',
              state: _step == _Step.failed
                  ? _StageState.error
                  : _stateFor(_Step.completed),
            ),
            const SizedBox(height: AppSpacing.xl),
            if (_step == _Step.failed && _errorMessage != null) ...[
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
            if (_step == _Step.completed) ...[
              Text(
                '${_bonusSummary?.calculatedCount ?? 0} bonus(es) calculated successfully.',
                textAlign: TextAlign.center,
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
          ],
        ),
      ),
    );
  }

  _StageState _stateFor(_Step step) {
    if (_step.index > step.index || _step == _Step.completed) {
      return _StageState.done;
    }
    if (_step == step) return _StageState.active;
    return _StageState.pending;
  }
}

enum _StageState { pending, active, done, error }

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
