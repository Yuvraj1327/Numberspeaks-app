import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/bonus_result.dart';
import '../models/report_progress.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/screen_header.dart';

/// The stages a report moves through, in order. Every stage except
/// [saving] corresponds to a real backend status (`processing`,
/// `validating`, `calculating`, `completed`); [uploaded] is already true by
/// the time this screen opens. The backend has no separate "saving" status
/// (results are written as part of calculating and are complete once the
/// report reads `completed`), so [saving] is shown as done only at that
/// point — it is never shown as in progress, because nothing reports that.
enum _Stage { uploaded, processing, validating, calculating, saving, completed }

extension on _Stage {
  String get label {
    switch (this) {
      case _Stage.uploaded:
        return 'Uploaded';
      case _Stage.processing:
        return 'Processing';
      case _Stage.validating:
        return 'Validating';
      case _Stage.calculating:
        return 'Calculating';
      case _Stage.saving:
        return 'Saving Results';
      case _Stage.completed:
        return 'Completed';
    }
  }

  String get headline {
    switch (this) {
      case _Stage.uploaded:
      case _Stage.processing:
        return 'Processing your report';
      case _Stage.validating:
        return 'Validating records';
      case _Stage.calculating:
        return 'Calculating bonuses';
      case _Stage.saving:
        return 'Saving results';
      case _Stage.completed:
        return 'Processing complete';
    }
  }

  String get detail {
    switch (this) {
      case _Stage.uploaded:
      case _Stage.processing:
        return 'Reading the PDF and extracting every user row…';
      case _Stage.validating:
        return 'Checking each row for missing or invalid values…';
      case _Stage.calculating:
        return 'Working out the bonus for every user…';
      case _Stage.saving:
        return 'Storing the final results…';
      case _Stage.completed:
        return 'Your results are ready.';
    }
  }
}

/// Screen 4 — Report Processing.
///
/// Two backends are supported, chosen at runtime by what the server
/// actually offers (never assumed):
///
///  - Background processing: the server queues the report on upload and
///    exposes `GET /reports/{id}/status`. This screen polls that and shows
///    exactly the status the server reports.
///  - Manual (older servers without `/status`): this screen drives the two
///    real calls itself — `POST /validate`, then `POST /calculate-bonus` —
///    and shows a stage as active only while its call is really in flight.
///
/// A request that times out is NOT shown as "Failed" — a timeout means the
/// server never told us the outcome, not that the outcome was bad.
class ReportProcessingScreen extends StatefulWidget {
  final String reportId;

  const ReportProcessingScreen({super.key, required this.reportId});

  @override
  State<ReportProcessingScreen> createState() => _ReportProcessingScreenState();
}

class _ReportProcessingScreenState extends State<ReportProcessingScreen> {
  static const _pollInterval = Duration(seconds: 2);
  // Consecutive failed status polls tolerated before giving up (each poll
  // already retries internally), so a brief server restart doesn't abort.
  static const _maxPollFailures = 5;

  _Stage _active = _Stage.processing;
  _Stage? _failedAt;
  bool _allDone = false;
  bool _isTimeout = false;
  String? _errorMessage;
  // True when the *backend itself* reported `failed` — Try Again then
  // re-runs the manual validate/calculate path rather than re-polling a
  // status that will never change.
  bool _backendFailed = false;
  ReportProgress? _progress;

  // Final results (for the completion summary). Null = not loaded.
  List<BonusResult>? _results;
  bool _loadingResults = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  bool get _running => !_allDone && _failedAt == null;

  Future<void> _run({bool manual = false}) async {
    setState(() {
      _active = _Stage.processing;
      _failedAt = null;
      _allDone = false;
      _isTimeout = false;
      _errorMessage = null;
      _results = null;
    });

    if (!manual) {
      final handled = await _followBackendStatus();
      if (handled) return;
    }
    await _runManually();
  }

  // --- Background processing: poll the real status ------------------------

