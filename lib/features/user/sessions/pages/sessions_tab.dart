// User-side Sessions tab — speaker-discovery + history surface.
//
// Two sub-tabs:
//   • Speakers — live list of every speaker (same data source as Home),
//                rendered as a horizontal card with the avatar, info
//                column and action column all VERTICALLY CENTERED so
//                there's no orphan whitespace around any block.
//   • History  — WhatsApp-style compact row list of priests this user
//                has already had a completed session with, OR who have
//                sent them a follow-up message. Unified (no chat/voice
//                split); tap opens that priest's chat history page.
//
// Card recipe (the alignment-critical bit):
//
//   Row(crossAxisAlignment: center,
//     children: [Avatar 64, gap 12, Expanded(InfoColumn), gap 10, Actions])
//
//   Avatar + Actions both centre against InfoColumn — symmetric
//   whitespace, no dead space at the bottom of the photo or below the
//   buttons. Card height naturally tracks the InfoColumn (typically
//   ~120 px) so 3 cards fit above the fold.
//
// Spacing is on a 4-px scale (4 / 6 / 10 / 12 / 14 / 20). Card surface
// uses a faint hairline border PLUS a single-layer ~4% shadow — the
// combo defines the edge crisply on a warm parchment surface without
// either reading heavy on its own.

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/pulsing_dot.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/user/home/bloc/home_cubit.dart';
import 'package:gospel_vox/features/user/home/bloc/home_state.dart';
import 'package:gospel_vox/features/user/home/pages/user_shell_page.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';

// ─── Local design tokens (page-scoped) ──────────────────────

class _C {
  static const double maxContentWidth = 640;
  static const double horizPad = 20;

  // ── Border-radius scale ─────────────────────────────────
  //
  // Locked to match the user home screen (speaker cards, bible session
  // banners, search bar — all use 20). Smaller surfaces inside a card
  // step down to 16; buttons step down to 12. No full-pill shapes,
  // no circular containers anywhere except status-indicator dots.
  static const double cardRadius = AppRadius.large; // 20
  static const double innerRadius = AppRadius.medium; // 16 — avatar, icon chrome
  static const double buttonRadius = AppRadius.small; // 12 — every button

  static const double cardPadding = 14;
  static const double cardInnerGutter = 12; // avatar ↔ info
  static const double actionGutter = 10; // info ↔ actions
  static const double listCardGap = 10; // between cards in the list

  // Avatar — rounded-square (innerRadius), NOT a circle. Matches the
  // photo treatment on the home-screen speaker card.
  static const double avatarSize = 64;
  static const double statusDotSize = 12;

  // Tab toggle + search.
  static const double pillBarHeight = 44;

  // Right-side action pills (rounded square, not full-pill).
  // 88 px — was 80, but "Notify me" was overflowing the row at small
  // text scales on narrow phones. The 8 px increase swallows the
  // overflow while still leaving the info column ~78 dp of width
  // on a 320 dp phone (worst case), which the dynamic tag-fit and
  // Flexible name + ellipsis already handle.
  static const double actionPillWidth = 88;
  static const double actionPillHeight = 34;
  static const double actionPillGap = 6;

  // Vertical gap between the card's main Row (avatar + info + actions)
  // and the full-width tags row below it.
  static const double tagsRowGap = 10;

  // Inline status dot rendered after the name. 8 px solid + 2 px white
  // ring = a 12-px footprint that reads clearly on any surface.
  static const double inlineDotSize = 8;

  // Listview bottom padding — clearance for the floating bottom nav.
  static const double listBottomPad = 120;
}

// Refined card shadow — a single near-invisible layer that, paired
// with the hairline border below, gives the card crisp edge definition
// without the puffy double-drop that read as heavy.
const List<BoxShadow> _kRefinedShadow = [
  BoxShadow(
    color: Color(0x0A6B3A2A), // primaryBrown α0.04
    blurRadius: 3,
    offset: Offset(0, 1),
  ),
];

// Hairline border colours. _kCardBorder is fainter (cards live on
// parchment), _kHairline is used by inputs & toggles that sit alone.
const Color _kCardBorder = Color(0x0F6B3A2A); // primaryBrown α0.06
const Color _kHairline = Color(0x146B3A2A); // primaryBrown α0.08

// Chip backgrounds — primaryBrown α0.06.
const Color _kTagBg = Color(0x0F6B3A2A);

// Slightly darker "pressed" card surface — ~2% darker than #FFFFFF
// against the warm palette. Animated into on tap-down for tactile feel.
const Color _kCardPressed = Color(0xFFFBF8F4);

// Page-local "vibrant" online green — saturated iOS-style emerald that
// reads as alive on a warm cream surface where AppColors.sageOnline
// (#3E8E5C) looks slightly muted. Scoped to this file so the rest of
// the app's sage tone stays untouched.
const Color _kVibrantGreen = Color(0xFF10B981);

// ─── Filter chips (mirrors the home-screen category set) ───
typedef _FilterDef = ({String label, IconData? icon, Color? iconColor});

const List<_FilterDef> _kFilterCategoriesSessions = <_FilterDef>[
  (label: 'All', icon: null, iconColor: null),
  (label: 'Online', icon: AppIcons.wifi, iconColor: _kVibrantGreen),
  (label: 'Priests', icon: AppIcons.userOutline, iconColor: null),
  (label: 'Pastors', icon: AppIcons.add, iconColor: null),
  (label: 'Counsellors', icon: AppIcons.chatOutline, iconColor: null),
  (label: 'Bible Teachers', icon: AppIcons.bible, iconColor: null),
];

// Search hint composition:
//   • The prefix "Search " never animates — it stays still on the line
//     so the user's eye doesn't flicker between cycles.
//   • Only the trailing word slides up + fades while cycling, giving
//     the Myntra/Flipkart-style "what to look for" rotation. Words
//     are wrapped in straight double-quotes so they read as concrete
//     example queries.
const String _kSearchHintPrefix = 'Search ';
const List<String> _kSearchHintWords = <String>[
  '"counseling"',
  '"grief support"',
  '"Fr Robin"',
  '"pastors"',
  '"Bible teachers"',
  '"prayer support"',
  '"healing ministry"',
];

// Responsive type-scale helper. Most phones in the wild fall into one
// of three width buckets — 320-360 (small), 360-420 (mid), 420+ (large).
// Instead of forcing ellipsis on small phones, fonts step down by a
// small factor so the same line stays visible at a slightly tighter
// size. Returns a multiplier in [0.92, 1.0].
double _typeScale(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w < 340) return 0.92;
  if (w < 360) return 0.96;
  return 1.0;
}

