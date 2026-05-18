// User-side Bible tab — replaces the placeholder at index 1 of the
// shell's IndexedStack. Owns its own BibleSessionCubit so that the
// tab's load lifecycle is bounded by the shell's lifetime; the cubit
// is closed in dispose, which kills any in-flight Future before the
// state is re-entered after sign-out.
//
// Four buckets are presented as tabs: LIVE / Upcoming / Past / All.
// The cubit loads all four in parallel on mount and on pull-to-
// refresh; tab switches are just a copyWith on the loaded state.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/bloc/bible_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/bible_session_state.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';

// Live red — distinct from errorRed so a pulsing live badge reads as
// urgency-of-attention rather than failure.
const Color _kLiveRed = Color(0xFFE53E3E);
// Forest green for "you're registered" badge — matches the user-side
// completed/paid tokens elsewhere.
const Color _kRegisteredGreen = Color(0xFF2E7D4F);
// Forest green for the "Open Meeting ✅" CTA on a live session the
// viewer has already paid for. Distinct from the amber pay-CTA so a
// returning user sees at a glance that they don't need to pay again.
const Color _kJoinedGreen = Color(0xFF2E7D4F);

class BibleTab extends StatefulWidget {
  const BibleTab({super.key});

  @override
  State<BibleTab> createState() => _BibleTabState();
}

