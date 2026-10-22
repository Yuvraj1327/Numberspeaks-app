import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/whatsapp_link.dart';
import '../models/bonus_result.dart';
import '../models/user_profile.dart';
import '../repositories/report_repository.dart';
import 'whatsapp_manual_dialog.dart';
import 'whatsapp_message_dialog.dart';

enum WhatsAppMode { auto, manual }

/// The single "WhatsApp" button used on every user card/row. Tapping it offers
/// "Auto Send" (through the backend / No1API, with a delivery status) and
/// "Manual Send" (opens the chat via wa.me with an editable message).
class WhatsAppMenuButton extends StatelessWidget {
  final void Function(WhatsAppMode mode) onSelected;
  final bool enabled;
  final bool compact;

  const WhatsAppMenuButton({
    super.key,
    required this.onSelected,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<WhatsAppMode>(
      tooltip: 'WhatsApp',
      enabled: enabled,
      onSelected: onSelected,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: WhatsAppMode.auto,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.bolt_outlined),
            title: Text('Auto Send'),
          ),
        ),
        PopupMenuItem(
          value: WhatsAppMode.manual,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.open_in_new),
            title: Text('Manual Send'),
          ),
        ),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: compact ? 6 : 8),
        decoration: BoxDecoration(
          color: enabled ? AppTheme.success : Colors.black26,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_outlined, size: 18, color: Colors.white),
            SizedBox(width: 6),
            Flexible(
              child: Text('WhatsApp',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            Icon(Icons.arrow_drop_down, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

/// WhatsApp button for a user whose result is not loaded yet (the Users list):
/// it fetches the user's current-week result when a mode is chosen.
class UserWhatsAppButton extends StatelessWidget {
  final UserProfile user;

  /// Called after a send flow so the list can refresh.
  final VoidCallback? onChanged;

  const UserWhatsAppButton({super.key, required this.user, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return WhatsAppMenuButton(
      onSelected: (mode) async {
        await startUserWhatsApp(context, user, mode);
        onChanged?.call();
      },
    );
  }
}

/// Manual Send for an already-loaded result (Results table / user detail).
Future<void> startManualSend(BuildContext context, BonusResult result) async {
  final ctx = await loadMessageContext(context, result.reportId);
  if (!context.mounted) return;
  await showWhatsAppManualDialog(context, targets: [result], template: ctx.template, week: ctx.week);
}

/// Loads the user's current-week result and runs the chosen send flow.
Future<void> startUserWhatsApp(BuildContext context, UserProfile user, WhatsAppMode mode) async {
  final repo = context.read<ReportRepository>();
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));

  if (!user.hasWhatsAppNumber || !WhatsAppLink.isUsableNumber(user.whatsappNumber ?? '')) {
    say('${user.name}: save a valid WhatsApp number first.');
    return;
  }
  try {
    final weeks = await repo.getUserWeeks(user.userId);
    final week = weeks.current;
    if (week == null) {
      say('${user.name} has no calculated week yet.');
      return;
    }
    final result = await repo.getUserResult(week.reportId, user.userId);
    if (!result.hasPayableBonus) {
      say('${user.name} has no payable bonus for ${week.weekLabel}, so there is nothing to send.');
      return;
    }
    if (!context.mounted) return;
    if (mode == WhatsAppMode.auto) {
      await showWhatsAppMessageDialog(context, result: result);
    } else {
      final ctx = await loadMessageContext(context, week.reportId);
      if (!context.mounted) return;
      await showWhatsAppManualDialog(context,
          targets: [result], template: ctx.template, week: ctx.week);
    }
  } on ApiException catch (e) {
    say(e.userMessage);
  }
}
