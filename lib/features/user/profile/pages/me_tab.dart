// User-side "Me" tab — profile header + menu list + sign-out.
//
// Reads displayName / email / photoUrl from users/{uid} (preferred)
// and falls back to FirebaseAuth.currentUser if Firestore is slow or
// unreachable. The auth profile is updated alongside Firestore in
// EditProfilePage._save, so the two are usually in sync, but we
// trust Firestore as the source of truth because that's what the
// rest of the app reads.
//
// Why not InkWell anywhere: the user side runs a warm beige palette
// and Material's default ripple looks washed-out and out-of-place
// against the cream surfaces. We use AnimatedScale on tap to give
// the tile press feedback without a ripple.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';
import 'package:gospel_vox/features/user/home/pages/user_shell_page.dart';

class MeTab extends StatefulWidget {
  const MeTab({super.key});

  @override
  State<MeTab> createState() => _MeTabState();
}

class _MeTabState extends State<MeTab> {
  String _displayName = '';
  String _email = '';
  String _photoUrl = '';
  bool _isLoading = true;
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
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
      setState(() {
        _displayName =
            (data?['displayName'] as String?) ?? user.displayName ?? '';
        _email = (data?['email'] as String?) ?? user.email ?? '';
        _photoUrl =
            (data?['photoUrl'] as String?) ?? user.photoURL ?? '';
        _isLoading = false;
      });
    } catch (_) {
      // Network failure / timeout — fall back to auth profile so
      // the tab still shows something useful instead of a hang.
      if (!mounted) return;
      setState(() {
        _displayName = user.displayName ?? '';
        _email = user.email ?? '';
        _photoUrl = user.photoURL ?? '';
        _isLoading = false;
      });
    }
  }

  Future<void> _navigateToEditProfile() async {
    await context.push('/user/edit-profile');
    // Reload after returning from edit so the header reflects any
    // saved changes (display name and/or photo). EditProfilePage
    // calls context.pop() on a successful save.
    if (mounted) _loadProfile();
  }

  void _switchToWalletTab() {
    final shell = UserShellScope.of(context);
    if (shell != null) {
      shell.switchToTab(2);
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);

    try {
      // Cached role must be cleared BEFORE auth.signOut — the
      // router's redirect fires the instant the auth state changes,
      // and a stale cache would route the next role selection back
      // to the previous role's shell.
      clearCachedRole();
      await sl<AuthRepository>().signOut();
      if (!mounted) return;
      context.go('/select-role');
    } catch (_) {
      if (!mounted) return;
      setState(() => _signingOut = false);
      AppSnackBar.error(context, 'Failed to sign out. Try again.');
    }
  }

  void _showSignOutConfirmation() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _SignOutSheet(
        onConfirm: () {
          Navigator.pop(sheetCtx);
          _signOut();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                      child: _ProfileHeader(
                        displayName: _displayName,
                        email: _email,
                        photoUrl: _photoUrl,
                        onEdit: _navigateToEditProfile,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceWhite,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppColors.muted.withValues(alpha: 0.08),
                        ),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 8,
                            color: Colors.black.withValues(alpha: 0.03),
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          _MenuItem(
                            icon: Icons.history_rounded,
                            title: 'Session History',
                            subtitle: 'View past consultations',
                            onTap: () =>
                                context.push('/user/session-history'),
                          ),
                          const _MenuDivider(),
                          _MenuItem(
                            icon: Icons.account_balance_wallet_outlined,
                            title: 'Transaction History',
                            subtitle: 'Coin purchases and charges',
                            onTap: _switchToWalletTab,
                          ),
                          const _MenuDivider(),
                          _MenuItem(
                            icon: Icons.settings_outlined,
                            title: 'Settings',
                            subtitle: 'Notifications, account, privacy',
                            onTap: () => context.push('/user/settings'),
                          ),
                          const _MenuDivider(),
                          _MenuItem(
                            icon: Icons.help_outline_rounded,
                            title: 'Help & Support',
                            subtitle: 'FAQs and contact us',
                            onTap: () {
                              AppSnackBar.info(
                                context,
                                'Help center coming soon',
                              );
                            },
                          ),
                          const _MenuDivider(),
                          _MenuItem(
                            icon: Icons.info_outline_rounded,
                            title: 'About Gospel Vox',
                            subtitle: 'Version, terms, privacy policy',
                            onTap: () => context.push('/user/about'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _SignOutTile(
                      signingOut: _signingOut,
                      onTap: _showSignOutConfirmation,
                    ),
                  ),
                  const SizedBox(height: 100),
                ],
              ),
            ),
    );
  }
}

