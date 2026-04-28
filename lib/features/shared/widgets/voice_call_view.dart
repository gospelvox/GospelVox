// Shared voice-call UI used by both user and priest sides. Side-
// specific knobs are limited to:
//   • `isUserSide` — drives the low-balance banner and the recharge
//     hint (user only)
//   • `isUserSide` — also picks which party renders in the avatar +
//     name strip (each side sees the OTHER's photo and name)
//   • the post-end navigation target — handled by the parent page
//     through the onEnded callback
//
// Visual language is intentionally close to a native phone call:
//   • Full-bleed dark warm gradient (matches the priest's incoming
//     screen so the call feels "owned" by the priest brand)
//   • Centred avatar with a slow pulsing ring while waiting; ring
//     stops once the other party joins
//   • Mute / End / Speaker controls in a fixed row, end button
//     sized larger and red (the iOS pattern)
//   • Timer pill in the top right; connection status in the top
//     left (Connected / Reconnecting / Waiting)
//   • Low-balance amber strip slides in below the top bar when the
//     user's balance hits the warning threshold
//
// Performance: no AnimationController proliferation here. The pulse
// ring uses a single SingleTickerProviderStateMixin controller; the
// scaling buttons use AnimatedScale (no controller) per the design
// rules.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/bloc/voice_call_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/voice_call_state.dart';
import 'package:gospel_vox/features/shared/widgets/recharge_sheet.dart';

// Pinned locally rather than in AppColors — this is the only voice
// call surface, and elevating these to theme tokens would pollute
// the warm-beige palette that drives the rest of the app.
const Color _kBgTop = Color(0xFF2C1810);
const Color _kBgBottom = Color(0xFF0A0400);
const Color _kGold = Color(0xFFC8902A);
const Color _kBeigeText = Color(0xFFF5EAD8);
const Color _kAccentGreen = Color(0xFF2E7D4F);
const Color _kAccentRed = Color(0xFFDC2626);
const Color _kAmber = Color(0xFFD4A060);
const Color _kSheetBg = Color(0xFF1A0E08);
const Color _kAvatarInner = Color(0xFF3D1F0F);

typedef VoiceEndedCallback = void Function(
  BuildContext context,
  VoiceCallEnded state,
);

class VoiceCallView extends StatefulWidget {
  final String sessionId;
  final bool isUserSide;
  final VoiceEndedCallback onEnded;

  const VoiceCallView({
    super.key,
    required this.sessionId,
    required this.isUserSide,
    required this.onEnded,
  });

  @override
  State<VoiceCallView> createState() => _VoiceCallViewState();
}

