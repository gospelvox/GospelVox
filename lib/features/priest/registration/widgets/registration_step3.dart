// Step 3 — verification documents. Feeds into the Review page (Step 4)
// where the priest can cross-check everything before the actual upload.
//
// Both upload cards use the same fixed-minHeight layout so they look
// identical in both empty and filled states. Nothing uploads here:
// tapping "Review Application" advances the wizard to Step 4, which
// owns the final submit + confirmation sheet.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/image_utils.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/info_hint.dart';

const Color _kSuccessGreen = Color(0xFF2E7D4F);

class RegistrationStep3 extends StatefulWidget {
  // Renamed conceptually to "proceed to review" but we keep the same
  // parameter name to avoid churn in the shell — semantically it now
  // hands the picked paths off so the cubit can store them and the
  // Review page can display them.
  final void Function(String? idProofPath, String? certificatePath)
      onSubmit;
  final VoidCallback onBack;

  // Lets us hydrate from the cubit when the priest comes back from
  // the Review page via an Edit button.
  final String? initialIdProofPath;
  final String? initialCertificatePath;

  const RegistrationStep3({
    super.key,
    required this.onSubmit,
    required this.onBack,
    this.initialIdProofPath,
    this.initialCertificatePath,
  });

  @override
  State<RegistrationStep3> createState() => _RegistrationStep3State();
}

class _RegistrationStep3State extends State<RegistrationStep3> {
  String? _idProofPath;
  String? _certificatePath;

  @override
  void initState() {
    super.initState();
    _idProofPath = widget.initialIdProofPath;
    _certificatePath = widget.initialCertificatePath;
  }

  Future<void> _pickFile(bool isIdProof) async {
    try {
      final picker = ImagePicker();
      // Documents are inherently photographic for most users — a pic
      // of an Aadhaar/Passport from the gallery is the common case.
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90,
      );
      if (picked == null) return;

      final error = await ImageUtils.validateImage(picked.path);
      if (!mounted) return;
      if (error != null) {
        AppSnackBar.error(context, error);
        return;
      }

      setState(() {
        if (isIdProof) {
          _idProofPath = picked.path;
        } else {
          _certificatePath = picked.path;
        }
      });
    } on TimeoutException {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not pick file. Try again.');
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        'Could not pick file. Check permissions.',
      );
    }
  }

  // Only gate is that the required ID proof has been picked. Terms
  // acknowledgement + final submit live on the Review page (Step 4).
  bool get _canProceed => _idProofPath != null;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                'Verification',
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              // One hint on the title carries the privacy promise —
              // no need for a loud banner below it.
              const InfoHint(
                id: 'docs_privacy_hint',
                text:
                    'Your documents are reviewed only by our admin team '
                    'and are stored securely. They will never be shared '
                    'with users.',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Upload documents to verify your identity',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 28),

          _DocumentCard(
            title: 'ID Proof',
            subtitle:
                'Government-issued photo ID\n(Aadhaar, Passport, Voter ID)',
            isRequired: true,
            filePath: _idProofPath,
            onPick: () => _pickFile(true),
          ),
          const SizedBox(height: 16),
          _DocumentCard(
            title: 'Ordination Certificate',
            subtitle:
                'Certificate of ordination or\nministry credentials',
            isRequired: false,
            filePath: _certificatePath,
            onPick: () => _pickFile(false),
          ),

          const SizedBox(height: 14),
          // Quiet muted caption — replaces the old blue InfoTip.
          Center(
            child: Text(
              'Accepted: JPG, PNG • Max 10MB • Auto-compressed before upload',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppColors.muted.withValues(alpha: 0.8),
              ),
            ),
          ),

          const SizedBox(height: 32),
          _SubmitButton(
            enabled: _canProceed,
            onTap: () =>
                widget.onSubmit(_idProofPath, _certificatePath),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              "You'll review everything before submitting",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
          ),
          SizedBox(height: bottomPad + 20),
        ],
      ),
    );
  }
}

// Single card used for both ID + certificate — guarantees uniform
// visual weight even when one is filled and the other isn't.
class _DocumentCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isRequired;
  final String? filePath;
  final VoidCallback onPick;

  const _DocumentCard({
    required this.title,
    required this.subtitle,
    required this.isRequired,
    required this.filePath,
    required this.onPick,
  });

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[\\/]+'));
    return parts.isEmpty ? path : parts.last;
  }

  @override
  Widget build(BuildContext context) {
    final hasFile = filePath != null && filePath!.isNotEmpty;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 180),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasFile
              ? _kSuccessGreen.withValues(alpha: 0.2)
              : AppColors.muted.withValues(alpha: 0.12),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: hasFile
            ? _buildUploadedState(_fileName(filePath!))
            : _buildEmptyState(),
      ),
    );
  }

  List<Widget> _buildEmptyState() {
    return [
      Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.primaryBrown.withValues(alpha: 0.06),
        ),
        child: Icon(
          Icons.cloud_upload_outlined,
          size: 24,
          color: AppColors.primaryBrown.withValues(alpha: 0.5),
        ),
      ),
      const SizedBox(height: 14),
      Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        subtitle,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: AppColors.muted,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 14),
      _ChooseFileButton(onTap: onPick),
      if (isRequired) ...[
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.errorRed,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Required',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.errorRed,
              ),
            ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _buildUploadedState(String fileName) {
    return [
      Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(filePath!),
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                width: 52,
                height: 52,
                color: AppColors.primaryBrown.withValues(alpha: 0.06),
                child: const Icon(
                  Icons.insert_drive_file_outlined,
                  color: AppColors.primaryBrown,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: _kSuccessGreen.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 16,
              color: _kSuccessGreen,
            ),
            const SizedBox(width: 8),
            Text(
              'Ready to upload',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _kSuccessGreen,
              ),
            ),
            const Spacer(),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPick,
              child: Text(
                'Change',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBrown,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

class _ChooseFileButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ChooseFileButton({required this.onTap});

  @override
  State<_ChooseFileButton> createState() => _ChooseFileButtonState();
}

class _ChooseFileButtonState extends State<_ChooseFileButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(
              color: AppColors.primaryBrown,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.add,
                size: 16,
                color: AppColors.primaryBrown,
              ),
              const SizedBox(width: 6),
              Text(
                'Choose File',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBrown,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubmitButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _SubmitButton({required this.enabled, required this.onTap});

  @override
  State<_SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<_SubmitButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return GestureDetector(
      onTapDown:
          enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel:
          enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(14),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppColors.primaryBrown
                          .withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const [],
          ),
          child: Center(
            child: Text(
              'Review Application',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
