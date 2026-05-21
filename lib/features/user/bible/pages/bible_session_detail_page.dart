// User-side Bible session detail. Drives the full new-flow lifecycle:
// register-free → wait → priest goes live → pay-at-join → open meet
// → rate after completion (or report).
//
// Session state is watched via `repository.watchSession` so the page
// reacts the instant a priest taps Start Meeting or the auto-complete
// cron fires. The user's own registration is a separate doc and is
// loaded one-shot (then refreshed after any user-initiated mutation
// + after a successful payment).
//
// The page owns its own RazorpayService instance — matches the wallet
// page pattern: init in initState, dispose in dispose. Razorpay's
// listener registry is per-instance, so giving each page its own
// instance keeps the success/failure handlers tied to this page's
// BuildContext without leaking.

import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/services/razorpay_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

// Forest green for "joined / paid / registered ✓" — warmer than
// AppColors.success against the beige scaffold.
const Color _kJoinedGreen = Color(0xFF2E7D4F);
const Color _kLiveRed = Color(0xFFE53E3E);

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
  late final Stream<BibleSessionModel> _sessionStream;

  // Latest known session model. Mirrored from the stream so widgets
  // outside the StreamBuilder (the Razorpay handlers) can read it.
  BibleSessionModel? _latestSession;
  BibleRegistration? _registration;
  bool _registrationLoaded = false;

  bool _isRegistering = false;
  bool _isPaying = false;

  // Drives setState every 30 s so live countdown text and the past-
  // deadline gate refresh themselves without a pull-to-refresh.
  Timer? _refreshTimer;

  // Returned to the bible tab on pop so the cubit only refetches
  // when the user actually changed state (register / cancel / pay /
  // rate). A passive look-and-back leaves the tab's cached list
  // untouched.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _razorpayService = RazorpayService();
    _razorpayService.init();
    _razorpayService.onSuccess = _onPaymentSuccess;
    _razorpayService.onFailure = _onPaymentFailure;
    _sessionStream = _repository.watchSession(widget.sessionId);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (mounted) setState(() {});
      },
    );
    _loadRegistration();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _razorpayService.dispose();
    super.dispose();
  }

  Future<void> _loadRegistration() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() => _registrationLoaded = true);
      return;
    }
    try {
      final reg = await _repository.getRegistration(
        widget.sessionId,
        uid,
      );
      if (!mounted) return;
      setState(() {
        // A previously-cancelled registration is treated as "not
        // registered" — the rules allow a clean re-register on top
        // of it, so the UI flow doesn't need to expose that doc.
        _registration = (reg != null && reg.isCancelled) ? null : reg;
        _registrationLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      // Don't downgrade a previously-loaded registration on a
      // transient read failure. A paid user pulling-to-refresh on a
      // flaky network would otherwise see _registration reset to
      // null, which renders STATE C (payment gate) and asks them to
      // pay again. Keep the prior known-good value; the next
      // successful refresh will catch up if the server doc actually
      // changed.
      debugPrint('[BibleDetail] _loadRegistration failed: $e');
      if (_registration == null) {
        setState(() => _registrationLoaded = true);
      }
    }
  }

  // ── Actions ────────────────────────────────────────────────────

  Future<void> _register() async {
    if (_isRegistering) return;
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
      _changed = true;
      await _loadRegistration();
      if (!mounted) return;
      AppSnackBar.success(
        context,
        "Registered! We'll notify you when it starts.",
      );
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

  // Pay-and-join entry point. Opens Razorpay in direct-amount mode
  // (no pre-created order); the success handler calls the new
  // payAndJoinBibleSession CF which verifies via Razorpay's
  // payments.fetch API and returns the meeting link.
  //
  // Works for BOTH cases:
  //   • Registered user paying to join the live session
  //   • Non-registered user paying directly (CF creates the reg
  //     as 'paid' in one step with paidOnCreate: true)
  void _payAndJoin() {
    final session = _latestSession;
    if (session == null || _isPaying) return;
    if (!session.isLive) return;
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
      // Plain hyphen (NOT em dash). Razorpay's description field is
      // ASCII-only — an em dash here would surface as the user-facing
      // "description contains invalid characters" error and block
      // every payment. The service-level sanitizer also strips non-
      // ASCII from session.title (priest may type emoji / smart
      // quotes), so this hyphen is the only literal we control.
      description: 'Bible Session - ${session.title}',
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
    if (paymentId == null) {
      if (mounted) {
        setState(() => _isPaying = false);
        AppSnackBar.error(
          context,
          "Payment captured but verification failed. "
          "Contact support with paymentId if amount was deducted.",
        );
      }
      return;
    }

    try {
      // V1 direct-amount checkout — Razorpay only returns paymentId,
      // not orderId/signature. The CF accepts empty strings for the
      // forward-compat fields and verifies via payments.fetch using
      // our key_secret. Returned `meetingLink` is the source of truth.
      final meetingLink = await _repository.payAndJoinBibleSession(
        sessionId: widget.sessionId,
        paymentId: paymentId,
        orderId: response.orderId ?? '',
        signature: response.signature ?? '',
      );
      if (!mounted) return;
      _changed = true;
      // The CF flipped (or created) the registration to 'paid'.
      // Re-read it so STATE D unlocks. The session stream has already
      // been live the whole time, so we don't need to refresh that.
      await _loadRegistration();
      if (!mounted) return;
      setState(() => _isPaying = false);
      AppSnackBar.success(
        context,
        "You're in! Opening meeting…",
      );
      // Auto-launch the meeting for convenience. Best-effort — a
      // failure surfaces a non-blocking snackbar and the user can
      // tap "Open Meeting" on the now-visible link card.
      await _launchUrl(meetingLink);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _isPaying = false);
      AppSnackBar.error(
        context,
        // Surface the CF's message verbatim — it's already user-
        // facing ("Session is completed — cannot pay to join", etc.)
        // and gives support something to grep.
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
    AppSnackBar.error(context, "Payment failed. Please try again.");
  }

  Future<void> _launchUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
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
        AppSnackBar.error(context, "Couldn't open the meeting link.");
      }
    }
  }

  Future<void> _submitRating({
    required int rating,
    required String? feedback,
  }) async {
    try {
      await _repository.rateBibleSession(
        sessionId: widget.sessionId,
        rating: rating,
        feedback: feedback,
      );
      if (!mounted) return;
      _changed = true;
      await _loadRegistration();
      if (!mounted) return;
      AppSnackBar.success(context, "Thank you for your review! 🙏");
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        "Couldn't submit your review. Please try again.",
      );
    }
  }

  Future<void> _openReportSheet() async {
    final session = _latestSession;
    if (session == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final description = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ReportIssueSheet(),
    );
    if (!mounted || description == null || description.trim().isEmpty) {
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('reports')
          .add({
            'reportedBy': user.uid,
            'reporterName':
                user.displayName ?? 'Gospel Vox user',
            'reportedUser': session.priestId,
            'reportedUserName': session.priestName.isNotEmpty
                ? session.priestName
                : 'Speaker',
            'reason': 'bible_session',
            'description': description.trim(),
            'sessionId': widget.sessionId,
            'status': 'pending',
            'createdAt': FieldValue.serverTimestamp(),
          })
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      AppSnackBar.success(
        context,
        "Report submitted. Our team will review it.",
      );
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        "Couldn't submit report. Please try again.",
      );
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
        // Explicit leading button so we can return `_changed` to the
        // bible tab. The default back button calls Navigator.maybePop
        // without a result, which would force the tab to refresh on
        // every back-tap or skip refresh entirely.
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
          "Bible Session",
          style: GoogleFonts.inter(
            fontSize: 16,
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
          // Mirror the latest session so the Razorpay handlers can
          // read it. snap.data is non-null here.
          _latestSession = snap.data;
          return RefreshIndicator(
            color: AppColors.primaryBrown,
            backgroundColor: AppColors.surfaceWhite,
            onRefresh: _loadRegistration,
            child: _buildLoaded(snap.data!),
          );
        },
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
            height: 80,
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
          const SizedBox(height: 14),
          _PriestInfoCard(
            session: session,
            onTap: () {
              if (session.priestId.isEmpty) return;
              context.push('/user/priest/${session.priestId}');
            },
          ),
          const SizedBox(height: 16),
          _buildStateView(session),
        ],
      ),
    );
  }

  // The 9-state decision tree. Order matters — terminal states first
  // (cancelled / completed) before transient ones (live / upcoming).
  Widget _buildStateView(BibleSessionModel session) {
    final reg = _registration;
    final isPaid = reg?.isPaid ?? false;
    final hasRated = reg?.hasRated ?? false;

    // STATE H — Cancelled. Trumps everything else.
    if (session.isCancelled) {
      return _CancelledStateView(
        wasRegistered: reg != null,
        wasPaid: isPaid,
      );
    }

    // STATE E/F/G — Completed branch.
    if (session.isCompleted) {
      if (isPaid && !hasRated) {
        // STATE E — rate the session.
        return _RatingStateView(
          session: session,
          onSubmit: _submitRating,
          onReport: _openReportSheet,
        );
      }
      if (isPaid && hasRated) {
        // STATE F — already rated.
        return _AlreadyRatedStateView(registration: reg!);
      }
      // STATE G — completed, didn't attend.
      return _CompletedNotAttendedStateView();
    }

    // STATE C/D/I — Live branch.
    if (session.isLive) {
      if (!session.isJoinable) {
        // STATE I — past deadline, auto-complete cron will catch up
        // shortly. Don't take more money.
        return _EndingSoonStateView(session: session);
      }
      if (isPaid) {
        // STATE D — link revealed. No "copy link" affordance — the
        // link is open-only to discourage out-of-app sharing.
        return _LinkRevealedStateView(
          session: session,
          onOpen: () => _launchUrl(session.meetingLink),
        );
      }
      // STATE C — payment gate. Works whether registered or not —
      // the CF handles both shapes.
      return _PaymentGateStateView(
        session: session,
        isPaying: _isPaying,
        onPay: _payAndJoin,
      );
    }

    // STATE A/B — Upcoming branch.
    final registrationKnown = _registrationLoaded;
    if (!registrationKnown) {
      // Still waiting for the reg fetch — show a small shimmer
      // instead of briefly flashing the "Register" button before
      // the actual reg lands and replaces it with "Registered ✓".
      return _RegistrationShimmer();
    }
    if (reg == null) {
      // STATE A — not registered.
      return _RegisterForFreeStateView(
        session: session,
        isRegistering: _isRegistering,
        onRegister: _register,
      );
    }
    // STATE B — registered, awaiting live.
    return _RegisteredAwaitingStateView(session: session);
  }
}

