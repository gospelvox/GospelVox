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
// The page subscribes to the global IapService outcomes stream for
// the bible payment flow (Pattern B — page owns the IAP wiring,
// like recharge_sheet). The sessionId rides on the purchase itself
// via PurchaseParam.applicationUserName → Play's obfuscatedAccountId
// → IapService extracts it from the returned PurchaseDetails and
// hands it to the bible verifier. That means a crash-and-recover
// after payment still credits the right session.

import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/config/iap_products.dart';
import 'package:gospel_vox/core/services/iap_service.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/services/purchase_watchdog.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';
import 'package:gospel_vox/features/user/bible/widgets/bible_session_rating_dialog.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Forest green for "joined / paid / registered ✓" — warmer than
// AppColors.success against the beige scaffold.
const Color _kJoinedGreen = AppColors.successGreen;
const Color _kLiveRed = AppColors.liveRed;

class BibleSessionDetailPage extends StatefulWidget {
  final String sessionId;
  const BibleSessionDetailPage({super.key, required this.sessionId});

  @override
  State<BibleSessionDetailPage> createState() =>
      _BibleSessionDetailPageState();
}

class _BibleSessionDetailPageState extends State<BibleSessionDetailPage> {
  // Resolved from the singleton so the same instance the IapService
  // bible verifier uses (registered against `sl<BibleSessionRepository>()`
  // in injection_container.dart) is what this page reads/writes
  // through. Previously this was an inline `BibleSessionRepository()`
  // construction — harmless for stateless reads but a footgun once the
  // verifier wiring depends on the singleton.
  late final BibleSessionRepository _repository = sl<BibleSessionRepository>();
  late final IapService _iap = sl<IapService>();
  StreamSubscription<IapOutcome>? _iapOutcomeSubscription;
  late final Stream<BibleSessionModel> _sessionStream;

  // Latest known session model. Mirrored from the stream so widgets
  // and the IAP outcome handler can read it outside the StreamBuilder.
  BibleSessionModel? _latestSession;
  BibleRegistration? _registration;
  bool _registrationLoaded = false;

  bool _isRegistering = false;
  bool _isPaying = false;

  // UI-only safety net — see PurchaseWatchdog. 40 s sits above the
  // 30 s verifyAndJoinBibleSession timeout so it can never fire during
  // a real verification; it only releases the Pay spinner if the store
  // never reports back at all. Never touches Play Billing or the CF.
  final PurchaseWatchdog _watchdog =
      PurchaseWatchdog(timeout: const Duration(seconds: 40));

  // Drives setState every 30 s so live countdown text and the past-
  // deadline gate refresh themselves without a pull-to-refresh.
  Timer? _refreshTimer;

  // Returned to the bible tab on pop so the cubit only refetches
  // when the user actually changed state (register / cancel / pay /
  // rate). A passive look-and-back leaves the tab's cached list
  // untouched.
  bool _changed = false;

  // Measured at runtime by the bottom sheet so the scroll body can
  // reserve enough padding for the docked CTA without overlapping.
  double _bottomSheetHeight = 0;

  // One-shot guard for the auto-popping rating dialog. The page
  // shows the call/chat-style BibleSessionRatingDialog the moment a
  // paid user who hasn't rated yet sees the session flip into the
  // effectively-completed state (priest tapped Mark Completed OR the
  // auto-complete cron fired OR the user opened the page after the
  // session ended). Flipping this flag to true on first show prevents
  // a stream tick / setState rebuild from re-popping the dialog and
  // trapping the user in an infinite modal loop. If they dismiss
  // without rating, the in-body _RatingStateView is still rendered
  // as the second-chance path.
  bool _didShowRatingDialog = false;

