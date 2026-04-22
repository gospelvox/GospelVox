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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
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

  static const sessionGradients = <List<Color>>[
    [Color(0xFF6B3A2A), Color(0xFFC8902A)], // brown → gold
    [Color(0xFF2C1810), Color(0xFF6B3A2A)], // dark → brown
    [Color(0xFF8B5A3A), Color(0xFFD4A060)], // warm mid → gold
  ];
}

// ─── Bible session stub data ──────────────────────────────

// Bible sessions are a Week 5 deliverable; the collection doesn't
// exist yet. These placeholder cards keep the carousel shipping
// with the home redesign. Replace with a Firestore stream when
// the real data model lands.
class _BibleSessionStub {
  final String title;
  final String category;
  final String priestName;
  final String date;
  final int priceCoins;

  const _BibleSessionStub({
    required this.title,
    required this.category,
    required this.priestName,
    required this.date,
    required this.priceCoins,
  });
}

const _kStubSessions = <_BibleSessionStub>[
  _BibleSessionStub(
    title: 'Book of John',
    category: 'Deep Study',
    priestName: 'Fr. Thomas',
    date: 'Mar 20',
    priceCoins: 50,
  ),
  _BibleSessionStub(
    title: 'Psalms Study',
    category: 'Daily Living',
    priestName: 'Dr. James',
    date: 'Mar 22',
    priceCoins: 30,
  ),
  _BibleSessionStub(
    title: 'Acts of Apostles',
    category: 'History',
    priestName: 'Sr. Maria',
    date: 'Mar 25',
    priceCoins: 40,
  ),
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
  final PageController _carouselController =
      PageController(viewportFraction: 0.78);

  String _activeFilter = 'All';
  int _carouselIndex = 0;

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
  }

  Animation<double> _interval(double start, double end) {
    return CurvedAnimation(
      parent: _animController,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
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
    final shell = UserShellScope.of(context);
    if (shell != null) {
      shell.switchToTab(3);
    } else {
      context.go('/user');
    }
  }

  void _comingSoon(String message) {
    AppSnackBar.info(context, message);
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
          // False until the notifications collection ships. The dot
          // is strictly for "you have unread activity" — showing it
          // permanently would train users to ignore it.
          hasUnread: false,
          onTap: () => _comingSoon('Notifications coming soon'),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: 'UPCOMING SESSIONS',
          onSeeAll: () => _comingSoon('Bible Sessions coming soon'),
        ),
        SizedBox(
          height: 150,
          child: state is HomeLoading
              ? _SessionsCarouselShimmer()
              // padEnds: false stops the PageView from centring the
              // first/last card inside its viewport. Combined with a
              // left gutter of 20 that matches the page padding, the
              // first card's left edge now lines up with the section
              // label above it and the priest grid below.
              : PageView.builder(
                  controller: _carouselController,
                  physics: const BouncingScrollPhysics(),
                  padEnds: false,
                  itemCount: _kStubSessions.length,
                  onPageChanged: (i) => setState(() => _carouselIndex = i),
                  itemBuilder: (_, i) {
                    return Padding(
                      padding: EdgeInsets.only(
                        left: i == 0 ? 20 : 0,
                        right: 12,
                      ),
                      child: _BibleSessionCard(
                        session: _kStubSessions[i],
                        gradient: _C.sessionGradients[
                            i % _C.sessionGradients.length],
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_kStubSessions.length, (i) {
            final active = i == _carouselIndex;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              // 16px active (was 20) reads more proportionate to the
              // 6px inactive dots in a 3-dot row. 20 felt like a
              // progress bar segment rather than a pager pill.
              width: active ? 16 : 6,
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: active
                    ? _C.brandBrown
                    : _C.brandBrown.withValues(alpha: 0.15),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildAvailableNowLabel() {
    return _SectionHeader(
      title: 'AVAILABLE NOW',
      // Tighter top because the carousel dots above already leave
      // breathing room — the default 24 made this section feel
      // stranded from the rail.
      topPadding: 16,
      onSeeAll: () => _comingSoon('Full speaker list coming soon'),
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
              onChat: () => _comingSoon('Session requests coming soon'),
              onCall: () => _comingSoon('Session requests coming soon'),
              onNotify: () => _comingSoon(
                "You'll be notified when ${priest.fullName} is available",
              ),
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
  // Section headers default to a 24px top gap (clear separation
  // between sections), but the header directly below the carousel
  // dots gets ~14px of pre-existing whitespace already, so callers
  // can tighten to `topPadding: 16` in that one spot.
  final double topPadding;

  const _SectionHeader({
    required this.title,
    required this.onSeeAll,
    this.topPadding = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
          const SizedBox(width: 8),
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

// ─── Bible session card ───────────────────────────────────

class _BibleSessionCard extends StatelessWidget {
  final _BibleSessionStub session;
  final List<Color> gradient;

  const _BibleSessionCard({required this.session, required this.gradient});

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: () {
        AppSnackBar.info(context, 'Bible Sessions coming soon');
      },
      scale: 0.97,
      child: Container(
        // No margin — the PageView itemBuilder applies the gutter
        // (left: 20 for i==0, right: 12 otherwise) so the first
        // card aligns with the page's 20px horizontal padding.
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          ),
          boxShadow: [
            BoxShadow(
              color: gradient.first.withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'BIBLE SESSION',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                Icon(
                  Icons.menu_book_rounded,
                  size: 18,
                  // 0.35 was almost invisible on the darker gradients
                  // — 0.45 still reads as a decorative accent but
                  // actually shows up.
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ],
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                session.title,
                maxLines: 1,
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              session.category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.2),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initials(session.priestName),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${session.priestName} · ${session.date}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${session.priceCoins} coins',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+')).take(2).toList();
    final buf = StringBuffer();
    for (final p in parts) {
      if (p.isNotEmpty) buf.write(p[0].toUpperCase());
    }
    final out = buf.toString();
    return out.isEmpty ? '?' : out;
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
