// Priest-side "My Users" list — WhatsApp-style row per user the
// priest has had at least one completed session with (plus any
// expired-only "tried to reach you" rows so a user who never
// connected still has a path back into messaging).
//
// Tapping a row opens the priest-side chat view (PriestChatPage)
// where the priest can read all past session messages with that
// user, see any free messages already sent, and type a new free
// message via the sendPriestMessage CF.
//
// The missed-request inbox lives on its own dedicated page —
// /priest/missed-requests — reachable from the dashboard amber
// banner, the foreground in-app banner, and the notifications
// inbox. My Users intentionally does NOT surface unread missed
// requests; this surface is about RELATIONSHIPS, the missed-
// requests page is about pending actions.
//
// The per-row "last message" preview is intentionally NOT live —
// that would require N parallel snapshot streams (one per row),
// which is overkill for a list surface that the priest backs
// out of as soon as they pick a user.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class PriestMyUsersPage extends StatefulWidget {
  const PriestMyUsersPage({super.key});

  @override
  State<PriestMyUsersPage> createState() => _PriestMyUsersPageState();
}

class _PriestMyUsersPageState extends State<PriestMyUsersPage> {
  bool _isLoading = true;
  List<UserSessionGroup> _groups = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _groups = const [];
      });
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    try {
      final groups = await sl<SessionHistoryRepository>()
          .getPriestUserGroups(uid);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _isLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Loading timed out. Pull down to retry.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Could not load users.');
    }
  }

  void _openUser(UserSessionGroup user) {
    context.push(
      '/priest/chat/${user.userId}',
      extra: <String, dynamic>{
        'userName': user.userName,
        'userPhotoUrl': user.userPhotoUrl,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leadingWidth: 60,
        leading: const Padding(
          padding: EdgeInsets.only(left: 16),
          child: AppBackButton(),
        ),
        title: Text(
          'My Users',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.deepDarkBrown,
          ),
        ),
      ),
      body: _isLoading ? const _UsersShimmer() : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_groups.isEmpty) {
      return RefreshIndicator(
        color: AppColors.primaryBrown,
        backgroundColor: AppColors.surfaceWhite,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 40),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.12),
            Center(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.muted.withValues(alpha: 0.06),
                ),
                child: AppIcon(
                  AppIcons.users,
                  size: 40,
                  color: AppColors.muted.withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No users yet',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.muted.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Once you complete a session with a user, they'll appear "
              'here so you can follow up.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.muted.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 100),
        itemCount: _groups.length,
        separatorBuilder: (_, _) => Padding(
          padding: const EdgeInsets.only(left: 82),
          child: Container(
            height: 0.5,
            color: AppColors.muted.withValues(alpha: 0.08),
          ),
        ),
        itemBuilder: (_, i) => _UserRow(
          user: _groups[i],
          onTap: () => _openUser(_groups[i]),
        ),
      ),
    );
  }
}

// ─── User row ─────────────────────────────────────────────────

class _UserRow extends StatefulWidget {
  final UserSessionGroup user;
  final VoidCallback onTap;

  const _UserRow({required this.user, required this.onTap});

  @override
  State<_UserRow> createState() => _UserRowState();
}

class _UserRowState extends State<_UserRow> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    // Two row variants drive every visual choice on this card:
    //   • Real customer (hasCompletedSession=true) — render
    //     "3 sessions · 12 min last" in muted color. Standard.
    //   • Tried-to-reach (no completed sessions, only expired) —
    //     render "Tried to reach you" in amber + show a small
    //     amber dot next to the avatar so the priest can spot
    //     missed-request rows at a glance in a long list.
    final isMissedOnly = !u.hasCompletedSession;
    final hasMultiple = u.totalSessions > 1;
    final subtitle = isMissedOnly
        ? 'Tried to reach you'
        : (hasMultiple
            ? '${u.totalSessions} sessions · ${u.lastSessionDuration} min last'
            : '${u.lastSessionDuration} min · last session');

    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.98),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                _Avatar(user: u, hasMissedRequest: isMissedOnly),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        u.userName.isNotEmpty ? u.userName : 'User',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: isMissedOnly
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: isMissedOnly
                              ? AppColors.amberGold
                              : AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  u.lastSessionText,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.6),
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

class _Avatar extends StatelessWidget {
  final UserSessionGroup user;
  // True when this user has only expired-request sessions with the
  // priest (no completed conversations yet). Drives a small amber
  // dot on the bottom-right of the avatar so the row is visually
  // tagged in a long list.
  final bool hasMissedRequest;

  const _Avatar({
    required this.user,
    this.hasMissedRequest = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial = user.userName.isNotEmpty
        ? user.userName[0].toUpperCase()
        : '?';

    final avatar = Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFF7F5F2),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.1),
          width: 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: user.userPhotoUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: user.userPhotoUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => _initialFallback(initial),
            )
          : _initialFallback(initial),
    );

    // Always wrap in a fixed 56-square Stack — even when the dot is
    // absent — so consecutive rows in the list have identical avatar
    // slot widths. Without this, rows with the dot shift everything
    // right by ~4px relative to dot-less rows, giving a subtle
    // alignment jitter as the priest scrolls.
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: 2, top: 2, child: avatar),
          if (hasMissedRequest)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.amberGold,
                  border: Border.all(
                    color: AppColors.background,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _initialFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

// ─── Loading shimmer ──────────────────────────────────────────

class _UsersShimmer extends StatelessWidget {
  const _UsersShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.08),
      highlightColor: AppColors.muted.withValues(alpha: 0.03),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        itemCount: 6,
        itemBuilder: (_, _) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 140,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 100,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 50,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
