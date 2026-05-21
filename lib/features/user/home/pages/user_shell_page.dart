// Root shell for the signed-in user role — an IndexedStack with a
// custom floating bottom-nav. We hold all top-level tab children
// alive at the same time so switching between them feels instant and
// preserves scroll position; only the active tab paints.
//
// Why expose the tab-switcher via an InheritedWidget: the Me tab's
// "My Sessions" row needs to jump to the Sessions tab without
// navigating routes — a route push would put the page on top of the
// shell and hide the nav bar. `UserShellScope.of(context)?.switchToTab(i)`
// gives child widgets a clean, typed way to ask the shell to change
// its selected index, without passing callbacks through the tree.
//
// Tab indices:
//   0  Home
//   1  Sessions (WhatsApp-style priest history)
//   2  Bible
//   3  Me
//
// Hide-on-scroll: the nav slides down off-screen when the user
// scrolls toward more content, and slides back up when they reverse.
// Driven by a NotificationListener<UserScrollNotification> +
// AnimationController. We deliberately animate via a scoped
// AnimatedBuilder around a Transform.translate so:
//   * The HomePage / other tab subtrees never rebuild on ticks
//     (Transform is composite-only, no layout).
//   * The IndexedStack never rebuilds on ticks (animation state lives
//     outside the shell's setState path).
//   * Content scrolls *behind* the nav rather than reflowing when it
//     hides — reflow during scroll is the #1 cause of jank in this
//     kind of UI.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/user/bible/pages/bible_tab.dart';
import 'package:gospel_vox/features/user/home/pages/home_page.dart';
import 'package:gospel_vox/features/user/home/widgets/floating_bottom_nav.dart';
import 'package:gospel_vox/features/user/matrimony/pages/matrimony_tab.dart';
import 'package:gospel_vox/features/user/profile/pages/me_tab.dart';
import 'package:gospel_vox/features/user/sessions/pages/sessions_tab.dart';

// Layout constants for the floating nav. Kept module-private — the
// shell needs them to compute the slide-down distance and to apply
// the correct bottom padding to the tab content.
const double _kNavSideMargin = 16;
const double _kNavBottomMargin = 12;

// Matrimony is appended as tab 4 (not inserted at 2) so existing
// callers of UserShellScope.switchToTab(0..3) keep working unchanged.
// Visual position in the nav row is still centre — that ordering is
// handled inside FloatingBottomNav.
const int _kMatrimonyTabIndex = 4;
const int _kMaxTabIndex = 4;

class UserShellPage extends StatefulWidget {
  const UserShellPage({super.key});

  @override
  State<UserShellPage> createState() => _UserShellPageState();
}