// ── Header ──

class _ProfileHeader extends StatelessWidget {
  final String displayName;
  final String email;
  final String photoUrl;
  final VoidCallback onEdit;

  const _ProfileHeader({
    required this.displayName,
    required this.email,
    required this.photoUrl,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.isNotEmpty
        ? displayName[0].toUpperCase()
        : '?';
    final shownName = displayName.isNotEmpty ? displayName : 'User';

    return Row(
      children: [
        _PressableScale(
          onTap: onEdit,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF7F5F2),
              border: Border.all(
                color: AppColors.amberGold.withValues(alpha: 0.3),
                width: 2.5,
              ),
              boxShadow: [
                BoxShadow(
                  blurRadius: 12,
                  color: Colors.black.withValues(alpha: 0.06),
                  offset: const Offset(0, 4),
                ),
              ],
              image: photoUrl.isNotEmpty
                  ? DecorationImage(
                      image: NetworkImage(photoUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: photoUrl.isEmpty
                ? Center(
                    child: Text(
                      initial,
                      style: GoogleFonts.inter(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppColors.muted,
                      ),
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                shownName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _PressableScale(
          onTap: onEdit,
          scale: 0.95,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceWhite,
              boxShadow: [
                BoxShadow(
                  blurRadius: 6,
                  color: Colors.black.withValues(alpha: 0.04),
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(
              Icons.edit_outlined,
              size: 16,
              color: AppColors.primaryBrown,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Menu item ──

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      scale: 0.98,
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

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

// ── Sign-out tile + confirmation sheet ──

class _SignOutTile extends StatelessWidget {
  final bool signingOut;
  final VoidCallback onTap;

  const _SignOutTile({
    required this.signingOut,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: signingOut ? null : onTap,
      scale: 0.97,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.errorRed.withValues(alpha: 0.12),
          ),
        ),
        child: signingOut
            ? const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.errorRed,
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.logout_rounded,
                    size: 18,
                    color: AppColors.errorRed.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Sign Out',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.errorRed.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _SignOutSheet extends StatelessWidget {
  final VoidCallback onConfirm;

  const _SignOutSheet({required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
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
                    color: AppColors.errorRed.withValues(alpha: 0.06),
                  ),
                  child: Icon(
                    Icons.logout_rounded,
                    size: 28,
                    color: AppColors.errorRed.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Sign Out?',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "You'll need to sign in again to access your account.",
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _OutlinedAction(
                      label: 'Cancel',
                      onTap: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _FilledDangerAction(
                      label: 'Sign Out',
                      onTap: onConfirm,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlinedAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _OutlinedAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.muted.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _FilledDangerAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _FilledDangerAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.errorRed,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
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

// Tap-scale wrapper used everywhere on the user side instead of
// InkWell. Keeps the warm palette free of Material's grey ripple.
class _PressableScale extends StatefulWidget {
  final VoidCallback? onTap;
  final double scale;
  final Widget child;

  const _PressableScale({
    required this.onTap,
    required this.child,
    this.scale = 0.97,
  });

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  double _scale = 1.0;

  void _press(bool down) {
    if (widget.onTap == null) return;
    setState(() => _scale = down ? widget.scale : 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _press(true),
      onPointerUp: (_) => _press(false),
      onPointerCancel: (_) => _press(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}