// ─── Sessions tab entry ─────────────────────────────────────

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  // 0 = Speakers, 1 = History. IndexedStack keeps both alive so
  // tab-switching is instant and scroll position survives.
  int _activeTab = 0;

  // History state — owned by the tab (not a cubit) because it's a
  // one-shot fetch with pull-to-refresh, not a live stream.
  bool _isHistoryLoading = true;
  List<PriestSessionGroup> _historyGroups = const [];

  // Owned HomeCubit instance — created in initState, closed in
  // dispose. Holding it as a State field (rather than letting
  // BlocProvider's `create` callback own it) means callbacks like
  // `_onPageChanged` can reach the cubit through `_homeCubit`
  // directly, instead of going through `context.read<HomeCubit>()`
  // on the State's BuildContext — which is OUTSIDE the BlocProvider
  // we return from `build`, and therefore can't see it. That lookup
  // was throwing on every PageView page change, costing one
  // exception per swipe and showing up as scroll/tab-switch stutter.
  late final HomeCubit _homeCubit;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  // PageController drives the sliding transition between the Speakers
  // and History sub-tabs. Both pages stay alive (via _KeepAlive
  // wrappers below) so scroll position + cubit state survive a swipe
  // OR a tab-toggle tap. The controller is the single source of truth
  // for the page index; _activeTab is mirrored from it via
  // `onPageChanged` so the tab pill always matches the visible page.
  final PageController _pageController = PageController();
  String _query = '';
  // Active category chip (Speakers sub-tab). 'All' = no extra filter
  // on top of the search query. Locally scoped — the HomeCubit owns
  // search, and category is a UI-only layer over its filtered output.
  String _activeFilter = 'All';

  @override
  void initState() {
    super.initState();
    _homeCubit = sl<HomeCubit>();
    _homeCubit.watchPriests();
    _loadHistory();
    _prewarmCoinPacks();
  }

  // Fire-and-forget warm-up so the very first low-balance bottom sheet
  // open lands instantly on cached content instead of paying a 200-
  // 400 ms shimmer for the Firestore round-trip. `getCoinPacks` is
  // idempotent + already cached by the repository; if the user never
  // taps Call, the cost is one tiny Firestore read at tab mount.
  void _prewarmCoinPacks() {
    try {
      sl<WalletRepository>().getCoinPacks();
    } catch (_) {
      // Silent — pre-warm is best-effort, the sheet has its own retry.
    }
  }

  @override
  void dispose() {
    // BlocProvider.value does NOT auto-close the cubit (it didn't
    // create it), so we own teardown here.
    _homeCubit.close();
    _searchController.dispose();
    _searchFocus.dispose();
    _pageController.dispose();
    super.dispose();
  }

  // Single source of truth for "hide keyboard". Called from:
  //   • the page-level tap-outside GestureDetector
  //   • before any navigation away (speaker card / history row tap)
  //   • on tab switch
  // so the user never lands on a destination with a phantom keyboard.
  void _dismissKeyboard() {
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  Future<void> _loadHistory() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _isHistoryLoading = false;
        _historyGroups = const [];
      });
      return;
    }

    if (mounted) setState(() => _isHistoryLoading = true);

    try {
      final groups =
          await sl<SessionHistoryRepository>().getUserPriestThreads(uid);
      if (!mounted) return;
      setState(() {
        _historyGroups = groups;
        _isHistoryLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isHistoryLoading = false);
      AppSnackBar.error(context, 'Loading timed out. Pull down to retry.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isHistoryLoading = false);
      AppSnackBar.error(context, 'Could not load history.');
    }
  }

  List<PriestSessionGroup> get _filteredHistory {
    if (_query.isEmpty) return _historyGroups;
    final q = _query.toLowerCase();
    return _historyGroups
        .where((g) => g.priestName.toLowerCase().contains(q))
        .toList();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    if (_activeTab == 0 && context.mounted) {
      _homeCubit.search(value);
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
    if (_activeTab == 0) {
      _homeCubit.search('');
    }
  }

  // Tab-toggle tap path. We DON'T setState `_activeTab` here — the
  // page animation kicks off, `onPageChanged` fires when the slide
  // settles, and that's what updates `_activeTab` (and consequently
  // the tab-pill highlight). One source of truth = no risk of the
  // pill and the visible page drifting apart during the slide.
  void _switchTab(int index) {
    if (_activeTab == index) return;
    HapticFeedback.selectionClick();
    _dismissKeyboard();
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  // Fires from BOTH the tab-toggle's `animateToPage` AND the user's
  // own swipe. Single update path keeps the tab pill in sync with
  // whatever surface mechanism the user used to navigate.
  void _onPageChanged(int index) {
    if (_activeTab == index) return;
    setState(() => _activeTab = index);
    if (index == 0 && context.mounted) {
      _homeCubit.search(_query);
    }
  }

  void _onFilterTap(String label) {
    if (_activeFilter == label) return;
    HapticFeedback.selectionClick();
    _dismissKeyboard();
    setState(() => _activeFilter = label);
  }

  void _openHistoryRow(PriestSessionGroup priest) {
    // A deleted-priest row is intentionally inert — there's no live
    // profile or chat to open. Tapping just acknowledges quietly
    // instead of routing into a dead chat-history page.
    if (priest.isDeleted) {
      _dismissKeyboard();
      AppSnackBar.error(context, 'This speaker is no longer available.');
      return;
    }
    HapticFeedback.lightImpact();
    _dismissKeyboard();
    context.push(
      '/user/chat-history/${priest.priestId}',
      extra: <String, dynamic>{
        'priestName': priest.priestName,
        'priestPhotoUrl': priest.priestPhotoUrl,
      },
    );
  }

  void _openSpeakerProfile(SpeakerModel priest) {
    _dismissKeyboard();
    context.push('/user/priest/${priest.uid}');
  }

  Future<void> _startSession(SpeakerModel priest, String type) async {
    HapticFeedback.lightImpact();
    _dismissKeyboard();
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

  Future<void> _subscribeToNotifyMe(SpeakerModel priest) async {
    HapticFeedback.lightImpact();
    _dismissKeyboard();
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
    } on FirebaseException catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't subscribe. Try again.");
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't subscribe. Try again.");
    }
  }

  // ─── Per-page scroll builders ───────────────────────────────
  //
  // Each PageView page is its own CustomScrollView so the Header can
  // scroll away while the operational band stays pinned. The two
  // share the same set of state-driven callbacks defined above —
  // tapping a tab on either page's pinned band animates the whole
  // PageView via _switchTab.

  Widget _buildSpeakersScroll() {
    return BlocBuilder<HomeCubit, HomeState>(
      builder: (ctx, state) {
        return RefreshIndicator(
          color: AppColors.primaryBrown,
          backgroundColor: AppColors.surfaceWhite,
          onRefresh: () => _homeCubit.refresh(),
          child: CustomScrollView(
            // primary: false so this scroll view doesn't try to attach
            // to the ambient PrimaryScrollController — each PageView
            // page needs its own independent scroll position.
            primary: false,
            keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              // 1. Title block — scrolls away
              const SliverToBoxAdapter(child: _Header()),
              // 2. Tab toggle — scrolls away with the title
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _C.horizPad,
                    20,
                    _C.horizPad,
                    14,
                  ),
                  child: _TabToggle(
                    activeIndex: _activeTab,
                    onChanged: _switchTab,
                  ),
                ),
              ),
              // 3. Search bar — pinned, transparent until content
              //    scrolls beneath it
              SliverPersistentHeader(
                pinned: true,
                delegate: _FloatingSearchBarDelegate(
                  query: _query,
                  searchController: _searchController,
                  searchFocus: _searchFocus,
                  onSearchChanged: _onSearchChanged,
                  onSearchClear: _clearSearch,
                  isSpeakers: true,
                ),
              ),
              // 4. Filter chips — scroll under the pinned search bar
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: _FilterChips(
                    activeLabel: _activeFilter,
                    onTap: _onFilterTap,
                  ),
                ),
              ),
              // 5. Speaker cards
              ..._buildSpeakersSlivers(state),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildSpeakersSlivers(HomeState state) {
    if (state is HomeInitial || state is HomeLoading) {
      return const [
        SliverToBoxAdapter(child: _SpeakersShimmer()),
      ];
    }
    if (state is HomeError) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ErrorState(
            message: state.message,
            onRetry: () => _homeCubit.refresh(),
          ),
        ),
      ];
    }
    final loaded = state as HomeLoaded;
    // Run our own combined filter on the FULL list (loaded.priests),
    // not the cubit's pre-filtered output — that way status-keyword
    // searches ("online", "busy") can short-circuit the cubit's
    // empty text-search result.
    final priests = _filterSpeakers(loaded.priests);
    final hasSearch = _query.isNotEmpty;
    final hasChip = _activeFilter != 'All';

    if (priests.isEmpty) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            _C.horizPad,
            16,
            _C.horizPad,
            _C.listBottomPad,
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _EmptyCard(
                icon: AppIcons.users,
                title: hasSearch || hasChip
                    ? 'No matches'
                    : 'No speakers available yet',
                subtitle: hasSearch || hasChip
                    ? "No speakers match that. Try 'healing' or 'family.'"
                    : 'Pull down to refresh.',
              ),
              const SizedBox(height: _C.listCardGap),
              const _TrustBanner(),
            ]),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          _C.horizPad,
          16,
          _C.horizPad,
          _C.listBottomPad,
        ),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i == priests.length) {
                return const _TrustBanner();
              }
              final priest = priests[i];
              return Padding(
                padding: EdgeInsets.only(
                  bottom: i == priests.length - 1 ? _C.listCardGap : _C.listCardGap,
                ),
                child: _SessionSpeakerCard(
                  priest: priest,
                  onTap: () => _openSpeakerProfile(priest),
                  onCall: () => _startSession(priest, 'voice'),
                  onChat: () => _startSession(priest, 'chat'),
                  onNotify: () => _subscribeToNotifyMe(priest),
                ),
              );
            },
            childCount: priests.length + 1,
          ),
        ),
      ),
    ];
  }

  // Unified filter — search query AND category chip, applied as an
  // intersection. Operates on the FULL priest list (not the cubit's
  // own filtered output) so status-keyword searches like "online" /
  // "busy" / "offline" can override the cubit's text-search empty
  // result. Returns the priests that should be visible on screen.
  List<SpeakerModel> _filterSpeakers(List<SpeakerModel> all) {
    var result = all;

    // ── 1. Search query ────────────────────────────────────
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      // Status keywords short-circuit the standard text search.
      // Typing "online" should obviously mean "filter to online
      // speakers" — not "search names containing the word online".
      if (q == 'online' || q == 'available') {
        result = result.where((p) => p.isAvailable).toList();
      } else if (q == 'busy') {
        result = result.where((p) => p.isOnline && p.isBusy).toList();
      } else if (q == 'offline' || q == 'unavailable') {
        result = result.where((p) => !p.isOnline).toList();
      } else {
        // Text search — broader field set than the cubit's default,
        // including subDenomination, churchName, and location so a
        // user typing "Bangalore" or "St. Mary's" finds matches.
        result = result.where((p) => _matchesTextQuery(p, q)).toList();
      }
    }

    // ── 2. Category chip filter ────────────────────────────
    result = _applyCategoryChip(result, _activeFilter);

    return result;
  }

  bool _matchesTextQuery(SpeakerModel p, String q) {
    if (p.fullName.toLowerCase().contains(q)) return true;
    if (p.denomination.toLowerCase().contains(q)) return true;
    if (p.subDenomination.toLowerCase().contains(q)) return true;
    if (p.churchName.toLowerCase().contains(q)) return true;
    if (p.location.toLowerCase().contains(q)) return true;
    if (p.specializations.any((s) => s.toLowerCase().contains(q))) {
      return true;
    }
    if (p.languages.any((l) => l.toLowerCase().contains(q))) return true;
    return false;
  }

  // Category chip → predicate. Falls back to substring match against
  // denomination + specializations, then a heuristic mapping for the
  // common role labels (Priests / Pastors / Counsellors / Bible
  // Teachers) where the raw category label isn't usually present in
  // the data as-is.
  List<SpeakerModel> _applyCategoryChip(
    List<SpeakerModel> base,
    String category,
  ) {
    if (category == 'All') return base;
    if (category == 'Online') {
      return base.where((p) => p.isAvailable).toList();
    }

    final cat = category.toLowerCase();
    final direct = base.where((p) {
      return p.denomination.toLowerCase().contains(cat) ||
          p.subDenomination.toLowerCase().contains(cat) ||
          p.specializations.any((s) => s.toLowerCase().contains(cat));
    }).toList();

    if (direct.isNotEmpty) return direct;

    // Heuristic fallback — maps role labels onto denominational
    // groupings + specialization keywords that actually live in the
    // data. Returns whatever the heuristic catches, or an empty list
    // if nothing matches (which surfaces the "No matches" empty state
    // honestly instead of silently dropping the filter).
    return _heuristicCategoryMatch(base, category);
  }

  List<SpeakerModel> _heuristicCategoryMatch(
    List<SpeakerModel> base,
    String category,
  ) {
    switch (category) {
      case 'Priests':
        return base.where((p) {
          final d = p.denomination.toLowerCase();
          return d.contains('catholic') || d.contains('orthodox');
        }).toList();
      case 'Pastors':
        return base.where((p) {
          final d = p.denomination.toLowerCase();
          return d.contains('protestant') ||
              d.contains('pentecostal') ||
              d.contains('evangelical') ||
              d.contains('baptist') ||
              d.contains('methodist');
        }).toList();
      case 'Counsellors':
        return base.where((p) {
          return p.specializations.any((s) {
            final sl = s.toLowerCase();
            return sl.contains('counsel');
          });
        }).toList();
      case 'Bible Teachers':
        return base.where((p) {
          return p.specializations.any((s) {
            final sl = s.toLowerCase();
            return sl.contains('bible') ||
                sl.contains('teaching') ||
                sl.contains('teacher') ||
                sl.contains('study');
          });
        }).toList();
    }
    return const [];
  }

  Widget _buildHistoryScroll() {
    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: _loadHistory,
      child: CustomScrollView(
        primary: false,
        keyboardDismissBehavior:
            ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          // 1. Title block — scrolls away
          const SliverToBoxAdapter(child: _Header()),
          // 2. Tab toggle — scrolls away with the title
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                _C.horizPad,
                20,
                _C.horizPad,
                14,
              ),
              child: _TabToggle(
                activeIndex: _activeTab,
                onChanged: _switchTab,
              ),
            ),
          ),
          // 3. Search bar — pinned, transparent until content scrolls
          //    beneath it. No filter chips on History tab — category
          //    filtering only makes sense for the live speakers feed.
          SliverPersistentHeader(
            pinned: true,
            delegate: _FloatingSearchBarDelegate(
              query: _query,
              searchController: _searchController,
              searchFocus: _searchFocus,
              onSearchChanged: _onSearchChanged,
              onSearchClear: _clearSearch,
              isSpeakers: false,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          // 4. History rows
          ..._buildHistorySlivers(),
        ],
      ),
    );
  }

  List<Widget> _buildHistorySlivers() {
    if (_isHistoryLoading) {
      return const [SliverToBoxAdapter(child: _HistoryShimmer())];
    }

    final groups = _filteredHistory;
    if (groups.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _HistoryEmpty(
            isFiltered: _query.isNotEmpty,
            hasAnyHistory: _historyGroups.isNotEmpty,
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: 4),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i == groups.length) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _C.horizPad,
                    16,
                    _C.horizPad,
                    _C.listBottomPad,
                  ),
                  child: const _TrustBanner(),
                );
              }
              return Column(
                children: [
                  _HistoryRow(
                    priest: groups[i],
                    onTap: () => _openHistoryRow(groups[i]),
                  ),
                  if (i < groups.length - 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 86),
                      child: Container(
                        height: 1.2,
                        color: AppColors.primaryBrown
                            .withValues(alpha: 0.18),
                      ),
                    ),
                ],
              );
            },
            childCount: groups.length + 1,
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<HomeCubit>.value(
      value: _homeCubit,
      child: Scaffold(
        backgroundColor: AppColors.backgroundPrimary,
        // Page-level tap-to-dismiss. translucent so taps still reach
        // cards / chips / buttons underneath — this only catches taps
        // on bare surface (between cards, on the header band, etc.)
        // AND has the side-effect of unfocusing whatever was focused
        // before child handlers run.
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _dismissKeyboard,
          child: SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: _C.maxContentWidth),
                // Each PageView page owns its own CustomScrollView so
                // the Header (title + subtitle + bell) can scroll away
                // while the operational band (tab + search + chips)
                // stays pinned. Each page maintains its own scroll
                // position, kept alive across swipes by _KeepAlive.
                child: PageView(
                  controller: _pageController,
                  onPageChanged: _onPageChanged,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  children: [
                    _KeepAlive(child: _buildSpeakersScroll()),
                    _KeepAlive(child: _buildHistoryScroll()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Page-keep-alive wrapper for the PageView children. Without this, a
// swipe to History and back would rebuild the SpeakersList from
// scratch — re-subscribing to the cubit's stream, replaying shimmer,
// and losing scroll position. With it, the off-screen page stays
// hydrated and a return swipe lands instantly with no reload flash.
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ─── Header (title · subtitle · notification bell) ──────────

// Page header — simple title + notification bell, mirroring the
// pattern used by the Bible tab so both tabs in the shell read as
// part of the same system. No tagline / subtitle; the tab toggle
// directly below provides context for what the user is looking at.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _C.horizPad,
        16,
        _C.horizPad,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Connect',
                  style: GoogleFonts.inter(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Connect with faithful speakers  ✨',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.1,
                    color: AppColors.primaryBrown.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Nudge the bell down 2 px so it visually centres on the
          // title's cap-height, not above it.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _NotificationBell(
              uid: FirebaseAuth.instance.currentUser?.uid,
              onTap: () {
                HapticFeedback.lightImpact();
                context.push('/user/notifications');
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Bare-bones notification bell — no circular chrome, just the glyph
// with a 10-px tap halo. Unread state surfaces as a terra-cotta count
// badge (the number of unread notifications, capped at "99+") at the
// icon's top-right corner.
class _NotificationBell extends StatelessWidget {
  final String? uid;
  final VoidCallback onTap;

  const _NotificationBell({required this.uid, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return _BellGlyph(count: 0, onTap: onTap);
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (_, snap) {
        final count = snap.data?.docs.length ?? 0;
        return _BellGlyph(count: count, onTap: onTap);
      },
    );
  }
}

class _BellGlyph extends StatefulWidget {
  // Count of unread notifications. 0 hides the badge; >0 shows the
  // number (capped at "99+") so the user sees how many are waiting,
  // not just that "something" is unread.
  final int count;
  final VoidCallback onTap;
  const _BellGlyph({required this.count, required this.onTap});

  @override
  State<_BellGlyph> createState() => _BellGlyphState();
}

class _BellGlyphState extends State<_BellGlyph> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.9),
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
            padding: const EdgeInsets.all(10),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const AppIcon(
                  AppIcons.bellOutline,
                  size: 22,
                  color: AppColors.deepDarkBrown,
                ),
                if (widget.count > 0)
                  Positioned(
                    top: -6,
                    right: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      constraints: const BoxConstraints(minWidth: 16),
                      height: 16,
                      decoration: BoxDecoration(
                        color: AppColors.terraCotta,
                        borderRadius: BorderRadius.circular(8),
                        // Cream ring carves the badge off the bell so it
                        // reads clearly even when it overlaps the glyph.
                        border: Border.all(
                          color: AppColors.backgroundPrimary,
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        widget.count > 99 ? '99+' : '${widget.count}',
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          height: 1,
                          color: Colors.white,
                        ),
                      ),
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

// ─── Tab toggle (Speakers · History) ────────────────────────

class _TabToggle extends StatelessWidget {
  final int activeIndex;
  final ValueChanged<int> onChanged;

  const _TabToggle({required this.activeIndex, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _C.horizPad),
      child: Container(
        height: _C.pillBarHeight,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(_C.cardRadius),
          border: Border.all(color: _kHairline, width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: _TabPill(
                label: 'Speakers',
                icon: AppIcons.users,
                isActive: activeIndex == 0,
                onTap: () => onChanged(0),
              ),
            ),
            Expanded(
              child: _TabPill(
                label: 'History',
                icon: AppIcons.clock,
                isActive: activeIndex == 1,
                onTap: () => onChanged(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const _TabPill({
    required this.label,
    required this.icon,
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
        decoration: BoxDecoration(
          color: isActive ? AppColors.primaryBrown : Colors.transparent,
          // Inner active pill steps DOWN one tier (medium=16) so it
          // visually nests inside the toggle's 20-radius shell.
          borderRadius: BorderRadius.circular(_C.innerRadius),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              icon,
              size: 14,
              color: isActive
                  ? AppColors.surfaceWhite
                  : AppColors.primaryBrown.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
                color: isActive
                    ? AppColors.surfaceWhite
                    : AppColors.primaryBrown.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Search bar ─────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSpeakers;
  // True when the field is empty AND the Speakers sub-tab is active.
  // We only run the cycling-hint animation in that combined state —
  // History tab and post-typing states get a plain, static hint so
  // the surface doesn't compete with the user's own input.
  final bool animateHint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.isSpeakers,
    required this.animateHint,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = controller.text.isEmpty;
    final hintStyle = GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: AppColors.primaryBrown.withValues(alpha: 0.5),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _C.horizPad),
      child: Container(
        height: _C.pillBarHeight,
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(_C.cardRadius),
          border: Border.all(color: _kHairline, width: 1),
        ),
        // Stack lets us overlay the cycling-hint widget on top of the
        // TextField. The TextField itself carries no hintText so it
        // can't double-up with the animated overlay.
        child: Stack(
          children: [
            TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onTapOutside: (_) => focusNode.unfocus(),
              textInputAction: TextInputAction.search,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppColors.black,
              ),
              decoration: InputDecoration(
                hintText: null,
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 16, right: 10),
                  child: AppIcon(
                    AppIcons.search,
                    size: 16,
                    color: AppColors.primaryBrown.withValues(alpha: 0.6),
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 42,
                  minHeight: 40,
                ),
                suffixIcon: isEmpty
                    ? null
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onClear,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: AppIcon(
                            AppIcons.close,
                            size: 16,
                            color: AppColors.primaryBrown
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                border: InputBorder.none,
                isCollapsed: true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
            if (isEmpty)
              Positioned.fill(
                left: 52, // past the prefix icon + its 10-px gap
                right: 16,
                child: IgnorePointer(
                  // RepaintBoundary so the cycling word's repaint cost
                  // is isolated — it doesn't ripple to the surrounding
                  // search-bar chrome (icon, suffix, border).
                  child: RepaintBoundary(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: animateHint && isSpeakers
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Static prefix — never animates, so
                                // the eye locks onto a stable anchor
                                // while only the trailing word cycles.
                                Text(
                                  _kSearchHintPrefix,
                                  maxLines: 1,
                                  style: hintStyle,
                                ),
                                Flexible(
                                  child: _AnimatedHintWord(
                                    words: _kSearchHintWords,
                                    style: hintStyle,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              isSpeakers
                                  ? '$_kSearchHintPrefix${_kSearchHintWords.first}'
                                  : 'Search past speakers…',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: hintStyle,
                            ),
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

// Cycling placeholder text — slide-up + fade transition between hints.
// Pauses cleanly on dispose; the AnimatedSwitcher's transition runs in
// the compositor, so the only frame-rate cost is the periodic setState
// every ~2.8 s. ClipRect prevents the outgoing text from leaking past
// the row's visual bounds during the slide.
// Cycle cadence — every 2.8 s is fast enough to feel alive without
// feeling restless. Anything below ~2 s draws attention away from the
// user's actual reading flow; anything above ~4 s feels like the loop
// stalled.
const Duration _kHintCycle = Duration(milliseconds: 2800);

// Slide-up transition recipe for the cycling word. Animation runs
// purely in the compositor (Transform.translate + Opacity), so the
// frame cost is independent of widget tree size — this is what keeps
// the search bar feeling fast even on lower-end devices.
class _AnimatedHintWord extends StatefulWidget {
  final List<String> words;
  final TextStyle style;

  const _AnimatedHintWord({
    required this.words,
    required this.style,
  });

  @override
  State<_AnimatedHintWord> createState() => _AnimatedHintWordState();
}

class _AnimatedHintWordState extends State<_AnimatedHintWord> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_kHintCycle, (_) {
      if (!mounted) return;
      setState(() {
        _index = (_index + 1) % widget.words.length;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary so the slide-up + fade transition (which runs
    // for 360 ms every 2.8 s) re-rasterises only the cycling-word
    // bounding box — not the entire search-bar pill behind it.
    return RepaintBoundary(
      child: ClipRect(
        child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 360),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        // layoutBuilder collapses to the active child's size so the
        // outgoing text doesn't push the layout while it slides away.
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.centerLeft,
            children: <Widget>[
              ...previousChildren,
              ?currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) {
          // Incoming word slides from below-the-baseline up into place;
          // outgoing word slides further up + fades. Both use the same
          // easing so the cross-fade reads as one continuous motion.
          final inOffset = Tween<Offset>(
            begin: const Offset(0, 0.55),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: inOffset, child: child),
          );
        },
        child: Text(
          widget.words[_index],
          key: ValueKey<int>(_index),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        ),
        ),
      ),
    );
  }
}

// ─── Category filter chips (mirrors home-screen design) ────

class _FilterChips extends StatelessWidget {
  final String activeLabel;
  final ValueChanged<String> onTap;

  const _FilterChips({required this.activeLabel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: _C.horizPad),
        itemCount: _kFilterCategoriesSessions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final def = _kFilterCategoriesSessions[i];
          return _FilterChip(
            label: def.label,
            icon: def.icon,
            iconColor: def.iconColor,
            isActive: activeLabel == def.label,
            onTap: () => onTap(def.label),
          );
        },
      ),
    );
  }
}

class _FilterChip extends StatefulWidget {
  final String label;
  final IconData? icon;
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
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.isActive
        ? AppColors.surfaceWhite
        : AppColors.deepDarkBrown;
    final iconFg = widget.isActive
        ? AppColors.surfaceWhite
        : (widget.iconColor ?? fg);

    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 32,
            padding: EdgeInsets.symmetric(
              horizontal: widget.icon == null ? 16 : 12,
            ),
            decoration: BoxDecoration(
              gradient: widget.isActive
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 0.5],
                      colors: [
                        Color(0xFF4A2D1C),
                        AppColors.deepDarkBrown,
                      ],
                    )
                  : null,
              color: widget.isActive ? null : AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(16),
              border: widget.isActive
                  ? null
                  : Border.all(
                      color: AppColors.borderLight,
                      width: 0.5,
                    ),
              boxShadow: widget.isActive
                  ? [
                      BoxShadow(
                        color: AppColors.deepDarkBrown
                            .withValues(alpha: 0.18),
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
                if (widget.icon != null) ...[
                  AppIcon(widget.icon, size: 15, color: iconFg),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
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

// ─── Floating search bar (pinned sliver, no chrome strip) ──
//
// Only the search bar pins to the viewport top. Tab toggle and filter
// chips ride along as regular scrolling content above/below the
// search bar — they scroll away naturally with the title, leaving
// the search bar as the only persistent affordance.
//
// Background handling:
//   • At scroll offset 0 (overlapsContent == false) the delegate's
//     own container is transparent — the search bar reads as
//     "floating on the page" with no warm chrome strip behind it.
//   • Once the user scrolls enough that the pinned header overlaps
//     content (overlapsContent == true), a soft warm-cream tint
//     fades in via AnimatedContainer. This hides the brief visual
//     "blip" of a speaker card passing through the small padding
//     band around the pill, without ever painting a heavy bar.
//
// Internal padding is 6 px top + 6 px bottom — just enough to keep
// the pill off the viewport edges. Total sliver height = 56 px.
class _FloatingSearchBarDelegate extends SliverPersistentHeaderDelegate {
  final String query;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchClear;
  final bool isSpeakers;

  // 44 (pill) + 6 + 6 padding
  static const double _kHeight = 56;

  _FloatingSearchBarDelegate({
    required this.query,
    required this.searchController,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onSearchClear,
    required this.isSpeakers,
  });

  @override
  double get maxExtent => _kHeight;

  @override
  double get minExtent => _kHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        // Transparent at rest, soft warm tint when content scrolls
        // beneath. The fade-in reads as "the page surface coming up
        // to support the floating pill" rather than a hard strip
        // appearing at the top.
        color: overlapsContent
            ? AppColors.backgroundPrimary.withValues(alpha: 0.92)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
        child: _SearchBar(
          controller: searchController,
          focusNode: searchFocus,
          isSpeakers: isSpeakers,
          animateHint: query.isEmpty,
          onChanged: onSearchChanged,
          onClear: onSearchClear,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_FloatingSearchBarDelegate oldDelegate) {
    return oldDelegate.query != query ||
        oldDelegate.isSpeakers != isSpeakers;
  }
}

// ─── Speaker card — center-aligned Row, right-side actions ─

class _SessionSpeakerCard extends StatefulWidget {
  final SpeakerModel priest;
  final VoidCallback onTap;
  final VoidCallback onCall;
  final VoidCallback onChat;
  final VoidCallback onNotify;

  const _SessionSpeakerCard({
    required this.priest,
    required this.onTap,
    required this.onCall,
    required this.onChat,
    required this.onNotify,
  });

  @override
  State<_SessionSpeakerCard> createState() => _SessionSpeakerCardState();
}

class _SessionSpeakerCardState extends State<_SessionSpeakerCard> {
  bool _pressed = false;
  Timer? _pressTimer;

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  void _schedulePress() {
    _pressTimer?.cancel();
    _pressTimer = Timer(const Duration(milliseconds: 60), () {
      if (!mounted) return;
      setState(() => _pressed = true);
    });
  }

  void _releasePress() {
    _pressTimer?.cancel();
    _pressTimer = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.priest;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _schedulePress(),
      onTapUp: (_) => _releasePress(),
      onTapCancel: _releasePress,
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(_C.cardPadding),
          decoration: BoxDecoration(
            color: _pressed ? _kCardPressed : AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(_C.cardRadius),
            border: Border.all(color: _kCardBorder, width: 1),
            boxShadow: _kRefinedShadow,
          ),
          // Two-tier card:
          //   • Main row — avatar + info + actions, vertically centered
          //     against each other so there's no orphan whitespace.
          //   • Tags row — full card width below, so spec names actually
          //     have horizontal room to render instead of truncating to
          //     two-letter stubs.
          child: _buildBody(p),
        ),
      ),
    );
  }

  Widget _buildBody(SpeakerModel p) {
    // Specs feed for the bottom row. Falls back to denomination as a
    // single "chip" when the speaker has zero specialisations — keeps
    // the row from being bare. _TagsRow itself owns the
    // measure-and-fit logic: it greedy-fits up to 3 chips at their
    // full natural width, then renders a "+N" overflow indicator for
    // whatever didn't fit. No ellipsis at any point.
    final tagFeed = p.specializations.isNotEmpty
        ? p.specializations
        : (p.denomination.isNotEmpty ? <String>[p.denomination] : const <String>[]);
    final hasTagsRow = tagFeed.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Avatar(priest: p),
            const SizedBox(width: _C.cardInnerGutter),
            Expanded(child: _InfoColumn(priest: p)),
            const SizedBox(width: _C.actionGutter),
            _ActionColumn(
              priest: p,
              onCall: widget.onCall,
              onChat: widget.onChat,
              onNotify: widget.onNotify,
            ),
          ],
        ),
        if (hasTagsRow) ...[
          const SizedBox(height: _C.tagsRowGap),
          _TagsRow(specs: tagFeed),
        ],
      ],
    );
  }
}

// ─── Avatar (circle 64, status dot bottom-right) ────────────

class _Avatar extends StatelessWidget {
  final SpeakerModel priest;
  const _Avatar({required this.priest});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _C.avatarSize,
      height: _C.avatarSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Photo body — rounded square (16) so it mirrors the photo
          // treatment on the home-screen speaker card instead of going
          // fully circular.
          ClipRRect(
            borderRadius: BorderRadius.circular(_C.innerRadius),
            child: Container(
              width: _C.avatarSize,
              height: _C.avatarSize,
              color: AppColors.surfaceSecondary,
              child: priest.hasPhoto
                  ? CachedNetworkImage(
                      imageUrl: priest.photoUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => Container(
                        color: AppColors.surfaceSecondary,
                      ),
                      errorWidget: (_, _, _) => _BigInitial(priest: priest),
                    )
                  : _BigInitial(priest: priest),
            ),
          ),
          // Status dot — top-right, slightly overhanging the avatar
          // edge so it reads as an indicator rather than a button.
          // (Indicator dots stay circular — that's a status-signal
          // semantic, not chrome.)
          Positioned(
            top: -1,
            right: -1,
            child: priest.isAvailable
                ? _PulsingHaloDot(color: _kVibrantGreen)
                : _StaticHaloDot(
                    color: priest.isBusy
                        ? AppColors.amberGold
                        : AppColors.muted.withValues(alpha: 0.85),
                  ),
          ),
        ],
      ),
    );
  }
}

// Online dot — pulsing center + a slim warm-cream halo ring around
// it. The halo uses the page background colour (not pure white) so
// it reads as part of the parchment palette and visually "carves"
// the dot out from any photo or card surface behind it without the
// stark sticker look of a white border.
//
// RepaintBoundary at the root isolates the constant 60 Hz pulse tick
// to just the dot's bounding box.
class _PulsingHaloDot extends StatelessWidget {
  final Color color;
  const _PulsingHaloDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: _C.statusDotSize,
        height: _C.statusDotSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            PulsingDot(size: _C.statusDotSize - 3, color: color),
            Container(
              width: _C.statusDotSize,
              height: _C.statusDotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.backgroundPrimary,
                  width: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaticHaloDot extends StatelessWidget {
  final Color color;
  const _StaticHaloDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _C.statusDotSize,
      height: _C.statusDotSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: AppColors.backgroundPrimary,
          width: 1.5,
        ),
      ),
    );
  }
}

class _BigInitial extends StatelessWidget {
  final SpeakerModel priest;
  const _BigInitial({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceSecondary,
      alignment: Alignment.center,
      child: Text(
        priest.initial,
        style: GoogleFonts.inter(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: AppColors.primaryBrown.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

// ─── Info column (name + dot · denomination · rating) ──────
//
// Tags moved OUT of the info column to a full-width row below the
// main card body — see _SessionSpeakerCardState._buildBody. That keeps
// the info column at exactly three lines and gives tags real horizontal
// room to render full spec names instead of truncating to "Co...".

class _InfoColumn extends StatelessWidget {
  final SpeakerModel priest;
  const _InfoColumn({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1 — Name followed by an inline 8-px status dot. The dot
        // sits at a fixed position relative to the name's last visible
        // character: a long name ellipsises before pushing the dot off,
        // a short name leaves predictable trailing space. No wrapping
        // pill = no inconsistent rhythm across cards.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Builder(
                builder: (ctx) {
                  final scale = _typeScale(ctx);
                  return Text(
                    priest.fullName.isNotEmpty
                        ? priest.fullName
                        : 'Speaker',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 17 * scale,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      height: 1.2,
                      color: AppColors.black,
                    ),
                  );
                },
              ),
            ),
            if (_inlineDotColor(priest) != null) ...[
              const SizedBox(width: 6),
              _InlineStatusDot(color: _inlineDotColor(priest)!),
            ],
          ],
        ),
        const SizedBox(height: 4),
        // Row 2 — Role / denomination.
        Builder(builder: (ctx) {
          final scale = _typeScale(ctx);
          return Text(
            _roleLabel(priest),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 13 * scale,
              fontWeight: FontWeight.w400,
              color: AppColors.primaryBrown.withValues(alpha: 0.7),
            ),
          );
        }),
        const SizedBox(height: 4),
        // Row 3 — Rating, OR "New" badge when reviewCount == 0. Never
        // shows a star next to a missing rating.
        _RatingOrNewRow(
          rating: priest.rating,
          reviewCount: priest.reviewCount,
          years: priest.yearsOfExperience,
        ),
      ],
    );
  }

  // Inline dot is shown for Online and Busy only — Offline collapses
  // to no dot, since the action column already swaps to "Notify me"
  // which signals unavailability.
  Color? _inlineDotColor(SpeakerModel p) {
    if (p.isAvailable) return _kVibrantGreen;
    if (p.isOnline && p.isBusy) return AppColors.amberGold;
    return null;
  }

  String _roleLabel(SpeakerModel p) {
    if (p.subDenomination.isNotEmpty) return p.subDenomination;
    if (p.denomination.isNotEmpty) return p.denomination;
    return 'Spiritual Speaker';
  }
}

// 8-px solid status dot with a 2-px white halo ring — the halo lets it
// read clearly against any surface (card white, cream banner, etc).
class _InlineStatusDot extends StatelessWidget {
  final Color color;
  const _InlineStatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _C.inlineDotSize,
      height: _C.inlineDotSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: AppColors.surfaceWhite, width: 2),
      ),
    );
  }
}