class _UserShellPageState extends State<UserShellPage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  // Stream of upcoming-session count for the Bible nav badge.
  // Created once in initState (not per-build) so we don't churn
  // a new Firestore subscription on every shell rebuild.
  late final Stream<int> _bibleUpcomingCount;

  // Hide-on-scroll controller. value 0 = fully visible, value 1 =
  // fully hidden (slid down by nav height + bottom inset + margin).
  late final AnimationController _hideController;

  // Last scroll direction we acted on. UserScrollNotification can
  // fire repeatedly with the same direction during a single drag —
  // tracking the last value lets us skip redundant forward()/reverse()
  // calls and keeps the animation controller from being thrashed.
  ScrollDirection _lastDirection = ScrollDirection.idle;

  @override
  void initState() {
    super.initState();
    _bibleUpcomingCount = FirebaseFirestore.instance
        .collection('bible_sessions')
        .where('status', isEqualTo: 'upcoming')
        .snapshots()
        .map((s) => s.size);

    _hideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );

    // Drain any pending notification-tap route. A tap from terminated
    // state stashes the route during NotificationService.init(); the
    // shell is the first screen mounted after auth gating, so this is
    // the earliest place GoRouter is guaranteed to be ready.
    //
    // Skip if the route is "/user" (we're already there) or empty.
    // Pushing the shell on top of itself would stack two of them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = NotificationService.pendingRoute;
      NotificationService.pendingRoute = null;
      if (route == null || route.isEmpty || route == '/user') return;
      if (!mounted) return;
      context.push(route);
    });
  }

  @override
  void dispose() {
    _hideController.dispose();
    super.dispose();
  }

  void _switchToTab(int index) {
    if (index == _currentIndex) return;
    if (index < 0 || index > _kMaxTabIndex) return;
    setState(() => _currentIndex = index);
    // Always re-reveal the nav when the user explicitly changes tabs —
    // they just tapped it, so it shouldn't immediately slide away.
    _hideController.reverse();
  }

  // Scroll listener. Returning false lets the notification keep
  // bubbling (so RefreshIndicator etc. still receive it). We do NOT
  // call setState here — the AnimationController drives a scoped
  // AnimatedBuilder, which is the only thing that rebuilds.
  bool _onScroll(UserScrollNotification n) {
    final dir = n.direction;
    if (dir == _lastDirection) return false;
    _lastDirection = dir;

    if (dir == ScrollDirection.reverse) {
      // User dragging up to reveal content below → hide the nav.
      _hideController.forward();
    } else if (dir == ScrollDirection.forward) {
      // User dragging down toward earlier content → reveal the nav.
      _hideController.reverse();
    }
    // ScrollDirection.idle leaves the nav in its current state.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Distance the nav slides when fully hidden. Uses the nav's full
    // visual height (card + lifted FAB) plus its bottom margin and
    // safe-area inset so the entire affordance — including the
    // raised matrimony FAB — clears the screen edge.
    final hideDistance =
        kFloatingNavTotalHeight + _kNavBottomMargin + bottomInset + 8;

    return UserShellScope(
      currentIndex: _currentIndex,
      switchToTab: _switchToTab,
      child: Scaffold(
        backgroundColor: AppColors.backgroundPrimary,
        // extendBody lets the IndexedStack paint into the area
        // beneath the floating nav, so scrolling content slides
        // *behind* the nav instead of stopping above it.
        extendBody: true,
        body: NotificationListener<UserScrollNotification>(
          onNotification: _onScroll,
          child: Stack(
            children: [
              Positioned.fill(
                child: IndexedStack(
                  index: _currentIndex,
                  // Matrimony is appended at index 4 (visual centre
                  // is handled by FloatingBottomNav) so the existing
                  // switchToTab(0..3) call-sites keep their meanings.
                  children: const [
                    HomePage(),
                    SessionsTab(),
                    BibleTab(),
                    MeTab(),
                    MatrimonyTab(),
                  ],
                ),
              ),
              Positioned(
                left: _kNavSideMargin,
                right: _kNavSideMargin,
                bottom: _kNavBottomMargin + bottomInset,
                child: AnimatedBuilder(
                  animation: _hideController,
                  // child is built ONCE; AnimatedBuilder only rebuilds
                  // the Transform.translate on each tick. The nav's
                  // own paint layer is wrapped in a RepaintBoundary
                  // inside FloatingBottomNav, so ticking the Transform
                  // doesn't repaint the icons/labels either.
                  builder: (_, child) {
                    final dy = _hideController.value * hideDistance;
                    return Transform.translate(
                      offset: Offset(0, dy),
                      child: child,
                    );
                  },
                  child: StreamBuilder<int>(
                    stream: _bibleUpcomingCount,
                    builder: (_, snap) {
                      return FloatingBottomNav(
                        currentIndex: _currentIndex,
                        matrimonyIndex: _kMatrimonyTabIndex,
                        bibleBadgeCount: snap.data ?? 0,
                        onTap: _switchToTab,
                      );
                    },
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

// InheritedWidget providing tab-switch access to descendant widgets.
// Opt-in: children that don't need it never touch this. We don't
// auto-subscribe (updateShouldNotify only fires when the index
// actually changes) because tab transitions shouldn't force unrelated
// widgets to rebuild — the shell itself already reacts to index
// changes via setState.
class UserShellScope extends InheritedWidget {
  final int currentIndex;
  final void Function(int index) switchToTab;

  const UserShellScope({
    super.key,
    required this.currentIndex,
    required this.switchToTab,
    required super.child,
  });

  static UserShellScope? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<UserShellScope>();
  }

  @override
  bool updateShouldNotify(UserShellScope oldWidget) =>
      currentIndex != oldWidget.currentIndex;
}
