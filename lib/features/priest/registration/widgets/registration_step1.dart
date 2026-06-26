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
import 'package:country_picker/country_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'package:gospel_vox/core/constants/community_roles.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/image_utils.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/image_crop_page.dart';
import 'package:gospel_vox/core/widgets/phone_country_prefix.dart';
import 'package:gospel_vox/core/widgets/info_hint.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

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
  // Saved role from a draft / re-entry. A value that isn't one of the
  // predefined roles is treated as the priest's earlier 'Other' entry
  // and re-hydrated into the free-text field.
  final String initialCommunityRole;

  final void Function(
    String fullName,
    String phone,
    String email,
    String? photoPath,
    String communityRole,
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
    this.initialCommunityRole = '',
  });

  @override
  State<RegistrationStep1> createState() => _RegistrationStep1State();
}

class _RegistrationStep1State extends State<RegistrationStep1> {
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  // Holds the typed value when the priest picks the 'Other' role.
  late final TextEditingController _otherRoleController;

  final FocusNode _nameFocus = FocusNode();
  final FocusNode _phoneFocus = FocusNode();
  final FocusNode _emailFocus = FocusNode();

  // Selected country for the phone dial code (default India, freely
  // changeable). The number text lives in _phoneController; the two are
  // combined into "+<code> <number>" on submit via composePhone.
  late Country _phoneCountry;

  String? _photoPath;
  String? _nameError;
  String? _phoneError;
  String? _emailError;
  // Surfaced inline below the photo when the admin tries to continue
  // without uploading one. Cleared when a photo is picked.
  String? _photoError;

