// User's session-waiting screen. Feels like a FaceTime calling UI on
// purpose — the user is anxious, the priest has 60 seconds to
// respond, and every visual cue has to reassure rather than alarm.
//
// The page fires createSessionRequest in initState (instead of on a
// button) because the user already made their decision on the priest
// profile; showing them a second "Confirm" button here would feel
// redundant. A PopScope guards the hardware back button so the
// confirmation sheet is the only exit.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/user/session/bloc/session_request_cubit.dart';
import 'package:gospel_vox/features/user/session/bloc/session_request_state.dart';

class SessionWaitingPage extends StatefulWidget {
  final String priestId;
  final String priestName;
  final String priestPhotoUrl;
  final String priestDenomination;
  final String sessionType;

  const SessionWaitingPage({
    super.key,
    required this.priestId,
    required this.priestName,
    required this.priestPhotoUrl,
    required this.priestDenomination,
    required this.sessionType,
  });

  @override
  State<SessionWaitingPage> createState() => _SessionWaitingPageState();
}

class _SessionWaitingPageState extends State<SessionWaitingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();

    // Slow pulse on the avatar so the screen has a heartbeat without
    // feeling frantic. Repeats reversed so the scale eases in and out
    // rather than snapping back.
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    // Fire the actual CF call once the first frame is up. Doing it
    // inline in initState works too, but the post-frame hop keeps
    // provider lookups safe even as the widget subtree is still
    // settling.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SessionRequestCubit>().sendRequest(
            priestId: widget.priestId,
            type: widget.sessionType,
          );
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // Hardware back funnels through the same confirmation sheet as
      // the explicit Cancel button — no silent cancellations.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showCancelConfirmation();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: BlocConsumer<SessionRequestCubit, SessionRequestState>(
          listener: (context, state) {
            if (state is SessionRequestAccepted) {
              context.go('/session/chat/${state.session.id}');
            } else if (state is SessionRequestDeclined) {
              _showDeclinedSheet(state.priestName);
            } else if (state is SessionRequestExpired) {
              _showExpiredSheet();
            } else if (state is SessionRequestCancelled) {
              if (context.canPop()) context.pop();
            } else if (state is SessionRequestError) {
              AppSnackBar.error(context, state.message);
              if (context.canPop()) context.pop();
            }
          },
          builder: (context, state) {
            if (state is SessionRequestWaiting) {
              return _buildWaitingState(state);
            }
            return _buildSendingState();
          },
        ),
      ),
    );
  }

  Widget _buildSendingState() {
    return SafeArea(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 2),
          _buildAvatar(),
          const SizedBox(height: 24),
          _buildPriestName(),
          const SizedBox(height: 28),
          Text(
            'Sending request…',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 16),
          _buildTypeBadge(),
          const Spacer(flex: 3),
          _buildCancelButton(),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
        ],
      ),
    );
  }

  Widget _buildWaitingState(SessionRequestWaiting state) {
    return SafeArea(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 2),
          _buildAvatar(),
          const SizedBox(height: 24),
          _buildPriestName(),
          const SizedBox(height: 28),
          Text(
            widget.sessionType == 'chat'
                ? 'Waiting for response…'
                : 'Calling…',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          // Clamp so nothing in the UI ever shows a negative second,
          // even if the cubit somehow emits stale state during the
          // Firestore round-trip for the cancel write.
          _buildCountdown(state.secondsRemaining.clamp(0, 60)),
          const SizedBox(height: 8),
          Text(
            'Request expires in ${state.secondsRemaining.clamp(0, 60)}s',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 16),
          _buildTypeBadge(),
          const Spacer(flex: 3),
          _buildCancelButton(),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = 1.0 + 0.04 * _pulseController.value;
        return Transform.scale(scale: scale, child: child);
      },
      child: Container(
        width: 110,
        height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surfaceWhite,
          border: Border.all(
            color: AppColors.primaryBrown.withValues(alpha: 0.15),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryBrown.withValues(alpha: 0.1),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
          image: widget.priestPhotoUrl.isNotEmpty
              ? DecorationImage(
                  image: NetworkImage(widget.priestPhotoUrl),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: widget.priestPhotoUrl.isEmpty
            ? Center(
                child: Text(
                  widget.priestName.isNotEmpty
                      ? widget.priestName[0].toUpperCase()
                      : '?',
                  style: GoogleFonts.inter(
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryBrown,
                  ),
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildPriestName() {
    return Column(
      children: [
        Text(
          widget.priestName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        if (widget.priestDenomination.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            widget.priestDenomination,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCountdown(int seconds) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              value: seconds / 60,
              color: AppColors.primaryBrown,
              backgroundColor: AppColors.muted.withValues(alpha: 0.1),
              strokeWidth: 3,
              strokeCap: StrokeCap.round,
            ),
          ),
          Text(
            '$seconds',
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeBadge() {
    final isChat = widget.sessionType == 'chat';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isChat
                ? Icons.chat_bubble_outline_rounded
                : Icons.mic_none_rounded,
            size: 16,
            color: AppColors.primaryBrown,
          ),
          const SizedBox(width: 8),
          Text(
            isChat ? 'Chat Session' : 'Voice Session',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.primaryBrown,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: _CancelButton(onTap: _showCancelConfirmation),
    );
  }

  void _showCancelConfirmation() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Cancel Request?',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "The speaker hasn't responded yet. Are you sure "
                  'you want to cancel?',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _SheetAction(
                        label: 'Go Back',
                        filled: false,
                        color: AppColors.muted,
                        onTap: () => Navigator.of(sheetContext).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SheetAction(
                        label: 'Yes, Cancel',
                        filled: true,
                        color: AppColors.errorRed,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          context
                              .read<SessionRequestCubit>()
                              .cancelRequest();
                        },
                      ),
                    ),
                  ],
                ),
                SizedBox(
                    height: MediaQuery.of(sheetContext).padding.bottom),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDeclinedSheet(String priestName) {
    _showTerminalSheet(
      icon: Icons.close_rounded,
      title: 'Request Declined',
      body: '$priestName is unavailable right now. Try another '
          'speaker or check back later.',
    );
  }

  void _showExpiredSheet() {
    _showTerminalSheet(
      icon: Icons.timer_off_outlined,
      title: 'Request Expired',
      body: "The speaker didn't respond in time. Try again or "
          'choose another speaker.',
    );
  }

  // Declined and expired render the same sheet with different copy —
  // extracting this keeps them visually consistent and prevents one
  // from drifting. isDismissible: false because the user must tap
  // "Back to Home" so the navigation stack doesn't rewind onto the
  // waiting screen in a stale state.
  void _showTerminalSheet({
    required IconData icon,
    required String title,
    required String body,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
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
                      color: AppColors.muted.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.muted.withValues(alpha: 0.08),
                  ),
                  child: Icon(icon, size: 28, color: AppColors.muted),
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 24),
                _SheetAction(
                  label: 'Back to Home',
                  filled: true,
                  color: AppColors.primaryBrown,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/user');
                  },
                ),
                SizedBox(
                    height: MediaQuery.of(sheetContext).padding.bottom),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CancelButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CancelButton({required this.onTap});

  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
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
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.25),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text(
                'Cancel Request',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatefulWidget {
  final String label;
  final bool filled;
  final Color color;
  final VoidCallback onTap;

  const _SheetAction({
    required this.label,
    required this.filled,
    required this.color,
    required this.onTap,
  });

  @override
  State<_SheetAction> createState() => _SheetActionState();
}

class _SheetActionState extends State<_SheetAction> {
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
            height: 52,
            decoration: BoxDecoration(
              color: filled ? widget.color : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: filled
                  ? null
                  : Border.all(
                      color: widget.color.withValues(alpha: 0.3),
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
