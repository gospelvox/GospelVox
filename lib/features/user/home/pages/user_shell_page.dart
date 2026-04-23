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

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';
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
            _MeTab(),
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

// Temporary "Me" tab — hosts a minimal sign-out button so we can
// switch roles during development without having to clear app
// storage. Expand with real profile/account tiles later.
class _MeTab extends StatefulWidget {
  const _MeTab();

  @override
  State<_MeTab> createState() => _MeTabState();
}

class _MeTabState extends State<_MeTab> {
  bool _signingOut = false;

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);

    try {
      // Cached role must be cleared BEFORE the auth.signOut write —
      // the router's redirect fires the instant the auth state
      // changes, and a stale cache would route the next role
      // selection back to the previous role's shell.
      clearCachedRole();
      await sl<AuthRepository>().signOut();
      if (!mounted) return;
      context.go('/select-role');
    } catch (_) {
      if (!mounted) return;
      setState(() => _signingOut = false);
      AppSnackBar.error(context, 'Failed to sign out. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.displayName ?? '';
    final email = user?.email ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Me',
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceWhite,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppColors.muted.withValues(alpha: 0.08),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primaryBrown
                            .withValues(alpha: 0.08),
                      ),
                      child: Icon(
                        Icons.person_outline_rounded,
                        size: 22,
                        color: AppColors.primaryBrown,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isNotEmpty ? name : 'Signed in',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.deepDarkBrown,
                            ),
                          ),
                          if (email.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              _SignOutButton(
                signingOut: _signingOut,
                onTap: _signOut,
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Temporary — signs you out so you can switch roles.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.7),
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

class _SignOutButton extends StatefulWidget {
  final bool signingOut;
  final VoidCallback onTap;

  const _SignOutButton({
    required this.signingOut,
    required this.onTap,
  });

  @override
  State<_SignOutButton> createState() => _SignOutButtonState();
}

class _SignOutButtonState extends State<_SignOutButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.signingOut;

    return Listener(
      onPointerDown: (_) {
        if (!disabled) setState(() => _scale = 0.97);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.errorRed.withValues(
                alpha: disabled ? 0.5 : 1.0,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: disabled
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.logout_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Sign Out',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
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
