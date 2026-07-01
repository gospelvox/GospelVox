// Full-screen call-like overlay that fires when an FCM message of
// type=bible_session_live arrives while the app is in foreground.
// Sits at MaterialApp.router.builder OUTER to the missed-request
// banner — both can theoretically fire at once, and the bible-live
// overlay (more urgent — session is starting right now) wins
// z-order.
//
// Lifecycle:
//   • _onEventChanged — fires whenever the service pushes a new
//     event. We slide the overlay in, start the 1.5 s vibration
//     loop, and arm a 60 s auto-dismiss.
//   • _join / _decline / auto-dismiss — stops vibration, clears
//     the notifier, and (for join) routes to the bible detail
//     page via the global appRouter. Using the global router
//     rather than an in-tree context is necessary because the
//     overlay sits above the Navigator — its BuildContext does
//     not have a GoRouter ancestor.
//
// We deliberately do NOT play an audio ring (unlike the priest's
// incoming-session ring). A bible session starting is high-urgency
// but not a phone-call-quality interrupt — the visible overlay +
// heavy haptic pulse is enough signal. Audio would be over-
// aggressive for a many-attendee broadcast event.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/pulsing_dot.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

const Color _kLiveRed = AppColors.liveRed;
// Forest green for the Join CTA — distinct from primaryBrown and
// reads as "accept / go ahead" against the dark backdrop.
const Color _kJoinGreen = Color(0xFF059669);
// 60 seconds matches the missed-request banner's spiritual half-life
// — long enough for a user who set the phone down to wander back
// and notice, short enough that a stale prompt clears on its own
// instead of nagging forever.
const Duration _kAutoDismissAfter = Duration(seconds: 60);
// Vibration cadence — same 1.5 s pulse as the RingService priest
// ringer. Heavy-impact haptics on a periodic timer; cancelled in
// lock-step with the overlay teardown so a swipe-away doesn't keep
// buzzing the user's pocket.
const Duration _kVibrationInterval = Duration(milliseconds: 1500);

class BibleSessionLiveOverlay extends StatefulWidget {
  final Widget child;
  const BibleSessionLiveOverlay({super.key, required this.child});

  @override
  State<BibleSessionLiveOverlay> createState() =>
      _BibleSessionLiveOverlayState();
}

