// User home feed — premium warm-toned surface the listener lands on.
//
// Visual anatomy (top to bottom), matching the reference mock:
//
//   • Gradient pane    – gold fading into bg, wraps the SafeArea
//                        header + search bar so the whole top of
//                        the screen reads as one warm hero band.
//   • Filter chips     – pure white pills on the flat bg, active
//                        chip is filled brandBrown.
//   • Sessions rail    – peeking PageView (viewportFraction 0.78)
//                        with 3 stub cards until the real Bible
//                        sessions collection ships.
//   • Available Now    – 2-column grid of priest cards. The TOP
//                        half of each card is the priest's photo
//                        filling a gradient-backed rectangle; if
//                        there's no photo the gradient shows with
//                        a large initial. Status + rating sit as
//                        soft translucent pills, not hard black
//                        blobs.
//
// Implementation notes:
//
//   1. All screen-specific colours live in the private `_C` class.
//      Don't sprinkle hex inline — drift is inevitable once that
//      starts.
//
//   2. Chip filtering is LOCAL to this widget (`_activeFilter`).
//      The cubit already owns search; mixing a second filter into
//      the cubit would force coupling we don't need.
//      `_visiblePriests(state)` layers the chip filter on top of
//      the cubit's search output.
//
//   3. Long display names and big coin balances are scaled down
//      with FittedBox rather than ellipsised. "Hi, Abhishekkkk..."
//      always reads worse than "Hi, Abhishekkkk" at 92% size.
//
//   4. The priest card's bottom section is a fixed 112px so a
//      long denomination/language row can never push the card
//      into overflow on a 320-wide phone. The image top takes the
//      remainder of the card's bounded height.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/pulsing_dot.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/shared/bloc/bible_session_cubit.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/user/home/bloc/home_cubit.dart';
import 'package:gospel_vox/features/user/home/bloc/home_state.dart';
import 'package:gospel_vox/features/user/home/pages/user_shell_page.dart';

// ─── Design tokens for this screen ─────────────────────────

class _C {
  static const bgColor = Color(0xFFEDE5D8);
  static const darkBrown = Color(0xFF140800);
  static const brandBrown = Color(0xFF2C1810);
  static const amberGold = Color(0xFFC8902A);
  static const goldLight = Color(0xFFE8B860);
  static const muted = Color(0xFF9B7B6E);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceWarm = Color(0xFFFBF7F2);
  static const onlineGreen = Color(0xFF2E7D4F);
  static const busyAmber = Color(0xFFD4A060);
  static const notifRed = Color(0xFFDC2626);

  // Cycled per priest card by `index % n` — keeps a priest's
  // colour stable across rebuilds so their card reads as a
  // consistent identity tile.
  static const priestGradients = <List<Color>>[
    [Color(0xFF8B6B5A), Color(0xFFC8A882)], // warm brown
    [Color(0xFF6B7B8B), Color(0xFF9BAAB8)], // cool blue-gray
    [Color(0xFF8B7B9B), Color(0xFFB8A8C8)], // warm purple
    [Color(0xFF7B8B6B), Color(0xFFA8B898)], // muted sage
    [Color(0xFF9B7B6B), Color(0xFFC8B8A8)], // dusty rose
    [Color(0xFF6B8B7B), Color(0xFF98B8A8)], // teal muted
  ];

  // Bible session carousel used to render flat gradient cards keyed
  // off these tokens. The format flipped to the dark-base banner
  // (_BibleSessionBanner) where the colour story lives in the
  // category-keyed artwork, so the gradient palette is no longer
  // needed here.
}

// ─── Bible carousel ───────────────────────────────────────

// Number of upcoming Bible sessions surfaced in the home carousel.
// 5 leaves headroom on the rail without overwhelming the section —
// the banner format is tall (216 px), so beyond five the user
// is going to bounce to the Bible tab anyway.
const int _kHomeBibleLimit = 5;

// Asset paths for the category-keyed banner artwork. Hoisted to
// top-level so the Home initState can precacheImage all five into
// the ImageCache before the first carousel frame paints, killing
// the white-flash-then-image pop on the first card.
const List<String> _kBibleBannerAssets = <String>[
  'assets/bible_banners/bible_book.png',
  'assets/bible_banners/cross.png',
  'assets/bible_banners/dove.png',
  'assets/bible_banners/praying hands.png',
  'assets/bible_banners/scrolls.png',
];

const _kFilterChips = <String>[
  'All',
  'Online',
  'Priests',
  'Pastors',
  'Counsellors',
  'Bible Teachers',
];

