import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/bonus_result.dart';

/// The "WhatsApp Number input + Send WhatsApp button" asked for on every
/// result row. The admin types/edits the number here; pressing Send opens
/// WhatsApp itself (via a `wa.me` link) with the bonus message already
/// typed in — nothing is ever sent automatically through an API call from
/// this app. The admin still has to press Send *inside* WhatsApp.
///
/// Message format (fixed, per the brief):
///   Dear {User Name},
///
///   ₹{Bonus Amount} has been created to your wallet.
///   Please enjoy the game!
///
/// Used by both the Results screen and the User Detail screen so this
/// behavior — and the exact message text — exists in exactly one place.
class WhatsAppSendField extends StatefulWidget {
  final BonusResult result;

  /// Called with the trimmed number whenever the admin finishes editing it
  /// (on submit, tapping away, or right before Send) — never on every
  /// keystroke. The caller is expected to persist it (see
  /// `ReportRepository.saveWhatsAppNumber`) so it survives a refresh or a
  /// logout/login, per this round's storage brief.
  final ValueChanged<String> onNumberSaved;

  const WhatsAppSendField({
    super.key,
    required this.result,
    required this.onNumberSaved,
  });

  @override
  State<WhatsAppSendField> createState() => _WhatsAppSendFieldState();
}

class _WhatsAppSendFieldState extends State<WhatsAppSendField> {
  late final TextEditingController _controller;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.result.whatsappNumber ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Bonus eligibility mirrors the rest of the app (`bonusAmount != null`
  /// and > 0) — a user who isn't owed anything has no bonus message to
  /// send, so Send is disabled rather than sending a "₹0.00" message.
  bool get _hasBonus => (widget.result.bonusAmount ?? 0) > 0;

  String get _digitsOnly => _controller.text.replaceAll(RegExp(r'[^0-9]'), '');

  void _persistIfChanged() {
    final trimmed = _controller.text.trim();
    if (trimmed != (widget.result.whatsappNumber ?? '')) {
      widget.onNumberSaved(trimmed);
    }
  }

  Future<void> _send() async {
    final digits = _digitsOnly;
    if (digits.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a WhatsApp number first.')),
      );
      return;
    }

    _persistIfChanged();
    setState(() => _sending = true);

    final message = 'Dear ${widget.result.userName},\n\n'
        '₹${Formatters.amount(widget.result.bonusAmount ?? 0)} has been created to your wallet.\n'
        'Please enjoy the game!';
    final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(message)}');

    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }

    if (!mounted) return;
    setState(() => _sending = false);
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open WhatsApp. Make sure it (or a browser) is available on this device.'),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'WhatsApp Number',
                  hintText: 'Country code + number, e.g. 9198XXXXXXXX',
                  isDense: true,
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
                onEditingComplete: _persistIfChanged,
                onTapOutside: (_) => _persistIfChanged(),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            ElevatedButton.icon(
              onPressed: (_hasBonus && !_sending) ? _send : null,
              style: ElevatedButton.styleFrom(
                // The theme's minimumSize is full-width (Size.fromHeight);
                // inside this Row that means an infinite minimum width and a
                // layout error on every result card.
                minimumSize: const Size(0, 48),
                backgroundColor: AppTheme.success,
                disabledBackgroundColor: AppTheme.success.withOpacity(0.35),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
              icon: _sending
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_outlined, size: 18),
              label: const Text('Send'),
            ),
          ],
        ),
        if (!_hasBonus)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'No bonus owed for this user — nothing to send.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black45),
            ),
          ),
      ],
    );
  }
}