// Rating row — single line. Review count is intentionally omitted so
// the row reads the same way for every speaker. Years of experience
// is always the trailing piece when present.
//
//   With rating:    ⭐ 3.7 · 5+ yrs       (or ⭐ 3.7 if no years)
//   Empty rating:   5+ yrs exp            (or [New] if no years either)
class _RatingOrNewRow extends StatelessWidget {
  final double rating;
  final int reviewCount;
  final int years;

  const _RatingOrNewRow({
    required this.rating,
    required this.reviewCount,
    required this.years,
  });

  @override
  Widget build(BuildContext context) {
    final hasRating = rating > 0 && reviewCount > 0;
    final hasYears = years > 0;
    final scale = _typeScale(context);

    final metaStyle = GoogleFonts.inter(
      fontSize: 12.5 * scale,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.05,
      color: AppColors.primaryBrown.withValues(alpha: 0.72),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    if (!hasRating) {
      // No rating yet — show years alone, or "New" badge as last resort.
      if (hasYears) {
        return Text(
          '$years+ yrs exp',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metaStyle,
        );
      }
      return const _NewBadge();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(
          AppIcons.starFilled,
          size: 13 * scale,
          color: AppColors.amberGold,
        ),
        SizedBox(width: 5 * scale),
        Text(
          rating.toStringAsFixed(1),
          style: GoogleFonts.inter(
            fontSize: 13.5 * scale,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
            color: AppColors.black.withValues(alpha: 0.82),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (hasYears) ...[
          const _Dot(),
          Flexible(
            child: Text(
              '$years+ yrs',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: metaStyle,
            ),
          ),
        ],
      ],
    );
  }
}

// Compact "New" badge — used when a speaker has zero reviews. Soft
// primaryBrown tint so it stays inside the warm palette without
// shouting like a "NEW!" promo badge would.
class _NewBadge extends StatelessWidget {
  const _NewBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'New',
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          color: AppColors.primaryBrown,
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text(
        '·',
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.black.withValues(alpha: 0.32),
        ),
      ),
    );
  }
}

