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
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

// Public legal + support endpoints. Hosted pages may not exist yet
// at the time of writing; the URL is what we ship to users / the
// app store and what we'll keep stable across releases. Updating
// the page content is a separate concern from the app build.
const String _kPrivacyPolicyUrl = 'https://gospelvox.com/privacy-policy';
const String _kHelpCenterUrl = 'https://gospelvox.com/help';
const String _kSupportEmail = 'support@gospelvox.com';

class PriestSettingsPage extends StatefulWidget {
  const PriestSettingsPage({super.key});

  @override
  State<PriestSettingsPage> createState() => _PriestSettingsPageState();
}

class _PriestSettingsPageState extends State<PriestSettingsPage> {
  String _priestName = '';
  String _denomination = '';
  String _photoUrl = '';
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    _loadPriestInfo();
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

  Future<void> _openNotifications() async {
    await context.push('/priest/notifications');
    // No manual refresh needed — the badge listens to a live stream
    // and updates the moment the notifications page marks reads.
  }

  // Opens an external URL in the system browser. Surfaces a snackbar
  // on launch failure (e.g. no browser, malformed URL) so a tap that
  // does nothing visible at least explains itself.
  Future<void> _launchExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't open the link.");
      return;
    }
    try {
      final ok =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        AppSnackBar.error(context, "Couldn't open the link.");
      }
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't open the link.");
    }
  }

  // Opens the device's default mail composer to support@gospelvox.com.
  // Falls back to a snackbar when no mail app is registered (some
  // tablets / emulator builds).
  Future<void> _openSupportEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: _kSupportEmail,
      queryParameters: <String, String>{
        'subject': 'Gospel Vox Support Request',
      },
    );
    try {
      final ok = await launchUrl(uri);
      if (!ok && mounted) {
        AppSnackBar.error(context, 'No email app available on this device.');
      }
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'No email app available on this device.');
    }
  }

  // Opens the irreversible delete-account confirmation sheet. The sheet
  // owns its own state (confirm-text input, in-flight flag) so the
  // settings page can stay mostly stateless about deletion.
  Future<void> _showDeleteAccountSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PriestDeleteAccountSheet(),
    );
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
                child: AppIcon(
                  AppIcons.logout,
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
                    icon: AppIcons.userOutline,
                    title: 'My Profile',
                    subtitle: 'Edit your profile details',
                    onTap: () => context.push('/priest/profile'),
                  ),
                  _SettingsTile(
                    icon: AppIcons.clock,
                    title: 'Availability',
                    subtitle: 'Pause requests, set schedule',
                    onTap: () =>
                        context.push('/priest/settings/availability'),
                  ),
                  _SettingsTile(
                    icon: AppIcons.wallet,
                    title: 'My Wallet',
                    subtitle: 'Balance, withdrawals, earnings',
                    onTap: () => context.push('/priest/wallet'),
                  ),
                  _SettingsTile(
                    icon: AppIcons.bank,
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
                  _UnreadNotificationsTile(
                    onTap: _openNotifications,
                  ),
                  _SettingsTile(
                    icon: AppIcons.history,
                    title: 'Session History',
                    subtitle: 'Past sessions & earnings',
                    onTap: () => context.push('/priest/session-history'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const _SectionLabel('SUPPORT'),
              const SizedBox(height: 8),
              _SettingsGroup(
                children: [
                  _SettingsTile(
                    icon: AppIcons.help,
                    title: 'Help & FAQ',
                    onTap: () => _launchExternalUrl(_kHelpCenterUrl),
                  ),
                  _SettingsTile(
                    icon: AppIcons.mail,
                    title: 'Contact Support',
                    subtitle: 'Get help with your account',
                    onTap: _openSupportEmail,
                  ),
                  _SettingsTile(
                    icon: AppIcons.document,
                    title: 'Terms & Privacy Policy',
                    onTap: () => _launchExternalUrl(_kPrivacyPolicyUrl),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _SettingsGroup(
                children: [
                  _SettingsTile(
                    icon: AppIcons.logout,
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
              // Account deletion sits in its own group below sign-out
              // with the same destructive red palette. Required by
              // Play Store / App Store policy — every account system
              // must offer an in-app delete path.
              const SizedBox(height: 12),
              _SettingsGroup(
                children: [
                  _SettingsTile(
                    icon: AppIcons.delete,
                    title: 'Delete Account',
                    subtitle: 'Permanently remove your account & data',
                    titleColor: AppColors.errorRed,
                    iconColor: AppColors.errorRed,
                    onTap: _showDeleteAccountSheet,
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
          if (Navigator.of(context).canPop()) const AppBackButton(),
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
              AppIcon(
                AppIcons.chevronRight,
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
              child: AppIcon(
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
              AppIcon(
                AppIcons.chevronRight,
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

// ─── Notification tile (live unread count) ─────────
//
// Streams notifications/{userId,isRead==false} so the badge reflects
// reality in real time. Older revision used a one-shot `.count()`
// aggregation, which stayed stale until the priest re-opened the
// settings page — a freshly-cleared inbox kept showing the previous
// count, and a freshly-arrived notification didn't bump the badge.
// The dashboard's bell already uses this exact stream pattern; this
// tile mirrors it so both surfaces never disagree.
class _UnreadNotificationsTile extends StatelessWidget {
  final VoidCallback onTap;
  const _UnreadNotificationsTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return _SettingsTile(
        icon: AppIcons.bellOutline,
        title: 'Notifications',
        onTap: onTap,
      );
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? 0;
        return _SettingsTile(
          icon: AppIcons.bellOutline,
          title: 'Notifications',
          trailing: count > 0 ? _NotifBadge(count: count) : null,
          onTap: onTap,
        );
      },
    );
  }
}

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

// ─── Delete Account sheet ────────────────────────────
//
// Mirrors the user-side _DeleteAccountSheet pattern, but writes to
// BOTH users/{uid} and priests/{uid}: a priest is also a user, and
// leaving the priest doc untouched would orphan it (still showing
// in the speaker feed under their old display name).
//
// Soft delete strategy:
//   • users/{uid}.isDeleted = true, PII zeroed, fcmTokens cleared
//   • priests/{uid}.isDeleted = true, identity fields zeroed,
//     isOnline=false / isBusy=false (so the watchdog + user-feed
//     stop surfacing them immediately)
//   • Auth account deleted via FirebaseAuth.user.delete()
//
// We deliberately do NOT touch priests/{uid}.walletBalance or
// users/{uid}.coinBalance — both are locked from client writes by
// Firestore rules. Reconciliation (refund pending balances, void
// outstanding withdrawals) is a server-side cleanup job triggered
// by the isDeleted flag — out of scope for this client-side flow.
class _PriestDeleteAccountSheet extends StatefulWidget {
  const _PriestDeleteAccountSheet();

  @override
  State<_PriestDeleteAccountSheet> createState() =>
      _PriestDeleteAccountSheetState();
}

class _PriestDeleteAccountSheetState
    extends State<_PriestDeleteAccountSheet> {
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

      // Best-effort token strip — without this the device keeps
      // receiving pushes addressed to the (now deleted) account
      // until the FCM token rotates naturally.
      await NotificationService().removeToken();
      if (!mounted) return;

      // Soft-delete the user doc first. coinBalance / role /
      // walletBalance / isActivated are blocked by rules — we leave
      // them alone and let a server-side reconciliation job zero
      // them once any outstanding balance is settled.
      await FirebaseFirestore.instance.doc('users/$uid').update({
        'isDeleted': true,
        'deletedAt': FieldValue.serverTimestamp(),
        'displayName': 'Deleted Speaker',
        'photoUrl': '',
        'email': '',
        'fcmTokens': <String>[],
      }).timeout(const Duration(seconds: 10));
      if (!mounted) return;

      // Soft-delete the priest doc. isOnline=false + isBusy=false
      // makes the speaker disappear from the user feed immediately
      // — same effect as a manual go-offline + watchdog pass would
      // produce, but synchronous so there's no window during which
      // a user could still try to dial them.
      try {
        await FirebaseFirestore.instance.doc('priests/$uid').update({
          'isDeleted': true,
          'deletedAt': FieldValue.serverTimestamp(),
          'fullName': 'Deleted Speaker',
          'photoUrl': '',
          'email': '',
          'phone': '',
          'isOnline': false,
          'isBusy': false,
        }).timeout(const Duration(seconds: 10));
      } catch (_) {
        // Priest doc write is best-effort. The user-doc isDeleted
        // flag above is the canonical signal — server-side cleanup
        // will reconcile the priest doc from there. Don't block
        // the auth.delete on a transient priest-doc write failure.
      }
      if (!mounted) return;

      // Auth delete may need a fresh credential — Firebase requires
      // a recent sign-in for destructive operations. If we hit
      // requires-recent-login, reauth via Google and retry once.
      try {
        await user.delete();
      } on FirebaseAuthException catch (e) {
        if (e.code == 'requires-recent-login') {
          final reauthed = await _reauthenticateWithGoogle(user);
          if (!mounted) return;
          if (!reauthed) {
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
      AppSnackBar.error(context, 'Delete timed out. Try again.');
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
                child: const AppIcon(
                  AppIcons.warning,
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
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ConsequenceRow('Remove your speaker profile from the feed'),
                  SizedBox(height: 8),
                  _ConsequenceRow('Delete your personal data'),
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