class _BibleTabState extends State<BibleTab> {
  late final BibleSessionCubit _cubit;
  // 30-second auto-refresh while the tab is mounted. The repository
  // calls are one-shot (`.get()`, not `.snapshots()`), so without a
  // periodic kick a session that auto-completes via the cron stays
  // stale on the Live tab until the user pull-to-refreshes. 30s is
  // shorter than the cron's 5-min cadence, so the worst-case "stale
  // live card" window is bounded by 30s + the cron's own latency.
  // Cheap: each tick is 4 parallel collection reads, all small.
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _cubit = sl<BibleSessionCubit>()..loadSessions();
    // Cross-surface tab pre-selection (e.g. home page's Live pill).
    // The notifier is static on the cubit class; we attach a
    // listener and also consume any value that was already set
    // before our listener was attached (an edge case during the
    // very first BibleTab mount in the shell's IndexedStack).
    BibleSessionCubit.pendingInitialTab.addListener(_consumePendingTab);
    _consumePendingTab();

    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        // Soft-fail by design — refresh() will set its own error
        // state if the read fails, and the existing list stays
        // visible in the meantime.
        if (!mounted) return;
        _cubit.refresh();
      },
    );
  }

  void _consumePendingTab() {
    if (!mounted) return;
    final pending = BibleSessionCubit.pendingInitialTab.value;
    if (pending == null) return;
    _cubit.switchTab(pending);
    // Clear immediately so re-entry without a fresh set doesn't
    // force the tab back to the same sub-bucket.
    BibleSessionCubit.pendingInitialTab.value = null;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    BibleSessionCubit.pendingInitialTab.removeListener(_consumePendingTab);
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: BlocBuilder<BibleSessionCubit, BibleSessionState>(
          builder: (context, state) {
            return RefreshIndicator(
              color: AppColors.primaryBrown,
              backgroundColor: AppColors.surfaceWhite,
              onRefresh: () => _cubit.refresh(),
              child: _buildBody(context, state),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, BibleSessionState state) {
    if (state is BibleSessionLoading || state is BibleSessionInitial) {
      return const _LoadingBody(activeTab: 'live');
    }
    if (state is BibleSessionError) {
      return _ErrorBody(
        message: state.message,
        onRetry: _cubit.refresh,
      );
    }
    if (state is BibleSessionLoaded) {
      return _LoadedBody(
        state: state,
        onSwitchTab: _cubit.switchTab,
      );
    }
    return const SizedBox.shrink();
  }
}

// ─── Body — loaded ───────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  final BibleSessionLoaded state;
  final void Function(String tab) onSwitchTab;

  const _LoadedBody({
    required this.state,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final list = state.activeList;
    final activeTab = state.activeTab;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(child: _Header(liveCount: state.live.length)),
        SliverToBoxAdapter(
          child: _TabBar(
            activeTab: activeTab,
            liveCount: state.live.length,
            upcomingCount: state.upcoming.length,
            pastCount: state.past.length,
            allCount: state.all.length,
            onSwitchTab: onSwitchTab,
          ),
        ),
        SliverToBoxAdapter(
          child: _CountLabel(count: list.length, tab: activeTab),
        ),
        if (list.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyBibleSessions(tab: activeTab),
          )
        else
          SliverList.builder(
            itemCount: list.length,
            itemBuilder: (itemContext, i) {
              final session = list[i];
              if (session.isLive) {
                return _LiveSessionCard(
                  session: session,
                  // Paid-state branch — the cubit's loadSessions step
                  // resolves the current user's reg per live session
                  // and stamps the paid ids onto the loaded state. We
                  // pass that down here so the card can switch its CTA
                  // from "Join Now · ₹X" to "Open Meeting ✅" without
                  // burning a per-card Firestore read on build.
                  isPaid: state.paidSessionIds.contains(session.id),
                  onTap: () => _openDetail(itemContext, session.id),
                );
              }
              return _BibleSessionCard(
                session: session,
                onTap: () => _openDetail(itemContext, session.id),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  // Detail page pops `true` when the user registered, cancelled, or
  // paid — anything that changed the list data. Refresh the cubit
  // only on those returns so a back-tap with no action doesn't burn
  // four parallel reads. The captured `itemContext` belongs to the
  // builder's element, so the `mounted` check guards against the
  // user backing out of the entire tab while the detail page is up.
  Future<void> _openDetail(BuildContext itemContext, String id) async {
    final changed =
        await itemContext.push<bool>('/bible/detail/$id');
    if (!itemContext.mounted) return;
    if (changed == true) {
      await itemContext.read<BibleSessionCubit>().refresh();
    }
  }
}

// ─── Body — loading ──────────────────────────────────────────────

class _LoadingBody extends StatelessWidget {
  final String activeTab;
  const _LoadingBody({required this.activeTab});

  @override
  Widget build(BuildContext context) {
    final baseColor = AppColors.muted.withValues(alpha: 0.14);
    final highlightColor = AppColors.warmBeige;

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        const SliverToBoxAdapter(child: _Header(liveCount: 0)),
        SliverToBoxAdapter(
          child: _TabBar(
            activeTab: activeTab,
            liveCount: 0,
            upcomingCount: 0,
            pastCount: 0,
            allCount: 0,
            onSwitchTab: (_) {},
          ),
        ),
        SliverToBoxAdapter(
          child: _CountLabel(count: 0, tab: activeTab),
        ),
        SliverList.builder(
          itemCount: 4,
          itemBuilder: (_, _) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Shimmer.fromColors(
              baseColor: baseColor,
              highlightColor: highlightColor,
              child: Container(
                height: 150,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

// ─── Body — error ────────────────────────────────────────────────

class _ErrorBody extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBody({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 44,
          color: AppColors.errorRed,
        ),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: AppColors.primaryBrown,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Retry',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final int liveCount;
  const _Header({required this.liveCount});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "Bible Sessions",
              style: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.deepDarkBrown,
                letterSpacing: -0.3,
              ),
            ),
            // Show a small "N live now" hint in the corner when any
            // session is live, regardless of which tab the user is on.
            // Pulls them toward the live tab without making it feel
            // like a notification badge.
            if (liveCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _kLiveRed.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _PulsingDot(size: 6, color: _kLiveRed),
                    const SizedBox(width: 6),
                    Text(
                      "$liveCount live",
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _kLiveRed,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Tab bar (LIVE / Upcoming / Past / All) ─────────────────────

class _TabBar extends StatelessWidget {
  final String activeTab;
  // Per-bucket counts. Each one is appended to its label as " (N)"
  // when > 0; zero is hidden so a quiet bible app doesn't read as
  // "Live (0) · Upcoming (0)" etc.
  final int liveCount;
  final int upcomingCount;
  final int pastCount;
  final int allCount;
  final void Function(String tab) onSwitchTab;

  const _TabBar({
    required this.activeTab,
    required this.liveCount,
    required this.upcomingCount,
    required this.pastCount,
    required this.allCount,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F5F2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            _TabButton(
              label: "Live",
              count: liveCount,
              isActive: activeTab == 'live',
              live: true,
              // Show a tiny pulsing dot next to the label when there
              // ARE live sessions — so even the inactive tab signals
              // "something's happening".
              showLiveDot: liveCount > 0,
              onTap: () => onSwitchTab('live'),
            ),
            _TabButton(
              label: "Upcoming",
              count: upcomingCount,
              isActive: activeTab == 'upcoming',
              onTap: () => onSwitchTab('upcoming'),
            ),
            _TabButton(
              label: "Past",
              count: pastCount,
              isActive: activeTab == 'past',
              onTap: () => onSwitchTab('past'),
            ),
            _TabButton(
              label: "All",
              count: allCount,
              isActive: activeTab == 'all',
              onTap: () => onSwitchTab('all'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  // Appended as " (N)" when > 0. 0 hides the suffix — a "Live (0)"
  // label reads as broken state, not informational.
  final int count;
  final bool isActive;
  // ignore: unused_element_parameter
  final bool live;
  // ignore: unused_element_parameter
  final bool showLiveDot;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.count,
    required this.isActive,
    required this.onTap,
    this.live = false,
    this.showLiveDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor =
        live ? _kLiveRed : AppColors.deepDarkBrown;
    final displayLabel = count > 0 ? '$label ($count)' : label;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : const [],
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showLiveDot) ...[
                  const _PulsingDot(size: 5, color: _kLiveRed),
                  const SizedBox(width: 5),
                ],
                Text(
                  displayLabel,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight:
                        isActive ? FontWeight.w700 : FontWeight.w500,
                    color: isActive ? activeColor : AppColors.muted,
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

// ─── Count label ─────────────────────────────────────────────────

class _CountLabel extends StatelessWidget {
  final int count;
  final String tab;

  const _CountLabel({required this.count, required this.tab});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            "$count ${tab.toUpperCase()}",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
              letterSpacing: 0.8,
            ),
          ),
          Text(
            "Tap card to view details",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ─────────────────────────────────────────────────

class _EmptyBibleSessions extends StatelessWidget {
  final String tab;
  const _EmptyBibleSessions({required this.tab});

  String get _title {
    switch (tab) {
      case 'live':
        return 'No live sessions right now';
      case 'upcoming':
        return 'No upcoming sessions';
      case 'past':
        return 'No past sessions yet';
      case 'all':
      default:
        return 'No Bible sessions yet';
    }
  }

  String get _subtitle {
    switch (tab) {
      case 'live':
        return "When a speaker starts a session,\nit'll appear here.";
      case 'upcoming':
        return 'Check back soon — speakers add new\nsessions every week.';
      case 'past':
        return "You'll see completed sessions here\nonce some have wrapped up.";
      case 'all':
      default:
        return "When speakers schedule sessions,\nyou'll find them all here.";
    }
  }

  IconData get _icon =>
      tab == 'live' ? Icons.podcasts_rounded : Icons.menu_book_outlined;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _icon,
              size: 56,
              color: AppColors.muted.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 16),
            Text(
              _title,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Live session card (special) ────────────────────────────────

class _LiveSessionCard extends StatefulWidget {
  final BibleSessionModel session;
  // True when the cubit's per-user reg lookup found status=='paid'
  // for this session. Flips the CTA from "Join Now · ₹X" (amber) to
  // "Open Meeting ✅" (green) so a returning paid user sees at a
  // glance that they don't need to pay again. Tap routes to the
  // detail page either way; the detail page renders STATE D (link
  // revealed) for paid users and STATE C (payment gate) otherwise.
  final bool isPaid;
  final VoidCallback onTap;

  const _LiveSessionCard({
    required this.session,
    required this.isPaid,
    required this.onTap,
  });

  @override
  State<_LiveSessionCard> createState() => _LiveSessionCardState();
}

class _LiveSessionCardState extends State<_LiveSessionCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final isPaid = widget.isPaid;

    final ctaColor = isPaid ? _kJoinedGreen : AppColors.amberGold;
    final ctaLabel = isPaid
        ? "Open Meeting ✅"
        : "Join Now · ₹${session.price}";

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.98),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _kLiveRed.withValues(alpha: 0.35),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: _kLiveRed.withValues(alpha: 0.08),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _kLiveRed.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _PulsingDot(size: 6, color: _kLiveRed),
                        const SizedBox(width: 5),
                        Text(
                          "LIVE",
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: _kLiveRed,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    session.remainingTimeText,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _kLiveRed,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                session.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              if (session.priestName.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  "by ${session.priestName}",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _PressableButton(
                onTap: widget.onTap,
                child: Container(
                  width: double.infinity,
                  height: 44,
                  decoration: BoxDecoration(
                    color: ctaColor,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: ctaColor.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      ctaLabel,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Standard session card (upcoming / past / all) ──────────────

class _BibleSessionCard extends StatefulWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;

  const _BibleSessionCard({
    required this.session,
    required this.onTap,
  });

  @override
  State<_BibleSessionCard> createState() => _BibleSessionCardState();
}

class _BibleSessionCardState extends State<_BibleSessionCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.98),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.08),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (session.category.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.amberGold
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        session.category,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppColors.amberGold
                              .withValues(alpha: 0.95),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  const Spacer(),
                  _StatusPill(session: session),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                session.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              if (session.priestName.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  "by ${session.priestName}",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  if (session.scheduledAt != null)
                    _MetaChip(
                      icon: Icons.event_outlined,
                      text:
                          "${_formatShortDate(session.scheduledAt!)} · "
                          "${session.formattedTime} IST",
                    ),
                  _MetaChip(
                    icon: Icons.timer_outlined,
                    text: session.formattedDuration,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    "₹${session.price}",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.amberGold,
                    ),
                  ),
                  const Spacer(),
                  if (session.isUpcoming)
                    Text(
                      session.startsInText,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.muted,
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

class _StatusPill extends StatelessWidget {
  final BibleSessionModel session;
  const _StatusPill({required this.session});

  @override
  Widget build(BuildContext context) {
    if (session.isCompleted) {
      return _Pill(
        bg: _kRegisteredGreen.withValues(alpha: 0.1),
        child: Text(
          "Completed",
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: _kRegisteredGreen,
            letterSpacing: 0.3,
          ),
        ),
      );
    }
    if (session.isCancelled) {
      return _Pill(
        bg: AppColors.muted.withValues(alpha: 0.12),
        child: Text(
          "Cancelled",
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
            letterSpacing: 0.3,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _Pill extends StatelessWidget {
  final Color bg;
  final Widget child;
  const _Pill({required this.bg, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 13,
          color: AppColors.muted.withValues(alpha: 0.5),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}

// ─── Pulsing dot ────────────────────────────────────────────────

class _PulsingDot extends StatefulWidget {
  final double size;
  final Color color;
  const _PulsingDot({this.size = 8, this.color = _kLiveRed});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.85, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacity = Tween<double>(begin: 1.0, end: 0.35).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        return SizedBox(
          width: widget.size * 1.6,
          height: widget.size * 1.6,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: _opacity.value * 0.4,
                child: Transform.scale(
                  scale: _scale.value,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color,
                    ),
                  ),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Pressable button (used by live card CTA) ───────────────────

class _PressableButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _PressableButton({required this.child, required this.onTap});

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return GestureDetector(
      onTapDown: disabled ? null : (_) => setState(() => _scale = 0.96),
      onTapUp: disabled ? null : (_) => setState(() => _scale = 1.0),
      onTapCancel: disabled ? null : () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

// ─── Date formatter ─────────────────────────────────────────────

String _formatShortDate(DateTime d) {
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month]} ${d.day}';
}
