// Priest dashboard — home surface for an approved priest.
//
// Availability model (3 states, NO derived flags):
//
//   • ONLINE — isOnline=true, isBusy=false. The default for an
//     activated priest with the app open. Set on dashboard mount
//     and refreshed via the 30s heartbeat. Stays true through
//     backgrounding and force-kill — only the watchdog (after a
//     stale-heartbeat sweep) or the priest's own "Go Offline"
//     toggle / sign-out can flip it false.
//
//   • BUSY — isOnline=true, isBusy=true. Set ONLY by the session
//     system when an active session begins (acceptSession writes
//     the flag) and cleared when the session ends (endSession +
//     watchdog clear it). Never written by this dashboard.
//
//   • OFFLINE — isOnline=false. Either the priest manually
//     toggled "Go Offline" in Settings, or the watchdog detected
//     no heartbeat for >5 minutes (network drop, force-kill).
//
// 30-second heartbeat runs while the dashboard is mounted and
// foregrounded. It refreshes lastHeartbeat so the watchdog can
// distinguish a live priest from one whose phone died. Heartbeat
// stops when the app is backgrounded but isOnline stays true —
// the priest is still "available," they just don't have the app
// in front of them. The watchdog's 5-minute window catches truly-
// dead priests; backgrounding for 1-4 minutes is normal usage.
//
// Unactivated priests do NOT auto-go-online. An activation CTA
// sits at the top of the dashboard until they activate; the
// status card reads "Not Activated" with explanation.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class PriestDashboardPage extends StatefulWidget {
  const PriestDashboardPage({super.key});

  @override
  State<PriestDashboardPage> createState() => _PriestDashboardPageState();
}

