import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/upload_report_response.dart';
import '../repositories/report_repository.dart';
import '../routing/app_router.dart';
import '../routing/app_routes.dart';

enum _UploadState { idle, uploading, success, error }

/// Screen 3 — Report Upload.
///
/// Uses POST /api/v1/reports/upload. The PDF can have any number of pages —
/// nothing here checks or limits page count, only that a PDF was selected.
/// After a successful upload the admin reviews (and can correct) the
/// extracted rows before confirming any calculation.
class ReportUploadScreen extends StatefulWidget {
  const ReportUploadScreen({super.key});

  @override
  State<ReportUploadScreen> createState() => _ReportUploadScreenState();
}

class _ReportUploadScreenState extends State<ReportUploadScreen> {
  PlatformFile? _selectedFile;
  _UploadState _state = _UploadState.idle;
  double _progress = 0;
  String? _errorMessage;
  UploadReportResponse? _uploadResponse;

  /// The week this PDF covers. Defaults to the week after the latest report.
  DateTimeRange? _period;

  @override
  void initState() {
    super.initState();
    _period = _currentWeek();
    _suggestNextWeek();
  }

  static DateTimeRange _currentWeek() {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    return DateTimeRange(start: monday, end: monday.add(const Duration(days: 6)));
  }

  Future<void> _suggestNextWeek() async {
    try {
      final reports = await context.read<ReportRepository>().listReports();
      final latest = reports.where((r) => r.periodEnd != null).toList()
        ..sort((a, b) => b.periodEnd!.compareTo(a.periodEnd!));
      if (latest.isEmpty || !mounted) return;
      final start = DateTime.parse(latest.first.periodStart!);
      final end = DateTime.parse(latest.first.periodEnd!);
      final length = end.difference(start);
      final next = end.add(const Duration(days: 1));
      setState(() => _period = DateTimeRange(start: next, end: next.add(length)));
    } on ApiException {
      // Keep the current-week default; the backend still guards duplicates.
    }
  }

  Future<void> _pickPeriod() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 2, 12, 31),
      initialDateRange: _period,
      helpText: 'Select the week this report covers',
    );
    if (picked != null) setState(() => _period = picked);
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    if (!file.name.toLowerCase().endsWith('.pdf')) {
      setState(() {
        _errorMessage = 'Please select a PDF file.';
        _selectedFile = null;
      });
      return;
    }

    setState(() {
      _selectedFile = file;
      _errorMessage = null;
      _state = _UploadState.idle;
      _uploadResponse = null;
    });
  }

  Future<void> _upload({bool replace = false}) async {
    final file = _selectedFile;
    final period = _period;
    if (file == null || file.bytes == null) {
      setState(() => _errorMessage = 'Please select a PDF file first.');
      return;
    }
    if (period == null) {
      setState(() => _errorMessage = 'Please select the week this report covers.');
      return;
    }

    setState(() {
      _state = _UploadState.uploading;
      _progress = 0;
      _errorMessage = null;
    });

    final repo = context.read<ReportRepository>();
    try {
      final response = await repo.uploadReport(
        fileBytes: file.bytes!,
        fileName: file.name,
        periodStart: Formatters.isoDate(period.start),
        periodEnd: Formatters.isoDate(period.end),
        replace: replace,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _state = _UploadState.success;
        _uploadResponse = response;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // Same week already imported: only a deliberate, confirmed replace goes on.
      if (!replace && e.statusCode == 409 && e.message.contains('already exists')) {
        setState(() => _state = _UploadState.idle);
        if (await _confirmReplace(period)) {
          await _upload(replace: true);
        }
        return;
      }
      setState(() {
        _state = _UploadState.error;
        _errorMessage = e.userMessage;
      });
    }
  }

  Future<bool> _confirmReplace(DateTimeRange period) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Replace this week?'),
        content: Text(
          'A report for ${Formatters.periodLabel(Formatters.isoDate(period.start), Formatters.isoDate(period.end))} '
          'has already been imported. Replacing it removes that week\'s extracted rows and results '
          '(your referral entries for the week are kept) and imports this PDF instead. '
          'Other weeks are not touched.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep existing')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upload Report')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  children: [
                    Icon(
                      Icons.picture_as_pdf_outlined,
                      size: 48,
                      color: _selectedFile != null ? AppTheme.primary : Colors.black38,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (_selectedFile == null)
                      Text(
                        'Select the PDF report to upload.\nAny number of pages is supported.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                      )
                    else ...[
                      Text(
                        _selectedFile!.name,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        _formatFileSize(_selectedFile!.size),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    OutlinedButton.icon(
                      onPressed: _state == _UploadState.uploading ? null : _pickFile,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(_selectedFile == null ? 'Choose PDF File' : 'Choose Different File'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Card(
              child: ListTile(
                leading: const Icon(Icons.date_range_outlined, color: AppTheme.primary),
                title: const Text('Report week'),
                subtitle: Text(
                  _period == null
                      ? 'Select a week'
                      : Formatters.periodLabel(
                          Formatters.isoDate(_period!.start), Formatters.isoDate(_period!.end)),
                ),
                trailing: const Icon(Icons.edit_calendar_outlined),
                enabled: _state != _UploadState.uploading,
                onTap: _state == _UploadState.uploading ? null : _pickPeriod,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_state == _UploadState.uploading) ...[
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Uploading… ${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_errorMessage != null && _state != _UploadState.uploading)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.danger),
                ),
              ),
            if (_state == _UploadState.success && _uploadResponse != null)
              Card(
                color: AppTheme.success.withValues(alpha: 0.08),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    children: [
                      const Icon(Icons.check_circle_outline, color: AppTheme.success, size: 32),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Upload successful',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(color: AppTheme.success, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '${_uploadResponse!.totalRecords} records extracted from '
                        '${_uploadResponse!.pagesProcessed} page(s).',
                        textAlign: TextAlign.center,
                      ),
                      if (_uploadResponse!.warnings.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '${_uploadResponse!.warnings.length} warning(s) during extraction.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppTheme.warning),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            if (_state == _UploadState.success && _uploadResponse != null)
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pushReplacementNamed(
                  AppRoutes.review,
                  arguments: ReviewArgs(
                    reportId: _uploadResponse!.reportId,
                    warnings: _uploadResponse!.warnings,
                  ),
                ),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Review Extracted Data'),
              )
            else
              ElevatedButton.icon(
                onPressed: _selectedFile == null || _state == _UploadState.uploading ? null : () => _upload(),
                icon: const Icon(Icons.upload_outlined),
                label: const Text('Upload'),
              ),
          ],
        ),
      ),
    );
  }
}
