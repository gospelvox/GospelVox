// User-side Sessions tab — WhatsApp-style list of priests this user
// has previously had completed sessions with.
//
// One row per priest (not per session). Two sub-tabs split the same
// underlying list by session type:
//   • Chats — priests with at least one completed chat
//   • Calls — priests with at least one completed voice call
// A priest who has both naturally appears in both tabs.
//
// Tapping a row opens that priest's public profile (/user/priest/:id)
// where the user can start a new PAID chat or voice session via the
// existing flow. There is no in-app messaging here — this tab is a
// re-engagement surface, not a chat inbox.
//
// Data is fetched once on mount via the repository and refreshed
// only on pull-to-refresh. Live priest status (online/busy) is
// captured at fetch time; that's "good enough" for a list view, and
// a stream per priest would be an order of magnitude more expensive
// for what is, ultimately, a recap surface.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';
import 'package:gospel_vox/features/user/home/pages/user_shell_page.dart';

const Color _kOnlineGreen = Color(0xFF059669);

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  // 0 = Chats, 1 = Calls. Local toggle — no need to persist across
  // tab switches since the user is back on Home most of the time.
  int _activeTab = 0;
  bool _isLoading = true;
  List<PriestSessionGroup> _allGroups = const [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _allGroups = const [];
      });
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    try {
      final groups = await sl<SessionHistoryRepository>()
          .getUserPriestThreads(uid);
      if (!mounted) return;
      setState(() {
        _allGroups = groups;
        _isLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Loading timed out. Pull down to retry.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Could not load sessions.');
    }
  }

  // Filter the cached groups by the active sub-tab. Same priest can
  // satisfy both filters when they have both a chat and a voice
  // session in their history — we don't dedupe across tabs.
  List<PriestSessionGroup> get _displayList {
    if (_activeTab == 0) {
      return _allGroups.where((g) => g.chatSessions > 0).toList();
    }
    return _allGroups.where((g) => g.voiceSessions > 0).toList();
  }

  // Tap dispatch differs by sub-tab:
  //   • Chats → ChatHistoryPage (read-only past messages from the
  //     last 14 days, with a sticky "Start New Session" button at
  //     the bottom that hands off to the priest profile).
  //   • Calls → straight to the priest profile. Voice calls have no
  //     text history to display, so a middle page would be empty
  //     filler.
  void _openPriestRow(PriestSessionGroup priest) {
    if (_activeTab == 0) {
      context.push(
        '/user/chat-history/${priest.priestId}',
        extra: <String, dynamic>{
          'priestName': priest.priestName,
          'priestPhotoUrl': priest.priestPhotoUrl,
        },
      );
    } else {
      context.push('/user/priest/${priest.priestId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sessions',
                      style: GoogleFonts.inter(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F5F2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _TabButton(
                      label: 'Chats',
                      isActive: _activeTab == 0,
                      onTap: () => setState(() => _activeTab = 0),
                    ),
                  ),
                  Expanded(
                    child: _TabButton(
                      label: 'Calls',
                      isActive: _activeTab == 1,
                      onTap: () => setState(() => _activeTab = 1),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const _SessionsShimmer();

    final list = _displayList;
    if (list.isEmpty) {
      return RefreshIndicator(
        color: AppColors.primaryBrown,
        backgroundColor: AppColors.surfaceWhite,
        onRefresh: _loadSessions,
        child: _EmptyState(isChats: _activeTab == 0),
      );
    }

    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: _loadSessions,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 100),
        itemCount: list.length,
        separatorBuilder: (_, _) => Padding(
          padding: const EdgeInsets.only(left: 82),
          child: Container(
            height: 0.5,
            color: AppColors.muted.withValues(alpha: 0.08),
          ),
        ),
        itemBuilder: (_, i) => _PriestSessionCard(
          priest: list[i],
          onTap: () => _openPriestRow(list[i]),
        ),
      ),
    );
  }
}

// ─── Sub-tab button (Chats / Calls) ────────────────────────

class _TabButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: isActive ? AppColors.surfaceWhite : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                    color: Colors.black.withValues(alpha: 0.04),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            color: isActive ? AppColors.deepDarkBrown : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

// ─── Priest row — WhatsApp-style ───────────────────────────

class _PriestSessionCard extends StatefulWidget {
  final PriestSessionGroup priest;
  final VoidCallback onTap;

  const _PriestSessionCard({
    required this.priest,
    required this.onTap,
  });

  @override
  State<_PriestSessionCard> createState() => _PriestSessionCardState();
}

class _PriestSessionCardState extends State<_PriestSessionCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final p = widget.priest;
    final hasDenom = p.priestDenomination.isNotEmpty;
    final hasMultiple = p.totalSessions > 1;

    // Subtitle is "Denomination · 3 sessions" when both fields are
    // present, "Denomination" alone, "3 sessions" alone, or empty.
    String subtitle;
    if (hasDenom && hasMultiple) {
      subtitle = '${p.priestDenomination} · ${p.totalSessions} sessions';
    } else if (hasDenom) {
      subtitle = p.priestDenomination;
    } else if (hasMultiple) {
      subtitle = '${p.totalSessions} sessions';
    } else {
      subtitle = '';
    }

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
                _Avatar(priest: p),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        p.priestName.isNotEmpty
                            ? p.priestName
                            : 'Speaker',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
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
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      p.lastSessionText,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted.withValues(alpha: 0.6),
                      ),
                    ),
                    if (p.isAvailable) ...[
                      const SizedBox(height: 6),
                      _StatusPill(
                        label: 'Online',
                        color: _kOnlineGreen,
                      ),
                    ] else if (p.isBusy) ...[
                      const SizedBox(height: 6),
                      _StatusPill(
                        label: 'Busy',
                        color: AppColors.amberGold,
                      ),
                    ],
                    // Offline → no badge, mirroring WhatsApp's clean
                    // chat-list density.
                  ],
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
  final PriestSessionGroup priest;
  const _Avatar({required this.priest});

  @override
  Widget build(BuildContext context) {
    final initial = priest.priestName.isNotEmpty
        ? priest.priestName[0].toUpperCase()
        : '?';

    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
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
            child: priest.priestPhotoUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: priest.priestPhotoUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => const SizedBox.shrink(),
                    errorWidget: (_, _, _) => _initialFallback(initial),
                  )
                : _initialFallback(initial),
          ),
          Positioned(
            bottom: 1,
            right: 1,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: priest.isAvailable
                    ? _kOnlineGreen
                    : (priest.isBusy
                        ? AppColors.amberGold
                        : AppColors.muted.withValues(alpha: 0.4)),
                border: Border.all(
                  color: AppColors.background,
                  width: 2.5,
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

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ─── Empty state ───────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final bool isChats;
  const _EmptyState({required this.isChats});

  @override
  Widget build(BuildContext context) {
    // ListView (not Center) so RefreshIndicator's drag works on an
    // otherwise empty surface. Spacer pushes the content into the
    // viewport center without losing scrollability.
    return ListView(
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
            child: Icon(
              isChats
                  ? Icons.chat_bubble_outline_rounded
                  : Icons.phone_outlined,
              size: 40,
              color: AppColors.muted.withValues(alpha: 0.3),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          isChats ? 'No chats yet' : 'No calls yet',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.muted.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          isChats
              ? 'Start a chat with a speaker from the\nHome tab to see them here'
              : 'Make a voice call with a speaker from\nthe Home tab to see them here',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            height: 1.5,
            color: AppColors.muted.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(height: 24),
        Center(child: _FindSpeakersButton()),
      ],
    );
  }
}

class _FindSpeakersButton extends StatefulWidget {
  @override
  State<_FindSpeakersButton> createState() => _FindSpeakersButtonState();
}

class _FindSpeakersButtonState extends State<_FindSpeakersButton> {
  double _scale = 1.0;

  void _onTap() {
    UserShellScope.of(context)?.switchToTab(0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.primaryBrown.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              'Find Speakers',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryBrown,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Loading shimmer ───────────────────────────────────────

class _SessionsShimmer extends StatelessWidget {
  const _SessionsShimmer();

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
