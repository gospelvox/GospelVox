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

import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';

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
      setState(() {
        _fullName = data['fullName'] as String? ?? '';
        _photoUrl = data['photoUrl'] as String? ?? '';
        _isOnline = data['isOnline'] as bool? ?? false;
        _isBusy = data['isBusy'] as bool? ?? false;
        _isActivated = data['isActivated'] as bool? ?? false;
        _totalSessions = (data['totalSessions'] as num?)?.toInt() ?? 0;
        _totalEarnings = (data['totalEarnings'] as num?)?.toDouble() ?? 0.0;
        _rating = (data['rating'] as num?)?.toDouble() ?? 0.0;
        _loading = false;
      });

      // Auto-online runs ONLY:
      //   • on the first activated snapshot of this dashboard mount
      //     (the "open the app → become available" intent), OR
      //   • when activation transitions false→true (priest just
      //     finished the activation flow).
      // Crucially, this does NOT re-fire whenever a later snapshot
      // shows isOnline=false. Without that guard, the priest's
      // manual Go-Offline toggle would be overwritten within ~1s
      // because writing isOnline=false produces a snapshot that
      // satisfies the old condition and re-onlines them.
      final activationJustEnabled = !wasActivated && _isActivated;
      if (_isActivated &&
          (!_didInitialAutoOnline || activationJustEnabled)) {
        _didInitialAutoOnline = true;
        _goOnlineIfEligible();
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

  // ─── Build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  color: AppColors.primaryBrown,
                  strokeWidth: 2.5,
                ),
              )
            : SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    _buildHeader(),
                    const SizedBox(height: 24),
                    if (!_isActivated) ...[
                      _buildActivationCta(),
                      const SizedBox(height: 20),
                    ],
                    _MissedRequestBanner(
                      count: _missedRequestCount,
                      requesterName: _missedRequesterName,
                      onTap: () => context.push('/priest/missed-requests'),
                    ),
                    _StatusCard(variant: _statusVariant),
                    const SizedBox(height: 20),
                    _buildStatsRow(),
                    const SizedBox(height: 24),
                    Text(
                      'QUICK ACTIONS',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildQuickActionsGrid(),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildHeader() {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _getGreeting(),
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _getDisplayName(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ],
          ),
        ),
        if (uid != null) ...[
          _NotificationBell(uid: uid),
          const SizedBox(width: 12),
        ],
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push('/priest/profile'),
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
            ),
            clipBehavior: Clip.antiAlias,
            child: _photoUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: _photoUrl,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => _headerInitial(),
                    placeholder: (_, _) => const SizedBox.shrink(),
                  )
                : _headerInitial(),
          ),
        ),
      ],
    );
  }

  Widget _headerInitial() {
    final source = _getDisplayName();
    final letter = source.isNotEmpty ? source[0].toUpperCase() : '?';
    return Center(
      child: Text(
        letter,
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
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
                child: Icon(
                  Icons.lock_open_rounded,
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
    return Row(
      children: [
        Expanded(
          child: _DashStatCard(
            label: 'Sessions',
            value: _totalSessions.toString(),
            icon: Icons.chat_bubble_outline_rounded,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _DashStatCard(
            label: 'Earned',
            value: '₹${_totalEarnings.toStringAsFixed(0)}',
            icon: Icons.account_balance_wallet_outlined,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _DashStatCard(
            label: 'Rating',
            value: _rating > 0 ? _rating.toStringAsFixed(1) : '—',
            icon: Icons.star_outline_rounded,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActionsGrid() {
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.6,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _QuickAction(
          icon: Icons.account_balance_wallet_outlined,
          title: 'My Wallet',
          onTap: () => context.push('/priest/wallet'),
        ),
        _QuickAction(
          icon: Icons.person_outline,
          title: 'My Profile',
          onTap: () => context.push('/priest/profile'),
        ),
        // My Users is the priest's primary relationship surface —
        // grouped by counterparty rather than by individual session
        // so they think in PEOPLE, not transactions. Old session-
        // history route remains reachable via deep link / settings.
        //
        // No badge here: the dedicated _MissedRequestBanner above
        // the status card surfaces the unread missed-request count.
        // Showing the same number twice on one screen was confusing.
        _QuickAction(
          icon: Icons.forum_outlined,
          title: 'My Users',
          onTap: () => context.push('/priest/my-users'),
        ),
        _QuickAction(
          icon: Icons.menu_book_outlined,
          title: 'Bible Sessions',
          onTap: () => context.push('/priest/bible-sessions'),
        ),
        _QuickAction(
          icon: Icons.settings_outlined,
          title: 'Settings',
          onTap: () => context.push('/priest/settings'),
        ),
      ],
    );
  }
}

// ─── Read-only status card ─────────────────────────────────

enum _StatusVariant { online, busy, offline, notActivated }

class _StatusCard extends StatelessWidget {
  final _StatusVariant variant;

  const _StatusCard({required this.variant});

  @override
  Widget build(BuildContext context) {
    final spec = _specFor(variant);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: spec.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: spec.border),
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
              color: spec.dot,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.title,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: spec.titleColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  spec.subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                    color: AppColors.muted,
                  ),
                ),
                if (variant == _StatusVariant.online ||
                    variant == _StatusVariant.busy) ...[
                  const SizedBox(height: 10),
                  Text(
                    variant == _StatusVariant.busy
                        ? 'Manage in Settings → Pause / Stop Accepting.'
                        : 'Manage availability in Settings.',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppColors.muted.withValues(alpha: 0.8),
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

  _StatusSpec _specFor(_StatusVariant v) {
    switch (v) {
      case _StatusVariant.online:
        return _StatusSpec(
          title: 'Online · Accepting requests',
          subtitle: 'Users can start chat or voice sessions with you '
              'right now.',
          dot: const Color(0xFF2E7D4F),
          titleColor: const Color(0xFF2E7D4F),
          background: const Color(0xFF2E7D4F).withValues(alpha: 0.06),
          border: const Color(0xFF2E7D4F).withValues(alpha: 0.18),
        );
      case _StatusVariant.busy:
        return _StatusSpec(
          title: 'Busy · Requests paused',
          subtitle: "You're still on the platform — users see you as "
              'Busy. Active sessions continue normally.',
          dot: AppColors.amberGold,
          titleColor: AppColors.amberGold,
          background: AppColors.amberGold.withValues(alpha: 0.1),
          border: AppColors.amberGold.withValues(alpha: 0.3),
        );
      case _StatusVariant.offline:
        return _StatusSpec(
          title: 'Offline · Not accepting requests',
          subtitle: "You're hidden from the user feed. Tap Resume "
              'Accepting in Settings to come back online.',
          dot: AppColors.muted.withValues(alpha: 0.5),
          titleColor: AppColors.deepDarkBrown,
          background: AppColors.surfaceWhite,
          border: AppColors.muted.withValues(alpha: 0.15),
        );
      case _StatusVariant.notActivated:
        return _StatusSpec(
          title: 'Not Activated',
          subtitle: 'Your account is approved but not yet activated. '
              'Activate above to appear in the feed.',
          dot: AppColors.muted.withValues(alpha: 0.4),
          titleColor: AppColors.deepDarkBrown,
          background: AppColors.surfaceWhite,
          border: AppColors.muted.withValues(alpha: 0.1),
        );
    }
  }
}

class _StatusSpec {
  final String title;
  final String subtitle;
  final Color dot;
  final Color titleColor;
  final Color background;
  final Color border;

  _StatusSpec({
    required this.title,
    required this.subtitle,
    required this.dot,
    required this.titleColor,
    required this.background,
    required this.border,
  });
}

// ─── Stat + action card widgets ────────────────────────────

class _DashStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _DashStatCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Icon(
            icon,
            size: 20,
            color: AppColors.primaryBrown.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatefulWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.title,
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
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color:
                        AppColors.primaryBrown.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    widget.icon,
                    size: 18,
                    color:
                        AppColors.primaryBrown.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
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

// Compact missed-request banner that sits between the greeting
// and the status card. Three states:
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
          : Padding(
              key: ValueKey('missed-$count-${widget.requesterName}'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Listener(
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.amberGold.withValues(alpha: 0.12),
            AppColors.amberGold.withValues(alpha: 0.06),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          // Phone-missed circle — with a count chip when there are
          // multiple. Stack overhang is small (only 2px) so the
          // banner's vertical bounds aren't blown out.
          SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.amberGold.withValues(alpha: 0.15),
                  ),
                  child: Icon(
                    Icons.phone_missed_rounded,
                    size: 18,
                    color: AppColors.amberGold,
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
                        color: AppColors.amberGold,
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
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: AppColors.amberGold.withValues(alpha: 0.5),
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
class _NotificationBell extends StatelessWidget {
  final String uid;
  const _NotificationBell({required this.uid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? 0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push('/priest/notifications'),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFF7F5F2),
                    border: Border.all(
                      color: AppColors.muted.withValues(alpha: 0.15),
                    ),
                  ),
                  child: const Icon(
                    Icons.notifications_none_rounded,
                    size: 20,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                if (count > 0)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 16,
                        minHeight: 16,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: AppColors.errorRed,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppColors.background,
                          width: 1.5,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          count > 9 ? '9+' : '$count',
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
