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
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/pulsing_dot.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/shared/bloc/bible_session_cubit.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/user/home/bloc/home_cubit.dart';
import 'package:gospel_vox/features/user/home/bloc/home_state.dart';
import 'package:gospel_vox/features/user/home/pages/user_shell_page.dart';
import 'package:gospel_vox/features/user/home/widgets/priest_card.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

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

// Number of priests rendered on the Home feed before the "See all →"
// link takes over. 2 = a single row — a teaser of who's available
// without pushing the Bible Sessions section below the fold. The
// full list lives on the /user/speakers page.
const int _kHomeSpeakerLimit = 2;

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

// Filter chip definitions. A record keeps the icon + colour bound to
// the label inline so we don't drift label/icon indices apart by
// editing one list and forgetting the other. `iconColor` is reserved
// for cases (Online → green) where the icon needs to carry its own
// semantic colour; null = inherit from the chip's foreground.
typedef _FilterDef = ({
  String label,
  IconData? icon,
  Color? iconColor,
});

// Muted sage — the "online / active" tint used by the filter chip
// icon, the trust-stat dot, the explore-banner availability line.
// Aliased to AppColors.sageOnline so the home-feed shares one
// canonical online colour with every other screen in the app.
const Color _kOnlineGreen = AppColors.sageOnline;

// Compact count formatter — keeps marketplace-scale CTA copy
// single-line at any catalogue size. Uses Indian K/L/Cr suffixes
// (the speaker catalogue is India-rooted) so a one-lakh-speaker
// row reads "1L" instead of forcing the banner to ellipsis.
//
//   42       → "42"
//   1234     → "1.2k"
//   12345    → "12k"
//   100000   → "1L"
//   1234567  → "12L"
//   12345678 → "1.2Cr"
String _compactCount(int n) {
  String trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (n < 1000) return n.toString();
  if (n < 100000) {
    final v = n / 1000;
    return v < 10 ? '${trim(v)}k' : '${v.round()}k';
  }
  if (n < 10000000) {
    final v = n / 100000;
    return v < 10 ? '${trim(v)}L' : '${v.round()}L';
  }
  return '${trim(n / 10000000)}Cr';
}