// ════════════════════════════════════════════════════════════════
// COMMON CARDS (session info + priest info)
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
          color: session.isLive
              ? _kLiveRed.withValues(alpha: 0.3)
              : AppColors.muted.withValues(alpha: 0.08),
          width: session.isLive ? 1.4 : 1,
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
              _StateBadge(session: session),
              const Spacer(),
              Text(
                "₹${session.price}",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.amberGold,
                ),
              ),
            ],
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
          // Registration count intentionally not displayed on the
          // user side — `session.isFull` still gates the Register
          // CTA (see _RegisterForFreeStateView), but the numeric
          // breakdown is meta noise for an end user deciding
          // whether to join. The priest's manage page surfaces
          // counts where they're operationally useful.
        ],
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  final BibleSessionModel session;
  const _StateBadge({required this.session});

  @override
  Widget build(BuildContext context) {
    if (session.isLive) {
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
            const _PulsingDot(size: 7, color: _kLiveRed),
            const SizedBox(width: 6),
            Text(
              "LIVE NOW",
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
        : session.isCompleted
            ? _kJoinedGreen
            : AppColors.muted;
    final label = session.isUpcoming
        ? "UPCOMING"
        : session.isCompleted
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

class _PriestInfoCard extends StatefulWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;
  const _PriestInfoCard({required this.session, required this.onTap});

  @override
  State<_PriestInfoCard> createState() => _PriestInfoCardState();
}

class _PriestInfoCardState extends State<_PriestInfoCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final initial = session.priestName.isNotEmpty
        ? session.priestName.substring(0, 1).toUpperCase()
        : '?';
    final hasPhoto = session.priestPhotoUrl.isNotEmpty;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.98),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
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
                            fontSize: 16,
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
                      "Speaker · Tap to view profile",
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              AppIcon(
                AppIcons.chevronRight,
                size: 18,
                color: AppColors.muted.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE A — UPCOMING, NOT REGISTERED
// ════════════════════════════════════════════════════════════════

class _RegisterForFreeStateView extends StatelessWidget {
  final BibleSessionModel session;
  final bool isRegistering;
  final VoidCallback onRegister;

  const _RegisterForFreeStateView({
    required this.session,
    required this.isRegistering,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final isFull = session.isFull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoBlock(
          icon: AppIcons.bell,
          accent: AppColors.amberGold,
          title: "Register for free to get notified",
          body:
              "We'll send you a notification the moment this session "
              "goes live. Payment is only required when you join.",
        ),
        const SizedBox(height: 16),
        if (isFull)
          _DisabledButton(label: "Session Full")
        else
          _PrimaryButton(
            label: "Register for Free",
            loading: isRegistering,
            onTap: onRegister,
            background: AppColors.amberGold,
          ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            "Registration is free. You'll pay ₹${session.price} only "
            "when you join the live session.",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE B — UPCOMING, REGISTERED
// ════════════════════════════════════════════════════════════════

class _RegisteredAwaitingStateView extends StatelessWidget {
  final BibleSessionModel session;

  const _RegisteredAwaitingStateView({required this.session});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // "You're registered" green confirmation badge.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: _kJoinedGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _kJoinedGreen.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const AppIcon(
                AppIcons.checkCircle,
                size: 18,
                color: _kJoinedGreen,
              ),
              const SizedBox(width: 8),
              Text(
                "You're registered",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _kJoinedGreen,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _InfoBlock(
          icon: AppIcons.bell,
          accent: AppColors.amberGold,
          title: session.startsInText.isNotEmpty
              ? session.startsInText
              : "We'll notify you when it starts",
          body:
              "We'll send you a call-like notification the moment "
              "the speaker starts this session. Payment of "
              "₹${session.price} is required to join the live meeting.",
        ),
        // No cancel-registration affordance — registration is a
        // commitment until the session completes or is cancelled
        // by the speaker. Removed in V2 to keep attendance numbers
        // honest for priests planning capacity.
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE C — LIVE, NOT PAID (Payment Gate)
// ════════════════════════════════════════════════════════════════

class _PaymentGateStateView extends StatelessWidget {
  final BibleSessionModel session;
  final bool isPaying;
  final VoidCallback onPay;

  const _PaymentGateStateView({
    required this.session,
    required this.isPaying,
    required this.onPay,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Live banner — pulsing dot + countdown so the urgency is
        // obvious even on a long page.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _kLiveRed.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _kLiveRed.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const _PulsingDot(size: 9, color: _kLiveRed),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "This session is happening NOW",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _kLiveRed,
                  ),
                ),
              ),
              Text(
                session.remainingTimeText,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _kLiveRed,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // The locked link surface — a real-looking placeholder behind
        // an ImageFilter blur. The "ghost" of a meet URL is visible
        // through the blur so the user understands what's gated, but
        // they can't read it.
        Container(
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
                    AppIcons.lock,
                    size: 16,
                    color: AppColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "MEETING LINK",
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.muted,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.warmBeige.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      "https://meet.google.com/abc-defg-hij",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Pay ₹${session.price} to unlock the meeting link and "
                "join this live session.",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              _PrimaryButton(
                label: "Pay ₹${session.price} & Join",
                loading: isPaying,
                onTap: onPay,
                background: AppColors.amberGold,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            "Payment is final and non-refundable.",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.muted.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE D — LIVE, PAID (Link Revealed)
// ════════════════════════════════════════════════════════════════

class _LinkRevealedStateView extends StatelessWidget {
  final BibleSessionModel session;
  final VoidCallback onOpen;

  const _LinkRevealedStateView({
    required this.session,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _kJoinedGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _kJoinedGreen.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const AppIcon(
                AppIcons.checkCircle,
                size: 18,
                color: _kJoinedGreen,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "You're in! Session is happening now.",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _kJoinedGreen,
                  ),
                ),
              ),
              Text(
                session.remainingTimeText,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _kJoinedGreen,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppIcon(
                    AppIcons.video,
                    size: 16,
                    color: _kJoinedGreen,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "MEETING LINK",
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _kJoinedGreen,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // The link itself is deliberately NOT shown as readable
              // text — the user opens it via the Open Meeting button,
              // which launches the OS browser/app handler. Hiding the
              // URL prevents copy-paste sharing outside the session
              // (the whole point of paywalling per-attendee is to keep
              // the link single-use-ish; an attendee who pastes the
              // URL into WhatsApp would invite free riders).
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _kJoinedGreen.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const AppIcon(
                      AppIcons.checkCircle,
                      size: 14,
                      color: _kJoinedGreen,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "Meeting link ready",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _kJoinedGreen,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _PrimaryButton(
                label: "Open Meeting",
                loading: false,
                onTap: onOpen,
                background: AppColors.primaryBrown,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE E — COMPLETED, PAID, NOT RATED (Rating form)
// ════════════════════════════════════════════════════════════════

class _RatingStateView extends StatefulWidget {
  final BibleSessionModel session;
  final Future<void> Function({
    required int rating,
    required String? feedback,
  }) onSubmit;
  final VoidCallback onReport;

  const _RatingStateView({
    required this.session,
    required this.onSubmit,
    required this.onReport,
  });

  @override
  State<_RatingStateView> createState() => _RatingStateViewState();
}

class _RatingStateViewState extends State<_RatingStateView> {
  int _rating = 0;
  final _feedbackCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _feedbackCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating < 1 || _submitting) return;
    final fb = _feedbackCtrl.text.trim();
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(
        rating: _rating,
        feedback: fb.isEmpty ? null : fb,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CompletedHeader(message: "Session Completed"),
        const SizedBox(height: 16),
        Container(
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
              Text(
                "How was this session? 🙏",
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "Your feedback helps speakers grow.",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 16),
              _StarRow(
                rating: _rating,
                onTap: (i) => setState(() => _rating = i),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _feedbackCtrl,
                maxLength: 300,
                maxLines: 3,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
                cursorColor: AppColors.primaryBrown,
                decoration: InputDecoration(
                  hintText: "Share your experience… (optional)",
                  hintStyle: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.6),
                  ),
                  filled: true,
                  fillColor: AppColors.warmBeige.withValues(alpha: 0.5),
                  counterText: '',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: AppColors.muted.withValues(alpha: 0.15),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: AppColors.primaryBrown,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _PrimaryButton(
                label: "Submit Review",
                loading: _submitting,
                onTap: (_rating >= 1 && !_submitting) ? _submit : null,
                background: AppColors.amberGold,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: GestureDetector(
            onTap: widget.onReport,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 8,
                horizontal: 12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.flag,
                    size: 14,
                    color: AppColors.errorRed,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    "Report an Issue",
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.errorRed,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StarRow extends StatelessWidget {
  final int rating;
  final ValueChanged<int> onTap;
  const _StarRow({required this.rating, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(5, (i) {
        final filled = i < rating;
        return GestureDetector(
          onTap: () => onTap(i + 1),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: AppIcon(
              filled ? AppIcons.starFilled : AppIcons.starOutline,
              size: 38,
              color: filled
                  ? AppColors.amberGold
                  : AppColors.muted.withValues(alpha: 0.5),
            ),
          ),
        );
      }),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE F — COMPLETED, ALREADY RATED
// ════════════════════════════════════════════════════════════════

class _AlreadyRatedStateView extends StatelessWidget {
  final BibleRegistration registration;
  const _AlreadyRatedStateView({required this.registration});

  @override
  Widget build(BuildContext context) {
    final feedback = registration.feedback?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CompletedHeader(message: "Session Completed"),
        const SizedBox(height: 16),
        Container(
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
              Text(
                "Your Review",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: List.generate(5, (i) {
                  final filled = i < (registration.rating ?? 0);
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: AppIcon(
                      filled
                          ? AppIcons.starFilled
                          : AppIcons.starOutline,
                      size: 28,
                      color: filled
                          ? AppColors.amberGold
                          : AppColors.muted.withValues(alpha: 0.4),
                    ),
                  );
                }),
              ),
              if (feedback != null && feedback.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '"$feedback"',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    fontStyle: FontStyle.italic,
                    color: AppColors.deepDarkBrown.withValues(alpha: 0.85),
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                "Thank you for sharing — your review helps speakers grow. 🙏",
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

// ════════════════════════════════════════════════════════════════
// STATE G — COMPLETED, NOT PAID
// ════════════════════════════════════════════════════════════════

class _CompletedNotAttendedStateView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CompletedHeader(message: "Session Completed"),
        const SizedBox(height: 14),
        _InfoBlock(
          icon: AppIcons.eventBusy,
          accent: AppColors.muted,
          title: "This session has ended",
          body:
              "You can browse other upcoming Bible sessions from the "
              "Bible tab.",
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE H — CANCELLED
// ════════════════════════════════════════════════════════════════

class _CancelledStateView extends StatelessWidget {
  final bool wasRegistered;
  final bool wasPaid;
  const _CancelledStateView({
    required this.wasRegistered,
    required this.wasPaid,
  });

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      "This session was cancelled by the speaker.",
      if (wasRegistered && !wasPaid)
        "Your registration has been cancelled automatically.",
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.errorRed.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.errorRed.withValues(alpha: 0.18),
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
              const SizedBox(height: 10),
              ...lines.map(
                (l) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    l,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.deepDarkBrown,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Paid users from the old flow get a contact-support footer.
        // New-flow users can't reach this branch (live sessions don't
        // transition to cancelled), but the safety net stays.
        if (wasPaid) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.amberGold.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.amberGold.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIcon(
                  AppIcons.info,
                  size: 16,
                  color: AppColors.amberGold,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "If you made a payment, please contact support "
                    "for a refund.",
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.amberGold.withValues(alpha: 0.95),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// STATE I — LIVE BUT PAST DEADLINE
// ════════════════════════════════════════════════════════════════

class _EndingSoonStateView extends StatelessWidget {
  final BibleSessionModel session;
  const _EndingSoonStateView({required this.session});

  @override
  Widget build(BuildContext context) {
    return _InfoBlock(
      icon: AppIcons.hourglass,
      accent: AppColors.muted,
      title: "Session Ending Soon",
      body:
          "This session is past its scheduled duration. The speaker "
          "is wrapping up — it will be marked complete shortly.",
    );
  }
}

// ════════════════════════════════════════════════════════════════
// COMMON HELPERS
// ════════════════════════════════════════════════════════════════

class _CompletedHeader extends StatelessWidget {
  final String message;
  const _CompletedHeader({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: _kJoinedGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _kJoinedGreen.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppIcon(
            AppIcons.checkCircle,
            size: 18,
            color: _kJoinedGreen,
          ),
          const SizedBox(width: 8),
          Text(
            message,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: _kJoinedGreen,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBlock extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String body;

  const _InfoBlock({
    required this.icon,
    required this.accent,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
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
      ),
    );
  }
}

class _RegistrationShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final base = AppColors.muted.withValues(alpha: 0.14);
    final highlight = AppColors.warmBeige;
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: highlight,
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }
}

// ─── Buttons ────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback? onTap;
  final Color background;

  const _PrimaryButton({
    required this.label,
    required this.loading,
    required this.onTap,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return _PressableButton(
      onTap: loading ? null : onTap,
      child: Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: disabled
              ? AppColors.muted.withValues(alpha: 0.2)
              : background,
          borderRadius: BorderRadius.circular(14),
          boxShadow: disabled
              ? const []
              : [
                  BoxShadow(
                    color: background.withValues(alpha: 0.3),
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
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Colors.white,
                    ),
                  ),
                )
              : Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: disabled ? AppColors.muted : Colors.white,
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

// ─── Pulsing dot ────────────────────────────────────────────────

class _PulsingDot extends StatefulWidget {
  final double size;
  final Color color;
  const _PulsingDot({this.size = 8, this.color = _kLiveRed});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.85, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacity = Tween<double>(begin: 1.0, end: 0.35).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        return SizedBox(
          width: widget.size * 1.6,
          height: widget.size * 1.6,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: _opacity.value * 0.4,
                child: Transform.scale(
                  scale: _scale.value,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color,
                    ),
                  ),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════
// REPORT ISSUE SHEET
// ════════════════════════════════════════════════════════════════

class _ReportIssueSheet extends StatefulWidget {
  const _ReportIssueSheet();

  @override
  State<_ReportIssueSheet> createState() => _ReportIssueSheetState();
}

class _ReportIssueSheetState extends State<_ReportIssueSheet> {
  final _ctrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.length < 10 || _submitting) return;
    setState(() => _submitting = true);
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final len = _ctrl.text.trim().length;
    final canSubmit = len >= 10 && !_submitting;

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
              children: [
                AppIcon(
                  AppIcons.flag,
                  size: 20,
                  color: AppColors.errorRed,
                ),
                const SizedBox(width: 10),
                Text(
                  "Report an Issue",
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              "Help us understand what went wrong with this session. "
              "Our team reviews every report.",
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              maxLength: 500,
              maxLines: 4,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
              cursorColor: AppColors.primaryBrown,
              decoration: InputDecoration(
                hintText: "Describe the issue…",
                hintStyle: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
                filled: true,
                fillColor: AppColors.warmBeige.withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: AppColors.muted.withValues(alpha: 0.15),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: AppColors.primaryBrown,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              len < 10
                  ? "At least 10 characters — $len/500"
                  : "$len/500",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: len < 10
                    ? AppColors.errorRed
                    : AppColors.muted,
              ),
            ),
            const SizedBox(height: 18),
            _PressableButton(
              onTap: canSubmit ? _submit : null,
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: canSubmit
                      ? AppColors.errorRed
                      : AppColors.muted.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    "Submit Report",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: canSubmit
                          ? Colors.white
                          : AppColors.muted,
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