class _VoiceCallViewState extends State<VoiceCallView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // Slow ring pulse around the avatar while we wait for the other
  // party to join. We stop the controller (don't dispose it — we
  // might need to restart it if the other side drops) once they
  // connect.
  late final AnimationController _pulseController;

  // Tracks the rising edge of low-balance for haptic feedback.
  bool _wasLowBalance = false;
  // Tracks the rising edge of "remote joined" for haptic feedback.
  bool _wasRemoteJoined = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    // CASE 4: hook the app lifecycle so we can refresh Agora's
    // local audio state when we come back from a system
    // interruption (incoming cellular call, OS pause, user
    // switching apps and returning). The cubit owns the actual
    // recovery logic — see VoiceCallCubit.onAppResumed.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState != AppLifecycleState.resumed) return;
    // The cubit may already be closed (call ended while we were
    // backgrounded) — read defensively.
    if (!mounted) return;
    final cubit = context.read<VoiceCallCubit>();
    if (cubit.isClosed) return;
    cubit.onAppResumed();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // Hardware back funnels through the same end-call sheet —
      // silently leaving would keep the Agora channel alive on
      // the other side until the watchdog kicks.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showEndConfirmation();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_kBgTop, _kBgBottom],
            ),
          ),
          child: BlocConsumer<VoiceCallCubit, VoiceCallState>(
            listenWhen: (prev, next) =>
                next is VoiceCallEnded || next is VoiceCallError,
            listener: (context, state) {
              if (state is VoiceCallEnded) {
                widget.onEnded(context, state);
              } else if (state is VoiceCallError) {
                AppSnackBar.error(context, state.message);
                // Bug #3: pop may fail when this page was reached
                // via context.go (no underlying route on the stack)
                // — leaves the user stuck on a misleading
                // "Connecting…" frame with just a snackbar. Fall
                // back to the side-appropriate home so the screen
                // never traps anyone.
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                } else {
                  context.go(widget.isUserSide ? '/user' : '/priest');
                }
              }
            },
            builder: (context, state) {
              if (state is VoiceCallActive) {
                _maybeBuzzOnRemoteJoin(state.isRemoteUserJoined);
                _maybeBuzzOnLowBalance(state.isLowBalance);
                _syncPulse(state.isRemoteUserJoined);
                return SafeArea(child: _buildActive(state));
              }
              return SafeArea(child: _buildConnecting());
            },
          ),
        ),
      ),
    );
  }

  // Pulse runs only while we're still waiting. Once the other
  // party joins it stops at rest position so the screen feels
  // settled — restarting it later if they drop would be fussy
  // and the "Reconnecting…" banner already conveys that state.
  void _syncPulse(bool remoteJoined) {
    if (remoteJoined && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0;
    } else if (!remoteJoined && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    }
  }

  void _maybeBuzzOnRemoteJoin(bool joined) {
    if (joined && !_wasRemoteJoined) {
      HapticFeedback.mediumImpact();
    }
    _wasRemoteJoined = joined;
  }

  void _maybeBuzzOnLowBalance(bool isLow) {
    if (isLow && !_wasLowBalance) {
      HapticFeedback.mediumImpact();
    }
    _wasLowBalance = isLow;
  }

  // Mid-call recharge. The user's balance stream the cubit
  // subscribes to picks up the new balance the moment Razorpay
  // credits the wallet — no extra plumbing needed here. Billing
  // continues running during the sheet (the cubit's timers don't
  // pause), which is the correct behaviour: the audio is still
  // flowing, the user is still being heard.
  //
  // Contextual copy: we hand the sheet the priest's name + the
  // 5-minute minimum + the deficit so the headline reads
  // "Minimum balance: ₹X (for 5 minutes)" / "You need ₹X more to
  // keep your call with $priestName going" instead of generic copy.
  Future<void> _openRecharge() async {
    HapticFeedback.lightImpact();
    final cubitState = context.read<VoiceCallCubit>().state;
    int? balance;
    String? headline;
    String? subtext;
    if (cubitState is VoiceCallActive) {
      balance = cubitState.remainingBalance;
      final ctx = recomputeRechargeContext(
        ratePerMinute: cubitState.session.ratePerMinute,
        currentBalance: cubitState.remainingBalance,
      );
      headline =
          'Minimum balance: ₹${ctx.requiredFor5Min} (for 5 minutes)';
      final priestName = cubitState.session.priestName;
      if (ctx.deficit > 0) {
        subtext = priestName.isNotEmpty
            ? 'Add ₹${ctx.deficit} more to keep your call '
                'with $priestName going'
            : 'Add ₹${ctx.deficit} more to keep your call going';
      }
    }
    await RechargeSheet.show(
      context,
      currentBalance: balance,
      infoHeadline: headline,
      infoSubtext: subtext,
    );
  }

  Widget _buildConnecting() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            color: _kGold,
            strokeWidth: 2.5,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Connecting…',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: _kBeigeText.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _buildActive(VoiceCallActive state) {
    final session = state.session;
    final otherName = widget.isUserSide
        ? (session.priestName.isNotEmpty ? session.priestName : 'Speaker')
        : (session.userName.isNotEmpty ? session.userName : 'User');
    final otherPhoto = widget.isUserSide
        ? session.priestPhotoUrl
        : session.userPhotoUrl;

    return Column(
      children: [
        _TopBar(
          isRemoteJoined: state.isRemoteUserJoined,
          isReconnecting: state.isReconnecting,
          formattedTime: state.formattedTime,
          networkQuality: state.networkQuality,
        ),
        if (widget.isUserSide && state.isLowBalance)
          _LowBalanceStrip(
            remaining: state.remainingBalance,
            onAddCoins: _openRecharge,
          ),
        // Flag #7: 45s into "Waiting…" without the remote joining,
        // surface this banner. The cubit auto-ends the call at 60s
        // total — this 15-second window gives the user something
        // honest to read instead of an indefinite spinner.
        if (state.showConnectionTrouble && !state.isRemoteUserJoined)
          const _ConnectionTroubleBanner(),
        // CASE 5: remote party silent for ≥15s. Pinned right under
        // the top bar so the user notices it before the call drops
        // and they assume their own connection is the problem.
        if (state.showSilenceWarning) const _SilenceHintBanner(),
        const Spacer(flex: 2),
        Center(
          child: Column(
            children: [
              _AvatarRing(
                pulseController: _pulseController,
                photoUrl: otherPhoto,
                name: otherName,
                showPulse: !state.isRemoteUserJoined,
              ),
              const SizedBox(height: 24),
              Text(
                otherName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: _kBeigeText,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                state.isRemoteUserJoined
                    ? 'Voice call in progress'
                    : 'Connecting…',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: _kBeigeText.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${session.ratePerMinute} coins/min',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: _kGold.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        if (state.isReconnecting && state.isRemoteUserJoined)
          const SizedBox(height: 0)
        else if (state.isReconnecting)
          const Padding(
            padding: EdgeInsets.only(top: 20),
            child: _ReconnectingBanner(),
          ),
        const Spacer(flex: 3),
        _ControlsRow(
          isMuted: state.isMuted,
          isSpeakerOn: state.isSpeakerOn,
          isEnding: state.isEnding,
          onToggleMute: () =>
              context.read<VoiceCallCubit>().toggleMute(),
          onToggleSpeaker: () =>
              context.read<VoiceCallCubit>().toggleSpeaker(),
          onEnd: state.isEnding ? null : _showEndConfirmation,
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            // Agora carries audio over TLS but their relays can
            // decrypt it server-side, so "end-to-end" would be a
            // false claim. "Encrypted voice call" is accurate
            // (transport encryption is real) and reads to users as
            // the same trust signal.
            '🔒 Encrypted voice call',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: Colors.white.withValues(alpha: 0.2),
            ),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
      ],
    );
  }

  void _showEndConfirmation() {
    final cubit = context.read<VoiceCallCubit>();
    final state = cubit.state;
    if (state is! VoiceCallActive || state.isEnding) return;

    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _kSheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _EndCallSheet(
          formattedTime: state.formattedTime,
          currentCost: state.currentCost,
          isUserSide: widget.isUserSide,
          onCancel: () => Navigator.of(sheetContext).pop(),
          onConfirm: () {
            HapticFeedback.heavyImpact();
            Navigator.of(sheetContext).pop();
            cubit.endCall(
              reason:
                  widget.isUserSide ? 'user_ended' : 'priest_ended',
            );
          },
        );
      },
    );
  }
}