// ─── Root ─────────────────────────────────────────────────

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<HomeCubit>(
      create: (_) => sl<HomeCubit>()..watchPriests(),
      child: const _HomeView(),
    );
  }
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;

  late final Animation<double> _heroAnim;
  late final Animation<double> _chipsAnim;
  late final Animation<double> _sessionsAnim;
  late final Animation<double> _gridLabelAnim;

  final TextEditingController _searchController = TextEditingController();
  // 0.92 makes the active banner dominate the viewport while still
  // showing ~8% of the next card as a swipe affordance. The previous
  // 0.78 was tuned for the old short gradient cards; with the new
  // 216-tall banner format, a wider slot is required for the title +
  // CTA to breathe.
  final PageController _carouselController =
      PageController(viewportFraction: 0.92);

  String _activeFilter = 'All';
  int _carouselIndex = 0;

  // Bible sessions surfaced on the home carousel. Driven by a live
  // Firestore stream now (was one-shot in initState) so a session
  // created on another device, a status flip (upcoming → live), or
  // a cancel all reflect on this page within seconds without a
  // pull-to-refresh.
  //
  // Carousel display rules (applied in `_onBibleSnap` after each
  // stream tick):
  //   • only `status in {upcoming, live}` (terminal sessions don't
  //     belong on a home rail);
  //   • drop sessions whose end-time has passed (server might not
  //     have flipped status yet);
  //   • sort by scheduledAt ascending (soonest first);
  //   • take the top _kHomeBibleLimit slots — a 2-month-out
  //     session only surfaces if there aren't enough nearer ones.
  bool _bibleLoading = true;
  List<BibleSessionModel> _bibleSessions = const [];
  int _liveCount = 0;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _bibleSub;
  // First-time bootstrap guard. Fires once per home-mount: if any
  // live session has the signed-in user as a non-cancelled
  // registrant, surface the call-like overlay so a user who missed
  // the FCM still gets pulled in. Set true after the first attempt
  // regardless of outcome so we don't re-check on stream updates.
  bool _liveBootstrapDone = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // The whole top hero (header + search) animates as one block so
    // the gradient doesn't fade in piece-wise and look twitchy.
    _heroAnim = _interval(0.0, 0.45);
    _chipsAnim = _interval(0.15, 0.55);
    _sessionsAnim = _interval(0.22, 0.62);
    _gridLabelAnim = _interval(0.32, 0.7);
    _animController.forward();

    _startBibleStream();

    // Decode every banner asset into the ImageCache before the
    // carousel paints its first frame. Combined with
    // gaplessPlayback: true on the Image.asset, this guarantees the
    // banner art and the text on top of it render in the same frame
    // — no white card with text appearing before the image pops in.
    // Scheduled post-frame because precacheImage needs a fully-set-up
    // BuildContext for the ImageCache inherited widget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final p in _kBibleBannerAssets) {
        precacheImage(AssetImage(p), context);
      }
    });
  }

  void _startBibleStream() {
    // Generous limit (20) so the client-side filter has room to
    // drop expired/cancelled rows without leaving the carousel
    // short. Pure `where status in [...]` keeps us inside the
    // auto-index — no composite index required. We sort + filter
    // in `_onBibleSnap` rather than via Firestore orderBy, which
    // would force a composite index AND silently drop docs whose
    // scheduledAt field is missing.
    _bibleSub = FirebaseFirestore.instance
        .collection('bible_sessions')
        .where('status', whereIn: ['upcoming', 'live'])
        .limit(20)
        .snapshots()
        .listen(_onBibleSnap, onError: (_) {
      if (!mounted) return;
      // Soft-fail — render empty rather than throwing. The Bible
      // tab has its own retry UX for users who care.
      setState(() {
        _bibleSessions = const [];
        _liveCount = 0;
        _bibleLoading = false;
      });
    });
  }

  void _onBibleSnap(QuerySnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;
    final now = DateTime.now();
    final parsed = snap.docs
        .map((d) => BibleSessionModel.fromFirestore(d.id, d.data()))
        .where((s) {
      // Drop rows with no scheduledAt — we can't reason about them
      // and they shouldn't render in a date-sorted carousel.
      final at = s.scheduledAt;
      if (at == null) return false;
      // Drop expired upcoming sessions — the priest may not have
      // marked them complete yet, but they shouldn't surface as
      // "upcoming" on home. Live sessions get a wider tolerance
      // (duration + 15 min buffer) to match the auto-complete cron.
      final endTime = at.add(Duration(
        minutes: s.durationMinutes + (s.isLive ? 15 : 0),
      ));
      return endTime.isAfter(now);
    }).toList()
      ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));

    final live = parsed.where((s) => s.isLive).length;
    final visible = parsed.take(_kHomeBibleLimit).toList();

    setState(() {
      _bibleSessions = visible;
      _liveCount = live;
      _bibleLoading = false;
    });

    // One-shot fallback: if the user opens the app while a session
    // they're registered for is live, surface the call-like overlay
    // even if the FCM never arrived (background-dropped push,
    // missed because notifications were disabled, etc.). Runs once
    // per page mount so the overlay isn't re-triggered on every
    // stream tick.
    if (!_liveBootstrapDone) {
      _liveBootstrapDone = true;
      final liveSessions = parsed.where((s) => s.isLive).toList();
      if (liveSessions.isNotEmpty) {
        _maybeFireLiveOverlay(liveSessions);
      }
    }
  }

  Future<void> _maybeFireLiveOverlay(
    List<BibleSessionModel> liveSessions,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // Check each live session for an active (non-cancelled)
    // registration belonging to this user. We stop at the first
    // match — surfacing the overlay for one session is plenty;
    // a user with two simultaneous live sessions they're registered
    // for is a rounding-error case.
    for (final s in liveSessions) {
      try {
        final regDoc = await FirebaseFirestore.instance
            .doc('bible_sessions/${s.id}/registrations/$uid')
            .get()
            .timeout(const Duration(seconds: 5));
        if (!mounted) return;
        final regData = regDoc.data();
        if (regData == null) continue;
        if (regData['status'] == 'cancelled') continue;
        // Match. Fire the overlay event. The overlay widget
        // mounted at MaterialApp.router.builder will pick it up.
        NotificationService.bibleSessionLiveEvent.value =
            BibleSessionLiveEvent(
          id: 'home-bootstrap-${s.id}',
          sessionId: s.id,
          sessionTitle: s.title,
          priestName: s.priestName,
          priestPhotoUrl: s.priestPhotoUrl,
          price: s.price,
        );
        return;
      } catch (_) {
        // Soft-fail per session; try the next one.
        continue;
      }
    }
  }

  void _switchToBibleTab() {
    final shell = UserShellScope.of(context);
    if (shell != null) {
      // Bible moved from index 1 to index 2 when Sessions took the
      // slot next to Home (Sessions is daily-use; Bible is weekly).
      shell.switchToTab(2);
    }
  }

  Animation<double> _interval(double start, double end) {
    return CurvedAnimation(
      parent: _animController,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
  }

  // didChangeDependencies / tab-return refresh is no longer needed —
  // the Firestore stream subscribed in `_startBibleStream` keeps the
  // carousel real-time, so a session created on another device or a
  // status flip lands here within a Firestore tick. The earlier
  // tab-return reload existed only because the carousel was a
  // one-shot fetch.

  @override
  void dispose() {
    _bibleSub?.cancel();
    _animController.dispose();
    _searchController.dispose();
    _carouselController.dispose();
    super.dispose();
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String _getFirstName() {
    final display = FirebaseAuth.instance.currentUser?.displayName ?? '';
    if (display.trim().isEmpty) return 'there';
    return display.trim().split(' ').first;
  }

  List<SpeakerModel> _visiblePriests(HomeLoaded state) {
    final base = state.filteredPriests;
    if (_activeFilter == 'All') return base;
    if (_activeFilter == 'Online') {
      return base.where((p) => p.isAvailable).toList();
    }
    final q = _activeFilter.toLowerCase();
    return base.where((p) {
      return p.denomination.toLowerCase().contains(q) ||
          p.specializations.any((s) => s.toLowerCase().contains(q));
    }).toList();
  }

  void _openProfile(String priestId) {
    context.push('/user/priest/$priestId');
  }

  void _switchToWalletTab() {
    // Wallet is no longer a shell tab — index 2 is now the Sessions
    // tab. The wallet lives at /user/wallet as a push route, so the
    // back button takes the user back here cleanly without losing
    // the Home tab's scroll/search state.
    context.push('/user/wallet');
  }

  // Subscribes the signed-in user to a one-shot "speaker is now
  // available" push notification. Persists the priestId on the
  // user's own doc as `notifySubscriptions: [priestId, ...]`. The
  // CF `notifyAvailableSubscribers` watches priests.isOnline
  // false→true transitions, fans out a push to every subscriber,
  // and atomically clears the priestId from each user's array so
  // they're pinged exactly once per "go online" event.
  //
  // Uses update() rather than set(merge:true) for the same reason
  // the FCM token save does — set(merge:true) on a missing user
  // doc would be treated as a CREATE by Firestore rules, which
  // require coinBalance/role and would reject the write. update()
  // fails fast with not-found instead, which we surface as a
  // recoverable error instead of a silent permission denial.
  Future<void> _subscribeToNotifyMe(SpeakerModel priest) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance
          .doc('users/$uid')
          .update({
            'notifySubscriptions':
                FieldValue.arrayUnion([priest.uid]),
          })
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      AppSnackBar.success(
        context,
        "You'll be notified when ${priest.fullName} is available",
      );
    } on FirebaseException catch (e) {
      debugPrint('[Home] notify-me subscribe failed: ${e.code} ${e.message}');
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't subscribe. Try again.");
    } catch (e) {
      debugPrint('[Home] notify-me subscribe unexpected: $e');
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't subscribe. Try again.");
    }
  }

  // Mirror of priest_profile_page._requestSession. The card already
  // hides this CTA when !priest.isAvailable. Beyond that we run the
  // same SessionPreflight the profile + chat-history surfaces use —
  // when balance is short of the 5-minute floor, the preflight
  // opens the RechargeSheet bottom sheet with contextual copy
  // ("Add ₹X more to start your chat with Fr. Y") instead of
  // letting the user reach the waiting page only to bounce off a
  // generic "insufficient-balance" snackbar from the CF.
  Future<void> _startSession(SpeakerModel priest, String type) async {
    final canStart = await SessionPreflight.check(
      context,
      type: type,
      priestName: priest.fullName,
    );
    if (!canStart || !mounted) return;
    context.push('/session/waiting', extra: <String, dynamic>{
      'priestId': priest.uid,
      'priestName': priest.fullName,
      'priestPhotoUrl': priest.photoUrl,
      'priestDenomination': priest.denomination,
      'type': type,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bgColor,
      body: BlocConsumer<HomeCubit, HomeState>(
        listener: (ctx, state) {
          if (state is HomeError) {
            AppSnackBar.error(ctx, state.message);
          }
        },
        builder: (ctx, state) {
          return RefreshIndicator(
            color: _C.brandBrown,
            backgroundColor: _C.surface,
            // Bible sessions are now live-streamed by
            // _startBibleStream, so the pull-indicator only needs
            // to re-fetch priests — the carousel auto-updates.
            onRefresh: () => ctx.read<HomeCubit>().refresh(),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                _animatedSliver(_heroAnim, _buildTopHero()),
                _animatedSliver(_chipsAnim, _buildFilterChips()),
                _animatedSliver(_sessionsAnim, _buildSessionsSection(state)),
                _animatedSliver(_gridLabelAnim, _buildAvailableNowLabel()),
                _buildBody(state),
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _animatedSliver(Animation<double> animation, Widget child) {
    return SliverToBoxAdapter(
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, inner) {
          final t = animation.value;
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 12),
              child: inner,
            ),
          );
        },
        child: child,
      ),
    );
  }

  // ─── Top hero (gradient + header + search) ────────────

  Widget _buildTopHero() {
    return Container(
      decoration: const BoxDecoration(
        // Warm-to-bg gradient runs the full vertical of the hero
        // so the bell + coin pill + greeting all share the same
        // tinted band, and the search bar rests at the soft end
        // where the gradient has nearly finished fading out.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_C.goldLight, _C.bgColor],
          stops: [0.0, 1.0],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeaderRow(),
              const SizedBox(height: 20),
              _buildSearchBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _getGreeting(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  // Bumped from 0.6 → 0.7 so the label stays
                  // legible against the darker top of the gold
                  // gradient, where 0.6 was borderline on AA.
                  color: _C.darkBrown.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 4),
              // Name scales down instead of ellipsising so longer
              // display names remain legible even in a narrow
              // header with a big coin number on the right.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'Hi, ${_getFirstName()}',
                  maxLines: 1,
                  style: GoogleFonts.inter(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: _C.darkBrown,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _NotificationBell(
          // hasUnread stays false until we wire a count query — the
          // dot is strictly for real unread activity, and a
          // permanent dot trains users to ignore it.
          hasUnread: false,
          onTap: () => context.push('/user/notifications'),
        ),
        const SizedBox(width: 10),
        _BalancePill(onTap: _switchToWalletTab),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: _C.brandBrown.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (q) {
          context.read<HomeCubit>().search(q);
          setState(() {});
        },
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: _C.darkBrown,
        ),
        decoration: InputDecoration(
          hintText: 'Search priests, role, language...',
          hintStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: _C.muted.withValues(alpha: 0.65),
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Icon(
              Icons.search_rounded,
              size: 22,
              color: _C.muted.withValues(alpha: 0.7),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 42,
            minHeight: 40,
          ),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _PressScale(
                    onTap: () {
                      _searchController.clear();
                      context.read<HomeCubit>().search('');
                      setState(() {});
                    },
                    scale: 0.9,
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: _C.muted,
                    ),
                  ),
                ),
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  // ─── Filter chips ─────────────────────────────────────

  Widget _buildFilterChips() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: _kFilterChips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final label = _kFilterChips[i];
            return _FilterChip(
              label: label,
              isActive: _activeFilter == label,
              onTap: () => setState(() => _activeFilter = label),
            );
          },
        ),
      ),
    );
  }

  // ─── Sessions rail ────────────────────────────────────

  Widget _buildSessionsSection(HomeState state) {
    final showShimmer = state is HomeLoading || _bibleLoading;
    final sessions = _bibleSessions;
    final dotCount = sessions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: 'UPCOMING SESSIONS',
          // Live-count pill sits between the title and the "See all"
          // link. Tapping it pre-selects the Bible tab's "Live" sub-
          // tab via BibleSessionCubit.pendingInitialTab — that
          // notifier survives a tab switch in the IndexedStack (the
          // BibleTab listens once and consumes on each change).
          trailing: _liveCount > 0
              ? _LivePill(
                  count: _liveCount,
                  onTap: () {
                    BibleSessionCubit.pendingInitialTab.value = 'live';
                    _switchToBibleTab();
                  },
                )
              : null,
          // "See all" lands the user on the Bible tab — that's where
          // the full list, filters, and detail page already live.
          onSeeAll: _switchToBibleTab,
        ),
        SizedBox(
          // 216 gives the banner format enough room for a 2-line
          // title + a description line + the date/time row + the
          // CTA, all without the bottom edge biting into the CTA's
          // glow on cards with the longest content.
          height: 216,
          child: showShimmer
              ? _SessionsCarouselShimmer()
              : sessions.isEmpty
                  ? const _BibleEmptyRail()
                  // padEnds:true (default) lets the first/last card
                  // sit centred in the viewport; combined with
                  // viewportFraction:0.92 and a 6 px symmetric inner
                  // padding, the first card's left edge lands at
                  // ~20 px from the screen edge — flush with the
                  // section header above and the priest grid below.
                  : PageView.builder(
                      controller: _carouselController,
                      physics: const BouncingScrollPhysics(),
                      itemCount: sessions.length,
                      onPageChanged: (i) =>
                          setState(() => _carouselIndex = i),
                      itemBuilder: (_, i) {
                        final session = sessions[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                          ),
                          child: _BibleSessionBanner(
                            session: session,
                            onTap: () => context.push(
                              '/bible/detail/${session.id}',
                            ),
                          ),
                        );
                      },
                    ),
        ),
        const SizedBox(height: 14),
        if (!showShimmer && dotCount > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(dotCount, (i) {
              final active = i == _carouselIndex;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: active ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: active
                      ? _C.amberGold
                      : _C.muted.withValues(alpha: 0.4),
                ),
              );
            }),
          ),
      ],
    );
  }

  Widget _buildAvailableNowLabel() {
    // Plain label — no "See all" link. The full list is the page the
    // user is already on, so a "See all" button there reads as a
    // dead button.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Text(
        'AVAILABLE NOW',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: _C.brandBrown,
        ),
      ),
    );
  }

  // ─── Grid body / loading / empty / error ──────────────

  Widget _buildBody(HomeState state) {
    if (state is HomeLoading || state is HomeInitial) {
      return const _PriestGridShimmer();
    }
    if (state is HomeError) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              state.message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: _C.muted,
              ),
            ),
          ),
        ),
      );
    }

    final loaded = state as HomeLoaded;
    final visible = _visiblePriests(loaded);

    if (visible.isEmpty) {
      return SliverToBoxAdapter(child: _buildEmpty(loaded));
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) {
            final priest = visible[i];
            return _PriestGridCard(
              priest: priest,
              gradient: _C
                  .priestGradients[i % _C.priestGradients.length],
              onTap: () => _openProfile(priest.uid),
              onChat: () => _startSession(priest, 'chat'),
              onCall: () => _startSession(priest, 'voice'),
              onNotify: () => _subscribeToNotifyMe(priest),
            );
          },
          childCount: visible.length,
        ),
      ),
    );
  }

  Widget _buildEmpty(HomeLoaded state) {
    final hasSearch = state.searchQuery.isNotEmpty;
    final hasChip = _activeFilter != 'All';

    String title;
    String subtitle;
    if (hasSearch) {
      title = 'No speakers found for “${state.searchQuery}”';
      subtitle = 'Try a different name, denomination, or topic.';
    } else if (hasChip) {
      title = 'No speakers in ${_activeFilter.toLowerCase()}';
      subtitle = 'Try selecting a different filter.';
    } else {
      title = 'No speakers available yet';
      subtitle = 'New speakers are joining regularly. Check back soon.';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _C.brandBrown.withValues(alpha: 0.05),
            ),
            child: Icon(
              hasSearch || hasChip
                  ? Icons.search_off_rounded
                  : Icons.people_outline_rounded,
              size: 28,
              color: _C.brandBrown.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _C.darkBrown,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: _C.muted,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Reusable press-to-scale wrapper ──────────────────────

class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const _PressScale({
    required this.child,
    required this.onTap,
    this.scale = 0.96,
  });

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  double _scale = 1.0;

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown:
          _enabled ? (_) => setState(() => _scale = widget.scale) : null,
      onPointerUp: _enabled ? (_) => setState(() => _scale = 1.0) : null,
      onPointerCancel:
          _enabled ? (_) => setState(() => _scale = 1.0) : null,
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

// ─── Section header ───────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback onSeeAll;
  // Optional pill / chip rendered between the title and the
  // "See all" link. The bible carousel uses this for the LIVE
  // indicator when any session is live; other section headers
  // can omit it. Kept as a generic Widget so future surfaces
  // don't need a per-feature header subclass.
  final Widget? trailing;

  const _SectionHeader({
    required this.title,
    required this.onSeeAll,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: _C.brandBrown,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
          const Spacer(),
          _PressScale(
            onTap: onSeeAll,
            scale: 0.92,
            child: Text(
              'See all →',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _C.amberGold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Live count pill — pulsing dot + "{N} Live" in red. Tappable;
// on tap, caller sets `BibleSessionCubit.pendingInitialTab = 'live'`
// before switching to the Bible tab so the user lands directly on
// the Live sub-tab without an extra interaction.
class _LivePill extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _LivePill({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFE53E3E).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFE53E3E).withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PulsingDot(size: 6, color: Color(0xFFE53E3E)),
            const SizedBox(width: 5),
            Text(
              "$count Live",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFE53E3E),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Notification bell ────────────────────────────────────

class _NotificationBell extends StatelessWidget {
  final VoidCallback onTap;
  // Only true when there's real unread activity. Wire this to a
  // notifications-collection query when that schema ships; right
  // now no data source exists, so callers pass `false` and the dot
  // stays hidden. A permanently-lit dot is badge-noise that trains
  // users to ignore it.
  final bool hasUnread;

  const _NotificationBell({
    required this.onTap,
    this.hasUnread = false,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      scale: 0.92,
      // Outer SizedBox is slightly larger than the circle so the
      // unread dot has room to sit HALF OUTSIDE the circle without
      // being clipped. 48×48 outer, 42×42 circle centered inside,
      // Stack overflow allowed via clipBehavior: Clip.none.
      child: SizedBox(
        width: 48,
        height: 48,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // The circle itself — explicit size + Center on the
            // Icon. Without both, the 22px icon defaults to the
            // container's top-start corner instead of centering.
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _C.surface,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _C.brandBrown.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Icons.notifications_none_rounded,
                  size: 22,
                  color: _C.brandBrown,
                ),
              ),
            ),
            // Unread dot — conditional. Positioned so its centre
            // lands on the circle's upper-right perimeter (≈ 45°
            // from top): half pops outside the circle, half still
            // overlaps it. Standard iOS badge placement.
            //
            // Geometry: circle radius 21, centre at (24,24) inside
            // the 48×48 stack. Perimeter point at 45° upper-right is
            // (24 + 21·cos45°, 24 − 21·sin45°) ≈ (38.85, 9.15). A
            // 10×10 dot centred there sits at top ≈ 4, right ≈ 4
            // measured from the 48×48 stack edges.
            if (hasUnread)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _C.notifRed,
                    border: Border.all(
                      // White halo so the dot reads against both
                      // the gold gradient band at the top of the
                      // page and the plain bg as the page scrolls.
                      color: _C.surface,
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Live coin balance pill ───────────────────────────────

// Streams the user's coinBalance from Firestore so the pill stays
// in sync with wallet credits/debits without the home tab needing
// to touch the wallet cubit.
class _BalancePill extends StatelessWidget {
  final VoidCallback onTap;
  const _BalancePill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return _PressScale(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: _C.brandBrown.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'COINS',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: _C.muted,
              ),
            ),
            const SizedBox(width: 6),
            // Cap the numeric width and scale down when bigger —
            // "10440" shouldn't push the pill so wide that it
            // crushes the greeting. Upper bound keeps the pill
            // visually stable.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 70),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: (uid == null)
                    ? _balanceText('0')
                    : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance
                            .doc('users/$uid')
                            .snapshots(),
                        builder: (_, snap) {
                          final bal = (snap.data?.data()?['coinBalance']
                                      as num?)
                                  ?.toInt() ??
                              0;
                          return _balanceText('$bal');
                        },
                      ),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: _C.brandBrown,
              ),
              child: const Icon(
                Icons.add_rounded,
                size: 16,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _balanceText(String value) => Text(
        value,
        maxLines: 1,
        softWrap: false,
        style: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: _C.darkBrown,
        ),
      );
}

// ─── Filter chip ──────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      scale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? _C.brandBrown : _C.surface,
          borderRadius: BorderRadius.circular(100),
          border: isActive
              ? null
              : Border.all(
                  color: _C.muted.withValues(alpha: 0.12),
                ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: _C.brandBrown.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            // Both states at w600 — colour does the active/inactive
            // work. Mixing w500/w600 made the active chip feel
            // disproportionately heavier than its neighbours.
            fontWeight: FontWeight.w600,
            color: isActive ? Colors.white : _C.brandBrown,
          ),
        ),
      ),
    );
  }
}

