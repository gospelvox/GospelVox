// Modal rating dialog for bible sessions — mirrors the SessionRatingDialog
// used after a chat/voice call so users get the SAME UX after every
// session type. Routed through BibleSessionRepository.rateBibleSession
// (which writes to `bible_sessions/{sid}/registrations/{uid}`) instead
// of the chat/voice path that updates a sessions/{id} doc.
//
// Behaviour parity with SessionRatingDialog:
//   • No backdrop or hardware-back dismiss.
//   • Submit is always visible. Empty-submit triggers a nudge instead
//     of closing — only the subtle top-right X dismisses without
//     writing.
//   • If the user fills anything (star OR text), Submit writes whichever
//     fields are populated.
//
// Caller flow: bible_session_detail_page auto-shows this the moment the
// session flips effectively-completed for a paid + not-yet-rated user.
// After submit/dismiss the page rebuilds — if the user rated, it shows
// the AlreadyRated view; if they dismissed empty, the in-body rating
// form remains visible as the second-chance path.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

class BibleSessionRatingDialog extends StatefulWidget {
  final BibleSessionModel session;

  const BibleSessionRatingDialog({super.key, required this.session});

  // Convenience launcher. Resolves to `true` when the user actually
  // submitted a rating, `false` when they dismissed without writing.
  // Caller uses this to decide whether to refresh the registration
  // before rebuilding the body state.
  static Future<bool> show(
    BuildContext context,
    BibleSessionModel session,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BibleSessionRatingDialog(session: session),
    );
    return result == true;
  }

  @override
  State<BibleSessionRatingDialog> createState() =>
      _BibleSessionRatingDialogState();
}

class _BibleSessionRatingDialogState
    extends State<BibleSessionRatingDialog> {
  final BibleSessionRepository _repository = BibleSessionRepository();
  final TextEditingController _feedbackController = TextEditingController();
  int _rating = 0;
  bool _saving = false;
  // Flips to true after the first Submit attempt without a star —
  // drives the "Tap a star to rate…" nudge that fades in below the
  // button. Once the user picks a star the nudge fades out
  // (feedback text is independent — optional, doesn't suppress the
  // nudge on its own).
  bool _emptySubmitAttempted = false;

  // Star rating is the mandatory gate — submit is blocked without
  // one. Feedback text remains optional. Used to drive the nudge
  // visibility below.
  bool get _hasRating => _rating > 0;

  @override
  void initState() {
    super.initState();
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

    // Star rating is mandatory. Submitting without a star — even
    // with feedback text typed — triggers a nudge instead of a
    // write. The previous implementation silently defaulted to
    // rating=5 for feedback-only submissions, which produced an
    // unconsented 5-star review on the priest's profile.
    if (_rating == 0) {
      HapticFeedback.lightImpact();
      if (!_emptySubmitAttempted) {
        setState(() => _emptySubmitAttempted = true);
      }
      return;
    }

    setState(() => _saving = true);

    try {
      await _repository.rateBibleSession(
        sessionId: widget.session.id,
        rating: _rating,
        feedback: feedback.isEmpty ? null : feedback,
      );
    } catch (_) {
      // Swallow — blocking the user on a metric-write failure feels
      // worse than silently losing one rating. Matches the call/chat
      // dialog's failure posture.
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _skip() {
    if (_saving) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final priestName = widget.session.priestName.trim();
    final headline = priestName.isNotEmpty
        ? 'How was your session with $priestName?'
        : 'How was your session?';
    // Nudge surfaces only when the priest tapped Submit without
    // picking a star. Once they tap a star it fades out — even if
    // they haven't typed feedback (text remains optional).
    final showNudge = _emptySubmitAttempted && !_hasRating;

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: AppColors.surfaceWhite,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 36),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 10, 14),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                    color: AppColors.fieldFill,
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
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  opacity: showNudge ? 1.0 : 0.0,
                  child: Center(
                    child: Text(
                      priestName.isNotEmpty
                          ? 'Tap a star to rate $priestName'
                          : 'Tap a star to rate this session',
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
                filled ? AppIcons.starFilled : AppIcons.starOutline,
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
                        color: AppColors.primaryBrown.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: Center(
              child: widget.saving
                  ? const SizedBox(
                      width: 32,
                      height: 32,
                      child: AppLoader(),
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
