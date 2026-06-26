// Report + Block actions for the Speaker a user is in a live session
// with (chat or voice). Surfaced behind the ⋮ button in both session
// top bars.
//
// Why this exists: Google Play's User-Generated-Content and Child
// Safety policies require an in-app way to REPORT a person you're
// communicating with — blocking alone isn't enough. Block protects
// the reporter; Report routes the abuse to the admin queue. We offer
// both, chained in one gesture.
//
// Direction is user → Speaker only (the user is always the reporter
// on this surface). Both writes are safe to retry:
//   • Report → SessionRepository.reportPriest  (new reports/{id} doc
//              the admin queue already consumes — no admin changes)
//   • Block  → HomeRepository.setPriestBlocked (arrayUnion no-op if
//              already blocked) — the SAME call the priest-profile
//              Block uses, so behaviour is identical app-wide.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Reason options for the report picker. The `tag` is the short,
// machine-ish value stored in reports/{id}.reason; the `label` is
// what the user reads (and what's prepended to the description so the
// admin sees full context without a join).
class _ReportReason {
  final String tag;
  final String label;
  const _ReportReason(this.tag, this.label);
}

const List<_ReportReason> _kReasons = [
  _ReportReason('harassment', 'Harassment or bullying'),
  _ReportReason('inappropriate', 'Inappropriate behaviour'),
  _ReportReason('sexual', 'Nudity or sexual content'),
  _ReportReason('scam', 'Spam or scam'),
  _ReportReason('child_safety', 'Child safety concern'),
  _ReportReason('other', 'Something else'),
];

enum _MenuAction { report, block }

// Entry point. Opens the ⋮ menu and drives the whole Report / Block
// flow. Safe to call from any session surface; pass the Speaker being
// reported and the reporting user's identity.
Future<void> showSessionParticipantMenu(
  BuildContext context, {
  required String priestId,
  required String priestName,
  required String reporterUserId,
  required String reporterName,
  String? sessionId,
}) async {
  final action = await showModalBottomSheet<_MenuAction>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _ActionMenuSheet(),
  );
  if (action == null || !context.mounted) return;

  if (action == _MenuAction.report) {
    final reported = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ReportReasonSheet(
        priestId: priestId,
        priestName: priestName,
        reporterUserId: reporterUserId,
        reporterName: reporterName,
        sessionId: sessionId,
      ),
    );
    if (reported != true || !context.mounted) return;
    // Report filed — offer to also block, so both policy actions can
    // happen in one flow without making the user hunt for Block.
    final alsoBlock = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _AlsoBlockSheet(priestName: priestName),
    );
    if (alsoBlock == true && context.mounted) {
      await _block(context,
          priestId: priestId,
          priestName: priestName,
          reporterUserId: reporterUserId);
    }
    return;
  }

  // Block-only path.
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ConfirmBlockSheet(priestName: priestName),
  );
  if (confirmed == true && context.mounted) {
    await _block(context,
        priestId: priestId,
        priestName: priestName,
        reporterUserId: reporterUserId);
  }
}

// Standalone "Report this speaker" entry for surfaces OUTSIDE a live
// session — e.g. the user-side priest profile, where there's no
// session to attach. Shows the SAME reason picker the in-session menu
// uses and writes the SAME reports/{id} doc (just with a null
// sessionId), so the admin queue and Child-Safety/UGC compliance are
// identical across both surfaces. Returns true if a report was filed.
Future<bool> showReportSpeakerSheet(
  BuildContext context, {
  required String priestId,
  required String priestName,
  required String reporterUserId,
  required String reporterName,
}) async {
  final reported = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ReportReasonSheet(
      priestId: priestId,
      priestName: priestName,
      reporterUserId: reporterUserId,
      reporterName: reporterName,
      sessionId: null,
    ),
  );
  return reported == true;
}

// Shared block write + feedback. Mirrors priest_profile_page's block:
// idempotent arrayUnion, so a retried tap can't corrupt state.
Future<void> _block(
  BuildContext context, {
  required String priestId,
  required String priestName,
  required String reporterUserId,
}) async {
  try {
    await sl<HomeRepository>().setPriestBlocked(
      userId: reporterUserId,
      priestId: priestId,
      blocked: true,
    );
    if (context.mounted) {
      AppSnackBar.success(context, '$priestName has been blocked.');
    }
  } catch (_) {
    if (context.mounted) {
      AppSnackBar.error(context, 'Could not block. Please try again.');
    }
  }
}

// ─── Sheets ────────────────────────────────────────────────────