  // Selected Christian community role. null until the priest picks one;
  // equals [kCommunityRoleOther] while the free-text field is showing.
  String? _communityRole;
  bool _otherRoleSelected = false;
  String? _roleError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.initialName.isNotEmpty
          ? widget.initialName
          : (widget.prefilledName ?? ''),
    );
    // Restore country + national number from any saved draft (or default
    // to India for a fresh start).
    _phoneCountry = phoneCountryFromStored(widget.initialPhone);
    _phoneController =
        TextEditingController(text: phoneNumberFromStored(widget.initialPhone));
    _emailController = TextEditingController(
      text: widget.initialEmail.isNotEmpty
          ? widget.initialEmail
          : widget.prefilledEmail,
    );
    _photoPath = widget.initialPhotoPath;

    // Restore the role. A known role pre-selects its list item; any
    // other non-empty value is the priest's earlier custom 'Other'
    // entry, so we reopen on 'Other' with the value back in the field.
    final initialRole = widget.initialCommunityRole;
    if (initialRole.isEmpty) {
      _communityRole = null;
      _otherRoleController = TextEditingController();
    } else if (isKnownCommunityRole(initialRole)) {
      _communityRole = initialRole;
      _otherRoleController = TextEditingController();
    } else {
      _communityRole = kCommunityRoleOther;
      _otherRoleSelected = true;
      _otherRoleController = TextEditingController(text: initialRole);
    }

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
    _otherRoleController.dispose();
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
    // Validate against the SELECTED country's real rules (length/format),
    // so a US number isn't judged by India's 10-digit rule and vice versa.
    final err = validatePhoneForCountry(_phoneCountry, _phoneController.text);
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

  String? _validateRole() {
    String? err;
    if (_communityRole == null) {
      err = 'Please select your role';
    } else if (_communityRole == kCommunityRoleOther &&
        _otherRoleController.text.trim().isEmpty) {
      err = 'Please type your role';
    }
    if (err != _roleError && mounted) {
      setState(() => _roleError = err);
    }
    return err;
  }

  // Resolves the value we actually store: the typed text for an 'Other'
  // pick, otherwise the selected role. Never returns the literal 'Other'.
  String _resolvedRole() {
    if (_communityRole == kCommunityRoleOther) {
      return _otherRoleController.text.trim();
    }
    return _communityRole ?? '';
  }

  // ── Role picker ──
  //
  // Same bottom-sheet pattern as Step 2's denomination picker so the two
  // single-selects feel identical across the wizard.
  Future<void> _pickRole() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Select your role',
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.5,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: kCommunityRoles.length,
                      itemBuilder: (_, i) {
                        final option = kCommunityRoles[i];
                        final selected = option == _communityRole;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.pop(sheetCtx, option),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.primaryBrown
                                      .withValues(alpha: 0.06)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    option,
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: selected
                                          ? AppColors.primaryBrown
                                          : AppColors.deepDarkBrown,
                                    ),
                                  ),
                                ),
                                if (selected)
                                  const AppIcon(
                                    AppIcons.check,
                                    color: AppColors.primaryBrown,
                                    size: 18,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (picked != null && mounted) {
      setState(() {
        _communityRole = picked;
        _roleError = null;
        _otherRoleSelected = picked == kCommunityRoleOther;
        if (!_otherRoleSelected) _otherRoleController.clear();
      });
    }
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
                  icon: AppIcons.gallery,
                  title: 'Choose from Gallery',
                  subtitle: 'Select an existing photo',
                  onTap: () =>
                      Navigator.pop(sheetCtx, ImageSource.gallery),
                ),
                const SizedBox(height: 12),
                _PickerOption(
                  icon: AppIcons.camera,
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
      // Square-crop step — same as the profile editor — so the avatar
      // isn't half-cut. Null = user backed out of the cropper.
      final cropped = await cropAvatarSquare(context, picked.path);
      if (!mounted || cropped == null) return;
      setState(() {
        _photoPath = cropped;
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
    final roleErr = _validateRole();

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
        roleErr != null ||
        photoMissing) {
      return;
    }

    widget.onNext(
      _nameController.text.trim(),
      composePhone(_phoneCountry, _phoneController.text),
      _emailController.text.trim(),
      _photoPath,
      _resolvedRole(),
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
            prefix: PhoneCountryPrefix(
              country: _phoneCountry,
              onSelected: (c) {
                setState(() {
                  _phoneCountry = c;
                  _phoneError = null;
                });
              },
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(15),
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
            onSubmitted: (_) => _emailFocus.unfocus(),
          ),
          const SizedBox(height: 20),

          _RoleDropdownField(
            label: 'Christian Community Role',
            value: _communityRole,
            hint: 'Select your role',
            errorText: _roleError,
            onTap: _pickRole,
            hintText:
                'Choose the role that best describes your service in the '
                'Christian community. This is shown on your public '
                'profile. Pick "Other" to type your own if it is not '
                'listed.',
            hintId: 'community_role_hint',
          ),
          if (_otherRoleSelected) ...[
            const SizedBox(height: 12),
            _OtherRoleField(
              controller: _otherRoleController,
              hint: 'Type your role',
              onChanged: () {
                if (_roleError != null && mounted) {
                  setState(() => _roleError = null);
                }
              },
            ),
          ],

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
                color: AppColors.fieldFill,
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
                        AppIcon(
                          AppIcons.camera,
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
                child: AppIcon(
                  hasPhoto ? AppIcons.edit : AppIcons.add,
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
            fillColor: AppColors.fieldFill,
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

// Tappable single-select box that opens the role bottom sheet. Mirrors
// Step 2's denomination dropdown so the wizard's two pickers look the
// same, with an optional info hint beside the label.
class _RoleDropdownField extends StatelessWidget {
  final String label;
  final String? value;
  final String hint;
  final String? errorText;
  final VoidCallback onTap;
  final String? hintText;
  final String? hintId;

  const _RoleDropdownField({
    required this.label,
    required this.value,
    required this.hint,
    required this.onTap,
    this.errorText,
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
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
            decoration: BoxDecoration(
              color: AppColors.fieldFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: errorText != null
                    ? AppColors.errorRed
                    : AppColors.muted.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value ?? hint,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      color: value == null
                          ? AppColors.muted.withValues(alpha: 0.5)
                          : AppColors.deepDarkBrown,
                    ),
                  ),
                ),
                AppIcon(
                  AppIcons.chevronDown,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.errorRed,
            ),
          ),
        ],
      ],
    );
  }
}

// Free-text field revealed when the priest picks the 'Other' role.
class _OtherRoleField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final VoidCallback? onChanged;

  const _OtherRoleField({
    required this.controller,
    required this.hint,
    this.onChanged,
  });

  @override
  State<_OtherRoleField> createState() => _OtherRoleFieldState();
}

class _OtherRoleFieldState extends State<_OtherRoleField> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (mounted) setState(() => _focused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      textInputAction: TextInputAction.done,
      maxLength: 60,
      onChanged: (_) => widget.onChanged?.call(),
      cursorColor: AppColors.primaryBrown,
      cursorWidth: 1.6,
      style: GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: AppColors.deepDarkBrown,
      ),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: AppColors.muted.withValues(alpha: 0.5),
        ),
        filled: true,
        fillColor: AppColors.fieldFill,
        isDense: true,
        counterText: '',
        border: _otherFieldBorder(AppColors.muted.withValues(alpha: 0.2)),
        enabledBorder: _otherFieldBorder(
          _focused
              ? AppColors.primaryBrown
              : AppColors.muted.withValues(alpha: 0.2),
        ),
        focusedBorder:
            _otherFieldBorder(AppColors.primaryBrown, width: 1.5),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }

  OutlineInputBorder _otherFieldBorder(Color color, {double width = 1}) {
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
            color: AppColors.fieldFill,
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
                child: AppIcon(
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