const List<_FilterDef> _kFilterChips = <_FilterDef>[
  (label: 'All', icon: null, iconColor: null),
  (label: 'Online', icon: AppIcons.wifi, iconColor: _kOnlineGreen),
  (label: 'Priests', icon: AppIcons.userOutline, iconColor: null),
  (label: 'Pastors', icon: AppIcons.add, iconColor: null),
  (
    label: 'Counsellors',
    icon: AppIcons.chatOutline,
    iconColor: null,
  ),
  (label: 'Bible Teachers', icon: AppIcons.bible, iconColor: null),
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
  // viewportFraction 1.0 shows one full banner at a time with no
  // peek of the next card — cleaner premium feel. The horizontal
  // gutter is moved inside each card (EdgeInsets.symmetric on the
  // builder) instead of being created by a sub-1.0 fraction.
  final PageController _carouselController = PageController();

  // Auto-scroll timer for the Bible-Sessions carousel. Advances one
  // page every 5 seconds, paused while the user is dragging and
  // resumed when their drag finishes (see NotificationListener in
  // _buildSessionsSection). Restarted from scratch on every restart
  // so the user always gets a fresh 5-second dwell on a card they
  // just settled on.
  Timer? _autoScrollTimer;

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
    // Available-now label appears before the Bible Sessions section
    // in the visual stack now, so its fade-in beats the carousel's.
    _gridLabelAnim = _interval(0.22, 0.62);
    _sessionsAnim = _interval(0.32, 0.7);
    _animController.forward();

    _startBibleStream();

    // Fire-and-forget warm-up of the coin-pack list so a low-balance
    // RechargeSheet opens with instant content the first time the user
    // taps Call from the home feed. Result is cached at the repository
    // layer; if the user never triggers the sheet, the cost is one
    // small Firestore read at page mount.
    try {
      sl<WalletRepository>().getCoinPacks();
    } catch (_) {
      // Silent — pre-warm is best-effort.
    }

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

    // Kick the auto-scroll loop. Safe to call repeatedly — each call
    // cancels the previous timer first. We restart whenever the
    // stream emits so a sessions list that grows from 1 → 2+ items
    // begins rotating without needing a page rebuild.
    _startAutoScroll();

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

  // Starts (or restarts) the carousel's 5-second auto-advance timer.
  // Called from _onBibleSnap once the first batch lands, and from
  // the swipe handler after the user lets go. Safe to call when
  // there's nothing to scroll — the periodic tick early-returns.
  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (!_carouselController.hasClients) return;
      final total = _bibleSessions.length;
      if (total <= 1) return;
      final current = _carouselController.page?.round() ?? _carouselIndex;
      final next = (current + 1) % total;
      _carouselController.animateToPage(
        next,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  // Cancels the auto-advance timer. Called when the user starts a
  // manual drag so we don't yank the carousel out from under them
  // mid-gesture. Resumed via _startAutoScroll once the drag settles.
  void _pauseAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
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
    _autoScrollTimer?.cancel();
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

  String _getGreetingEmoji() {
    final hour = DateTime.now().hour;
    if (hour < 17) return '☀️';
    return '🌙';
  }

  // First name only — longer "first + middle + last" strings would
  // crowd the headline, and the ellipsis fallback below also bites
  // before that case becomes interesting. Empty / null display names
  // fall back to "there" so the headline still reads as a greeting.
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

  // Mirror of priest_profile_page._requestSession. SessionPreflight
  // intercepts insufficient-balance cases with a contextual
  // RechargeSheet ("Add ₹X more to start your chat with Fr. Y")
  // instead of letting the user reach the waiting page only to
  // bounce off a generic snackbar from the CF.
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
      // Page-level tap-to-dismiss for the keyboard. translucent so
      // taps still reach cards/chips/buttons underneath; the handler
      // only fires for surface taps and unfocuses whatever currently
      // owns focus. Keeps the keyboard from sticking around after a
      // user taps a priest card mid-typing.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: BlocConsumer<HomeCubit, HomeState>(
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
              // Dragging the list down also clears the keyboard —
              // belt-and-braces with the page-level GestureDetector
              // since RefreshIndicator may consume some pointer events.
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                _animatedSliver(_heroAnim, _buildTopHero()),
                _animatedSliver(_chipsAnim, _buildFilterChips()),
                // Available now first — the hero discovery rail of
                // the feed. Bible Sessions follows below as a
                // recurring secondary entry-point.
                _animatedSliver(
                  _gridLabelAnim,
                  _buildAvailableNowLabel(state),
                ),
                _buildBody(state),
                // Eye-magnet CTA — breaks the gestalt-closure of the
                // 2-card grid above with stacked priest faces +
                // concrete count + one-shot gold-pulse on first
                // paint. Hidden by _buildExploreBanner itself when
                // the total available count is <= the on-screen
                // preview, so it never lies.
                _animatedSliver(_gridLabelAnim, _buildExploreBanner(state)),
                _animatedSliver(_sessionsAnim, _buildSessionsSection(state)),
                // Trust-signals card — lives at the end of the feed
                // as a "why-this-app" reassurance pad after the
                // primary content. Reads `availablePriests.length`
                // off the existing HomeLoaded state, so no extra
                // stream / network call is introduced.
                SliverToBoxAdapter(child: _buildTrustStats(state)),
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
          );
        },
        ),
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

  // ─── Top hero (flat bg + headline + search) ───────────

  Widget _buildTopHero() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeaderRow(),

          ],
        ),
      ),
    );
  }

  Widget _buildHeaderRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _getGreeting(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _getGreetingEmoji(),
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // Single-line "Hi, {firstName}" — ellipsises on long
              // names so the header never grows past one row of
              // typography. Smaller font than the previous two-line
              // tagline so the trust-stats + grid below get more
              // vertical breathing room.
              Text(
                'Hi, ${_getFirstName()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // Trailing actions sit nudged down 2 px so they centre on the
        // headline's first line rather than floating above it.
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NotificationBell(
                // Live unread count is streamed inside the bell from
                // the `notifications` collection — we pass the uid so
                // the StreamBuilder can subscribe; if the user is
                // signed out, the bell falls back to a bare glyph.
                uid: FirebaseAuth.instance.currentUser?.uid,
                onTap: () => context.push('/user/notifications'),
              ),
              const SizedBox(width: 14),
              _BalancePill(onTap: _switchToWalletTab),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.borderLight, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        // Tapping anywhere outside the field dismisses the keyboard
        // before the underlying tap fires its own handler (e.g. a
        // priest-card push). Without this, a user mid-typing who
        // tapped a card would land on the profile with the keyboard
        // still visible.
        onTapOutside: (_) =>
            FocusManager.instance.primaryFocus?.unfocus(),
        onChanged: (q) {
          context.read<HomeCubit>().search(q);
          setState(() {});
        },
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: AppColors.deepDarkBrown,
        ),
        decoration: InputDecoration(
          hintText: 'Search priests, language, topic...',
          hintStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: _C.muted.withValues(alpha: 0.7),
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: AppIcon(
              AppIcons.search,
              size: 22,
              color: _C.muted.withValues(alpha: 0.75),
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
                    child: AppIcon(
                      AppIcons.close,
                      size: 18,
                      color: _C.muted,
                    ),
                  ),
                ),
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 15),
        ),
      ),
    );
  }

  // ─── Filter chips ─────────────────────────────────────

  Widget _buildFilterChips() {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: SizedBox(
        // Outer strip trimmed to 38 so the chip's 32 px body has
        // 3 px breathing room above and below — claws back ~10 px
        // of vertical space across the page.
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: _kFilterChips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final def = _kFilterChips[i];
            return _FilterChip(
              label: def.label,
              icon: def.icon,
              iconColor: def.iconColor,
              isActive: _activeFilter == def.label,
              onTap: () => setState(() => _activeFilter = def.label),
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
          title: 'Bible sessions',
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
          // 140 — trimmed 20 px versus the previous 160. The
          // banner's internal top/bottom padding drops from 18 to 14
          // (see _BibleSessionBanner), so the status row + 2-line
          // title + date·price row still fit with ~6 px of safety
          // margin on the longest content.
          height: 140,
          child: showShimmer
              ? _SessionsCarouselShimmer()
              : sessions.isEmpty
                  ? const _BibleEmptyRail()
                  // viewportFraction is 1.0 (default) — one full
                  // banner per viewport, no peek of the next card.
                  // The 20-px horizontal gutter is applied inside
                  // each itemBuilder so it travels with the card.
                  //
                  // NotificationListener pauses the auto-scroll
                  // timer while the user is actively dragging
                  // (dragDetails != null on ScrollStartNotification)
                  // and resumes it on ScrollEndNotification. A
                  // programmatic animateToPage also fires those
                  // notifications, but with dragDetails == null, so
                  // it doesn't accidentally trigger the pause path.
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n is ScrollStartNotification &&
                            n.dragDetails != null) {
                          _pauseAutoScroll();
                        } else if (n is ScrollEndNotification) {
                          _startAutoScroll();
                        }
                        return false;
                      },
                      child: PageView.builder(
                        controller: _carouselController,
                        physics: const BouncingScrollPhysics(),
                        itemCount: sessions.length,
                        // No setState — the indicator subscribes to
                        // _carouselController directly and morphs in
                        // lockstep with the actual scroll position.
                        // Skipping the rebuild keeps the page slide
                        // frame-rate clean on lower-end devices.
                        onPageChanged: (i) => _carouselIndex = i,
                        itemBuilder: (_, i) {
                          final session = sessions[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
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
        ),
        const SizedBox(height: 14),
        if (!showShimmer && dotCount > 1)
          // AnimatedBuilder ticks once per frame while the PageView
          // is scrolling (auto-advance or finger drag) and stays
          // idle otherwise. We read the continuous fractional page
          // from the controller and interpolate each dot's width
          // and colour from that — so the pill morph is locked
          // 1:1 to the actual banner motion, with zero duration
          // mismatch and no implicit-animation catch-up.
          AnimatedBuilder(
            animation: _carouselController,
            builder: (_, _) {
              final page = _carouselController.hasClients
                  ? (_carouselController.page ?? _carouselIndex.toDouble())
                  : _carouselIndex.toDouble();
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(dotCount, (i) {
                  // t = 1.0 on the active dot, 0.0 on dots ≥1 page
                  // away. Fractional during a swipe, which is what
                  // gives the smooth shrink/grow handoff between
                  // neighbours.
                  final t = (1.0 - (page - i).abs()).clamp(0.0, 1.0);
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 6.0 + 18.0 * t,
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(100),
                      color: Color.lerp(
                        AppColors.muted.withValues(alpha: 0.3),
                        AppColors.deepDarkBrown,
                        t,
                      ),
                    ),
                  );
                }),
              );
            },
          ),
      ],
    );
  }

  // Trust-banner card pinned to the bottom of the home feed. Single
  // calm composition designed around the "show less, prove more"
  // principle from the UX audit:
  //
  //   • One radius (24), one elevation (subtle drop shadow), no
  //     internal pill containers, no dividers, no decorative chrome.
  //   • Background is assets/trusted banner.png — the warm-beige
  //     plate with the church silhouette on the right. A strong
  //     warm wash pulls the church back to ambient brightness so
  //     it stops competing with the content.
  //   • Content reads in one second: title, social-proof line,
  //     benefit summary, three plain trust labels.
  //
  // Card height is natural (driven by the content) rather than a
  // forced 3:2 ratio — the previous fixed-ratio approach was the
  // root cause of the cramped pills + truncated labels in the
  // earlier draft. The background image fills whatever height the
  // content demands; BoxFit.cover + centerRight keeps the church
  // visible across phone widths.
  //
  // `state` is no longer read — the card is pure reassurance copy.
  // Kept in the signature so the call site in `slivers` doesn't
  // need to change.
  Widget _buildTrustStats(HomeState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6B3F22).withValues(alpha: 0.10),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  'assets/trusted banner.png',
                  fit: BoxFit.cover,
                  alignment: Alignment.centerRight,
                ),
              ),
              // Left-to-right warm wash. Strong on the left where the
              // copy lives, fading to near-zero on the right so the
              // church silhouette stays visible as real artwork.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      stops: const [0.0, 0.55, 1.0],
                      colors: [
                        const Color(0xFFFAF1E6).withValues(alpha: 0.92),
                        const Color(0xFFF6E6D3).withValues(alpha: 0.55),
                        const Color(0xFFF6E6D3).withValues(alpha: 0.10),
                      ],
                    ),
                  ),
                ),
              ),
              // Sun-glow radiating from the top-right corner, matching
              // the actual sunbeam direction baked into the PNG.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.75, -0.5),
                      radius: 1.3,
                      stops: const [0.0, 0.7],
                      colors: [
                        const Color(0xFFFFE6B0).withValues(alpha: 0.28),
                        const Color(0xFFFFE6B0).withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(20),
                child: _TrustBannerContent(),
              ),
              // Hairline inner border — keeps the card edge crisp
              // against the warm home-feed background.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _kTrustHairlineGold.withValues(alpha: 0.45),
                        width: 0.6,
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

  Widget _buildAvailableNowLabel(HomeState state) {
    // Title-only header — the inline count was tested and pulled.
    // The header carries its own pill-styled "See all" so users who
    // scan top-of-section have an immediate exit to the full
    // catalogue. The loud _ExploreBanner below the grid is still
    // the primary discovery CTA — the header pill is a secondary
    // shortcut, deliberately smaller in visual weight.
    return _SectionHeader(
      title: 'Available now',
      onSeeAll: () => context.push('/user/speakers'),
    );
  }

  // Full-width "explore all priests" CTA shown directly below the
  // 2-card grid. Self-hides when there's nothing more to discover
  // (total visible count <= the on-screen preview slot) so the
  // banner never lies about scale.
  Widget _buildExploreBanner(HomeState state) {
    if (state is! HomeLoaded) return const SizedBox.shrink();
    final visible = _visiblePriests(state);
    if (visible.length <= _kHomeSpeakerLimit) {
      return const SizedBox.shrink();
    }
    return _ExploreBanner(
      priests: visible,
      onTap: () => context.push('/user/speakers'),
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
    // Cap to the home preview slot count. The "See all →" link on
    // the section header opens /user/speakers which renders the full
    // filtered list without this cap.
    final visible =
        _visiblePriests(loaded).take(_kHomeSpeakerLimit).toList();

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
          // 0.72 keeps the photo as the hero element while leaving
          // tight room for: name + expertise tag + 30-px Call/Chat
          // row. Cards read as compact tiles instead of tall posters,
          // so the Bible Sessions section below stays visible without
          // the user needing to scroll twice.
          childAspectRatio: 0.72,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) {
            final priest = visible[i];
            return PriestCard(
              priest: priest,
              gradient:
                  kPriestGradients[i % kPriestGradients.length],
              onTap: () => _openProfile(priest.uid),
              onCall: () => _startSession(priest, 'voice'),
              onChat: () => _startSession(priest, 'chat'),
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
            child: AppIcon(
              hasSearch || hasChip
                  ? AppIcons.search
                  : AppIcons.users,
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

// Shared press affordance for every tappable surface on the home stack.
// Scales + fades opacity in lockstep so the pressed state reads as one
// consistent tactile gesture — replaces the dozen ad-hoc Listener +
// AnimatedScale combinations that drifted apart over time.
//
// Both effects use the same 150 ms easeOut curve; AnimatedOpacity inside
// AnimatedScale is harmless (compositor handles both transforms in the
// same frame) and stays cheap because we only repaint on the actual
// state transitions, not every frame.
class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const _PressScale({
    required this.child,
    required this.onTap,
    this.scale = 0.97,
  });

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _enabled ? (_) => _setPressed(true) : null,
      onPointerUp: _enabled ? (_) => _setPressed(false) : null,
      onPointerCancel: _enabled ? (_) => _setPressed(false) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? widget.scale : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _pressed ? 0.85 : 1.0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// ─── Section header ───────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  // Nullable so sections that already surface a dedicated CTA (e.g.
  // the Available-now grid, which has its own full-width Explore
  // banner below the cards) can render title-only without a
  // competing tertiary link in the header.
  final VoidCallback? onSeeAll;
  final Widget? trailing;

  const _SectionHeader({
    required this.title,
    this.onSeeAll,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 0, 14),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                // Weight pulled back from w700 → w600 to fit the
                // limited-weight palette (400 / 600 / 700) — the
                // single 700 per screen is reserved for hero copy,
                // not every section header.
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
          const Spacer(),
          if (onSeeAll != null)
            _PressScale(
              onTap: onSeeAll!,
              scale: 0.94,
              // Solid brown pill with gold text + arrow — a
              // "mini version" of the _ExploreBanner that mirrors
              // its colour story (brown shell, gold content). A
              // single filled surface beats an outlined chip here:
              // no border to read as a loose rectangle, no
              // free-floating circle to compete with the banner's
              // larger gold disc.
              //
              // Subtle gold-tinted drop shadow gives the pill a
              // touch of depth so it lifts cleanly off the warm
              // parchment background.
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
                decoration: BoxDecoration(
                  color: _C.brandBrown,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: _C.brandBrown.withValues(alpha: 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'See all',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.1,
                        color: _C.goldLight,
                      ),
                    ),
                    const SizedBox(width: 5),
                    const AppIcon(
                      AppIcons.arrowRight,
                      size: 14,
                      color: _C.goldLight,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Explore-all CTA banner ───────────────────────────────
//
// Full-width hero CTA injected directly below the 2-card grid.
// The grid above is a gestalt-closed unit; without a strong
// signal below, the brain reads "2 priests = total". This
// banner breaks the closure with three independent attention
// triggers stacked at the eye's natural F-pattern landing
// zone:
//
//   1. Stacked priest faces — the fusiform face area
//      pre-attentively processes faces ~170ms before text.
//   2. Concrete count — specificity heuristic / anchoring
//      converts an abstract "more" into a tangible quantity.
//   3. One-shot scale + gold-halo pulse on first paint —
//      pre-attentive motion cue without loop fatigue.
//
// Background is brandBrown on the parchment surface, giving
// it the highest contrast of any band on the page so it owns
// the eye on landing without needing chrome or shouting copy.
class _ExploreBanner extends StatefulWidget {
  final List<SpeakerModel> priests;
  final VoidCallback onTap;

  const _ExploreBanner({
    required this.priests,
    required this.onTap,
  });

  @override
  State<_ExploreBanner> createState() => _ExploreBannerState();
}

class _ExploreBannerState extends State<_ExploreBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    // Fire once on first paint so the eye registers the CTA on
    // landing. No reverse, no loop — pre-attentive cue, not
    // ongoing visual noise.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pulse.forward();
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.priests.length;
    final onlineCount =
        widget.priests.where((p) => p.isAvailable).length;
    final avatarPriests = widget.priests.take(4).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) {
          final t = _pulse.value;
          // Scale settles inside the first 30% of the timeline,
          // then holds at 1.0 for the rest of the run.
          final scaleT =
              Curves.easeOutBack.transform((t / 0.3).clamp(0.0, 1.0));
          final scale = 0.96 + (1.0 - 0.96) * scaleT;
          // Triangle halo opacity — ramps up over the first half,
          // ramps back to 0 over the second half. Peak ~0.55 is
          // enough to read as a glow without overpowering the
          // surrounding parchment surface.
          final haloOpacity = t < 0.5 ? t * 2 * 0.55 : (1.0 - t) * 2 * 0.55;
          return Transform.scale(
            scale: scale,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: _C.brandBrown.withValues(alpha: 0.18),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                  BoxShadow(
                    color: _C.goldLight.withValues(alpha: haloOpacity),
                    blurRadius: 22,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: child,
            ),
          );
        },
        child: Material(
          color: _C.brandBrown,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            splashColor: _C.goldLight.withValues(alpha: 0.18),
            highlightColor: _C.goldLight.withValues(alpha: 0.06),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
              child: Row(
                children: [
                  _AvatarStack(priests: avatarPriests),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // FittedBox.scaleDown auto-shrinks the
                        // headline when the count widens the
                        // string past the available width. The
                        // combo that actually works in a Column-
                        // in-Expanded layout:
                        //   • SizedBox gives FittedBox a hard
                        //     max width = available column width
                        //     (without it FittedBox can inherit
                        //     an unbounded constraint from the
                        //     Column's intrinsic-sizing pass).
                        //   • softWrap: false stops Text from
                        //     wrapping at the column's natural
                        //     width before FittedBox sees it.
                        //   • no `overflow` set, so even if some
                        //     edge case bypasses FittedBox the
                        //     fallback is clip, never "...".
                        SizedBox(
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Meet all ${_compactCount(total)} speakers',
                              softWrap: false,
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: const Color(0xFFFBF7F2),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        if (onlineCount > 0)
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: _kOnlineGreen,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '${_compactCount(onlineCount)} online right now',
                                    softWrap: false,
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: _C.goldLight,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        else
                          SizedBox(
                            width: double.infinity,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Tap to browse profiles',
                                softWrap: false,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: _C.goldLight,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [_C.goldLight, _C.amberGold],
                      ),
                    ),
                    child: const AppIcon(
                      AppIcons.arrowRight,
                      size: 22,
                      color: _C.brandBrown,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Overlapping circular avatars used inside _ExploreBanner. Borders
// are painted in the banner's background colour so adjacent avatars
// get a clean visual gap where they overlap.
class _AvatarStack extends StatelessWidget {
  final List<SpeakerModel> priests;
  const _AvatarStack({required this.priests});

  @override
  Widget build(BuildContext context) {
    const size = 28.0;
    const overlap = 10.0;
    final count = priests.length;
    if (count == 0) return const SizedBox.shrink();
    final width = size + (count - 1) * (size - overlap);
    return SizedBox(
      width: width,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < count; i++)
            Positioned(
              left: i * (size - overlap),
              child: _Avatar(
                priest: priests[i],
                gradient: kPriestGradients[i % kPriestGradients.length],
                size: size,
              ),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final SpeakerModel priest;
  final List<Color> gradient;
  final double size;
  const _Avatar({
    required this.priest,
    required this.gradient,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        priest.initial,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
    // Three-layer ring: gold outer band + cream inner gap + image.
    // The gold band signals "platform-vetted speaker" without
    // overloading any single brand colour, and the cream gap separates
    // the gold from the photo so the ring reads cleanly even when the
    // avatar image is light-toned.
    //
    // Sizes are deliberately conservative (1.5 px ring + 1 px gap) for
    // these compact 28 px stack avatars — at this scale, anything
    // thicker would eat too much of the face area. The same treatment
    // can be applied at a larger scale on detail pages.
    //
    // ClipOval guarantees a perfect circular clip on the image — the
    // `Container(shape: circle) + clipBehavior` combo sometimes
    // renders a polygonal silhouette on certain pixel ratios.
    const goldRing = 1.5;
    const creamGap = 1.0;
    return Container(
      width: size,
      height: size,
      // Outer gold band.
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.amberGold,
      ),
      child: Padding(
        padding: const EdgeInsets.all(goldRing),
        // Cream gap layer.
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.surfaceCream,
          ),
          padding: const EdgeInsets.all(creamGap),
          child: ClipOval(
            child: priest.hasPhoto
                ? CachedNetworkImage(
                    imageUrl: priest.photoUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => fallback,
                    errorWidget: (_, _, _) => fallback,
                  )
                : fallback,
          ),
        ),
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

// Bell + live unread badge for the user home header.
//
// Streams `notifications` filtered by uid + isRead==false so the badge
// reflects the same data the notifications page reads. The badge is a
// stadium-shaped (pill) container — fixed height, expanding horizontally
// for 1 → 9 → 99+ — with a 1.5 px cream cutout border that lets it
// "punch" out of the bell silhouette behind it.
//
// Stream is mounted lazily inside the build only when `uid` is non-null,
// so signed-out states (rare on this page, but defensible) never hold a
// Firestore subscription open.
class _NotificationBell extends StatelessWidget {
  final VoidCallback onTap;
  final String? uid;

  const _NotificationBell({
    required this.onTap,
    this.uid,
  });

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return _PressScale(
        onTap: onTap,
        scale: 0.92,
        child: const _BellGlyph(count: 0),
      );
    }
    return _PressScale(
      onTap: onTap,
      scale: 0.92,
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        // Snapshot identical in shape to the priest dashboard bell — the
        // home and priest sides share the `notifications` collection
        // contract so the same query reads correctly for both roles.
        stream: FirebaseFirestore.instance
            .collection('notifications')
            .where('userId', isEqualTo: uid)
            .where('isRead', isEqualTo: false)
            .snapshots(),
        builder: (_, snap) {
          final count = snap.data?.docs.length ?? 0;
          return _BellGlyph(count: count);
        },
      ),
    );
  }
}

// Pure-paint widget — no state, no controllers — that draws the bell
// glyph and (when count > 0) the pill badge over its top-right corner.
// Stack uses Clip.none so the badge spills outside the 30×28 bounding
// box without being chopped by the surrounding header row layout.
class _BellGlyph extends StatelessWidget {
  final int count;
  const _BellGlyph({required this.count});

  @override
  Widget build(BuildContext context) {
    final show = count > 0;
    return SizedBox(
      width: 30,
      height: 28,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          const AppIcon(
            AppIcons.bellOutline,
            size: 26,
            color: AppColors.deepDarkBrown,
          ),
          if (show)
            Positioned(
              top: -3,
              right: -4,
              // Growing-stadium badge — the recipe that gives both
              // shapes from one widget:
              //   • minWidth == minHeight == 18 → a single-digit
              //     count ("1", "9") renders as a perfect 18×18
              //     circle because the symmetric constraint and the
              //     borderRadius (height/2 = 9) make the ends fully
              //     round.
              //   • As digits are added, horizontal padding lets the
              //     container widen past 18; the borderRadius stays
              //     at 9, so the ends stay perfectly rounded — the
              //     badge morphs from circle → pill without ever
              //     letting the text overflow the surface.
              //   • Counts ≥100 collapse to "99+" so the badge never
              //     widens past ~3 glyphs (~30 px) and keeps a clean
              //     stadium look even at marketplace scale.
              child: Container(
                constraints: const BoxConstraints(
                  minWidth: 18,
                  minHeight: 18,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  // Warm terra-cotta sits in the parchment palette
                  // instead of fighting it the way a bright #CC0000
                  // would. Same colour the priest dashboard uses for
                  // its bell badge so the two surfaces feel like one
                  // system.
                  color: AppColors.terraCotta,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Text(
                  count > 99 ? '99+' : '$count',
                  maxLines: 1,
                  softWrap: false,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1.05,
                    // Tabular figures keep digit widths constant so
                    // the morph from circle → pill happens cleanly
                    // and reads consistently as counts roll over.
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
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
      scale: 0.95,
      child: Container(
        height: 40,
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
        decoration: BoxDecoration(
          color: _C.surface,
          // Unified 20-radius family — coin pill, search, chips,
          // speaker cards, Bible banners, trust card all share
          // this radius so the home feed reads as one design
          // system instead of a patchwork.
          borderRadius: BorderRadius.circular(AppRadius.large),
          // Warm two-layer shadow — matches the rest of the cards on
          // the home feed instead of the previous flat black drop.
          boxShadow: kWarmCardShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Gold coin glyph — 24px disc with a 2-stop gold gradient
            // (lighter top-left → deeper bottom-right) instead of the
            // previous flat amber. Gradient gives the disc subtle
            // dimensionality so it reads as a minted token, not a
            // sticker.
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.coinGoldLight,
                    AppColors.coinGoldDeep,
                  ],
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                r'$',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.0,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Cap the numeric width and scale down when bigger —
            // "10440" shouldn't push the pill so wide that it
            // crushes the greeting. Upper bound keeps the pill
            // visually stable.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 60),
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
            const SizedBox(width: 8),
            // Explicit "+ add" affordance — replaces the prior
            // chevron-right with a thin outlined circle holding a
            // small plus glyph. The outlined treatment stays lighter
            // than the previous filled brown circle the chevron was
            // brought in to escape, while still reading clearly as
            // "add money" rather than "drill in to wallet".
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.deepDarkBrown.withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              alignment: Alignment.center,
              child: const AppIcon(
                AppIcons.add,
                size: 13,
                color: AppColors.deepDarkBrown,
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
          fontWeight: FontWeight.w700,
          color: _C.darkBrown,
          // Tabular figures so the pill width doesn't twitch as the
          // balance changes between e.g. "199" → "200" mid-transaction.
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
}

// ─── Filter chip ──────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  // Optional semantic colour for the icon (e.g., green for "Online")
  // that's preserved on the inactive chip but overridden to white
  // when the chip is active — colour is reserved for state on the
  // active chip, so we mute the green there to avoid a fight.
  final Color? iconColor;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isActive ? Colors.white : AppColors.deepDarkBrown;
    // On the active chip we want the icon to read as part of the
    // chip, not as its own semantic accent — so the colour collapses
    // to plain white.
    final resolvedIconColor =
        isActive ? Colors.white : (iconColor ?? fg);

    return _PressScale(
      onTap: onTap,
      scale: 0.95,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 32,
        padding: EdgeInsets.symmetric(
          horizontal: icon == null ? 16 : 12,
        ),
        decoration: BoxDecoration(
          // Active chip uses a top-down gradient — slight white sheen
          // at the very top edge fades into the base brown by 50% of
          // the height. Reads as a subtle embossed / tactile surface
          // rather than the previous flat fill. Inactive chips stay
          // on a solid surface so they don't compete for attention.
          gradient: isActive
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, 0.5],
                  colors: [
                    // 10% white over the brown gives the embossed
                    // top edge effect without lightening the body.
                    Color(0xFF4A2D1C),
                    AppColors.deepDarkBrown,
                  ],
                )
              : null,
          color: isActive ? null : AppColors.surfaceWhite,
          // Stadium shape — height/2 = 16 so the chip ends are fully
          // rounded. Matches the locked radius scale's "full rounded
          // → filter chips" rule.
          borderRadius: BorderRadius.circular(16),
          border: isActive
              ? null
              : Border.all(color: AppColors.borderLight, width: 0.5),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: AppColors.deepDarkBrown.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              AppIcon(icon, size: 15, color: resolvedIconColor),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                // Both states at w600 — colour does the active/inactive
                // work. Mixing w500/w600 made the active chip feel
                // disproportionately heavier than its neighbours.
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
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
    final labelText = isLive ? 'LIVE NOW' : 'UPCOMING';
    final dotColor = isLive ? _liveRed : _C.amberGold;
    final labelColor = isLive ? _liveRed : _C.amberGold;
    final timeLabel = session.formattedTime.isEmpty
        ? session.formattedDate
        : '${session.formattedDate} · ${session.formattedTime}';
    final ctaLabel = _ctaLabel(session);
    final displayTitle =
        session.title.isEmpty ? 'Bible Session' : session.title;

    return _PressScale(
      onTap: onTap,
      scale: 0.97,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ─── Layer 1: full-bleed category artwork ───────────
              // BoxFit.cover fills the whole banner with the image
              // — no painted gradient base; the artwork itself is
              // the background. gaplessPlayback + initState precache
              // keep the first paint flash-free.
              Image.asset(
                _bannerImage(session.category),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, wasSyncLoaded) {
                  if (wasSyncLoaded || frame != null) return child;
                  // Show a near-black fill while the asset decodes
                  // so the white scaffold never flashes through.
                  return const ColoredBox(color: Color(0xFF1A0E08));
                },
              ),

              // ─── Layer 2: left-heavy dark veil ──────────────────
              // Black → translucent gradient from left to right.
              // Anchors text legibility on the left while leaving
              // the artwork breathing room on the right where the
              // visual focus of the image typically sits.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      stops: const [0.0, 0.55, 1.0],
                      colors: [
                        Colors.black.withValues(alpha: 0.78),
                        Colors.black.withValues(alpha: 0.45),
                        Colors.black.withValues(alpha: 0.10),
                      ],
                    ),
                  ),
                ),
              ),

              // ─── Layer 3: content (left ~60% column) ────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Text column owns the left 3/5 of the banner.
                    // The Spacer on the right keeps the artwork's
                    // focal point unobscured.
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Top block: label + title sit together.
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: dotColor,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      labelText,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.inter(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: labelColor,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                displayTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  height: 1.12,
                                  letterSpacing: -0.3,
                                ),
                              ),
                            ],
                          ),
                          // Bottom block: date·time line + CTA pill.
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  AppIcon(
                                    AppIcons.calendar,
                                    size: 10,
                                    color: Colors.white
                                        .withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      timeLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.white
                                            .withValues(alpha: 0.75),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _RegisterPill(label: ctaLabel),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Spacer reserves the right 2/5 of the banner for
                    // the artwork's focal point. No widget here —
                    // just dead space so the text column never runs
                    // into the visual centre of the image.
                    const Spacer(flex: 2),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // CTA label resolves to one of two states:
  //   • live session   → "Join Now"
  //   • upcoming       → "Register for Free"
  // Price is intentionally NOT surfaced on the banner — the price
  // belongs on the detail page, where the user actually commits.
  // Showing price here turned the CTA into a value-judgement
  // ("₹50? worth it?") before the user had any context.
  String _ctaLabel(BibleSessionModel s) {
    if (s.isLive) return 'Join Now';
    return 'Register for Free';
  }

}

// Small gold pill used as the banner's CTA. Gold fill, dark text,
// no trailing arrow — the whole banner is tappable, so a chrome
// arrow on the pill was redundant. Tap routing stays on the parent
// banner's onTap; this widget is purely visual.
class _RegisterPill extends StatelessWidget {
  final String label;
  const _RegisterPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _C.amberGold,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: _C.amberGold.withValues(alpha: 0.4),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.deepDarkBrown,
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
            // Top-anchored text column. Tightened to 14/12 to fit
            // the carousel's reduced 140-px parent height — leaves
            // ~6 px of safety margin below the CTA before clipping.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
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
                            const AppIcon(
                              AppIcons.gift,
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
        const AppIcon(
          AppIcons.arrowRight,
          size: 11,
          color: _C.darkBrown,
        ),
      ],
    );
  }
}

// ─── Priest grid card ─────────────────────────────────────

// ─── Trust banner ─────────────────────────────────────────
//
// Premium reassurance card. Four-band layout:
//   1. Header  — gold medal + title + sub
//   2. Rating  — 4.9 ★ + slim divider + social proof
//   3. Service — Prayer · Healing · Spiritual support (gold bullets)
//   4. Tags    — inline icon-labels (Verified / Private / Biblical)
//
// Colour palette (intentionally tight — three brown shades + gold):
//   • _kTrustInkDeep  — primary headline ink, warmest deep brown
//   • _kTrustInkSoft  — softer brown for service trio
//   • _kTrustInkMuted — warm gray-brown for secondary copy
//   • _kTrustGold     — accent gold (star + bullet dots)
//   • _kTrustBrown    — solid brown used by tag icons / cross glyph
//   • _kTrustGoldLight — radial-highlight pole of the medal gradient
const Color _kTrustBrown = Color(0xFF6B3F22);
const Color _kTrustGold = Color(0xFFD8A246);
const Color _kTrustGoldLight = Color(0xFFEFC25C);
const Color _kTrustInkDeep = Color(0xFF2B1810);
const Color _kTrustInkMuted = Color(0xFF8A6B5C);
const Color _kTrustHairlineGold = Color(0xFFD8B98A);

class _TrustBannerContent extends StatelessWidget {
  const _TrustBannerContent();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Band 1: header (medal | divider | title block) ──
        // IntrinsicHeight lets the vertical divider match the
        // tallest sibling's height. Title is allowed to wrap to
        // two lines like the reference ("Trusted spiritual /
        // guidance"); subtitle stays one line.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: _TrustMedal(size: 42)),
              const SizedBox(width: 14),
              Container(
                width: 1,
                margin: const EdgeInsets.symmetric(vertical: 2),
                color: _kTrustHairlineGold.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Trusted spiritual guidance',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        letterSpacing: -0.3,
                        color: _kTrustInkDeep,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Verified priests & pastors',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: _kTrustInkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Horizontal hairline directly under the header.
        Container(
          height: 0.7,
          color: _kTrustHairlineGold.withValues(alpha: 0.55),
        ),
        const SizedBox(height: 14),
        // ── Band 2: two-column body ──
        // Left: praying-hands glyph + short benefit copy.
        // Right: 4.9 ★ rating block.
        // Vertical hairline between them mirrors the reference.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 6,
                // Typographic tagline replaces the gospelvox SVG —
                // the symbol read as visual noise at 48 px and pushed
                // the paragraph into a narrow gutter. Three-line
                // statement with a gold accent on the closing word
                // ("anywhere.") that mirrors the ★ on the right
                // column. Each line is a single word, so wrapping is
                // deterministic at every phone width — no ellipsis.
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Spiritual',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        letterSpacing: -0.4,
                        color: _kTrustInkDeep,
                      ),
                    ),
                    Text(
                      'guidance,',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        letterSpacing: -0.4,
                        color: _kTrustInkDeep,
                      ),
                    ),
                    Text(
                      'anywhere.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        letterSpacing: -0.4,
                        color: _kTrustGold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Prayer  ·  Healing  ·  Care',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: _kTrustInkMuted,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 0.7,
                margin: const EdgeInsets.symmetric(vertical: 4),
                color: _kTrustHairlineGold.withValues(alpha: 0.55),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            '4.9',
                            style: GoogleFonts.inter(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              height: 1.0,
                              letterSpacing: -0.8,
                              color: _kTrustInkDeep,
                            ),
                          ),
                          const SizedBox(width: 5),
                          const AppIcon(
                            AppIcons.starFilled,
                            color: _kTrustGold,
                            size: 24,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Average rating',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: _kTrustInkDeep,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Trusted by believers worldwide',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                        color: _kTrustInkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // ── Band 3: pill row ──
        // Three equal pills. Labels split across two lines (primary
        // bold, secondary smaller) — same structure as the reference.
        // Primary words are short (Verified / Private / Faith) so
        // they fit on a single line at phone widths without ellipsis.
        Row(
          children: const [
            Expanded(
              child: _TrustPill(
                icon: AppIcons.verified,
                primary: 'Verified',
                secondary: 'advisors',
              ),
            ),
            SizedBox(width: 6),
            Expanded(
              child: _TrustPill(
                icon: AppIcons.lock,
                primary: 'Private',
                secondary: 'sessions',
              ),
            ),
            SizedBox(width: 6),
            Expanded(
              child: _TrustPill(
                iconWidget: _CrossGlyph(size: 13, color: _kTrustBrown),
                primary: 'Faith',
                secondary: 'centered',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// Gold medal — radial gradient + thin inner-highlight ring + check
// glyph. The inner ring is what stops the badge from reading as a
// flat coin.
class _TrustMedal extends StatelessWidget {
  final double size;
  const _TrustMedal({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: Alignment(-0.35, -0.4),
          radius: 1.0,
          colors: [_kTrustGoldLight, _kTrustGold],
        ),
      ),
      alignment: Alignment.center,
      child: Container(
        width: size - 5,
        height: size - 5,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.32),
            width: 0.8,
          ),
        ),
        child: AppIcon(
          AppIcons.verified,
          color: Colors.white,
          size: size * 0.58,
        ),
      ),
    );
  }
}

// Premium pill chip. Capsule with a soft vertical cream gradient,
// 0.7-px warm-gold hairline border, and a circular tinted backdrop
// behind the icon so the glyph reads as a proper feature mark and
// not a lone icon floating in space. Two-line label: bold primary
// + muted secondary.
class _TrustPill extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String primary;
  final String secondary;

  const _TrustPill({
    this.icon,
    this.iconWidget,
    required this.primary,
    required this.secondary,
  }) : assert(icon != null || iconWidget != null);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
      decoration: BoxDecoration(
        // Subtle vertical gradient: lighter cream at the top, warmer
        // cream at the bottom. Adds depth so the pill reads as a
        // physical chip rather than a flat sticker.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFFFF7E8).withValues(alpha: 0.78),
            const Color(0xFFF4E2C8).withValues(alpha: 0.62),
          ],
        ),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(
          color: _kTrustHairlineGold.withValues(alpha: 0.6),
          width: 0.7,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tinted circular backdrop behind the glyph — warm brown
          // radial gradient (lighter at top-left for a touch of
          // dimension).
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.3, -0.3),
                radius: 0.95,
                colors: [
                  _kTrustBrown.withValues(alpha: 0.20),
                  _kTrustBrown.withValues(alpha: 0.10),
                ],
              ),
            ),
            child: iconWidget ??
                AppIcon(icon, color: _kTrustBrown, size: 14),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  primary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    letterSpacing: -0.1,
                    color: _kTrustInkDeep,
                  ),
                ),
                Text(
                  secondary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                    color: _kTrustInkMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Small Latin cross built from two rounded rects. Material Icons
// doesn't ship a clean Christian cross — AppIcons.add reads as "plus",
// not a cross — so we draw one with the same warm-brown weight as
// the other pill glyphs.
class _CrossGlyph extends StatelessWidget {
  final double size;
  final Color color;

  const _CrossGlyph({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    final stem = size * 0.22;
    final crossbarH = size * 0.22;
    final crossbarW = size * 0.65;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Center(
            child: Container(
              width: stem,
              height: size * 0.92,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(stem / 2),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: size * 0.22,
            child: Center(
              child: Container(
                width: crossbarW,
                height: crossbarH,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(crossbarH / 2),
                ),
              ),
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
    // Single full-viewport placeholder — matches the real carousel
    // (viewportFraction 1.0 with 20-px inset on each card), so the
    // shimmer → data transition doesn't shift the layout.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Shimmer.fromColors(
        baseColor: _C.muted.withValues(alpha: 0.14),
        highlightColor: _C.surfaceWarm,
        child: Container(
          decoration: BoxDecoration(
            color: _C.muted.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
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
          childAspectRatio: 0.72,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, _) {
            return Shimmer.fromColors(
              baseColor: _C.muted.withValues(alpha: 0.14),
              highlightColor: _C.surfaceWarm,
              child: Container(
                decoration: BoxDecoration(
                  color: _C.muted.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(12),
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
