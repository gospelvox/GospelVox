// Shares a CSV string as a file via share_plus, with a clipboard
// fallback. Kept context-free so every admin export surface (list,
// per-priest, receipt) shares identically; the caller shows the toast
// based on the returned outcome.

import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:share_plus/share_plus.dart';

enum CsvShareResult { shared, copiedToClipboard, failed }

Future<CsvShareResult> shareCsvFile({
  required String csv,
  required String filename,
  required String subject,
}) async {
  final bytes = Uint8List.fromList(utf8.encode(csv));
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(bytes, mimeType: 'text/csv', name: filename),
        ],
        subject: subject,
      ),
    );
    return CsvShareResult.shared;
  } catch (_) {
    // share_plus can throw on builds predating the native plugin, or
    // when no share target exists. Fall back to the clipboard so the
    // admin always walks away with the data.
    try {
      await Clipboard.setData(ClipboardData(text: csv));
      return CsvShareResult.copiedToClipboard;
    } catch (_) {
      return CsvShareResult.failed;
    }
  }
}