  /// Returns true if the server supports `/status` (and this method took
  /// the run to a final state), false if the manual flow should be used.
  Future<bool> _followBackendStatus() async {
    final repo = context.read<ReportRepository>();
    var failures = 0;

    while (mounted) {
      ReportProgress progress;
      try {
        progress = await repo.getReportStatus(widget.reportId);
        failures = 0;
      } on ApiException catch (e) {
        // Older servers have no /status route: FastAPI's generic 404
        // ("Not Found"), unlike the real "No report found with id …".
        if (e.kind == ApiErrorKind.notFound && e.message == 'Not Found') return false;
        if (!mounted) return true;
        failures++;
        if (failures >= _maxPollFailures || e.kind == ApiErrorKind.notFound) {
          _fail(e);
          return true;
        }
        await Future<void>.delayed(_pollInterval);
        continue;
      }
      if (!mounted) return true;

      setState(() => _progress = progress);

      switch (progress.status) {
        case 'completed':
          await _finish(progress.status);
          return true;
        case 'failed':
          setState(() {
            _failedAt = _active;
            _backendFailed = true;
            _isTimeout = false;
            _errorMessage = (progress.errorMessage?.isNotEmpty ?? false)
                ? progress.errorMessage
                : 'The report could not be processed.';
          });
          return true;
        case 'validated':
          // Validated through the manual endpoints and waiting for the
          // bonus step — nothing is running server-side to wait for.
          return false;
        case 'validating':
          setState(() => _active = _Stage.validating);
          break;
        case 'calculating':
          setState(() => _active = _Stage.calculating);
          break;
        default: // uploaded | processing
          setState(() => _active = _Stage.processing);
      }
      await Future<void>.delayed(_pollInterval);
    }
    return true;
  }

  // --- Manual flow for servers without background processing --------------

  Future<void> _runManually() async {
    final repo = context.read<ReportRepository>();
    final alreadyValidated = _progress?.status == 'validated';

    if (!alreadyValidated) {
      setState(() => _active = _Stage.validating);
      try {
        final validation = await repo.validateReport(widget.reportId);
        if (!mounted) return;
        if (validation.status != 'validated') {
          setState(() {
            _failedAt = _Stage.validating;
            _isTimeout = false;
            _errorMessage = validation.validCount == 0
                ? 'None of the ${validation.totalInputRecords} extracted row(s) passed validation.'
                : 'Validation did not complete successfully.';
          });
          return;
        }
      } on ApiException catch (e) {
        if (mounted) _fail(e, at: _Stage.validating);
        return;
      }
    }

    setState(() => _active = _Stage.calculating);
    try {
      final bonus = await repo.calculateBonus(widget.reportId);
      if (!mounted) return;
      if (bonus.status != 'completed') {
        setState(() {
          _failedAt = _Stage.calculating;
          _isTimeout = false;
          _errorMessage = 'Bonus calculation did not complete successfully.';
        });
        return;
      }
      // calculateBonus already recorded history/activity for this run.
      setState(() {
        _results = bonus.results;
        _allDone = true;
      });
    } on ApiException catch (e) {
      if (mounted) _fail(e, at: _Stage.calculating);
    }
  }

  // --- Shared ---------------------------------------------------------------

  void _fail(ApiException e, {_Stage? at}) {
    setState(() {
      _failedAt = at ?? _active;
      _isTimeout = e.kind == ApiErrorKind.timeout;
      _errorMessage = e.userMessage;
    });
  }

