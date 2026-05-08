// Modal rating dialog shown to the user immediately after a chat or
// voice session ends. Replaces the previous full PostSessionPage —
// the user no longer sees a dedicated screen with duration / coins /
// rate, just an inline ask-for-rating sheet that lets them either
// submit or dismiss.
//
// Forced-but-not-trapped UX:
//   • No X / close icon. No backdrop dismiss. No hardware-back
//     dismiss (PopScope.canPop=false).
//   • Submit is the primary CTA — saves the rating + free-text
//     feedback to sessions/{id}.userRating + userFeedback (same
//     shape PostSessionPage used to write, so the priest's rating
//     aggregator keeps working without a schema change). Submit
//     ALWAYS closes the dialog, even when no rating was picked,
//     so the user is never blocked.
//   • A small, muted "Maybe later" link below Submit is the
//     visible-but-de-emphasised opt-out. It's there for honesty
//     (the user can always escape) but its visual weight is low
//     enough that most users will rate before tapping it.
//
// The session is already settled on the server by the time this
// dialog opens — endSession returned a SessionSummary up-stack and
// the cubit emitted VoiceCallEnded / ChatSessionEnded. So nothing
// in the app is blocked on this modal; whether the user taps
// Submit or Maybe later, they go home.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

class SessionRatingDialog extends StatefulWidget {
  final SessionModel session;

  const SessionRatingDialog({super.key, required this.session});

  // Convenience launcher. Returns when the dialog is dismissed
  // (Submit or Maybe later — both pop). Caller awaits and then
  // navigates home.
  static Future<void> show(BuildContext context, SessionModel session) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SessionRatingDialog(session: session),
    );
  }

  @override
  State<SessionRatingDialog> createState() => _SessionRatingDialogState();
}

class _SessionRatingDialogState extends State<SessionRatingDialog> {
  final TextEditingController _feedbackController = TextEditingController();
  int _rating = 0;
  bool _saving = false;

  @override
  void dispose() {
    _feedbackController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() => _saving = true);

    // Only write if the user actually picked a rating. Writing a
    // blank rating would no-op for the aggregator and pollute the
    // feedback log with empty strings.
    if (_rating > 0) {
      try {
        await FirebaseFirestore.instance
            .doc('sessions/${widget.session.id}')
            .update({
              'userRating': _rating,
              'userFeedback': _feedbackController.text.trim(),
            })
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        // Swallow — server-side aggregation tolerates a missed
        // rating, and blocking the user on a metric-write failure
        // would feel worse than silently losing one rating.
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _skip() {
    if (_saving) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: AppColors.surfaceWhite,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primaryBrown.withValues(alpha: 0.08),
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: 28,
                      color: AppColors.primaryBrown,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Rate your experience',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Your feedback helps other believers find the '
                  'right speaker.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 18),
                _StarRow(
                  rating: _rating,
                  onChanged: (value) => setState(() => _rating = value),
                ),
                const SizedBox(height: 18),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F5F2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _feedbackController,
                    maxLines: 3,
                    maxLength: 200,
                    textCapitalization: TextCapitalization.sentences,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(200),
                    ],
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: AppColors.deepDarkBrown,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Share your experience…',
                      hintStyle: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted.withValues(alpha: 0.5),
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(14),
                      counterStyle: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _SubmitButton(saving: _saving, onTap: _submit),
                const SizedBox(height: 8),
                Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _saving ? null : _skip,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        'Maybe later',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppColors.muted.withValues(alpha: 0.55),
                        ),
                      ),
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

class _StarRow extends StatelessWidget {
  final int rating;
  final ValueChanged<int> onChanged;

  const _StarRow({required this.rating, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (i) {
        final filled = i < rating;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(i + 1),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: AnimatedScale(
              scale: filled ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: Icon(
                filled
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                size: 36,
                color: filled
                    ? AppColors.amberGold
                    : AppColors.muted.withValues(alpha: 0.25),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _SubmitButton extends StatefulWidget {
  final bool saving;
  final VoidCallback onTap;

  const _SubmitButton({required this.saving, required this.onTap});

  @override
  State<_SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<_SubmitButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        if (!widget.saving) setState(() => _scale = 0.97);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.saving ? null : widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: double.infinity,
            height: 50,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown.withValues(
                alpha: widget.saving ? 0.5 : 1.0,
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: widget.saving
                  ? null
                  : [
                      BoxShadow(
                        color:
                            AppColors.primaryBrown.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: Center(
              child: widget.saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      'Submit',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
