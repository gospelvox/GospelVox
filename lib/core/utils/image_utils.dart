// Image validation + progressive-quality compression before uploads.
//
// Why this matters: priest documents and profile photos are viewed on
// phones, not A3 prints. Shipping 8MB JPEGs from a modern camera wastes
// Storage quota and makes uploads fail on rural 3G links. Squeezing to
// 500KB at 800px is visually indistinguishable at thumbnail sizes and
// roughly 16× cheaper to serve.
//
// We deliberately avoid the `path` + `path_provider` packages — they
// aren't explicit deps in pubspec.yaml and the lint forbids relying on
// transitive packages. `Directory.systemTemp` gives us the same cache
// dir via dart:io with zero extra dependencies.

import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';

class ImageUtils {
  ImageUtils._();

  static const int maxFileSizeBytes = 500 * 1024;
  static const int maxDimension = 800;

  // Compresses only if the source exceeds the target size. We drop
  // quality in 15-point steps because a single pass at a fixed quality
  // often overshoots or undershoots; stepping lets us honour the cap
  // without blindly nuking detail on already-small images.
  static Future<String> compressImage(String sourcePath) async {
    try {
      final file = File(sourcePath);
      if (!await file.exists()) return sourcePath;

      final fileSize = await file.length();
      if (fileSize <= maxFileSizeBytes) return sourcePath;

      final tempDir = Directory.systemTemp;

      int quality = 85;
      String? resultPath;

      while (quality >= 30) {
        // Unique filename per pass so a failed earlier attempt can't
        // confuse the plugin's caching.
        final targetPath =
            '${tempDir.path}${Platform.pathSeparator}gv_compressed_${DateTime.now().microsecondsSinceEpoch}_$quality.jpg';

        final result = await FlutterImageCompress.compressAndGetFile(
          sourcePath,
          targetPath,
          quality: quality,
          minWidth: maxDimension,
          minHeight: maxDimension,
        );

        if (result == null) break;

        final resultSize = await result.length();
        if (resultSize <= maxFileSizeBytes) {
          resultPath = result.path;
          break;
        }

        quality -= 15;
        resultPath = result.path;
      }

      // If we blew through all quality tiers and still can't fit, fall
      // back to whatever we produced last rather than the huge original
      // — any compression is better than none.
      return resultPath ?? sourcePath;
    } catch (_) {
      // Compression is best-effort. If the plugin fails (permissions,
      // codec issues), we let the upload proceed with the raw file
      // rather than blocking registration entirely.
      return sourcePath;
    }
  }

  // Returns null if the file is acceptable, else a human-readable
  // reason we can surface via the snackbar. Called before compression
  // so the user hears about absurd files right away.
  static Future<String?> validateImage(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return 'File not found';

    final bytes = await file.length();
    if (bytes > 10 * 1024 * 1024) {
      return 'Image too large. Please choose a photo under 10MB.';
    }

    final dot = filePath.lastIndexOf('.');
    final ext = dot == -1 ? '' : filePath.substring(dot).toLowerCase();
    if (!const ['.jpg', '.jpeg', '.png', '.webp'].contains(ext)) {
      return 'Please choose a JPG or PNG image.';
    }

    return null;
  }
}
