import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/whatsapp_link.dart';
import '../models/bonus_result.dart';
import '../repositories/report_repository.dart';
import '../services/whatsapp_api_service.dart';

/// A user who will NOT be messaged, and why (shown before confirming).
class BulkSkipPreview {
  final String userName;
  final String reason;
  const BulkSkipPreview(this.userName, this.reason);
}

/// "Send Selected" / "Send All Eligible": a full preview of every message,
/// the recipient count, who is skipped, a mandatory test-number message, and an
/// explicit confirmation. The backend then sends in the background, one
/// message at a time with a pause between them; this dialog shows its
/// recorded progress and a final success/failure summary.
Future<void> showWhatsAppBulkDialog(
  BuildContext context, {
  required String reportId,
  required String title,
  required List<BonusResult> targets,
  required List<BulkSkipPreview> skipped,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _BulkDialog(reportId: reportId, title: title, targets: targets, skipped: skipped),
  );
}

enum _Stage { preview, running, done }

class _BulkDialog extends StatefulWidget {
  final String reportId;
  final String title;
  final List<BonusResult> targets;
  final List<BulkSkipPreview> skipped;

  const _BulkDialog({
    required this.reportId,
    required this.title,
    required this.targets,
    required this.skipped,
  });

  @override
  State<_BulkDialog> createState() => _BulkDialogState();
}

class _BulkDialogState extends State<_BulkDialog> {
  _Stage _stage = _Stage.preview;
  bool _loadingPreview = true;
  bool? _testPassed;
  bool _reviewed = false;
  bool _busy = false;
  String? _error;
  Map<String, String> _messages = {};

  final _testNumber = TextEditingController();
  bool _testAuthorized = false;
  String? _testResult;

