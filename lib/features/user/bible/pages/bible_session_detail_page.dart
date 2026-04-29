// User-side Bible session detail. Drives the whole register → pay →
// join lifecycle. The page owns its own RazorpayService instance
// (matches the wallet-page pattern: init in initState, dispose in
// dispose) because Razorpay's listener registry is per-instance and
// reusing a singleton would leak the previous page's BuildContext.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/services/razorpay_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';

// Forest green used throughout the user side for "joined / paid"
// states. Brighter than AppColors.success but still warm enough to
// sit on the beige scaffold.
const Color _kJoinedGreen = Color(0xFF2E7D4F);

class BibleSessionDetailPage extends StatefulWidget {
  final String sessionId;
  const BibleSessionDetailPage({super.key, required this.sessionId});

  @override
  State<BibleSessionDetailPage> createState() =>
      _BibleSessionDetailPageState();
}

class _BibleSessionDetailPageState extends State<BibleSessionDetailPage> {
  final BibleSessionRepository _repository = BibleSessionRepository();
  late final RazorpayService _razorpayService;

  BibleSessionModel? _session;
  BibleRegistration? _registration;

  bool _isLoading = true;
  bool _isRegistering = false;
  bool _isPaying = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _razorpayService = RazorpayService();
    _razorpayService.init();
    _razorpayService.onSuccess = _onPaymentSuccess;
    _razorpayService.onFailure = _onPaymentFailure;
    _load();
  }

  @override
  void dispose() {
    _razorpayService.dispose();
    super.dispose();
  }

  // ── Data load ──────────────────────────────────────────────────

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = "You're signed out. Please sign in again.";
      });
      return;
    }

    try {
      final session = await _repository.getSession(widget.sessionId);
      if (session == null) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _loadError = "Session not found.";
        });
        return;
      }

      final reg = await _repository.getRegistration(
        widget.sessionId,
        uid,
      );

      if (!mounted) return;
      setState(() {
        _session = session;
        // A previously cancelled registration is treated as "not
        // registered" — the UI flow lets them re-register cleanly.
        _registration = (reg != null && reg.isCancelled) ? null : reg;
        _isLoading = false;
        _loadError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = "Couldn't load session. Pull to retry.";
      });
    }
  }

  Future<void> _refreshRegistrationOnly() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final reg = await _repository.getRegistration(
        widget.sessionId,
        uid,
      );
      if (!mounted) return;
      setState(() {
        _registration = (reg != null && reg.isCancelled) ? null : reg;
      });
    } catch (_) {
      // Soft-fail: the next manual refresh will pick it up.
    }
  }

  // ── Actions ────────────────────────────────────────────────────

  Future<void> _register() async {
    final session = _session;
    if (session == null || _isRegistering) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      AppSnackBar.error(
        context,
        "You're signed out. Please sign in again.",
      );
      return;
    }

    setState(() => _isRegistering = true);
    try {
      await _repository.registerForSession(
        sessionId: widget.sessionId,
        userId: user.uid,
        userName: user.displayName ?? 'Gospel Vox user',
        userPhotoUrl: user.photoURL ?? '',
      );

      if (!mounted) return;
      // Re-load to pick up the new registration + any registrationCount
      // bump that did go through.
      await _load();
      if (!mounted) return;
      AppSnackBar.success(context, "You're registered!");
    } on FirebaseException catch (e) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        e.code == 'permission-denied'
            ? "You can't register for this session."
            : "Couldn't register. Please try again.",
      );
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        "Couldn't register. Please try again.",
      );
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  Future<void> _cancelRegistration() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final confirmed = await _showCancelRegistrationSheet();
    if (!mounted || confirmed != true) return;

    try {
      await _repository.cancelRegistration(
        sessionId: widget.sessionId,
        userId: user.uid,
      );
      if (!mounted) return;
      setState(() => _registration = null);
      await _load();
      if (!mounted) return;
      AppSnackBar.info(
        context,
        "No worries! You can always register for other sessions.",
      );
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        "Couldn't cancel. Please try again.",
      );
    }
  }

  Future<bool?> _showCancelRegistrationSheet() {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _ConfirmSheet(
        title: "Cancel registration?",
        message:
            "You'll be removed from this session's attendee list. "
            "You can register again later if there's still room.",
        confirmLabel: "Yes, cancel",
        cancelLabel: "Stay registered",
        destructive: true,
      ),
    );
  }

  void _payAndJoin() {
    final session = _session;
    if (session == null || _isPaying) return;
    if (!session.hasLink) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      AppSnackBar.error(
        context,
        "You're signed out. Please sign in again.",
      );
      return;
    }

    setState(() => _isPaying = true);

    _razorpayService.openCheckoutWithoutOrder(
      amountInPaise: session.price * 100,
      description: 'Bible Session — ${session.title}',
      userEmail: user.email ?? '',
      userName: user.displayName ?? '',
      // Notes flow back to Razorpay's dashboard so support can trace
      // a payment to a specific session without joining tables.
      notes: <String, String>{
        'sessionId': widget.sessionId,
        'uid': user.uid,
      },
    );
  }

  Future<void> _onPaymentSuccess(PaymentSuccessResponse response) async {
    final paymentId = response.paymentId;
    final session = _session;
    if (paymentId == null || session == null) {
      if (mounted) {
        setState(() => _isPaying = false);
        AppSnackBar.error(
          context,
          "Payment captured but verification failed. "
          "Contact support with paymentId if coins aren't credited.",
        );
      }
      return;
    }

    try {
      await _repository.verifyPayment(
        sessionId: widget.sessionId,
        paymentId: paymentId,
        amount: session.price,
      );
      if (!mounted) return;
      // CF flipped the registration to paid. Re-read it so the link
      // section unlocks.
      await _refreshRegistrationOnly();
      if (!mounted) return;
      setState(() => _isPaying = false);
      AppSnackBar.success(
        context,
        "Payment confirmed. The meeting link is now available.",
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _isPaying = false);
      AppSnackBar.error(
        context,
        // Surface the CF's message verbatim — it's already user-
        // facing ("Order not paid", "Amount mismatch", etc.) and
        // gives support something to grep.
        e.message ?? "Payment verification failed. Contact support.",
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isPaying = false);
      AppSnackBar.error(
        context,
        "Couldn't verify payment. Contact support if amount was deducted.",
      );
    }
  }

  void _onPaymentFailure(PaymentFailureResponse response) {
    if (!mounted) {
      _isPaying = false;
      return;
    }
    setState(() => _isPaying = false);
    // Code 2 = user dismissed the sheet — not a failure.
    if (response.code == 2) return;
    AppSnackBar.error(
      context,
      "Payment failed. Please try again.",
    );
  }

  Future<void> _openMeetingLink() async {
    final link = _session?.meetingLink ?? '';
    if (link.isEmpty) return;
    final uri = Uri.tryParse(link);
    if (uri == null) {
      if (mounted) {
        AppSnackBar.error(context, "This meeting link looks invalid.");
      }
      return;
    }
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        AppSnackBar.error(
          context,
          "Couldn't open the meeting link. Try copying it manually.",
        );
      }
    } catch (_) {
      if (mounted) {
        AppSnackBar.error(
          context,
          "Couldn't open the meeting link.",
        );
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.deepDarkBrown,
        title: Text(
          "Bible Session",
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
    );
  }

  Widget _buildBody() {
    if (_isLoading) return _buildLoading();
    if (_loadError != null) return _buildError(_loadError!);
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
            height: 80,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Shimmer.fromColors(
          baseColor: base,
          highlightColor: highlight,
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
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
    final reg = _registration;
    final isPaid = reg?.isPaid ?? false;
    final showLinkSection = isPaid && session.hasLink;

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
          _PriestInfoCard(session: session),
          if (showLinkSection) ...[
            const SizedBox(height: 16),
            _MeetLinkCard(
              session: session,
              onOpen: _openMeetingLink,
            ),
          ],
          ..._buildReminderBanners(session, isPaid),
          const SizedBox(height: 20),
          _ActionArea(
            session: session,
            registration: reg,
            isRegistering: _isRegistering,
            isPaying: _isPaying,
            onRegister: _register,
            onCancelRegistration: _cancelRegistration,
            onPayAndJoin: _payAndJoin,
          ),
          if (session.isCancelled) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.errorRed.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.errorRed.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.cancel_outlined,
                    size: 18,
                    color: AppColors.errorRed,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "This session has been cancelled by the speaker.",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppColors.errorRed,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Client-side reminder banners (per spec — V1 does not schedule
  // CF-side push reminders). Hidden once paid because we already
  // surface the link card above; doubling up reads as nagging.
  List<Widget> _buildReminderBanners(
    BibleSessionModel session,
    bool isPaid,
  ) {
    if (!session.isUpcoming || session.isCancelled) return const [];
    if (isPaid) return const [];

    if (session.minutesUntil > 0 && session.minutesUntil <= 60) {
      return [
        const SizedBox(height: 12),
        _ReminderBanner(
          icon: Icons.access_time_rounded,
          color: AppColors.amberGold,
          text:
              "Session starts in ${session.minutesUntil} minutes!",
        ),
      ];
    }
    if (session.hoursUntil > 0 && session.hoursUntil <= 24) {
      return [
        const SizedBox(height: 12),
        _ReminderBanner(
          icon: Icons.calendar_today_outlined,
          color: AppColors.primaryBrown,
          text: "Session is tomorrow — don't forget!",
        ),
      ];
    }
    return const [];
  }
}

// ─── Session info card ──────────────────────────────────────────

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
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.people_outline_rounded,
                size: 14,
                color: AppColors.muted.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  session.maxParticipants > 0
                      ? "${session.registrationCount} / "
                          "${session.maxParticipants} registered"
                      : "${session.registrationCount} registered",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
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

// ─── Priest info card ───────────────────────────────────────────

class _PriestInfoCard extends StatelessWidget {
  final BibleSessionModel session;
  const _PriestInfoCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final initial = session.priestName.isNotEmpty
        ? session.priestName.substring(0, 1).toUpperCase()
        : '?';
    final hasPhoto = session.priestPhotoUrl.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primaryBrown.withValues(alpha: 0.1),
              image: hasPhoto
                  ? DecorationImage(
                      image: NetworkImage(session.priestPhotoUrl),
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
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryBrown,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.priestName.isNotEmpty
                      ? session.priestName
                      : 'Speaker',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "Speaker",
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
    );
  }
}

// ─── Meet link card ─────────────────────────────────────────────

class _MeetLinkCard extends StatelessWidget {
  final BibleSessionModel session;
  final VoidCallback onOpen;

  const _MeetLinkCard({
    required this.session,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kJoinedGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _kJoinedGreen.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.videocam_rounded,
                size: 18,
                color: _kJoinedGreen,
              ),
              const SizedBox(width: 10),
              Text(
                "Meeting Link",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _kJoinedGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _PressableButton(
            onTap: onOpen,
            child: Container(
              width: double.infinity,
              height: 44,
              decoration: BoxDecoration(
                color: _kJoinedGreen,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  "Open Meeting Link",
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
      ),
    );
  }
}

// ─── Reminder banner ────────────────────────────────────────────

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

// ─── Action area ────────────────────────────────────────────────

class _ActionArea extends StatelessWidget {
  final BibleSessionModel session;
  final BibleRegistration? registration;
  final bool isRegistering;
  final bool isPaying;
  final VoidCallback onRegister;
  final VoidCallback onCancelRegistration;
  final VoidCallback onPayAndJoin;

  const _ActionArea({
    required this.session,
    required this.registration,
    required this.isRegistering,
    required this.isPaying,
    required this.onRegister,
    required this.onCancelRegistration,
    required this.onPayAndJoin,
  });

  @override
  Widget build(BuildContext context) {
    // Cancelled / completed: no action available, the cancellation
    // banner below already explains the state.
    if (session.isCancelled || session.isCompleted) {
      return const SizedBox.shrink();
    }

    final reg = registration;

    // State 1 — full and not registered.
    if (reg == null && session.isFull) {
      return _DisabledButton(label: "Session Full");
    }

    // State 2 — not registered yet.
    if (reg == null) {
      return _PrimaryButton(
        label: "Register for Free",
        loading: isRegistering,
        onTap: onRegister,
      );
    }

    // State 6 — already paid.
    if (reg.isPaid) {
      return Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: _kJoinedGreen.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kJoinedGreen.withValues(alpha: 0.2)),
        ),
        child: Center(
          child: Text(
            session.hasLink
                ? "Joined ✓ — Scroll up for link"
                : "Joined ✓ — Link will appear when ready",
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _kJoinedGreen,
            ),
          ),
        ),
      );
    }

    // States 3-5 — registered, not paid.
    if (!session.isJoinWindowOpen) {
      // State 3 — too early to pay.
      return Column(
        children: [
          Container(
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: _kJoinedGreen.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _kJoinedGreen.withValues(alpha: 0.2),
              ),
            ),
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: _kJoinedGreen,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Registered ✓",
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _kJoinedGreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Join button activates 15 min before session",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onCancelRegistration,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                "Cancel Registration",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                  decoration: TextDecoration.underline,
                  decorationColor:
                      AppColors.muted.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // State 4 — join window open but priest hasn't added link.
    if (!session.hasLink) {
      return _DisabledButton(
        label: "Waiting for speaker to add meeting link",
      );
    }

    // State 5 — join window open, link present → "Join & Pay".
    return _PressableButton(
      onTap: isPaying ? null : onPayAndJoin,
      child: Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: _kJoinedGreen,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: _kJoinedGreen.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Center(
          child: isPaying
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Text(
                  "Join Session — Pay ₹${session.price}",
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

// ─── Reusable buttons ───────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback onTap;

  const _PrimaryButton({
    required this.label,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressableButton(
      onTap: loading ? null : onTap,
      child: Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.primaryBrown,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryBrown.withValues(alpha: 0.2),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

class _DisabledButton extends StatelessWidget {
  final String label;
  const _DisabledButton({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 52,
      decoration: BoxDecoration(
        color: AppColors.muted.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
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

// ─── Confirm bottom sheet (used by cancel-registration flow) ────

class _ConfirmSheet extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  const _ConfirmSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  @override
  Widget build(BuildContext context) {
    final accent =
        destructive ? AppColors.errorRed : AppColors.primaryBrown;
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(24),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          24,
          16,
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
                  color: accent,
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
