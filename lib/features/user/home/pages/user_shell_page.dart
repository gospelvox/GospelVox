// Root shell for the signed-in listener role — an IndexedStack with
// a custom pill bottom-nav. We hold all top-level tab children alive
// at the same time so switching between them feels instant and
// preserves scroll position; only the active tab paints.
//
// Why expose the tab-switcher via an InheritedWidget: the home tab's
// coin pill needs to jump to the wallet tab without navigating
// routes (a route push would put the wallet on top of the shell and
// hide the nav bar). `UserShellScope.of(context)?.switchToTab(i)`
// gives child widgets a clean, typed way to ask the shell to change
// its selected index, without passing callbacks through the tree.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/user/home/pages/home_page.dart';
import 'package:gospel_vox/features/user/wallet/pages/wallet_page.dart';

class UserShellPage extends StatefulWidget {
  const UserShellPage({super.key});

  @override
  State<UserShellPage> createState() => _UserShellPageState();
}

class _UserShellPageState extends State<UserShellPage> {
  int _currentIndex = 0;

  void _switchToTab(int index) {
    if (index == _currentIndex) return;
    if (index < 0 || index > 4) return;
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
            _PlaceholderTab(title: "Matrimony", icon: Icons.favorite_outline),
            _PlaceholderTab(title: "Bible", icon: Icons.menu_book_outlined),
            WalletPage(),
            _PlaceholderTab(title: "Me", icon: Icons.person_outline),
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
                activeIcon: Icons.home,
                label: "Home",
                onTap: () => _switchToTab(0),
              ),
              _NavItem(
                index: 1,
                currentIndex: _currentIndex,
                inactiveIcon: Icons.favorite_outline,
                activeIcon: Icons.favorite,
                label: "Matrimony",
                onTap: () => _switchToTab(1),
              ),
              _NavItem(
                index: 2,
                currentIndex: _currentIndex,
                inactiveIcon: Icons.menu_book_outlined,
                activeIcon: Icons.menu_book,
                label: "Bible",
                onTap: () => _switchToTab(2),
              ),
              _NavItem(
                index: 3,
                currentIndex: _currentIndex,
                inactiveIcon: Icons.account_balance_wallet_outlined,
                activeIcon: Icons.account_balance_wallet,
                label: "Wallet",
                onTap: () => _switchToTab(3),
              ),
              _NavItem(
                index: 4,
                currentIndex: _currentIndex,
                inactiveIcon: Icons.person_outline,
                activeIcon: Icons.person,
                label: "Me",
                onTap: () => _switchToTab(4),
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
// auto-subscribe (updateShouldNotify returns false) because tab
// transitions shouldn't force unrelated widgets to rebuild — the
// shell itself already reacts to index changes via setState.
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

  const _NavItem({
    required this.index,
    required this.currentIndex,
    required this.inactiveIcon,
    required this.activeIcon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = index == currentIndex;

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
                Icon(
                  isActive ? activeIcon : inactiveIcon,
                  size: 22,
                  color: isActive ? Colors.white : AppColors.muted,
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

class _PlaceholderTab extends StatelessWidget {
  final String title;
  final IconData icon;

  const _PlaceholderTab({
    required this.title,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 48,
              color: AppColors.muted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Coming Soon",
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppColors.muted.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
