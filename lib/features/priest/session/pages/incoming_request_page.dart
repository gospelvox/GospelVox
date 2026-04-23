// Priest-side "someone is calling you" screen. Full-bleed dark warm
// gradient background intentionally mimics a phone call UI — every
// priest already knows how to react to that pattern, and the
// incoming request is the most interruptive thing the app does.
//
// The page itself is stateful only for the ring-pulse animation. The
// activation gate lives in the cubit, so tapping Accept on an
// unactivated account routes through a sentinel error state which
// the BlocListener turns into a bottom sheet — see
// IncomingRequestError in the cubit.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/session/bloc/incoming_request_cubit.dart';
import 'package:gospel_vox/features/priest/session/bloc/incoming_request_state.dart';
import 'package:gospel_vox/features/priest/widgets/activation_prompt_sheet.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

// Pinned locally rather than in AppColors because this is the only
// surface in the app with a near-black background — elevating these
// to theme tokens would pollute the palette for a single screen.
const Color _kBgTop = Color(0xFF2C1810);
const Color _kBgBottom = Color(0xFF140800);
const Color _kGold = Color(0xFFC8902A);
const Color _kBeigeText = Color(0xFFF5EAD8);
const Color _kAccentGreen = Color(0xFF2E7D4F);
const Color _kAccentRed = Color(0xFFDC2626);
const Color _kAvatarInner = Color(0xFF3D1F0F);

class IncomingRequestPage extends StatefulWidget {
  final SessionModel session;
  // The priest's current activation state is read from the dashboard
  // stream and handed in as a bool — re-reading it here would be a
  // second Firestore call against the same doc.
  final bool isActivated;

  const IncomingRequestPage({
    super.key,
    required this.session,
    required this.isActivated,
  });

  @override
  State<IncomingRequestPage> createState() => _IncomingRequestPageState();
}

class _IncomingRequestPageState extends State<IncomingRequestPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ringController;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
        child: BlocConsumer<IncomingRequestCubit, IncomingRequestState>(
          listener: (context, state) {
            if (state is IncomingRequestAccepted) {
              context.go('/session/priest-chat/${state.session.id}');
            } else if (state is IncomingRequestDeclined) {
              if (context.canPop()) context.pop();
            } else if (state is IncomingRequestExpired) {
              AppSnackBar.info(context, 'Request expired');
              if (context.canPop()) context.pop();
            } else if (state is IncomingRequestError) {
              if (state.message == '__needs_activation__') {
                ActivationPromptSheet.show(context);
              } else {
                AppSnackBar.error(context, state.message);
              }
            }
          },
          builder: (context, state) {
            return SafeArea(
              child: _buildContent(context, state),
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, IncomingRequestState state) {
    final session = widget.session;
    final secondsRemaining =
        state is IncomingRequestReceived ? state.secondsRemaining : null;
    final accepting = state is IncomingRequestAccepting;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(flex: 2),
        Text(
          session.isChat ? 'INCOMING CHAT' : 'INCOMING CALL',
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: _kGold,
          ),
        ),
        const SizedBox(height: 28),
        _buildAvatar(session),
        const SizedBox(height: 24),
        Text(
          session.userName.isNotEmpty ? session.userName : 'Someone',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: _kBeigeText,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${session.isChat ? 'Chat' : 'Voice'} · '
          '${session.ratePerMinute} coins/min',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: _kBeigeText.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 16),
        if (secondsRemaining != null) _buildCountdown(secondsRemaining),
        const Spacer(flex: 3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Row(
            children: [
              _ActionCircle(
                icon: Icons.close_rounded,
                label: 'Decline',
                color: _kAccentRed,
                size: 64,
                labelColor: _kBeigeText.withValues(alpha: 0.5),
                enabled: !accepting,
                onTap: () => context
                    .read<IncomingRequestCubit>()
                    .declineRequest(session.id),
              ),
              const Spacer(),
              _ActionCircle(
                icon: session.isChat
                    ? Icons.chat_rounded
                    : Icons.mic_rounded,
                label: accepting ? 'Accepting…' : 'Accept',
                color: _kAccentGreen,
                size: 72,
                labelColor: _kAccentGreen,
                labelWeight: FontWeight.w600,
                enabled: !accepting,
                onTap: () => context
                    .read<IncomingRequestCubit>()
                    .acceptRequest(session.id, widget.isActivated),
              ),
            ],
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 32),
      ],
    );
  }

  Widget _buildAvatar(SessionModel session) {
    return AnimatedBuilder(
      animation: _ringController,
      builder: (context, child) {
        // Outward-pulsing ring: as the progress advances, the ring
        // expands and its alpha fades to zero. Gives the "you're
        // being called" feel without flashy color changes.
        return Container(
          width: 120 + 16 * _ringController.value,
          height: 120 + 16 * _ringController.value,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: _kGold.withValues(
                alpha: 0.3 * (1 - _ringController.value),
              ),
              width: 2,
            ),
          ),
          child: child,
        );
      },
      child: Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _kAvatarInner,
          border: Border.all(
            color: _kGold.withValues(alpha: 0.3),
            width: 2,
          ),
          image: session.userPhotoUrl.isNotEmpty
              ? DecorationImage(
                  image: NetworkImage(session.userPhotoUrl),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: session.userPhotoUrl.isEmpty
            ? Center(
                child: Text(
                  session.userName.isNotEmpty
                      ? session.userName[0].toUpperCase()
                      : '?',
                  style: GoogleFonts.inter(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: _kBeigeText,
                  ),
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildCountdown(int secondsRemaining) {
    return Column(
      children: [
        Text(
          '${secondsRemaining}s',
          style: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: _kGold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Auto-decline in $secondsRemaining seconds',
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: _kBeigeText.withValues(alpha: 0.35),
          ),
        ),
      ],
    );
  }
}

class _ActionCircle extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double size;
  final Color labelColor;
  final FontWeight labelWeight;
  final bool enabled;
  final VoidCallback onTap;

  const _ActionCircle({
    required this.icon,
    required this.label,
    required this.color,
    required this.size,
    required this.labelColor,
    this.labelWeight = FontWeight.w500,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_ActionCircle> createState() => _ActionCircleState();
}

class _ActionCircleState extends State<_ActionCircle> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        if (widget.enabled) setState(() => _scale = 0.95);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.enabled
                      ? widget.color
                      : widget.color.withValues(alpha: 0.4),
                  boxShadow: widget.enabled
                      ? [
                          BoxShadow(
                            color: widget.color.withValues(alpha: 0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  widget.icon,
                  size: 28,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: widget.labelWeight,
                  color: widget.labelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
