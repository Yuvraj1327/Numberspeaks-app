import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/whatsapp_link.dart';
import '../models/bonus_result.dart';
import '../repositories/report_repository.dart';

/// What happened in the confirmation dialog.
class WhatsAppSendOutcome {
  /// The result with its new send status, or null if nothing changed.
  final BonusResult? result;

  /// True when the server's state may differ from the screen's (for example
  /// the server said a send is already in flight): reload the results.
  final bool refresh;

  const WhatsAppSendOutcome({this.result, this.refresh = false});
}

/// "Auto Send WhatsApp": shows the recipient, number, bonus amount and the
/// exact message (editable). NOTHING is sent until the admin presses
/// "Confirm & Send"; the message then goes through the backend's No1API
/// integration. The send status shown afterwards is what the backend
/// recorded, never a guess.
///
/// Returns null if the dialog was cancelled without any attempt.
Future<WhatsAppSendOutcome?> showWhatsAppMessageDialog(
  BuildContext context, {
  required BonusResult result,
}) {
  return showDialog<WhatsAppSendOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _WhatsAppMessageDialog(result: result),
  );
}

class _WhatsAppMessageDialog extends StatefulWidget {
  final BonusResult result;

  const _WhatsAppMessageDialog({required this.result});

  @override
  State<_WhatsAppMessageDialog> createState() => _WhatsAppMessageDialogState();
}

class _WhatsAppMessageDialogState extends State<_WhatsAppMessageDialog> {
  late final TextEditingController _message;
  late BonusResult _result = widget.result;
  bool _busy = false;
  bool _attempted = false;
  bool _refresh = false;

  /// For a message whose last attempt ended 'unknown' (it may already be on the
  /// user's phone): the admin must confirm they checked before a re-send.
  bool _checkedUnknown = false;
  String? _error;

  /// The last status the server actually reported (what to fall back to when
  /// a request fails without an answer).
  late String _knownStatus = widget.result.sendStatus;

  String get _number => _result.whatsappNumber ?? '';

  String _template = WhatsAppLink.defaultTemplate;
  String _week = '';

  String get _defaultMessage {
    final r = _result;
    return WhatsAppLink.render(
      _template,
      userId: r.userName,
      name: r.userName,
      payableBonus: r.payable,
      personalBonus: r.personalAdjustment ?? 0,
      referralBonus: r.referralAdjustment ?? 0,
      carriedBalance: r.previousBalance ?? 0,
      week: _week,
    );
  }

  @override
  void initState() {
    super.initState();
    _message = TextEditingController(text: _defaultMessage);
    _loadTemplate();
  }

  /// Fetches the saved template and the week; replaces the text only if the
  /// admin has not started typing their own.
  Future<void> _loadTemplate() async {
    final repo = context.read<ReportRepository>();
    try {
      final settings = await repo.getSettings();
      final report = await repo.getReport(widget.result.reportId);
      if (!mounted) return;
      final untouched = _message.text == _defaultMessage;
      _template = settings.whatsappTemplate ?? WhatsAppLink.defaultTemplate;
      _week = report.periodLabel == '—' ? '' : report.periodLabel;
      if (untouched && !_busy && !_attempted) setState(() => _message.text = _defaultMessage);
    } catch (_) {
      // Keep the built-in message; the admin can still edit it.
    }
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  bool get _locked => _busy || _result.isSent;

  Future<void> _confirmAndSend() async {
    if (_busy) return; // never two requests from one dialog
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'The message cannot be empty.');
      return;
    }
    if (!WhatsAppLink.isUsableNumber(_number)) {
      setState(
          () => _error = 'This number does not look valid. Edit it and include the country code.');
      return;
    }

    setState(() {
      _busy = true;
      _attempted = true;
      _error = null;
      _result = _result.copyWith(sendStatus: 'sending', clearSendError: true);
    });