// ─── Top bar ──────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final bool isRemoteJoined;
  final bool isReconnecting;
  final String formattedTime;
  // Agora's 0-6 scale, with 1=excellent / 6=disconnected. Drives
  // both the "Poor connection" / "Disconnected" label and the
  // optional weak-signal pill in the right column.
  final int networkQuality;

  const _TopBar({
    required this.isRemoteJoined,
    required this.isReconnecting,
    required this.formattedTime,
    required this.networkQuality,
  });

  @override
  Widget build(BuildContext context) {
    final statusDot = _statusDot();
    final statusLabel = _statusLabel();
    // Show the small signal pill only when quality is at least
    // qualityPoor — otherwise it's pure visual noise.
    final showSignal = networkQuality >= 3;
    final signalIsBad = networkQuality >= 5;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusDot,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      statusLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // The signal pill, the timer pill, and the gap between
          // them sit in a Row(min) so the left status column can
          // claim the rest of the width without elbowing them off
          // the screen on a 320px device.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSignal) ...[
                const SizedBox(width: 8),
                _SignalPill(isBad: signalIsBad),
              ],
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  formattedTime,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Status pill copy precedence: Disconnected > Reconnecting >
  // Waiting > Poor > Connected. The disconnect state is the most
  // actionable, so it wins; weak-but-not-down quality only shows
  // once the channel is actually up (otherwise "Poor connection"
  // would mask the more useful "Waiting…").
  String _statusLabel() {
    if (networkQuality >= 6) return 'Disconnected';
    if (isReconnecting) return 'Reconnecting…';
    if (!isRemoteJoined) return 'Waiting…';
    if (networkQuality >= 4) return 'Poor connection';
    return 'Connected';
  }

  Color _statusDot() {
    if (networkQuality >= 6) return _kAccentRed;
    if (isReconnecting) return _kAmber;
    if (!isRemoteJoined) return const Color(0xFF9B7B6E);
    if (networkQuality >= 4) return _kAmber;
    return _kAccentGreen;
  }
}

// Small amber/red signal pill that joins the timer in the top
// right when network is poor or worse. Kept separate from the
// status pill so the user can see "Connected" + a "Weak" badge
// instead of one fused "Connected (Weak)" string that's harder
// to scan.
class _SignalPill extends StatelessWidget {
  final bool isBad;
  const _SignalPill({required this.isBad});