  @override
  void initState() {
    super.initState();
    // Subscribe to the global IapService outcomes stream for the
    // bible payment flow. _onIapOutcome filters by productId so the
    // page only reacts to bible_session_199 outcomes — coin /
    // activation purchases that happen on other surfaces while this
    // page is open are silently ignored.
    _iapOutcomeSubscription = _iap.outcomes.listen(_onIapOutcome);
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
    _watchdog.disarm();
    _refreshTimer?.cancel();
    _iapOutcomeSubscription?.cancel();
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

  // Pay-and-join entry point. Opens the Play sheet for the single
  // bible_session_199 SKU. The sessionId is encoded onto the
  // purchase via PurchaseParam.applicationUserName (mapped to
  // Play's obfuscatedAccountId), which IapService extracts on the
  // way back and hands to the bible verifier. That round-trip
  // means an app-crash mid-purchase still credits the right
  // session when the restored purchase emits on the next launch.
  //
  // Works for BOTH cases (handled by verifyAndJoinBibleSession CF):
  //   • Registered user paying to join the live session.
  //   • Non-registered user paying directly (CF creates the reg
  //     as 'paid' in one step with paidOnCreate: true).
  Future<void> _payAndJoin() async {
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

    if (!_iap.isStoreAvailable) {
      AppSnackBar.error(
        context,
        "In-app purchases aren't available on this device yet. "
        "Please use an Android device with Google Play.",
      );
      return;
    }

    setState(() => _isPaying = true);

    final products = await _iap.queryProducts(
      {IapProducts.bibleSession199},
    );
    if (!mounted) return;
    final product = products[IapProducts.bibleSession199];
    if (product == null) {
      setState(() => _isPaying = false);
      AppSnackBar.error(
        context,
        "Bible session entry isn't available right now. "
        "Please try again later.",
      );
      return;
    }

    final started = await _iap.buyConsumable(
      product,
      // Encode sessionId on the purchase so the verifier can read
      // it back via obfuscatedAccountId even after a crash + restore.
      applicationUserName: widget.sessionId,
    );
    if (!mounted) return;
    if (!started) {
      // IapService already emitted an unavailable/error outcome
      // which _onIapOutcome will handle. Reset locally so the UI
      // unlocks immediately rather than waiting on the async
      // outcome.
      setState(() => _isPaying = false);
      return;
    }
    // Buy dispatched — arm the watchdog so the Pay spinner can't hang
    // forever if no outcome ever comes back.
    _watchdog.arm(_onWatchdogExpired);
  }

  // Fired only when a buy went to the store but no IapOutcome arrived
  // in time. Releases the Pay spinner and reassures the user. A
  // purchase that does complete still lets them in via the app-wide
  // outcome listener and/or restorePurchases on next launch.
  void _onWatchdogExpired() {
    if (!mounted) return;
    setState(() => _isPaying = false);
    AppSnackBar.info(
      context,
      "Taking longer than expected. If you were charged, we'll let you in "
      "as soon as it clears — no need to pay again.",
    );
  }

  // Handles outcomes from the global IapService.outcomes broadcast
  // stream. Filters by productId so this page only reacts to
  // bible_session_199 outcomes — coin / activation purchases that
  // fire while this page is open are silently ignored.
  //
  // On success the meeting link returned by the server is opened
  // IMMEDIATELY — by the time this outcome fires the payment is fully
  // settled and the link is already in `outcome.meetingLink`, so the
  // user shouldn't wait on anything else first. The registration
  // re-read that flips STATE D / renders the link card still runs, but
  // in the BACKGROUND, so it lands a moment later without holding up
  // the meeting launch. (Money + crediting are untouched — that all
  // happened server-side before this outcome was emitted.)
  Future<void> _onIapOutcome(IapOutcome outcome) async {
    if (!mounted) return;
    if (outcome.productId != IapProducts.bibleSession199) return;

    // Our product resolved — stand the watchdog down; every kind
    // below updates the UI.
    _watchdog.disarm();

    switch (outcome.kind) {
      case IapOutcomeKind.success:
        final meetingLink = outcome.meetingLink ?? '';
        _changed = true;
        // No await before this point since the top-of-method mounted
        // guard, so `mounted` is still true — release the spinner and
        // confirm success right away.
        setState(() => _isPaying = false);
        AppSnackBar.success(
          context,
          "You're in! Opening meeting…",
        );
        // Re-read the registration in the BACKGROUND so STATE D / the
        // link card update without making the user wait. _loadRegistration
        // has its own mounted guards, so firing it unawaited is safe.
        // The link we need is already in `meetingLink`.
        unawaited(_loadRegistration());
        // Auto-launch the meeting for convenience. Best-effort — a
        // failure surfaces a non-blocking snackbar inside _launchUrl
        // and the user can tap "Open Meeting" on the now-visible
        // link card.
        await _launchUrl(meetingLink);
        break;
      case IapOutcomeKind.pending:
        setState(() => _isPaying = false);
        AppSnackBar.info(
          context,
          "Payment is processing. We'll let you in as soon as it clears.",
        );
        break;
      case IapOutcomeKind.canceled:
        setState(() => _isPaying = false);
        break;
      case IapOutcomeKind.error:
        setState(() => _isPaying = false);
        AppSnackBar.error(
          context,
          outcome.message ?? "Couldn't complete your purchase.",
        );
        break;
      case IapOutcomeKind.unavailable:
        setState(() => _isPaying = false);
        AppSnackBar.error(
          context,
          "In-app purchases aren't available on this device yet.",
        );
        break;
    }
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

  Future<void> _shareSession() async {
    final session = _latestSession;
    if (session == null) return;
    HapticFeedback.lightImpact();
    final dateLine = session.scheduledAt != null
        ? '${session.formattedDate} · ${session.formattedTime} IST'
        : '';
    final speakerLine = session.priestName.isNotEmpty
        ? '\nSpeaker: ${session.priestName}'
        : '';
    final shareText =
        '${session.title}\n'
        '${dateLine.isNotEmpty ? "$dateLine\n" : ""}'
        '$speakerLine\n\n'
        "Join me for this Bible session on Gospel Vox 🙏";
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: shareText,
          subject: 'Bible Session: ${session.title}',
        ),
      );
    } catch (_) {
      // share_plus can throw on a build that pre-dates the native
      // plugin. Fall back to copying the text so the user can paste
      // it manually.
      await Clipboard.setData(ClipboardData(text: shareText));
      if (!mounted) return;
      AppSnackBar.success(context, "Session details copied to clipboard.");
    }
  }

  Future<void> _addToCalendar() async {
    final session = _latestSession;
    if (session == null || session.scheduledAt == null) return;
    HapticFeedback.lightImpact();

    // Google Calendar event-creation URL. Works on Android (opens the
    // Calendar app if installed, else web) and iOS (opens Safari →
    // Calendar import). Universal enough to avoid platform branches.
    String fmt(DateTime dt) {
      final u = dt.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}'
          'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
    }

    final start = session.scheduledAt!.toUtc();
    final end = start.add(Duration(minutes: session.durationMinutes));
    final params = <String, String>{
      'action': 'TEMPLATE',
      'text': session.title,
      'dates': '${fmt(start)}/${fmt(end)}',
      'details': session.description.isNotEmpty
          ? '${session.description}\n\nSpeaker: ${session.priestName}'
          : 'Bible session with ${session.priestName} on Gospel Vox',
    };
    final uri = Uri.https(
      'calendar.google.com',
      '/calendar/render',
      params,
    );
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        AppSnackBar.error(
          context,
          "Couldn't open calendar. Please add the event manually.",
        );
      }
    } catch (_) {
      if (mounted) {
        AppSnackBar.error(
          context,
          "Couldn't open calendar. Please add the event manually.",
        );
      }
    }
  }

  // Pops the call/chat-style rating dialog as soon as the session is
  // effectively completed AND the current user paid AND hasn't yet
  // rated. One-shot per page mount — _didShowRatingDialog locks it
  // so a stream tick / setState rebuild can't re-pop. After the
  // dialog closes we refresh the registration (if it wrote anything)
  // so the in-body state flips to _AlreadyRatedStateView.
  //
  // Called from the StreamBuilder build path, but the dialog is
  // scheduled via addPostFrameCallback so we never invoke showDialog
  // during a build phase. Registration must be loaded — without it
  // we can't tell isPaid / hasRated, and a premature pop would either
  // miss eligible users or prompt non-attendees.
  void _maybeShowRatingDialog(BibleSessionModel session) {
    if (_didShowRatingDialog) return;
    if (!_registrationLoaded) return;
    final reg = _registration;
    if (reg == null || !reg.isPaid || reg.hasRated) return;
    if (!session.isEffectivelyCompleted) return;

    _didShowRatingDialog = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final submitted = await BibleSessionRatingDialog.show(context, session);
      if (!mounted) return;
      if (submitted) {
        _changed = true;
        await _loadRegistration();
        if (!mounted) return;
        AppSnackBar.success(context, "Thank you for your review! 🙏");
      }
    });
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
      // No AppBar — the floating back / share / calendar buttons live
      // in the Stack overlay so the hero header reaches the top of
      // the screen, matching the reference image.
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<BibleSessionModel>(
          stream: _sessionStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return _withFloatingActions(
                child: _buildError("Couldn't load session."),
                canShare: false,
                canCalendar: false,
              );
            }
            if (!snap.hasData) {
              return _withFloatingActions(
                child: _buildLoading(),
                canShare: false,
                canCalendar: false,
              );
            }
            _latestSession = snap.data;
            // Auto-pop the call/chat-style rating dialog the moment a
            // paid user who hasn't rated sees the session as
            // effectively completed. Scheduled post-frame so we don't
            // call showDialog during a build, and gated on a one-shot
            // flag so a subsequent stream tick / setState can't re-pop.
            _maybeShowRatingDialog(snap.data!);
            return _withFloatingActions(
              child: _buildLoaded(snap.data!),
              canShare: true,
              canCalendar: snap.data!.scheduledAt != null,
            );
          },
        ),
      ),
    );
  }

  // Stacks the body underneath a row of floating circular buttons —
  // back on the left, share + calendar on the right — and overlays
  // the state-aware bottom sheet pinned to the bottom of the screen.
  //
  // Cancelled sessions suppress the floating share + calendar buttons
  // entirely; sharing a cancelled session is a footgun (recipients
  // would tap a dead listing) so we strip the affordance here and
  // surface a muted explainer in the bottom sheet.
  Widget _withFloatingActions({
    required Widget child,
    required bool canShare,
    required bool canCalendar,
  }) {
    final session = _latestSession;
    final isCancelled = session?.isCancelled ?? false;
    final showShare = canShare && !isCancelled;
    final showCalendar = canCalendar && !isCancelled;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 12,
          left: 16,
          right: 16,
          child: Row(
            children: [
              AppBackButton(
                onTap: () => Navigator.of(context).pop(_changed),
              ),
              const Spacer(),
              if (showShare)
                _CircleIconButton(
                  icon: AppIcons.share,
                  onTap: _shareSession,
                ),
              if (showShare && showCalendar) const SizedBox(width: 10),
              if (showCalendar)
                _CircleIconButton(
                  icon: AppIcons.calendar,
                  onTap: _addToCalendar,
                ),
            ],
          ),
        ),
        // Hide the docked footer while the keyboard is open. The only
        // text input on this page is the completed-session review field;
        // when the user is writing a review the share-only footer would
        // otherwise sit over the field inside the shrunk viewport. The
        // scroll body keeps its bottomReserve padding so the field still
        // scrolls clear of the keyboard.
        if (session != null &&
            MediaQuery.of(context).viewInsets.bottom == 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomActionRegion(
              child: _buildBottomAction(session),
              onMeasured: (h) {
                if (h != _bottomSheetHeight && mounted) {
                  setState(() => _bottomSheetHeight = h);
                }
              },
            ),
          ),
      ],
    );
  }

  Widget _buildLoading() {
    final base = AppColors.muted.withValues(alpha: 0.14);
    final highlight = AppColors.warmBeige;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(20, 72, 20, 200),
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
            height: 100,
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
      padding: const EdgeInsets.fromLTRB(32, 120, 32, 32),
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
    // Body padding reserves space at the bottom for the docked
    // action sheet so the last in-body card never hides behind it.
    final bottomReserve = _bottomSheetHeight > 0
        ? _bottomSheetHeight + 16
        : 180.0;
    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: _loadRegistration,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(20, 72, 20, bottomReserve),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HeroHeader(session: session),
            const SizedBox(height: 20),
            _InfoGridCard(session: session),
            const SizedBox(height: 16),
            _SpeakerCard(
              session: session,
              onTap: () {
                if (session.priestId.isEmpty) return;
                context.push('/user/priest/${session.priestId}');
              },
            ),
            const SizedBox(height: 22),
            if (session.description.isNotEmpty)
              _AboutSection(text: session.description),
            const SizedBox(height: 18),
            _inBodyStateContent(session),
          ],
        ),
      ),
    );
  }

  // The 9-state decision tree. Order matters — terminal states first
  // (cancelled / completed) before transient ones (live / upcoming).
  // This returns the IN-BODY content; the bottom sheet picks up the
  // matching CTA via `_buildBottomAction`.
  Widget _inBodyStateContent(BibleSessionModel session) {
    final reg = _registration;
    final isPaid = reg?.isPaid ?? false;
    final hasRated = reg?.hasRated ?? false;

    // STATE H — Cancelled.
    if (session.isCancelled) {
      return _CancelledStateView(
        wasRegistered: reg != null,
        wasPaid: isPaid,
      );
    }

    // STATE E/F/G — Completed branch.
    // isEffectivelyCompleted covers BOTH real completed docs AND a
    // stale 'live' doc whose deadline has passed (the auto-complete
    // cron hasn't flipped it yet). Without this, a user opening a
    // session 20 minutes after it ended would see the broken Live
    // branch ("session ended" with no rating prompt) for up to 5
    // minutes while waiting for the cron — that gap was the source
    // of the "stays live forever" complaint.
    if (session.isEffectivelyCompleted) {
      if (isPaid && !hasRated) {
        return _RatingStateView(
          session: session,
          onSubmit: _submitRating,
          onReport: _openReportSheet,
        );
      }
      if (isPaid && hasRated) {
        return _AlreadyRatedStateView(registration: reg!);
      }
      return _CompletedNotAttendedStateView();
    }

    // STATE C/D/I — Live branch. Only reachable now when status='live'
    // AND we're still inside the (startedAt + duration) window — the
    // past-deadline case falls into the Completed branch above instead
    // of the legacy _EndingSoonStateView.
    if (session.isEffectivelyLive) {
      if (isPaid) {
        return _LiveLinkReadyCard(session: session);
      }
      return _LiveLockedLinkCard(session: session);
    }

    // STATE A/B — Upcoming branch. The in-body "Registration is free"
    // info card is the user-facing explainer; the actual CTA is in
    // the bottom sheet.
    if (!_registrationLoaded) return const _RegistrationShimmer();
    if (reg != null) {
      return _RegisteredAwaitingStateView(session: session);
    }
    return _RegistrationFreeInfoCard(session: session);
  }

  // The docked bottom sheet content — varies by state. For terminal
  // / special states the bottom sheet collapses to a slim share +
  // calendar footer so the in-body content owns the page rhythm.
  Widget _buildBottomAction(BibleSessionModel session) {
    final reg = _registration;
    final isPaid = reg?.isPaid ?? false;
    final hasRated = reg?.hasRated ?? false;

    // Cancelled sessions get a faded, non-interactive footer note —
    // sharing or scheduling a dead listing would mislead recipients,
    // so we suppress the affordance and explain why.
    if (session.isCancelled) {
      return const _DisabledFooterNote(
        message: "Sharing isn't available for cancelled sessions.",
      );
    }
    // isEffectivelyCompleted — collapse to share-only footer for any
    // session that's past its deadline (real completed OR stale-live)
    // so we never present a payable CTA on a session that's already
    // over.
    if (session.isEffectivelyCompleted) {
      if (isPaid && !hasRated) {
        // Rating form is the focus — keep the footer minimal so the
        // user doesn't get pulled away while writing a review.
        return _FooterShareOnly(onShare: _shareSession);
      }
      return _FooterShareOnly(onShare: _shareSession);
    }
    if (session.isEffectivelyLive) {
      if (isPaid) {
        return _BottomCtaSheet(
          primaryLabel: "Open Meeting",
          primaryIcon: AppIcons.video,
          primaryColor: AppColors.primaryBrown,
          helperText: "You're in! Tap to join the live meeting.",
          loading: false,
          onPrimary: () => _launchUrl(session.meetingLink),
          onShare: _shareSession,
          onCalendar: session.scheduledAt != null
              ? _addToCalendar
              : null,
        );
      }
      return _BottomCtaSheet(
        primaryLabel: "Pay ₹${session.price} & Join",
        primaryIcon: AppIcons.lock,
        primaryColor: AppColors.amberGold,
        helperText: "Payment is final and non-refundable.",
        loading: _isPaying,
        onPrimary: _payAndJoin,
        onShare: _shareSession,
        onCalendar: session.scheduledAt != null
            ? _addToCalendar
            : null,
      );
    }

    // Upcoming branch.
    if (!_registrationLoaded) {
      return _FooterShareOnly(onShare: _shareSession);
    }
    if (reg != null) {
      // STATE B — registered. Disabled green confirmation pill so the
      // bottom sheet's slot stays visually consistent across states.
      return _BottomCtaSheet(
        primaryLabel: "Registered ✓",
        primaryIcon: AppIcons.checkCircle,
        primaryColor: _kJoinedGreen,
        helperText: session.startsInText.isNotEmpty
            ? "${session.startsInText}. We'll notify you when it goes live."
            : "We'll notify you the moment it goes live.",
        loading: false,
        onPrimary: null,
        onShare: _shareSession,
        onCalendar: session.scheduledAt != null
            ? _addToCalendar
            : null,
      );
    }
    // STATE A — not registered.
    final isFull = session.isFull;
    return _BottomCtaSheet(
      primaryLabel: isFull ? "Session Full" : "Register for Free",
      primaryIcon: AppIcons.bell,
      primaryColor: AppColors.amberGold,
      helperText: isFull
          ? "You can come back later if a spot opens up."
          : "You'll pay ₹${session.price} only when you join.",
      loading: _isRegistering,
      onPrimary: isFull ? null : _register,
      onShare: _shareSession,
      onCalendar: session.scheduledAt != null ? _addToCalendar : null,
    );
  }
}

