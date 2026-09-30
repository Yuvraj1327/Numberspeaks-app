import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/bonus_result.dart';
import '../repositories/report_repository.dart';
import '../routing/app_router.dart';
import '../widgets/status_pill.dart';

/// Screen 6 — Individual User Bonus Details.
///
/// Uses GET /api/v1/reports/{report_id}/results/{user_id} to refresh the
/// result passed in from the Results screen, including its durable
/// `whatsapp_status` (the latest send outcome, persisted server-side —
/// survives app restarts). A same-session send is preferred when present
/// since it can be more specific (see ReportRepository.
/// sessionWhatsAppStatusFor). There is no per-user WhatsApp send endpoint —
/// only a report-wide one (see Results screen) — so this screen shows
/// status and directs the user back to the report-wide action rather than
/// inventing one.
class UserDetailScreen extends StatefulWidget {
  final UserDetailArgs args;

  const UserDetailScreen({super.key, required this.args});

  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> {
  late BonusResult _result;
  bool _refreshing = false;
  String? _refreshError;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _result = widget.args.initialResult;
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    final repo = context.read<ReportRepository>();
    try {
      final fresh = await repo.getUserResult(widget.args.reportId, _result.userId);
      if (!mounted) return;
      setState(() {
        _result = fresh;
        _refreshing = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _refreshError = e.userMessage;
        _refreshing = false;
      });
    }
  }

  /// Same "no per-user send endpoint" reality as the Results screen's
  /// Retry action — this calls the report-wide send again, which already
  /// skips anyone already sent and only (re)attempts pending/failed
  /// numbers. See README "known gaps".
  Future<void> _retryWhatsApp() async {
    setState(() => _retrying = true);
    final repo = context.read<ReportRepository>();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Retrying WhatsApp for pending/failed users on this report…')),
    );
    try {
      await repo.sendWhatsApp(widget.args.reportId);
      if (!mounted) return;
      setState(() => _retrying = false);
      _refresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _retrying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage), backgroundColor: AppTheme.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ReportRepository>();
    // The session cache (if a send just happened) can be more specific
    // than the backend's own latest-status field; otherwise fall back to
    // that durable value from GET /results, which is always present. Then
    // normalized for display so a user with no WhatsApp number on file
    // always reads "No Number" (see BonusResult.displayWhatsAppStatus).
    final rawWhatsAppStatus =
        repo.sessionWhatsAppStatusFor(widget.args.reportId, _result.bonusResultId) ??
            _result.whatsappStatus;
    final whatsAppStatus = _result.displayWhatsAppStatus(rawWhatsAppStatus);
    final canRetry = whatsAppStatus == 'failed' || whatsAppStatus == 'not_sent';

    return Scaffold(
      appBar: AppBar(
        title: Text(_result.userName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: _refreshing
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_refreshError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                  'Could not refresh: $_refreshError',
                  style: const TextStyle(color: AppTheme.warning),
                  textAlign: TextAlign.center,
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  children: [
                    Text(
                      _result.bonusAmount != null
                          ? Formatters.amount(_result.bonusAmount!)
                          : 'Not calculated yet',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: _result.bonusAmount != null ? AppTheme.success : Colors.black38,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text('Bonus Amount', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(label: 'User Name', value: _result.userName),
                    _DetailRow(label: 'WhatsApp Number', value: _result.whatsappNumber ?? 'Not on file'),
                    _DetailRow(label: 'Level', value: _result.level ?? '—'),
                    _DetailRow(label: 'Casino Pts', value: Formatters.points(_result.casinoPts)),
                    _DetailRow(label: 'Sport Pts', value: Formatters.points(_result.sportPts)),
                    _DetailRow(
                        label: 'Third Party Pts', value: Formatters.points(_result.thirdPartyPts)),
                    _DetailRow(label: 'Profit/Loss', value: Formatters.points(_result.profitLoss)),
                    _DetailRow(label: 'Ptype', value: _result.ptype ?? '—', isLast: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.chat_outlined, color: AppTheme.primary),
                        const SizedBox(width: AppSpacing.sm),
                        Text('WhatsApp Status',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        StatusPill.forWhatsAppStatus(whatsAppStatus),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _messageForStatus(whatsAppStatus),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (canRetry) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _retrying ? null : _retryWhatsApp,
                          icon: _retrying
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.refresh),
                          label: Text(_retrying ? 'Retrying…' : 'Retry WhatsApp'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back to Results'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _messageForStatus(String status) {
    switch (status) {
      case 'sent':
        return 'The bonus message was sent successfully to this user.';
      case 'skipped_already_sent':
        return 'This user already had a successfully sent message for this report.';
      case 'failed':
        return 'Sending the WhatsApp message to this user failed.';
      case 'skipped_no_number':
        return 'This user has no WhatsApp number on file.';
      case 'skipped_no_bonus':
        return 'No bonus is owed for this user, so no message was sent.';
      case 'not_sent':
        return 'No WhatsApp message has been sent to this user yet for this report. '
            'Use Retry below, or "Send Bonus via WhatsApp" on the Results screen, '
            'to send to all eligible users on this report.';
      default:
        return 'Status: $status';
    }
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLast;

  const _DetailRow({required this.label, required this.value, this.isLast = false});

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
              Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (!isLast) const Divider(),
      ],
    );
  }
}
