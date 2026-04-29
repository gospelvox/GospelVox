// Priest-side detail page for a Bible session they own. Mirrors
// the user-side detail page in look-and-feel but swaps the action
// area for management tools — add/edit Meet link, view attendees,
// cancel the session, mark complete after it's run.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';

class PriestBibleDetailPage extends StatefulWidget {
  final String sessionId;
  const PriestBibleDetailPage({super.key, required this.sessionId});

  @override
  State<PriestBibleDetailPage> createState() =>
      _PriestBibleDetailPageState();
}

class _PriestBibleDetailPageState extends State<PriestBibleDetailPage> {
  final BibleSessionRepository _repository = BibleSessionRepository();

  BibleSessionModel? _session;
  List<BibleRegistration> _registrations = const [];
  bool _isLoading = true;
  bool _isMutating = false;
  // Tracks if any priest-side mutation happened that should bubble
  // up to the list page (cancel, complete, add link). Returned as
  // pop() result so the list reloads only when needed.
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final session = await _repository.getSession(widget.sessionId);
      if (session == null) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _error = "Session not found.";
        });
        return;
      }
      // Fetch registrations independently — a permission error here
      // shouldn't block the rest of the page from rendering.
      List<BibleRegistration> regs = const [];
      try {
        regs = await _repository.getRegistrations(widget.sessionId);
      } catch (_) {
        regs = const [];
      }
      if (!mounted) return;
      setState(() {
        _session = session;
        _registrations = regs;
        _isLoading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = "Couldn't load session. Pull to retry.";
      });
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

  Future<void> _showAddLinkSheet() async {
    final session = _session;
    if (session == null) return;
    final updated = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _AddLinkSheet(initialLink: session.meetingLink),
    );
    if (!mounted || updated == null) return;
    await _runMutation(() async {
      try {
        await _repository.updateMeetingLink(widget.sessionId, updated);
        if (!mounted) return;
        _changed = true;
        await _load();
        if (!mounted) return;
        AppSnackBar.success(
          context,
          updated.isEmpty
              ? "Link cleared."
              : "Meet link saved — registered users will see it.",
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

  Future<void> _confirmCancel() async {
    final session = _session;
    if (session == null) return;
    final paidCount = _registrations.where((r) => r.isPaid).length;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CancelSessionSheet(paidCount: paidCount),
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
        await _load();
        if (!mounted) return;
        AppSnackBar.info(
          context,
          notified > 0
              ? 'Session cancelled. $notified registered '
                  '${notified == 1 ? "user has" : "users have"} '
                  'been notified.'
              : 'Session cancelled.',
        );
      } catch (_) {
        if (!mounted) return;
        AppSnackBar.error(
          context,
          "Couldn't cancel. Please try again.",
        );
      }
    });
  }

  Future<void> _confirmComplete() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ConfirmSheet(
        title: "Mark as completed?",
        message:
            "Use this once the session has finished. It'll move to "
            "your past sessions and stop accepting new registrations.",
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
        await _load();
        if (!mounted) return;
        AppSnackBar.success(context, "Session marked as completed.");
      } catch (_) {
        if (!mounted) return;
        AppSnackBar.error(
          context,
          "Couldn't update. Please try again.",
        );
      }
    });
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        // No-op; the actual return value is supplied via pop(_changed).
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          foregroundColor: AppColors.deepDarkBrown,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_changed),
          ),
          title: Text(
            "Manage Session",
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
        body: RefreshIndicator(
          color: AppColors.primaryBrown,
          backgroundColor: AppColors.surfaceWhite,
          onRefresh: _load,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return _buildLoading();
    if (_error != null) return _buildError(_error!);
    final session = _session;
    if (session == null) return _buildError("Session unavailable.");
    return _buildLoaded(session);
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
        Icon(
          Icons.error_outline_rounded,
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
    final warning = session.linkWarning;
    final canComplete =
        session.isUpcoming && session.isInPast;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PriestSessionInfoCard(session: session),
          if (warning != null) ...[
            const SizedBox(height: 12),
            _ReminderBanner(
              icon: Icons.warning_amber_rounded,
              color: AppColors.amberGold,
              text: warning,
            ),
          ],
          const SizedBox(height: 16),
          _MeetLinkSection(
            session: session,
            onTap: _showAddLinkSheet,
            onShowGuide: () => _showLinkGuide(context),
          ),
          const SizedBox(height: 16),
          _AttendeesSection(
            registrations: _registrations,
            maxParticipants: session.maxParticipants,
          ),
          const SizedBox(height: 24),
          if (!session.isCancelled && !session.isCompleted) ...[
            if (canComplete) ...[
              _OutlinedActionButton(
                label: "Mark as Completed",
                color: AppColors.primaryBrown,
                onTap: _isMutating ? null : _confirmComplete,
              ),
              const SizedBox(height: 10),
            ],
            _OutlinedActionButton(
              label: "Cancel Session",
              color: AppColors.errorRed,
              onTap: _isMutating ? null : _confirmCancel,
            ),
          ] else if (session.isCancelled) ...[
            _StatusBanner(
              text: "This session has been cancelled.",
              color: AppColors.errorRed,
              icon: Icons.cancel_outlined,
            ),
          ] else ...[
            _StatusBanner(
              text: "This session is marked as completed.",
              color: const Color(0xFF2E7D4F),
              icon: Icons.check_circle_outline_rounded,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showLinkGuide(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _MeetLinkGuideSheet(),
    );
  }
}

// ─── Priest session info card ───────────────────────────────────

class _PriestSessionInfoCard extends StatelessWidget {
  final BibleSessionModel session;
  const _PriestSessionInfoCard({required this.session});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.06),
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
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              color: AppColors.primaryBrown.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              "BIBLE SESSION",
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryBrown,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            session.title,
            style: GoogleFonts.inter(
              fontSize: 20,
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
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.6,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: Icons.calendar_today_outlined,
                text: session.formattedDate,
              ),
              _InfoChip(
                icon: Icons.access_time_rounded,
                text: session.formattedTime,
              ),
              if (session.category.isNotEmpty)
                _InfoChip(
                  icon: Icons.local_offer_outlined,
                  text: session.category,
                ),
              _InfoChip(
                icon: Icons.currency_rupee_rounded,
                text: '${session.price}',
              ),
            ],
          ),
        ],
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
          Icon(icon, size: 13, color: AppColors.primaryBrown),
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