// Chip typography + geometry constants. _TagsRow uses these directly
// in its TextPainter measure pass so the fit calculation matches what
// _Chip actually renders. Any change here MUST mirror _Chip's build()
// values — they're the contract between layout-fit and paint-time.
const double _kChipHPad = 10;
const double _kChipVPad = 4;
const double _kChipGap = 6;
const double _kChipFontSize = 11;
const FontWeight _kChipFontWeight = FontWeight.w500;

// Tags row — single line, no wrap, no ellipsis. Greedy-fits as many
// chips as the row can hold at their FULL natural width, plus the
// "+N" overflow indicator whenever there are hidden specs.
//
// Algorithm:
//   1. Try to render `min(specs.length, maxChips)` chips. If the
//      total intrinsic width (incl. the "+N" chip if applicable)
//      fits within the row's available width, use that count.
//   2. Otherwise drop one chip and retry, all the way down to 1.
//   3. If even one chip + "+N" doesn't fit, fall back to showing
//      only "+specs.length" (the user still gets the count signal
//      without any truncated chip).
//
// The "+N" chip is ALWAYS rendered when there are hidden specs, no
// matter how few visible chips we end up with — that's the user's
// only signal that more specialisations exist. Visible chips are
// rendered at their intrinsic width with NO ellipsis: a chip either
// fits in full or it doesn't appear, so the user never sees a
// half-truncated "Counsel…" stub.
class _TagsRow extends StatelessWidget {
  final List<String> specs;

