import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../models/upload_report_response.dart';
import '../repositories/report_repository.dart';
import '../routing/app_routes.dart';

enum _UploadState { idle, uploading, success, error }

/// Screen 3 — Report Upload.
///
/// Uses POST /api/v1/reports/upload. The PDF can have any number of pages —
/// nothing here checks or limits page count, only that a PDF was selected.
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

  Future<void> _upload() async {
    final file = _selectedFile;
    if (file == null || file.bytes == null) {
      setState(() => _errorMessage = 'Please select a PDF file first.');
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
      setState(() {
        _state = _UploadState.error;
        _errorMessage = e.userMessage;
      });
    }
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
                color: AppTheme.success.withOpacity(0.08),
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
                  AppRoutes.processing,
                  arguments: _uploadResponse!.reportId,
                ),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Processing'),
              )
            else
              ElevatedButton.icon(
                onPressed: _selectedFile == null || _state == _UploadState.uploading ? null : _upload,
                icon: const Icon(Icons.upload_outlined),
                label: const Text('Upload'),
              ),
          ],
        ),
      ),
    );
  }
}
