// Slide-down in-app banner that fires when an FCM message of
// type=missed_request arrives while the app is in foreground.
// Sits at MaterialApp.router.builder alongside OfflineBanner so
// it overlays every screen — same persistence model: route
// changes don't dismiss it.
//
// Why this exists separately from the system local-notification:
//   • OEM-themed Android (Xiaomi / Realme / Oppo / some Samsung)
//     suppresses Importance.high heads-up banners while the app
//     is foregrounded. Priests on those devices saw absolutely
//     nothing when a missed request landed — the system banner
//     was relegated silently to the tray.
//   • Reusing the system banner with Importance.max would be
//     intrusive for a non-incoming-call event. A dedicated
//     in-app pill banner reads as informational, matches the
//     dashboard banner's amber language, and is still impossible
//     to miss.
//
// Tap = navigate to /priest/my-users (the route the FCM payload
// already carries; we honour it rather than hard-coding so a
// future CF change can redirect without an app update).
//
// Auto-dismiss after 6s. Manual dismiss via tap-X. Both clear
// the ValueNotifier so a back-to-back missed request a few
// seconds later still triggers a fresh slide-in.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';

class MissedRequestForegroundBanner extends StatefulWidget {
  final Widget child;
  const MissedRequestForegroundBanner({super.key, required this.child});

  @override
  State<MissedRequestForegroundBanner> createState() =>
      _MissedRequestForegroundBannerState();
}

class _MissedRequestForegroundBannerState
    extends State<MissedRequestForegroundBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;

  MissedRequestForegroundEvent? _current;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    NotificationService.foregroundMissedRequestEvent
        .addListener(_onEventChanged);
  }

  @override
  void dispose() {
    NotificationService.foregroundMissedRequestEvent
        .removeListener(_onEventChanged);
    _autoDismiss?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onEventChanged() {
    if (!mounted) return;
    final next = NotificationService.foregroundMissedRequestEvent.value;
    if (next == null) return;

    setState(() => _current = next);
    _controller.forward(from: 0);

    _autoDismiss?.cancel();
    _autoDismiss = Timer(const Duration(seconds: 6), _dismiss);
  }

  Future<void> _dismiss() async {
    _autoDismiss?.cancel();
    await _controller.reverse();
    if (!mounted) return;
    setState(() => _current = null);
    // Clear so the next missed request triggers a fresh listener
    // tick; the notifier compares values, so reassigning the same
    // event object would be a no-op.
    NotificationService.foregroundMissedRequestEvent.value = null;
  }

  void _onTap() {
    // Tap always lands on the dedicated missed-requests page. We
    // ignore the FCM-supplied `route` because the CF still writes
    // the legacy "/priest/my-users" deep link — overriding here
    // (and in NotificationService for the cold-tap path) is the
    // client-side fix until the CF can be redeployed.
    _dismiss();
    // Use the global appRouter rather than the in-tree context —
    // the banner sits above the Navigator so its BuildContext does
    // not have a GoRouter ancestor.
    appRouter.push('/priest/missed-requests');
  }

  @override
  Widget build(BuildContext context) {
    final event = _current;
    return Stack(
      children: [
        widget.child,
        if (event != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: SlideTransition(
                position: _slide,
                child: _BannerCard(
                  key: ValueKey(event.id),
                  body: event.body,
                  onTap: _onTap,
                  onDismiss: _dismiss,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BannerCard extends StatefulWidget {
  final String body;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _BannerCard({
    super.key,
    required this.body,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  State<_BannerCard> createState() => _BannerCardState();
}

class _BannerCardState extends State<_BannerCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Listener(
          onPointerDown: (_) => setState(() => _scale = 0.98),
          onPointerUp: (_) => setState(() => _scale = 1.0),
          onPointerCancel: (_) => setState(() => _scale = 1.0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _scale,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.deepDarkBrown,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.deepDarkBrown.withValues(alpha: 0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.amberGold.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.phone_missed_rounded,
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
                            widget.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Tap to respond',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onDismiss,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
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
          ),
        ),
      ),
    );
  }
}
