// Step 1 — personal info. Name + phone + email + profile photo.
//
// Deliberately ignores the Google/Apple avatar: we want a real
// professional portrait uploaded manually, not a casual selfie from
// someone's social profile. Email stays editable (the spec's latest
// iteration loosened the read-only rule) but is pre-filled from Auth.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/image_utils.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/info_hint.dart';

// Moved out of the State class so the pure functions can be unit-tested
// later without needing a widget tree.
final RegExp _kNameRegex = RegExp(r'^[a-zA-Z\s]+$');
final RegExp _kEmailRegex = RegExp(r'^[\w\-\.]+@([\w\-]+\.)+[\w\-]{2,}$');

class RegistrationStep1 extends StatefulWidget {
  final String prefilledEmail;
  final String? prefilledName;
  // Carried through so the wizard's persisted draft can survive a
  // re-entry (user backs out, comes back later).
  final String initialName;
  final String initialPhone;
  final String initialEmail;
  final String? initialPhotoPath;

  final void Function(
    String fullName,
    String phone,
    String email,
    String? photoPath,
  ) onNext;

  const RegistrationStep1({
    super.key,
    required this.prefilledEmail,
    required this.onNext,
    this.prefilledName,
    this.initialName = '',
    this.initialPhone = '',
    this.initialEmail = '',
    this.initialPhotoPath,
  });

  @override
  State<RegistrationStep1> createState() => _RegistrationStep1State();
}

class _RegistrationStep1State extends State<RegistrationStep1> {
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;

  final FocusNode _nameFocus = FocusNode();
  final FocusNode _phoneFocus = FocusNode();
  final FocusNode _emailFocus = FocusNode();

