// Square avatar cropper. Added so a priest who picks a portrait photo
// can frame their face into the square the avatar is displayed in —
// before this, the avatar used BoxFit.cover and chopped the top/bottom
// of a tall photo ("only half the head shows").
//
// Built on crop_your_image, which is PURE DART — it renders the crop UI
// with Flutter widgets and returns cropped bytes. It pulls in NO native
// code, so it needs zero AndroidManifest / Gradle / theme changes and
// cannot affect the native build. That trade (vs the native uCrop-based
// image_cropper) was deliberate for a production app.
//
// Usage:
//   final cropped = await cropAvatarSquare(context, picked.path);
//   if (cropped == null) return;          // user backed out
//   // feed `cropped` (a file path) into the existing compress+upload.

import 'dart:io';
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Reads the source image, shows the square crop screen, and on confirm
// writes the cropped bytes to a temp file and returns its path. Returns
// null if the user cancels or the source can't be read — callers treat
// null as "keep the existing photo, do nothing".
Future<String?> cropAvatarSquare(
  BuildContext context,
  String sourcePath,
) async {
  final Uint8List bytes;
  try {
    bytes = await File(sourcePath).readAsBytes();
  } catch (_) {
    if (context.mounted) {
      AppSnackBar.error(context, "Couldn't open that photo. Try another.");
    }
    return null;
  }
  if (!context.mounted) return null;

  final cropped = await Navigator.of(context).push<Uint8List?>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ImageCropPage(imageBytes: bytes),
    ),
  );
  if (cropped == null) return null;

  try {
    // Unique temp name so back-to-back edits never collide or serve a
    // stale cached file. The systemTemp dir is fine — the bytes are
    // immediately handed to the existing compress + upload pipeline.
    final outPath =
        '${Directory.systemTemp.path}/avatar_crop_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await File(outPath).writeAsBytes(cropped, flush: true);
    return outPath;
  } catch (_) {
    if (context.mounted) {
      AppSnackBar.error(context, "Couldn't process the photo. Try again.");
    }
    return null;
  }
}

class _ImageCropPage extends StatefulWidget {
  final Uint8List imageBytes;

  const _ImageCropPage({required this.imageBytes});

  @override
  State<_ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<_ImageCropPage> {
  final CropController _controller = CropController();
  bool _cropping = false;

  void _onCropped(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        Navigator.of(context).pop(croppedImage);
      case CropFailure():
        setState(() => _cropping = false);
        AppSnackBar.error(context, "Couldn't crop the photo. Try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1410),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1410),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: _cropping ? null : () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Adjust photo',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: Crop(
              image: widget.imageBytes,
              controller: _controller,
              // Square output framed by a circular guide so the priest
              // sees exactly how the round avatar will read.
              aspectRatio: 1,
              withCircleUi: true,
              baseColor: const Color(0xFF1A1410),
              maskColor: Colors.black.withValues(alpha: 0.5),
              onCropped: _onCropped,
              progressIndicator: const AppLoader(),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Drag and pinch to frame your face',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _cropping
                        ? null
                        : () {
                            setState(() => _cropping = true);
                            _controller.crop();
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryBrown,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          AppColors.primaryBrown.withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                    ),
                    child: _cropping
                        ? const SizedBox(
                            width: 29,
                            height: 29,
                            child: AppLoader(),
                          )
                        : Text(
                            'Done',
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
