// Root shell for the signed-in user role — an IndexedStack with a
// custom pill bottom-nav. We hold all top-level tab children alive at
// the same time so switching between them feels instant and preserves
// scroll position; only the active tab paints.
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
// Sessions sits next to Home because it's a daily-use surface;
// Bible is a weekly cadence. Wallet is no longer a tab — it lives
// at /user/wallet as a push route, reached from the Home coin pill
// and the Me tab.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/user/bible/pages/bible_tab.dart';
import 'package:gospel_vox/features/user/home/pages/home_page.dart';
import 'package:gospel_vox/features/user/profile/pages/me_tab.dart';
import 'package:gospel_vox/features/user/sessions/pages/sessions_tab.dart';

class UserShellPage extends StatefulWidget {
  const UserShellPage({super.key});

  @override
  State<UserShellPage> createState() => _UserShellPageState();
}

class _UserShellPageState extends State<UserShellPage> {
  int _currentIndex = 0;
  // Stream of upcoming-session count for the Bible nav badge.
  // Created once in initState (not per-build) so we don't churn
  // a new Firestore subscription on every shell rebuild.
  late final Stream<int> _bibleUpcomingCount;

  @override
  void initState() {
    super.initState();
    _bibleUpcomingCount = FirebaseFirestore.instance
        .collection('bible_sessions')
        .where('status', isEqualTo: 'upcoming')
        .snapshots()
        .map((s) => s.size);
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

  void _switchToTab(int index) {
    if (index == _currentIndex) return;
    if (index < 0 || index > 3) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return UserShellScope(
      currentIndex: _currentIndex,
      switchToTab: _switchToTab,
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: const [
            HomePage(),
            SessionsTab(),
            BibleTab(),
            MeTab(),
          ],
        ),
        bottomNavigationBar: Container(
          height: 72 + MediaQuery.of(context).padding.bottom,
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 12,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                index: 0,
                currentIndex: _currentIndex,
                inactiveIcon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: "Home",
                onTap: () => _switchToTab(0),
              ),
              _NavItem(
                index: 1,
                currentIndex: _currentIndex,
                inactiveIcon: Icons.chat_outlined,
                activeIcon: Icons.chat_rounded,
                label: "Sessions",
                onTap: () => _switchToTab(1),
              ),
              StreamBuilder<int>(
                stream: _bibleUpcomingCount,
                builder: (_, snap) {
                  return _NavItem(
                    index: 2,
                    currentIndex: _currentIndex,
                    inactiveIcon: Icons.menu_book_outlined,
                    activeIcon: Icons.menu_book_rounded,
                    label: "Bible",
                    badgeCount: snap.data ?? 0,
                    onTap: () => _switchToTab(2),
                  );
                },
              ),
              _NavItem(
                index: 3,
                currentIndex: _currentIndex,
                inactiveIcon: Icons.person_outline,
                activeIcon: Icons.person_rounded,
                label: "Me",
                onTap: () => _switchToTab(3),
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

class _NavItem extends StatelessWidget {
  final int index;
  final int currentIndex;
  final IconData inactiveIcon;
  final IconData activeIcon;
  final String label;
  final VoidCallback onTap;
  // Optional badge rendered as a small amber pill over the icon's
  // upper-right corner. 0 hides it. Used by the Bible tab to
  // expose the upcoming-session count without forcing the user to
  // open the tab to see they have somewhere to be.
  final int badgeCount;

  const _NavItem({
    required this.index,
    required this.currentIndex,
    required this.inactiveIcon,
    required this.activeIcon,
    required this.label,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = index == currentIndex;
    // Cap the displayed count so a runaway upcoming list doesn't
    // bloat the badge wider than the icon. "9+" is the standard
    // iOS / Android convention.
    final badgeText = badgeCount > 9 ? '9+' : '$badgeCount';

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: isActive
                ? const EdgeInsets.symmetric(horizontal: 16, vertical: 6)
                : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: isActive ? AppColors.primaryBrown : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon + optional overlapping badge. Stack with
                // clipBehavior: Clip.none lets the badge pop outside
                // the 22-px icon bounds for the standard "notification
                // dot on icon corner" silhouette. Sized to 22 so the
                // row layout matches the no-badge variant exactly —
                // adding/removing the badge doesn't shift adjacent
                // items.
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        isActive ? activeIcon : inactiveIcon,
                        size: 22,
                        color:
                            isActive ? Colors.white : AppColors.muted,
                      ),
                      if (badgeCount > 0)
                        Positioned(
                          top: -6,
                          right: -8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 16,
                              minHeight: 14,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.amberGold,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.surfaceWhite,
                                width: 1.5,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              badgeText,
                              style: GoogleFonts.inter(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

