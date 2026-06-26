// Priest's own profile — view + inline edit.
//
// Class is named PriestMyProfilePage to avoid colliding with the
// USER-side PriestProfilePage (lib/features/user/home/pages/...)
// which renders a public-facing speaker profile from the home feed.
//
// View ↔ edit is a single page (not a separate route) so the priest
// keeps their scroll position and visual context when toggling. Edit
// mode does several visible things at once on purpose — banner, field
// chrome change, sticky save bar — because the previous version was
// too subtle and priests didn't realise they had entered edit mode.
//
// Locked fields (name, email, denomination) are read from priests/{uid}
// and intentionally not editable here — changing them later cascades
// through KYC/admin moderation, so we keep them owned by support.
// Everything else writes back into priests/{uid} on Save.

import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/constants/community_roles.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/image_utils.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:country_picker/country_picker.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/image_crop_page.dart';
import 'package:gospel_vox/core/widgets/phone_country_prefix.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Source of truth for chip options. Kept here (rather than imported from
// the registration step) because that file is in a "do not touch" area
// and exposes them privately. If they diverge later, surface a follow-up
// task to lift these into a shared constants file.
const List<String> _kSpecializations = [
  'Counseling',
  'Prayer Support',
  'Healing Ministry',
  'Deliverance',
  'Bible Teaching',
  'Youth Ministry',
  'Family Counseling',
  'Marriage Guidance',
  'Grief Support',
  'Addiction Recovery',
  'Spiritual Direction',
  'Evangelism',
  'Worship Leading',
  "Children's Ministry",
  'Other',
];

const List<String> _kLanguages = [
  'English',
  'Malayalam',
  'Hindi',
  'Tamil',
  'Telugu',
  'Kannada',
  'Marathi',
  'Bengali',
  'Gujarati',
  'Urdu',
  'Punjabi',
  'Odia',
  'Other',
];

class PriestMyProfilePage extends StatefulWidget {
  const PriestMyProfilePage({super.key});

  @override
  State<PriestMyProfilePage> createState() => _PriestMyProfilePageState();
}

class _PriestMyProfilePageState extends State<PriestMyProfilePage> {
  bool _isLoading = true;
  bool _isEditing = false;
  bool _isSaving = false;

  // ── View-mode snapshot. Mirrors priests/{uid}.
  String _fullName = '';
  String _email = '';
  String _phone = '';
  String _denomination = '';
  String _communityRole = '';
  String _photoUrl = '';
  String _bio = '';
  String _churchName = '';
  String _diocese = '';
  String _location = '';
  int _yearsOfExperience = 0;
  List<String> _specializations = const [];
  List<String> _languages = const [];
  String _status = '';
  bool _isActivated = false;
  double _rating = 0;
  int _reviewCount = 0;
  int _totalSessions = 0;

  // Selected country for the phone dial code. Hydrated from the saved
  // phone when Edit is tapped; combined with _phoneController into
  // "+<code> <number>" on save.
  Country _phoneCountry = defaultPhoneCountry();

  // ── Edit-mode controllers. Hydrated when Edit is tapped.
  final _phoneController = TextEditingController();
  final _bioController = TextEditingController();
  final _churchController = TextEditingController();
  final _dioceseController = TextEditingController();
  final _locationController = TextEditingController();
  final _experienceController = TextEditingController();
  final _otherSpecController = TextEditingController();
  final _otherLanguageController = TextEditingController();
  final _otherRoleController = TextEditingController();
  // Edit-mode role state. _editCommunityRole equals [kCommunityRoleOther]
  // while the free-text field is showing; the typed value is merged on
  // Save so the stored role never reads the literal 'Other'.
  String? _editCommunityRole;
  bool _editRoleOtherSelected = false;
  List<String> _editSpecializations = [];
  List<String> _editLanguages = [];
  // Tracks whether the user has tapped the "Other" chip in either
  // group. When true we surface an inline text field; the typed
  // value is merged into the saved array on Save.
  bool _editSpecOtherSelected = false;
  bool _editLanguageOtherSelected = false;
  String? _newPhotoPath;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _bioController.dispose();
    _churchController.dispose();
    _dioceseController.dispose();
    _locationController.dispose();
    _experienceController.dispose();
    _otherSpecController.dispose();
    _otherLanguageController.dispose();
    _otherRoleController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .doc('priests/$uid')
          .get()
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      final data = doc.data();
      if (!doc.exists || data == null) {
        setState(() => _isLoading = false);
        return;
      }