// ─── Meet link section ──────────────────────────────────────────

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
      padding: const EdgeInsets.all(20),
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
              Icon(
                Icons.videocam_outlined,
                size: 18,
                color: AppColors.muted,
              ),
              const SizedBox(width: 10),
              Text(
                "MEET LINK",
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
                  child: const Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: Color(0xFF3B82F6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
            const SizedBox(height: 12),
            Center(
              child: _PressableButton(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
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
              child: Icon(
                Icons.videocam_off_outlined,
                size: 36,
                color: AppColors.muted.withValues(alpha: 0.2),
              ),
            ),
            const SizedBox(height: 12),
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
                "Add your Google Meet link so registered\nusers receive it before the session.",
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.6),
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: _PressableButton(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: AppColors.primaryBrown,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    "Add Meet Link",
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBrown,
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

// ─── Attendees section ──────────────────────────────────────────

class _AttendeesSection extends StatelessWidget {
  final List<BibleRegistration> registrations;
  final int maxParticipants;

  const _AttendeesSection({
    required this.registrations,
    required this.maxParticipants,
  });

  @override
  Widget build(BuildContext context) {
    final countText = maxParticipants > 0
        ? "${registrations.length} / $maxParticipants"
        : "${registrations.length}";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
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
              Icon(
                Icons.people_outline_rounded,
                size: 18,
                color: AppColors.muted,
              ),
              const SizedBox(width: 10),
              Text(
                "ATTENDEES",
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
                  countText,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryBrown,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (registrations.isEmpty)
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
            ...registrations.map((r) => _AttendeeTile(registration: r)),
        ],
      ),
    );
  }
}

class _AttendeeTile extends StatelessWidget {
  final BibleRegistration registration;
  const _AttendeeTile({required this.registration});

  @override
  Widget build(BuildContext context) {
    final initial = registration.userName.isNotEmpty
        ? registration.userName.substring(0, 1).toUpperCase()
        : '?';
    final hasPhoto = registration.userPhotoUrl.isNotEmpty;
    final isPaid = registration.isPaid;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
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
          if (isPaid) ...[
            const Icon(
              Icons.check_circle_rounded,
              size: 16,
              color: Color(0xFF2E7D4F),
            ),
            const SizedBox(width: 4),
            Text(
              "Paid",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF2E7D4F),
              ),
            ),
          ] else ...[
            Text(
              "Registered",
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

// ─── Reminder banner / status banner ────────────────────────────

class _ReminderBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _ReminderBanner({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;

  const _StatusBanner({
    required this.text,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: color,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Action buttons ─────────────────────────────────────────────

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
            color: disabled
                ? color.withValues(alpha: 0.3)
                : color,
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

class _AddLinkSheet extends StatefulWidget {
  final String initialLink;
  const _AddLinkSheet({required this.initialLink});

  @override
  State<_AddLinkSheet> createState() => _AddLinkSheetState();
}

class _AddLinkSheetState extends State<_AddLinkSheet> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialLink);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final value = _ctrl.text.trim();
    if (value.isNotEmpty) {
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasScheme) {
        setState(() => _error = "Please paste a valid link.");
        return;
      }
    }
    Navigator.of(context).pop(value);
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
            Text(
              widget.initialLink.isEmpty
                  ? "Add Meet Link"
                  : "Edit Meet Link",
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Paste your Google Meet link here. Registered users will "
              "see it once they pay to join.",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              keyboardType: TextInputType.url,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
              cursorColor: AppColors.primaryBrown,
              decoration: InputDecoration(
                hintText: "https://meet.google.com/...",
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
                  borderSide: BorderSide(
                    color: AppColors.primaryBrown,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.errorRed,
                ),
              ),
            ],
            const SizedBox(height: 20),
            _PressableButton(
              onTap: _save,
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    "Save",
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
              height: MediaQuery.of(context).padding.bottom + 8,
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// CANCEL SESSION SHEET (with paid-attendees warning)
// ════════════════════════════════════════════════════════════════

class _CancelSessionSheet extends StatelessWidget {
  final int paidCount;
  const _CancelSessionSheet({required this.paidCount});

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
              "All registered users will be notified. "
              "Repeated cancellations may affect your account.",
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
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: AppColors.amberGold,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "$paidCount ${paidCount == 1 ? 'user has' : 'users have'} "
                        "already paid. Admin will process refunds for them.",
                        style: GoogleFonts.inter(
                          fontSize: 12,
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
// MEET LINK GUIDE SHEET (mirrors the create-sheet's guide so the
// priest can read the same instructions when adding a link from
// the detail page).
// ════════════════════════════════════════════════════════════════

class _MeetLinkGuideSheet extends StatelessWidget {
  const _MeetLinkGuideSheet();

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
                  child: const Icon(
                    Icons.videocam_rounded,
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
                        "How to Create a Meeting Link",
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
            const _GuideStep(
              number: 1,
              title: "Open Google Meet",
              description:
                  "Open the Google Meet app on your phone, or visit "
                  "meet.google.com in your browser.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 2,
              title: "Create a New Meeting",
              description:
                  "Tap the 'New meeting' button or '+' icon.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 3,
              title: "Choose 'Create a meeting for later'",
              description:
                  "This gives you a link without starting the meeting "
                  "right now.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 4,
              title: "Copy the Link",
              description:
                  "You'll see a link like meet.google.com/abc-defg-hij. "
                  "Tap 'Copy' or long-press to copy it.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 5,
              title: "Paste Here",
              description:
                  "Come back to Gospel Vox and paste the link in the "
                  "Meet Link field.",
            ),
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
