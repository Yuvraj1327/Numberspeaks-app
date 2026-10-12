import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/file_download.dart';
import '../core/formatters.dart';
import '../models/bonus_settings.dart';
import '../models/referral_entry.dart';
import '../models/report_summary.dart';
import '../models/user_profile.dart';
import '../repositories/report_repository.dart';
import '../routing/app_router.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';

/// Users, Referrers and the Referral Ledger in one place.
///
/// * Users — everyone in the reports, with who referred them.
/// * Referrers — saved referrer details (name, notes, own default rate) with
///   how many users they brought and their total adjustment.
/// * Ledger — every referral entry of every week; add manual activity, edit
///   the rate/amount, delete, export CSV.
///
/// All of it lives in Supabase through the backend, scoped to the admin.
class ReferralHubScreen extends StatefulWidget {
  const ReferralHubScreen({super.key});

  @override
  State<ReferralHubScreen> createState() => _ReferralHubScreenState();
}

class _ReferralHubScreenState extends State<ReferralHubScreen> {
  bool _loading = true;
  String? _error;
  List<UserProfile> _users = [];
  List<Referrer> _referrers = [];
  List<ReferralEntry> _ledger = [];
  List<ReportSummary> _reports = [];
  BonusSettings? _settings;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final repo = context.read<ReportRepository>();
    try {
      final results = await Future.wait([
        repo.listUsers(),
        repo.referrers(),
        repo.ledger(),
        repo.listReports(),
        repo.getSettings(),
      ]);
      if (!mounted) return;
      setState(() {
        _users = results[0] as List<UserProfile>;
        _referrers = results[1] as List<Referrer>;
        _ledger = results[2] as List<ReferralEntry>;
        _reports = results[3] as List<ReportSummary>;
        _settings = results[4] as BonusSettings;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _loading = false;
      });
    }
  }

  /// Latest referrer of each user, from the ledger (already newest first).
  Map<String, ReferralEntry> get _latestLinkByReferred {
    final map = <String, ReferralEntry>{};
    for (final e in _ledger) {
      map.putIfAbsent(e.referredUserId, () => e);
    }
    return map;
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(Future<void> Function() action, String ok) async {
    try {
      await action();
      if (!mounted) return;
      _snack(ok);
      _load(silent: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(e.userMessage);
    }
  }

  // --- Referrers ----------------------------------------------------------

  Future<void> _editReferrer([Referrer? existing]) async {
    final repo = context.read<ReportRepository>();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _ReferrerDialog(users: _users, existing: existing, globalRate: _settings?.referralRate ?? 0.1),
    );
    if (result == null || !mounted) return;
    await _run(
      () async {
        if (existing == null) {
          await repo.addReferrer(result);
        } else {
          await repo.updateReferrer(existing.referrerId, result);
        }
      },
      'Referrer saved.',
    );
  }

  Future<void> _deleteReferrer(Referrer r) async {
    final repo = context.read<ReportRepository>();
    final ok = await _confirm('Remove referrer?', 'Only the saved details of ${r.title} are removed. '
        'Their ledger entries stay.');
    if (!ok) return;
    await _run(() => repo.deleteReferrer(r.referrerId), 'Referrer removed.');
  }

  // --- Ledger -------------------------------------------------------------

  Future<void> _addEntry() async {
    final repo = context.read<ReportRepository>();
    if (_reports.isEmpty) {
      _snack('Import a weekly report first.');
      return;
    }
    final result = await showDialog<_EntryInput>(
      context: context,
      builder: (context) => _EntryDialog(
        reports: _reports,
        users: _users,
        referrers: _referrers,
        globalRate: _settings?.referralRate ?? 0.1,
      ),
    );
    if (result == null || !mounted) return;
    await _run(
      () => repo.addLedgerEntry(
        reportId: result.reportId,
        referrerUserId: result.referrerUserId,
        referredUserId: result.referredUserId,
        rate: result.rate,
        amount: result.amount,
        note: result.note,
      ),
      'Referral added. It is applied when that week is calculated.',
    );
  }

  Future<void> _editEntry(ReferralEntry e) async {
    final repo = context.read<ReportRepository>();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _EntryEditDialog(entry: e),
    );
    if (result == null || !mounted) return;
    await _run(
      () => repo.updateLedgerEntry(e.entryId, result),
      'Entry updated. Recalculate that week to apply it.',
    );
  }

  Future<void> _deleteEntry(ReferralEntry e) async {
    final repo = context.read<ReportRepository>();
    final ok = await _confirm('Delete entry?', 'Remove ${e.referrerName ?? 'referrer'} → ${e.referredName ?? 'user'} '
        'for ${Formatters.periodLabel(e.periodStart, e.periodEnd)}?');
    if (!ok) return;
    await _run(() => repo.deleteLedgerEntry(e.entryId), 'Entry deleted.');
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Referrals'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Users'), Tab(text: 'Referrers'), Tab(text: 'Ledger')],
          ),
        ),
        body: _loading
            ? const LoadingView()
            : _error != null
                ? ErrorView(message: _error!, onRetry: _load)
                : TabBarView(children: [_usersTab(), _referrersTab(), _ledgerTab()]),
      ),
    );
  }

  // --- Tabs -----------------------------------------------------------------

  Widget _usersTab() {
    final links = _latestLinkByReferred;
    final q = _query.trim().toLowerCase();
    final users = _users.where((u) => q.isEmpty || u.name.toLowerCase().contains(q)).toList();
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search users'),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (users.isEmpty) const EmptyView(icon: Icons.groups_outlined, message: 'No users yet. Import a weekly report to create them.'),
          for (final u in users)
            Card(
              child: ListTile(
                title: Row(
                  children: [
                    Flexible(child: Text(u.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                    if (links[u.userId] != null) ...[
                      const SizedBox(width: 8),
                      _Badge(
                        text: 'Referred by ${links[u.userId]!.referrerName ?? links[u.userId]!.referrerUserId}',
                        color: AppTheme.blue,
                      ),
                    ],
                    if (_referrers.any((r) => r.userId == u.userId)) ...[
                      const SizedBox(width: 8),
                      const _Badge(text: 'Referrer', color: AppTheme.success),
                    ],
                  ],
                ),
                subtitle: Text(
                  'ID ${u.userId.substring(0, u.userId.length < 8 ? u.userId.length : 8)}'
                  '${u.hasWhatsAppNumber ? ' • ${u.whatsappNumber}' : ' • no WhatsApp'}',
                ),
                trailing: TextButton(
                  onPressed: () async {
                    await Navigator.of(context).pushNamed(
                      AppRoutes.userDetail,
                      arguments: UserDetailArgs(userId: u.userId, userName: u.name),
                    );
                    if (mounted) _load(silent: true);
                  },
                  child: const Text('Edit'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _referrersTab() {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => _load(silent: true),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 96),
            children: [
              if (_referrers.isEmpty)
                const EmptyView(
                  icon: Icons.share_outlined,
                  message: 'Add a referrer to save their details and their own referral rate.',
                ),
              for (final r in _referrers)
                Card(
                  child: ListTile(
                    title: Row(
                      children: [
                        Flexible(child: Text(r.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                        if (!r.isActive) ...[const SizedBox(width: 8), const _Badge(text: 'Inactive', color: Colors.grey)],
                      ],
                    ),
                    subtitle: Text(
                      'User: ${r.userName ?? r.userId} • ${r.referredCount} referred • '
                      'Rate ${r.defaultRate == null ? 'default' : Formatters.percent(r.defaultRate!)}'
                      '${r.notes == null ? '' : '\n${r.notes}'}',
                    ),
                    isThreeLine: r.notes != null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          Formatters.signed(r.totalAdjustment),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: r.totalAdjustment < 0 ? AppTheme.danger : AppTheme.success,
                          ),
                        ),
                        IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _editReferrer(r)),
                        IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteReferrer(r)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          right: AppSpacing.md,
          bottom: AppSpacing.md,
          child: FloatingActionButton.extended(
            heroTag: 'add-referrer',
            onPressed: _editReferrer,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Add referrer'),
          ),
        ),
      ],
    );
  }

  Widget _ledgerTab() {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => _load(silent: true),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 96),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => downloadAndSave(
                    context,
                    apiPath: '/export/referrals.csv',
                    fileName: 'referral-ledger.csv',
                    allowedExtension: 'csv',
                  ),
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Export CSV'),
                ),
              ),
              if (_ledger.isEmpty)
                const EmptyView(
                  icon: Icons.receipt_long_outlined,
                  message: 'Referral activity of every week appears here.',
                ),
              for (final e in _ledger)
                Card(
                  child: ListTile(
                    title: Text(
                      '${e.referrerName ?? e.referrerUserId} → ${e.referredName ?? e.referredUserId}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${Formatters.periodLabel(e.periodStart, e.periodEnd)} • '
                      '${e.amount == null ? 'amount pending' : (e.amount! < 0 ? 'Loss ${Formatters.amount(-e.amount!)}' : e.amount! > 0 ? 'Win ${Formatters.amount(e.amount!)}' : 'No result')}'
                      '${e.isManual ? ' (manual)' : ''} • ${Formatters.percent(e.rate)}'
                      '${e.note == null ? '' : '\n${e.note}'}',
                    ),
                    isThreeLine: e.note != null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          e.adjustment == null ? '—' : Formatters.signed(e.adjustment!),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: (e.adjustment ?? 0) < 0 ? AppTheme.danger : AppTheme.success,
                          ),
                        ),
                        IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _editEntry(e)),
                        IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteEntry(e)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          right: AppSpacing.md,
          bottom: AppSpacing.md,
          child: FloatingActionButton.extended(
            heroTag: 'add-entry',
            onPressed: _addEntry,
            icon: const Icon(Icons.add),
            label: const Text('Add referral'),
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

double? _percentToFraction(String text) {
  final p = double.tryParse(text.trim().replaceAll('%', ''));
  if (p == null || p < 0 || p > 100) return null;
  return double.parse((p / 100).toStringAsFixed(6));
}

Widget _userDropdown({
  required String label,
  required List<UserProfile> users,
  required UserProfile? initial,
  required ValueChanged<UserProfile?> onSelected,
}) {
  return DropdownMenu<UserProfile>(
    label: Text(label),
    expandedInsets: EdgeInsets.zero,
    enableFilter: true,
    requestFocusOnTap: true,
    initialSelection: initial,
    dropdownMenuEntries: [for (final u in users) DropdownMenuEntry(value: u, label: u.name)],
    onSelected: onSelected,
  );
}

class _ReferrerDialog extends StatefulWidget {
  final List<UserProfile> users;
  final Referrer? existing;
  final double globalRate;

  const _ReferrerDialog({required this.users, required this.existing, required this.globalRate});

  @override
  State<_ReferrerDialog> createState() => _ReferrerDialogState();
}

class _ReferrerDialogState extends State<_ReferrerDialog> {
  UserProfile? _user;
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late final TextEditingController _rate;
  bool _active = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.displayName ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _rate = TextEditingController(text: e?.defaultRate == null ? '' : (e!.defaultRate! * 100).toString().replaceAll(RegExp(r'\.0$'), ''));
    _active = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _save() {
    final existing = widget.existing;
    if (existing == null && _user == null) {
      setState(() => _error = 'Choose the user who is the referrer.');
      return;
    }
    double? rate;
    if (_rate.text.trim().isNotEmpty) {
      rate = _percentToFraction(_rate.text);
      if (rate == null) {
        setState(() => _error = 'Rate must be between 0 and 100.');
        return;
      }
    }
    Navigator.of(context).pop({
      if (existing == null) 'user_id': _user!.userId,
      'display_name': _name.text.trim(),
      'notes': _notes.text.trim(),
      if (rate != null) 'default_rate': rate,
      if (rate == null && existing != null) 'clear_default_rate': true,
      'is_active': _active,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.existing == null ? 'Add referrer' : 'Edit referrer'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.existing == null)
              _userDropdown(label: 'Referrer (User ID / name)', users: widget.users, initial: null, onSelected: (u) => _user = u)
            else
              Align(alignment: Alignment.centerLeft, child: Text('User: ${widget.existing!.userName ?? widget.existing!.userId}')),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name (optional)')),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Referral rate',
                suffixText: '%',
                helperText: 'Leave empty to use the default (${Formatters.percent(widget.globalRate)})',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: _active, onChanged: (v) => setState(() => _active = v)),
            if (_error != null) Text(_error!, style: const TextStyle(color: AppTheme.danger)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _EntryInput {
  final String reportId;
  final String referrerUserId;
  final String referredUserId;
  final double? rate;
  final double? amount;
  final String? note;

  const _EntryInput(this.reportId, this.referrerUserId, this.referredUserId, this.rate, this.amount, this.note);
}

class _EntryDialog extends StatefulWidget {
  final List<ReportSummary> reports;
  final List<UserProfile> users;
  final List<Referrer> referrers;
  final double globalRate;

  const _EntryDialog({required this.reports, required this.users, required this.referrers, required this.globalRate});

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late ReportSummary _report = widget.reports.first;
  UserProfile? _referrer;
  UserProfile? _referred;
  bool _loss = true;
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _rate = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (_referrer == null || _referred == null) {
      setState(() => _error = 'Choose both the referrer and the referred user.');
      return;
    }
    if (_referrer!.userId == _referred!.userId) {
      setState(() => _error = 'A user cannot refer themselves.');
      return;
    }
    double? amount;
    if (_amount.text.trim().isNotEmpty) {
      final n = double.tryParse(_amount.text.trim());
      if (n == null || n < 0) {
        setState(() => _error = 'Enter the loss/win amount as a positive number.');
        return;
      }
      amount = _loss ? -n : n;
    }
    double? rate;
    if (_rate.text.trim().isNotEmpty) {
      rate = _percentToFraction(_rate.text);
      if (rate == null) {
        setState(() => _error = 'Rate must be between 0 and 100.');
        return;
      }
    }
    Navigator.of(context).pop(_EntryInput(_report.reportId, _referrer!.userId, _referred!.userId, rate, amount, _note.text));
  }

  @override
  Widget build(BuildContext context) {
    final ownRate = widget.referrers.where((r) => r.userId == _referrer?.userId).firstOrNull?.defaultRate;
    return AlertDialog(
      scrollable: true,
      title: const Text('Add referral activity'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownMenu<ReportSummary>(
              label: const Text('Week / period'),
              expandedInsets: EdgeInsets.zero,
              initialSelection: _report,
              dropdownMenuEntries: [for (final r in widget.reports) DropdownMenuEntry(value: r, label: r.title)],
              onSelected: (r) => setState(() => _report = r ?? _report),
            ),
            const SizedBox(height: AppSpacing.sm),
            _userDropdown(label: 'Referrer User ID', users: widget.users, initial: null, onSelected: (u) => setState(() => _referrer = u)),
            const SizedBox(height: AppSpacing.sm),
            _userDropdown(label: 'Referred User ID', users: widget.users, initial: null, onSelected: (u) => _referred = u),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('Loss')), ButtonSegment(value: false, label: Text('Win'))],
              selected: {_loss},
              onSelectionChanged: (s) => setState(() => _loss = s.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Referred user\'s amount (optional)',
                helperText: 'Empty = use their profit/loss from the report',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Referral rate',
                suffixText: '%',
                helperText: 'Empty = ${Formatters.percent(ownRate ?? widget.globalRate)}',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: AppTheme.danger))),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Add')),
      ],
    );
  }
}

class _EntryEditDialog extends StatefulWidget {
  final ReferralEntry entry;

  const _EntryEditDialog({required this.entry});

  @override
  State<_EntryEditDialog> createState() => _EntryEditDialogState();
}

class _EntryEditDialogState extends State<_EntryEditDialog> {
  late final TextEditingController _rate =
      TextEditingController(text: (widget.entry.rate * 100).toString().replaceAll(RegExp(r'\.0$'), ''));
  late final TextEditingController _amount =
      TextEditingController(text: widget.entry.isManual && widget.entry.amount != null ? widget.entry.amount.toString() : '');
  late final TextEditingController _note = TextEditingController(text: widget.entry.note ?? '');
  String? _error;

  @override
  void dispose() {
    _rate.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final rate = _percentToFraction(_rate.text);
    if (rate == null) {
      setState(() => _error = 'Rate must be between 0 and 100.');
      return;
    }
    final amountText = _amount.text.trim();
    final amount = amountText.isEmpty ? null : double.tryParse(amountText);
    if (amountText.isNotEmpty && amount == null) {
      setState(() => _error = 'Amount must be a number (loss negative, win positive).');
      return;
    }
    Navigator.of(context).pop({
      'rate': rate,
      if (amount != null) 'amount': amount else 'clear_amount': true,
      'note': _note.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Edit referral entry'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('${widget.entry.referrerName ?? ''} → ${widget.entry.referredName ?? ''}'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Referral rate', suffixText: '%'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(
                labelText: 'Manual amount (loss negative, win positive)',
                helperText: 'Empty = use the report\'s profit/loss',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: AppTheme.danger))),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