      setState(() {
        _fullName = data['fullName'] as String? ?? '';
        _email = data['email'] as String? ?? '';
        _phone = data['phone'] as String? ?? '';
        _denomination = data['denomination'] as String? ?? '';
        _communityRole = data['communityRole'] as String? ?? '';
        _photoUrl = data['photoUrl'] as String? ?? '';
        _bio = data['bio'] as String? ?? '';
        _churchName = data['churchName'] as String? ?? '';
        _diocese = data['diocese'] as String? ?? '';
        _location = data['location'] as String? ?? '';
        _yearsOfExperience =
            (data['yearsOfExperience'] as num?)?.toInt() ?? 0;
        _specializations =
            List<String>.from(data['specializations'] as List? ?? const []);
        _languages =
            List<String>.from(data['languages'] as List? ?? const []);
        _status = data['status'] as String? ?? '';
        _isActivated = data['isActivated'] as bool? ?? false;
        _rating = (data['rating'] as num?)?.toDouble() ?? 0;
        _reviewCount = (data['reviewCount'] as num?)?.toInt() ?? 0;
        _totalSessions = (data['totalSessions'] as num?)?.toInt() ?? 0;
        _isLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Loading timed out.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Failed to load profile.');
    }
  }

  void _enterEditMode() {
    // Split the saved "+<code> <number>" (or legacy bare digits) back into
    // the country selector + the national-number field.
    _phoneCountry = phoneCountryFromStored(_phone);
    _phoneController.text = phoneNumberFromStored(_phone);
    _bioController.text = _bio;
    _churchController.text = _churchName;
    _dioceseController.text = _diocese;
    _locationController.text = _location;
    _experienceController.text =
        _yearsOfExperience > 0 ? _yearsOfExperience.toString() : '';

    // Hydrate the role picker. A known role pre-selects its item; any
    // other non-empty value is a custom 'Other' entry the priest typed,
    // so we reopen on 'Other' with the value back in the field.
    if (_communityRole.isEmpty) {
      _editCommunityRole = null;
      _editRoleOtherSelected = false;
      _otherRoleController.text = '';
    } else if (isKnownCommunityRole(_communityRole)) {
      _editCommunityRole = _communityRole;
      _editRoleOtherSelected = false;
      _otherRoleController.text = '';
    } else {
      _editCommunityRole = kCommunityRoleOther;
      _editRoleOtherSelected = true;
      _otherRoleController.text = _communityRole;
    }

    // Split saved specializations into "known chips" + "custom Other".
    // Anything that doesn't appear in _kSpecializations is treated as
    // the priest's free-text Other value so re-editing preserves it.
    final knownSpecs = _kSpecializations.toSet();
    final specCustom = _specializations
        .where((s) => !knownSpecs.contains(s))
        .toList();
    _editSpecializations = _specializations
        .where((s) => knownSpecs.contains(s))
        .toList();
    if (specCustom.isNotEmpty) {
      _editSpecOtherSelected = true;
      _otherSpecController.text = specCustom.join(', ');
    } else {
      _editSpecOtherSelected = false;
      _otherSpecController.text = '';
    }

    final knownLangs = _kLanguages.toSet();
    final langCustom = _languages
        .where((l) => !knownLangs.contains(l))
        .toList();
    _editLanguages = _languages
        .where((l) => knownLangs.contains(l))
        .toList();
    if (langCustom.isNotEmpty) {
      _editLanguageOtherSelected = true;
      _otherLanguageController.text = langCustom.join(', ');
    } else {
      _editLanguageOtherSelected = false;
      _otherLanguageController.text = '';
    }

    _newPhotoPath = null;
    setState(() => _isEditing = true);
  }

  void _cancelEdit() {
    FocusScope.of(context).unfocus();
    setState(() {
      _isEditing = false;
      _newPhotoPath = null;
    });
  }

  Future<void> _pickNewPhoto() async {
    final source = await _showPhotoSourceSheet();
    if (source == null) return;
    try {
      final picker = ImagePicker();
      // Match every other picker in the app — 800×800 is plenty for a
      // profile avatar and decoding 1600 wastes memory before
      // ImageUtils.compressImage shrinks it again.
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      // Square-crop step so a portrait photo isn't half-cut by the
      // cover-fit avatar. Null = user backed out of the cropper, so we
      // keep the current photo untouched.
      final cropped = await cropAvatarSquare(context, picked.path);
      if (!mounted || cropped == null) return;
      setState(() => _newPhotoPath = cropped);
    } catch (_) {
      if (mounted) AppSnackBar.error(context, 'Could not open photo picker.');
    }
  }

