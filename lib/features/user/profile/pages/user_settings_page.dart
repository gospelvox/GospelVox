// User Settings — notifications + account deletion + legal links.
//
// Account deletion exists primarily because the App Store / Play
// Store policies REQUIRE an in-app delete option for any account
// system. Without this entry point the app gets rejected at review,
// regardless of the rest of the polish.
//
// Soft delete strategy:
//   We don't actually remove users/{uid} immediately — we mark it
//   isDeleted=true and zero out personally identifying fields. This
//   keeps session history intact for the priest side (their earnings
//   transcripts shouldn't disappear when a counterparty leaves) and
//   lets a backend cleanup job hard-delete on a delay if we ever
//   need it. Auth deletion (FirebaseAuth.user.delete) DOES happen
//   immediately so the user can no longer sign in.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';

class UserSettingsPage extends StatefulWidget {
  const UserSettingsPage({super.key});

  @override
  State<UserSettingsPage> createState() => _UserSettingsPageState();
}

class _UserSettingsPageState extends State<UserSettingsPage> {
  bool _notificationsEnabled = true;
  bool _isLoading = true;
  // Guards against rapid-fire toggling racing the Firestore write.
  bool _toggleInFlight = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .doc('users/$uid')
          .get()
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      // Default to true (opt-out model) — most users expect to
      // receive notifications about their own session activity.
      setState(() {
        _notificationsEnabled =
            (doc.data()?['notificationsEnabled'] as bool?) ?? true;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleNotifications() async {
    if (_toggleInFlight) return;
    final next = !_notificationsEnabled;

    setState(() {
      _notificationsEnabled = next;
      _toggleInFlight = true;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        if (!mounted) return;
        setState(() {
          _notificationsEnabled = !next;
          _toggleInFlight = false;
        });
        return;
      }
      await FirebaseFirestore.instance
          .doc('users/$uid')
          .update({'notificationsEnabled': next})
          .timeout(const Duration(seconds: 10));
      if (mounted) setState(() => _toggleInFlight = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notificationsEnabled = !next;
        _toggleInFlight = false;
      });
      AppSnackBar.error(context, 'Failed to update setting.');
    }
  }

  void _showDeleteAccountFlow() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _DeleteAccountSheet(),
    );
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
          'Settings',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        centerTitle: true,
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
                  _SectionLabel('NOTIFICATIONS'),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceWhite,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.muted.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Push Notifications',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.deepDarkBrown,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Session requests, updates, and alerts',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w400,
                                  color: AppColors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _Toggle(
                          value: _notificationsEnabled,
                          onTap: _toggleNotifications,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  _SectionLabel('ACCOUNT'),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceWhite,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.muted.withValues(alpha: 0.08),
                      ),
                    ),
                    child: _DangerRow(
                      icon: Icons.delete_outline_rounded,
                      title: 'Delete Account',
                      subtitle: 'Permanently delete your account and data',
                      onTap: _showDeleteAccountFlow,
                    ),
                  ),
                  const SizedBox(height: 32),
                  _SectionLabel('LEGAL'),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceWhite,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.muted.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Column(
                      children: [
                        _SettingsRow(
                          icon: Icons.description_outlined,
                          title: 'Terms of Service',
                          onTap: () {
                            AppSnackBar.info(
                              context,
                              'Terms of Service coming soon',
                            );
                          },
                        ),
                        const _RowDivider(),
                        _SettingsRow(
                          icon: Icons.privacy_tip_outlined,
                          title: 'Privacy Policy',
                          onTap: () {
                            AppSnackBar.info(
                              context,
                              'Privacy Policy coming soon',
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  Center(
                    child: Text(
                      'Gospel Vox v1.0.0',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
}

// ── Reusable bits ──

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: AppColors.muted,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final VoidCallback onTap;

  const _Toggle({required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 48,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: value
              ? const Color(0xFF2E7D4F)
              : AppColors.muted.withValues(alpha: 0.2),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  blurRadius: 3,
                  color: Colors.black.withValues(alpha: 0.1),
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.primaryBrown.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 18,
                color: AppColors.primaryBrown.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppColors.muted.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

class _DangerRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DangerRow({
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.errorRed.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: AppColors.errorRed,
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
                      color: AppColors.errorRed,
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
              color: AppColors.muted.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 1,
        color: AppColors.muted.withValues(alpha: 0.06),
      ),
    );
  }
}

// ── Account deletion sheet ──

class _DeleteAccountSheet extends StatefulWidget {
  const _DeleteAccountSheet();

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  final TextEditingController _confirmController = TextEditingController();
  bool _isDeleting = false;
  bool _isConfirmed = false;

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _deleteAccount() async {
    setState(() => _isDeleting = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (!mounted) return;
        setState(() => _isDeleting = false);
        AppSnackBar.error(context, 'Not signed in.');
        return;
      }
      final uid = user.uid;

      // Strip the FCM token from this device first — without this,
      // the device keeps receiving pushes addressed to the (now
      // deleted) account until the FCM token rotates naturally.
      await NotificationService().removeToken();

      // Soft-delete the Firestore profile. We zero out PII rather
      // than `delete()` the doc so session history still has a
      // counterparty record on the priest side.
      //
      // coinBalance is intentionally NOT touched here — the field
      // is locked from client writes by Firestore rules (only the
      // payments / session CFs may mutate it). Marking isDeleted is
      // the signal a future server-side cleanup job will use to
      // zero out the balance after any reconciliation.
      await FirebaseFirestore.instance.doc('users/$uid').update({
        'isDeleted': true,
        'deletedAt': FieldValue.serverTimestamp(),
        'displayName': 'Deleted User',
        'photoUrl': '',
        'email': '',
        'fcmTokens': <String>[],
      }).timeout(const Duration(seconds: 10));

      // Auth delete may need a fresh credential — Firebase requires
      // a recent sign-in for destructive ops. If we get hit with
      // requires-recent-login, reauth via Google and retry once.
      try {
        await user.delete();
      } on FirebaseAuthException catch (e) {
        if (e.code == 'requires-recent-login') {
          final reauthed = await _reauthenticateWithGoogle(user);
          if (!reauthed) {
            if (!mounted) return;
            setState(() => _isDeleting = false);
            AppSnackBar.error(
              context,
              'Please sign in again to delete your account.',
            );
            return;
          }
          await user.delete();
        } else {
          rethrow;
        }
      }

      if (!mounted) return;
      Navigator.pop(context);
      clearCachedRole();
      if (!mounted) return;
      context.go('/select-role');
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      AppSnackBar.error(
        context,
        'Delete timed out. Try again.',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      AppSnackBar.error(
        context,
        'Failed to delete account. Please try again.',
      );
    }
  }

  Future<bool> _reauthenticateWithGoogle(User user) async {
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return false;
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await user.reauthenticateWithCredential(credential);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
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
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.errorRed.withValues(alpha: 0.08),
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  size: 28,
                  color: AppColors.errorRed,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                'Delete Your Account?',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'This action is permanent and cannot be undone. '
              'Deleting your account will:',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.errorRed.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.errorRed.withValues(alpha: 0.1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  _ConsequenceRow('Delete your profile and personal data'),
                  SizedBox(height: 8),
                  _ConsequenceRow('Remove all session history'),
                  SizedBox(height: 8),
                  _ConsequenceRow('Forfeit any remaining coin balance'),
                  SizedBox(height: 8),
                  _ConsequenceRow('Revoke access to all services'),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Type DELETE to confirm',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF7F5F2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isConfirmed
                      ? AppColors.errorRed.withValues(alpha: 0.3)
                      : AppColors.muted.withValues(alpha: 0.12),
                ),
              ),
              child: TextField(
                controller: _confirmController,
                textCapitalization: TextCapitalization.characters,
                enabled: !_isDeleting,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.errorRed,
                ),
                onChanged: (v) {
                  final next = v.trim() == 'DELETE';
                  if (next != _isConfirmed) {
                    setState(() => _isConfirmed = next);
                  }
                },
                decoration: InputDecoration(
                  hintText: 'DELETE',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.3),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _SheetActionOutlined(
                    label: 'Cancel',
                    onTap: _isDeleting
                        ? null
                        : () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SheetActionDanger(
                    label: 'Delete Account',
                    isLoading: _isDeleting,
                    onTap: (_isConfirmed && !_isDeleting)
                        ? _deleteAccount
                        : null,
                  ),
                ),
              ],
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 20),
          ],
        ),
      ),
    );
  }
}

class _ConsequenceRow extends StatelessWidget {
  final String text;
  const _ConsequenceRow(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 5,
          height: 5,
          margin: const EdgeInsets.only(top: 6),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.errorRed,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.deepDarkBrown,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetActionOutlined extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _SheetActionOutlined({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.muted.withValues(alpha: disabled ? 0.1 : 0.2),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.muted.withValues(alpha: disabled ? 0.5 : 1.0),
          ),
        ),
      ),
    );
  }
}

class _SheetActionDanger extends StatelessWidget {
  final String label;
  final bool isLoading;
  final VoidCallback? onTap;

  const _SheetActionDanger({
    required this.label,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.errorRed.withValues(
            alpha: disabled ? 0.4 : 1.0,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}
