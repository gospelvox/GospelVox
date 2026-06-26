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

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _currentIndex = 0;
  // Stream of upcoming-session count for the Bible nav badge.
  // Created once in initState (not per-build) so we don't churn
  // a new Firestore subscription on every shell rebuild.
  late final Stream<int> _bibleUpcomingCount;

  // Hide-on-scroll controller. value 0 = fully visible, value 1 =
  // fully hidden (slid down by nav height + bottom inset + margin).
  late final AnimationController _hideController;

  // Keyboard-tracking state. When the on-screen keyboard opens, the
  // Scaffold body shrinks to viewInsets.bottom — without this hook,
  // the floating nav would sit just above the keyboard (instead of
  // staying anchored to the screen edge), which looks like the nav
  // teleported up onto the keyboard. We slide it off-screen via the
  // existing hide-controller while the keyboard is up, and restore
  // whatever pre-keyboard state it had when the keyboard closes.
  bool _wasKeyboardOpen = false;
  double _navStateBeforeKeyboard = 0.0;

  // Timestamp of the last unhandled back press on the Home tab, for the
  // "press back again to exit" double-tap guard. Null until the first
  // back press; reset implicitly by the 2s window check.
  DateTime? _lastBackPressed;

  @override
  void initState() {
    super.initState();
    // Count only GENUINE upcoming sessions — exclude dead/never-started
    // ones (scheduled slot + duration + 15min grace already passed).
    // Those are hidden from the Bible Upcoming tab, so counting raw
    // `snapshot.size` here would make the nav badge show MORE than the
    // list the user actually sees. Map through the model and filter by
    // isExpiredUpcoming so the badge matches the tab exactly.
    _bibleUpcomingCount = FirebaseFirestore.instance
        .collection('bible_sessions')
        .where('status', isEqualTo: 'upcoming')
        .snapshots()
        .map((s) => s.docs
            .map((d) => BibleSessionModel.fromFirestore(d.id, d.data()))
            .where((m) => !m.isExpiredUpcoming)
            .length);

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
    //
    // Push permission is requested here (not at app launch) so the
    // dialog only appears once the user has signed in and landed on
    // their real home — Play / Apple HIG both flag cold-start prompts.
    // The call is idempotent and process-flagged inside the service,
    // so re-mounting the shell doesn't re-prompt.
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _drainPendingRoute();
      unawaited(NotificationService().requestPermissionsIfNeeded());
    });
  }

  // Drains a stashed notification-tap route. Called on mount (cold-
  // start tap) AND on resume (background tap) — the latter is why this
  // is factored out: a tap that resumes an already-mounted shell never
  // re-runs initState, so without the resume path the route would sit
  // un-applied and the notification would appear to "do nothing".
  // Skips '/user' (already there) and empty.
  void _drainPendingRoute() {
    final route = NotificationService.pendingRoute;
    NotificationService.pendingRoute = null;
    if (route != null && route.isNotEmpty && route != '/user' && mounted) {
      context.push(route);
    }
  }

  // Hardware-back handler for the shell (the only route on the stack
  // while the user is on a main tab). Two-stage guard so a stray back
  // press never drops the user out of the app:
  //   1. Not on Home → switch to Home first (standard tabbed-app back).
  //   2. On Home → require a second back within 2s to actually exit.
  void _onBackInvoked(bool didPop, Object? result) {
    if (didPop) return;
    if (_currentIndex != 0) {
      _switchToTab(0);
      return;
    }
    final now = DateTime.now();
    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      AppSnackBar.info(context, 'Press back again to exit');
      return;
    }
    SystemNavigator.pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Deferred a frame so navigation runs after the resume settles.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _drainPendingRoute());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideController.dispose();
    super.dispose();
  }

  // Fires whenever ancestor inherited widgets change — including
  // MediaQuery, which updates when the on-screen keyboard opens or
  // closes. We diff the keyboard state and drive the hide-controller
  // accordingly so the floating nav slides off-screen with the same
  // 220 ms animation it uses for the scroll-based hide.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    if (keyboardOpen == _wasKeyboardOpen) return;
    _wasKeyboardOpen = keyboardOpen;

    if (keyboardOpen) {
      // Remember whatever scroll-state the nav was in so we can
      // restore it on close (don't fight the scroll listener).
      _navStateBeforeKeyboard = _hideController.value;
      _hideController.forward();
    } else {
      // Restore: if the nav was hidden because of scroll, keep it
      // hidden; otherwise reveal.
      if (_navStateBeforeKeyboard >= 0.5) {
        _hideController.forward();
      } else {
        _hideController.reverse();
      }
    }
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
  //
  // IMPORTANT: only vertical scrolls count. A horizontal PageView
  // swipe inside a tab (e.g., Sessions → Speakers ↔ History) fires
  // the same UserScrollNotification with a `reverse`/`forward`
  // direction, which would otherwise be mistaken for "user is
  // scrolling content downward" and would yank the bottom nav off-
  // screen mid-swipe. Filtering by axis keeps the hide-on-scroll
  // behaviour scoped to vertical content scrolls only.
  bool _onScroll(UserScrollNotification n) {
    // Persistent bottom nav: the nav stays fixed on screen at all times
    // and never hides on scroll. Earlier builds slid it away on a
    // downward drag (driving _hideController), but users reported the
    // nav "disappearing" on the matrimony tab and others, so the
    // hide-on-scroll behaviour is intentionally disabled. We keep
    // _hideController pinned at 0 (fully visible) and just let the
    // notification keep bubbling.
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
      child: PopScope(
        // We own the back gesture on the shell so a stray back press
        // can't drop the user straight out of the app (handled in
        // _onBackInvoked: tab→Home first, then press-again-to-exit).
        canPop: false,
        onPopInvokedWithResult: _onBackInvoked,
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
