// User-side Bible tab — replaces the placeholder at index 1 of the
// shell's IndexedStack. Owns its own BibleSessionCubit so that the
// tab's load lifecycle is bounded by the shell's lifetime; the cubit
// is closed in dispose, which kills any in-flight Future before the
// state is re-entered after sign-out.
//
// Three buckets are presented as tabs: LIVE / Upcoming / Past. The
// cubit loads all three in parallel on mount; tab switches are just
// a copyWith on the loaded state. Refreshes happen on three triggers
// only — pull-to-refresh, detail-page return, app-resume — all
// routed through the cubit's SILENT path so no shimmer flash.

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
import 'package:gospel_vox/core/widgets/app_icons.dart';

// Live red — distinct from errorRed so a pulsing live badge reads as
// urgency-of-attention rather than failure.
const Color _kLiveRed = Color(0xFFE53E3E);
// Forest green for the "Open Meeting ✅" CTA on a live session the
// viewer has already paid for. Distinct from the amber pay-CTA so a
// returning user sees at a glance that they don't need to pay again.
const Color _kJoinedGreen = Color(0xFF2E7D4F);

// "Starting in" badge palette. Two-stage urgency:
//   • imminent (< 2h)  → soft mint background with deeper green text
//   • later (≥ 2h)     → soft peach background with terracotta text
// Matches the reference's green/peach split on the upcoming list.
const Color _kSoonBg = Color(0xFFE6F4EC);
const Color _kSoonText = Color(0xFF2E8B57);
const Color _kLaterBg = Color(0xFFFCE3D7);
const Color _kLaterText = Color(0xFFC4502A);
// "Awaiting host" — scheduled time has passed but the priest hasn't
// tapped "Start Meeting" yet. Soft warm amber so the badge reads as
// "in progress, please wait" rather than "starting" (green, wrong)
// or "ended" (grey, also wrong). Distinct from the live-red.
const Color _kAwaitBg = Color(0xFFFEF1DC);
const Color _kAwaitText = Color(0xFFB87333);

class BibleTab extends StatefulWidget {
  const BibleTab({super.key});

  @override
  State<BibleTab> createState() => _BibleTabState();
}

class _BibleTabState extends State<BibleTab> with WidgetsBindingObserver {
  late final BibleSessionCubit _cubit;

  // Pure-rebuild tick. Doesn't fetch anything — just calls setState
  // so the build path re-evaluates time-based getters
  // (isEffectivelyLive / isPastDeadline) and re-bucketed lists
  // (live → past on deadline crossing). Without this a user sitting
  // on the tab when a session crosses its deadline would keep
  // seeing it under Live until the next pull-to-refresh or app-
  // resume. 30 s is fine-grained enough that the boundary feels
  // immediate and cheap enough that an idle tab doesn't burn
  // battery.
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _cubit = sl<BibleSessionCubit>()..loadSessions();
    // Listen for app foreground/background transitions so a user who
    // backgrounded the app, then returns minutes/hours later, gets a
    // silent refresh instead of stale data. The 30s tick below is
    // for in-memory re-bucketing only; a real Firestore refetch
    // still runs on app-resume / pull-to-refresh / detail-page return.
    WidgetsBinding.instance.addObserver(this);

