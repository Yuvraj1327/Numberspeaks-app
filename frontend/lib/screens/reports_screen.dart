import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../models/report_status.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/status_pill.dart';

/// Reports tab — the report this device has uploaded (the backend has no
/// "list reports" endpoint, only a per-device "last report" convenience —
/// see LocalReportStore/README), and the entry point for uploading a new
/// one.
class ReportsScreen extends StatefulWidget {
  final void Function(int tabIndex) onSwitchTab;

  const ReportsScreen({super.key, required this.onSwitchTab});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool _loading = true;
  String? _errorMessage;
  String? _reportId;
  String? _fileName;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final repo = context.read<ReportRepository>();
    try {
      final reportId = await repo.getLastReportId();
      final fileName = await repo.getLastReportFileName();
      final status = await repo.getLastReportStatus();
      if (!mounted) return;
      setState(() {
        _reportId = reportId;
        _fileName = fileName;
        _status = status;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.userMessage;
        _loading = false;
      });
    }
  }

  Future<void> _upload() async {
    await Navigator.of(context).pushNamed(AppRoutes.upload);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null) {
      return ErrorView(message: _errorMessage!, onRetry: _load);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(
            children: [
              Text(
                'Reports',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _upload,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Upload'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_reportId == null)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: EmptyView(
                icon: Icons.description_outlined,
                message: 'No report uploaded yet on this device.\nUpload a PDF report to get started.',
              ),
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.picture_as_pdf_outlined, color: AppTheme.primary),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Text(
                            _fileName ?? 'Latest report',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_status != null)
                          StatusPill.forReportStatus(ReportStatus.fromString(_status)),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _upload,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Upload New'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => widget.onSwitchTab(2),
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('View Results'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}