// ════════════════════════════════════════════════════════════════
// TOP CHROME — circular floating icon button
// ════════════════════════════════════════════════════════════════

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surfaceWhite,
          boxShadow: [
            BoxShadow(
              blurRadius: 8,
              offset: const Offset(0, 2),
              color: Colors.black.withValues(alpha: 0.04),
            ),
          ],
        ),
        child: AppIcon(
          icon,
          size: 15,
          color: AppColors.deepDarkBrown,
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// HERO HEADER — status pill + price, title, attending row, blurb
// ════════════════════════════════════════════════════════════════

class _HeroHeader extends StatelessWidget {
  final BibleSessionModel session;
  const _HeroHeader({required this.session});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatusPill(session: session),
            if (session.category.isNotEmpty)
              _CategoryChip(label: session.category),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          session.title.isNotEmpty ? session.title : 'Bible Session',
          style: GoogleFonts.inter(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: AppColors.deepDarkBrown,
            height: 1.15,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        _AttendanceRow(session: session),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final BibleSessionModel session;
  const _StatusPill({required this.session});

  @override
  Widget build(BuildContext context) {
    if (session.isEffectivelyLive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: _kLiveRed.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PulsingDot(size: 7, color: _kLiveRed),
            const SizedBox(width: 7),
            Text(
              "LIVE NOW",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: _kLiveRed,
                letterSpacing: 0.7,
              ),
            ),
          ],
        ),
      );
    }
    final Color color;
    final String label;
    final IconData? icon;
    if (session.isUpcoming) {
      color = AppColors.primaryBrown;
      label = "UPCOMING";
      icon = AppIcons.calendar;
    } else if (session.isEffectivelyCompleted) {
      color = _kJoinedGreen;
      label = "COMPLETED";
      icon = AppIcons.checkCircle;
    } else {
      color = AppColors.terraCotta;
      label = "CANCELLED";
      icon = AppIcons.cancel;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

// Tag-style chip used in the hero row to surface the session's
// category alongside the status pill — secondary metadata to the
// state pill, so it uses a softer amber tint to read as supporting
// info rather than another status signal.
class _CategoryChip extends StatelessWidget {
  final String label;
  const _CategoryChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            AppIcons.tag,
            size: 11,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.amberGold,
                letterSpacing: 0.7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceRow extends StatelessWidget {
  final BibleSessionModel session;
  const _AttendanceRow({required this.session});

  @override
  Widget build(BuildContext context) {
    final attending = session.registrationCount;
    final hasCap = session.maxParticipants > 0;
    final spotsLeft = hasCap
        ? (session.maxParticipants - attending).clamp(0, 1 << 30)
        : -1;

    return Row(
      children: [
        AppIcon(
          AppIcons.users,
          size: 13,
          color: AppColors.primaryBrown,
        ),
        const SizedBox(width: 6),
        Text(
          "$attending attending",
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.primaryBrown,
          ),
        ),
        if (hasCap) ...[
          const SizedBox(width: 10),
          Container(
            width: 3,
            height: 3,
            decoration: BoxDecoration(
              color: AppColors.muted.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            spotsLeft > 0
                ? "$spotsLeft spots left"
                : "Session full",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: spotsLeft > 0
                  ? _kJoinedGreen
                  : AppColors.terraCotta,
            ),
          ),
        ],
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// INFO GRID CARD — 4 columns separated by hairline dividers
// ════════════════════════════════════════════════════════════════

class _InfoGridCard extends StatelessWidget {
  final BibleSessionModel session;
  const _InfoGridCard({required this.session});

  @override
  Widget build(BuildContext context) {
    // Build the 4 column tiles. Each column has a fixed structure:
    // icon → bold value → muted subtitle. When data is missing the
    // subtitle is hidden but the column stays so the grid stays
    // visually balanced.
    // 3-column grid only — Date / Time / Duration. Category was lifted
    // out into the hero row as a chip beside the status pill, so the
    // grid stays focused on time-related context.
    final dayLabel = _weekdayName(session.scheduledAt);
    final tiles = <_InfoTile>[
      _InfoTile(
        icon: AppIcons.calendar,
        value: session.formattedDate.isNotEmpty
            ? session.formattedDate
            : '—',
        subtitle: dayLabel,
      ),
      _InfoTile(
        icon: AppIcons.clock,
        value: session.formattedTime.isNotEmpty
            ? session.formattedTime
            : '—',
        subtitle: 'IST',
      ),
      _InfoTile(
        icon: AppIcons.stopwatch,
        value: session.formattedDuration,
        subtitle: 'Duration',
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.borderLight,
          width: 1,
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              Expanded(child: tiles[i]),
              if (i < tiles.length - 1)
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  indent: 14,
                  endIndent: 14,
                  color: AppColors.borderLight,
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _weekdayName(DateTime? dt) {
    if (dt == null) return '';
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[(dt.toLocal().weekday - 1) % 7];
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String subtitle;
  const _InfoTile({
    required this.icon,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    // FittedBox lets the value text shrink-to-fit instead of clipping
    // with an ellipsis — a long date like "September 25, 2026" stays
    // readable on a phone instead of truncating to "Septemb…". The
    // value font caps at the design size (13) and only scales down
    // when the column is narrower than the natural text width.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(icon, size: 18, color: AppColors.primaryBrown),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
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
// SPEAKER CARD — avatar | name + verified + "Tap to view profile" | >
// ════════════════════════════════════════════════════════════════

class _SpeakerCard extends StatefulWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;
  const _SpeakerCard({required this.session, required this.onTap});

  @override
  State<_SpeakerCard> createState() => _SpeakerCardState();
}

class _SpeakerCardState extends State<_SpeakerCard> {
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
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.borderLight,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            session.priestName.isNotEmpty
                                ? session.priestName
                                : 'Speaker',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.deepDarkBrown,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        AppIcon(
                          AppIcons.verified,
                          size: 14,
                          color: AppColors.amberGold,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "Speaker",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              AppIcon(
                AppIcons.chevronRight,
                size: 20,
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
// ABOUT SECTION — title + 3-line clamp with Read more toggle
// ════════════════════════════════════════════════════════════════

class _AboutSection extends StatefulWidget {
  final String text;
  const _AboutSection({required this.text});

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final body = widget.text;
    final bodyStyle = GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: AppColors.deepDarkBrown.withValues(alpha: 0.78),
      height: 1.55,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "About this session",
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 10),
        // LayoutBuilder probes whether the text actually overflows
        // the 3-line clamp so we only show the toggle when it adds
        // value — short blurbs don't get a misleading "Read more" tail.
        LayoutBuilder(
          builder: (context, constraints) {
            final tp = TextPainter(
              text: TextSpan(text: body, style: bodyStyle),
              maxLines: 3,
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: constraints.maxWidth);
            final overflows = tp.didExceedMaxLines;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  alignment: Alignment.topLeft,
                  child: Text(
                    body,
                    maxLines: _expanded ? null : 3,
                    overflow: _expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: bodyStyle,
                  ),
                ),
                if (overflows) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            _expanded ? "Show less" : "Read more",
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.amberGold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: AppIcon(
                              AppIcons.chevronDown,
                              size: 18,
                              color: AppColors.amberGold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// IN-BODY STATE VIEWS
// ════════════════════════════════════════════════════════════════

// State A — UPCOMING, NOT REGISTERED — beige "Registration is free"
// explainer card (matches the bell-card in the reference image).
class _RegistrationFreeInfoCard extends StatelessWidget {
  final BibleSessionModel session;
  const _RegistrationFreeInfoCard({required this.session});

  @override
  Widget build(BuildContext context) {
    return _BellInfoCard(
      title: session.price > 0
          ? "Registration is free"
          : "This session is free",
      body: session.price > 0
          ? "We'll notify you when the session goes live. "
              "Payment is only required when you join."
          : "We'll notify you the moment this session goes live.",
    );
  }
}

// State B — REGISTERED. Green confirmation banner + "Starts in …" info.
class _RegisteredAwaitingStateView extends StatelessWidget {
  final BibleSessionModel session;
  const _RegisteredAwaitingStateView({required this.session});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AccentBanner(
          color: _kJoinedGreen,
          icon: AppIcons.checkCircle,
          title: "You're registered",
          body: session.startsInText.isNotEmpty
              ? "${session.startsInText}. We'll send you a call-like "
                  "notification the moment the speaker starts."
              : "We'll notify you the moment this session goes live.",
        ),
        const SizedBox(height: 12),
        _BellInfoCard(
          title: "Payment at join",
          body: "₹${session.price} is required to join the live meeting. "
              "Pay only once it's live — no money is taken now.",
        ),
      ],
    );
  }
}

// State C — LIVE, NOT PAID. Big live banner + locked-link teaser. The
// "Pay & Join" CTA itself lives in the bottom sheet so the visual
// weight matches the rest of the state-aware flow.
class _LiveLockedLinkCard extends StatelessWidget {
  final BibleSessionModel session;
  const _LiveLockedLinkCard({required this.session});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _kLiveRed.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
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
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(
                    AppIcons.lock,
                    size: 14,
                    color: AppColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "MEETING LINK",
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
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
                      session.platform.placeholder,
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
                "Pay ₹${session.price} from the button below to unlock "
                "the meeting link and join this live session.",
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

// State D — LIVE, PAID. Show a "Meeting link ready" green confirmation;
// the actual launch lives in the bottom sheet's primary CTA.
class _LiveLinkReadyCard extends StatelessWidget {
  final BibleSessionModel session;
  const _LiveLinkReadyCard({required this.session});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AccentBanner(
          color: _kJoinedGreen,
          icon: AppIcons.checkCircle,
          title: "You're in! Session is live",
          body: session.remainingTimeText,
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: _kJoinedGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _kJoinedGreen.withValues(alpha: 0.18),
            ),
          ),
          child: Row(
            children: [
              const AppIcon(
                AppIcons.video,
                size: 14,
                color: _kJoinedGreen,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Meeting link unlocked — tap Open Meeting to join.",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _kJoinedGreen,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Zoom join extras, if the speaker provided them. The full Zoom
        // link usually embeds the password (so these are often empty),
        // but when present they let the user join manually from the
        // Zoom app. Copy buttons because passcodes are fiddly to type.
        if (session.hasMeetingId || session.hasPasscode) ...[
          const SizedBox(height: 12),
          if (session.hasMeetingId)
            _JoinExtraLine(label: "Meeting ID", value: session.meetingId),
          if (session.hasPasscode)
            _JoinExtraLine(
              label: "Passcode",
              value: session.meetingPasscode,
            ),
        ],
      ],
    );
  }
}

// One labelled join detail (Meeting ID / Passcode) with a tap-to-copy
// button. Shown to PAID users on a live Zoom session.
class _JoinExtraLine extends StatelessWidget {
  final String label;
  final String value;
  const _JoinExtraLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            Text(
              "$label: ",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                Clipboard.setData(ClipboardData(text: value));
                AppSnackBar.success(context, "$label copied");
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: AppIcon(
                  AppIcons.copy,
                  size: 16,
                  color: AppColors.primaryBrown,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// State E — COMPLETED, PAID, NOT RATED — rating form in-body.
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
        _AccentBanner(
          color: _kJoinedGreen,
          icon: AppIcons.checkCircle,
          title: "Session Completed",
          body: "Share a quick review to help the speaker grow.",
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderLight),
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

// State F — COMPLETED, ALREADY RATED.
class _AlreadyRatedStateView extends StatelessWidget {
  final BibleRegistration registration;
  const _AlreadyRatedStateView({required this.registration});

  @override
  Widget build(BuildContext context) {
    final feedback = registration.feedback?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AccentBanner(
          color: _kJoinedGreen,
          icon: AppIcons.checkCircle,
          title: "Session Completed",
          body: "Thanks for joining and sharing your review.",
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Your Review",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
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
                    color:
                        AppColors.deepDarkBrown.withValues(alpha: 0.85),
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// State G — COMPLETED, NOT PAID.
class _CompletedNotAttendedStateView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _AccentBanner(
      color: AppColors.muted,
      icon: AppIcons.eventBusy,
      title: "This session has ended",
      body: "Browse other upcoming Bible sessions from the Bible tab.",
    );
  }
}

// State H — CANCELLED.
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
            borderRadius: BorderRadius.circular(16),
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
                    size: 16,
                    color: AppColors.errorRed,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "SESSION CANCELLED",
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.errorRed,
                      letterSpacing: 0.7,
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
        if (wasPaid) ...[
          const SizedBox(height: 12),
          _BellInfoCard(
            title: "Need a refund?",
            body: "Please contact support if you paid for this session.",
            accent: AppColors.amberGold,
            icon: AppIcons.info,
          ),
        ],
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// COMMON HELPERS
// ════════════════════════════════════════════════════════════════

// "Registration is free" style card — bell-in-circle + bold title +
// muted body. Mirrors the reference image's notification card.
class _BellInfoCard extends StatelessWidget {
  final String title;
  final String body;
  final Color accent;
  final IconData icon;
  const _BellInfoCard({
    required this.title,
    required this.body,
    this.accent = AppColors.primaryBrown,
    this.icon = AppIcons.bell,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warmBeige.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceWhite,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Center(
              child: AppIcon(icon, size: 16, color: accent),
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
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                    height: 1.45,
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

// Tinted accent banner used for state confirmations.
class _AccentBanner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String body;

  const _AccentBanner({
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.deepDarkBrown
                          .withValues(alpha: 0.75),
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RegistrationShimmer extends StatelessWidget {
  const _RegistrationShimmer();

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
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// BOTTOM ACTION REGION — pinned docked sheet
// ════════════════════════════════════════════════════════════════

// Measures its child so the scroll body can reserve enough bottom
// padding to never hide content behind the docked sheet.
class _BottomActionRegion extends StatefulWidget {
  final Widget child;
  final ValueChanged<double> onMeasured;
  const _BottomActionRegion({
    required this.child,
    required this.onMeasured,
  });

  @override
  State<_BottomActionRegion> createState() => _BottomActionRegionState();
}

class _BottomActionRegionState extends State<_BottomActionRegion> {
  final GlobalKey _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _key.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        widget.onMeasured(box.size.height);
      }
    });
    return Container(
      key: _key,
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(22),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowWarm.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle pill — purely decorative; matches the
              // reference image's grabber affordance.
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              widget.child,
            ],
          ),
        ),
      ),
    );
  }
}

// The full bottom-sheet content: wide primary CTA + helper text +
// share / calendar bottom row.
class _BottomCtaSheet extends StatelessWidget {
  final String primaryLabel;
  final IconData primaryIcon;
  final Color primaryColor;
  final String helperText;
  final bool loading;
  final VoidCallback? onPrimary;
  final VoidCallback onShare;
  final VoidCallback? onCalendar;

  const _BottomCtaSheet({
    required this.primaryLabel,
    required this.primaryIcon,
    required this.primaryColor,
    required this.helperText,
    required this.loading,
    required this.onPrimary,
    required this.onShare,
    required this.onCalendar,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PrimaryButton(
          label: primaryLabel,
          loading: loading,
          onTap: onPrimary,
          background: primaryColor,
          leadingIcon: primaryIcon,
        ),
        const SizedBox(height: 10),
        Text(
          helperText,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 1,
          color: AppColors.borderLight,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: _BottomActionItem(
                icon: AppIcons.share,
                label: "Share this session",
                onTap: onShare,
              ),
            ),
            if (onCalendar != null)
              Expanded(
                child: _BottomActionItem(
                  icon: AppIcons.calendar,
                  label: "Add to calendar",
                  onTap: onCalendar!,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// Minimal bottom sheet for terminal / non-actionable states. The
// share button is still useful (a completed session can be shared
// as social proof), but the calendar button doesn't make sense
// anymore.
// Faded, non-interactive footer note for cancelled sessions. The
// share + calendar affordances are stripped (both at the top of the
// page and here) and replaced with a muted explainer so the user
// knows why those actions are gone — silently disappearing controls
// is more confusing than a one-line caption.
class _DisabledFooterNote extends StatelessWidget {
  final String message;
  const _DisabledFooterNote({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(
            AppIcons.lock,
            size: 13,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.muted.withValues(alpha: 0.75),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterShareOnly extends StatelessWidget {
  final VoidCallback onShare;
  const _FooterShareOnly({required this.onShare});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: _BottomActionItem(
        icon: AppIcons.share,
        label: "Share this session",
        onTap: onShare,
      ),
    );
  }
}

class _BottomActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _BottomActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(
              icon,
              size: 14,
              color: AppColors.deepDarkBrown,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ],
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
  final IconData? leadingIcon;

  const _PrimaryButton({
    required this.label,
    required this.loading,
    required this.onTap,
    required this.background,
    this.leadingIcon,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return _PressableButton(
      onTap: loading ? null : onTap,
      child: Container(
        width: double.infinity,
        height: 54,
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
                  width: 35,
                  height: 35,
                  child: AppLoader(),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leadingIcon != null) ...[
                      AppIcon(
                        leadingIcon!,
                        size: 16,
                        color: disabled
                            ? AppColors.muted
                            : Colors.white,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      label,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color:
                            disabled ? AppColors.muted : Colors.white,
                      ),
                    ),
                  ],
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
