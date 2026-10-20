import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../core/whatsapp_link.dart';
import '../models/bonus_result.dart';
import '../repositories/report_repository.dart';

/// Opens a `wa.me` link in WhatsApp. Replaced in tests.
typedef WhatsAppOpener = Future<bool> Function(Uri uri);

Future<bool> _defaultOpener(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

/// The saved message template and the week label for [reportId], falling back
/// to the built-in message if either cannot be loaded.
Future<({String template, String week})> loadMessageContext(
    BuildContext context, String reportId) async {
  final repo = context.read<ReportRepository>();
  var template = WhatsAppLink.defaultTemplate;
  var week = '';
  try {
    template = (await repo.getSettings()).whatsappTemplate ?? template;
  } catch (_) {}
  try {
    final label = (await repo.getReport(reportId)).periodLabel;
    week = label == '—' ? '' : label;
  } catch (_) {}
  return (template: template, week: week);
}

/// "Manual Send": for each recipient, one at a time, shows the editable message
/// and opens their WhatsApp chat (`wa.me`) with it pre-filled. The admin presses
/// send inside WhatsApp themselves.
///
/// Opening WhatsApp is NOT delivery and is never recorded as such: this dialog
/// only counts "opened" and "skipped", and the backend's send status is untouched.
Future<void> showWhatsAppManualDialog(
  BuildContext context, {
  required List<BonusResult> targets,
  required String template,
  required String week,
  String title = 'Manual Send',
  WhatsAppOpener opener = _defaultOpener,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ManualSendDialog(
        targets: targets, template: template, week: week, title: title, opener: opener),
  );
}

class ManualSendDialog extends StatefulWidget {
  final List<BonusResult> targets;
  final String template;
  final String week;
  final String title;
  final WhatsAppOpener opener;

  const ManualSendDialog({
    super.key,
    required this.targets,
    required this.template,
    required this.week,
    required this.title,
    this.opener = _defaultOpener,
  });

  @override
  State<ManualSendDialog> createState() => _ManualSendDialogState();
}

class _ManualSendDialogState extends State<ManualSendDialog> {
  int _index = 0;
  int _opened = 0;
  int _skipped = 0;
  bool _openedCurrent = false;
  String? _error;
  late final TextEditingController _message = TextEditingController(text: _defaultFor(0));

  bool get _done => _index >= widget.targets.length;
  BonusResult get _current => widget.targets[_index];

  String _defaultFor(int i) {
    if (i >= widget.targets.length) return '';
    final r = widget.targets[i];
    return WhatsAppLink.render(
      widget.template,
      userId: r.userName,
      name: r.userName,
      payableBonus: r.payable,
      personalBonus: r.personalAdjustment ?? 0,
      referralBonus: r.referralAdjustment ?? 0,
      carriedBalance: r.previousBalance ?? 0,
      week: widget.week,
    );
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
    final number = _current.whatsappNumber ?? '';
    if (!WhatsAppLink.isUsableNumber(number)) {
      setState(() => _error = 'This number does not look valid. Edit it and include the country code.');
      return;
    }
    bool ok;
    try {
      ok = await widget.opener(WhatsAppLink.waMeUri(number, text));
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      if (ok) {
        if (!_openedCurrent) _opened++;
        _openedCurrent = true;
        _error = null;
      } else {
        _error = 'Could not open WhatsApp on this device.';
      }
    });
  }

  void _advance({required bool skipped}) {
    setState(() {
      if (skipped) _skipped++;
      _index++;
      _openedCurrent = false;
      _error = null;
      _message.text = _defaultFor(_index);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return _summary(context);
    final r = _current;
    final total = widget.targets.length;
    final last = _index == total - 1;
    return AlertDialog(
      scrollable: true,
      title: Text(total > 1 ? '${widget.title} (${_index + 1} of $total)' : widget.title),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recipient: ${r.userName}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('WhatsApp number: ${r.whatsappNumber ?? ''}'),
            Text('Bonus: ${Formatters.rupees(r.payable)}',
                style: const TextStyle(color: AppTheme.success, fontWeight: FontWeight.w700)),
            if (widget.week.isNotEmpty) Text('Week: ${widget.week}'),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('manual-message'),
              controller: _message,
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
                onPressed: () => setState(() => _message.text = _defaultFor(_index)),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset to default message'),
              ),
            ),
            Text(
              _openedCurrent
                  ? 'WhatsApp was opened. Press send in WhatsApp yourself; this app cannot tell '
                      'whether it was sent or delivered.'
                  : 'Nothing is sent from here: WhatsApp opens with this message ready for you to send.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: _openedCurrent ? AppTheme.warning : Colors.black54),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Stop'),
        ),
        if (total > 1 || !_openedCurrent)
          TextButton(
            key: const Key('manual-skip'),
            onPressed: () => _advance(skipped: !_openedCurrent),
            child: Text(_openedCurrent ? (last ? 'Finish' : 'Next') : 'Skip'),
          ),
        ElevatedButton.icon(
          key: const Key('manual-open'),
          onPressed: _open,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.success,
            foregroundColor: Colors.white,
            minimumSize: const Size(170, 44),
          ),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(_openedCurrent ? 'Open again' : 'Open WhatsApp'),
        ),
        if (total == 1 && _openedCurrent)
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }

  Widget _summary(BuildContext context) {
    return AlertDialog(
      title: const Text('Manual send finished'),
      content: Text(
        'WhatsApp was opened for $_opened user${_opened == 1 ? '' : 's'}; $_skipped skipped.\n\n'
        'Opening WhatsApp is not delivery. Delivery statuses in this app are unchanged.',
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}