class _PriestDashboardPageState extends State<PriestDashboardPage>
    with WidgetsBindingObserver {
  Timer? _heartbeatTimer;

  bool _loading = true;

  String _fullName = '';
  String _photoUrl = '';
  bool _isOnline = false;
  bool _isBusy = false;
  bool _isActivated = false;
  int _totalSessions = 0;
  double _totalEarnings = 0.0;
  double _rating = 0.0;
  // Effective ratings count for the dashboard tile. Sourced in
  // priority order:
  //   1. priests/{uid}.reviewCount — the CF-aggregated counter, kept
  //      atomically in sync with `rating` and `recentReviews` by
  //      onSessionRated + onBibleSessionRated.
  //   2. priests/{uid}.recentReviews length — when the aggregated
  //      counter is 0 but the denormalised array has entries, the
  //      array is the authoritative signal. Covers backfilled priests
  //      (the legacy backfill writes recentReviews without updating
  //      reviewCount) and the brief window before a CF that has just
  //      rewritten the array catches up on the counter field.
  //   3. Local sessions query — last-resort async fallback in
  //      _computeRatingFromSessions for un-backfilled legacy priests
  //      whose chat/voice ratings live only on sessions/{id}.userRating.
  // Used as the gate for "has ratings": a positive count shows the
  // average, zero shows the empty-state hint. We can't use `_rating >
  // 0` for this — an aggregated 0.0 average is technically possible
  // (it isn't with our 1-5 scale, but the gate should still reflect
  // "do we have data?" not "is the data nonzero?").
  int _reviewCount = 0;
  // Latches once the client-side rating fallback has run. The priest
  // doc stream re-fires every heartbeat (lastHeartbeat updates land
  // here), so without the latch we'd re-issue the sessions query
  // every 30s for a priest whose CF aggregation hasn't populated
  // rating/reviewCount yet AND who has no recentReviews entries.
  bool _ratingFallbackAttempted = false;
  // True between starting the fallback and it returning. Gates the
  // rating tile so it doesn't flash "No ratings yet" during the
  // ~1 second the fallback takes — the tile shows a quiet "—" while
  // we're still resolving, then flips to either the real number or
  // the empty state once we know for sure.
  bool _ratingFallbackInFlight = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;

  // Latches once the first auto-online write of this dashboard
  // mount has fired. Without this, EVERY snapshot showing
  // isOnline=false would re-trigger _goOnlineIfEligible() — which
  // means the moment the priest taps Go Offline on the settings
  // page, this listener observes the resulting false snapshot and
  // immediately writes true back, fighting the manual toggle.
  // First-mount auto-online still works (and so does the
  // "activation just flipped on" path); subsequent snapshots
  // respect whatever the priest's last write said.
  bool _didInitialAutoOnline = false;
  // Live stream of unread missed-request notifications from the last
  // 24 hours. Drives the amber missed-request banner that sits below
  // the greeting and above the status card. The banner is the priest's
  // single, glanceable signal that "someone tried to reach you" — it
  // stays visible until they respond or dismiss each one from the My
  // Users page (no longer cleared by simply opening My Users).
  //
  // We hold the latest requester name as well as the count so the
  // banner can render the "Asha tried to reach you" single-name
  // variant without a second query.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _missedSub;
  int _missedRequestCount = 0;
  String _missedRequesterName = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachDocStream();
    // Pending-request routing now lives in
    // PriestIncomingRequestService (initialised in main.dart) so
    // that incoming calls route to /priest/incoming regardless of
    // which page the priest is currently on. Keeping a duplicate
    // listener here would just double-push the same session.
    _attachMissedRequestStream();

    // Drain any pending notification-tap route. A tap from terminated
    // state stashes the route during NotificationService.init(); the
    // dashboard is the first screen mounted for an approved priest, so
    // this is the earliest place GoRouter is guaranteed to be ready.
    //
    // Skip push if the route equals "/priest" — we're already on it,
    // and pushing again would stack a duplicate dashboard. The session-
    // request push uses "/priest" specifically so the dashboard's own
    // pending-request stream picks it up with the full SessionModel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = NotificationService.pendingRoute;
      NotificationService.pendingRoute = null;
      if (route == null || route.isEmpty || route == '/priest') return;
      if (!mounted) return;
      context.push(route);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    _docSub?.cancel();
    _missedSub?.cancel();
    // No isOnline write on dispose — see availability-model header.
    // The watchdog CF sweeps stale heartbeats as the safety net for
    // force-killed priests; sign-out writes offline directly via
    // AuthRepository before clearing auth state.
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Backgrounding does NOT change isOnline anymore — the priest
      // is still "available" while the app is in their pocket. We
      // just stop the heartbeat: the watchdog will pick up a truly-
      // dead device after 5 stale minutes.
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      // Send one fresh heartbeat immediately so a priest who just
      // came back doesn't sit at "watchdog about to flip me offline"
      // for 30 seconds, then restart the periodic timer.
      _sendHeartbeatOnce();
      _ensureHeartbeatRunning();
    }
  }

  // ─── Firestore wiring ──────────────────────────────────────

  void _attachDocStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _docSub = FirebaseFirestore.instance
        .doc('priests/$uid')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final data = snap.data() ?? const <String, dynamic>{};
      final wasActivated = _isActivated;

      // Resolve the rating + count from the priest doc using a
      // priority chain. The aggregated counter is the canonical
      // source, but it can lag (CF in-flight) or be wrong (legacy
      // backfill only wrote recentReviews). Falling through to the
      // denormalised array means a backfilled priest sees the right
      // number on the first frame instead of waiting for the async
      // sessions-query fallback every mount. Both onSessionRated and
      // onBibleSessionRated update recentReviews atomically with
      // reviewCount, so an entry-bearing array with reviewCount == 0
      // is the unambiguous "aggregation is out of sync" signal.
      final docReviewCount =
          (data['reviewCount'] as num?)?.toInt() ?? 0;
      final docRating = (data['rating'] as num?)?.toDouble() ?? 0.0;
      int effectiveReviewCount = docReviewCount;
      double effectiveRating = docRating;
      if (effectiveReviewCount == 0) {
        final arrayRatings = ((data['recentReviews'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => (m['rating'] as num?)?.toDouble())
            .whereType<double>()
            .where((r) => r > 0)
            .toList();
        if (arrayRatings.isNotEmpty) {
          effectiveReviewCount = arrayRatings.length;
          effectiveRating = double.parse(
            (arrayRatings.reduce((a, b) => a + b) / arrayRatings.length)
                .toStringAsFixed(1),
          );
        }
      }

      // Decide if the async fallback is needed BEFORE setState so the
      // same build cycle flips the rating tile into its "resolving"
      // state — without this the tile renders "No ratings yet" for
      // one frame before the fallback kicks in. Now only triggers
      // when both the counter AND the array are empty (the
      // un-backfilled legacy case).
      final shouldStartFallback =
          effectiveReviewCount == 0 && !_ratingFallbackAttempted;

      setState(() {
        _fullName = data['fullName'] as String? ?? '';
        _photoUrl = data['photoUrl'] as String? ?? '';
        _isOnline = data['isOnline'] as bool? ?? false;
        _isBusy = data['isBusy'] as bool? ?? false;
        _isActivated = data['isActivated'] as bool? ?? false;
        _totalSessions = (data['totalSessions'] as num?)?.toInt() ?? 0;
        _totalEarnings = (data['totalEarnings'] as num?)?.toDouble() ?? 0.0;
        _rating = effectiveRating;
        _reviewCount = effectiveReviewCount;
        _loading = false;
        if (shouldStartFallback) _ratingFallbackInFlight = true;
      });

      // Last-resort client-side rating fallback. Only fires when
      // BOTH the aggregated reviewCount and the denormalised
      // recentReviews array are empty — i.e. an un-backfilled legacy
      // priest whose chat/voice ratings exist only on the source
      // sessions docs. The recentReviews short-circuit above covers
      // every other case (backfilled priests, CF-in-flight after a
      // rating) synchronously, so this async path almost never runs
      // in practice. Latched so we don't re-query on every
      // heartbeat-driven priest-doc snapshot.
      //
      // Why only when the effective count is 0: every other rating-
      // display surface in the app reads priests/{uid}.rating directly
      // (profile page, reviews page, user-side priest profile/card,
      // session history summary). Recomputing on every mount would
      // make the dashboard disagree with all of those whenever the
      // CF-aggregated value has drifted from the raw average. The
      // canonical fix for drift lives in the CF; the dashboard's
      // job is to surface what the source of truth says, not to
      // unilaterally correct it.
      if (shouldStartFallback) {
        _ratingFallbackAttempted = true;
        _computeRatingFromSessions();
      }

      // Auto-online is now opt-in. We respect whatever the priest's
      // last toggle said:
      //   • Activation flips false → true: eager-online them once,
      //     because finishing the activation flow IS the explicit
      //     "start accepting" action.
      //   • First mount snapshot: do NOT write isOnline. If the
      //     priest was already online, the heartbeat-restart logic
      //     below picks up the existing state. If they were offline
      //     (manual Go-Offline, watchdog flip, fresh sign-in) they
      //     stay offline — surfacing in availability settings is the
      //     explicit way back online.
      // Without this guard, opening the app to check earnings would
      // silently flip a previously-offline priest back to available.
      final activationJustEnabled = !wasActivated && _isActivated;
      if (_isActivated && activationJustEnabled) {
        _didInitialAutoOnline = true;
        _goOnlineIfEligible();
      } else if (!_didInitialAutoOnline) {
        // Mark so the next snapshot doesn't re-trigger anything.
        // No write — the heartbeat block below either starts the
        // 30s timer (if already online) or leaves us offline.
        _didInitialAutoOnline = true;
      }

      // Keep heartbeat running ONLY while our local view says
      // online. If something else (watchdog, admin, sign-out) took
      // us offline, stop the heartbeat so we don't fight it.
      if (_isOnline) {
        _ensureHeartbeatRunning();
      } else {
        _heartbeatTimer?.cancel();
      }
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    });
  }

  // Listen for pending session requests targeted at this priest.
  //
  // Query intentionally has NO orderBy — two reasons:
  //   1. `where priestId + where status + orderBy createdAt`
  //      requires a composite Firestore index. Without it the
  //      whole stream throws FAILED_PRECONDITION on first fire
  //      and the priest never sees any request. We trade the
  //      server-side sort for a client-side sort so the app
  //      works out-of-the-box in a fresh Firebase project.
  //   2. `orderBy` on a server timestamp excludes docs whose
  //      timestamp hasn't been stamped yet — for ~1s right after
  //      the CF write, the doc would be invisible.
  //
  // We dedupe seen ids because a still-pending doc emits multiple
  // snapshots as metadata propagates, and we don't want to push
  // the incoming screen twice for the same request.
  // Live stream of unread missed_request notifications from the last
  // 24 hours. The 24h floor is a server-side range filter so stale
  // requests don't keep accruing on the dashboard banner forever
  // even if the priest never explicitly dismisses them. Pairing
  // four equality filters + a range + orderBy needs a composite
  // index — Firebase emits a one-click create link in the console
  // logs the first time this query runs.
  //
  // We capture the most recent requester's name (first doc of a
  // descending-by-createdAt result) so the banner can render the
  // "Asha tried to reach you" single-name variant without firing
  // a second query.
  void _attachMissedRequestStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final since = Timestamp.fromDate(
      DateTime.now().subtract(const Duration(hours: 24)),
    );

    _missedSub = FirebaseFirestore.instance
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .where('type', isEqualTo: 'missed_request')
        .where('isRead', isEqualTo: false)
        .where('createdAt', isGreaterThan: since)
        .orderBy('createdAt', descending: true)
        .limit(99)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final nextCount = snap.size;
      final nextName = snap.docs.isNotEmpty
          ? (snap.docs.first.data()['requesterName'] as String? ?? '')
          : '';
      if (nextCount == _missedRequestCount &&
          nextName == _missedRequesterName) {
        return;
      }
      setState(() {
        _missedRequestCount = nextCount;
        _missedRequesterName = nextName;
      });
    }, onError: (e, st) {
      // Surface the real error in logs — without this we'd silently
      // hide a misconfigured query forever. The most common failure
      // here is the FAILED_PRECONDITION you get the first time the
      // query runs in a project: Firestore embeds a one-click
      // create-index URL in the error message. Open the Flutter
      // console (Logcat / `flutter run` output), click the link,
      // and the banner starts working ~1-3 minutes after the
      // index finishes building.
      debugPrint(
        '[PriestDashboard] missed-request stream failed: $e\n$st',
      );
    });
  }

  // ─── Rating fallback (race-window only) ────────────────────

  // Runs at most once per dashboard mount, only when the priest doc
  // reports reviewCount == 0. Covers the race between the first
  // rating landing on the session/registration doc and the CF
  // updating priests/{uid}.rating + reviewCount — without this the
  // priest sees "No ratings yet" until the next mount even though
  // their first review already exists.
  //
  // Reads BOTH chat/voice ratings (from the sessions collection) AND
  // bible-session ratings (from the denormalised priests/{uid}.recentReviews
  // array), averages the combined set, and patches the dashboard's
  // local view. The two CFs (onSessionRated + onBibleSessionRated)
  // remain the source of truth for the priest doc fields; this
  // method just covers their write lag.
  //
  // What it MUST NOT do: override the doc value when reviewCount > 0.
  // Every other rating-display surface in the app reads the priest
  // doc directly; if this method "corrected" the dashboard, the
  // dashboard would silently disagree with profile / reviews /
  // session history / user-side surfaces — a worse user experience
  // than a slightly-drifted-but-consistent number.
  Future<void> _computeRatingFromSessions() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final sessionsFuture = FirebaseFirestore.instance
          .collection('sessions')
          .where('priestId', isEqualTo: uid)
          .limit(500)
          .get();
      // Bible aggregation happens on the priest doc itself — we read
      // it both for its mirrored recentReviews entries AND so we can
      // pick up any rating the CF has just written before our
      // priest-doc stream snapshot caught up.
      final priestFuture =
          FirebaseFirestore.instance.doc('priests/$uid').get();

      final results = await Future.wait([
        sessionsFuture,
        priestFuture,
      ]).timeout(const Duration(seconds: 8));

      final snap = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final priestSnap =
          results[1] as DocumentSnapshot<Map<String, dynamic>>;

      final ratings = <double>[];
      for (final d in snap.docs) {
        final r = (d.data()['userRating'] as num?)?.toDouble();
        if (r != null && r > 0) ratings.add(r);
      }

      // Pick up bible ratings from the denormalised mirror so a priest
      // who has only bible reviews (no chat/voice yet) doesn't see the
      // empty state. We also dedupe-defensively against the sentinel
      // key so a snapshot replay can't double-count.
      final seenBibleKeys = <String>{};
      final recent =
          (priestSnap.data()?['recentReviews'] as List?) ?? const [];
      for (final raw in recent.whereType<Map>()) {
        final entry = Map<String, dynamic>.from(raw);
        if (entry['source'] != 'bible') continue;
        final key = entry['sessionId'] as String?;
        if (key == null || !seenBibleKeys.add(key)) continue;
        final r = (entry['rating'] as num?)?.toDouble();
        if (r != null && r > 0) ratings.add(r);
      }

      if (!mounted) return;
      if (ratings.isEmpty) {
        // Truly no ratings yet — flip out of the resolving state so
        // the tile is allowed to show "No ratings yet".
        setState(() => _ratingFallbackInFlight = false);
        return;
      }
      final avg = ratings.reduce((a, b) => a + b) / ratings.length;
      setState(() {
        _rating = double.parse(avg.toStringAsFixed(1));
        _reviewCount = ratings.length;
        _ratingFallbackInFlight = false;
      });
    } catch (_) {
      // Best-effort — leave the empty state in place if the query
      // fails. The CFs will eventually catch up on their own.
      if (mounted) setState(() => _ratingFallbackInFlight = false);
    }
  }

  // ─── Online / busy / offline lifecycle ─────────────────────

  // Called on first snapshot of the priest doc and whenever
  // activation flips on. Writes isOnline=true and refreshes
  // lastHeartbeat. Does NOT touch isBusy — that field is owned
  // entirely by the session system (acceptSession sets, endSession
  // clears). Skipped entirely until the priest is activated.
  Future<void> _goOnlineIfEligible() async {
    if (!_isActivated) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance.doc('priests/$uid').update({
        'isOnline': true,
        'lastHeartbeat': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Silent — stream listener will re-attempt on next snapshot,
      // and watchdog tolerates transient write failures.
    }
    _ensureHeartbeatRunning();
  }

  void _ensureHeartbeatRunning() {
    if (_heartbeatTimer?.isActive ?? false) return;
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendHeartbeatOnce(),
    );
  }

  Future<void> _sendHeartbeatOnce() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance.doc('priests/$uid').update({
        'lastHeartbeat': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Watchdog will flip us offline if this stays broken — the
      // correct eventual outcome.
    }
  }

  // ─── Helpers ───────────────────────────────────────────────

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String _getGreetingEmoji() {
    final hour = DateTime.now().hour;
    if (hour < 17) return '☀️';
    return '🌙';
  }

  String _getDisplayName() {
    final trimmed = _fullName.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final auth = FirebaseAuth.instance.currentUser?.displayName ?? '';
    if (auth.trim().isNotEmpty) return auth.trim();
    return 'Speaker';
  }

  _StatusVariant get _statusVariant {
    if (!_isActivated) return _StatusVariant.notActivated;
    if (!_isOnline) {
      // Manual stop is the canonical "offline" — auto-go-online
      // skips this state until the priest taps Resume Accepting.
      return _StatusVariant.offline;
    }
    if (_isBusy) return _StatusVariant.busy;
    return _StatusVariant.online;
  }

  // Indian-style grouping: 1192 → 1,192, 100000 → 1,00,000.
  // Used for the Earned stat. NumberFormat is allocated lazily once.
  static final NumberFormat _inrFormatter =
      NumberFormat.decimalPattern('en_IN');

  // ─── Build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Hold the spinner until BOTH the priest doc has loaded AND the
    // rating fallback (if it had to run) has returned. Without the
    // second gate the dashboard renders briefly with the priest doc's
    // raw reviewCount=0, the rating tile flashes the empty state for
    // ~1s, then the fallback finishes and the tile flips to the real
    // rating — a visible state change the priest reads as a glitch.
    // Blocking the whole surface for that ~1s makes the dashboard
    // appear in one settled state.
    final isResolvingDashboard = _loading || _ratingFallbackInFlight;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: isResolvingDashboard
            ? const Center(
                child: CircularProgressIndicator(
                  color: AppColors.primaryBrown,
                  strokeWidth: 2.5,
                ),
              )
            : SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                child: Center(
                  // ConstrainedBox caps content width at 600px so the
                  // dashboard reads as a designed surface on tablets
                  // (centered with margins) instead of stretching to
                  // full iPad width. Phones < 600px are unaffected —
                  // ConstrainedBox.maxWidth only kicks in once the
                  // parent is wider than that.
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(),
                          if (!_isActivated) ...[
                            const SizedBox(height: 24),
                            _buildActivationCta(),
                          ],
                          const SizedBox(height: 24),
                          _StatusCard(variant: _statusVariant),
                          if (_missedRequestCount > 0) ...[
                            const SizedBox(height: 12),
                            _MissedRequestBanner(
                              count: _missedRequestCount,
                              requesterName: _missedRequesterName,
                              onTap: () => context
                                  .push('/priest/missed-requests'),
                            ),
                          ],
                          const SizedBox(height: 24),
                          _SectionLabel(text: 'YOUR STATS'),
                          const SizedBox(height: 12),
                          _buildStatsRow(),
                          const SizedBox(height: 24),
                          _SectionLabel(text: 'QUICK ACTIONS'),
                          const SizedBox(height: 12),
                          _buildQuickActionsRow(),
                          if (_statusVariant ==
                              _StatusVariant.online) ...[
                            const SizedBox(height: 24),
                            _ManageAvailabilityCard(
                              onTap: () => context
                                  .push('/priest/settings/availability'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildHeader() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final name = _getDisplayName();
    final fallback = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _getGreeting(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _getGreetingEmoji(),
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepDarkBrown,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (uid != null) ...[
          _NotificationBell(uid: uid),
          const SizedBox(width: 10),
        ],
        _ProfileAvatar(
          photoUrl: _photoUrl,
          fallbackLetter: fallback,
          onTap: () => context.push('/priest/profile'),
        ),
      ],
    );
  }

  // Activation CTA is a first-class card (not a small hint) because
  // it's the single most important action an unactivated priest can
  // take, and the dashboard is the surface they'll see most.
  Widget _buildActivationCta() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.amberGold.withValues(alpha: 0.18),
            AppColors.amberGold.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.35),
        ),
      ),
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
                  color: AppColors.amberGold.withValues(alpha: 0.2),
                ),
                child: const AppIcon(
                  AppIcons.lockOpen,
                  size: 18,
                  color: AppColors.amberGold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Activate Your Account',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Pay a one-time activation fee to appear in the user feed '
            'and start accepting sessions. Until then your account '
            'stays private.',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: AppColors.deepDarkBrown.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 14),
          _ActivationCta(
            onTap: () => context.push('/priest/activation'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    // Gate on reviewCount, not rating: `_reviewCount` is now the
    // resolved-effective count (doc reviewCount, falling back to
    // recentReviews length, falling back to the async sessions
    // query), so a positive value is the unambiguous "do we have any
    // ratings?" signal regardless of which path filled it. We can't
    // use `_rating > 0` — an aggregated 0.0 average is technically
    // possible. By the time this widget renders, the build() guard
    // has already waited for the async fallback (if it had to run)
    // to finish, so this value is final, no "empty → has-rating"
    // flash.
    final hasRating = _reviewCount > 0;
    final earnedFormatted =
        '₹${_inrFormatter.format(_totalEarnings.round())}';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _DashStatCard(
              icon: AppIcons.chat,
              iconColor: AppColors.primaryBrown,
              value: _totalSessions.toString(),
              label: 'Sessions',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _DashStatCard(
              icon: AppIcons.wallet,
              iconColor: AppColors.amberGold,
              value: earnedFormatted,
              label: 'Earned',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            // The rating stat doubles as the entry point to the
            // priest's reviews page. We tap-wrap unconditionally so
            // even the "No ratings yet" empty state opens the page —
            // a priest who hasn't been rated yet gets to see the
            // empty-state copy and understand what will appear here
            // once the first rating lands.
            child: _DashStatCard(
              icon: AppIcons.starFilled,
              iconColor: AppColors.amberGold,
              value: hasRating ? _rating.toStringAsFixed(1) : '',
              label: hasRating ? 'Rating' : '',
              isEmpty: !hasRating,
              emptyHint: 'No ratings yet',
              extra: hasRating ? _RatingStars(rating: _rating) : null,
              onTap: () => context.push('/priest/reviews'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionsRow() {
    // Icon foreground alternates between primaryBrown and amberGold
    // so the four tiles have visual rhythm rather than reading as a
    // single monochrome strip.
    final actions = <_QuickActionData>[
      _QuickActionData(
        icon: AppIcons.wallet,
        label: 'My Wallet',
        iconColor: AppColors.amberGold,
        onTap: () => context.push('/priest/wallet'),
      ),
      // My Users is the priest's primary relationship surface —
      // grouped by counterparty rather than by individual session.
      // No badge here: the dedicated _MissedRequestBanner above
      // surfaces the unread missed-request count.
      _QuickActionData(
        icon: AppIcons.users,
        label: 'My Users',
        iconColor: AppColors.primaryBrown,
        onTap: () => context.push('/priest/my-users'),
      ),
      _QuickActionData(
        icon: AppIcons.bible,
        label: 'Bible Sessions',
        iconColor: AppColors.amberGold,
        onTap: () => context.push('/priest/bible-sessions'),
      ),
      _QuickActionData(
        icon: AppIcons.settings,
        label: 'Settings',
        iconColor: AppColors.primaryBrown,
        onTap: () => context.push('/priest/settings'),
      ),
    ];

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            Expanded(
              child: _QuickAction(
                icon: actions[i].icon,
                label: actions[i].label,
                iconColor: actions[i].iconColor,
                onTap: actions[i].onTap,
              ),
            ),
            if (i < actions.length - 1) const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _QuickActionData {
  final IconData icon;
  final String label;
  final Color iconColor;
  final VoidCallback onTap;
  const _QuickActionData({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.onTap,
  });
}

// Quiet uppercase section label — sits above stats / quick actions.
// Tracked-out and muted so it reads as a divider, not a heading that
// competes with content titles below it.
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

// ─── Status card ───────────────────────────────────────────

// Sage green — used ONLY as a state signal on the online status card.
// Earthy, desaturated; sits next to the warm browns without clashing.
const Color _kSageGreen = Color(0xFF5A7A4F);

enum _StatusVariant { online, busy, offline, notActivated }

class _StatusCard extends StatelessWidget {
  final _StatusVariant variant;

  const _StatusCard({required this.variant});

  @override
  Widget build(BuildContext context) {
    if (variant == _StatusVariant.notActivated) {
      return const _NotActivatedStatusCard();
    }
    final spec = _specFor(variant);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: spec.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: spec.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: spec.dot,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        spec.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: spec.titleColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  spec.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: spec.glyphTint,
            ),
            child: AppIcon(
              spec.glyph,
              size: 26,
              color: spec.glyphColor,
            ),
          ),
        ],
      ),
    );
  }

  _StatusSpec _specFor(_StatusVariant v) {
    switch (v) {
      case _StatusVariant.online:
        // Sage green carries the "active" signal — dot, title text, and
        // broadcast icon all share it. Card bg gets a whisper of green
        // tint so the whole surface feels alive without shouting.
        return _StatusSpec(
          background: _kSageGreen.withValues(alpha: 0.05),
          border: _kSageGreen.withValues(alpha: 0.2),
          dot: _kSageGreen,
          titleColor: _kSageGreen,
          title: 'Online · Accepting requests',
          subtitle: 'Users can start chat or voice sessions',
          glyph: AppIcons.broadcast,
          glyphTint: _kSageGreen.withValues(alpha: 0.12),
          glyphColor: _kSageGreen,
        );
      case _StatusVariant.busy:
        return _StatusSpec(
          background: AppColors.surfaceWhite,
          border: AppColors.muted.withValues(alpha: 0.1),
          dot: AppColors.amberGold,
          titleColor: AppColors.primaryBrown,
          title: 'Busy · In a session',
          subtitle:
              'Active session in progress. New requests are paused.',
          glyph: AppIcons.hourglass,
          glyphTint: AppColors.amberGold.withValues(alpha: 0.15),
          glyphColor: AppColors.primaryBrown,
        );
      case _StatusVariant.offline:
        return _StatusSpec(
          background: AppColors.surfaceWhite,
          border: AppColors.muted.withValues(alpha: 0.1),
          dot: AppColors.muted.withValues(alpha: 0.5),
          titleColor: AppColors.primaryBrown,
          title: 'Offline · Not accepting requests',
          subtitle:
              "You're hidden from the user feed. Resume in Settings.",
          glyph: AppIcons.block,
          glyphTint: AppColors.muted.withValues(alpha: 0.12),
          glyphColor: AppColors.muted,
        );
      case _StatusVariant.notActivated:
        throw StateError('notActivated handled by dedicated widget');
    }
  }
}

class _StatusSpec {
  final Color background;
  final Color border;
  final Color dot;
  final Color titleColor;
  final String title;
  final String subtitle;
  final IconData glyph;
  final Color glyphTint;
  final Color glyphColor;
  const _StatusSpec({
    required this.background,
    required this.border,
    required this.dot,
    required this.titleColor,
    required this.title,
    required this.subtitle,
    required this.glyph,
    required this.glyphTint,
    required this.glyphColor,
  });
}

// Dedicated card for the not-activated state — keeps a soft surface
// look so it pairs cleanly with the activation CTA above. The dark
// status card variants don't fit a "not yet onboarded" state.
class _NotActivatedStatusCard extends StatelessWidget {
  const _NotActivatedStatusCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.muted.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Not Activated',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your account is approved but not yet activated. '
                  'Activate above to appear in the feed.',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
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

// ─── Stat card ─────────────────────────────────────────────

class _DashStatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;
  final Widget? extra;
  final bool isEmpty;
  final String? emptyHint;
  // Optional — when set, the card becomes tappable with the standard
  // press scale + haptic. Sessions and Earned tiles leave this null
  // (no destination yet); Rating uses it to open /priest/reviews.
  final VoidCallback? onTap;

  const _DashStatCard({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
    this.extra,
    this.isEmpty = false,
    this.emptyHint,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = _buildCard();
    if (onTap == null) return card;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap!();
      },
      child: card,
    );
  }

  Widget _buildCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: iconColor.withValues(alpha: 0.14),
            ),
            child: AppIcon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(height: 14),
          if (isEmpty)
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  emptyHint ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                    color: AppColors.muted,
                  ),
                ),
              ),
            )
          else ...[
            // FittedBox so "₹1,00,000"-class values don't ellipsis on
            // a 320px viewport where the per-card content area shrinks.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepDarkBrown,
                  height: 1.1,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
                color: AppColors.muted,
              ),
            ),
            if (extra != null) ...[
              const SizedBox(height: 8),
              extra!,
            ],
          ],
        ],
      ),
    );
  }
}

