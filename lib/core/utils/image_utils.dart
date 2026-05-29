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

  // Target post-compression size. The pipeline iterates quality steps
  // until the file fits under this, then uploads. Profile / ID / cert
  // photos are rendered at thumbnail-to-mid-size on phones, so this
  // is visually indistinguishable from the source while being ~16×
  // cheaper to serve on Firebase Storage.
  static const int maxFileSizeBytes = 500 * 1024;

  // Hard reject for the SOURCE file. The image_picker pre-shrink
  // already downscales typical phone photos well under this, so the
  // cap only trips on absurd uploads (multi-megapixel PNGs, raw
  // camera roll exports through the system picker) — exactly the
  // ones that bloat Storage costs without giving us anything in
  // return. 2 MB is generous enough that no legitimate user hits it
  // by accident and tight enough that the per-upload bill is bounded.
  static const int maxSourceBytes = 2 * 1024 * 1024;

  // Human-readable equivalent, used in UI hints next to the picker
  // so the user is told the cap up front instead of finding out via
  // an error toast.
  static const String maxSourceLabel = '2 MB';

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
  // so the user hears about an oversized source right away — the
  // compressor only kicks in if we make it past this gate.
  static Future<String?> validateImage(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return 'File not found';

    final bytes = await file.length();
    if (bytes > maxSourceBytes) {
      return 'Photo cannot be uploaded — please choose an image '
          'under $maxSourceLabel.';
    }

    final dot = filePath.lastIndexOf('.');
    final ext = dot == -1 ? '' : filePath.substring(dot).toLowerCase();
    if (!const ['.jpg', '.jpeg', '.png', '.webp'].contains(ext)) {
      return 'Please choose a JPG or PNG image.';
    }

    return null;
  }
}
