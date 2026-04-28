// Priest settings hub.
//
// One canonical surface for "everything not on the dashboard": profile,
// availability, wallet/bank, notifications, support. Each tile just
// routes — no real state lives here. The Pause Requests toggle moved
// out of this page when we introduced /priest/settings/availability;
// keeping toggles in two places had caused stale-state bugs.
//
// Sign-out path is deliberately kept on the AuthRepository + the
// router's clearCachedRole() helper, NOT AuthCubit. The cache clear
// is what stops a stale role from sending the next sign-in straight
// back into the priest shell.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
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

class PriestSettingsPage extends StatefulWidget {
  const PriestSettingsPage({super.key});

  @override
  State<PriestSettingsPage> createState() => _PriestSettingsPageState();
}

class _PriestSettingsPageState extends State<PriestSettingsPage> {
  String _priestName = '';
  String _denomination = '';
  String _photoUrl = '';
  int _unreadNotifCount = 0;
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    _loadPriestInfo();
    _loadUnreadCount();
  }

  Future<void> _loadPriestInfo() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .doc('priests/$uid')
          .get()
          .timeout(const Duration(seconds: 8));
      if (!mounted || !doc.exists) return;
      final data = doc.data() ?? const <String, dynamic>{};
      setState(() {
        _priestName = data['fullName'] as String? ?? '';
        _denomination = data['denomination'] as String? ?? '';
        _photoUrl = data['photoUrl'] as String? ?? '';
      });
    } catch (_) {
      // Header gracefully degrades to initials + empty subtitle if the
      // read fails. Not surfaced — the rest of the page still works.
    }
  }

  Future<void> _loadUnreadCount() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final agg = await FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .where('isRead', isEqualTo: false)
          .count()
          .get()
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() => _unreadNotifCount = agg.count ?? 0);
    } catch (_) {
      // Silent — badge just stays at its previous value.
    }
  }

  Future<void> _openNotifications() async {
    await context.push('/priest/notifications');
    if (!mounted) return;
    // Refresh the badge when we come back — the notifications page
    // marks reads against Firestore directly, so re-aggregating is
    // the simplest way to stay in sync.
    _loadUnreadCount();
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      // Cache clear has to happen first — the router caches the role
      // for the current uid, and a lingering value would shortcut the
      // next sign-in straight back into the priest shell.
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

  Future<void> _showSignOutConfirmation() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
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
              const SizedBox(height: 20),
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.errorRed.withValues(alpha: 0.08),
                ),
                child: Icon(
                  Icons.logout_rounded,
                  size: 28,
                  color: AppColors.errorRed,
                ),
              ),
              const SizedBox(height: 18),
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
                  height: 1.5,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(sheetCtx).pop(false),
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.muted.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Text(
                          'Cancel',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.deepDarkBrown,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(sheetCtx).pop(true),
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.errorRed,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Sign Out',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true && mounted) {
      await _signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              _buildProfileCard(),
              const SizedBox(height: 28),
              const _SectionLabel('ACCOUNT'),
              const SizedBox(height: 8),
              _SettingsGroup(
                children: [
                  _SettingsTile(
                    icon: Icons.person_outline_rounded,
                    title: 'My Profile',
                    subtitle: 'Edit your profile details',
                    onTap: () => context.push('/priest/profile'),
                  ),
                  _SettingsTile(
                    icon: Icons.schedule_rounded,
                    title: 'Availability',
                    subtitle: 'Pause requests, set schedule',
                    onTap: () =>
                        context.push('/priest/settings/availability'),
                  ),
                  _SettingsTile(
                    icon: Icons.account_balance_wallet_outlined,
                    title: 'My Wallet',
                    subtitle: 'Balance, withdrawals, earnings',
                    onTap: () => context.push('/priest/wallet'),
                  ),
                  _SettingsTile(
                    icon: Icons.account_balance_outlined,
                    title: 'Bank Details',
                    subtitle: 'Manage payout account',
                    onTap: () => context.push('/priest/bank-details'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const _SectionLabel('ACTIVITY'),
              const SizedBox(height: 8),
              _SettingsGroup(
                children: [
                  _SettingsTile(
                    icon: Icons.notifications_none_rounded,
                    title: 'Notifications',
                    trailing: _unreadNotifCount > 0
                        ? _NotifBadge(count: _unreadNotifCount)
                        : null,
                    onTap: _openNotifications,
                  ),
                  _SettingsTile(
                    icon: Icons.history_rounded,
                    title: 'Session History',
                    subtitle: 'Past sessions & earnings',
                    onTap: () => AppSnackBar.info(
                      context,
                      'Session History coming soon',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const _SectionLabel('SUPPORT'),
              const SizedBox(height: 8),
              _SettingsGroup(
                children: [
                  _SettingsTile(
                    icon: Icons.help_outline_rounded,
                    title: 'Help & FAQ',
                    onTap: () =>
                        AppSnackBar.info(context, 'Help center coming soon'),
                  ),
                  _SettingsTile(
                    icon: Icons.mail_outline_rounded,
                    title: 'Contact Support',
                    subtitle: 'Get help with your account',
                    onTap: () =>
                        AppSnackBar.info(context, 'Support coming soon'),
                  ),
                  _SettingsTile(
                    icon: Icons.description_outlined,
                    title: 'Terms & Privacy Policy',
                    onTap: () => AppSnackBar.info(context, 'Coming soon'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _SettingsGroup(
                children: [
                  _SettingsTile(
                    icon: Icons.logout_rounded,
                    title: 'Sign Out',
                    titleColor: AppColors.errorRed,
                    iconColor: AppColors.errorRed,
                    showChevron: false,
                    trailing: _signingOut
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.errorRed,
                            ),
                          )
                        : null,
                    onTap:
                        _signingOut ? null : _showSignOutConfirmation,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  'Gospel Vox v1.0.0',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              'Settings',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
          if (Navigator.of(context).canPop())
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => context.pop(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceWhite,
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                      color: Colors.black.withValues(alpha: 0.04),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.arrow_back_ios_new,
                  size: 16,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: _AnimatedTap(
        onTap: () => context.push('/priest/profile'),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                blurRadius: 12,
                offset: const Offset(0, 4),
                color: Colors.black.withValues(alpha: 0.04),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFF7F5F2),
                  border: Border.all(
                    color: AppColors.amberGold.withValues(alpha: 0.3),
                    width: 2,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _photoUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: _photoUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _avatarInitial(),
                        placeholder: (_, _) => const SizedBox.shrink(),
                      )
                    : _avatarInitial(),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _priestName.isEmpty ? 'Speaker' : _priestName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _denomination.isEmpty ? '—' : _denomination,
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
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: AppColors.muted.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatarInitial() {
    final letter =
        _priestName.isNotEmpty ? _priestName[0].toUpperCase() : '?';
    return Center(
      child: Text(
        letter,
        style: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

// ─── Section label ─────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
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

// ─── Settings group container ──────────────────────

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
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
      ),
    );
  }
}

// ─── Settings tile (icon + label + chevron/trailing) ─

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color? titleColor;
  final Color? iconColor;
  final bool showChevron;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.titleColor,
    this.iconColor,
    this.showChevron = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final iconCol = iconColor ?? AppColors.primaryBrown;
    final titleCol = titleColor ?? AppColors.deepDarkBrown;

    return _AnimatedTap(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconCol.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 18,
                color: iconColor ?? iconCol.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: titleCol,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
            if (showChevron) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.muted.withValues(alpha: 0.35),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Notification unread badge ─────────────────────

class _NotifBadge extends StatelessWidget {
  final int count;
  const _NotifBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.errorRed,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        count > 99 ? '99+' : count.toString(),
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

// ─── Press-scale wrapper ───────────────────────────

class _AnimatedTap extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;

  const _AnimatedTap({required this.onTap, required this.child});

  @override
  State<_AnimatedTap> createState() => _AnimatedTapState();
}

class _AnimatedTapState extends State<_AnimatedTap> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return Listener(
      onPointerDown: (_) {
        if (!disabled) setState(() => _scale = 0.98);
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
          child: widget.child,
        ),
      ),
    );
  }
}