class _RatingStars extends StatelessWidget {
  final double rating;
  const _RatingStars({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final position = i + 1;
        final IconData icon;
        if (rating >= position) {
          icon = AppIcons.starFilled;
        } else if (rating >= position - 0.5) {
          icon = AppIcons.starHalf;
        } else {
          icon = AppIcons.starOutline;
        }
        return AppIcon(
          icon,
          size: 11,
          color: AppColors.amberGold,
        );
      }),
    );
  }
}

// ─── Quick action ──────────────────────────────────────────

class _QuickAction extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color iconColor;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.onTap,
  });

  @override
  State<_QuickAction> createState() => _QuickActionState();
}

class _QuickActionState extends State<_QuickAction> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.95),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            padding:
                const EdgeInsets.symmetric(vertical: 18, horizontal: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.08),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x08000000),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        widget.iconColor.withValues(alpha: 0.14),
                  ),
                  child: AppIcon(
                    widget.icon,
                    size: 22,
                    color: widget.iconColor,
                  ),
                ),
                const SizedBox(height: 12),
                // Fixed-height label area keeps all four tiles
                // perfectly symmetric whether the label is one line
                // ("Settings") or wraps to two ("Bible Sessions").
                SizedBox(
                  height: 30,
                  child: Center(
                    child: Text(
                      widget.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                        height: 1.25,
                        letterSpacing: 0.1,
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

// Compact missed-request banner that sits between the status card
// and the stats row. Three states:
//   • count == 0 → SizedBox.shrink (banner gone)
//   • count == 1 → "Asha tried to reach you" (single name)
//   • count >= 2 → "You missed N requests" (with count chip on icon)
//
// AnimatedSwitcher fades + size-tweens between states so the dashboard
// reflows smoothly when the count changes — no jump, no flicker. The
// outer ValueKey includes the count *and* requester name so going
// 1→1 with a different name (a fresh missed request lands while the
// previous one is still pending) still triggers the transition.
class _MissedRequestBanner extends StatefulWidget {
  final int count;
  final String requesterName;
  final VoidCallback onTap;

  const _MissedRequestBanner({
    required this.count,
    required this.requesterName,
    required this.onTap,
  });

  @override
  State<_MissedRequestBanner> createState() => _MissedRequestBannerState();
}

class _MissedRequestBannerState extends State<_MissedRequestBanner> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1.0,
            child: child,
          ),
        );
      },
      child: count <= 0
          ? const SizedBox.shrink(key: ValueKey('missed-empty'))
          : Listener(
              key: ValueKey('missed-$count-${widget.requesterName}'),
              onPointerDown: (_) => setState(() => _scale = 0.98),
              onPointerUp: (_) => setState(() => _scale = 1.0),
              onPointerCancel: (_) => setState(() => _scale = 1.0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.lightImpact();
                  widget.onTap();
                },
                child: AnimatedScale(
                  scale: _scale,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  child: _buildBanner(count),
                ),
              ),
            ),
    );
  }

  Widget _buildBanner(int count) {
    final isMulti = count >= 2;
    final title = isMulti
        ? 'You missed $count requests'
        : '${_displayName()} tried to reach you';
    final subtitle =
        isMulti ? 'Tap to view & respond' : 'Tap to respond';

    // Terra-cotta — semantic urgency color, in the same warm-red
    // family as the bell badge so the priest's "you missed something"
    // signal reads as one consistent system.
    const terraCotta = Color(0xFFB5523A);

    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.3),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: terraCotta.withValues(alpha: 0.12),
                  ),
                  child: const AppIcon(
                    AppIcons.phoneMissed,
                    size: 20,
                    color: terraCotta,
                  ),
                ),
                if (isMulti)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: terraCotta,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppColors.background,
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        count > 99 ? '99+' : '$count',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: terraCotta,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AppIcon(
            AppIcons.chevronRight,
            size: 20,
            color: terraCotta.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }

  // Trim a long name down to a single first-name token so the banner
  // doesn't ellipsis on a 320px viewport. Falls back to "Someone" for
  // the rare case the CF wrote an empty requesterName.
  String _displayName() {
    final raw = widget.requesterName.trim();
    if (raw.isEmpty) return 'Someone';
    final firstSpace = raw.indexOf(' ');
    if (firstSpace <= 0) return raw;
    return raw.substring(0, firstSpace);
  }
}