// Shared shell: rounded top, drag handle, safe-area bottom padding.
class _SheetShell extends StatelessWidget {
  final Widget child;
  const _SheetShell({required this.child});

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomPad + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.muted.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          // Scroll-fallback: when the keyboard opens for the Report
          // note field, the radio list + field + Submit button can
          // exceed the space left above the keyboard on a small phone.
          // Flexible + scroll lets the body shrink and scroll instead
          // of overflowing; it stays its natural (min) height otherwise.
          Flexible(
            child: SingleChildScrollView(
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionMenuSheet extends StatelessWidget {
  const _ActionMenuSheet();

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionRow(
            icon: AppIcons.report,
            label: 'Report',
            color: AppColors.deepDarkBrown,
            onTap: () => Navigator.of(context).pop(_MenuAction.report),
          ),
          const SizedBox(height: 4),
          _ActionRow(
            icon: AppIcons.block,
            label: 'Block',
            color: AppColors.errorRed,
            onTap: () => Navigator.of(context).pop(_MenuAction.block),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
        child: Row(
          children: [
            AppIcon(icon, size: 18, color: color),
            const SizedBox(width: 16),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Reason picker + optional note. Does the report write itself so the
// Submit button can show a spinner; pops `true` only on success.
class _ReportReasonSheet extends StatefulWidget {
  final String priestId;
  final String priestName;
  final String reporterUserId;
  final String reporterName;
  final String? sessionId;

  const _ReportReasonSheet({
    required this.priestId,
    required this.priestName,
    required this.reporterUserId,
    required this.reporterName,
    required this.sessionId,
  });

  @override
  State<_ReportReasonSheet> createState() => _ReportReasonSheetState();
}

class _ReportReasonSheetState extends State<_ReportReasonSheet> {
  _ReportReason? _selected;
  final TextEditingController _note = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _selected;
    if (reason == null || _submitting) return;
    setState(() => _submitting = true);

    // Human-readable label first so the admin reads it without a
    // lookup table; append the free-text note when present.
    final note = _note.text.trim();
    final description = note.isEmpty ? reason.label : '${reason.label} — $note';

    try {
      await sl<SessionRepository>().reportPriest(
        reportedPriestId: widget.priestId,
        reportedPriestName: widget.priestName,
        reporterUserId: widget.reporterUserId,
        reporterName: widget.reporterName,
        reason: reason.tag,
        description: description,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      AppSnackBar.success(
        context,
        'Report submitted. Our team will review it.',
      );
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      AppSnackBar.error(context, 'Could not submit report. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Report ${widget.priestName}',
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tell us what went wrong. Reports are confidential.',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          ..._kReasons.map((r) {
            final isSel = _selected?.tag == r.tag;
            return InkWell(
              onTap: _submitting ? null : () => setState(() => _selected = r),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    AppIcon(
                      isSel
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: isSel ? AppColors.primaryBrown : AppColors.muted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        r.label,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight:
                              isSel ? FontWeight.w600 : FontWeight.w400,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            enabled: !_submitting,
            maxLines: 3,
            minLines: 2,
            maxLength: 500,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppColors.deepDarkBrown,
            ),
            decoration: InputDecoration(
              hintText: 'Add details (optional)',
              hintStyle: GoogleFonts.inter(
                fontSize: 14,
                color: AppColors.muted,
              ),
              filled: true,
              fillColor: AppColors.background,
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed:
                  (_selected == null || _submitting) ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.errorRed,
                disabledBackgroundColor:
                    AppColors.errorRed.withValues(alpha: 0.4),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 32,
                      height: 32,
                      child: AppLoader(),
                    )
                  : Text(
                      'Submit report',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// Post-report follow-up: "Also block?"
class _AlsoBlockSheet extends StatelessWidget {
  final String priestName;
  const _AlsoBlockSheet({required this.priestName});

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Also block $priestName?',
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "You won't see them in your feed or be able to start a "
            'session with them. You can unblock later from Settings.',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(
                      color: AppColors.muted.withValues(alpha: 0.4),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Not now',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.errorRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Block',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Block-only confirm (when the user taps Block directly).
class _ConfirmBlockSheet extends StatelessWidget {
  final String priestName;
  const _ConfirmBlockSheet({required this.priestName});

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Block $priestName?',
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "You won't see them in your feed or be able to start a "
            'session with them. You can unblock later from Settings.',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(
                      color: AppColors.muted.withValues(alpha: 0.4),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.errorRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Block',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
