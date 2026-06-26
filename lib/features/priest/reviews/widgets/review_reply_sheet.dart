// Reply composer bottom sheet for a single review.
//
// Constraints (all enforced server-side too):
//   • 300 character cap, counter visible.
//   • One reply per review.
//   • Editable for 24 hours after first publish, then locked. The
//     caller (PriestReviewsPage) only opens this sheet for the edit
//     path when ReviewReply.isEditable is true — the server is the
//     backstop if the priest somehow opens an expired session.
//
// UX notes:
//   • Sheet is non-dismissible while sending so a back-tap can't
//     leave the priest wondering whether their reply landed.
//   • Live char counter changes color at >280 (warning) → >=300
//     (limit reached) so the priest sees the boundary before the
//     keystroke that would overflow.
//   • Empty submit shakes the field + nudges, never silently sends.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
// Importing without `show` so the `PriestReviewsSnack` extension on
// BuildContext is also brought into scope (an explicit `show` clause
// would filter it out and silently break the success toast).
import 'package:gospel_vox/features/priest/reviews/pages/priest_reviews_page.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

class ReviewReplySheet extends StatefulWidget {
  final PriestReviewItem review;

  const ReviewReplySheet({super.key, required this.review});

  @override
  State<ReviewReplySheet> createState() => _ReviewReplySheetState();
}

class _ReviewReplySheetState extends State<ReviewReplySheet> {
  static const int _maxChars = 300;

  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.review.priestReply?.text ?? '',
    );
    _controller.addListener(_onChanged);
    // Auto-focus the composer so the keyboard is up the moment the
    // sheet settles — saves the priest a tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _onChanged() {
    if (!mounted) return;
    if (_errorText != null) {
      setState(() => _errorText = null);
    } else {
      // Cheap setState to refresh the live char counter — debouncing
      // would add complexity for no perceptible win on a 300-char cap.
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final text = _controller.text.trim();

    if (text.isEmpty) {
      HapticFeedback.lightImpact();
      setState(() => _errorText = 'Add a few words before posting.');
      return;
    }
    if (text.length > _maxChars) {
      // The input formatter blocks new keystrokes past 300, but a
      // paste could still slip a longer string in — guard explicitly.
      HapticFeedback.lightImpact();
      setState(
        () => _errorText = 'Replies must be $_maxChars characters or fewer.',
      );
      return;
    }

    setState(() => _saving = true);
    final wasEdit = widget.review.priestReply != null;

    try {
      await ReplyToReviewService.submit(
        review: widget.review,
        text: text,
      );
      if (!mounted) return;
      HapticFeedback.selectionClick();
      Navigator.of(context).pop(true);
      // Brief success surface — `wasEdit` decides the copy so the
      // priest gets a distinct confirmation between first send and
      // an in-window edit.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The page that pushed this sheet still has a valid context
        // by the time the post-frame callback runs. Pop happens
        // first so the success banner doesn't overlap the sheet's
        // dismiss animation.
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger == null) return;
      });
      _showSuccessToast(wasEdit ? 'Reply updated' : 'Reply posted');
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      // The CF surfaces precise reasons for each rejection path; use
      // them verbatim when they're user-friendly, fall back to a
      // generic line otherwise.
      final msg = e.message ?? '';
      setState(() {
        _saving = false;
        _errorText = msg.isEmpty
            ? 'Could not post your reply. Try again.'
            : msg;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = 'Could not post your reply. Try again.';
      });
    }
  }

  void _showSuccessToast(String message) {
    // The page that hosts this sheet is still mounted under us — we
    // post the success banner there via the snackbar extension on
    // BuildContext exposed from priest_reviews_page.
    // ignore: use_build_context_synchronously
    context.showReviewSuccess(message);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final len = _controller.text.characters.length;
    final atLimit = len >= _maxChars;
    final near = !atLimit && len >= _maxChars - 20;
    final counterColor = atLimit
        ? AppColors.errorRed
        : near
            ? AppColors.amberGold
            : AppColors.muted;

    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(24),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.muted.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.review.priestReply == null
                              ? 'Reply to review'
                              : 'Edit your reply',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.deepDarkBrown,
                          ),
                        ),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _saving
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: AppIcon(
                            AppIcons.close,
                            size: 18,
                            color: AppColors.muted
                                .withValues(alpha: _saving ? 0.2 : 0.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ReviewQuote(review: widget.review),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.fieldFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _errorText != null
                            ? AppColors.errorRed
                                .withValues(alpha: 0.5)
                            : Colors.transparent,
                      ),
                    ),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      maxLines: 5,
                      minLines: 4,
                      maxLength: _maxChars,
                      textCapitalization: TextCapitalization.sentences,
                      enabled: !_saving,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(_maxChars),
                      ],
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        color: AppColors.deepDarkBrown,
                      ),
                      decoration: InputDecoration(
                        hintText:
                            'Thank them, address their feedback, or '
                            'invite them back…',
                        hintStyle: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted.withValues(alpha: 0.55),
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(14),
                        // We render our own counter outside so we
                        // control the colour at the warning thresholds.
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (_errorText != null) ...[
                        AppIcon(
                          AppIcons.error,
                          size: 13,
                          color: AppColors.errorRed,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _errorText!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: AppColors.errorRed,
                            ),
                          ),
                        ),
                      ] else
                        Expanded(
                          child: Text(
                            'Replies are visible to the user and on '
                            'your public profile.',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        '$len / $_maxChars',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: counterColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SubmitButton(
                    label: widget.review.priestReply == null
                        ? 'Post Reply'
                        : 'Update Reply',
                    saving: _saving,
                    onTap: _submit,
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                      widget.review.priestReply == null
                          ? 'You can edit your reply for 24 hours after '
                              'posting.'
                          : 'Edits lock 24 hours after first publish.',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted.withValues(alpha: 0.85),
                      ),
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

// Compact quote of the review the priest is responding to. Keeps the
// composer screen feeling conversational instead of free-floating —
// the priest is always reminded of what specifically they're
// replying to.
class _ReviewQuote extends StatelessWidget {
  final PriestReviewItem review;
  const _ReviewQuote({required this.review});

  @override
  Widget build(BuildContext context) {
    final stars = review.stars;
    final feedback = review.feedback.trim();
    final name = _firstName(review.userName);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7F1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                name,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(5, (i) {
                  final filled = i < stars;
                  return AppIcon(
                    filled
                        ? AppIcons.starFilled
                        : AppIcons.starOutline,
                    size: 12,
                    color: filled
                        ? AppColors.amberGold
                        : AppColors.muted.withValues(alpha: 0.35),
                  );
                }),
              ),
            ],
          ),
          if (feedback.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              feedback,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.45,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _firstName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Someone';
    final firstSpace = trimmed.indexOf(' ');
    return firstSpace <= 0 ? trimmed : trimmed.substring(0, firstSpace);
  }
}

class _SubmitButton extends StatefulWidget {
  final String label;
  final bool saving;
  final VoidCallback onTap;

  const _SubmitButton({
    required this.label,
    required this.saving,
    required this.onTap,
  });

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
                alpha: widget.saving ? 0.55 : 1.0,
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: widget.saving
                  ? null
                  : [
                      BoxShadow(
                        color: AppColors.primaryBrown
                            .withValues(alpha: 0.22),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: Center(
              child: widget.saving
                  ? const SizedBox(
                      width: 35,
                      height: 35,
                      child: AppLoader(),
                    )
                  : Text(
                      widget.label,
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
