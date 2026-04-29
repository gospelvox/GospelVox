// Slide-down "you're offline" banner that lives above every screen.
//
// Wired into MaterialApp.router's `builder:` so it overlays the
// active route without being part of any single page's tree —
// changing tabs, pushing routes, signing in/out: the banner persists
// at the top, transparent over whatever is behind it.
//
// Why a SafeArea-aware overlay instead of a Snackbar:
//   • Snackbars get dismissed by route transitions and gestures.
//   • An overlay banner stays visible until connectivity returns,
//     so users on a flaky connection don't miss the message.
//   • Tapping it doesn't steal focus from the page below — it's
//     informational, not interactive (apart from the close button).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/connectivity_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';

class OfflineBanner extends StatefulWidget {
  final Widget child;
  const OfflineBanner({super.key, required this.child});

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  StreamSubscription<bool>? _sub;
  bool _isOnline = true;
  bool _userDismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    final svc = ConnectivityService();
    _isOnline = svc.isOnline;
    if (!_isOnline) _controller.value = 1;

    _sub = svc.onChanged.listen((online) {
      if (!mounted) return;
      setState(() {
        _isOnline = online;
        // Coming back online clears the user-dismissed flag so the
        // banner reappears the next time the network drops.
        if (online) _userDismissed = false;
      });
      if (online) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (!_isOnline && !_userDismissed)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: SlideTransition(
                position: _slide,
                child: _BannerCard(
                  onDismiss: () => setState(() => _userDismissed = true),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  final VoidCallback onDismiss;
  const _BannerCard({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.deepDarkBrown,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.deepDarkBrown.withValues(alpha: 0.18),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.amberGold.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 18,
                  color: AppColors.amberGold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "You're offline",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Sign-in, sessions, and notifications need internet. "
                      "Reconnect to continue.",
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        height: 1.4,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.7),
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
