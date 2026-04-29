// Edit Profile — display name + avatar.
//
// Email is intentionally read-only because authentication is tied to
// the OAuth provider (Google / Apple). Letting the user type a new
// email here would create a mismatch between the auth identity and
// the Firestore profile, so we just show the auth email and lock it.
//
// Save flow:
//   1. If a new photo was picked, compress it via ImageUtils, upload
//      to Storage at users/{uid}/profile.jpg, get the download URL.
//   2. Patch users/{uid} with the new displayName (+ photoUrl if
//      changed). Both writes go through one update() call so the
//      doc never lands in a half-saved state.
//   3. Mirror the change into FirebaseAuth.currentUser so the auth
//      profile stays in step with our Firestore source of truth.
//
// We update Firestore first (it's our canonical store), and only
// touch the auth profile after Firestore succeeds — that way a
// failure during the auth update doesn't leave Firestore behind a
// stale name.

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/image_utils.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  String _email = '';
  String _photoUrl = '';
  String? _newPhotoPath;
  String _initialName = '';
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .doc('users/${user.uid}')
          .get()
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      final data = doc.data();
      final name =
          (data?['displayName'] as String?) ?? user.displayName ?? '';
      setState(() {
        _initialName = name;
        _nameController.text = name;
        _email = (data?['email'] as String?) ?? user.email ?? '';
        _photoUrl =
            (data?['photoUrl'] as String?) ?? user.photoURL ?? '';
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      final name = user.displayName ?? '';
      setState(() {
        _initialName = name;
        _nameController.text = name;
        _email = user.email ?? '';
        _photoUrl = user.photoURL ?? '';
        _isLoading = false;
      });
    }
  }

  bool get _hasChanges {
    final nameChanged = _nameController.text.trim() != _initialName.trim();
    return nameChanged || _newPhotoPath != null;
  }

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
                  'Change Photo',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Pick a new profile picture',
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
      // Pre-shrink at pick time — the avatar lives at 800px max
      // and decoding 8MP would just waste memory before compression
      // overrides it anyway.
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
        _newPhotoPath = picked.path;
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

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || name.length < 2) {
      AppSnackBar.error(context, 'Name must be at least 2 characters');
      return;
    }

    setState(() => _isSaving = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      final uid = user?.uid;
      if (uid == null) {
        if (!mounted) return;
        setState(() => _isSaving = false);
        AppSnackBar.error(context, 'Not signed in.');
        return;
      }

      String? newPhotoUrl;

      if (_newPhotoPath != null) {
        final compressed =
            await ImageUtils.compressImage(_newPhotoPath!);
        final ref = FirebaseStorage.instance
            .ref('users/$uid/profile.jpg');
        await ref.putFile(File(compressed));
        newPhotoUrl = await ref.getDownloadURL();
      }

      final updates = <String, dynamic>{
        'displayName': name,
      };
      if (newPhotoUrl != null) {
        updates['photoUrl'] = newPhotoUrl;
      }

      await FirebaseFirestore.instance
          .doc('users/$uid')
          .update(updates)
          .timeout(const Duration(seconds: 10));

      // Best-effort sync of the auth profile. If these fail (rare —
      // network blip mid-save), the Firestore doc is already correct
      // and that's what the rest of the app reads from, so we don't
      // surface the error.
      try {
        await user!.updateDisplayName(name);
        if (newPhotoUrl != null) {
          await user.updatePhotoURL(newPhotoUrl);
        }
      } catch (_) {
        // Swallow — Firestore is the source of truth.
      }

      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _initialName = name;
        if (newPhotoUrl != null) {
          _photoUrl = newPhotoUrl;
          _newPhotoPath = null;
        }
      });
      AppSnackBar.success(context, 'Profile updated');
      context.pop();
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(context, 'Save timed out. Try again.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(context, 'Failed to update profile.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: AppColors.deepDarkBrown,
          ),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Edit Profile',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.only(right: 20),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primaryBrown,
                  ),
                ),
              ),
            )
          else if (_hasChanges)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: _save,
                child: Text(
                  'Save',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBrown,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: AppColors.primaryBrown,
                ),
              ),
            )
          : SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Center(child: _PhotoSection(
                    photoUrl: _photoUrl,
                    newPhotoPath: _newPhotoPath,
                    displayName: _nameController.text,
                    onTap: _showImagePickerSheet,
                  )),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Tap to change photo',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Display Name',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F5F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.muted.withValues(alpha: 0.12),
                      ),
                    ),
                    child: TextField(
                      controller: _nameController,
                      focusNode: _nameFocus,
                      textCapitalization: TextCapitalization.words,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        color: AppColors.deepDarkBrown,
                      ),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Your display name',
                        hintStyle: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted.withValues(alpha: 0.4),
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Email',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.muted.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w400,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: AppColors.muted.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Email is linked to your Google account and cannot be changed',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
}

class _PhotoSection extends StatelessWidget {
  final String photoUrl;
  final String? newPhotoPath;
  final String displayName;
  final VoidCallback onTap;

  const _PhotoSection({
    required this.photoUrl,
    required this.newPhotoPath,
    required this.displayName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasNew = newPhotoPath != null;
    final hasRemote = photoUrl.isNotEmpty;
    final hasAnyImage = hasNew || hasRemote;
    final initial = displayName.trim().isNotEmpty
        ? displayName.trim()[0].toUpperCase()
        : '?';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF7F5F2),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.15),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  blurRadius: 16,
                  color: Colors.black.withValues(alpha: 0.06),
                  offset: const Offset(0, 4),
                ),
              ],
              image: hasNew
                  ? DecorationImage(
                      image: FileImage(File(newPhotoPath!)),
                      fit: BoxFit.cover,
                    )
                  : hasRemote
                      ? DecorationImage(
                          image: NetworkImage(photoUrl),
                          fit: BoxFit.cover,
                        )
                      : null,
            ),
            child: hasAnyImage
                ? null
                : Center(
                    child: Text(
                      initial,
                      style: GoogleFonts.inter(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryBrown,
                border: Border.all(
                  color: AppColors.background,
                  width: 2.5,
                ),
              ),
              child: const Icon(
                Icons.camera_alt_outlined,
                size: 14,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerOption extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F5F2),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.muted.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryBrown.withValues(alpha: 0.08),
              ),
              child: Icon(
                icon,
                size: 20,
                color: AppColors.primaryBrown,
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
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppColors.muted.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}
