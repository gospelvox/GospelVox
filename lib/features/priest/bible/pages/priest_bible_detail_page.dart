// Priest-side detail page for a Bible session they own. Branches on
// session.status into four distinct views: upcoming / live / completed
// / cancelled.
//
// Session state is watched via `repository.watchSession` so the page
// reacts immediately when the priest goes live, when the auto-complete
// cron flips the session, or when an admin force-cancels. Registrations
// are loaded once and reloaded after each priest-side mutation —
// registrations don't change often enough to justify a live listener.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/pulsing_dot.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';
import 'package:gospel_vox/features/shared/data/meeting_platform.dart';
import 'package:gospel_vox/features/shared/widgets/meeting_platform_selector.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

const Color _kCompletedGreen = AppColors.successGreen;
const Color _kLiveRed = AppColors.liveRed;

class PriestBibleDetailPage extends StatefulWidget {
  final String sessionId;
  const PriestBibleDetailPage({super.key, required this.sessionId});

  @override
  State<PriestBibleDetailPage> createState() =>
      _PriestBibleDetailPageState();
}

class _PriestBibleDetailPageState extends State<PriestBibleDetailPage> {
  final BibleSessionRepository _repository = BibleSessionRepository();

  late final Stream<BibleSessionModel> _sessionStream;
  List<BibleRegistration> _registrations = const [];
  bool _registrationsLoaded = false;
  bool _isMutating = false;
  // Commission split (%) from app_config, so the "Earned"/"Revenue"
  // tiles show the NET the priest actually receives (matching the
  // wallet), not the gross ticket price. Defaults to the model default
  // until the live value loads.
  int _bibleCommissionPercent = BibleSessionModel.defaultCommissionPercent;
  // Tracks if any priest-side mutation happened that should bubble up
  // to the list page (cancel, complete, add link, start). Returned as
  // pop() result so the list reloads only when needed.
  bool _changed = false;