  // Upper bound on visible chips. Capped at 3 — beyond that the row
  // reads as a chip salad and the +N indicator carries the rest.
  static const int _maxChips = 3;

  const _TagsRow({required this.specs});

  @override
  Widget build(BuildContext context) {
    if (specs.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final fit = _planFit(maxWidth);
        return _buildRow(fit);
      },
    );
  }

  // Returns the chosen layout for this row: how many chips to show
  // (0 ≤ shown ≤ min(specs.length, _maxChips)) and how many to hide
  // behind the "+N" indicator.
  ({int shown, int hidden}) _planFit(double maxWidth) {
    final cap = math.min(specs.length, _maxChips);

    for (var shown = cap; shown >= 1; shown--) {
      final hidden = specs.length - shown;
      final total = _rowWidth(shown, hidden);
      if (total <= maxWidth) {
        return (shown: shown, hidden: hidden);
      }
    }

    // Even the smallest configuration (1 chip + maybe "+N") didn't
    // fit. Fall back to "+N-only" — communicates the count without
    // any half-visible chip on the right edge.
    return (shown: 0, hidden: specs.length);
  }

  // Measures the natural width of the row when `shown` visible chips
  // are followed by a "+hidden" indicator (no indicator when hidden
  // is 0). All measurements use a TextPainter so the layout decision
  // sees the same widths the paint pass will produce.
  double _rowWidth(int shown, int hidden) {
    double total = 0;
    for (var i = 0; i < shown; i++) {
      if (i > 0) total += _kChipGap;
      total += _measureChipWidth(specs[i]);
    }
    if (hidden > 0) {
      if (shown > 0) total += _kChipGap;
      total += _measureChipWidth('+$hidden');
    }
    return total;
  }

  double _measureChipWidth(String label) {
    final tp = TextPainter(
      maxLines: 1,
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: _kChipFontSize,
          fontWeight: _kChipFontWeight,
          // GoogleFonts.inter applies a fontFamily — leaving it null
          // here is acceptable because TextPainter uses the default
          // text run's advance-widths, which for the tight 11-px size
          // tracks Inter to within ~1 px. We add a small safety margin
          // in the caller to absorb that.
          fontFamily: 'Inter',
        ),
      ),
    )..layout();
    // 2 px safety margin per chip — absorbs font-fallback width drift
    // (Inter not yet loaded, fallback font slightly wider) and floating-
    // point rounding when comparing against constraints.maxWidth.
    return tp.width + _kChipHPad * 2 + 2;
  }

  Widget _buildRow(({int shown, int hidden}) fit) {
    final widgets = <Widget>[];
    for (var i = 0; i < fit.shown; i++) {
      if (i > 0) widgets.add(const SizedBox(width: _kChipGap));
      widgets.add(_Chip(label: specs[i]));
    }
    if (fit.hidden > 0) {
      if (widgets.isNotEmpty) widgets.add(const SizedBox(width: _kChipGap));
      widgets.add(_Chip(label: '+${fit.hidden}'));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: widgets);
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: _kChipHPad,
        vertical: _kChipVPad,
      ),
      decoration: BoxDecoration(
        color: _kTagBg,
        borderRadius: BorderRadius.circular(6),
      ),
      // No maxLines / overflow — _TagsRow only emits a chip when its
      // full intrinsic width fits the row, so we never paint a
      // truncated "Counsel…" stub. The Text widget renders the label
      // verbatim or not at all.
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: _kChipFontSize,
          fontWeight: _kChipFontWeight,
          color: AppColors.primaryBrown,
        ),
      ),
    );
  }
}

