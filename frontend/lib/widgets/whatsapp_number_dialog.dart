import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';

/// Lets the admin type or change a casino user's WhatsApp number. The number
/// is saved permanently by [onSave] (a call to the backend, which stores it
/// in Supabase); the dialog only closes once that save has really succeeded,
/// so a number is never shown as saved when it was not.
///
/// Returns the number as saved (the backend tidies it, e.g. removes spaces),
/// an empty string if it was cleared, or null if the dialog was cancelled.
Future<String?> showWhatsAppNumberDialog(
  BuildContext context, {
  required String userName,
  required String? currentNumber,
  required Future<String?> Function(String number) onSave,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _WhatsAppNumberDialog(
      userName: userName,
      currentNumber: currentNumber,
      onSave: onSave,
    ),
  );
}

class _WhatsAppNumberDialog extends StatefulWidget {
  final String userName;
  final String? currentNumber;
  final Future<String?> Function(String number) onSave;

  const _WhatsAppNumberDialog({
    required this.userName,
    required this.currentNumber,
    required this.onSave,
  });

  @override
  State<_WhatsAppNumberDialog> createState() => _WhatsAppNumberDialogState();
}

class _WhatsAppNumberDialogState extends State<_WhatsAppNumberDialog> {
  late final TextEditingController _controller;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentNumber ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.onSave(_controller.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop(saved ?? '');
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
      title: Text('WhatsApp number — ${widget.userName}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'WhatsApp number',
                hintText: 'Country code first, e.g. 919876543210',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              onSubmitted: (_) => _saving ? null : _save(),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Include the country code (for example 91 for India). The number is saved '
              'permanently for this user. Leave it empty to remove it.',
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
              : const Text('Save'),
        ),
      ],
    );
  }
}
