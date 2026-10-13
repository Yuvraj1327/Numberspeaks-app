import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/bonus_result.dart';
import '../models/user_profile.dart';
import '../repositories/report_repository.dart';
import '../routing/app_router.dart';
import '../routing/app_routes.dart';
import 'report_review_screen.dart' show EditRowSheet;
import '../widgets/whatsapp_message_dialog.dart';
import '../widgets/whatsapp_number_dialog.dart';

/// Individual user: this period's calculation breakdown (when opened from a
/// report), the saved WhatsApp number (editable, kept permanently), the
/// Send WhatsApp action, the balance carried forward, and the full
/// calculation history for the user.
///
/// A casino user is only a bonus recipient — they never log in.
class UserDetailScreen extends StatefulWidget {
  final UserDetailArgs args;

  const UserDetailScreen({super.key, required this.args});

  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> {
  BonusResult? _result;
  UserProfile? _profile;
  List<HistoryEntry> _history = [];

  bool _loading = true;
  String? _resultError;
  String? _historyError;

  String? get _reportId => widget.args.reportId;

  @override
  void initState() {
    super.initState();
    _result = widget.args.initialResult;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _resultError = null;
      _historyError = null;
    });
    final repo = context.read<ReportRepository>();

    String? resultError;
    BonusResult? result = _result;
    final reportId = _reportId;
    if (reportId != null) {
      try {
        result = await repo.getUserResult(reportId, widget.args.userId);
      } on ApiException catch (e) {
        resultError = e.userMessage;
      }
    }

    String? historyError;
    UserProfile? profile = _profile;
    var history = _history;
    try {
      final data = await repo.getUserHistory(widget.args.userId);
      profile = data.user;
      history = data.history;
    } on ApiException catch (e) {
      historyError = e.userMessage;
    }