  // Ticks every 30 s so the time-based view branch
  // (isEffectivelyLive / isPastDeadline) re-evaluates without waiting
  // for the auto-complete cron to flip the doc. Without this, a
  // priest sitting on this page when their session crosses the
  // deadline would stay on the Live view (open meeting / mark
  // completed) for up to a cron cycle.
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _sessionStream = _repository.watchSession(widget.sessionId);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (mounted) setState(() {});
      },
    );
    _loadRegistrations();
    _loadCommission();
  }

  Future<void> _loadCommission() async {
    final pct = await _repository.getBibleCommissionPercent();
    if (!mounted) return;
    setState(() => _bibleCommissionPercent = pct);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadRegistrations() async {
    try {
      final regs = await _repository.getRegistrations(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _registrations = regs;
        _registrationsLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _registrationsLoaded = true);
    }
  }

  // Wraps mutation calls so we don't double-fire while one's pending.
  Future<void> _runMutation(Future<void> Function() action) async {
    if (_isMutating) return;
    setState(() => _isMutating = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }
  }

  // ── Mutations ─────────────────────────────────────────────────

  Future<void> _showAddLinkSheet(BibleSessionModel session) async {
    final updated = await showModalBottomSheet<
        ({
          String link,
          String platformId,
          String meetingId,
          String passcode,
        })>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddLinkSheet(
        initialLink: session.meetingLink,
        initialPlatform: session.meetingPlatform,
        initialMeetingId: session.meetingId,
        initialPasscode: session.meetingPasscode,
      ),
    );
    if (!mounted || updated == null) return;
    await _runMutation(() async {
      try {
        await _repository.updateMeetingLink(
          widget.sessionId,
          updated.link,
          meetingPlatform: updated.platformId,
          meetingId: updated.meetingId,
          meetingPasscode: updated.passcode,
        );
        if (!mounted) return;
        _changed = true;
        AppSnackBar.success(
          context,
          updated.link.isEmpty
              ? "Link cleared."
              : "Meeting link saved — registered users will see it.",
        );
      } catch (_) {
        if (!mounted) return;
        AppSnackBar.error(
          context,
          "Couldn't save link. Please try again.",
        );
      }
    });
  }

  Future<void> _confirmStart(BibleSessionModel session) async {
    final activeCount = _registrations.length;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _StartMeetingConfirmationSheet(
        registeredCount: activeCount,
        price: session.price,
        durationMinutes: session.durationMinutes,
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runMutation(() async {
      try {
        final notified =
            await _repository.startBibleSession(widget.sessionId);
        if (!mounted) return;
        _changed = true;
        AppSnackBar.success(
          context,
          notified > 0
              ? "Meeting started! $notified "
                  "${notified == 1 ? 'user' : 'users'} notified."
              : "Meeting started!",
        );
        // Auto-launch the meeting link so the priest doesn't have to
        // tap a second time. Best-effort: a launch failure doesn't
        // roll back — the session is genuinely live and they can tap
        // the Open Meeting button on the next frame.
        await _launchMeeting(session.meetingLink);
      } catch (e) {
        if (!mounted) return;
        AppSnackBar.error(context, _humanError(e));
      }
    });
  }

  Future<void> _confirmCancel(BibleSessionModel session) async {
    final paidCount = _registrations.where((r) => r.isPaid).length;
    final registeredOnly =
        _registrations.where((r) => r.isRegistered).length;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CancelSessionSheet(
        paidCount: paidCount,
        registeredOnlyCount: registeredOnly,
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runMutation(() async {
      try {
        final notified = await _repository.cancelSession(
          sessionId: widget.sessionId,
          sessionTitle: session.title.isNotEmpty
              ? session.title
              : 'Bible Session',
          priestName: session.priestName.isNotEmpty
              ? session.priestName
              : 'The speaker',
        );
        if (!mounted) return;
        _changed = true;
        AppSnackBar.info(
          context,
          notified > 0
              ? 'Session cancelled. $notified registered '
                  '${notified == 1 ? "user has" : "users have"} '
                  'been notified.'
              : 'Session cancelled.',
        );
      } catch (e, st) {
        // Log the actual error so a developer running `flutter logs`
        // can see WHY the cancel failed — silent catches turned a
        // missing-CF deploy into an unhelpful "Couldn't cancel"
        // toast with no diagnostic trail.
        debugPrint('[BibleCancel] failed: $e\n$st');
        if (!mounted) return;
        AppSnackBar.error(context, _humanMutationError(e, action: 'cancel'));
      }
    });
  }

  Future<void> _confirmComplete() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ConfirmSheet(
        title: "Mark this session as completed?",
        message:
            "Use this once the meeting has wrapped. The session will "
            "move to your past sessions and post-session ratings "
            "become available to attendees.",
        confirmLabel: "Mark Completed",
        cancelLabel: "Not yet",
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runMutation(() async {
      try {
        await _repository.completeSession(widget.sessionId);
        if (!mounted) return;
        _changed = true;
        AppSnackBar.success(context, "Session marked as completed.");
        await _loadRegistrations();
      } catch (e, st) {
        // Log the actual error so a developer running `flutter logs`
        // can see WHY the complete failed — silent catches turned a
        // missing-CF deploy into an unhelpful "Couldn't update"
        // toast with no diagnostic trail.
        debugPrint('[BibleComplete] failed: $e\n$st');
        if (!mounted) return;
        AppSnackBar.error(
          context,
          _humanMutationError(e, action: 'complete'),
        );
      }
    });
  }

  // Maps the most common server-call failures into actionable copy.
  // The `action` argument is woven into the message so a missing-CF
  // deploy reads as "Server isn't ready — complete won't work" instead
  // of a generic "something failed".
  //
  // Codes we map:
  //   • not-found        → Functions not deployed yet. Most common
  //                        cause when fresh devs run the app against
  //                        a Firebase project where `firebase deploy
  //                        --only functions` hasn't been run.
  //   • permission-denied → Caller isn't the session owner. Surface
  //                        verbatim so support can see the mismatch.
  //   • failed-precondition → Session is already terminal (cancelled
  //                        / completed). Specific to bible CFs.
  //   • unauthenticated  → Auth state lost mid-flow. Prompt re-sign.
  //   • TimeoutException → Network or cold-start hang. Suggest retry.
  String _humanMutationError(Object e, {required String action}) {
    if (e is FirebaseFunctionsException) {
      switch (e.code) {
        case 'not-found':
          return "Server functions aren't deployed for $action. "
              "Run: firebase deploy --only functions";
        case 'permission-denied':
          return "You don't own this session, so it can't be $action"
              "${action.endsWith('e') ? 'd' : 'ed'}.";
        case 'failed-precondition':
          return e.message ??
              "This session can't be $action${action.endsWith('e') ? 'd' : 'ed'} in its current state.";
        case 'unauthenticated':
          return 'Please sign in again to continue.';
        default:
          return "Couldn't $action. ${e.message ?? 'Please try again.'}";
      }
    }
    if (e is TimeoutException) {
      return "$action timed out. Check your connection and try again.";
    }
    return "Couldn't $action. Please try again.";
  }

  // Launch the meeting link in the OS default handler. Returns true
  // if the launch succeeded; the caller decides whether to surface a
  // failure or just let the user retry via the page's Open Meeting
  // button.
  Future<bool> _launchMeeting(String url) async {
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  Future<void> _showLinkGuide(MeetingPlatform platform) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MeetLinkGuideSheet(platform: platform),
    );
  }

  // Translate CF HttpsError code into something a priest can act on.
  // Most "couldn't start" errors come from preconditions:
  //   • no meeting link (UI gate above usually prevents this)
  //   • another live session for this priest
  //   • the session has already moved past 'upcoming' (rare race)
  String _humanError(Object e) {
    final msg = e.toString();
    if (msg.contains('already have a live session')) {
      return "You already have another live session. "
          "Complete or auto-end that one first.";
    }
    if (msg.contains('meeting link')) {
      return "Please add the meeting link first.";
    }
    if (msg.contains('Cannot start')) {
      return "This session is no longer in 'upcoming' state.";
    }
    return "Couldn't start the meeting. Please try again.";
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          foregroundColor: AppColors.deepDarkBrown,
          leading: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Align(
              alignment: Alignment.center,
              child: AppBackButton(
                onTap: () => Navigator.of(context).pop(_changed),
              ),
            ),
          ),
          title: Text(
            "Manage Session",
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
        body: StreamBuilder<BibleSessionModel>(
          stream: _sessionStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return _buildError("Couldn't load session.");
            }
            if (!snap.hasData) {
              return _buildLoading();
            }
            final session = snap.data!;
            return RefreshIndicator(
              color: AppColors.primaryBrown,
              backgroundColor: AppColors.surfaceWhite,
              onRefresh: _loadRegistrations,
              child: _buildLoaded(session),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLoading() {
    final base = AppColors.muted.withValues(alpha: 0.14);
    final highlight = AppColors.warmBeige;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.all(20),
      children: [
        Shimmer.fromColors(
          baseColor: base,
          highlightColor: highlight,
          child: Container(
            height: 220,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Shimmer.fromColors(
          baseColor: base,
          highlightColor: highlight,
          child: Container(
            height: 140,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError(String message) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        AppIcon(
          AppIcons.error,
          size: 44,
          color: AppColors.errorRed,
        ),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }

  Widget _buildLoaded(BibleSessionModel session) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SessionInfoCard(session: session),
          const SizedBox(height: 16),
          // isEffectivelyLive — a status='live' doc whose deadline
          // has passed must NOT render the Live state view (open-
          // meeting button + complete CTA), because the meeting is
          // already over. We route it through the Completed view
          // instead. The auto-complete cron will flip the doc on
          // its next tick; meanwhile the priest sees the correct
          // post-session UI immediately.
          if (session.isEffectivelyLive)
            _LiveStateView(
              session: session,
              paidCount:
                  _registrations.where((r) => r.isPaid).length,
              commissionPercent: _bibleCommissionPercent,
              registrationsLoaded: _registrationsLoaded,
              isMutating: _isMutating,
              onOpenMeeting: () => _launchMeeting(session.meetingLink),
              onComplete: _confirmComplete,
            )
          else if (session.isUpcoming)
            _UpcomingStateView(
              session: session,
              registrations: _registrations,
              registrationsLoaded: _registrationsLoaded,
              isMutating: _isMutating,
              onAddLink: () => _showAddLinkSheet(session),
              onShowLinkGuide: () => _showLinkGuide(session.platform),
              onStart: () => _confirmStart(session),
              onCancel: () => _confirmCancel(session),
            )
          else if (session.isEffectivelyCompleted)
            _CompletedStateView(
              session: session,
              registrations: _registrations,
              registrationsLoaded: _registrationsLoaded,
              commissionPercent: _bibleCommissionPercent,
            )
          else
            _CancelledStateView(
              session: session,
              attendedCount: _registrations
                  .where((r) => !r.isCancelled)
                  .length,
            ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// SESSION INFO CARD (common header — used in all 4 states)
// ════════════════════════════════════════════════════════════════

class _SessionInfoCard extends StatelessWidget {
  final BibleSessionModel session;
  const _SessionInfoCard({required this.session});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: session.isEffectivelyLive
              ? _kLiveRed.withValues(alpha: 0.3)
              : AppColors.muted.withValues(alpha: 0.06),
          width: session.isEffectivelyLive ? 1.4 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _HeaderStatusPill(session: session),
              const Spacer(),
              Text(
                "₹${session.price}",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            session.title,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
              height: 1.25,
            ),
          ),
          if (session.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              session.description,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.55,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: AppIcons.calendar,
                text: session.formattedDate,
              ),
              _InfoChip(
                icon: AppIcons.clock,
                text: '${session.formattedTime} IST',
              ),
              _InfoChip(
                icon: AppIcons.stopwatch,
                text: session.formattedDuration,
              ),
              if (session.category.isNotEmpty)
                _InfoChip(
                  icon: AppIcons.tag,
                  text: session.category,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderStatusPill extends StatelessWidget {
  final BibleSessionModel session;
  const _HeaderStatusPill({required this.session});

  @override
  Widget build(BuildContext context) {
    if (session.isEffectivelyLive) {
      return Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _kLiveRed.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PulsingDot(size: 7, color: _kLiveRed),
            const SizedBox(width: 6),
            Text(
              "LIVE",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: _kLiveRed,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      );
    }
    final color = session.isUpcoming
        ? AppColors.amberGold
        : session.isEffectivelyCompleted
            ? _kCompletedGreen
            : AppColors.muted;
    final label = session.isUpcoming
        ? "UPCOMING"
        : session.isEffectivelyCompleted
            ? "COMPLETED"
            : "CANCELLED";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.warmBeige,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 13, color: AppColors.primaryBrown),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE: UPCOMING
// ════════════════════════════════════════════════════════════════

class _UpcomingStateView extends StatelessWidget {
  final BibleSessionModel session;
  final List<BibleRegistration> registrations;
  final bool registrationsLoaded;
  final bool isMutating;
  final VoidCallback onAddLink;
  final VoidCallback onShowLinkGuide;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  const _UpcomingStateView({
    required this.session,
    required this.registrations,
    required this.registrationsLoaded,
    required this.isMutating,
    required this.onAddLink,
    required this.onShowLinkGuide,
    required this.onStart,
    required this.onCancel,
  });

  // The Start Meeting gate. Two conditions must both hold:
  //   1. A meeting link is set. The CF refuses without one and the
  //      pay-on-live flow needs it to hand out.
  //   2. We're within 30 min before the scheduled start, OR past
  //      scheduled time (priest can start late — no upper bound,
  //      matches the prompt spec).
  // The CF itself doesn't enforce condition 2; this is the UI-only
  // guardrail against starting weeks before scheduledAt.
  bool get _canStart {
    if (!session.hasLink) return false;
    if (session.scheduledAt == null) return false;
    final diff = session.scheduledAt!
        .toLocal()
        .difference(DateTime.now())
        .inMinutes;
    return diff <= 30; // any negative diff is fine (priest is late)
  }

  String? get _startDisabledReason {
    if (!session.hasLink) return "Add the meeting link first.";
    if (session.scheduledAt == null) return null;
    final diff = session.scheduledAt!
        .toLocal()
        .difference(DateTime.now())
        .inMinutes;
    if (diff > 30) {
      final hours = diff ~/ 60;
      if (hours >= 1) {
        return "You can start within 30 min of the scheduled time.";
      }
      return "Available in $diff min.";
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MeetLinkSection(
          session: session,
          onTap: onAddLink,
          onShowGuide: onShowLinkGuide,
        ),
        const SizedBox(height: 12),
        const _MeetingGuidelinesCard(),
        const SizedBox(height: 16),
        _AttendeesSection(
          registrations: registrations,
          loaded: registrationsLoaded,
          maxParticipants: session.maxParticipants,
          showRatings: false,
        ),
        const SizedBox(height: 24),
        _PrimaryActionButton(
          label: "Start Meeting",
          onTap: (_canStart && !isMutating) ? onStart : null,
          disabledHint: _startDisabledReason,
        ),
        const SizedBox(height: 10),
        _OutlinedActionButton(
          label: "Cancel Session",
          color: AppColors.errorRed,
          onTap: isMutating ? null : onCancel,
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE: LIVE
// ════════════════════════════════════════════════════════════════
//
// Holds its own 30-second Timer so the countdown pill and the
// "Mark Complete" gate (50% of duration must have elapsed) both
// refresh without re-rendering the rest of the page. The session
// stream still drives state transitions (live → completed) — this
// timer only refreshes the local time-derived bits.

class _LiveStateView extends StatefulWidget {
  final BibleSessionModel session;
  final int paidCount;
  final int commissionPercent;
  final bool registrationsLoaded;
  final bool isMutating;
  final Future<bool> Function() onOpenMeeting;
  final VoidCallback onComplete;

  const _LiveStateView({
    required this.session,
    required this.paidCount,
    required this.commissionPercent,
    required this.registrationsLoaded,
    required this.isMutating,
    required this.onOpenMeeting,
    required this.onComplete,
  });

  @override
  State<_LiveStateView> createState() => _LiveStateViewState();
}

class _LiveStateViewState extends State<_LiveStateView> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // Manual completion only allowed once at least half the scheduled
  // duration has elapsed — guards against a priest tapping Mark
  // Complete to bail on a session two minutes in. Past the halfway
  // mark, we trust them.
  bool get _canManualComplete {
    final startedAt = widget.session.startedAt;
    if (startedAt == null) return false;
    final halfwayMs = (widget.session.durationMinutes * 60 * 1000) ~/ 2;
    final elapsedMs =
        DateTime.now().difference(startedAt.toLocal()).inMilliseconds;
    return elapsedMs >= halfwayMs;
  }

  Duration get _elapsed {
    final startedAt = widget.session.startedAt;
    if (startedAt == null) return Duration.zero;
    return DateTime.now().difference(startedAt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // Net of commission — matches what actually lands in the wallet.
    final revenue =
        session.priestNetEarnings(widget.paidCount, widget.commissionPercent);
    final elapsedMin = _elapsed.inMinutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Live status banner — pulsing dot + countdown
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _kLiveRed.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _kLiveRed.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const PulsingDot(size: 9, color: _kLiveRed),
                  const SizedBox(width: 8),
                  Text(
                    "LIVE NOW",
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _kLiveRed,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    session.remainingTimeText,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _kLiveRed,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                elapsedMin == 0
                    ? "Started moments ago"
                    : "Started $elapsedMin min ago",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Open Meeting button — primary action while live
        _PrimaryActionButton(
          label: "Open Meeting",
          onTap: widget.isMutating
              ? null
              : () async {
                  final ok = await widget.onOpenMeeting();
                  if (!context.mounted) return;
                  if (!ok) {
                    AppSnackBar.error(
                      context,
                      "Couldn't open the meeting link.",
                    );
                  }
                },
        ),
        const _MeetingGuidelinesCard(),
        const SizedBox(height: 12),

        // Revenue + attendance summary
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.06),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: "Joined (paid)",
                  value: widget.registrationsLoaded
                      ? "${widget.paidCount} / ${session.registrationCount}"
                      : "—",
                  icon: AppIcons.users,
                ),
              ),
              Container(
                width: 1,
                height: 36,
                color: AppColors.muted.withValues(alpha: 0.1),
              ),
              Expanded(
                child: _StatTile(
                  label: "Earned so far",
                  value: "₹$revenue",
                  icon: AppIcons.rupee,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Mark Complete — gated to past 50% of duration
        if (_canManualComplete)
          _OutlinedActionButton(
            label: "Mark as Completed",
            color: AppColors.primaryBrown,
            onTap: widget.isMutating ? null : widget.onComplete,
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: AppColors.warmBeige.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.12),
              ),
            ),
            child: Row(
              children: [
                AppIcon(
                  AppIcons.lockClock,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "You can mark this completed after half the "
                    "scheduled duration.",
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.muted,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),

        // Auto-complete footer
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.amberGold.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.amberGold.withValues(alpha: 0.18),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(
                AppIcons.info,
                size: 14,
                color: AppColors.amberGold,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "This session auto-completes when its duration ends. "
                  "Mark it complete sooner if you finish early.",
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.amberGold.withValues(alpha: 0.95),
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(icon, size: 13, color: AppColors.primaryBrown),
              const SizedBox(width: 5),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE: COMPLETED
// ════════════════════════════════════════════════════════════════

class _CompletedStateView extends StatelessWidget {
  final BibleSessionModel session;
  final List<BibleRegistration> registrations;
  final bool registrationsLoaded;
  final int commissionPercent;

  const _CompletedStateView({
    required this.session,
    required this.registrations,
    required this.registrationsLoaded,
    required this.commissionPercent,
  });

  @override
  Widget build(BuildContext context) {
    final paid = registrations.where((r) => r.isPaid).toList();
    final ratings = paid.where((r) => r.hasRated).toList();
    // Net of commission — matches the wallet ledger, not gross price.
    final revenue = session.priestNetEarnings(paid.length, commissionPercent);
    final avg = ratings.isEmpty
        ? 0.0
        : ratings.fold<int>(0, (a, r) => a + (r.rating ?? 0)) /
            ratings.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.06),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(
                    AppIcons.checkCircle,
                    size: 18,
                    color: _kCompletedGreen,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "SESSION SUMMARY",
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _kCompletedGreen,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _StatTile(
                      label: "Duration",
                      value: session.formattedDuration,
                      icon: AppIcons.stopwatch,
                    ),
                  ),
                  Expanded(
                    child: _StatTile(
                      label: "Attendees",
                      value: "${paid.length}",
                      icon: AppIcons.users,
                    ),
                  ),
                  Expanded(
                    child: _StatTile(
                      label: "Revenue",
                      value: "₹$revenue",
                      icon: AppIcons.rupee,
                    ),
                  ),
                ],
              ),
              if (ratings.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.amberGold.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      AppIcon(
                        AppIcons.starFilled,
                        size: 16,
                        color: AppColors.amberGold,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        avg.toStringAsFixed(1),
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        "average from ${ratings.length} "
                        "${ratings.length == 1 ? 'review' : 'reviews'}",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_wasAutoCompleted(session)) ...[
                const SizedBox(height: 10),
                Text(
                  "Auto-completed by the system after the scheduled "
                  "duration.",
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _AttendeesSection(
          registrations: registrations,
          loaded: registrationsLoaded,
          maxParticipants: session.maxParticipants,
          showRatings: true,
        ),
      ],
    );
  }

  // We can't read the autoCompleted flag from the model (it's not
  // surfaced as a typed field), but if completedAt exists and the
  // priest didn't manually complete (which would have shown a
  // distinct snackbar moment), we can't reliably distinguish without
  // the raw doc. For V1 we simply show the auto-completion footer
  // when the session ended within 30 min of `scheduledAt + duration`
  // — that window catches almost every cron completion and avoids
  // making the model carry a one-purpose audit flag.
  bool _wasAutoCompleted(BibleSessionModel s) {
    final scheduledAt = s.scheduledAt;
    final completedAt = s.completedAt;
    if (scheduledAt == null || completedAt == null) return false;
    final expectedEnd = scheduledAt.add(
      Duration(minutes: s.durationMinutes),
    );
    final delta = completedAt.difference(expectedEnd).inMinutes.abs();
    return delta <= 30;
  }
}

// ════════════════════════════════════════════════════════════════
// STATE: CANCELLED
// ════════════════════════════════════════════════════════════════

class _CancelledStateView extends StatelessWidget {
  final BibleSessionModel session;
  final int attendedCount;
  const _CancelledStateView({
    required this.session,
    required this.attendedCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.cancel,
                size: 18,
                color: AppColors.errorRed,
              ),
              const SizedBox(width: 8),
              Text(
                "SESSION CANCELLED",
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.errorRed,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            attendedCount == 0
                ? "This session was cancelled with no active "
                    "registrations."
                : "$attendedCount registered "
                    "${attendedCount == 1 ? 'user was' : 'users were'} "
                    "notified.",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.deepDarkBrown,
              height: 1.5,
            ),
          ),
          if (session.cancelledAt != null) ...[
            const SizedBox(height: 8),
            Text(
              "Cancelled ${_formatFullDate(session.cancelledAt!)} · "
              "${_formatTimeFromDate(session.cancelledAt!)}",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// MEET LINK SECTION
// ════════════════════════════════════════════════════════════════

// ════════════════════════════════════════════════════════════════
// MEETING GUIDELINES CARD
// ════════════════════════════════════════════════════════════════
//
// Shown in BOTH the upcoming view (so the priest reads the rules
// before tapping Start Meeting) and the live view (so they can
// reference them while the meeting is running). Stateless because
// the copy is fixed; if guidelines ever need to be remote-config
// driven we'd swap the literal list for a config read here.

class _MeetingGuidelinesCard extends StatelessWidget {
  const _MeetingGuidelinesCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.info,
                size: 14,
                color: AppColors.amberGold,
              ),
              const SizedBox(width: 6),
              Text(
                "Meeting Guidelines",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.amberGold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "• Join using the same Google account where you created "
            "the meeting link\n"
            "• Start the meeting before users join\n"
            "• Stay for the full session duration\n"
            "• Admit waiting participants promptly",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _MeetLinkSection extends StatelessWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;
  final VoidCallback onShowGuide;

  const _MeetLinkSection({
    required this.session,
    required this.onTap,
    required this.onShowGuide,
  });

  @override
  Widget build(BuildContext context) {
    final hasLink = session.hasLink;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.video,
                size: 18,
                color: AppColors.muted,
              ),
              const SizedBox(width: 10),
              Text(
                session.platform.linkLabel,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onShowGuide,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  child: const AppIcon(
                    AppIcons.info,
                    size: 18,
                    color: Color(0xFF3B82F6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (hasLink) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warmBeige.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                session.meetingLink,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            if (session.hasMeetingId || session.hasPasscode) ...[
              const SizedBox(height: 8),
              if (session.hasMeetingId)
                _MeetExtraLine(
                  label: "Meeting ID",
                  value: session.meetingId,
                ),
              if (session.hasPasscode)
                _MeetExtraLine(
                  label: "Passcode",
                  value: session.meetingPasscode,
                ),
            ],
            const SizedBox(height: 12),
            Center(
              child: _PressableButton(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: AppColors.primaryBrown,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    "Edit Link",
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBrown,
                    ),
                  ),
                ),
              ),
            ),
          ] else ...[
            Center(
              child: AppIcon(
                AppIcons.video,
                size: 36,
                color: AppColors.muted.withValues(alpha: 0.2),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                "No Meet link added yet",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                "Add the link before you Start the Meeting.",
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.7),
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: _PressableButton(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.amberGold,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color:
                            AppColors.amberGold.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Text(
                    "Add Meeting Link",
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// ATTENDEES SECTION (used by upcoming + completed views)
// ════════════════════════════════════════════════════════════════

class _AttendeesSection extends StatelessWidget {
  final List<BibleRegistration> registrations;
  final bool loaded;
  final int maxParticipants;
  // In completed-state views we surface star ratings next to each
  // attendee that left one. In other states we just show paid /
  // registered status.
  final bool showRatings;

  const _AttendeesSection({
    required this.registrations,
    required this.loaded,
    required this.maxParticipants,
    required this.showRatings,
  });

  @override
  Widget build(BuildContext context) {
    final visible = registrations.where((r) => !r.isCancelled).toList();
    final countText = maxParticipants > 0
        ? "${visible.length} / $maxParticipants"
        : "${visible.length}";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.users,
                size: 18,
                color: AppColors.muted,
              ),
              const SizedBox(width: 10),
              Text(
                showRatings ? "ATTENDEES & FEEDBACK" : "ATTENDEES",
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  loaded ? countText : "—",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryBrown,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (!loaded)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                  width: 29,
                  height: 29,
                  child: AppLoader(),
                ),
              ),
            )
          else if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  "No attendees yet — share your session with others!",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.7),
                  ),
                ),
              ),
            )
          else
            ...visible.map(
              (r) => _AttendeeTile(
                registration: r,
                showRating: showRatings,
              ),
            ),
        ],
      ),
    );
  }
}

class _AttendeeTile extends StatelessWidget {
  final BibleRegistration registration;
  final bool showRating;
  const _AttendeeTile({
    required this.registration,
    required this.showRating,
  });

  @override
  Widget build(BuildContext context) {
    final initial = registration.userName.isNotEmpty
        ? registration.userName.substring(0, 1).toUpperCase()
        : '?';
    final hasPhoto = registration.userPhotoUrl.isNotEmpty;
    final isPaid = registration.isPaid;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryBrown.withValues(alpha: 0.1),
                  image: hasPhoto
                      ? DecorationImage(
                          image: NetworkImage(registration.userPhotoUrl),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: hasPhoto
                    ? null
                    : Center(
                        child: Text(
                          initial,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primaryBrown,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  registration.userName.isNotEmpty
                      ? registration.userName
                      : 'Gospel Vox user',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ),
              if (showRating && registration.hasRated) ...[
                AppIcon(
                  AppIcons.starFilled,
                  size: 14,
                  color: AppColors.amberGold,
                ),
                const SizedBox(width: 3),
                Text(
                  "${registration.rating}",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ] else if (isPaid) ...[
                const AppIcon(
                  AppIcons.checkCircle,
                  size: 14,
                  color: _kCompletedGreen,
                ),
                const SizedBox(width: 4),
                Text(
                  "Paid",
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _kCompletedGreen,
                  ),
                ),
              ] else
                Text(
                  "Registered",
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
            ],
          ),
          if (showRating &&
              registration.feedback != null &&
              registration.feedback!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 48),
              child: Text(
                '"${registration.feedback!.trim()}"',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  fontStyle: FontStyle.italic,
                  color: AppColors.muted,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// START MEETING CONFIRMATION SHEET (5-checkbox heavy confirmation)
// ════════════════════════════════════════════════════════════════
//
// Modal sheet that cannot be dismissed by tapping outside or
// swiping down. Five distinct checkboxes — the priest must tick all
// before the Start button enables. Each checkbox row is a single
// GestureDetector so the entire row (not just the box) toggles.

class _StartMeetingConfirmationSheet extends StatefulWidget {
  final int registeredCount;
  final int price;
  final int durationMinutes;

  const _StartMeetingConfirmationSheet({
    required this.registeredCount,
    required this.price,
    required this.durationMinutes,
  });

  @override
  State<_StartMeetingConfirmationSheet> createState() =>
      _StartMeetingConfirmationSheetState();
}

class _StartMeetingConfirmationSheetState
    extends State<_StartMeetingConfirmationSheet> {
  final _checked = List<bool>.filled(5, false);
  bool _submitting = false;

  bool get _allChecked => _checked.every((c) => c);

  void _toggle(int i) {
    if (_submitting) return;
    setState(() => _checked[i] = !_checked[i]);
  }

  Future<void> _onStart() async {
    if (!_allChecked || _submitting) return;
    setState(() => _submitting = true);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final items = <String>[
      "All ${widget.registeredCount} registered "
          "${widget.registeredCount == 1 ? 'user' : 'users'} will get "
          "a call-style notification to join immediately.",
      "Users pay ₹${widget.price} to access the meeting link. "
          "This payment is final and non-refundable.",
      "I commit to running this session for the full duration "
          "(${widget.durationMinutes} minutes). Ending early will be "
          "reported to admin.",
      "Repeated violations (early termination, fake sessions) may "
          "result in account suspension and monetisation being "
          "stopped.",
      "Once started, this session can only end by completion — it "
          "cannot be cancelled.",
    ];

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
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
              const SizedBox(height: 16),
              Row(
                children: [
                  AppIcon(
                    AppIcons.warning,
                    size: 22,
                    color: AppColors.amberGold,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    "Before You Start",
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                "Please read and acknowledge each point carefully.",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              for (int i = 0; i < items.length; i++) ...[
                _CheckRow(
                  checked: _checked[i],
                  text: items[i],
                  onTap: () => _toggle(i),
                ),
                if (i < items.length - 1) const SizedBox(height: 12),
              ],
              const SizedBox(height: 24),
              _PressableButton(
                onTap: (_allChecked && !_submitting) ? _onStart : null,
                child: Container(
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _allChecked
                        ? AppColors.primaryBrown
                        : AppColors.muted.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: _allChecked
                        ? [
                            BoxShadow(
                              color: AppColors.primaryBrown
                                  .withValues(alpha: 0.25),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : const [],
                  ),
                  child: Center(
                    child: _submitting
                        ? const SizedBox(
                            width: 35,
                            height: 35,
                            child: AppLoader(),
                          )
                        : Text(
                            "Start Meeting",
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _allChecked
                                  ? Colors.white
                                  : AppColors.muted,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: GestureDetector(
                  onTap: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    child: Text(
                      "Cancel",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: MediaQuery.of(context).padding.bottom + 8,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final bool checked;
  final String text;
  final VoidCallback onTap;
  const _CheckRow({
    required this.checked,
    required this.text,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: checked
                  ? AppColors.amberGold
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: checked
                    ? AppColors.amberGold
                    : AppColors.muted.withValues(alpha: 0.4),
                width: 1.6,
              ),
            ),
            child: checked
                ? const AppIcon(
                    AppIcons.check,
                    size: 15,
                    color: Colors.white,
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: checked
                    ? AppColors.deepDarkBrown.withValues(alpha: 0.6)
                    : AppColors.deepDarkBrown,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// PRIMARY + OUTLINED ACTION BUTTONS
// ════════════════════════════════════════════════════════════════

class _PrimaryActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  // Surfaced as a tooltip-style hint below the button when disabled.
  // Drives the "Add the meeting link first" / "Available in X min"
  // copy without forcing the caller to render its own helper text.
  final String? disabledHint;

  const _PrimaryActionButton({
    required this.label,
    required this.onTap,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PressableButton(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: disabled
                  ? AppColors.muted.withValues(alpha: 0.22)
                  : AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(14),
              boxShadow: disabled
                  ? const []
                  : [
                      BoxShadow(
                        color: AppColors.primaryBrown
                            .withValues(alpha: 0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
            ),
            child: Center(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: disabled
                      ? AppColors.muted
                      : Colors.white,
                ),
              ),
            ),
          ),
        ),
        if (disabled && disabledHint != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              AppIcon(
                AppIcons.info,
                size: 13,
                color: AppColors.muted.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  disabledHint!,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _OutlinedActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _OutlinedActionButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return _PressableButton(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: disabled ? color.withValues(alpha: 0.3) : color,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: disabled ? color.withValues(alpha: 0.5) : color,
            ),
          ),
        ),
      ),
    );
  }
}

class _PressableButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _PressableButton({required this.child, required this.onTap});

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return GestureDetector(
      onTapDown: disabled ? null : (_) => setState(() => _scale = 0.97),
      onTapUp: disabled ? null : (_) => setState(() => _scale = 1.0),
      onTapCancel: disabled ? null : () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// ADD/EDIT LINK BOTTOM SHEET
// ════════════════════════════════════════════════════════════════

// One labelled line (Meeting ID / Passcode) with a tap-to-copy
// button. Shown under the link in the priest's manage view.
class _MeetExtraLine extends StatelessWidget {
  final String label;
  final String value;
  const _MeetExtraLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Text(
            "$label: ",
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              AppSnackBar.success(context, "$label copied");
            },
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: AppIcon(
                AppIcons.paste,
                size: 14,
                color: AppColors.primaryBrown,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Forgiving normaliser. Accepts ANY https URL — Google Meet, Zoom, a
// custom/corporate Zoom domain, anything — because requiring an exact
// host wrongly rejects perfectly valid links (e.g. mychurch.zoom.us).
// We only:
//   • strip whitespace and prepend https:// when the scheme is missing
//     (the #1 cause of "couldn't join" complaints), and
//   • reject genuinely unusable input (no host at all).
// A host that doesn't match the chosen platform is ALLOWED but flagged
// with a soft `warning` so the priest can double-check — never blocked.
_LinkNormResult _normaliseMeetingLink(String raw, MeetingPlatform platform) {
  // Strip ALL whitespace, not just edges — mobile keyboards sometimes
  // sneak a trailing space and copy buffers occasionally include line
  // breaks from web sources.
  var s = raw.replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty) return const _LinkNormResult.empty();

  // Force https (and add it when missing) so a bare host like
  // `zoom.us/j/123` becomes a parseable URL.
  if (s.toLowerCase().startsWith('http://')) {
    s = 'https://${s.substring(7)}';
  } else if (!s.toLowerCase().startsWith('https://')) {
    s = 'https://$s';
  }

  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) {
    return const _LinkNormResult.error(
      "That doesn't look like a valid link.",
    );
  }

  // Forgiving: accept as-is. Flag a soft mismatch warning only.
  final warning = platform.matchesUrl(s)
      ? null
      : "Doesn't look like a ${platform.label} link — double-check it.";
  return _LinkNormResult.ok(s, warning: warning);
}

class _LinkNormResult {
  final String? url;
  final String? error;
  // Soft, non-blocking hint (e.g. "doesn't look like a Zoom link").
  // Present alongside a valid `url` — the link still saves.
  final String? warning;
  final bool isEmpty;
  const _LinkNormResult._(
      {this.url, this.error, this.warning, this.isEmpty = false});
  const _LinkNormResult.empty() : this._(isEmpty: true);
  const _LinkNormResult.ok(String u, {String? warning})
      : this._(url: u, warning: warning);
  const _LinkNormResult.error(String e) : this._(error: e);
  bool get isValid => url != null;
}

class _AddLinkSheet extends StatefulWidget {
  final String initialLink;
  final String initialPlatform;
  final String initialMeetingId;
  final String initialPasscode;
  const _AddLinkSheet({
    required this.initialLink,
    required this.initialPlatform,
    required this.initialMeetingId,
    required this.initialPasscode,
  });

  @override
  State<_AddLinkSheet> createState() => _AddLinkSheetState();
}

class _AddLinkSheetState extends State<_AddLinkSheet> {
  late final TextEditingController _ctrl;
  late final TextEditingController _idCtrl;
  late final TextEditingController _passcodeCtrl;
  late MeetingPlatform _platform;
  _LinkNormResult _result = const _LinkNormResult.empty();
  bool _canPaste = false;

  @override
  void initState() {
    super.initState();
    _platform = MeetingPlatform.fromId(widget.initialPlatform);
    _ctrl = TextEditingController(text: widget.initialLink);
    _idCtrl = TextEditingController(text: widget.initialMeetingId);
    _passcodeCtrl = TextEditingController(text: widget.initialPasscode);
    _ctrl.addListener(_onChanged);
    _idCtrl.addListener(_onExtrasChanged);
    _passcodeCtrl.addListener(_onExtrasChanged);
    _onChanged();
    _refreshClipboardState();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    _idCtrl.removeListener(_onExtrasChanged);
    _idCtrl.dispose();
    _passcodeCtrl.removeListener(_onExtrasChanged);
    _passcodeCtrl.dispose();
    super.dispose();
  }

  // The ID/passcode fields don't affect link validation, but they do
  // affect _canSave (a changed passcode is a saveable change), so a
  // keystroke needs to refresh the Save button's enabled state.
  void _onExtrasChanged() => setState(() {});

  void _onChanged() {
    final next = _normaliseMeetingLink(_ctrl.text, _platform);
    if (next.url != _result.url ||
        next.error != _result.error ||
        next.warning != _result.warning ||
        next.isEmpty != _result.isEmpty) {
      setState(() => _result = next);
    }
  }

  void _selectPlatform(MeetingPlatform p) {
    if (p.id == _platform.id) return;
    setState(() => _platform = p);
    // Re-validate so the soft mismatch warning reflects the new choice.
    _onChanged();
  }

  Future<void> _refreshClipboardState() async {
    // Only enable the Paste button if there's actually text on the
    // clipboard — avoids a dead-feeling button on a fresh boot.
    final has = await Clipboard.hasStrings();
    if (mounted) setState(() => _canPaste = has);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _ctrl.text = text;
    _ctrl.selection =
        TextSelection.collapsed(offset: _ctrl.text.length);
  }

  void _clear() {
    _ctrl.clear();
  }

  // Save is a no-op if nothing has actually changed — prevents an
  // unnecessary Firestore write + a misleading "Link cleared." toast
  // when the priest opens the sheet, looks at it, and taps Save.
  bool get _hasChanges {
    final current = _result.isValid ? _result.url! : _ctrl.text.trim();
    final extrasChanged = _platform.usesAccessCodes &&
        (_idCtrl.text.trim() != widget.initialMeetingId.trim() ||
            _passcodeCtrl.text.trim() != widget.initialPasscode.trim());
    return current != widget.initialLink ||
        _platform.id != widget.initialPlatform ||
        extrasChanged;
  }

  bool get _canSave {
    if (_result.isEmpty) {
      // Empty input — only allow saving if there's something to clear.
      return widget.initialLink.isNotEmpty;
    }
    return _result.isValid && _hasChanges;
  }

  void _save() {
    if (!_canSave) return;
    final value = _result.isValid ? _result.url! : '';
    final useCodes = _platform.usesAccessCodes;
    Navigator.of(context).pop((
      link: value,
      platformId: _platform.id,
      meetingId: useCodes ? _idCtrl.text.trim() : '',
      passcode: useCodes ? _passcodeCtrl.text.trim() : '',
    ));
  }

  // Compact labelled text field for the optional Zoom extras (Meeting
  // ID / Passcode). Same beige fill as the link field so the sheet
  // reads as one coherent form.
  Widget _extrasField({
    required String label,
    required TextEditingController controller,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.deepDarkBrown,
          ),
          cursorColor: AppColors.primaryBrown,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.6),
            ),
            filled: true,
            fillColor: AppColors.warmBeige.withValues(alpha: 0.5),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.muted.withValues(alpha: 0.15),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppColors.primaryBrown,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
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
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    widget.initialLink.isEmpty
                        ? "Add Meeting Link"
                        : "Edit Meeting Link",
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ),
                _PasteChip(
                  enabled: _canPaste,
                  onTap: () async {
                    await _pasteFromClipboard();
                    await _refreshClipboardState();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              "Paste your ${_platform.label} link below. You can skip "
              "the https:// — we'll add it for you. Users see the link "
              "as soon as they pay to join the live session.",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            MeetingPlatformSelector(
              selected: _platform,
              onChanged: _selectPlatform,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
              cursorColor: AppColors.primaryBrown,
              decoration: InputDecoration(
                hintText: _platform.placeholder,
                hintStyle: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: "Clear",
                        icon: AppIcon(
                          AppIcons.cancel,
                          size: 18,
                          color:
                              AppColors.muted.withValues(alpha: 0.7),
                        ),
                        onPressed: _clear,
                      ),
                filled: true,
                fillColor: AppColors.warmBeige.withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: _result.error != null
                        ? AppColors.errorRed.withValues(alpha: 0.4)
                        : AppColors.muted.withValues(alpha: 0.15),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: _result.error != null
                        ? AppColors.errorRed
                        : AppColors.primaryBrown,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _LinkStatusRow(result: _result),
            if (_platform.usesAccessCodes) ...[
              const SizedBox(height: 18),
              _extrasField(
                label: "Meeting ID (optional)",
                controller: _idCtrl,
                hint: "e.g. 123 4567 8901",
              ),
              const SizedBox(height: 14),
              _extrasField(
                label: "Passcode (optional)",
                controller: _passcodeCtrl,
                hint: "Only if your link doesn't include it",
              ),
            ],
            const SizedBox(height: 20),
            Opacity(
              opacity: _canSave ? 1.0 : 0.5,
              child: _PressableButton(
                onTap: _canSave ? _save : null,
                child: Container(
                  width: double.infinity,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.amberGold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      _result.isEmpty && widget.initialLink.isNotEmpty
                          ? "Clear Link"
                          : "Save Link",
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
            SizedBox(
              height: MediaQuery.of(context).padding.bottom + 8,
            ),
          ],
        ),
      ),
    );
  }
}

// Small pill button that sits next to the title and pastes the
// clipboard into the field in one tap. Disabled (greyed) when the
// clipboard has no text so it doesn't feel dead on first open.
class _PasteChip extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _PasteChip({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = enabled
        ? AppColors.primaryBrown
        : AppColors.muted.withValues(alpha: 0.5);
    final bg = enabled
        ? AppColors.primaryBrown.withValues(alpha: 0.08)
        : AppColors.muted.withValues(alpha: 0.08);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(AppIcons.paste, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              "Paste",
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Live status row that sits under the text field. Three states:
//   • empty   → faint hint that explains what we accept
//   • valid   → green check + canonical preview of what will be saved
//   • invalid → red icon + a specific reason
// Animated so the height/colour change doesn't snap.
class _LinkStatusRow extends StatelessWidget {
  final _LinkNormResult result;
  const _LinkStatusRow({required this.result});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    final String text;

    if (result.isEmpty) {
      color = AppColors.muted;
      icon = AppIcons.lightbulb;
      text = "Tip: paste your meeting link — we'll handle the rest.";
    } else if (result.isValid && result.warning != null) {
      // Valid + saveable, but the host doesn't match the chosen
      // platform — a soft amber nudge, NOT a blocker.
      color = AppColors.amberGold;
      icon = AppIcons.info;
      text = result.warning!;
    } else if (result.isValid) {
      color = AppColors.successGreen;
      icon = AppIcons.checkCircle;
      text = "Will be saved as: ${result.url!}";
    } else {
      color = AppColors.errorRed;
      icon = AppIcons.error;
      text = result.error ?? "Invalid link.";
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: child,
      ),
      child: Row(
        key: ValueKey(text),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// CANCEL SESSION SHEET
// ════════════════════════════════════════════════════════════════

class _CancelSessionSheet extends StatelessWidget {
  final int paidCount;
  final int registeredOnlyCount;
  const _CancelSessionSheet({
    required this.paidCount,
    required this.registeredOnlyCount,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          24,
          12,
          24,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "Cancel this session?",
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              registeredOnlyCount > 0
                  ? "$registeredOnlyCount registered "
                      "${registeredOnlyCount == 1 ? 'user' : 'users'} "
                      "will be notified. Repeated cancellations may "
                      "affect your account."
                  : "Repeated cancellations may affect your account.",
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
            if (paidCount > 0) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.amberGold.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.amberGold.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(
                      AppIcons.warning,
                      size: 16,
                      color: AppColors.amberGold,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "$paidCount "
                        "${paidCount == 1 ? 'user has' : 'users have'} "
                        "already paid. Admin will process refunds for them.",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color:
                              AppColors.amberGold.withValues(alpha: 0.95),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            _PressableButton(
              onTap: () => Navigator.of(context).pop(true),
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.errorRed,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    "Yes, cancel session",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(false),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                height: 44,
                alignment: Alignment.center,
                child: Text(
                  "Keep session",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// GENERIC CONFIRM SHEET (used by mark-completed)
// ════════════════════════════════════════════════════════════════

class _ConfirmSheet extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;

  const _ConfirmSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          24,
          12,
          24,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
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
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            _PressableButton(
              onTap: () => Navigator.of(context).pop(true),
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    confirmLabel,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(false),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                height: 44,
                alignment: Alignment.center,
                child: Text(
                  cancelLabel,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// MEET LINK GUIDE SHEET
// ════════════════════════════════════════════════════════════════

class _MeetLinkGuideSheet extends StatelessWidget {
  final MeetingPlatform platform;
  const _MeetLinkGuideSheet({required this.platform});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
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
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color:
                        const Color(0xFF3B82F6).withValues(alpha: 0.08),
                  ),
                  child: const AppIcon(
                    AppIcons.video,
                    size: 22,
                    color: Color(0xFF3B82F6),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        platform.guideTitle,
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "It takes less than a minute!",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            for (var i = 0; i < platform.guideSteps.length; i++) ...[
              if (i > 0) const SizedBox(height: 16),
              _GuideStep(
                number: i + 1,
                title: platform.guideSteps[i].title,
                description: platform.guideSteps[i].description,
              ),
            ],
            const SizedBox(height: 20),
            _PressableButton(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    "Got it!",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: MediaQuery.of(context).padding.bottom + 12,
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  final int number;
  final String title;
  final String description;

  const _GuideStep({
    required this.number,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryBrown.withValues(alpha: 0.08),
          ),
          child: Center(
            child: Text(
              "$number",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryBrown,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Date / time formatters ─────────────────────────────────────

const _kMonthNames = [
  '',
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _formatFullDate(DateTime d) {
  return '${_kMonthNames[d.month]} ${d.day}, ${d.year}';
}

String _formatTimeFromDate(DateTime d) {
  final hour = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
  final period = d.hour >= 12 ? 'PM' : 'AM';
  return '$hour:${d.minute.toString().padLeft(2, '0')} $period';
}