// Bell + live unread count for the priest dashboard header. Streams
// the notifications collection filtered by uid + isRead==false. We
// stream rather than `.count()`-aggregate because the inbox is small
// (≤50 unread realistically) and a stream gives instant feedback when
// a CF writes a new notification, without a manual refresh.
class _NotificationBell extends StatefulWidget {
  final String uid;
  const _NotificationBell({required this.uid});

  @override
  State<_NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<_NotificationBell> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: widget.uid)
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? 0;
        return Listener(
          onPointerDown: (_) => setState(() => _scale = 0.95),
          onPointerUp: (_) => setState(() => _scale = 1.0),
          onPointerCancel: (_) => setState(() => _scale = 1.0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.lightImpact();
              context.push('/priest/notifications');
            },
            child: AnimatedScale(
              scale: _scale,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceWhite,
                  border: Border.all(
                    color: AppColors.muted.withValues(alpha: 0.12),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0A000000),
                      blurRadius: 10,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    const AppIcon(
                      AppIcons.bellOutline,
                      size: 22,
                      color: AppColors.deepDarkBrown,
                    ),
                    if (count > 0)
                      Positioned(
                        top: 4,
                        right: 4,
                        // Growing-stadium terracotta badge — same
                        // recipe as the user-side home bell:
                        //   • minWidth == minHeight == 18 →
                        //     single-digit counts render as a perfect
                        //     circle (radius height/2 = 9 keeps the
                        //     ends fully round).
                        //   • As digits grow, horizontal padding lets
                        //     the container widen; the radius stays
                        //     constant so the badge morphs into a
                        //     stadium without overflowing.
                        //   • Counts >= 100 collapse to "99+" so the
                        //     badge never widens past ~30 px, keeping
                        //     a clean shape even at marketplace scale.
                        //   • AppColors.terraCotta == the same warm
                        //     desaturated red the user-side bell and
                        //     bottom-nav badge already use — one
                        //     visual system across both surfaces.
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: 18,
                            minHeight: 18,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.terraCotta,
                            borderRadius: BorderRadius.circular(9),
                            // White cutout border so the badge reads
                            // as "punched through" the bell circle
                            // behind it. Matches the surfaceWhite
                            // that the bell sits on (not the page bg
                            // — the bell is inside a white container,
                            // unlike the bare bell on the user side).
                            border: Border.all(
                              color: AppColors.surfaceWhite,
                              width: 1.5,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            count > 99 ? '99+' : '$count',
                            maxLines: 1,
                            softWrap: false,
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              height: 1.05,
                              // Tabular keeps digit widths constant
                              // so the morph from circle → pill stays
                              // smooth as counts roll over.
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
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
      },
    );
  }
}