// ─── Action column (right-side pill stack) ──────────────────
//
//   • Available → Call (filled) + Chat (outlined) stacked, 6-px gap
//   • Busy/Offline → single Notify-me (outlined)

class _ActionColumn extends StatelessWidget {
  final SpeakerModel priest;
  final VoidCallback onCall;
  final VoidCallback onChat;
  final VoidCallback onNotify;

  const _ActionColumn({
    required this.priest,
    required this.onCall,
    required this.onChat,
    required this.onNotify,
  });

  @override
  Widget build(BuildContext context) {
    if (priest.isAvailable) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionPill(
            icon: AppIcons.phone,
            label: 'Call',
            filled: true,
            onTap: onCall,
          ),
          const SizedBox(height: _C.actionPillGap),
          _ActionPill(
            icon: AppIcons.chatOutline,
            label: 'Chat',
            filled: false,
            onTap: onChat,
          ),
        ],
      );
    }
    // Busy + Offline both collapse to "Notify me". A busy priest can't
    // take a new session either, so the user's only useful action is
    // to subscribe to the back-online ping.
    return _ActionPill(
      icon: AppIcons.bellOutline,
      label: 'Notify me',
      filled: false,
      onTap: onNotify,
    );
  }
}

class _ActionPill extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _ActionPill({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  State<_ActionPill> createState() => _ActionPillState();
}

class _ActionPillState extends State<_ActionPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final BoxBorder? border;
    if (widget.filled) {
      bg = AppColors.primaryBrown;
      fg = AppColors.surfaceWhite;
      border = null;
    } else {
      bg = AppColors.surfaceWhite;
      fg = AppColors.primaryBrown;
      border = Border.all(
        color: AppColors.primaryBrown.withValues(alpha: 0.2),
        width: 1,
      );
    }

    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _pressed ? 0.92 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: _C.actionPillWidth,
              height: _C.actionPillHeight,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(_C.buttonRadius),
                border: border,
              ),
              alignment: Alignment.center,
              // Padding pulls the row contents in 6 px from each edge
              // so the visible bounds never touch the pill's rounded
              // corners. FittedBox scales the row down (preserving
              // proportion) on the rare case the icon+label exceeds
              // the pill's interior even with the width we've set —
              // overflow-proof at any text-scale setting.
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(widget.icon, size: 13, color: fg),
                      const SizedBox(width: 5),
                      Text(
                        widget.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── History row (compact WhatsApp-style) ───────────────────

class _HistoryRow extends StatefulWidget {
  final PriestSessionGroup priest;
  final VoidCallback onTap;

  const _HistoryRow({required this.priest, required this.onTap});

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

// WhatsApp-style date formatter for the row's trailing timestamp.
//
//   Today           → "h:mm AM/PM"
//   Yesterday       → "Yesterday"
//   Within last 7d  → "Mon" / "Tue" / etc.
//   Older this year → "DD/MM"
//   Older year      → "DD/MM/YY"
//
// Locale-independent intentionally — the strings sit in the row's
// tight right edge and need predictable width.
String _whatsappDate(DateTime? at) {
  if (at == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(at.year, at.month, at.day);
  final dayDiff = today.difference(that).inDays;

  if (dayDiff == 0) {
    final hour12 = at.hour == 0 ? 12 : (at.hour > 12 ? at.hour - 12 : at.hour);
    final mm = at.minute.toString().padLeft(2, '0');
    final period = at.hour >= 12 ? 'PM' : 'AM';
    return '$hour12:$mm $period';
  }
  if (dayDiff == 1) return 'Yesterday';
  if (dayDiff < 7) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[at.weekday - 1];
  }
  final dd = at.day.toString().padLeft(2, '0');
  final mm = at.month.toString().padLeft(2, '0');
  if (at.year == now.year) return '$dd/$mm';
  final yy = (at.year % 100).toString().padLeft(2, '0');
  return '$dd/$mm/$yy';
}

class _HistoryRowState extends State<_HistoryRow> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final p = widget.priest;

    // Preview line. Priority:
    //   1. Real last message text — prefixed with "You: " when the
    //      signed-in user sent it (WhatsApp convention).
    //   2. Fallback to "Last call · X min" / "Last chat" when we
    //      don't have a message (voice-only history, or fetch
    //      failure).
    final hasMsg = (p.lastMessageText ?? '').isNotEmpty;
    final isVoice = p.lastSessionType == 'voice';
    final typeIcon = hasMsg
        ? AppIcons.chatOutline
        : (isVoice ? AppIcons.phone : AppIcons.chatOutline);
    final String subtitle;
    if (hasMsg) {
      final prefix = (p.lastMessageFromUser ?? false) ? 'You: ' : '';
      subtitle = '$prefix${p.lastMessageText}';
    } else if (p.lastSessionAt == null) {
      subtitle = 'Tap to continue';
    } else if (isVoice) {
      subtitle = p.lastSessionDuration > 0
          ? 'Last call · ${p.lastSessionDuration} min'
          : 'Last call';
    } else {
      subtitle = 'Last chat';
    }

    // Use the most-recent activity (message OR session) for the date —
    // a follow-up message yesterday should outrank a session 3d ago.
    final dateText = _whatsappDate(p.lastActivityAt);

    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.985),
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
            padding: const EdgeInsets.symmetric(
              horizontal: _C.horizPad,
              vertical: 12,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _HistoryAvatar(priest: p),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Row 1: name (left) + date (right) on one line.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text(
                              p.priestName.isNotEmpty
                                  ? p.priestName
                                  : 'Speaker',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: AppColors.black,
                              ),
                            ),
                          ),
                          if (dateText.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              dateText,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.05,
                                // Always muted brown — status is
                                // signaled by the avatar dot, not the
                                // date colour.
                                color: AppColors.primaryBrown
                                    .withValues(alpha: 0.75),
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Row 2: type icon + preview text. Higher
                      // contrast than before — preview is now the
                      // primary content of the row, so it earns the
                      // weight bump.
                      Row(
                        children: [
                          AppIcon(
                            typeIcon,
                            size: 12,
                            color: AppColors.primaryBrown
                                .withValues(alpha: 0.75),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: AppColors.primaryBrown
                                    .withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _HistoryAvatar extends StatelessWidget {
  final PriestSessionGroup priest;
  const _HistoryAvatar({required this.priest});

  @override
  Widget build(BuildContext context) {
    // Deleted priest → neutral placeholder glyph, never an initial
    // derived from "Unavailable" (which would read as a stray "U").
    final initial = priest.isDeleted
        ? '?'
        : (priest.priestName.isNotEmpty
            ? priest.priestName[0].toUpperCase()
            : '?');
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
              borderRadius: BorderRadius.circular(_C.innerRadius),
              color: AppColors.surfaceSecondary,
            ),
            clipBehavior: Clip.antiAlias,
            child: priest.isDeleted
                ? Center(
                    child: AppIcon(
                      AppIcons.userOutline,
                      size: 22,
                      color: AppColors.muted.withValues(alpha: 0.6),
                    ),
                  )
                : (priest.priestPhotoUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: priest.priestPhotoUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => const SizedBox.shrink(),
                        errorWidget: (_, _, _) => _avatarFallback(initial),
                      )
                    : _avatarFallback(initial)),
          ),
          // Indicator dot stays circular — semantic status signal,
          // not chrome. Top-right placement matches the speaker card
          // avatar so both surfaces read as one system. Warm-cream
          // halo ring (matching the page background) carves the dot
          // out without the stark sticker look of pure white.
          // No status dot for a deleted priest — there's no live
          // presence to signal.
          if (!priest.isDeleted)
            Positioned(
              top: -1,
              right: -1,
              child: priest.isAvailable
                  ? _PulsingHaloDot(color: _kVibrantGreen)
                  : Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: priest.isBusy
                            ? AppColors.amberGold
                            : AppColors.muted.withValues(alpha: 0.4),
                        border: Border.all(
                          color: AppColors.backgroundPrimary,
                          width: 1.5,
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _avatarFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.primaryBrown.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

// ─── Trust banner (bottom of both lists) ────────────────────

class _TrustBanner extends StatelessWidget {
  const _TrustBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(_C.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.surfaceCream,
        borderRadius: BorderRadius.circular(_C.cardRadius),
        border: Border.all(color: _kHairline, width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_C.buttonRadius),
              color: AppColors.primaryBrown,
            ),
            alignment: Alignment.center,
            child: const AppIcon(
              AppIcons.shield,
              size: 16,
              color: AppColors.surfaceWhite,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'All our speakers are verified',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.black,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Your privacy and trust are our priority.',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.primaryBrown.withValues(alpha: 0.6),
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

// ─── Empty / error / shimmer states ─────────────────────────

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(_C.cardRadius),
        border: Border.all(color: _kCardBorder, width: 1),
        boxShadow: _kRefinedShadow,
      ),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_C.innerRadius),
              color: AppColors.primaryBrown.withValues(alpha: 0.06),
            ),
            alignment: Alignment.center,
            child: AppIcon(
              icon,
              size: 22,
              color: AppColors.primaryBrown.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.black,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.primaryBrown.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryEmpty extends StatelessWidget {
  final bool isFiltered;
  final bool hasAnyHistory;

  const _HistoryEmpty({
    required this.isFiltered,
    required this.hasAnyHistory,
  });

  @override
  Widget build(BuildContext context) {
    final title = isFiltered ? 'No matches' : 'No sessions yet';
    final subtitle = isFiltered
        ? "No speakers match that. Try 'healing' or 'family.'"
        : 'Talk to a speaker from the Speakers tab and they\'ll appear here.';

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 40),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.10),
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_C.innerRadius),
              color: AppColors.primaryBrown.withValues(alpha: 0.06),
            ),
            alignment: Alignment.center,
            child: AppIcon(
              isFiltered ? AppIcons.search : AppIcons.chats,
              size: 30,
              color: AppColors.primaryBrown.withValues(alpha: 0.4),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.black,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            height: 1.45,
            color: AppColors.primaryBrown.withValues(alpha: 0.6),
          ),
        ),
        if (!hasAnyHistory && !isFiltered) ...[
          const SizedBox(height: 20),
          Center(child: _BrowseSpeakersButton()),
        ],
      ],
    );
  }
}