  String? _photoPath;
  String? _nameError;
  String? _phoneError;
  String? _emailError;
  // Surfaced inline below the photo when the admin tries to continue
  // without uploading one. Cleared when a photo is picked.
  String? _photoError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.initialName.isNotEmpty
          ? widget.initialName
          : (widget.prefilledName ?? ''),
    );
    _phoneController = TextEditingController(text: widget.initialPhone);
    _emailController = TextEditingController(
      text: widget.initialEmail.isNotEmpty
          ? widget.initialEmail
          : widget.prefilledEmail,
    );
    _photoPath = widget.initialPhotoPath;

    // Validate on blur so users see errors as they leave fields, not
    // only on submit — kinder than the big red reveal at the bottom.
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _validateName();
    });
    _phoneFocus.addListener(() {
      if (!_phoneFocus.hasFocus) _validatePhone();
    });
    _emailFocus.addListener(() {
      if (!_emailFocus.hasFocus) _validateEmail();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _nameFocus.dispose();
    _phoneFocus.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  // ── Validators ──

  String? _validateName() {
    final name = _nameController.text.trim();
    String? err;
    if (name.isEmpty) {
      err = 'Full name is required';
    } else if (name.length < 3) {
      err = 'Name must be at least 3 characters';
    } else if (!_kNameRegex.hasMatch(name)) {
      err = 'Name can only contain letters and spaces';
    }
    if (err != _nameError && mounted) {
      setState(() => _nameError = err);
    }
    return err;
  }

  String? _validatePhone() {
    final phone = _phoneController.text.trim();
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    String? err;
    if (digits.isEmpty) {
      err = 'Phone number is required';
    } else if (digits.length != 10) {
      err = 'Enter a valid 10-digit number';
    } else if (!const ['6', '7', '8', '9'].contains(digits[0])) {
      err = 'Enter a valid Indian mobile number';
    }
    if (err != _phoneError && mounted) {
      setState(() => _phoneError = err);
    }
    return err;
  }

  String? _validateEmail() {
    final email = _emailController.text.trim();
    String? err;
    if (email.isEmpty) {
      err = 'Email is required';
    } else if (!_kEmailRegex.hasMatch(email)) {
      err = 'Enter a valid email address';
    }
    if (err != _emailError && mounted) {
      setState(() => _emailError = err);
    }
    return err;
  }

  // ── Photo picker ──

  Future<void> _showImagePickerSheet() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Choose Photo',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Select a clear portrait of yourself',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 24),
                _PickerOption(
                  icon: Icons.photo_library_outlined,
                  title: 'Choose from Gallery',
                  subtitle: 'Select an existing photo',
                  onTap: () =>
                      Navigator.pop(sheetCtx, ImageSource.gallery),
                ),
                const SizedBox(height: 12),
                _PickerOption(
                  icon: Icons.camera_alt_outlined,
                  title: 'Take a Photo',
                  subtitle: 'Use your camera',
                  onTap: () =>
                      Navigator.pop(sheetCtx, ImageSource.camera),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (source == null) return;
    await _pickImage(source);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      // Pre-shrink at pick time — we still compress before upload,
      // but picking 8MP when we need 800px wastes memory on the
      // decode too.
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (picked == null) return;

      final error = await ImageUtils.validateImage(picked.path);
      if (!mounted) return;
      if (error != null) {
        AppSnackBar.error(context, error);
        return;
      }
      setState(() {
        _photoPath = picked.path;
        _photoError = null;
      });
    } on TimeoutException {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not access photos. Try again.');
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        'Could not pick image. Check permissions.',
      );
    }
  }

  // ── Submit ──

  void _validateAndProceed() {
    final nameErr = _validateName();
    final phoneErr = _validatePhone();
    final emailErr = _validateEmail();

    // Photo is required. A priest who skipped it would land on the
    // public marketplace without a face — users don't book faceless
    // speakers, so there's no sensible way to let this through.
    final bool photoMissing =
        _photoPath == null || _photoPath!.isEmpty;
    if (photoMissing != (_photoError != null) && mounted) {
      setState(() {
        _photoError =
            photoMissing ? 'Please upload a profile photo' : null;
      });
    }

    if (nameErr != null ||
        phoneErr != null ||
        emailErr != null ||
        photoMissing) {
      return;
    }

    widget.onNext(
      _nameController.text.trim(),
      _phoneController.text.trim(),
      _emailController.text.trim(),
      _photoPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text(
            'About You',
            style: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Let's start with your basic information",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 32),

          // Photo picker — centered hero. The coach-mark pulse lives
          // on the photo's info icon because this is the first thing
          // the priest sees in the whole wizard: if we can teach them
          // the "tap info" pattern here, it carries across all steps.
          Center(
            child: _PhotoCircle(
              photoPath: _photoPath,
              onTap: _showImagePickerSheet,
              hasError: _photoError != null,
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Upload a professional portrait',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
                const InfoHint(
                  id: 'photo_hint',
                  text:
                      'Upload a clear, recent portrait photo. This will be '
                      'visible to users seeking guidance and helps build '
                      'trust. Please use a real photo — not an avatar or '
                      'group picture.',
                ),
              ],
            ),
          ),
          if (_photoError != null) ...[
            const SizedBox(height: 6),
            Center(
              child: Text(
                _photoError!,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.errorRed,
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),

          _LabeledField(
            label: 'Full Name',
            hint: 'Enter your full name',
            controller: _nameController,
            focusNode: _nameFocus,
            keyboardType: TextInputType.name,
            textInputAction: TextInputAction.next,
            errorText: _nameError,
            hintId: 'name_hint',
            hintText:
                'Your name will be displayed to users. Please use your '
                'real name as it appears on your ID.',
            inputFormatters: [
              // Keep input clean rather than letting digits/emojis in
              // then rejecting at submit — smoother UX.
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z\s]')),
              LengthLimitingTextInputFormatter(60),
            ],
            onChanged: () {
              if (_nameError != null && mounted) {
                setState(() => _nameError = null);
              }
            },
            onSubmitted: (_) => _phoneFocus.requestFocus(),
          ),
          const SizedBox(height: 20),

          _LabeledField(
            label: 'Phone Number',
            hint: '99999 99999',
            controller: _phoneController,
            focusNode: _phoneFocus,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            errorText: _phoneError,
            hintId: 'phone_hint',
            hintText:
                'Your phone number is kept private and will never be '
                'shared with users. We use it only to contact you for '
                'account verification and important updates.',
            prefix: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '+91',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            onChanged: () {
              if (_phoneError != null && mounted) {
                setState(() => _phoneError = null);
              }
            },
            onSubmitted: (_) => _emailFocus.requestFocus(),
          ),
          const SizedBox(height: 20),

          _LabeledField(
            label: 'Email',
            hint: 'your@email.com',
            controller: _emailController,
            focusNode: _emailFocus,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            errorText: _emailError,
            hintId: 'email_hint',
            hintText:
                'Your email is used for account notifications and '
                'support. It will not be visible to users.',
            inputFormatters: [
              LengthLimitingTextInputFormatter(80),
            ],
            onChanged: () {
              if (_emailError != null && mounted) {
                setState(() => _emailError = null);
              }
            },
            onSubmitted: (_) => _validateAndProceed(),
          ),

          const SizedBox(height: 32),

          _ContinueButton(onTap: _validateAndProceed),
          SizedBox(height: bottomPad + 20),
        ],
      ),
    );
  }
}