// ─── Bible session banner ─────────────────────────────────
//
// Dark-base premium banner: category-keyed artwork bleeds in from
// the right, a left-side veil keeps the title/CTA legible, and the
// drop-shadow gives the card the floating feel of the KATSEYE-style
// reference. Replaces the older flat gradient card.
//
// Layout strategy:
//
//   • LayoutBuilder reads the real card width inside its PageView
//     slot so the design holds from 320 px phones up to 430 px
//     phones without a hardcoded card width fighting the
//     viewportFraction.
//   • TextPainter measures the title once per build; if it wraps
//     to two lines we drop the description to one line so the CTA
//     never bites into the bottom edge. The reverse (1-line title,
//     2-line description) is also handled — both cases stay inside
//     the 184 px usable vertical (216 height − 16 + 16 padding).

class _BibleSessionBanner extends StatelessWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;

  const _BibleSessionBanner({
    required this.session,
    required this.onTap,
  });

  // Near-black base; the artwork overlays this and the left-edge of
  // the gradient sits on it solid, so no priest photo shines through
  // and harms text contrast.
  static const _darkBase = Color(0xFF1A0E08);
  // Pre-built mid-stop of the veil. (`_darkBase.withValues` isn't a
  // compile-time constant, so the hex form is required for the
  // `const LinearGradient` below.)
  static const _veilMid = Color(0x8C1A0E08); // ~55% alpha over _darkBase
  static const _liveRed = Color(0xFFE53E3E);

  String _bannerImage(String category) {
    // Lower-cased switch tolerates server typos like " Prayer" or
    // "DEEP STUDY". Anything outside the curated five falls through
    // to dove — the most neutral spiritual symbol we ship.
    switch (category.trim().toLowerCase()) {
      case 'deep study':
        return 'assets/bible_banners/bible_book.png';
      case 'prayer':
        return 'assets/bible_banners/praying hands.png';
      case 'worship':
        return 'assets/bible_banners/cross.png';
      case 'daily living':
        return 'assets/bible_banners/scrolls.png';
      default:
        return 'assets/bible_banners/dove.png';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLive = session.isLive;
    // Price is always positive in V1 (min ₹49 — confirmed during
    // spec sign-off); free sessions don't exist on this surface.
    final ctaText = isLive ? 'Join Now' : 'Register Now';
    final labelText = isLive ? 'LIVE NOW' : 'UPCOMING SESSION';
    final labelColor = isLive ? _liveRed : _C.amberGold;
    final timeLabel = session.formattedTime.isEmpty
        ? ''
        : '${session.formattedTime} IST';

    final titleStyle = GoogleFonts.inter(
      fontSize: 22,
      fontWeight: FontWeight.w900,
      color: Colors.white,
      height: 1.1,
      letterSpacing: -0.5,
    );

    return _PressScale(
      onTap: onTap,
      scale: 0.97,
      child: DecoratedBox(
        // Outer decoration carries the shadow — putting the shadow
        // on the inner clipped container would clip it away too.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.30),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            color: _darkBase,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth;
                // Text column owns the left 55%. Subtract the 18 px
                // left inset so TextPainter measures against the
                // real wrap width, not the column's bounding box.
                final textColWidth = cardWidth * 0.55;
                final textMeasureWidth = textColWidth - 18;

                // Decide description line count based on whether the
                // title wraps. The reverse (short title) gives the
                // description more room, so the card never wastes
                // vertical real-estate.
                final titlePainter = TextPainter(
                  text: TextSpan(text: session.title, style: titleStyle),
                  maxLines: 2,
                  textDirection: TextDirection.ltr,
                  ellipsis: '…',
                )..layout(maxWidth: textMeasureWidth);
                final titleIsTwoLines =
                    titlePainter.computeLineMetrics().length > 1;
                final descMaxLines = titleIsTwoLines ? 1 : 2;

                return Stack(
                  children: [
                    // ─── Layer 1: category artwork (right side) ───
                    Positioned(
                      right: -10,
                      top: 0,
                      bottom: 0,
                      width: cardWidth * 0.58,
                      child: Image.asset(
                        _bannerImage(session.category),
                        fit: BoxFit.cover,
                        // gaplessPlayback holds the previous frame
                        // through asset swaps so a category change
                        // doesn't flash white. Combined with the
                        // initState precache, first paint is also
                        // flash-free.
                        gaplessPlayback: true,
                        // Soft fade-in if the precache somehow
                        // missed (e.g., low-memory eviction).
                        frameBuilder:
                            (context, child, frame, wasSyncLoaded) {
                          if (wasSyncLoaded || frame != null) return child;
                          return const SizedBox.shrink();
                        },
                      ),
                    ),

                    // ─── Layer 2: left-to-right dark veil ─────────
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            stops: [0.0, 0.55, 1.0],
                            colors: [
                              _darkBase,
                              _veilMid,
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ─── Layer 3: text + CTA (left side) ──────────
                    Positioned(
                      left: 18,
                      right: cardWidth * 0.45,
                      top: 16,
                      bottom: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top row: status label + price pill.
                          Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: labelColor,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  labelText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.inter(
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w700,
                                    color: labelColor,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _C.amberGold
                                      .withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: _C.amberGold
                                        .withValues(alpha: 0.5),
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  '₹${session.price}',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _C.goldLight,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Title — max 2 lines, ellipsis on overflow.
                          Text(
                            session.title.isEmpty
                                ? 'Bible Session'
                                : session.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                          const SizedBox(height: 5),
                          // Description — line count flips based on
                          // the title's measured wrap.
                          if (session.description.isNotEmpty)
                            Flexible(
                              child: Text(
                                session.description,
                                maxLines: descMaxLines,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w400,
                                  color: Colors.white
                                      .withValues(alpha: 0.55),
                                  height: 1.35,
                                ),
                              ),
                            )
                          else
                            const Spacer(),
                          const SizedBox(height: 6),
                          // Date + time row.
                          Row(
                            children: [
                              Icon(
                                Icons.calendar_today_rounded,
                                size: 11,
                                color: _C.amberGold
                                    .withValues(alpha: 0.7),
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  session.formattedDate,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                              if (timeLabel.isNotEmpty) ...[
                                const SizedBox(width: 10),
                                Icon(
                                  Icons.schedule_rounded,
                                  size: 11,
                                  color: _C.amberGold
                                      .withValues(alpha: 0.7),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    timeLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.inter(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white
                                          .withValues(alpha: 0.7),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          // CTA — Join Now / Register Now.
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _C.amberGold,
                              borderRadius: BorderRadius.circular(7),
                              boxShadow: [
                                BoxShadow(
                                  color: _C.amberGold
                                      .withValues(alpha: 0.45),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  ctaText,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 13,
                                  color: Colors.white,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// Demo: while there are no upcoming Bible sessions, the carousel
// slot shows the welcome-offer promo banner. The artwork (2:1) is
// text-free; the overlay below renders the offer copy on the left
// half so the praying-hands illustration on the right stays visible
// on every phone. The dark veil at the left guarantees text
// legibility; a softer veil at the right mutes the bright beam so
// attention stays on the CTA.
class _BibleEmptyRail extends StatelessWidget {
  const _BibleEmptyRail();

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth - 40;
    final cacheWidth = (cardWidth * dpr).round();

    // Two-tone gold gradient on the CTA — gives the button depth
    // and the "premium card" feel rather than a flat ad button.
    const ctaTopGold = Color(0xFFEFC25C);
    const ctaBottomGold = Color(0xFFD8A246);
    const valueGold = Color(0xFFEFC25C);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/file_00000000378c71fa8bd380482da69cd1.png',
                fit: BoxFit.cover,
                cacheWidth: cacheWidth,
              ),
            ),
            // Left veil — bullet-proofs text legibility regardless
            // of where BoxFit.cover lands the image edges.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.50),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.6],
                  ),
                ),
              ),
            ),
            // Right-side dim — softens the bright top-right beam
            // ~15% so it doesn't out-pull the CTA. A real fix is
            // re-exporting the PNG with a calmer light source.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.18),
                    ],
                    stops: const [0.6, 1.0],
                  ),
                ),
              ),
            ),
            // Top-anchored text column. 18-dp top inset gives the
            // pill clear breathing room from the card edge; 14-dp
            // bottom padding keeps the CTA glow from clipping.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  // 0.46 (down from 0.52) gives ~10% more breathing
                  // room between the text block and the hands.
                  constraints: BoxConstraints(maxWidth: cardWidth * 0.46),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: _C.goldLight, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.card_giftcard_rounded,
                              color: _C.goldLight,
                              size: 10,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'WELCOME OFFER',
                              style: GoogleFonts.inter(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: _C.goldLight,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 9),
                      // Price leads — bigger and brighter (with a
                      // soft text-shadow lift) so the cost-to-value
                      // is the first thing the eye lands on.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'For ₹29',
                          maxLines: 1,
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.05,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(alpha: 0.45),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 1),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Get 100 Coins',
                          maxLines: 1,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: valueGold,
                            height: 1.15,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [ctaTopGold, ctaBottomGold],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: ctaTopGold.withValues(alpha: 0.38),
                              blurRadius: 12,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: _ClaimNowLabel(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClaimNowLabel extends StatelessWidget {
  const _ClaimNowLabel();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Claim Now',
          style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: _C.darkBrown,
          ),
        ),
        const SizedBox(width: 5),
        const Icon(
          Icons.arrow_forward_rounded,
          size: 11,
          color: _C.darkBrown,
        ),
      ],
    );
  }
}

// ─── Priest grid card ─────────────────────────────────────

// Top half: the priest's photo fills a gradient-backed rectangle
// (BoxFit.cover). If there's no photo, the gradient shows through
// with a large white initial. A subtle bottom-up gradient sits
// under the photo so the status + rating pills read against any
// photo. Bottom half is a fixed 112px so long denom/language
// strings can't push the card into overflow on a 320-wide phone.
class _PriestGridCard extends StatelessWidget {
  final SpeakerModel priest;
  final List<Color> gradient;
  final VoidCallback onTap;
  final VoidCallback onChat;
  final VoidCallback onCall;
  final VoidCallback onNotify;

  const _PriestGridCard({
    required this.priest,
    required this.gradient,
    required this.onTap,
    required this.onChat,
    required this.onCall,
    required this.onNotify,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: _C.brandBrown.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(child: _buildTop()),
            SizedBox(height: 112, child: _buildBottom()),
          ],
        ),
      ),
    );
  }

  Widget _buildTop() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Base gradient — the visual identity of the card; visible
        // on edges and fully when there's no photo.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradient,
            ),
          ),
        ),
        // Photo on top, covering the full rectangle.
        if (priest.hasPhoto)
          Positioned.fill(
            child: CachedNetworkImage(
              imageUrl: priest.photoUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => _BigInitial(priest: priest),
            ),
          )
        else
          _BigInitial(priest: priest),
        // Feathered bottom — the lower ~45% of the photo fades into
        // the card's white info panel instead of showing a hard
        // horizontal cut. The upper half is fully transparent so
        // face/subject stays crisp; from 55% downward it ramps into
        // solid surface-white, which meets the white bottom section
        // seamlessly. Matches the reference mock's blended edge.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    _C.surface.withValues(alpha: 0.55),
                    _C.surface,
                  ],
                  stops: const [0.0, 0.55, 0.85, 1.0],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 10,
          left: 10,
          child: _StatusBadge(priest: priest),
        ),
        if (priest.rating > 0)
          Positioned(
            top: 10,
            right: 10,
            child: _RatingBadge(rating: priest.rating),
          ),
      ],
    );
  }

  Widget _buildBottom() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Full names scale-down rather than ellipsis. Cards are
          // narrow; a shrunk "Dr. James Philip" reads better than
          // "Dr. James P…" with a clipped tail.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              priest.fullName,
              maxLines: 1,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _C.darkBrown,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _roleLine(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: _C.muted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _experienceLine(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: _C.muted.withValues(alpha: 0.75),
            ),
          ),
          const Spacer(),
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildActions() {
    if (priest.isAvailable) {
      return Row(
        children: [
          Expanded(
            child: _PressScale(
              onTap: onChat,
              scale: 0.95,
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _C.brandBrown, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Chat',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _C.brandBrown,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _PressScale(
              onTap: onCall,
              scale: 0.95,
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: _C.brandBrown,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Call',
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
    return _PressScale(
      onTap: onNotify,
      scale: 0.95,
      child: Container(
        width: double.infinity,
        height: 34,
        decoration: BoxDecoration(
          // Slightly stronger tint + border so the button reads as
          // tappable against the card's bottom white section. Text
          // uses darkBrown (not muted) for higher contrast — muted
          // on muted-tint was borderline under WCAG AA.
          color: _C.muted.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _C.muted.withValues(alpha: 0.22),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          'Notify me',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _C.darkBrown.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  String _roleLine() {
    if (priest.specializations.isNotEmpty) {
      return priest.specializations.first;
    }
    if (priest.denomination.isNotEmpty) return priest.denomination;
    return 'Speaker';
  }

  String _experienceLine() {
    final parts = <String>[];
    if (priest.yearsOfExperience > 0) {
      parts.add('${priest.yearsOfExperience} yrs');
    }
    if (priest.languages.isNotEmpty) {
      parts.add(priest.languages.take(2).join(', '));
    }
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}

class _BigInitial extends StatelessWidget {
  final SpeakerModel priest;
  const _BigInitial({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        priest.initial,
        style: GoogleFonts.inter(
          fontSize: 56,
          fontWeight: FontWeight.w800,
          color: Colors.white.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

// Soft translucent pill — cream-on-image instead of the dark blob.
// Reads cleanly on any of the 6 priest gradients without the
// heavy-ink feeling of black-at-25%-alpha.
class _StatusBadge extends StatelessWidget {
  final SpeakerModel priest;
  const _StatusBadge({required this.priest});

  @override
  Widget build(BuildContext context) {
    final (label, dotColor, textColor) = _spec(priest);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color, Color) _spec(SpeakerModel p) {
    if (p.isAvailable) {
      return ('Online', _C.onlineGreen, _C.darkBrown);
    }
    if (p.isOnline && p.isBusy) {
      return ('Busy', _C.busyAmber, _C.darkBrown);
    }
    return ('Offline', _C.muted, _C.muted);
  }
}

class _RatingBadge extends StatelessWidget {
  final double rating;
  const _RatingBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.star_rounded,
            size: 12,
            color: _C.amberGold,
          ),
          const SizedBox(width: 3),
          Text(
            rating.toStringAsFixed(1),
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _C.darkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shimmer placeholders ─────────────────────────────────

class _SessionsCarouselShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Match the real carousel geometry exactly so the shimmer →
    // data transition doesn't visibly shift the layout:
    //   • first card left edge = 20 (matches page gutter)
    //   • card width = viewportWidth × 0.78 (matches
    //     PageController(viewportFraction: 0.78))
    //   • right gutter 12 between cards
    final viewport = MediaQuery.of(context).size.width;
    final cardWidth = viewport * 0.78;

    return Shimmer.fromColors(
      baseColor: _C.muted.withValues(alpha: 0.14),
      highlightColor: _C.surfaceWarm,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(left: 20),
        itemCount: 3,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, _) {
          return Container(
            width: cardWidth,
            decoration: BoxDecoration(
              color: _C.muted.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(20),
            ),
          );
        },
      ),
    );
  }
}

class _PriestGridShimmer extends StatelessWidget {
  const _PriestGridShimmer();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, _) {
            return Shimmer.fromColors(
              baseColor: _C.muted.withValues(alpha: 0.14),
              highlightColor: _C.surfaceWarm,
              child: Container(
                decoration: BoxDecoration(
                  color: _C.muted.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            );
          },
          childCount: 4,
        ),
      ),
    );
  }
}
