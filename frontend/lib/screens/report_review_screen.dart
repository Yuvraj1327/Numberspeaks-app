import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/responsive.dart';
import '../core/formatters.dart';
import '../models/bonus_result.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/grid_table.dart';
import '../widgets/loading_view.dart';

/// Review & correct — the step between upload and calculation.
///
/// Shows the values extracted from the PDF in a table. PDF extraction can
/// misread a figure, so the admin can tap any row to correct it; corrections
/// are saved immediately (to Supabase, through the backend). Referral entries
/// can be added from here too. Nothing is calculated until the admin presses
/// "Confirm & Calculate".
class ReportReviewScreen extends StatefulWidget {
  final String reportId;
  final List<String> warnings;

  const ReportReviewScreen({super.key, required this.reportId, this.warnings = const []});

  @override
  State<ReportReviewScreen> createState() => _ReportReviewScreenState();
}

class _ReportReviewScreenState extends State<ReportReviewScreen> {
  static const _columns = [
    GridColumn('#', 52),
    GridColumn('User ID / Name', 170),
    GridColumn('Level', 90),
    GridColumn('Casino Pts', 100, numeric: true),
    GridColumn('Sport Pts', 100, numeric: true),
    GridColumn('Third Party Pts', 110, numeric: true),
    GridColumn('Profit / Loss', 110, numeric: true),
    GridColumn('Ptype', 90),
    GridColumn('WhatsApp number', 150),
    GridColumn('', 56),
  ];