class _PhotoCircle extends StatefulWidget {
  final String? photoPath;
  final VoidCallback onTap;
  // Red ring around the circle when Continue was tapped without a
  // photo — cheaper visual tell than scrolling the error into view.
  final bool hasError;

  const _PhotoCircle({
    required this.photoPath,
    required this.onTap,
    this.hasError = false,
  });

  @override
  State<_PhotoCircle> createState() => _PhotoCircleState();
}

class _PhotoCircleState extends State<_PhotoCircle> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final hasPhoto =
        widget.photoPath != null && widget.photoPath!.isNotEmpty;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFF7F5F2),
                border: Border.all(
                  color: widget.hasError
                      ? AppColors.errorRed
                      : hasPhoto
                          ? AppColors.primaryBrown
                          : AppColors.muted.withValues(alpha: 0.2),
                  width: widget.hasError
                      ? 2
                      : hasPhoto
                          ? 2.5
                          : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                    color: Colors.black.withValues(alpha: 0.06),
                  ),
                ],
              ),
              child: hasPhoto
                  ? ClipOval(
                      child: Image.file(
                        File(widget.photoPath!),
                        fit: BoxFit.cover,
                        width: 100,
                        height: 100,
                      ),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.camera_alt_outlined,
                          size: 28,
                          color: AppColors.muted.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Add Photo',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            color:
                                AppColors.muted.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
            ),
            Positioned(
              bottom: 2,
              right: 2,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryBrown,
                  border: Border.all(
                    color: AppColors.background,
                    width: 2.5,
                  ),
                ),
                child: Icon(
                  hasPhoto ? Icons.edit : Icons.add,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final String? errorText;
  final Widget? prefix;
  final List<TextInputFormatter>? inputFormatters;
  final VoidCallback? onChanged;
  final ValueChanged<String>? onSubmitted;

  // When provided, an info icon appears next to the label and reveals
  // this text as a tooltip on tap. The id scopes read/unread tracking
  // to a single hint — tapping the Name hint doesn't mark the Phone
  // hint as read too.
  final String? hintText;
  final String? hintId;

  const _LabeledField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.keyboardType,
    required this.textInputAction,
    this.focusNode,
    this.errorText,
    this.prefix,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.hintText,
    this.hintId,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
            ),
            if (hintText != null && hintId != null)
              InfoHint(id: hintId!, text: hintText!),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          inputFormatters: inputFormatters,
          onChanged: (_) => onChanged?.call(),
          onFieldSubmitted: onSubmitted,
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: AppColors.deepDarkBrown,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
            prefixIcon: prefix == null
                ? null
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
                    child: prefix,
                  ),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 0, minHeight: 0),
            filled: true,
            fillColor: const Color(0xFFF7F5F2),
            isDense: true,
            border: _border(AppColors.muted.withValues(alpha: 0.2)),
            enabledBorder:
                _border(AppColors.muted.withValues(alpha: 0.2)),
            focusedBorder: _border(AppColors.primaryBrown, width: 1.5),
            errorBorder: _border(AppColors.errorRed),
            focusedErrorBorder:
                _border(AppColors.errorRed, width: 1.5),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            errorText: errorText,
            errorStyle: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.errorRed,
            ),
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _border(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}

class _PickerOption extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PickerOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_PickerOption> createState() => _PickerOptionState();
}

class _PickerOptionState extends State<_PickerOption> {
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
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F5F2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      AppColors.primaryBrown.withValues(alpha: 0.08),
                ),
                child: Icon(
                  widget.icon,
                  size: 22,
                  color: AppColors.primaryBrown,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinueButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ContinueButton({required this.onTap});

  @override
  State<_ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<_ContinueButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            color: AppColors.primaryBrown,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrown.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              'Continue',
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