    if (!mounted) return;
    setState(() {
      _result = result;
      _profile = profile;
      _history = history;
      _resultError = resultError;
      _historyError = historyError;
      _loading = false;
    });
  }

  String? get _number {
    final fromProfile = _profile?.whatsappNumber;
    final value = _profile != null ? fromProfile : _result?.whatsappNumber;
    return (value != null && value.trim().isNotEmpty) ? value : null;
  }

  Future<void> _editNumber() async {
    final repo = context.read<ReportRepository>();
    final saved = await showWhatsAppNumberDialog(
      context,
      userName: widget.args.userName,
      currentNumber: _number,
      onSave: (number) async {
        final updated = await repo.saveWhatsAppNumber(widget.args.userId, number);
        return updated.whatsappNumber;
      },
    );
    if (saved == null || !mounted) return;
    setState(() {
      _profile = _profile == null
          ? null
          : UserProfile(
              userId: _profile!.userId,
              name: _profile!.name,
              level: _profile!.level,
              whatsappNumber: saved.isEmpty ? null : saved,
              carryForwardBalance: _profile!.carryForwardBalance,
              createdAt: _profile!.createdAt,
            );
      _result = _result?.copyWith(whatsappNumber: saved, clearWhatsAppNumber: saved.isEmpty);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved.isEmpty ? 'WhatsApp number removed.' : 'WhatsApp number saved.')),
    );
  }

  /// Corrects the figures extracted from the report for this user (same
  /// sheet as the review screen). The week must be recalculated afterwards.
  Future<void> _editRow() async {
    final result = _result;
    final reportId = _reportId;
    if (result == null || reportId == null) return;
    final saved = await showModalBottomSheet<BonusResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => EditRowSheet(reportId: reportId, row: result),
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved. Recalculate this week to update the bonus.')),
    );
    _load();
  }

  Future<void> _editUser() async {
    final name = TextEditingController(text: _profile?.name ?? widget.args.userName);
    final level = TextEditingController(text: _profile?.level ?? '');
    final repo = context.read<ReportRepository>();
    String? error;
    final saved = await showDialog<UserProfile>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          scrollable: true,
          title: const Text('Edit user'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'User ID / Name')),
              const SizedBox(height: AppSpacing.sm),
              TextField(controller: level, decoration: const InputDecoration(labelText: 'Level')),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: const TextStyle(color: AppTheme.danger)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                try {
                  final updated = await repo.updateUser(widget.args.userId, {
                    'name': name.text.trim(),
                    'level': level.text.trim(),
                  });
                  if (context.mounted) Navigator.of(context).pop(updated);
                } on ApiException catch (e) {
                  setLocal(() => error = e.userMessage);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    level.dispose();
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User updated.')));
    _load();
  }

  Future<void> _openReferrals() async {
    final reportId = _reportId;
    if (reportId == null) return;
    await Navigator.of(context).pushNamed(AppRoutes.referrals, arguments: reportId);
    if (mounted) _load();
  }

  Future<void> _sendWhatsApp() async {
    final result = _result;
    final number = _number;
    if (result == null || number == null) return;
    final outcome = await showWhatsAppMessageDialog(
      context,
      result: result.copyWith(whatsappNumber: number),
    );
    if (outcome == null || !mounted) return;
    if (outcome.result != null) setState(() => _result = outcome.result);
    if (outcome.refresh) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.args.userName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: _loading
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            tooltip: 'Edit user',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _editUser,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_resultError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Text(
                        'Could not refresh this report\'s figures: $_resultError',
                        style: const TextStyle(color: AppTheme.warning),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (_result != null) ...[
                    _PayableCard(result: _result!),
                    const SizedBox(height: AppSpacing.md),
                    _BreakdownCard(result: _result!),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  _WhatsAppCard(
                    number: _number,
                    result: _result,
                    onEdit: _editNumber,
                    onSend: _sendWhatsApp,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_result != null) ...[
                    _ReferralCard(result: _result!, onManage: _openReferrals),
                    const SizedBox(height: AppSpacing.md),
                    _RowDetailsCard(result: _result!, onEdit: _editRow),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  _HistoryCard(
                    profile: _profile,
                    history: _history,
                    loading: _loading && _history.isEmpty,
                    error: _historyError,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _PayableCard extends StatelessWidget {
  final BonusResult result;

  const _PayableCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final calculated = result.isCalculated;
    final carry = result.carryForwardBalance ?? 0;
    final color = !calculated
        ? Colors.black38
        : (result.payable > 0 ? AppTheme.success : Colors.black54);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            Text(
              'FINAL PAYABLE BONUS',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.black45,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              calculated ? Formatters.rupees(result.payable) : 'Not calculated yet',
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800, color: color),
            ),
            if (calculated && carry < 0) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${Formatters.rupees(carry)} is carried forward to the next period',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.danger, fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  final BonusResult result;

  const _BreakdownCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;

    if (!r.isCalculated) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(
            r.calculationStatus == 'invalid'
                ? 'This row could not be calculated. Correct it on the review screen and calculate again.'
                : 'No calculation yet. Review the report and press "Confirm & Calculate".',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
        ),
      );
    }

    Color? signColor(double? v) {
      if (v == null || v == 0) return null;
      return v > 0 ? AppTheme.success : AppTheme.danger;
    }

    final rate = r.personalRateUsed;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Calculation breakdown', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            _BreakdownRow(
              label: 'Profit / Loss this period',
              value: Formatters.signed(r.profitLoss),
              note: r.profitLoss < 0 ? 'A loss earns a bonus' : (r.profitLoss > 0 ? 'A win is deducted' : null),
            ),
            _BreakdownRow(
              label: 'Previous carried balance',
              value: Formatters.signed(r.previousBalance ?? 0),
              color: signColor(r.previousBalance),
            ),
            _BreakdownRow(
              label: rate == null ? 'Personal adjustment' : 'Personal adjustment (${Formatters.percent(rate)})',
              value: Formatters.signed(r.personalAdjustment ?? 0),
              color: signColor(r.personalAdjustment),
            ),
            _BreakdownRow(
              label: 'Referral adjustment',
              value: Formatters.signed(r.referralAdjustment ?? 0),
              color: signColor(r.referralAdjustment),
              note: 'Kept separate from the personal adjustment',
            ),
            const Divider(),
            _BreakdownRow(
              label: 'Final balance',
              value: Formatters.signed(r.finalBalance ?? 0),
              color: signColor(r.finalBalance),
              bold: true,
              note: 'Previous + personal + referral',
            ),
            _BreakdownRow(
              label: 'Payable bonus',
              value: Formatters.rupees(r.payable),
              color: r.payable > 0 ? AppTheme.success : null,
              bold: true,
              note: 'The final balance when positive, otherwise ₹0',
            ),
            _BreakdownRow(
              label: 'Carried forward',
              value: Formatters.signed(r.carryForwardBalance ?? 0),
              color: signColor(r.carryForwardBalance),
              note: 'A negative final balance moves to the next period',
              isLast: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final bool bold;
  final String? note;
  final bool isLast;

  const _BreakdownRow({
    required this.label,
    required this.value,
    this.color,
    this.bold = false,
    this.note,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                if (note != null)
                  Text(note!, style: const TextStyle(fontSize: 11.5, color: Colors.black45)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
                fontSize: bold ? 16 : 14,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who referred this user this week, and how many users they referred.
class _ReferralCard extends StatelessWidget {
  final BonusResult result;
  final VoidCallback onManage;

  const _ReferralCard({required this.result, required this.onManage});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Referrals this week', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            _BreakdownRow(
              label: 'Referred by',
              value: r.hasReferrer ? '${r.referrerName} (${r.referrerUserId})' : 'Nobody',
            ),
            _BreakdownRow(label: 'Users they referred', value: '${r.referredCount}'),
            _BreakdownRow(
              label: 'Referral adjustment',
              value: r.referralAdjustment == null ? '—' : Formatters.signed(r.referralAdjustment!),
              isLast: true,
            ),
            const SizedBox(height: AppSpacing.xs),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onManage,
                icon: const Icon(Icons.share_outlined, size: 18),
                label: const Text('Manage referrals'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowDetailsCard extends StatelessWidget {
  final BonusResult result;
  final VoidCallback onEdit;

  const _RowDetailsCard({required this.result, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('From the report', style: Theme.of(context).textTheme.titleSmall),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Correct values'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _BreakdownRow(label: 'User ID / Name', value: r.userName),
            _BreakdownRow(label: 'Level', value: r.level ?? '—'),
            _BreakdownRow(label: 'Casino Pts', value: Formatters.points(r.casinoPts)),
            _BreakdownRow(label: 'Sport Pts', value: Formatters.points(r.sportPts)),
            _BreakdownRow(label: 'Third Party Pts', value: Formatters.points(r.thirdPartyPts)),
            _BreakdownRow(label: 'Profit / Loss', value: Formatters.points(r.profitLoss)),
            _BreakdownRow(label: 'Ptype', value: r.ptype ?? '—', isLast: true),
          ],
        ),
      ),
    );
  }
}

class _WhatsAppCard extends StatelessWidget {
  final String? number;
  final BonusResult? result;
  final VoidCallback onEdit;
  final VoidCallback onSend;

  const _WhatsAppCard({
    required this.number,
    required this.result,
    required this.onEdit,
    required this.onSend,
  });

  /// The latest send status as the backend recorded it.
  static String _statusText(BonusResult r) {
    switch (r.sendStatus) {
      case 'sent':
        final at = r.sentAt == null ? null : DateTime.tryParse(r.sentAt!)?.toLocal();
        return at == null ? 'Sent' : 'Sent on ${Formatters.dateTime(at)}';
      case 'sending':
        return 'Sending (not finished)';
      case 'failed':
        return 'Failed${r.sendError == null ? '' : ': ${r.sendError}'}';
      case 'unknown':
        return 'Unknown${r.sendError == null ? '' : ': ${r.sendError}'}';
      default:
        return 'Pending';
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    final canSend = r != null && r.hasPayableBonus && number != null && !r.isSent;

    String? reason;
    if (r != null && !r.hasPayableBonus) {
      reason = 'No payable bonus this period — there is no bonus message to send.';
    } else if (r != null && number == null) {
      reason = 'Add a WhatsApp number to send the bonus message.';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.chat_outlined, color: AppTheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('WhatsApp', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    number ?? 'No number saved yet',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: number == null ? AppTheme.warning : null,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: Icon(number == null ? Icons.add : Icons.edit_outlined, size: 18),
                  label: Text(number == null ? 'Add number' : 'Edit'),
                ),
              ],
            ),
            if (r != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _statusText(r),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
              ),
              const SizedBox(height: AppSpacing.sm),
              ElevatedButton.icon(
                onPressed: canSend ? onSend : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.send_outlined, size: 18),
                label: Text(r.isSent ? 'Sent' : r.canRetrySend ? 'Retry send' : 'Auto Send WhatsApp'),
              ),
              if (reason != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    reason,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black45),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final UserProfile? profile;
  final List<HistoryEntry> history;
  final bool loading;
  final String? error;

  const _HistoryCard({
    required this.profile,
    required this.history,
    required this.loading,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    final carry = profile?.carryForwardBalance;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Calculation history', style: Theme.of(context).textTheme.titleSmall)),
                if (carry != null)
                  Flexible(
                    child: Text(
                      'Balance: ${Formatters.signed(carry)}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: carry < 0 ? AppTheme.danger : Colors.black54,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              Text(error!, style: const TextStyle(color: AppTheme.warning))
            else if (history.isEmpty)
              Text(
                'No calculations yet for this user.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
              )
            else
              for (var i = 0; i < history.length; i++) ...[
                _HistoryRow(entry: history[i]),
                if (i != history.length - 1) const Divider(height: AppSpacing.lg),
              ],
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final HistoryEntry entry;

  const _HistoryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                e.reportFileName?.isNotEmpty == true ? e.reportFileName! : 'Report',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(
                Formatters.dateTime(e.calculatedAt),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11.5, color: Colors.black45),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.xs,
          children: [
            _MiniStat('P/L', Formatters.points(e.profitLoss)),
            _MiniStat('Personal', Formatters.signed(e.personalAdjustment)),
            _MiniStat('Referral', Formatters.signed(e.referralAdjustment)),
            _MiniStat('Previous', Formatters.signed(e.previousBalance)),
            _MiniStat('Final', Formatters.signed(e.finalBalance)),
            _MiniStat(
              'Payable',
              Formatters.rupees(e.payableBonus),
              color: e.payableBonus > 0 ? AppTheme.success : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _MiniStat(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            color: Colors.black45,
          ),
        ),
        Text(value, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: color)),
      ],
    );
  }
}