    try {
      final sent = await context.read<ReportRepository>().sendWhatsApp(
            reportId: _result.reportId,
            bonusResultId: _result.bonusResultId,
            message: text,
            acknowledgeUnknown: _knownStatus == 'unknown' && _checkedUnknown,
          );
      if (!mounted) return;
      _knownStatus = sent.status;
      setState(() {
        _busy = false;
        _result = _result.copyWith(
          sendStatus: sent.status,
          sendError: sent.error,
          clearSendError: sent.error == null,
          sentAt: sent.sentAt,
        );
        _error = switch (sent.status) {
          'failed' => sent.error ?? 'Sending failed.',
          'unknown' =>
            'Not confirmed: ${sent.error ?? 'the provider gave no clear answer.'} The message may '
                'already have been delivered. Check WhatsApp before sending again.',
          _ => null,
        };
        _checkedUnknown = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // 409: the server already has a send in flight or sent. 503/422: the
      // backend refused before sending anything. Otherwise (network, timeout,
      // 5xx) the request may or may not have been processed; retrying is still
      // safe because the server refuses a duplicate while sending or after sent.
      final conflict = e.kind == ApiErrorKind.conflict;
      final refused = conflict || e.statusCode == 503 || e.kind == ApiErrorKind.validation;
      setState(() {
        _busy = false;
        _refresh = true;
        _result = _result.copyWith(sendStatus: _knownStatus);
        if (conflict) {
          _error = '${e.userMessage} Refresh the results to see its current status.';
        } else if (refused) {
          _error = e.message.isNotEmpty ? '${e.message} Nothing was sent.' : e.userMessage;
        } else {
          _error =
              'Could not confirm the result. ${e.userMessage} The message may or may not have been '
              'sent; retrying will not send it twice.';
        }
      });
    }
  }

  void _close() {
    Navigator.of(context).pop(
      (_attempted || _refresh)
          ? WhatsAppSendOutcome(result: _attempted ? _result : null, refresh: _refresh)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sent = _result.isSent;
    final retry = _result.canRetrySend || _attempted && !sent;
    final needsCheck = _knownStatus == 'unknown' && !_busy;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Confirm WhatsApp message'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _line(Icons.person_outline, 'Recipient', _result.userName),
              const SizedBox(height: AppSpacing.xs),
              _line(Icons.phone_outlined, 'WhatsApp number', _number),
              const SizedBox(height: AppSpacing.xs),
              _line(Icons.savings_outlined, 'Bonus amount', Formatters.rupees(_result.payable),
                  valueColor: AppTheme.success),
              if (needsCheck) ...[
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'A previous attempt for this user is Unknown: the message may already have been '
                  'delivered. Check WhatsApp first.',
                  style: TextStyle(color: AppTheme.warning, fontWeight: FontWeight.w600),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _checkedUnknown,
                  onChanged: (v) => setState(() => _checkedUnknown = v ?? false),
                  title: const Text('I checked: it was not delivered. Send again.',
                      style: TextStyle(fontSize: 13)),
                ),
              ],
              if (_result.isSending && !_busy) ...[
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'A previous send for this user never finished, so its outcome is unknown. '
                  'Check WhatsApp before sending again.',
                  style: TextStyle(color: AppTheme.warning, fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _message,
                enabled: !_locked,
                minLines: 3,
                maxLines: 6,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: 'Message to send (you can edit it)',
                  alignLabelWithHint: true,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _locked ? null : () => setState(() => _message.text = _defaultMessage),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Reset to default message'),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              if (sent)
                const Text('Sent. The provider confirmed this message.',
                    style: TextStyle(color: AppTheme.success, fontWeight: FontWeight.w700))
              else if (_busy)
                const Text('Sending…', style: TextStyle(fontWeight: FontWeight.w700))
              else
                Text(
                  'Nothing is sent until you press Confirm & Send.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: const TextStyle(color: AppTheme.danger)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _close,
            child: Text(sent || _attempted ? 'Close' : 'Cancel'),
          ),
          if (!sent)
            ElevatedButton.icon(
              onPressed: (_busy || needsCheck && !_checkedUnknown) ? null : _confirmAndSend,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.success,
                foregroundColor: Colors.white,
                minimumSize: const Size(170, 44),
              ),
              icon: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_outlined, size: 18),
              label: Text(retry ? 'Retry send' : 'Confirm & Send'),
            ),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String label, String value, {Color? valueColor}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.black54),
        const SizedBox(width: AppSpacing.xs),
        Text('$label: ', style: const TextStyle(color: Colors.black54)),
        Expanded(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700, color: valueColor),
          ),
        ),
      ],
    );
  }
}