    _tickTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (mounted) setState(() {});
      },
    );

    // Cross-surface tab pre-selection (e.g. home page's Live pill).
    // The notifier is static on the cubit class; we attach a
    // listener and also consume any value that was already set
    // before our listener was attached (an edge case during the
    // very first BibleTab mount in the shell's IndexedStack).
    BibleSessionCubit.pendingInitialTab.addListener(_consumePendingTab);
    _consumePendingTab();
  }

  void _consumePendingTab() {
    if (!mounted) return;
    final pending = BibleSessionCubit.pendingInitialTab.value;
    if (pending == null) return;
    // Defensive: the cross-surface notifier could in theory carry an
    // 'all' value from older callers — coerce to 'upcoming' so the
    // user-side tab (which no longer renders an All bucket) doesn't
    // land on an unreachable state.
    final coerced = pending == 'all' ? 'upcoming' : pending;
    _cubit.switchTab(coerced);
    BibleSessionCubit.pendingInitialTab.value = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // App came back to foreground after being backgrounded. Refresh
    // silently so live sessions that started / ended while the user
    // was away don't keep showing stale countdowns. Pull-to-refresh
    // remains the always-available manual override.
    if (state == AppLifecycleState.resumed && mounted) {
      _cubit.refresh();
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
      return const _LoadingBody(activeTab: 'upcoming');
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
    // Filter the cubit's live list down to sessions that are still
    // effectively live (status='live' AND within the deadline). A
    // stale-live row past its deadline is shunted into the Past
    // bucket so the user never sees "live" sessions that have
    // actually finished — the auto-complete cron will flip the doc
    // later, but the UI doesn't wait.
    final effectivelyLive =
        state.live.where((s) => s.isEffectivelyLive).toList();
    final staleLiveAsPast =
        state.live.where((s) => !s.isEffectivelyLive).toList();
    final pastIncludingStale = [...staleLiveAsPast, ...state.past];

    final activeTab = _coerceTab(state.activeTab);
    final list = _listFor(state, effectivelyLive, pastIncludingStale);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        const SliverToBoxAdapter(child: _Header()),
        SliverToBoxAdapter(
          child: _TabBar(
            activeTab: activeTab,
            liveCount: effectivelyLive.length,
            upcomingCount: state.upcoming.length,
            pastCount: pastIncludingStale.length,
            onSwitchTab: onSwitchTab,
          ),
        ),
        SliverToBoxAdapter(
          child: _SectionHeader(
            tab: activeTab,
            count: list.length,
            // joinable count == effectivelyLive count post-filter,
            // since isEffectivelyLive == isLive && isJoinable for any
            // session with a startedAt. Stale-live rows are already
            // out of this list.
            joinableLiveCount: effectivelyLive.length,
          ),
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
              return _BibleSessionCard(
                session: session,
                // Per-user state plumbed from the cubit so the card
                // doesn't have to do its own Firestore read on build:
                //   • isPaid  → live CTA flips to "Open Meeting ✅"
                //   • isRegistered → upcoming CTA flips to
                //                    "Registered ✓" instead of the
                //                    misleading "Register Free" prompt
                //                    that re-asks a user who already
                //                    registered.
                isPaid: state.paidSessionIds.contains(session.id),
                isRegistered:
                    state.registeredSessionIds.contains(session.id),
                onTap: () => _openDetail(itemContext, session.id),
                onSpeakerTap: () =>
                    itemContext.push('/user/priest/${session.priestId}'),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  // The 'all' tab was removed from the UI; if a stale value sneaks
  // through (cross-surface notifier or a future deep link), fall
  // back to 'upcoming' so the tab bar still highlights something.
  String _coerceTab(String t) =>
      (t == 'live' || t == 'upcoming' || t == 'past') ? t : 'upcoming';

  List<BibleSessionModel> _listFor(
    BibleSessionLoaded s,
    List<BibleSessionModel> effectivelyLive,
    List<BibleSessionModel> pastIncludingStale,
  ) {
    switch (_coerceTab(s.activeTab)) {
      case 'live':
        return effectivelyLive;
      case 'past':
        return pastIncludingStale;
      case 'upcoming':
      default:
        return s.upcoming;
    }
  }

  // Detail page pops `true` when the user registered, cancelled, or
  // paid — anything that changed the list data. Refresh the cubit
  // only on those returns so a back-tap with no action doesn't burn
  // four parallel reads. The captured `itemContext` belongs to the
  // builder's element, so the `mounted` check guards against the
  // user backing out of the entire tab while the detail page is up.
  Future<void> _openDetail(BuildContext itemContext, String id) async {
    final changed = await itemContext.push<bool>('/bible/detail/$id');
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
        const SliverToBoxAdapter(child: _Header()),
        SliverToBoxAdapter(
          child: _TabBar(
            activeTab: activeTab,
            liveCount: 0,
            upcomingCount: 0,
            pastCount: 0,
            onSwitchTab: (_) {},
          ),
        ),
        SliverToBoxAdapter(
          child: _SectionHeader(
            tab: activeTab,
            count: 0,
            joinableLiveCount: 0,
          ),
        ),
        SliverList.builder(
          itemCount: 3,
          itemBuilder: (_, _) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Shimmer.fromColors(
              baseColor: baseColor,
              highlightColor: highlightColor,
              child: Container(
                height: 220,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
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
        AppIcon(
          AppIcons.error,
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
  const _Header();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Bible Sessions",
              style: GoogleFonts.inter(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppColors.deepDarkBrown,
                letterSpacing: -0.4,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Grow in faith. Join live or upcoming sessions.",
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tab bar (Live / Upcoming / Past) ───────────────────────────

class _TabBar extends StatelessWidget {
  final String activeTab;
  final int liveCount;
  final int upcomingCount;
  final int pastCount;
  final void Function(String tab) onSwitchTab;

  const _TabBar({
    required this.activeTab,
    required this.liveCount,
    required this.upcomingCount,
    required this.pastCount,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      // Outer pill container with three equal-width inner segments.
      // ONLY the active segment renders its own filled brown pill —
      // matches the reference image, where Live and Past are flat
      // text inside the cream bar and Upcoming sits as a dark capsule.
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.surfaceCream,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: AppColors.borderLight, width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: _TabButton(
                label: "Live",
                isActive: activeTab == 'live',
                showLiveDot: liveCount > 0,
                onTap: () => onSwitchTab('live'),
              ),
            ),
            Expanded(
              child: _TabButton(
                label: upcomingCount > 0
                    ? "Upcoming ($upcomingCount)"
                    : "Upcoming",
                isActive: activeTab == 'upcoming',
                onTap: () => onSwitchTab('upcoming'),
              ),
            ),
            Expanded(
              child: _TabButton(
                label: "Past",
                isActive: activeTab == 'past',
                onTap: () => onSwitchTab('past'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool isActive;
  // ignore: unused_element_parameter
  final bool showLiveDot;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isActive,
    required this.onTap,
    this.showLiveDot = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          // primaryBrown (#6B3A2A) is the canonical brand brown — use
          // it here instead of the near-black deepDarkBrown so the
          // active pill stays on-palette with buttons, the FAB, and
          // the rest of the warm-brown design tokens.
          color: isActive ? AppColors.primaryBrown : Colors.transparent,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showLiveDot) ...[
                _PulsingDot(
                  size: 5,
                  color: isActive ? Colors.white : _kLiveRed,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight:
                      isActive ? FontWeight.w700 : FontWeight.w600,
                  color: isActive
                      ? Colors.white
                      : AppColors.primaryBrown.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Section header (Next up / Live now / Past sessions) ────────

class _SectionHeader extends StatelessWidget {
  final String tab;
  final int count;
  // Count of LIVE-tab rows that are still inside the join window.
  // `count` includes rows whose deadline passed (kept visible until
  // the auto-complete cron flips them to past) — those shouldn't
  // count toward "an active session you can join". Only meaningful
  // when tab == 'live'.
  final int joinableLiveCount;

  const _SectionHeader({
    required this.tab,
    required this.count,
    required this.joinableLiveCount,
  });

  ({IconData icon, String title, String subtitle}) get _copy {
    switch (tab) {
      case 'live':
        return (
          icon: AppIcons.podcast,
          title: 'Live now',
          subtitle: joinableLiveCount == 0
              ? (count == 0
                  ? 'No sessions broadcasting right now'
                  : "Just ended — auto-archiving shortly")
              : 'Join an active session',
        );
      case 'past':
        return (
          icon: AppIcons.history,
          title: 'Past sessions',
          subtitle: 'Recently completed',
        );
      case 'upcoming':
      default:
        return (
          icon: AppIcons.calendar,
          title: 'Next up',
          subtitle: 'Your upcoming sessions',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _copy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceSecondary,
              border: Border.all(
                color: AppColors.borderLight,
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: AppIcon(
              c.icon,
              size: 14,
              color: AppColors.deepDarkBrown.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.title,
                style: GoogleFonts.inter(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                c.subtitle,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
            ],
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
      case 'past':
        return 'No past sessions yet';
      case 'upcoming':
      default:
        return 'No upcoming sessions';
    }
  }

  String get _subtitle {
    switch (tab) {
      case 'live':
        return "When a speaker starts a session,\nit'll appear here.";
      case 'past':
        return "You'll see completed sessions here\nonce some have wrapped up.";
      case 'upcoming':
      default:
        return 'Check back soon — speakers add new\nsessions every week.';
    }
  }

  IconData get _icon =>
      tab == 'live' ? AppIcons.podcast : AppIcons.bible;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(
              _icon,
              size: 52,
              color: AppColors.muted.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 14),
            Text(
              _title,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12.5,
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

// ─── Bible session card (unified live + upcoming + past) ────────
//
// One card shape across every bucket so the tab switch reads as a
// content swap, not a layout shift. Status-specific affordances:
//   • live → red top-strip with pulsing LIVE pill + "X min left"
//   • upcoming → soft "Starting in …" badge (green if <2h, peach
//     otherwise) + Join Now (in join window) / Remind Me (further out)
//   • past → "Completed" / "Cancelled" pill, price reads as "Free"
//     when applicable

class _BibleSessionCard extends StatefulWidget {
  final BibleSessionModel session;
  final bool isPaid;
  // True when the current user already has a non-cancelled
  // registration on this UPCOMING session. Drives the upcoming
  // CTA branch — flips from amber "Register Free" (prompt) to
  // outlined-green "Registered ✓" (acknowledgement). Ignored for
  // live / completed / cancelled (those CTAs have their own logic).
  final bool isRegistered;
  final VoidCallback onTap;
  final VoidCallback onSpeakerTap;

  const _BibleSessionCard({
    required this.session,
    required this.isPaid,
    required this.isRegistered,
    required this.onTap,
    required this.onSpeakerTap,
  });

  @override
  State<_BibleSessionCard> createState() => _BibleSessionCardState();
}

class _BibleSessionCardState extends State<_BibleSessionCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // "Properly live" = status='live' AND still inside the join
    // window. A live-past-deadline session shouldn't keep the red
    // border / pulsing LIVE pill / red shadow because nothing about
    // it is actually live anymore — the auto-complete cron will move
    // it to past on the next tick. Treat it as a muted card so the
    // visual signal matches the "Just ended" timing pill and ghost
    // CTA the CTA branch picks for it.
    final isLiveJoinable = session.isLive && session.isJoinable;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.985),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isLiveJoinable
                  ? _kLiveRed.withValues(alpha: 0.35)
                  : AppColors.borderLight,
              width: isLiveJoinable ? 1.4 : 1,
            ),
            boxShadow: isLiveJoinable
                ? [
                    BoxShadow(
                      color: _kLiveRed.withValues(alpha: 0.08),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : kWarmCardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Row 1: category pill (or LIVE) + timing badge ──
              // No Expanded around the pill — let it shrink-wrap to
              // its label width so the row reads as "small chip on
              // the left, small badge on the right with a gap", not
              // a stretched bar. LIVE pill only renders for actually-
              // joinable live sessions — for live-past-deadline rows
              // we fall back to the category pill so the card doesn't
              // visually claim it's broadcasting.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isLiveJoinable)
                    _LivePill()
                  else
                    _CategoryPill(category: session.category),
                  const Spacer(),
                  _TimingBadge(session: session),
                ],
              ),
              const SizedBox(height: 10),
              // ── Title ──
              Text(
                session.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 17.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepDarkBrown,
                  height: 1.2,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              // ── Speaker (clickable) ──
              _SpeakerRow(
                priestName: session.priestName.isEmpty
                    ? 'Gospel Vox'
                    : session.priestName,
                priestPhotoUrl: session.priestPhotoUrl,
                onTap: widget.onSpeakerTap,
              ),
              const SizedBox(height: 10),
              // ── Meta pills (date / time / duration) ──
              _MetaPills(session: session),
              const SizedBox(height: 10),
              // ── Attending row ──
              _AttendingRow(
                count: session.registrationCount,
                isPast: session.isCompleted || session.isCancelled,
              ),
              const SizedBox(height: 10),
              // ── Price + CTA ──
              _PriceAndCta(
                session: session,
                isPaid: widget.isPaid,
                isRegistered: widget.isRegistered,
                onTap: widget.onTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Card sub-widgets ────────────────────────────────────────────

class _CategoryPill extends StatelessWidget {
  final String category;
  const _CategoryPill({required this.category});

  @override
  Widget build(BuildContext context) {
    if (category.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            AppIcons.bible,
            size: 11,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              category,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.amberGold,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LivePill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: _kLiveRed.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PulsingDot(size: 6, color: _kLiveRed),
            const SizedBox(width: 6),
            Text(
              "LIVE",
              style: GoogleFonts.inter(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: _kLiveRed,
                letterSpacing: 0.7,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimingBadge extends StatelessWidget {
  final BibleSessionModel session;
  const _TimingBadge({required this.session});

  @override
  Widget build(BuildContext context) {
    // Live → red countdown ("45 min left"). Only "properly" live
    // sessions (within the deadline) show this. A stale-live row
    // past its deadline now falls into the Past tab and is rendered
    // through the Completed branch below — see _LoadedBody where the
    // bucketing happens.
    if (session.isEffectivelyLive) {
      return _TimingBox(
        bg: _kLiveRed.withValues(alpha: 0.1),
        labelColor: _kLiveRed,
        valueColor: _kLiveRed,
        label: "Ending in",
        value: session.remainingTimeText.replaceAll(' left', ''),
      );
    }
    // Completed / cancelled → muted status pill.
    // isEffectivelyCompleted catches both real 'completed' docs and
    // a stale 'live' doc whose deadline has passed, so the pill copy
    // is honest the instant the deadline elapses (no waiting for the
    // 5-min cron flip).
    if (session.isEffectivelyCompleted) {
      return _StatusBox(
        bg: AppColors.success.withValues(alpha: 0.12),
        color: AppColors.success,
        text: "Completed",
      );
    }
    if (session.isCancelled) {
      return _StatusBox(
        bg: AppColors.muted.withValues(alpha: 0.16),
        color: AppColors.muted,
        text: "Cancelled",
      );
    }
    // Upcoming branch.
    if (session.scheduledAt == null) return const SizedBox.shrink();

    // Scheduled time has come/gone but status is still 'upcoming' —
    // the priest hasn't tapped "Start Meeting" yet. The OLD code
    // showed "Started" here, which was a lie (nothing had started).
    // Show an honest "Awaiting host / Speaker is preparing" pill so
    // the user understands the delay is on the speaker side; the in-
    // app push fires the moment the priest actually goes live.
    final diff = session.scheduledAt!.toLocal().difference(DateTime.now());
    if (diff.isNegative) {
      return _TimingBox(
        bg: _kAwaitBg,
        labelColor: _kAwaitText,
        valueColor: _kAwaitText,
        label: 'Speaker is',
        value: 'preparing',
      );
    }

    final imminent = session.hoursUntil < 2;
    final (label, value) = _formatStartsIn(session);
    return _TimingBox(
      bg: imminent ? _kSoonBg : _kLaterBg,
      labelColor: imminent ? _kSoonText : _kLaterText,
      valueColor: imminent ? _kSoonText : _kLaterText,
      label: label,
      value: value,
    );
  }

  // Splits the countdown into a small label + a bold value so the
  // pill reads like the reference ("Starting in" / "1h 04m"). Day-
  // range values collapse the prefix to "Starts in" to match the
  // image's wording on far-out sessions.
  //
  // The "past scheduled time, status still upcoming" case is handled
  // by the caller above (the "Awaiting host" branch) — by the time
  // we get here, `diff` is guaranteed non-negative.
  (String, String) _formatStartsIn(BibleSessionModel s) {
    final diff = s.scheduledAt!.toLocal().difference(DateTime.now());
    final days = s.daysUntil;
    if (days >= 1) return ('Starts in', '${days}d');
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    if (h >= 1) {
      return (
        'Starting in',
        m == 0 ? '${h}h' : '${h}h ${m.toString().padLeft(2, '0')}m'
      );
    }
    if (m >= 1) return ('Starting in', '${m}m');
    return ('Starting', 'now');
  }
}

class _TimingBox extends StatelessWidget {
  final Color bg;
  final Color labelColor;
  final Color valueColor;
  final String label;
  final String value;

  const _TimingBox({
    required this.bg,
    required this.labelColor,
    required this.valueColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
              color: labelColor.withValues(alpha: 0.85),
              height: 1.1,
            ),
          ),
          if (value.isNotEmpty) ...[
            const SizedBox(height: 1),
            Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: valueColor,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  final Color bg;
  final Color color;
  final String text;

  const _StatusBox({
    required this.bg,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _SpeakerRow extends StatelessWidget {
  final String priestName;
  final String priestPhotoUrl;
  final VoidCallback onTap;

  const _SpeakerRow({
    required this.priestName,
    required this.priestPhotoUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Avatar — network image with a brown initial fallback so
          // priests without a photo still get a branded chip.
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.deepDarkBrown,
              border: Border.all(
                color: AppColors.borderLight,
                width: 1,
              ),
              image: priestPhotoUrl.isNotEmpty
                  ? DecorationImage(
                      image: NetworkImage(priestPhotoUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            alignment: Alignment.center,
            child: priestPhotoUrl.isEmpty
                ? Text(
                    priestName.isNotEmpty
                        ? priestName.characters.first.toUpperCase()
                        : 'G',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              priestName,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
          const SizedBox(width: 5),
          AppIcon(
            AppIcons.verified,
            size: 12,
            color: AppColors.amberGold,
          ),
        ],
      ),
    );
  }
}

// Single rounded beige strip holding date · time · duration with thin
// vertical dividers between segments — matches the reference image
// (one unified container, NOT three standalone chips). Wraps to the
// content width so the row sits at the left of the card without
// stretching all the way to the right edge.
class _MetaPills extends StatelessWidget {
  final BibleSessionModel session;
  const _MetaPills({required this.session});

  @override
  Widget build(BuildContext context) {
    final hasDate = session.scheduledAt != null;
    return Align(
      alignment: Alignment.centerLeft,
      child: IntrinsicHeight(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.borderLight, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasDate)
                _MetaCell(
                  icon: AppIcons.calendar,
                  text: _formatShortDate(session.scheduledAt!),
                ),
              if (hasDate) const _MetaDivider(),
              _MetaCell(
                icon: AppIcons.clock,
                text: hasDate ? "${session.formattedTime} IST" : "TBA",
              ),
              const _MetaDivider(),
              _MetaCell(
                icon: AppIcons.stopwatch,
                text: session.formattedDuration,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaCell extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaCell({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            icon,
            size: 10.5,
            color: AppColors.muted,
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown.withValues(alpha: 0.78),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaDivider extends StatelessWidget {
  const _MetaDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      color: AppColors.borderLight,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );
  }
}

class _AttendingRow extends StatelessWidget {
  final int count;
  // True for completed/cancelled sessions — switches the copy to
  // past tense ("X joined" / "Nobody joined") so a past card doesn't
  // read as if registrations are still open.
  final bool isPast;

  const _AttendingRow({required this.count, required this.isPast});

  // Decorative avatar palette — three warm tones derived from the
  // existing brand palette so the stack feels intentional. Real
  // attendee photos would mean a per-card subcollection read on every
  // build; that's wasteful for a list view. The count IS authoritative
  // (it's the server-maintained registrationCount field).
  static const _avatarColors = [
    AppColors.primaryBrown,
    AppColors.amberGold,
    AppColors.deepDarkBrown,
  ];

  String get _label {
    if (count == 0) {
      return isPast ? 'Nobody joined' : 'Be the first to join';
    }
    return isPast ? '$count joined' : '$count attending';
  }

  @override
  Widget build(BuildContext context) {
    // Hide the decorative avatar stack entirely when no one has
    // registered — three brown circles next to "Be the first to join"
    // is a contradiction (the avatars imply people, the text says
    // there aren't any).
    final showAvatars = count > 0;
    return Row(
      children: [
        if (showAvatars) ...[
          SizedBox(
            width: 44,
            height: 20,
            child: Stack(
              children: [
                for (var i = 0; i < 3; i++)
                  Positioned(
                    left: i * 11.0,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _avatarColors[i],
                        border: Border.all(
                          color: AppColors.surfaceWhite,
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: AppIcon(
                        AppIcons.user,
                        size: 8,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ] else ...[
          // Small users-icon stand-in to keep the row's vertical
          // height stable across cards. Without this the empty-state
          // row would collapse and the bottom CTA would jump up.
          AppIcon(
            AppIcons.users,
            size: 12,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 7),
        ],
        Text(
          _label,
          style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}

class _PriceAndCta extends StatelessWidget {
  final BibleSessionModel session;
  final bool isPaid;
  final bool isRegistered;
  final VoidCallback onTap;

  const _PriceAndCta({
    required this.session,
    required this.isPaid,
    required this.isRegistered,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final priceLabel =
        session.price == 0 ? 'Free' : '₹${session.price}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          priceLabel,
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.amberGold,
            height: 1.0,
          ),
        ),
        const Spacer(),
        _BibleCta(
          session: session,
          isPaid: isPaid,
          isRegistered: isRegistered,
          onTap: onTap,
        ),
      ],
    );
  }
}

class _BibleCta extends StatelessWidget {
  final BibleSessionModel session;
  final bool isPaid;
  final bool isRegistered;
  final VoidCallback onTap;

  const _BibleCta({
    required this.session,
    required this.isPaid,
    required this.isRegistered,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Live → primary CTA. Paid users see green "Open Meeting".
    // isEffectivelyLive instead of isLive — a session past its
    // deadline gets routed through the Completed branch below so
    // the user is never offered a payable "Join Now" on a session
    // that's actually over.
    if (session.isEffectivelyLive) {
      final bg = isPaid ? _kJoinedGreen : AppColors.amberGold;
      final label = isPaid ? "Open Meeting" : "Join Now";
      return _PrimaryCta(label: label, bg: bg, onTap: onTap);
    }
    // Completed / cancelled → ghost view-details. The timing pill
    // carries the status signal; the card stays tappable so the user
    // can still read the description / rate.
    if (session.isEffectivelyCompleted || session.isCancelled) {
      return _GhostCta(label: 'View details', onTap: onTap);
    }
    // Upcoming, already registered → outlined-green "Registered ✓"
    // acknowledgement. Replaces the old "Register Free" prompt that
    // misleadingly invited the user to register a second time even
    // though they were already on the registrants list.
    if (isRegistered) {
      return _RegisteredCta(onTap: onTap);
    }
    // Upcoming, not registered → outlined amber "Register Free".
    // Tap opens the detail page where the actual free-register flow
    // lives. NB: we deliberately do NOT promote this to "Join Now"
    // inside the 15-min pre-start window — the priest may not have
    // tapped "Start Meeting" yet, so "Join Now" would lead to a
    // Register/Awaiting screen with no actual join affordance.
    // Staying on "Register Free" until the session is actually live
    // keeps the label honest.
    return _RegisterFreeCta(onTap: onTap);
  }
}

class _PrimaryCta extends StatelessWidget {
  final String label;
  final Color bg;
  final VoidCallback onTap;

  const _PrimaryCta({
    required this.label,
    required this.bg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: bg.withValues(alpha: 0.25),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 15,
              color: Colors.white,
            ),
          ],
        ),
      ),
    );
  }
}

// Outlined amber "Register Free" CTA shown on upcoming cards. Routes
// to the detail page where the actual free-registration flow lives
// (single Firestore write in `registerForSession`). Renamed from the
// older "Remind Me" copy — that label suggested an in-app reminder
// toggle, but tapping it only ever opened the detail page, leaving
// the user to wonder if anything happened. "Register Free" matches
// what tap actually leads to.
class _RegisterFreeCta extends StatelessWidget {
  final VoidCallback onTap;
  const _RegisterFreeCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.amberGold,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              AppIcons.bellOutline,
              size: 12,
              color: AppColors.amberGold,
            ),
            const SizedBox(width: 5),
            Text(
              'Register Free',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.amberGold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Outlined green "Registered ✓" CTA shown when the current user
// already has a non-cancelled registration on this upcoming session.
// Acknowledges the registration so the user doesn't see a prompt to
// re-register every time they revisit the tab. Stays tappable so
// the user can open the detail page to cancel / read the description
// / set reminders.
class _RegisteredCta extends StatelessWidget {
  final VoidCallback onTap;
  const _RegisteredCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: _kJoinedGreen.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _kJoinedGreen.withValues(alpha: 0.55),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              AppIcons.checkCircle,
              size: 12,
              color: _kJoinedGreen,
            ),
            const SizedBox(width: 5),
            Text(
              'Registered',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: _kJoinedGreen,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GhostCta extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _GhostCta({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: AppColors.surfaceSecondary,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.borderLight,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: AppColors.deepDarkBrown.withValues(alpha: 0.7),
          ),
        ),
      ),
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

// ─── Date formatter ─────────────────────────────────────────────

String _formatShortDate(DateTime d) {
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month]} ${d.day}';
}
