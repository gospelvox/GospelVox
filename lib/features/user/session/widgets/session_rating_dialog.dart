// Modal rating dialog shown to the user immediately after a chat or
// voice session ends. Replaces the previous full PostSessionPage —
// the user no longer sees a dedicated screen with duration / coins /
// rate, just an inline ask-for-rating sheet that lets them either
// submit or dismiss.
//
// Always-enabled-submit UX:
//   • No backdrop dismiss. No hardware-back dismiss
//     (PopScope.canPop=false).
//   • Submit is ALWAYS visible and tappable. A small hint line
//     above the button reads "Tap a star or share a note" — it
//     fades out the moment the user interacts (taps a star OR
//     types a character). So the surface is honest: the button
//     is always there, the nudge appears only when the user
//     hasn't engaged yet, and disappears once they have.
//   • The dismiss affordance is a deliberately-subtle close icon
//     pinned to the top-right corner: low-opacity muted glyph,
//     small hit-area-but-visible-enough-to-find.
//   • If Submit is tapped with nothing filled, it closes silently
//     — equivalent to dismissing. If anything (star OR text) is
//     filled, _submit writes whatever's there. No data is lost,
//     no validation blocks the user.
//
// The session is already settled on the server by the time this
// dialog opens — endSession returned a SessionSummary up-stack and
// the cubit emitted VoiceCallEnded / ChatSessionEnded. So nothing
// in the app is blocked on this modal; whether the user taps
// Submit or the close icon, they go home.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

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
  // Flips to true the FIRST time the user taps Submit with no
  // rating and no text. Drives the "Share your valuable feedback"
  // nudge that appears below the button — only after an empty
  // submit attempt, not on first open. Resets implicitly: once
  // _hasAnyInput goes true, the nudge fades out regardless of
  // this flag.
  bool _emptySubmitAttempted = false;

  // True the moment the user has interacted — star tapped OR
  // non-blank text typed. Drives the nudge fade-out and gates
  // whether Submit writes data or shows the prompt.
  bool get _hasAnyInput =>
      _rating > 0 || _feedbackController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Rebuild on every keystroke so the nudge fade-out + Submit
    // behaviour react to the very first character.
    _feedbackController.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _feedbackController.removeListener(_onInputChanged);
    _feedbackController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final feedback = _feedbackController.text.trim();

    // Empty submit: don't close. Light haptic + flip the nudge
    // flag so "Share your valuable feedback" appears below the
    // button. User can still bail via the X corner — they're
    // never trapped, just nudged.
    if (feedback.isEmpty && _rating == 0) {
      HapticFeedback.lightImpact();
      if (!_emptySubmitAttempted) {
        setState(() => _emptySubmitAttempted = true);
      }
      return;
    }

    setState(() => _saving = true);

    try {
      // Write whichever fields the user filled in. Rating is
      // optional — the aggregator no-ops on a missing userRating,
      // and the priest's feedback log gets the text either way.
      final update = <String, dynamic>{};
      if (_rating > 0) update['userRating'] = _rating;
      if (feedback.isNotEmpty) update['userFeedback'] = feedback;
      await FirebaseFirestore.instance
          .doc('sessions/${widget.session.id}')
          .update(update)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Swallow — blocking the user on a metric-write failure
      // would feel worse than silently losing one rating.
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
    final priestName = widget.session.priestName.trim();
    final headline = priestName.isNotEmpty
        ? 'How was your session with $priestName?'
        : 'How was your session?';
    // Nudge appears only AFTER an empty submit attempt, never on
    // first open. Fades back out the moment the user fills any
    // input. Wrapped in AnimatedOpacity so the layout slot stays
    // reserved and the button below never shifts position.
    final showNudge = _emptySubmitAttempted && !_hasAnyInput;

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: AppColors.surfaceWhite,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        // Wider horizontal inset = visually smaller dialog. Premium
        // minimal apps use generous outside breathing room rather
        // than packing the dialog edge-to-edge.
        insetPadding: const EdgeInsets.symmetric(horizontal: 36),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 10, 14),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Subtle close icon — top-right. Low-opacity muted
                // glyph; users who want out can find it without
                // being shouted at.
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      onPressed: _saving ? null : _skip,
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: AppIcon(
                        AppIcons.close,
                        color: AppColors.muted.withValues(alpha: 0.35),
                      ),
                      splashRadius: 16,
                      tooltip: 'Close',
                    ),
                  ),
                ),
                // Personal headline — names the priest so the
                // question feels like it's about THAT conversation,
                // not a generic rating prompt. Compact font size
                // for the smaller dialog footprint.
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                  child: Text(
                    headline,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _StarRow(
                  rating: _rating,
                  onChanged: (value) => setState(() => _rating = value),
                ),
                const SizedBox(height: 14),
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
                      hintText: 'Share your thoughts…',
                      hintStyle: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted.withValues(alpha: 0.5),
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(12),
                      counterStyle: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Friendly nudge — only after the user tapped
                // Submit without filling anything. Opacity-only
                // fade so the button below never shifts position.
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  opacity: showNudge ? 1.0 : 0.0,
                  child: Center(
                    child: Text(
                      'Share your valuable feedback on $priestName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.amberGold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // Submit is always visible. If pressed empty, the
                // handler triggers a haptic nudge + the message
                // above; it does NOT close. If anything is filled,
                // writes and closes. X corner is the unconditional
                // escape.
                _SubmitButton(saving: _saving, onTap: _submit),
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
              child: AppIcon(
                filled
                    ? AppIcons.starFilled
                    : AppIcons.starOutline,
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