  @override
  Widget build(BuildContext context) {
    final tint = isBad ? _kAccentRed : _kAmber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBad
                ? Icons.signal_wifi_off_rounded
                : Icons.signal_wifi_bad_rounded,
            size: 14,
            color: isBad ? const Color(0xFFFF6B6B) : tint,
          ),
          const SizedBox(width: 4),
          Text(
            isBad ? 'Poor' : 'Weak',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: isBad ? const Color(0xFFFF6B6B) : tint,
            ),
          ),
        ],
      ),
    );
  }
}

// Flag #7: shown 45s into the "remote hasn't joined yet" wait,
// before the cubit auto-ends the call at 60s. Same visual
// language as _SilenceHintBanner so the warning surface stays
// consistent — both sit directly below the top bar.
class _ConnectionTroubleBanner extends StatelessWidget {
  const _ConnectionTroubleBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _kAmber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _kAmber.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.signal_cellular_connected_no_internet_0_bar_rounded,
            size: 16,
            color: _kAmber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'The other party is having trouble connecting',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _kAmber,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "We'll end the call automatically if they don't "
                  'arrive in the next few seconds.',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    color: _kAmber.withValues(alpha: 0.7),
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

// Sits below the top bar when the remote party has been silent
// for ≥15s while the channel is still up. The whole point is to
// help the user diagnose "they can't hear me / I can't hear them"
// before the call ends and they assume something else broke.
class _SilenceHintBanner extends StatelessWidget {
  const _SilenceHintBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _kAmber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _kAmber.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.mic_off_rounded,
            size: 16,
            color: _kAmber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Can't hear the other person?",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _kAmber,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Their microphone might be muted or not working. '
                  'Ask them to check their audio settings.',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    color: _kAmber.withValues(alpha: 0.7),
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

// ─── Low-balance strip ────────────────────────────────────

class _LowBalanceStrip extends StatelessWidget {
  final int remaining;
  // Mid-call recharge entry point. The strip itself isn't tappable
  // — only the inline "Add Coins" button on the right is — so a
  // user reaching for the warning to dismiss it doesn't accidentally
  // trigger a payment sheet.
  final VoidCallback onAddCoins;

  const _LowBalanceStrip({
    required this.remaining,
    required this.onAddCoins,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: _kAccentRed.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: Color(0xFFFF6B6B),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Low balance: $remaining coins',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFFF6B6B),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _AddCoinsPill(onTap: onAddCoins),
        ],
      ),
    );
  }
}

// Inline gold pill that opens the recharge sheet without leaving
// the call. Sized to fit comfortably in the low-balance strip on a
// 320px device alongside the warning text. Uses GestureDetector +
// AnimatedScale per the project's design rule (no InkWell).
class _AddCoinsPill extends StatefulWidget {
  final VoidCallback onTap;
  const _AddCoinsPill({required this.onTap});

  @override
  State<_AddCoinsPill> createState() => _AddCoinsPillState();
}

class _AddCoinsPillState extends State<_AddCoinsPill> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.95),
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
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _kGold,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: _kGold.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              'Add Coins',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Avatar ───────────────────────────────────────────────

class _AvatarRing extends StatelessWidget {
  final AnimationController pulseController;
  final String photoUrl;
  final String name;
  final bool showPulse;

  const _AvatarRing({
    required this.pulseController,
    required this.photoUrl,
    required this.name,
    required this.showPulse,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    final inner = Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _kAvatarInner,
        border: Border.all(
          color: _kGold.withValues(alpha: 0.3),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: _kGold.withValues(alpha: 0.15),
            blurRadius: 32,
            spreadRadius: 8,
          ),
        ],
        image: photoUrl.isNotEmpty
            ? DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: photoUrl.isEmpty
          ? Center(
              child: Text(
                initial,
                style: GoogleFonts.inter(
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  color: _kBeigeText,
                ),
              ),
            )
          : null,
    );

    if (!showPulse) return inner;

    return AnimatedBuilder(
      animation: pulseController,
      builder: (context, child) {
        final t = pulseController.value;
        return SizedBox(
          width: 160,
          height: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer ring expands + fades while we wait. Two
              // overlapping rings would feel busy here, so a
              // single one is enough to read as "ringing".
              Container(
                width: 130 + 24 * t,
                height: 130 + 24 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _kGold.withValues(alpha: 0.3 * (1 - t)),
                    width: 2,
                  ),
                ),
              ),
              child!,
            ],
          ),
        );
      },
      child: inner,
    );
  }
}

// ─── Reconnecting banner ──────────────────────────────────

class _ReconnectingBanner extends StatelessWidget {
  const _ReconnectingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _kAmber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              color: _kAmber,
              strokeWidth: 2,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Reconnecting…',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _kAmber,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Controls row ─────────────────────────────────────────

class _ControlsRow extends StatelessWidget {
  final bool isMuted;
  final bool isSpeakerOn;
  final bool isEnding;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleSpeaker;
  final VoidCallback? onEnd;