  /// The backend says `completed`: load the real results for the summary.
  /// A failure to load them doesn't undo the completed report.
  Future<void> _finish(String status) async {
    final repo = context.read<ReportRepository>();
    setState(() {
      _allDone = true;
      _loadingResults = true;
    });
    try {
      final results = await repo.getResults(widget.reportId);
      await repo.recordBackgroundRunFinished(widget.reportId, status: status, results: results);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loadingResults = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() => _loadingResults = false);
    }
  }

  _StageState _stateFor(_Stage stage) {
    if (_allDone) return _StageState.done;
    final failedAt = _failedAt;
    if (failedAt != null) {
      if (stage.index < failedAt.index) return _StageState.done;
      if (stage == failedAt) return _isTimeout ? _StageState.timeout : _StageState.error;
      return _StageState.pending;
    }
    if (stage.index < _active.index) return _StageState.done;
    if (stage == _active) return _StageState.active;
    return _StageState.pending;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Processing Report')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusCard(context),
            const SizedBox(height: AppSpacing.md),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg - 4, vertical: AppSpacing.sm),
                child: Column(
                  children: [
                    for (final stage in _Stage.values)
                      _StageRow(
                        label: stage.label,
                        state: _stateFor(stage),
                        isLast: stage == _Stage.values.last,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_failedAt != null && _errorMessage != null) _buildFailure(context),
            if (_allDone) _buildCompletion(context),
          ],
        ),
      ),
    );
  }

  /// The big "what is happening right now" card at the top.
  Widget _buildStatusCard(BuildContext context) {
    final failed = _failedAt != null;
    final Color color = failed
        ? (_isTimeout ? AppTheme.warning : AppTheme.danger)
        : _allDone
            ? AppTheme.success
            : AppTheme.primary;
    final IconData icon = failed
        ? (_isTimeout ? Icons.schedule_outlined : Icons.error_outline)
        : _allDone
            ? Icons.check_circle_outline
            : Icons.auto_graph_rounded;

    final title = failed
        ? (_isTimeout ? 'Taking longer than expected' : 'Processing failed')
        : _allDone
            ? _Stage.completed.headline
            : _active.headline;
    final detail = failed
        ? 'Stopped at: ${(_failedAt ?? _active).label}'
        : _allDone
            ? _Stage.completed.detail
            : _active.detail;

    final progress = _progress;
    final facts = <String>[
      if (progress != null && progress.pagesProcessed > 0) '${progress.pagesProcessed} page(s) read',
      if (progress != null && progress.totalRecords > 0) '${progress.totalRecords} record(s) found',
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            IconBadge(icon: icon, color: color, size: 64),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.navy),
            ),
            const SizedBox(height: AppSpacing.xs + 2),
            Text(detail, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                facts.join('  •  '),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.navy, fontSize: 13.5, fontWeight: FontWeight.w500),
              ),
            ],
            if (_running) ...[
              const SizedBox(height: AppSpacing.lg - 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: const LinearProgressIndicator(minHeight: 8),
              ),
              const SizedBox(height: AppSpacing.sm + 2),
              Text(
                'Large reports can take a minute. You can keep this screen open.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFailure(BuildContext context) {
    final invalid = _progress?.failedCount ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _errorMessage!,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _isTimeout ? AppTheme.warning : AppTheme.danger,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (_isTimeout) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'This does not necessarily mean it failed — the server may still '
            'be working on it. Try again to check.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (invalid > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('$invalid row(s) had validation issues.',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton(
          onPressed: () => _run(manual: _backendFailed),
          child: const Text('Try Again'),
        ),
      ],
    );
  }

  /// Total users / bonus-eligible users / total bonus / WhatsApp sent /
  /// WhatsApp pending-or-failed — every figure comes from the real results.
  /// Right after calculation no WhatsApp send has happened yet, so "sent" is
  /// naturally 0 and "pending/failed" is the full eligible count.
  Widget _buildCompletion(BuildContext context) {
    final results = _results;
    final viewResults = ElevatedButton.icon(
      onPressed: () => Navigator.of(context).pushReplacementNamed(
        AppRoutes.results,
        arguments: widget.reportId,
      ),
      icon: const Icon(Icons.list_alt_outlined),
      label: const Text('View Results'),
    );

    if (_loadingResults) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (results == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your report is processed. The results summary could not be loaded '
            'just now — open the results to try again.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          viewResults,
        ],
      );
    }

    // "Bonus-eligible" = has a calculated bonus amount at all (the same
    // definition used by ReportRepository, Dashboard and the Reports tab).
    final eligible = results.where((r) => r.bonusAmount != null).toList();
    final totalBonus = results.fold<double>(0, (sum, r) => sum + (r.bonusAmount ?? 0));
    final whatsAppSent = eligible.where((r) => r.whatsappStatus == 'sent').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg - 4, vertical: AppSpacing.sm),
            child: Column(
              children: [
                _SummaryRow(label: 'Total users', value: '${results.length}'),
                _SummaryRow(label: 'Bonus-eligible users', value: '${eligible.length}'),
                _SummaryRow(label: 'Total bonus', value: Formatters.amount(totalBonus)),
                _SummaryRow(label: 'WhatsApp sent', value: '$whatsAppSent'),
                _SummaryRow(
                  label: 'WhatsApp pending/failed',
                  value: '${eligible.length - whatsAppSent}',
                  isLast: true,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        viewResults,
      ],
    );
  }
}

enum _StageState { pending, active, done, error, timeout }

class _StageRow extends StatelessWidget {
  final String label;
  final _StageState state;
  final bool isLast;

  const _StageRow({required this.label, required this.state, required this.isLast});

  @override
  Widget build(BuildContext context) {
    Widget icon;
    Color color;
    switch (state) {
      case _StageState.pending:
        color = AppTheme.textMuted.withOpacity(0.55);
        icon = Icon(Icons.circle_outlined, color: color);
        break;
      case _StageState.active:
        color = AppTheme.primary;
        icon = const SizedBox(
          height: 22,
          width: 22,
          child: CircularProgressIndicator(strokeWidth: 2.6),
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md - 2),
          child: Row(
            children: [
              SizedBox(height: 26, width: 26, child: Center(child: icon)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: state == _StageState.pending ? FontWeight.w700 : FontWeight.w600,
                    color: state == _StageState.pending ? AppTheme.textMuted : AppTheme.navy,
                  ),
                ),
              ),
              if (state == _StageState.active)
                const Text('In progress',
                    style: TextStyle(
                        color: AppTheme.primary, fontSize: 12.5, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1),
      ],
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
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md - 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 14)),
              Text(value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: 15.5, fontWeight: FontWeight.w700, color: AppTheme.navy)),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1),
      ],
    );
  }
}