class _BrowseSpeakersButton extends StatefulWidget {
  @override
  State<_BrowseSpeakersButton> createState() => _BrowseSpeakersButtonState();
}

class _BrowseSpeakersButtonState extends State<_BrowseSpeakersButton> {
  double _scale = 1.0;

  void _onTap() {
    HapticFeedback.lightImpact();
    final state =
        context.findAncestorStateOfType<_SessionsTabState>();
    state?._switchTab(0);
    if (state == null) {
      UserShellScope.of(context)?.switchToTab(0);
    }
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
              vertical: 11,
            ),
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Browse Speakers',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.surfaceWhite,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.primaryBrown.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Retry',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.surfaceWhite,
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

class _SpeakersShimmer extends StatelessWidget {
  const _SpeakersShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.primaryBrown.withValues(alpha: 0.06),
      highlightColor: AppColors.primaryBrown.withValues(alpha: 0.02),
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          _C.horizPad,
          0,
          _C.horizPad,
          _C.listBottomPad,
        ),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(height: _C.listCardGap),
        itemBuilder: (_, _) => Container(
          height: 120,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_C.cardRadius),
          ),
        ),
      ),
    );
  }
}

class _HistoryShimmer extends StatelessWidget {
  const _HistoryShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.primaryBrown.withValues(alpha: 0.06),
      highlightColor: AppColors.primaryBrown.withValues(alpha: 0.02),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(_C.horizPad, 4, _C.horizPad, 0),
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
