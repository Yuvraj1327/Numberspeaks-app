import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../repositories/report_repository.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';

/// Bonus rates: the personal rate (3% by default) and the referral rate
/// (10% by default). Each admin has their own; the rate used is stored with
/// every calculation, so changing it never rewrites past results.
class RatesScreen extends StatefulWidget {
  const RatesScreen({super.key});

  @override
  State<RatesScreen> createState() => _RatesScreenState();
}

class _RatesScreenState extends State<RatesScreen> {
  final TextEditingController _personal = TextEditingController();
  final TextEditingController _referral = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _personal.dispose();
    _referral.dispose();
    super.dispose();
  }

  static String _percentText(double percent) {
    if ((percent - percent.roundToDouble()).abs() < 1e-9) return percent.round().toString();
    return Formatters.percent(percent / 100).replaceAll('%', '');
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final settings = await context.read<ReportRepository>().getSettings();
      if (!mounted) return;
      setState(() {
        _personal.text = _percentText(settings.personalPercent);
        _referral.text = _percentText(settings.referralPercent);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.userMessage;
        _loading = false;
      });
    }
  }

  double? _fraction(String text) {
    final percent = double.tryParse(text.trim().replaceAll('%', ''));
    if (percent == null || percent < 0 || percent > 100) return null;
    return double.parse((percent / 100).toStringAsFixed(6));
  }

  Future<void> _save() async {
    final personal = _fraction(_personal.text);
    final referral = _fraction(_referral.text);
    if (personal == null || referral == null) {
      setState(() => _error = 'Enter a percentage between 0 and 100 for both rates.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<ReportRepository>().saveSettings(
            personalRate: personal,
            referralRate: referral,
          );
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rates saved. They apply to calculations from now on.')),
      );
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
    return Scaffold(
      appBar: AppBar(title: const Text('Bonus rates')),
      body: _loading
          ? const LoadingView()
          : _loadError != null
              ? ErrorView(message: _loadError!, onRetry: _load)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Personal rate', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    'A loss adds this percentage of the loss to the user\'s bonus. '
                                    'A win deducts this percentage of the win from future bonuses.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: Colors.black54),
                                  ),
                                  const SizedBox(height: AppSpacing.sm),
                                  TextField(
                                    controller: _personal,
                                    enabled: !_saving,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(decimal: true),
                                    decoration: const InputDecoration(
                                      labelText: 'Personal rate',
                                      suffixText: '%',
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.lg),
                                  Text('Referral rate', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    'The default for new referral entries: a referred user\'s loss '
                                    'adds this percentage of the loss to the referrer, a win deducts it.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: Colors.black54),
                                  ),
                                  const SizedBox(height: AppSpacing.sm),
                                  TextField(
                                    controller: _referral,
                                    enabled: !_saving,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(decimal: true),
                                    decoration: const InputDecoration(
                                      labelText: 'Referral rate',
                                      suffixText: '%',
                                    ),
                                  ),
                                  if (_error != null) ...[
                                    const SizedBox(height: AppSpacing.sm),
                                    Text(_error!, style: const TextStyle(color: AppTheme.danger)),
                                  ],
                                  const SizedBox(height: AppSpacing.md),
                                  ElevatedButton(
                                    onPressed: _saving ? null : _save,
                                    child: _saving
                                        ? const SizedBox(
                                            height: 20,
                                            width: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Text('Save rates'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'Changing a rate does not change anything already calculated. A report '
                            'that has already been calculated keeps the rate it used; calculate it '
                            'again to apply a new rate.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}