  bool _loading = true;
  String? _errorMessage;
  List<BonusResult> _rows = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final rows = await context.read<ReportRepository>().getResults(widget.reportId);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        _errorMessage = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.userMessage;
        _loading = false;
      });
    }
  }

  List<BonusResult> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((r) => r.userName.toLowerCase().contains(q)).toList();
  }

  Future<void> _edit(BonusResult row) async {
    final updated = await showModalBottomSheet<BonusResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => EditRowSheet(reportId: widget.reportId, row: row),
    );
    if (updated == null || !mounted) return;
    setState(() {
      final index = _rows.indexWhere((r) => r.bonusResultId == updated.bonusResultId);
      if (index != -1) _rows[index] = updated;
      _rows.sort((a, b) => a.userName.toLowerCase().compareTo(b.userName.toLowerCase()));
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved changes to ${updated.userName}.')),
    );
  }

  Future<void> _openReferrals() async {
    await Navigator.of(context).pushNamed(AppRoutes.referrals, arguments: widget.reportId);
  }

  Future<void> _confirm() async {
    await Navigator.of(context).pushNamed(AppRoutes.processing, arguments: widget.reportId);
    // Back here means processing did not finish (or the admin came back to
    // fix something) — show the current state of the rows.
    if (mounted) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Extracted Data'),
        actions: [
          IconButton(
            tooltip: 'Referrals',
            icon: const Icon(Icons.group_add_outlined),
            onPressed: _loading ? null : _openReferrals,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  static const _tableMinWidth = 760.0;

  Widget _rowCard(BonusResult r, int index) {
    Widget stat(String label, String value, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: Colors.black45,
                  )),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ],
          ),
        );

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _edit(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm + 4, AppSpacing.sm, AppSpacing.sm + 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('${index + 1}', style: const TextStyle(color: Colors.black45)),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.userName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        if (r.hasReferrer)
                          Text(
                            'Referred by ${r.referrerName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5, color: AppTheme.blue, fontWeight: FontWeight.w600),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Correct this row',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _edit(r),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  stat('Casino Pts', Formatters.points(r.casinoPts)),
                  stat('Sport Pts', Formatters.points(r.sportPts)),
                  stat('Third Party', Formatters.points(r.thirdPartyPts)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  stat('Profit / Loss', Formatters.points(r.profitLoss),
                      color: r.profitLoss < 0 ? AppTheme.danger : null),
                  stat('Level', r.level ?? '—'),
                  stat('Ptype', r.ptype ?? '—'),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(children: [
                stat('WhatsApp number', r.hasWhatsAppNumber ? r.whatsappNumber! : '—')
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null) return ErrorView(message: _errorMessage!, onRetry: _load);
    if (_rows.isEmpty) {
      return const EmptyView(message: 'No rows were extracted from this report.');
    }

    final visible = _visible;
    // While the keyboard is up (search field / edit sheet) the page keeps only
    // the search box and table; notes and the action bar return afterwards.
    return LayoutBuilder(builder: (context, constraints) {
      final keyboardOpen = constraints.maxHeight < Responsive.shortBodyHeight;

      return Column(
        children: [
          // The notes above the table scroll on their own if the screen is short
          // (small phone, large font) so the table and buttons always keep room.
          if (!keyboardOpen)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.28),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
                      child: Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: AppTheme.blue.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline, size: 18, color: AppTheme.blue),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                '${_rows.length} user(s) read from the PDF. Check the figures and tap a row '
                                'to correct anything that was misread. Nothing is calculated until you confirm.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (widget.warnings.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: BoxDecoration(
                            color: AppTheme.warning.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${widget.warnings.length} warning(s) while reading the PDF',
                                style: const TextStyle(
                                    color: AppTheme.warning, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              for (final warning in widget.warnings.take(5))
                                Text(warning, style: Theme.of(context).textTheme.bodySmall),
                              if (widget.warnings.length > 5)
                                Text(
                                  '…and ${widget.warnings.length - 5} more.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search by User ID / Name',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? const EmptyView(message: 'No users match your search.', icon: Icons.search_off)
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // Ten columns need sideways scrolling on a phone, so below
                      // this width each row is a card with the same fields.
                      if (constraints.maxWidth < _tableMinWidth) {
                        return ListView.separated(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.md,
                            0,
                            AppSpacing.md,
                            AppSpacing.md,
                          ),
                          itemCount: visible.length,
                          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (context, index) => _rowCard(visible[index], index),
                        );
                      }
                      return GridTable(
                        columns: _columns,
                        itemCount: visible.length,
                        rowHeight: Responsive.rowHeight(context, 56),
                        onRowTap: (index) => _edit(visible[index]),
                        cellsBuilder: (context, index) {
                          final r = visible[index];
                          return [
                            Text('${index + 1}', style: const TextStyle(color: Colors.black45)),
                            Text(
                              r.userName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(r.level ?? '—', overflow: TextOverflow.ellipsis),
                            Text(Formatters.points(r.casinoPts)),
                            Text(Formatters.points(r.sportPts)),
                            Text(Formatters.points(r.thirdPartyPts)),
                            Text(
                              Formatters.points(r.profitLoss),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: r.profitLoss < 0 ? AppTheme.danger : null,
                              ),
                            ),
                            Text(r.ptype ?? '—', overflow: TextOverflow.ellipsis),
                            Text(
                              r.hasWhatsAppNumber ? r.whatsappNumber! : '—',
                              overflow: TextOverflow.ellipsis,
                            ),
                            IconButton(
                              tooltip: 'Correct this row',
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => _edit(r),
                            ),
                          ];
                        },
                      );
                    },
                  ),
          ),
          if (!keyboardOpen)
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.navy.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _openReferrals,
                        icon: const Icon(Icons.group_add_outlined),
                        label: const Text('Referrals'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _confirm,
                        icon: const Icon(Icons.calculate_outlined),
                        label: const Text('Confirm & Calculate'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    });
  }
}

/// One numeric field of the edit sheet, with the value it started with.
class _NumericField {
  final String key;
  final String label;
  final TextEditingController controller;
  final double original;

  const _NumericField(this.key, this.label, this.controller, this.original);
}

/// Bottom sheet with the editable fields of one extracted row. Pops with the
/// saved row, or null if cancelled. Only fields the admin actually changed
/// are sent.
class EditRowSheet extends StatefulWidget {
  final String reportId;
  final BonusResult row;

  const EditRowSheet({super.key, required this.reportId, required this.row});

  @override
  State<EditRowSheet> createState() => EditRowSheetState();
}

class EditRowSheetState extends State<EditRowSheet> {
  late final TextEditingController _name;
  late final TextEditingController _level;
  late final TextEditingController _casino;
  late final TextEditingController _sport;
  late final TextEditingController _third;
  late final TextEditingController _profitLoss;
  late final TextEditingController _ptype;
  late final TextEditingController _whatsapp;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final r = widget.row;
    _name = TextEditingController(text: r.userName);
    _level = TextEditingController(text: r.level ?? '');
    _casino = TextEditingController(text: _numberText(r.casinoPts));
    _sport = TextEditingController(text: _numberText(r.sportPts));
    _third = TextEditingController(text: _numberText(r.thirdPartyPts));
    _profitLoss = TextEditingController(text: _numberText(r.profitLoss));
    _ptype = TextEditingController(text: r.ptype ?? '');
    _whatsapp = TextEditingController(text: r.whatsappNumber ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _level, _casino, _sport, _third, _profitLoss, _ptype, _whatsapp]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 1250.0 -> "1250", 12.5 -> "12.5" (an editable plain number, no commas).
  static String _numberText(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  double? _parse(String text) => double.tryParse(text.trim().replaceAll(',', ''));

  Future<void> _save() async {
    final r = widget.row;
    final changes = <String, dynamic>{};

    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'User ID / Name cannot be empty.');
      return;
    }
    if (name != r.userName) changes['user_name'] = name;

    final numeric = <_NumericField>[
      _NumericField('casino_pts', 'Casino Pts', _casino, r.casinoPts),
      _NumericField('sport_pts', 'Sport Pts', _sport, r.sportPts),
      _NumericField('third_party_pts', 'Third Party Pts', _third, r.thirdPartyPts),
      _NumericField('profit_loss', 'Profit/Loss', _profitLoss, r.profitLoss),
    ];
    for (final field in numeric) {
      final value = _parse(field.controller.text);
      if (value == null) {
        setState(() => _error = '${field.label} must be a number.');
        return;
      }
      if (value != field.original) changes[field.key] = value;
    }

    if (_level.text.trim() != (r.level ?? '')) changes['level'] = _level.text.trim();
    if (_ptype.text.trim() != (r.ptype ?? '')) changes['ptype'] = _ptype.text.trim();
    if (_whatsapp.text.trim() != (r.whatsappNumber ?? '')) {
      changes['whatsapp_number'] = _whatsapp.text.trim();
    }

    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await context.read<ReportRepository>().correctRow(
            widget.reportId,
            r.bonusResultId,
            changes,
          );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      // A timeout does not mean the save failed: ask the server what it holds
      // before reporting anything, and never ask the admin to blindly resubmit.
      if (e.kind == ApiErrorKind.timeout) {
        final saved = await _findSavedRow(changes);
        if (!mounted) return;
        if (saved != null) {
          Navigator.of(context).pop(saved);
          return;
        }
      }
      setState(() {
        _saving = false;
        _error = e.kind == ApiErrorKind.timeout
            ? 'The server did not confirm the save in time. Nothing was lost on screen — '
                'press Save again to retry (saving the same values twice is safe).'
            : e.userMessage;
      });
    }
  }

  /// The row as stored on the server if it already holds every value in
  /// [changes], else null.
  Future<BonusResult?> _findSavedRow(Map<String, dynamic> changes) async {
    try {
      final rows = await context.read<ReportRepository>().getResults(widget.reportId);
      final row = rows.where((r) => r.bonusResultId == widget.row.bonusResultId).firstOrNull;
      if (row == null) return null;
      final stored = <String, dynamic>{
        'user_name': row.userName,
        'casino_pts': row.casinoPts,
        'sport_pts': row.sportPts,
        'third_party_pts': row.thirdPartyPts,
        'profit_loss': row.profitLoss,
        'level': row.level ?? '',
        'ptype': row.ptype ?? '',
      };
      for (final entry in changes.entries) {
        if (entry.key == 'whatsapp_number') continue; // stored normalised; not comparable verbatim
        if (stored[entry.key] != entry.value) return null;
      }
      if (changes.containsKey('whatsapp_number')) {
        final sent = (changes['whatsapp_number'] as String).replaceAll(RegExp(r'[^0-9]'), '');
        final have = (row.whatsappNumber ?? '').replaceAll(RegExp(r'[^0-9]'), '');
        final matches = sent.isEmpty
            ? have.isEmpty
            : have.isNotEmpty && (have.endsWith(sent) || sent.endsWith(have));
        if (!matches) return null;
      }
      return row;
    } on ApiException {
      return null;
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool number = false,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      enabled: !_saving,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Correct row', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Change only what was misread from the PDF. Saving does not calculate anything.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
            ),
            const SizedBox(height: AppSpacing.md),
            _field(_name, 'User ID / Name'),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _field(_level, 'Level')),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _field(_ptype, 'Ptype')),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _field(_casino, 'Casino Pts', number: true)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _field(_sport, 'Sport Pts', number: true)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _field(_third, 'Third Party Pts', number: true)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _field(_profitLoss, 'Profit/Loss', number: true)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _field(_whatsapp, 'WhatsApp number', hint: 'Country code first, e.g. 919876543210'),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: const TextStyle(color: AppTheme.danger)),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
