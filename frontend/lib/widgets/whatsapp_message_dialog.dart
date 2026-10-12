import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/whatsapp_link.dart';
import '../models/bonus_result.dart';
import '../repositories/report_repository.dart';

/// "Send WhatsApp": shows the saved number and an editable message, then
/// opens WhatsApp (the app, or WhatsApp Web, depending on the device) with a
/// pre-filled `wa.me` link. Nothing is sent automatically — the admin presses
/// Send inside WhatsApp.
///
/// Only after the link was really launched does the dialog tell the backend
/// that WhatsApp was *opened* for this user. That is recorded as "Opened",
/// never as "Sent" or "Delivered".
///
/// Returns the updated result (with the new "opened" record), or null if
/// nothing was opened.
Future<BonusResult?> showWhatsAppMessageDialog(
  BuildContext context, {
  required BonusResult result,
}) {
  return showDialog<BonusResult>(
    context: context,
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
  bool _busy = false;

  /// True once the wa.me link has been launched but the "opened" record has
  /// not been saved yet (so only the record is retried, never the launch).
  bool _launchedAwaitingRecord = false;
  String? _error;

  String get _number => widget.result.whatsappNumber ?? '';

  String get _defaultMessage => WhatsAppLink.defaultMessage(
        userId: widget.result.userName,
        payableBonus: widget.result.payable,
      );

  @override
  void initState() {
    super.initState();
    _message = TextEditingController(text: _defaultMessage);
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'The message cannot be empty.');
      return;
    }
    if (!WhatsAppLink.isUsableNumber(_number)) {
      setState(() => _error = 'This number does not look valid. Edit it and include the country code.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    // The launch is the very first awaited call so that, on the web, the
    // browser still treats it as a direct result of the admin's click.
    var launched = false;
    try {
      launched = await launchUrl(
        WhatsAppLink.build(number: _number, message: text),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }

    if (!mounted) return;
    if (!launched) {
      setState(() {
        _busy = false;
        _error = 'Could not open WhatsApp. Make sure WhatsApp (or a web browser) is available '
            'on this device. Nothing was recorded.';
      });
      return;
    }

    _launchedAwaitingRecord = true;
    await _record(text);
  }

  Future<void> _record(String message) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final record = await context.read<ReportRepository>().recordWhatsAppOpened(
            reportId: widget.result.reportId,
            bonusResultId: widget.result.bonusResultId,
            whatsappNumber: _number,
            message: message,
          );
      if (!mounted) return;
      Navigator.of(context).pop(
        widget.result.copyWith(
          whatsappStatus: record.status,
          whatsappInitiatedAt: record.initiatedAt,
          whatsappInitiatedCount: record.count,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'WhatsApp was opened, but saving that record failed: ${e.userMessage}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Send WhatsApp'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.person_outline, size: 18, color: Colors.black54),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      widget.result.userName,
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    Formatters.rupees(widget.result.payable),
                    style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.success),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  const Icon(Icons.phone_outlined, size: 18, color: Colors.black54),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: Text(_number)),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _message,
                enabled: !_busy && !_launchedAwaitingRecord,
                minLines: 3,
                maxLines: 6,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: 'Message (you can edit it)',
                  alignLabelWithHint: true,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: (_busy || _launchedAwaitingRecord)
                      ? null
                      : () => setState(() => _message.text = _defaultMessage),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Reset to default message'),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'This opens WhatsApp with the message ready. Nothing is sent until you press '
                'Send inside WhatsApp.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
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
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(_launchedAwaitingRecord ? 'Close' : 'Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: _busy
              ? null
              : (_launchedAwaitingRecord ? () => _record(_message.text.trim()) : _open),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.success,
            foregroundColor: Colors.white,
            minimumSize: const Size(150, 44),
          ),
          icon: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Icon(_launchedAwaitingRecord ? Icons.save_outlined : Icons.open_in_new, size: 18),
          label: Text(_launchedAwaitingRecord ? 'Save record' : 'Open WhatsApp'),
        ),
      ],
    );
  }
}