  Future<ImageSource?> _showPhotoSourceSheet() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              _PhotoSourceRow(
                icon: AppIcons.camera,
                label: 'Take a photo',
                onTap: () => Navigator.of(sheetCtx).pop(ImageSource.camera),
              ),
              const SizedBox(height: 6),
              _PhotoSourceRow(
                icon: AppIcons.gallery,
                label: 'Choose from library',
                onTap: () => Navigator.of(sheetCtx).pop(ImageSource.gallery),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveProfile() async {
    if (_isSaving) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppSnackBar.error(context, 'Not signed in.');
      return;
    }

    HapticFeedback.lightImpact();
    FocusScope.of(context).unfocus();

    // Country-aware phone check before we write anything. Profile editing
    // had no phone validation at all, so a malformed number could be
    // saved silently.
    final phoneError =
        validatePhoneForCountry(_phoneCountry, _phoneController.text);
    if (phoneError != null) {
      AppSnackBar.error(context, phoneError);
      return;
    }

    final phone = composePhone(_phoneCountry, _phoneController.text);
    final bio = _bioController.text.trim();
    final church = _churchController.text.trim();
    final diocese = _dioceseController.text.trim();
    final location = _locationController.text.trim();
    final years =
        int.tryParse(_experienceController.text.trim()) ?? _yearsOfExperience;

    // Merge custom Other text into the saved arrays. The "Other" chip
    // is a UX marker, not real data — we drop it and substitute the
    // typed value so the user-facing display reads naturally.
    final mergedSpecs = _mergeOther(
      selected: _editSpecializations,
      otherSelected: _editSpecOtherSelected,
      otherText: _otherSpecController.text,
    );
    final mergedLangs = _mergeOther(
      selected: _editLanguages,
      otherSelected: _editLanguageOtherSelected,
      otherText: _otherLanguageController.text,
    );

    // Resolve the role: typed text for an 'Other' pick, else the chosen
    // role. It's mandatory at registration, so a cleared value here is a
    // user error we block rather than silently writing an empty role.
    final resolvedRole = _editCommunityRole == kCommunityRoleOther
        ? _otherRoleController.text.trim()
        : (_editCommunityRole ?? '');
    if (resolvedRole.isEmpty) {
      AppSnackBar.error(context, 'Please select your role');
      return;
    }

    setState(() => _isSaving = true);

    try {
      final updates = <String, dynamic>{
        'phone': phone,
        'communityRole': resolvedRole,
        'bio': bio,
        'churchName': church,
        'diocese': diocese,
        'location': location,
        'yearsOfExperience': years,
        'specializations': mergedSpecs,
        'languages': mergedLangs,
      };

      // Upload + overwrite the same Storage path registration uses
      // (priests/{uid}/photo.jpg) so we never accumulate orphans.
      if (_newPhotoPath != null) {
        final compressed = await ImageUtils.compressImage(_newPhotoPath!);
        final ref =
            FirebaseStorage.instance.ref().child('priests/$uid/photo.jpg');
        final task = ref.putFile(
          File(compressed),
          SettableMetadata(contentType: 'image/jpeg'),
        );
        final snap = await task.timeout(const Duration(seconds: 60));
        final url = await snap.ref.getDownloadURL();
        updates['photoUrl'] = url;
      }

      await FirebaseFirestore.instance
          .doc('priests/$uid')
          .update(updates)
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      setState(() {
        _phone = phone;
        _communityRole = resolvedRole;
        _bio = bio;
        _churchName = church;
        _diocese = diocese;
        _location = location;
        _yearsOfExperience = years;
        _specializations = mergedSpecs;
        _languages = mergedLangs;
        if (updates.containsKey('photoUrl')) {
          _photoUrl = updates['photoUrl'] as String;
        }
        _isEditing = false;
        _isSaving = false;
        _newPhotoPath = null;
      });
      AppSnackBar.success(context, 'Profile updated');
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(context, 'Save timed out. Try again.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(context, 'Failed to save. Try again.');
    }
  }

  // Strip the 'Other' marker from the selected chips and substitute
  // the priest's typed values. Comma- or newline-separated entries
  // are split so one Other field can capture more than one custom
  // value when needed. Duplicates and empties are dropped.
  List<String> _mergeOther({
    required List<String> selected,
    required bool otherSelected,
    required String otherText,
  }) {
    final out = <String>[];
    final seen = <String>{};
    for (final item in selected) {
      if (item == 'Other') continue;
      final v = item.trim();
      if (v.isEmpty || !seen.add(v.toLowerCase())) continue;
      out.add(v);
    }
    if (otherSelected) {
      final pieces = otherText
          .split(RegExp(r'[,\n]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      for (final p in pieces) {
        if (seen.add(p.toLowerCase())) out.add(p);
      }
    }
    return out;
  }

  // Role bottom sheet — same single-select pattern as registration so
  // the priest sees a familiar picker when editing their role.
  Future<void> _pickCommunityRole() async {
    FocusScope.of(context).unfocus();
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
                        final selected = option == _editCommunityRole;
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
        _editCommunityRole = picked;
        _editRoleOtherSelected = picked == kCommunityRoleOther;
        if (!_editRoleOtherSelected) _otherRoleController.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Background gets a tiny warm shift in edit mode so the whole
    // surface feels different — subliminal but reinforces the sticky
    // banner and bottom bar.
    final bgColor = _isEditing
        ? const Color(0xFFEFE6D7) // Slightly deeper warm than 0xFFF4EDE3
        : AppColors.background;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: _buildAppBar(),
      // Resize when the keyboard opens so editable fields stay visible
      // and the sticky bottom bar lifts above the keyboard naturally.
      resizeToAvoidBottomInset: true,
      body: _isLoading
          ? const _ProfileShimmer()
          : SafeArea(
              bottom: false,
              child: _buildScrollContent(),
            ),
      // Save bar lives in bottomNavigationBar (not Positioned in a
      // Stack) so the Scaffold accounts for its height when sizing the
      // body. Without this, a focused field could sit visually below
      // the bar — fields looked invisible while typing.
      bottomNavigationBar: _isEditing && !_isLoading
          ? _buildStickySaveBar()
          : null,
    );
  }

  // ─── App bar ─────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _isEditing
          ? const Color(0xFFEFE6D7)
          : AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      leadingWidth: 56,
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Align(
          child: _isEditing
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _cancelEdit,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.surfaceWhite,
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                          color: Colors.black.withValues(alpha: 0.05),
                        ),
                      ],
                    ),
                    child: AppIcon(
                      AppIcons.close,
                      size: 18,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                )
              : const AppBackButton(),
        ),
      ),
      title: Text(
        _isEditing ? 'Edit Profile' : 'My Profile',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      centerTitle: false,
      actions: [
        if (!_isEditing && !_isLoading)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _EditPillButton(onTap: _enterEditMode),
          ),
      ],
    );
  }

  // ─── Scroll content (everything below the app bar) ─────────

  Widget _buildScrollContent() {
    // Save bar lives in bottomNavigationBar now, so we no longer need
    // extra bottom padding to clear it — the Scaffold handles spacing.
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isEditing) ...[
            const SizedBox(height: 8),
            _buildEditingBanner(),
            const SizedBox(height: 20),
          ] else
            const SizedBox(height: 12),
          _buildHeader(),
          const SizedBox(height: 28),
          _SectionLabel(_isEditing ? 'ACCOUNT (LOCKED)' : 'ACCOUNT'),
          const SizedBox(height: 10),
          _buildAccountGroup(),
          if (_isEditing) ...[
            const SizedBox(height: 8),
            const _InfoTip(
              'Name, email, and denomination cannot be changed. '
              'Contact support if you need to update these.',
            ),
          ],
          const SizedBox(height: 28),
          const _SectionLabel('MINISTRY DETAILS'),
          const SizedBox(height: 10),
          _buildMinistrySection(),
          const SizedBox(height: 28),
          const _SectionLabel('BIO'),
          const SizedBox(height: 10),
          _buildBioSection(),
          const SizedBox(height: 28),
          _buildChipSectionHeader(
            label: 'SPECIALIZATIONS',
            count: _isEditing
                ? _editSpecializations.length
                : _specializations.length,
          ),
          const SizedBox(height: 10),
          _buildSpecializationsSection(),
          const SizedBox(height: 28),
          _buildChipSectionHeader(
            label: 'LANGUAGES',
            count: _isEditing ? _editLanguages.length : _languages.length,
          ),
          const SizedBox(height: 10),
          _buildLanguagesSection(),
        ],
      ),
    );
  }

  // ─── Editing banner ──────────────────────────────

  Widget _buildEditingBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primaryBrown.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primaryBrown,
            ),
            child: const AppIcon(
              AppIcons.edit,
              size: 14,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "You're editing your profile",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBrown,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Tap any field below to update it',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.primaryBrown.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Header (avatar + name + status) ─────────────

  Widget _buildHeader() {
    return Column(
      children: [
        Center(
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
                    color: AppColors.amberGold.withValues(alpha: 0.3),
                    width: 2.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                      color: Colors.black.withValues(alpha: 0.06),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildAvatarChild(),
              ),
              if (_isEditing)
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _pickNewPhoto,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primaryBrown,
                        border: Border.all(
                          color: AppColors.background,
                          width: 2.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                            color: AppColors.primaryBrown
                                .withValues(alpha: 0.3),
                          ),
                        ],
                      ),
                      child: const AppIcon(
                        AppIcons.camera,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_isEditing) ...[
          const SizedBox(height: 14),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _pickNewPhoto,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: AppColors.surfaceWhite,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.primaryBrown.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.camera,
                    size: 14,
                    color: AppColors.primaryBrown,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _newPhotoPath != null ? 'Change photo' : 'Change photo',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBrown,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ] else ...[
          const SizedBox(height: 16),
          Text(
            _fullName.isEmpty ? 'Speaker' : _fullName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _denomination.isEmpty ? '—' : _denomination,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 10),
          _buildStatusRow(),
          const SizedBox(height: 10),
          Text(
            '$_totalSessions sessions · $_yearsOfExperience yrs experience',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAvatarChild() {
    if (_newPhotoPath != null) {
      return Image.file(File(_newPhotoPath!), fit: BoxFit.cover);
    }
    if (_photoUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: _photoUrl,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => _avatarInitial(),
        placeholder: (_, _) => const SizedBox.shrink(),
      );
    }
    return _avatarInitial();
  }

  Widget _avatarInitial() {
    final letter = _fullName.isNotEmpty ? _fullName[0].toUpperCase() : '?';
    return Center(
      child: Text(
        letter,
        style: GoogleFonts.inter(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }

  Widget _buildStatusRow() {
    final isApproved = _status == 'approved';
    final isSuspended = _status == 'suspended';

    final Color badgeFg;
    final Color badgeBg;
    final String badgeText;
    if (_isActivated) {
      badgeFg = AppColors.successGreen;
      badgeBg = AppColors.successGreen.withValues(alpha: 0.08);
      badgeText = 'Active';
    } else if (isSuspended) {
      badgeFg = AppColors.errorRed;
      badgeBg = AppColors.errorRed.withValues(alpha: 0.08);
      badgeText = 'Suspended';
    } else if (isApproved) {
      badgeFg = AppColors.successGreen;
      badgeBg = AppColors.successGreen.withValues(alpha: 0.08);
      badgeText = 'Approved';
    } else {
      badgeFg = AppColors.muted;
      badgeBg = AppColors.muted.withValues(alpha: 0.08);
      badgeText = _status.isEmpty ? 'Pending' : _capitalize(_status);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: badgeBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              badgeText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: badgeFg,
              ),
            ),
          ),
        ),
        if (_rating > 0) ...[
          const SizedBox(width: 10),
          // Whole rating chip is tap-wrapped so the priest gets a
          // natural shortcut from "I have ratings" → "show me what
          // they said" without needing to bounce through the
          // dashboard. The chevron is the visual affordance.
          Flexible(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                context.push('/priest/reviews');
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.starFilled,
                    size: 15,
                    color: AppColors.amberGold,
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      '${_rating.toStringAsFixed(1)} ($_reviewCount)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                  ),
                  AppIcon(
                    AppIcons.chevronRight,
                    size: 14,
                    color: AppColors.muted.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  // ─── Account section (locked) ────────────────────

  Widget _buildAccountGroup() {
    // In edit mode, locked fields render visibly disabled (greyed
    // background + lock badge) so the priest sees at-a-glance which
    // fields they can vs. can't change.
    if (_isEditing) {
      return Column(
        children: [
          _DisabledLockedField(
            icon: AppIcons.userOutline,
            label: 'Full Name',
            value: _fullName,
          ),
          const SizedBox(height: 10),
          _DisabledLockedField(
            icon: AppIcons.mail,
            label: 'Email',
            value: _email,
          ),
          const SizedBox(height: 10),
          _DisabledLockedField(
            icon: AppIcons.church,
            label: 'Denomination',
            value: _denomination,
          ),
        ],
      );
    }

    return _ProfileGroup(
      children: [
        _ProfileField(
          icon: AppIcons.userOutline,
          label: 'Full Name',
          value: _fullName,
          isLocked: true,
        ),
        _ProfileField(
          icon: AppIcons.mail,
          label: 'Email',
          value: _email,
          isLocked: true,
        ),
        _ProfileField(
          icon: AppIcons.church,
          label: 'Denomination',
          value: _denomination,
          isLocked: true,
        ),
      ],
    );
  }

  // ─── Ministry details ────────────────────────────

  Widget _buildMinistrySection() {
    if (_isEditing) {
      return Column(
        children: [
          _RolePickerField(
            label: 'Christian Community Role',
            value: _editCommunityRole,
            hint: 'Select your role',
            onTap: _pickCommunityRole,
          ),
          if (_editRoleOtherSelected) ...[
            const SizedBox(height: 10),
            _OtherInputField(
              controller: _otherRoleController,
              hint: 'Type your role',
            ),
          ],
          const SizedBox(height: 14),
          _FormField(
            label: 'Phone',
            icon: AppIcons.phone,
            controller: _phoneController,
            hint: '98765 43210',
            keyboardType: TextInputType.phone,
            prefix: PhoneCountryPrefix(
              country: _phoneCountry,
              onSelected: (c) => setState(() => _phoneCountry = c),
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(15),
            ],
          ),
          const SizedBox(height: 14),
          _FormField(
            label: 'Church',
            icon: Icons.location_city_outlined,
            controller: _churchController,
            hint: 'Name of your church',
            inputFormatters: [LengthLimitingTextInputFormatter(80)],
          ),
          const SizedBox(height: 14),
          _FormField(
            label: 'Diocese',
            icon: AppIcons.map,
            controller: _dioceseController,
            hint: 'Your diocese',
            inputFormatters: [LengthLimitingTextInputFormatter(80)],
          ),
          const SizedBox(height: 14),
          _FormField(
            label: 'Location',
            icon: AppIcons.location,
            controller: _locationController,
            hint: 'City, State',
            inputFormatters: [LengthLimitingTextInputFormatter(80)],
          ),
          const SizedBox(height: 14),
          _FormField(
            label: 'Years of Experience',
            icon: AppIcons.briefcase,
            controller: _experienceController,
            hint: 'e.g. 12',
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
          ),
        ],
      );
    }

    return _ProfileGroup(
      children: [
        _ProfileField(
          icon: AppIcons.userOutline,
          label: 'Role',
          value: _communityRole,
        ),
        _ProfileField(
          icon: AppIcons.phone,
          label: 'Phone',
          value: phoneForDisplay(_phone),
        ),
        _ProfileField(
          icon: Icons.location_city_outlined,
          label: 'Church',
          value: _churchName,
        ),
        _ProfileField(
          icon: AppIcons.map,
          label: 'Diocese',
          value: _diocese,
        ),
        _ProfileField(
          icon: AppIcons.location,
          label: 'Location',
          value: _location,
        ),
        _ProfileField(
          icon: AppIcons.briefcase,
          label: 'Experience',
          value:
              _yearsOfExperience > 0 ? '$_yearsOfExperience years' : '',
        ),
      ],
    );
  }

  // ─── Bio ─────────────────────────────────────────

  Widget _buildBioSection() {
    if (_isEditing) {
      return _FormField(
        label: 'About your ministry',
        icon: AppIcons.bible,
        controller: _bioController,
        hint: 'Share your story, what brings you here, who you serve...',
        maxLines: 6,
        minLines: 5,
        maxLength: 500,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: Text(
        _bio.isEmpty ? 'No bio added yet' : _bio,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          height: 1.6,
          color: _bio.isEmpty
              ? AppColors.muted.withValues(alpha: 0.7)
              : AppColors.deepDarkBrown,
        ),
      ),
    );
  }

  // ─── Chip section header (label + selected count) ─────

  Widget _buildChipSectionHeader({required String label, required int count}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: AppColors.muted,
              ),
            ),
          ),
          if (_isEditing && count > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primaryBrown.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count selected',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBrown,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Specializations / Languages ────────────────

  Widget _buildSpecializationsSection() {
    final items = _isEditing ? _editSpecializations : _specializations;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        _isEditing ? 12 : 16,
        16,
        16,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: _isEditing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ChipEditHint(
                  text:
                      'Tap chips to add or remove specializations',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _kSpecializations.map((s) {
                    if (s == 'Other') {
                      return _ChoiceChipTile(
                        label: 'Other',
                        selected: _editSpecOtherSelected,
                        onTap: () {
                          setState(() {
                            _editSpecOtherSelected =
                                !_editSpecOtherSelected;
                            if (!_editSpecOtherSelected) {
                              _otherSpecController.clear();
                            }
                          });
                        },
                      );
                    }
                    final selected = _editSpecializations.contains(s);
                    return _ChoiceChipTile(
                      label: s,
                      selected: selected,
                      onTap: () {
                        setState(() {
                          if (selected) {
                            _editSpecializations.remove(s);
                          } else {
                            _editSpecializations.add(s);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                if (_editSpecOtherSelected) ...[
                  const SizedBox(height: 12),
                  _OtherInputField(
                    controller: _otherSpecController,
                    hint: 'Type your specialization',
                  ),
                ],
              ],
            )
          : (items.isEmpty
              ? Text(
                  'No specializations selected',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.7),
                  ),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: items
                      .map(
                        (s) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primaryBrown
                                .withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: AppColors.primaryBrown
                                  .withValues(alpha: 0.1),
                            ),
                          ),
                          child: Text(
                            s,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AppColors.primaryBrown,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                )),
    );
  }

  Widget _buildLanguagesSection() {
    final items = _isEditing ? _editLanguages : _languages;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        _isEditing ? 12 : 16,
        16,
        16,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: _isEditing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ChipEditHint(
                  text: 'Tap chips to add or remove languages you speak',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _kLanguages.map((l) {
                    if (l == 'Other') {
                      return _ChoiceChipTile(
                        label: 'Other',
                        selected: _editLanguageOtherSelected,
                        onTap: () {
                          setState(() {
                            _editLanguageOtherSelected =
                                !_editLanguageOtherSelected;
                            if (!_editLanguageOtherSelected) {
                              _otherLanguageController.clear();
                            }
                          });
                        },
                      );
                    }
                    final selected = _editLanguages.contains(l);
                    return _ChoiceChipTile(
                      label: l,
                      selected: selected,
                      onTap: () {
                        setState(() {
                          if (selected) {
                            _editLanguages.remove(l);
                          } else {
                            _editLanguages.add(l);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                if (_editLanguageOtherSelected) ...[
                  const SizedBox(height: 12),
                  _OtherInputField(
                    controller: _otherLanguageController,
                    hint: 'Type the language you speak',
                  ),
                ],
              ],
            )
          : (items.isEmpty
              ? Text(
                  'No languages selected',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.7),
                  ),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: items
                      .map(
                        (l) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceWhite,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color:
                                  AppColors.muted.withValues(alpha: 0.18),
                            ),
                          ),
                          child: Text(
                            l,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AppColors.deepDarkBrown,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                )),
    );
  }

  // ─── Sticky bottom save bar ────────────────────

  Widget _buildStickySaveBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        boxShadow: [
          BoxShadow(
            blurRadius: 24,
            offset: const Offset(0, -4),
            color: Colors.black.withValues(alpha: 0.08),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: _BottomBarButton(
                  label: 'Cancel',
                  onTap: _isSaving ? null : _cancelEdit,
                  filled: false,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: _BottomBarButton(
                  label: 'Save Changes',
                  onTap: _isSaving ? null : _saveProfile,
                  filled: true,
                  loading: _isSaving,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Section label ─────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

// ─── Edit pill button (header CTA) ─────────────────────

class _EditPillButton extends StatefulWidget {
  final VoidCallback onTap;
  const _EditPillButton({required this.onTap});

  @override
  State<_EditPillButton> createState() => _EditPillButtonState();
}

class _EditPillButtonState extends State<_EditPillButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.96),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                  color:
                      AppColors.primaryBrown.withValues(alpha: 0.25),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(
                  AppIcons.edit,
                  size: 14,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  'Edit',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Bottom bar button (Cancel / Save) ─────────────────

class _BottomBarButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool loading;

  const _BottomBarButton({
    required this.label,
    required this.onTap,
    required this.filled,
    this.loading = false,
  });

  @override
  State<_BottomBarButton> createState() => _BottomBarButtonState();
}

class _BottomBarButtonState extends State<_BottomBarButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    final filled = widget.filled;

    final bg = filled
        ? (disabled
            ? AppColors.primaryBrown.withValues(alpha: 0.5)
            : AppColors.primaryBrown)
        : Colors.transparent;
    final fg = filled ? Colors.white : AppColors.deepDarkBrown;
    final borderColor = filled
        ? Colors.transparent
        : AppColors.muted.withValues(alpha: 0.3);

    return Listener(
      onPointerDown: (_) {
        if (!disabled) setState(() => _scale = 0.97);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
              boxShadow: filled && !disabled
                  ? [
                      BoxShadow(
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                        color: AppColors.primaryBrown
                            .withValues(alpha: 0.25),
                      ),
                    ]
                  : null,
            ),
            child: widget.loading
                ? const SizedBox(
                    width: 35,
                    height: 35,
                    child: AppLoader(),
                  )
                : Text(
                    widget.label,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── View-mode group container ─────────────────────────

class _ProfileGroup extends StatelessWidget {
  final List<Widget> children;
  const _ProfileGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Container(
                margin: const EdgeInsets.only(left: 56),
                height: 1,
                color: AppColors.muted.withValues(alpha: 0.06),
              ),
          ],
        ],
      ),
    );
  }
}

// ─── View-mode read-only field ─────────────────────────

class _ProfileField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isLocked;

  const _ProfileField({
    required this.icon,
    required this.label,
    required this.value,
    this.isLocked = false,
  });

  @override
  Widget build(BuildContext context) {
    final empty = value.isEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          AppIcon(
            icon,
            size: 18,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  empty ? 'Not set' : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: empty
                        ? AppColors.muted.withValues(alpha: 0.5)
                        : AppColors.deepDarkBrown,
                  ),
                ),
              ],
            ),
          ),
          if (isLocked) ...[
            const SizedBox(width: 8),
            AppIcon(
              AppIcons.lock,
              size: 14,
              color: AppColors.muted.withValues(alpha: 0.4),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Edit-mode locked field (visibly disabled) ─────────
//
// Uses a flat dimmed surface + lock badge so the priest sees this
// is intentionally not editable, not just an unstyled read-only row.

class _DisabledLockedField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DisabledLockedField({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final empty = value.isEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.muted.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        children: [
          AppIcon(
            icon,
            size: 18,
            color: AppColors.muted.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  empty ? 'Not set' : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.deepDarkBrown.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 7,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              color: AppColors.muted.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  AppIcons.lock,
                  size: 10,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 3),
                Text(
                  'Locked',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Form field (edit-mode input) ─────────────────────
//
// Real text-field aesthetic: label above, bordered input box below,
// brown focus ring. This is the visual signal that says "I'm an
// editable field, tap me." Replaces the previous inline-row design
// which was indistinguishable from view mode.

class _FormField extends StatefulWidget {
  final String label;
  final IconData icon;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  // Optional leading widget between the icon and the text (e.g. the phone
  // country-code selector).
  final Widget? prefix;

  const _FormField({
    required this.label,
    required this.icon,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.inputFormatters,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.prefix,
  });

  @override
  State<_FormField> createState() => _FormFieldState();
}

class _FormFieldState extends State<_FormField> {
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
    final borderColor = _focused
        ? AppColors.primaryBrown
        : AppColors.muted.withValues(alpha: 0.18);
    final iconColor = _focused
        ? AppColors.primaryBrown
        : AppColors.muted.withValues(alpha: 0.6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            widget.label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: widget.maxLines != null && widget.maxLines! > 1
                ? 12
                : 4,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: borderColor,
              width: _focused ? 1.6 : 1,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                      color: AppColors.primaryBrown
                          .withValues(alpha: 0.08),
                    ),
                  ]
                : [
                    BoxShadow(
                      blurRadius: 6,
                      offset: const Offset(0, 1),
                      color: Colors.black.withValues(alpha: 0.02),
                    ),
                  ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  top: widget.maxLines != null && widget.maxLines! > 1
                      ? 2
                      : 12,
                ),
                child: AppIcon(widget.icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 12),
              if (widget.prefix != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: widget.prefix,
                ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  keyboardType: widget.keyboardType,
                  inputFormatters: widget.inputFormatters,
                  maxLines: widget.maxLines,
                  minLines: widget.minLines,
                  maxLength: widget.maxLength,
                  cursorColor: AppColors.primaryBrown,
                  cursorWidth: 1.6,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                    color: AppColors.deepDarkBrown,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 12,
                    ),
                    border: InputBorder.none,
                    hintText: widget.hint,
                    hintStyle: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted.withValues(alpha: 0.45),
                    ),
                    counterText: widget.maxLength != null ? null : '',
                    counterStyle: GoogleFonts.inter(
                      fontSize: 10,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Role picker (single-select dropdown) ───────────
//
// Tappable box that opens the role bottom sheet. Styled to match
// _FormField so it reads as just another editable ministry field.

class _RolePickerField extends StatelessWidget {
  final String label;
  final String? value;
  final String hint;
  final VoidCallback onTap;

  const _RolePickerField({
    required this.label,
    required this.value,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.18),
              ),
              boxShadow: [
                BoxShadow(
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                  color: Colors.black.withValues(alpha: 0.02),
                ),
              ],
            ),
            child: Row(
              children: [
                AppIcon(
                  AppIcons.userOutline,
                  size: 18,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasValue ? value! : hint,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: hasValue
                          ? AppColors.deepDarkBrown
                          : AppColors.muted.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                AppIcon(
                  AppIcons.chevronDown,
                  size: 18,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Toggleable choice chip ─────────────────────────

class _ChoiceChipTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceChipTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryBrown
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.3),
            width: selected ? 1.5 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                    color: AppColors.primaryBrown
                        .withValues(alpha: 0.2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const AppIcon(
                AppIcons.check,
                size: 14,
                color: Colors.white,
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? Colors.white : AppColors.deepDarkBrown,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Inline text field used by the "Other" chip ─────
//
// Compact bordered input that appears below the chip group when the
// priest taps "Other". Comma- or newline-separated values let them
// list more than one custom entry without re-toggling.

class _OtherInputField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;

  const _OtherInputField({
    required this.controller,
    required this.hint,
  });

  @override
  State<_OtherInputField> createState() => _OtherInputFieldState();
}

class _OtherInputFieldState extends State<_OtherInputField> {
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
    final borderColor = _focused
        ? AppColors.primaryBrown
        : AppColors.muted.withValues(alpha: 0.25);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor,
          width: _focused ? 1.5 : 1,
        ),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        textInputAction: TextInputAction.done,
        maxLength: 80,
        cursorColor: AppColors.primaryBrown,
        cursorWidth: 1.6,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: AppColors.deepDarkBrown,
        ),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: widget.hint,
          hintStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: AppColors.muted.withValues(alpha: 0.5),
          ),
          counterText: '',
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}

// ─── Inline edit hint above chip groups ─────────────

class _ChipEditHint extends StatelessWidget {
  final String text;
  const _ChipEditHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppIcon(
          AppIcons.touch,
          size: 13,
          color: AppColors.muted.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Inline info tip ─────────────────────────────

class _InfoTip extends StatelessWidget {
  final String text;
  const _InfoTip(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(
            AppIcons.info,
            size: 13,
            color: AppColors.muted.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.muted.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Image-source bottom sheet row ─────────────────

class _PhotoSourceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PhotoSourceRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.primaryBrown.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: AppIcon(icon, size: 20, color: AppColors.primaryBrown),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            AppIcon(
              AppIcons.chevronRight,
              size: 20,
              color: AppColors.muted.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Loading shimmer ───────────────────────────────

class _ProfileShimmer extends StatelessWidget {
  const _ProfileShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.08),
      highlightColor: AppColors.muted.withValues(alpha: 0.03),
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        child: Column(
          children: [
            const SizedBox(height: 4),
            Container(
              width: 100,
              height: 100,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Container(width: 160, height: 16, color: Colors.white),
            const SizedBox(height: 8),
            Container(width: 120, height: 12, color: Colors.white),
            const SizedBox(height: 28),
            Container(
              height: 180,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              height: 240,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