  const _ControlsRow({
    required this.isMuted,
    required this.isSpeakerOn,
    required this.isEnding,
    required this.onToggleMute,
    required this.onToggleSpeaker,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CallControl(
            icon: isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: isMuted ? 'Unmute' : 'Mute',
            isActive: isMuted,
            activeColor: _kAccentRed.withValues(alpha: 0.2),
            onTap: () {
              HapticFeedback.selectionClick();
              onToggleMute();
            },
          ),
          _EndCallButton(
            isEnding: isEnding,
            onTap: onEnd,
          ),
          _CallControl(
            icon: isSpeakerOn
                ? Icons.volume_up_rounded
                : Icons.volume_off_rounded,
            label: isSpeakerOn ? 'Speaker' : 'Earpiece',
            // The "active" highlight reads better as the off state
            // (earpiece) — that's the one the user has explicitly
            // chosen to break out of the default speakerphone.
            isActive: !isSpeakerOn,
            activeColor: Colors.white.withValues(alpha: 0.15),
            onTap: () {
              HapticFeedback.selectionClick();
              onToggleSpeaker();
            },
          ),
        ],
      ),
    );
  }
}

class _CallControl extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _CallControl({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  State<_CallControl> createState() => _CallControlState();
}

class _CallControlState extends State<_CallControl> {
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.isActive
                      ? widget.activeColor
                      : Colors.white.withValues(alpha: 0.08),
                ),
                child: Icon(
                  widget.icon,
                  size: 24,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: Colors.white.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EndCallButton extends StatefulWidget {
  final bool isEnding;
  final VoidCallback? onTap;

  const _EndCallButton({required this.isEnding, required this.onTap});

  @override
  State<_EndCallButton> createState() => _EndCallButtonState();
}

class _EndCallButtonState extends State<_EndCallButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null || widget.isEnding;
    return Listener(
      onPointerDown: (_) {
        if (!disabled) setState(() => _scale = 0.95);
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _kAccentRed.withValues(
                    alpha: disabled ? 0.5 : 1.0,
                  ),
                  boxShadow: disabled
                      ? null
                      : [
                          BoxShadow(
                            color: _kAccentRed.withValues(alpha: 0.4),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                ),
                child: widget.isEnding
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.call_end_rounded,
                        size: 32,
                        color: Colors.white,
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.isEnding ? 'Ending…' : 'End',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── End-call sheet (dark themed) ────────────────────────

class _EndCallSheet extends StatelessWidget {
  final String formattedTime;
  final int currentCost;
  final bool isUserSide;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _EndCallSheet({
    required this.formattedTime,
    required this.currentCost,
    required this.isUserSide,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _kBeigeText.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _kAccentRed.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.call_end_rounded,
                size: 28,
                color: _kAccentRed,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'End Call?',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: _kBeigeText,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isUserSide
                  ? 'You will be charged for the time spent so far. '
                      'This action cannot be undone.'
                  : 'The user will be charged for the time spent so far. '
                      'This action cannot be undone.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: _kBeigeText.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Duration',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: _kBeigeText.withValues(alpha: 0.5),
                        ),
                      ),
                      Text(
                        formattedTime,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _kBeigeText,
                        ),
                      ),
                    ],
                  ),
                  if (isUserSide) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Est. charge',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: _kBeigeText.withValues(alpha: 0.5),
                          ),
                        ),
                        Text(
                          '$currentCost coins',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFFFF6B6B),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _SheetBtn(
                    label: 'Continue',
                    filled: false,
                    color: _kBeigeText,
                    onTap: onCancel,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SheetBtn(
                    label: 'End Call',
                    filled: true,
                    color: _kAccentRed,
                    onTap: onConfirm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetBtn extends StatefulWidget {
  final String label;
  final bool filled;
  final Color color;
  final VoidCallback onTap;

  const _SheetBtn({
    required this.label,
    required this.filled,
    required this.color,
    required this.onTap,
  });

  @override
  State<_SheetBtn> createState() => _SheetBtnState();
}

class _SheetBtnState extends State<_SheetBtn> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final filled = widget.filled;
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
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
            height: 50,
            decoration: BoxDecoration(
              color: filled ? widget.color : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: filled
                  ? null
                  : Border.all(
                      color: widget.color.withValues(alpha: 0.35),
                      width: 1.5,
                    ),
            ),
            child: Center(
              child: Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: filled ? Colors.white : widget.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