  BulkProgress? _progress;
  Timer? _poll;
  int _pollFailures = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _testNumber.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final repo = context.read<ReportRepository>();
    var template = WhatsAppLink.defaultTemplate;
    var week = '';
    try {
      final settings = await repo.getSettings();
      template = settings.whatsappTemplate ?? WhatsAppLink.defaultTemplate;
      final report = await repo.getReport(widget.reportId);
      week = report.periodLabel == '—' ? '' : report.periodLabel;
    } catch (_) {
      // Fall back to the built-in template.
    }
    bool? passed;
    try {
      passed = await repo.whatsAppTestPassed();
    } on ApiException {
      passed = null;
    }
    if (!mounted) return;
    setState(() {
      _messages = {
        for (final r in widget.targets)
          r.bonusResultId: WhatsAppLink.render(
            template,
            userId: r.userName,
            name: r.userName,
            payableBonus: r.payable,
            personalBonus: r.personalAdjustment ?? 0,
            referralBonus: r.referralAdjustment ?? 0,
            carriedBalance: r.previousBalance ?? 0,
            week: week,
          ),
      };
      _testPassed = passed;
      _loadingPreview = false;
    });
  }

  Future<void> _sendTest() async {
    final number = _testNumber.text.trim();
    if (!WhatsAppLink.isUsableNumber(number)) {
      setState(() => _testResult = 'Enter a valid test number with the country code.');
      return;
    }
    setState(() {
      _busy = true;
      _testResult = null;
    });
    try {
      final (status, error) = await context.read<ReportRepository>().sendWhatsAppTest(
            number: number,
            message: 'Test message from Numberspeaks. No action needed.',
          );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _testPassed = status == 'sent';
        _testResult = status == 'sent'
            ? 'Test message accepted by the provider. Check that it arrived on that phone.'
            : (status == 'unknown'
                ? 'The test result is unknown (no answer from the provider). Check the phone, then try again.'
                : 'Test failed: ${error ?? 'the provider rejected it.'}');
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _testResult = e.message.isNotEmpty && e.statusCode == 503 ? e.message : e.userMessage;
      });
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final progress = await context.read<ReportRepository>().startWhatsAppBulk(
        reportId: widget.reportId,
        items: [
          for (final r in widget.targets)
            (bonusResultId: r.bonusResultId, message: _messages[r.bonusResultId] ?? ''),
        ],
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = progress;
        _stage = progress.isRunning ? _Stage.running : _Stage.done;
      });
      if (progress.isRunning) _startPolling();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = (e.statusCode == 503 ||
                    e.kind == ApiErrorKind.conflict ||
                    e.kind == ApiErrorKind.validation) &&
                e.message.isNotEmpty
            ? '${e.message} Nothing was sent.'
            : 'Could not start the bulk send. ${e.userMessage} If you are unsure, close this window and '
                'check the Results table before trying again; messages already sent are never sent twice.';
      });
    }
  }

  void _startPolling() {
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final id = _progress?.batchId;
      if (id == null) return;
      try {
        final p = await context.read<ReportRepository>().whatsAppBulkProgress(widget.reportId, id);
        if (!mounted) return;
        _pollFailures = 0;
        setState(() {
          _progress = p;
          if (!p.isRunning) _stage = _Stage.done;
        });
        if (!p.isRunning) _poll?.cancel();
      } on ApiException {
        if (++_pollFailures >= 5 && mounted) {
          _poll?.cancel();
          setState(() => _error = 'Lost contact with the server. The run continues on the server; '
              'close this window and reload the results to see what was sent.');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final running = _stage == _Stage.running;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        scrollable: true,
        title: Text(widget.title),
        content: SizedBox(
          width: 520,
          child: _loadingPreview
              ? const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Center(child: CircularProgressIndicator()))
              : switch (_stage) {
                  _Stage.preview => _previewBody(context),
                  _ => _progressBody(context),
                },
        ),
        actions: [
          if (_stage == _Stage.preview) ...[
            TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
            ElevatedButton.icon(
              onPressed: (_busy || !_reviewed || _testPassed != true || widget.targets.isEmpty)
                  ? null
                  : _start,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.success,
                foregroundColor: Colors.white,
                minimumSize: const Size(170, 44),
              ),
              icon: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_outlined, size: 18),
              label: Text('Confirm & Send ${widget.targets.length}'),
            ),
          ] else
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(running ? 'Close (keeps running)' : 'Close'),
            ),
        ],
      ),
    );
  }

  Widget _previewBody(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${widget.targets.length} recipient(s) will be messaged.',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Messages go out one at a time with a pause between them. Users who are already Sent are never '
          'messaged again.',
          style: small,
        ),
        if (widget.skipped.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('${widget.skipped.length} skipped (no valid number / nothing to send)',
                style: const TextStyle(
                    color: AppTheme.warning, fontWeight: FontWeight.w700, fontSize: 13)),
            children: [
              for (final s in widget.skipped)
                ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.userName),
                    subtitle: Text(s.reason)),
            ],
          ),
        ],
        const Divider(height: AppSpacing.lg),
        _testSection(context),
        const Divider(height: AppSpacing.lg),
        Text('Message preview', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: widget.targets.isEmpty
              ? const Text('Nobody to send to.')
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final r in widget.targets) ...[
                        Text(
                            '${r.userName} • ${r.whatsappNumber} • ${Formatters.rupees(r.payable)}',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(_messages[r.bonusResultId] ?? '',
                            style: const TextStyle(fontSize: 13)),
                        const Divider(height: 12),
                      ],
                    ],
                  ),
                ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
            'To change one person\'s message, close this window and use that user\'s Auto Send button.',
            style: small),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _reviewed,
          onChanged: _busy ? null : (v) => setState(() => _reviewed = v ?? false),
          title: Text(
              'I reviewed these ${widget.targets.length} messages and confirm sending them.',
              style: const TextStyle(fontSize: 13)),
        ),
        if (_error != null) Text(_error!, style: const TextStyle(color: AppTheme.danger)),
      ],
    );
  }

  Widget _testSection(BuildContext context) {
    if (_testPassed == true && _testResult == null) {
      return const Row(
        children: [
          Icon(Icons.check_circle_outline, color: AppTheme.success, size: 18),
          SizedBox(width: AppSpacing.xs),
          Expanded(child: Text('A test message was already accepted. Bulk sending is unlocked.')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 1: send a test message', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Bulk sending stays locked until one message to a number you are authorized to message was accepted.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: _testNumber,
          enabled: !_busy && _testPassed != true,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
              labelText: 'Test WhatsApp number (with country code)', isDense: true),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _testAuthorized,
          onChanged: (_busy || _testPassed == true)
              ? null
              : (v) => setState(() => _testAuthorized = v ?? false),
          title:
              const Text('I am authorized to message this number.', style: TextStyle(fontSize: 13)),
        ),
        if (_testPassed != true)
          OutlinedButton.icon(
            onPressed: (_busy || !_testAuthorized) ? null : _sendTest,
            icon: const Icon(Icons.science_outlined, size: 18),
            label: const Text('Send test message'),
          ),
        if (_testResult != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(_testResult!,
                style: TextStyle(color: _testPassed == true ? AppTheme.success : AppTheme.danger)),
          ),
      ],
    );
  }

  Widget _progressBody(BuildContext context) {
    final p = _progress;
    if (p == null) return const SizedBox.shrink();
    final total = p.queued;
    final value = total == 0 ? 1.0 : (p.done / total).clamp(0.0, 1.0);
    final interrupted = p.status == 'interrupted';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.isRunning
              ? 'Sending… ${p.done} of $total processed'
              : interrupted
                  ? 'The run was interrupted on the server.'
                  : 'Finished: ${p.done} of $total processed',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.sm),
        LinearProgressIndicator(value: value),
        const SizedBox(height: AppSpacing.sm),
        Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.xs, children: [
          Text('Queued: ${p.providerQueued}',
              style: const TextStyle(color: AppTheme.teal, fontWeight: FontWeight.w700)),
          Text('Sent: ${p.sent}',
              style: const TextStyle(color: AppTheme.success, fontWeight: FontWeight.w700)),
          Text('Failed: ${p.failed}',
              style: const TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w700)),
          Text('Unknown: ${p.unknown}',
              style: const TextStyle(color: AppTheme.warning, fontWeight: FontWeight.w700)),
          Text('Pending: ${p.pending}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('Skipped: ${p.skipped.length}',
              style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w700)),
        ]),
        if (p.problems.isNotEmpty || p.skipped.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in p.problems)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                          '${f.userName ?? 'User'}: ${f.status == 'failed' ? 'Failed' : 'Unknown'}'),
                      subtitle: Text(f.error ?? ''),
                    ),
                  for (final s in p.skipped)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${s.userName ?? 'User'}: skipped'),
                      subtitle: Text(s.reason),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Failed and Unknown users can be retried from the Results table. Check WhatsApp first for Unknown ones.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: const TextStyle(color: AppTheme.danger)),
        ],
      ],
    );
  }
}