class _BibleSessionLiveOverlayState
    extends State<BibleSessionLiveOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;

  BibleSessionLiveEvent? _current;
  Timer? _autoDismiss;
  Timer? _vibrationTimer;
  // Firestore subscription on the session doc while the overlay is
  // showing. Without this, a session that the priest cancels OR that
  // the auto-complete cron flips to 'completed' while the overlay is
  // still on screen would keep showing "LIVE NOW" until the 60-second
  // auto-dismiss fires. Subscribed in _onEventChanged, cancelled in
  // _clear / dispose so we never leak the listener.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _statusSub;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    NotificationService.bibleSessionLiveEvent
        .addListener(_onEventChanged);
  }

  @override
  void dispose() {
    NotificationService.bibleSessionLiveEvent
        .removeListener(_onEventChanged);
    _autoDismiss?.cancel();
    _stopVibration();
    _statusSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onEventChanged() {
    if (!mounted) return;
    final next = NotificationService.bibleSessionLiveEvent.value;
    if (next == null) return;

    // Diagnostic — pairs with the foreground-FCM log in
    // NotificationService so a priest-side test can confirm the
    // notifier handoff actually reached the overlay listener.
    debugPrint(
      '[BibleOverlay] Event received: ${next.sessionTitle}',
    );

    // Paid-user fast-path: a returning paid user (multi-device, FCM
    // redelivery, cross-session bleed via legacy verify flow) should
    // not see the "Pay ₹X to join" call screen for a session they
    // already paid for. Probe their reg doc with a tight 3-second
    // timeout and, if paid, deep-link them straight to the detail
    // page (STATE D — link revealed) instead of popping the overlay.
    // On any error we fall through to the overlay — that's the safe
    // default for a not-paid user we couldn't classify.
    _maybeShowOverlay(next);
  }

  Future<void> _maybeShowOverlay(BibleSessionLiveEvent next) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && next.sessionId.isNotEmpty) {
      try {
        final regDoc = await FirebaseFirestore.instance
            .doc('bible_sessions/${next.sessionId}/registrations/$uid')
            .get()
            .timeout(const Duration(seconds: 3));
        final regStatus = regDoc.data()?['status'] as String?;
        if (regStatus == 'paid') {
          debugPrint(
            '[BibleOverlay] Skipping overlay — user already paid '
            'for ${next.sessionId}',
          );
          // Clear the notifier so a back-to-back same-session push
          // doesn't re-trigger this branch on every fire.
          NotificationService.bibleSessionLiveEvent.value = null;
          // Deep-link to the detail page; route handler honours the
          // existing /bible/detail/:id surface and will render
          // STATE D (link revealed) for paid users.
          appRouter.push('/bible/detail/${next.sessionId}');
          return;
        }
      } catch (_) {
        // Network blip / timeout / permission edge — show the
        // overlay anyway. False-positive nags are recoverable
        // (user taps Not Now); false-negative (skipping a real
        // call) would be worse.
      }
    }

    if (!mounted) return;
    setState(() => _current = next);
    _controller.forward(from: 0);
    _startVibration();

    _autoDismiss?.cancel();
    _autoDismiss = Timer(_kAutoDismissAfter, _decline);

    // Watch the session doc so the overlay self-dismisses the moment
    // the session is no longer 'live' on the server (auto-completed
    // by the cron, ended by priest, or cancelled). Without this we
    // would proudly show "LIVE NOW" on a session that's already over.
    _statusSub?.cancel();
    if (next.sessionId.isNotEmpty) {
      _statusSub = FirebaseFirestore.instance
          .doc('bible_sessions/${next.sessionId}')
          .snapshots()
          .listen(
        (snap) {
          if (!mounted) return;
          // First snapshot for this overlay instance — we expect an
          // effectively-live session. Dismiss the moment it's no
          // longer EFFECTIVELY live: status left 'live' (completed /
          // cancelled / deleted doc) OR the (startedAt + duration)
          // deadline passed even though the doc still reads 'live'
          // (the auto-complete cron hasn't caught up yet). Reusing
          // isEffectivelyLive keeps the overlay consistent with the
          // detail page and every other surface, so a user never gets
          // a "LIVE NOW" call for a session that's actually over.
          final data = snap.data();
          if (data == null) {
            _clear();
            return;
          }
          final model = BibleSessionModel.fromFirestore(snap.id, data);
          if (!model.isEffectivelyLive) {
            _clear();
          }
        },
        onError: (_) {
          // Stream errors are non-fatal — keep the overlay; the
          // 60-second auto-dismiss is the safety net.
        },
      );
    }
  }

  // Heavy-impact haptic on a 1.5 s timer — same cadence as the
  // priest's RingService incoming-call vibration, scaled down to
  // haptics-only (no audio). The first pulse fires immediately so
  // the user feels the prompt the moment the overlay appears.
  void _startVibration() {
    _stopVibration();
    HapticFeedback.heavyImpact();
    _vibrationTimer = Timer.periodic(_kVibrationInterval, (_) {
      if (_current == null) {
        _stopVibration();
        return;
      }
      HapticFeedback.heavyImpact();
    });
  }

  void _stopVibration() {
    _vibrationTimer?.cancel();
    _vibrationTimer = null;
  }

  Future<void> _clear() async {
    _autoDismiss?.cancel();
    _stopVibration();
    // Drop the session-doc listener BEFORE the animation so a status
    // flip arriving mid-fade-out doesn't try to re-call _clear().
    await _statusSub?.cancel();
    _statusSub = null;
    await _controller.reverse();
    if (!mounted) return;
    setState(() => _current = null);
    // Reset the notifier so a back-to-back live event triggers a
    // fresh listener tick — ValueNotifier compares values, so
    // reassigning the same instance would be a no-op.
    NotificationService.bibleSessionLiveEvent.value = null;
  }

  Future<void> _join() async {
    final event = _current;
    if (event == null) return;
    final sessionId = event.sessionId;
    await _clear();
    if (sessionId.isEmpty) return;
    // appRouter is the global GoRouter instance — using the in-tree
    // BuildContext would fail because the overlay sits above the
    // Navigator (no GoRouter ancestor in scope).
    appRouter.push('/bible/detail/$sessionId');
  }

  Future<void> _decline() => _clear();

  @override
  Widget build(BuildContext context) {
    final event = _current;
    return Stack(
      children: [
        widget.child,
        if (event != null)
          Positioned.fill(
            child: FadeTransition(
              opacity: _fade,
              child: _OverlayContent(
                key: ValueKey(event.id),
                event: event,
                onJoin: _join,
                onDecline: _decline,
              ),
            ),
          ),
      ],
    );
  }
}

