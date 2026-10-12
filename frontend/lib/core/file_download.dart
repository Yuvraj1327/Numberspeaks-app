import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/report_repository.dart';
import 'api_exception.dart';

/// Downloads [apiPath] (a CSV export or the JSON backup) from the backend and
/// hands it to the platform's "save file" dialog. Shows a SnackBar with the
/// outcome; nothing is stored on the device by the app itself.
Future<void> downloadAndSave(
  BuildContext context, {
  required String apiPath,
  required String fileName,
  required String allowedExtension,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final repo = context.read<ReportRepository>();
  try {
    final bytes = await repo.download(apiPath);
    final saved = await FilePicker.platform.saveFile(
      dialogTitle: 'Save $fileName',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [allowedExtension],
      bytes: Uint8List.fromList(bytes),
    );
    messenger.showSnackBar(
      SnackBar(content: Text(saved == null && !kIsWeb ? 'Export cancelled.' : '$fileName exported.')),
    );
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not save the file.')));
  }
}
