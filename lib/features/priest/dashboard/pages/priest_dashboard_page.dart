// Priest dashboard — home surface for an approved priest.
//
// Availability model (important — this is the authoritative flow):
//
//   • Online is AUTOMATIC. App foregrounded & priest is activated
//     ⇒ isOnline=true. App paused for 2 minutes ⇒ isOnline=false.
//     There is NO manual online/offline toggle anywhere in the app.
//
//   • Busy is MANUAL and set in Settings > Pause Requests. A busy
//     priest is still online (they can finish ongoing work) but
//     users see them as "Busy" and can't start new sessions. The
//     dashboard reflects the current state; the actual toggle lives
//     on the Settings page so the dashboard stays focused on
//     read-only status + quick actions.
//
//   • A 30-second heartbeat runs while online so a Cloud Function
//     watchdog can kick stale priests when the app is force-killed
//     instead of gracefully backgrounded.
//
//   • Unactivated priests do NOT auto-go-online. An activation CTA
//     sits at the top of the dashboard until they activate; the
//     status card reads "Not Activated" with explanation.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

class PriestDashboardPage extends StatefulWidget {
  const PriestDashboardPage({super.key});

  @override
  State<PriestDashboardPage> createState() => _PriestDashboardPageState();
}

class _PriestDashboardPageState extends State<PriestDashboardPage>
    with WidgetsBindingObserver {
  Timer? _heartbeatTimer;
  Timer? _offlineGraceTimer;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachDocStream();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    _offlineGraceTimer?.cancel();
    _docSub?.cancel();
    // Best-effort mark offline on unmount. Fire-and-forget is
    // intentional — if the widget is gone the priest is gone, and
    // the watchdog CF catches anything this write misses.
    _markOffline();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _startOfflineGrace();
    } else if (state == AppLifecycleState.resumed) {
      _cancelOfflineGrace();
      _goOnlineIfEligible();
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

      // First snapshot (or activation just flipped on): attempt to
      // go online. Skipping the initial snapshot would leave a
      // freshly-resumed priest offline until the next lifecycle
      // event fires.
      if (_isActivated && (!wasActivated || !_isOnline)) {
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

  // ─── Automatic online/offline lifecycle ───────────────────

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

  Future<void> _markOffline() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance.doc('priests/$uid').update({
        'isOnline': false,
      });
    } catch (_) {
      // Same logic as _goOnlineIfEligible — swallow, watchdog is
      // the authoritative safety net.
    }
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

  void _startOfflineGrace() {
    _offlineGraceTimer?.cancel();
    // 2 minutes of grace so a quick app switch doesn't drop us from
    // the feed — users would see a priest flicker out and back in
    // every time the priest reads a notification.
    _offlineGraceTimer = Timer(const Duration(minutes: 2), () async {
      await _markOffline();
      _heartbeatTimer?.cancel();
    });
  }

  void _cancelOfflineGrace() {
    _offlineGraceTimer?.cancel();
    _offlineGraceTimer = null;
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
    if (_isOnline && _isBusy) return _StatusVariant.busy;
    if (_isOnline) return _StatusVariant.online;
    // Shouldn't normally land here while dashboard is mounted — lifecycle
    // observer will flip isOnline=true within a few hundred ms of resume.
    return _StatusVariant.offline;
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
            'Pay a one-time ₹500 fee to appear in the user feed '
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
                    'Manage availability in Settings → Pause Requests.',
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
          title: "You're Online",
          subtitle: 'Users can start chat or voice sessions with you '
              'right now.',
          dot: const Color(0xFF2E7D4F),
          titleColor: const Color(0xFF2E7D4F),
          background: const Color(0xFF2E7D4F).withValues(alpha: 0.06),
          border: const Color(0xFF2E7D4F).withValues(alpha: 0.18),
        );
      case _StatusVariant.busy:
        return _StatusSpec(
          title: "You're Busy",
          subtitle: "You're online, but requests are paused. Existing "
              'conversations still work.',
          dot: AppColors.amberGold,
          titleColor: AppColors.amberGold,
          background: AppColors.amberGold.withValues(alpha: 0.1),
          border: AppColors.amberGold.withValues(alpha: 0.3),
        );
      case _StatusVariant.offline:
        return _StatusSpec(
          title: 'Reconnecting…',
          subtitle: 'Your status is syncing. If this persists, check '
              'your connection.',
          dot: AppColors.muted.withValues(alpha: 0.4),
          titleColor: AppColors.deepDarkBrown,
          background: AppColors.surfaceWhite,
          border: AppColors.muted.withValues(alpha: 0.1),
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
        onTap: widget.onTap,
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
                    color: AppColors.primaryBrown.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    widget.icon,
                    size: 18,
                    color: AppColors.primaryBrown.withValues(alpha: 0.6),
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
                'Activate for ₹500',
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