// The actual full-screen UI. Material wrapper is required so any
// touch targets inside the overlay (the buttons) get the standard
// Material ripple infrastructure and don't accidentally bleed
// through to the page underneath.
class _OverlayContent extends StatelessWidget {
  final BibleSessionLiveEvent event;
  final VoidCallback onJoin;
  final VoidCallback onDecline;

  const _OverlayContent({
    super.key,
    required this.event,
    required this.onJoin,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final initial = event.priestName.isNotEmpty
        ? event.priestName.substring(0, 1).toUpperCase()
        : '?';
    final hasPhoto = event.priestPhotoUrl.isNotEmpty;

    return Material(
      color: Colors.black.withValues(alpha: 0.88),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Priest avatar with amber ring. The amber ring is the
              // brand accent; pairing it with the warm dark backdrop
              // gives the overlay the "spiritual call" feel rather
              // than a generic system phone-ringer aesthetic.
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.08),
                  border: Border.all(
                    color: AppColors.amberGold,
                    width: 3,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: hasPhoto
                    ? CachedNetworkImage(
                        imageUrl: event.priestPhotoUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => _initialAvatar(initial),
                        errorWidget: (_, _, _) => _initialAvatar(initial),
                      )
                    : _initialAvatar(initial),
              ),
              const SizedBox(height: 22),
              Text(
                event.priestName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.72),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                event.sessionTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const PulsingDot(size: 10, color: _kLiveRed),
                  const SizedBox(width: 8),
                  Text(
                    "LIVE NOW",
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _kLiveRed,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                event.price > 0
                    ? "₹${event.price} to join"
                    : "Tap to join",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 56),
              _JoinButton(onTap: onJoin),
              const SizedBox(height: 18),
              _DeclineButton(onTap: onDecline),
            ],
          ),
        ),
      ),
    );
  }

  Widget _initialAvatar(String initial) {
    return Container(
      alignment: Alignment.center,
      color: Colors.white.withValues(alpha: 0.06),
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 40,
          fontWeight: FontWeight.w700,
          color: AppColors.amberGold,
        ),
      ),
    );
  }
}

class _JoinButton extends StatefulWidget {
  final VoidCallback onTap;
  const _JoinButton({required this.onTap});

  @override
  State<_JoinButton> createState() => _JoinButtonState();
}

class _JoinButtonState extends State<_JoinButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.95),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: 220,
          height: 58,
          decoration: BoxDecoration(
            color: _kJoinGreen,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: _kJoinGreen.withValues(alpha: 0.45),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(
                AppIcons.video,
                size: 22,
                color: Colors.white,
              ),
              const SizedBox(width: 10),
              Text(
                "Join Meeting",
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeclineButton extends StatefulWidget {
  final VoidCallback onTap;
  const _DeclineButton({required this.onTap});

  @override
  State<_DeclineButton> createState() => _DeclineButtonState();
}

class _DeclineButtonState extends State<_DeclineButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.95),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: 170,
          height: 46,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(23),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            "Not Now",
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}