// ─── Profile avatar ────────────────────────────────────────

class _ProfileAvatar extends StatefulWidget {
  final String photoUrl;
  final String fallbackLetter;
  final VoidCallback onTap;
  const _ProfileAvatar({
    required this.photoUrl,
    required this.fallbackLetter,
    required this.onTap,
  });

  @override
  State<_ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<_ProfileAvatar> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.95),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF7F5F2),
              border: Border.all(
                color: AppColors.amberGold.withValues(alpha: 0.3),
                width: 2,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 10,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.photoUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: widget.photoUrl,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => _initial(),
                    placeholder: (_, _) => const SizedBox.shrink(),
                  )
                : _initial(),
          ),
        ),
      ),
    );
  }

  Widget _initial() {
    return Center(
      child: Text(
        widget.fallbackLetter,
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

// ─── Manage availability card ──────────────────────────────

// Sits at the bottom of the dashboard when the priest is ONLINE.
// Tap navigates to /priest/settings — that page owns the actual
// isOnline=false write (and the resume-accepting flow). The
// dashboard never writes the toggle directly.
class _ManageAvailabilityCard extends StatefulWidget {
  final VoidCallback onTap;
  const _ManageAvailabilityCard({required this.onTap});

  @override
  State<_ManageAvailabilityCard> createState() =>
      _ManageAvailabilityCardState();
}

class _ManageAvailabilityCardState extends State<_ManageAvailabilityCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.1),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Decorative meditation glyph in a warm amber halo —
          // mirrors the "cross-on-hill / restful" illustration from
          // the reference design without needing a custom asset.
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.amberGold.withValues(alpha: 0.22),
                  AppColors.amberGold.withValues(alpha: 0.08),
                ],
              ),
            ),
            child: const AppIcon(
              AppIcons.prayer,
              size: 34,
              color: AppColors.primaryBrown,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Want to take a break?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Go offline and pause incoming requests.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 12),
                Listener(
                  onPointerDown: (_) => setState(() => _scale = 0.97),
                  onPointerUp: (_) => setState(() => _scale = 1.0),
                  onPointerCancel: (_) => setState(() => _scale = 1.0),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      widget.onTap();
                    },
                    child: AnimatedScale(
                      scale: _scale,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryBrown,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primaryBrown
                                  .withValues(alpha: 0.22),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const AppIcon(
                              AppIcons.pause,
                              size: 16,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            // Flexible + ellipsis so the button text
                            // gracefully shrinks/clips on a 320px
                            // phone with a large accessibility font
                            // setting instead of overflowing.
                            Flexible(
                              child: Text(
                                'Manage Availability',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                  letterSpacing: 0.1,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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

class _ActivationCta extends StatefulWidget {
  final VoidCallback onTap;
  const _ActivationCta({required this.onTap});

  @override
  State<_ActivationCta> createState() => _ActivationCtaState();
}

class _ActivationCtaState extends State<_ActivationCta> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryBrown.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(
              child: Text(
                // Label intentionally amount-free — the paywall page
                // shows the live fee from app_config so the dashboard
                // copy doesn't drift if admin changes it.
                'Activate Now',
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
