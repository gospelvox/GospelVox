// Dedicated full-screen list of unread missed-request notifications,
// grouped by requester so a user who tried 3 times shows up as ONE
// card with a count badge — not three separate cards.
//
// Reachable from:
//   • Dashboard amber banner tap
//   • Foreground in-app banner tap (via FCM message)
//   • Background / terminated FCM tap (route override in
//     NotificationService for type=missed_request)
//   • Priest notifications inbox row tap
//
// Behavior of acting on a card:
//   • Quick reply ("I'm available, [name]"): fires sendPriestMessage
//     CF for the user, then BATCH-marks every unread missed_request
//     for that requesterId as read. C5: one tap clears all attempts
//     from one user, prevents the priest from ever sending a
//     duplicate message to a repeat caller.
//   • Edit (custom compose): marks the missed_request read FIRST
//     (C4 — opening the chat counts as handling it), THEN navigates
//     to priest chat. If the priest types nothing and bails, the
//     card is gone but they can find the user in My Users.
//   • Dismiss with reason: same batch-clear-by-requesterId.
//   • Clear All: batch-marks every visible card.
//
// Stream + AnimatedList wiring:
//   StreamSubscription pushes raw notifications, we group by
//   requesterId in-place, then diff prev↔next groups (keyed by
//   requesterId) against the AnimatedList. Removals get a slide-up
//   + fade animation; insertions get the same animation reversed.
//
// Error handling:
//   The stream's onError flips _hasError. The empty list and the
//   error list are visually distinct (E3): empty = green check
//   "All caught up", error = brown "Couldn't load. Tap to retry"
//   so a missing composite index doesn't masquerade as success.
//
// App lifecycle:
//   On app resume the stream is re-attached (E5). The 24h cutoff
//   used by the dashboard banner doesn't apply here — this page
//   shows the priest's full unread backlog regardless of age —
//   so resume only matters for picking up the freshest server
//   data, which it does naturally via re-subscription.

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/notifications/data/notification_model.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';

class MissedRequestsPage extends StatefulWidget {
  const MissedRequestsPage({super.key});

  @override
  State<MissedRequestsPage> createState() => _MissedRequestsPageState();
}

// In-memory shape representing one card on the page — possibly
// backed by multiple notification docs for the same requester.
// Keyed by requesterId for diff purposes.
class _MissedGroup {
  final String requesterId;
  final String requesterName;
  final String requesterPhotoUrl;
  // Most-recent attempt's session type — drives "Missed call" vs
  // "Missed chat" copy on the single-attempt variant.
  final String latestSessionType;
  // Most-recent attempt's createdAt.
  final DateTime? latestAt;
  // Number of unread missed_request notifications the priest has
  // received from this requester. >= 1 by construction.
  final int count;
  // Backing notification ids — used at action time to batch-mark
  // every related doc as read (C5).
  final List<String> notificationIds;

  const _MissedGroup({
    required this.requesterId,
    required this.requesterName,
    required this.requesterPhotoUrl,
    required this.latestSessionType,
    required this.latestAt,
    required this.count,
    required this.notificationIds,
  });

  String get timeAgo {
    final ts = latestAt;
    if (ts == null) return '';
    final diff = DateTime.now().difference(ts);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final d = ts.day.toString().padLeft(2, '0');
    final m = ts.month.toString().padLeft(2, '0');
    return '$d/$m/${ts.year}';
  }

  String get firstName {
    final raw = requesterName.trim();
    if (raw.isEmpty) return '';
    final spaceIdx = raw.indexOf(' ');
    return spaceIdx > 0 ? raw.substring(0, spaceIdx) : raw;
  }
}

class _MissedRequestsPageState extends State<MissedRequestsPage>
    with WidgetsBindingObserver {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  bool _loading = true;
  bool _hasError = false;

  // Source of truth for what the AnimatedList currently shows.
  List<_MissedGroup> _groups = const [];

  // Notifications mid-flight (sending a quick reply, dismissing,
  // bulk-clearing). Disables card interactions to prevent double-fire.
  final Set<String> _busyRequesterIds = <String>{};
  bool _clearingAll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachStream();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  // E5: re-attach the stream when the app comes back from
  // background. A fresh subscription drops any stale cache and
  // pulls the latest server state — important if the priest was
  // offline for a while and missed_request docs landed in the
  // meantime.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sub?.cancel();
      _attachStream();
    }
  }

  void _attachStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() {
        _loading = false;
        _hasError = false;
      });
      return;
    }

    setState(() {
      _hasError = false;
      // Don't flip _loading=true on re-attach — the existing list is
      // valid until the new stream emits. Prevents flicker on resume.
      if (_groups.isEmpty) _loading = true;
    });

    _sub = FirebaseFirestore.instance
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .where('type', isEqualTo: 'missed_request')
        .where('isRead', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .listen(_onSnapshot, onError: (e, st) {
      debugPrint('[MissedRequests] stream failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _hasError = true;
      });
    });
  }

  // C2 fix: diff prev=[] against next=[A,B,C] on the first emission
  // exactly like every subsequent emission. The AnimatedList mounts
  // with initialItemCount: 0, the diff emits 3 insertItem calls, and
  // the count converges naturally. The previous code pre-populated
  // _groups before scheduling inserts, which double-counted slots.
  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;

    final next = _groupNotifications(
      snap.docs.map((d) => NotificationModel.fromFirestore(d.id, d.data())),
    );

    if (_loading) {
      // Flip out of shimmer first, let AnimatedList mount with
      // initialItemCount: 0, THEN diff against the fresh data on the
      // next frame. This sequence is what avoids the C2 doubled-slot
      // bug — never set _groups before the AnimatedList builds.
      setState(() {
        _loading = false;
        _hasError = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _diffAndApply(next);
      });
      return;
    }
    _diffAndApply(next);
  }

  // Group missed_request notifications by requesterId. Multiple
  // attempts from one user become one card; single attempts pass
  // through. Source list is already createdAt desc, so the first
  // notification per requester is the latest.
  List<_MissedGroup> _groupNotifications(
    Iterable<NotificationModel> notifs,
  ) {
    final byRequester = <String, List<NotificationModel>>{};
    for (final n in notifs) {
      final id = n.requesterId;
      if (id == null || id.isEmpty) continue;
      byRequester.putIfAbsent(id, () => []).add(n);
    }

    final groups = <_MissedGroup>[];
    for (final entry in byRequester.entries) {
      final list = entry.value;
      // The query is already createdAt desc, so list[0] is latest.
      final latest = list.first;
      // Display name + photo from the latest attempt — the user may
      // have updated their name between attempts; the freshest
      // value is the most accurate.
      groups.add(_MissedGroup(
        requesterId: entry.key,
        requesterName: latest.requesterName ?? '',
        requesterPhotoUrl: latest.requesterPhotoUrl ?? '',
        latestSessionType: latest.sessionType ?? 'chat',
        latestAt: latest.createdAt,
        count: list.length,
        notificationIds: list.map((n) => n.id).toList(),
      ));
    }

    // Most-recent attempt first across groups.
    groups.sort((a, b) {
      final aT = a.latestAt ?? DateTime(2000);
      final bT = b.latestAt ?? DateTime(2000);
      return bT.compareTo(aT);
    });
    return groups;
  }

  void _diffAndApply(List<_MissedGroup> next) {
    final prev = _groups;
    final prevIds = {for (var i = 0; i < prev.length; i++) prev[i].requesterId: i};
    final nextIds = {for (var i = 0; i < next.length; i++) next[i].requesterId: i};

    // Removals walked descending so each remove doesn't shift
    // pending-remove indices.
    final removed = <int>[];
    for (var i = prev.length - 1; i >= 0; i--) {
      if (!nextIds.containsKey(prev[i].requesterId)) removed.add(i);
    }
    for (final i in removed) {
      final removingItem = prev[i];
      _listKey.currentState?.removeItem(
        i,
        (context, animation) => SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1.0,
          child: FadeTransition(
            opacity: animation,
            child: _MissedRequestCard(
              group: removingItem,
              isBusy: false,
              onAvailable: () {},
              onType: () {},
              onDismiss: () {},
            ),
          ),
        ),
        duration: const Duration(milliseconds: 280),
      );
    }

    // Insertions walked ascending so earlier indices land first.
    for (var i = 0; i < next.length; i++) {
      if (!prevIds.containsKey(next[i].requesterId)) {
        _listKey.currentState?.insertItem(
          i,
          duration: const Duration(milliseconds: 240),
        );
      }
    }

    setState(() => _groups = next);
  }

  // ─── Quick reply ────────────────────────────────────────────

  Future<void> _sendQuickReply(_MissedGroup g) async {
    if (g.requesterId.isEmpty) return;
    if (_busyRequesterIds.contains(g.requesterId)) return;

    final isMulti = g.count >= 2;
    final firstName = g.firstName;
    final greeting = firstName.isNotEmpty ? firstName : 'there';

    final message = isMulti
        ? "Hi $greeting, I'm sorry I missed you. I'm available now — "
            "let's connect whenever you're ready."
        : "Hi $greeting, I'm available now if you'd like to connect. "
            'Feel free to reach out.';

    HapticFeedback.mediumImpact();
    setState(() => _busyRequesterIds.add(g.requesterId));

    try {
      // C3 fix: do the CF call FIRST. If it succeeds, the message is
      // sent — period. The downstream isRead update is bookkeeping;
      // its failure must NEVER cause us to claim the message wasn't
      // sent. Previously a Firestore timeout right after a successful
      // CF call would surface "Couldn't send" and the priest would
      // tap again, double-billing the user's daily-message limit.
      final result = await sl<SessionRepository>().sendPriestMessage(
        userId: g.requesterId,
        text: message,
      );

      if (!mounted) return;
      HapticFeedback.lightImpact();
      if (!result.delivered) {
        AppSnackBar.error(
          context,
          "Message saved but couldn't be delivered — the user may have "
              'turned off messages from you.',
        );
      } else {
        AppSnackBar.success(context, 'Message sent.');
      }

      // C5: batch-clear EVERY unread missed_request from this user,
      // not just the one card. Done unawaited so a slow Firestore
      // write doesn't hold up the success snackbar; failure is
      // logged but never bubbled — the stream tick on success will
      // remove the card, on failure the priest can re-tap "I'm
      // available" and the dedupe-by-message-text downstream is
      // their problem (we can't prevent every duplicate here).
      unawaited(_markAllForRequesterRead(g));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      AppSnackBar.error(context, _humaniseSendError(e));
    } on TimeoutException {
      if (!mounted) return;
      AppSnackBar.error(context, 'Send timed out. Try again.');
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't send. Try again.");
    } finally {
      if (mounted) {
        setState(() => _busyRequesterIds.remove(g.requesterId));
      }
    }
  }

  // C5: marks every backing notification doc for one requester as
  // read in a single batch. Same payload regardless of action
  // (quick reply / dismiss) — the action's own dismissReason is
  // applied separately by the dismiss path before this fires.
  Future<void> _markAllForRequesterRead(
    _MissedGroup g, {
    Map<String, dynamic>? extraFields,
  }) async {
    try {
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      for (final id in g.notificationIds) {
        batch.update(db.doc('notifications/$id'), {
          'isRead': true,
          if (extraFields != null) ...extraFields,
        });
      }
      await batch.commit().timeout(const Duration(seconds: 6));
    } catch (e, st) {
      debugPrint('[MissedRequests] batch read-flip failed: $e\n$st');
    }
  }

  String _humaniseSendError(FirebaseFunctionsException e) {
    final reason = '${e.code} ${e.message ?? ''}';
    if (reason.contains('Activate your account')) {
      return 'Activate your account before sending messages.';
    }
    if (reason.contains('Only approved speakers')) {
      return 'Only approved speakers can send messages.';
    }
    if (reason.contains('only message users')) {
      return "You can only message users you've had a session with.";
    }
    if (reason.contains('Daily message limit')) {
      return "You've hit your daily limit (15 messages per day).";
    }
    if (reason.contains('Daily limit per user')) {
      return "You've hit the daily limit for this user (3 per day).";
    }
    return "Couldn't send. Try again.";
  }

  // C4 fix: mark the missed_request notifications read BEFORE
  // navigating to chat. The priest's intent on tapping the edit
  // pencil is "I'm handling this now" — so the inbox should
  // reflect that immediately even if they end up not actually
  // sending anything. They can always reach the user again
  // through My Users if they change their mind.
  Future<void> _openCustomCompose(_MissedGroup g) async {
    if (g.requesterId.isEmpty) {
      AppSnackBar.error(context, 'Missing user — try refreshing.');
      return;
    }
    HapticFeedback.lightImpact();

    // Fire-and-forget — the navigation should happen even if the
    // batch update is slow. The stream will reconcile.
    unawaited(_markAllForRequesterRead(g, extraFields: {
      'dismissReason': 'custom_reply_opened',
      'dismissedAt': FieldValue.serverTimestamp(),
    }));

    if (!mounted) return;
    context.push(
      '/priest/chat/${g.requesterId}',
      extra: <String, dynamic>{
        'userName': g.requesterName,
        'userPhotoUrl': g.requesterPhotoUrl,
      },
    );
  }

  // ─── Dismiss ────────────────────────────────────────────────

  Future<void> _showDismissSheet(_MissedGroup g) async {
    HapticFeedback.lightImpact();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Dismiss this request?',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 16),
                _DismissOption(
                  icon: Icons.schedule_rounded,
                  text: 'I was busy, will respond later',
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _dismiss(g, 'busy');
                  },
                ),
                const SizedBox(height: 8),
                _DismissOption(
                  icon: Icons.check_circle_outline_rounded,
                  text: 'Already contacted them',
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _dismiss(g, 'contacted');
                  },
                ),
                const SizedBox(height: 8),
                _DismissOption(
                  icon: Icons.not_interested_rounded,
                  text: 'Not able to help right now',
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _dismiss(g, 'unavailable');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _dismiss(_MissedGroup g, String reason) async {
    if (_busyRequesterIds.contains(g.requesterId)) return;
    HapticFeedback.lightImpact();
    setState(() => _busyRequesterIds.add(g.requesterId));
    try {
      // Same C5 batch path — clears all attempts from this user in
      // one write, with the dismiss reason stamped on every doc.
      await _markAllForRequesterRead(g, extraFields: {
        'dismissReason': reason,
        'dismissedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't dismiss. Try again.");
    } finally {
      if (mounted) {
        setState(() => _busyRequesterIds.remove(g.requesterId));
      }
    }
  }

  // ─── Clear all ──────────────────────────────────────────────

  Future<void> _showClearAllSheet() async {
    HapticFeedback.lightImpact();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Clear all missed requests?',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  "You can still find these users in My Users — "
                  'this only clears the missed-request reminders.',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _SheetButton(
                        label: 'Cancel',
                        filled: false,
                        onTap: () => Navigator.of(sheetCtx).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SheetButton(
                        label: 'Clear All',
                        filled: true,
                        onTap: () => Navigator.of(sheetCtx).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (confirmed != true) return;
    await _clearAll();
  }

  Future<void> _clearAll() async {
    if (_clearingAll || _groups.isEmpty) return;
    setState(() => _clearingAll = true);
    HapticFeedback.mediumImpact();
    try {
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      for (final g in _groups) {
        for (final id in g.notificationIds) {
          batch.update(db.doc('notifications/$id'), {
            'isRead': true,
            'dismissReason': 'cleared_all',
            'dismissedAt': FieldValue.serverTimestamp(),
          });
        }
      }
      await batch.commit().timeout(const Duration(seconds: 10));
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't clear. Try again.");
    } finally {
      if (mounted) setState(() => _clearingAll = false);
    }
  }

  // ─── Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasItems = !_loading && !_hasError && _groups.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        leadingWidth: 60,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => context.pop(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceWhite,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                Icons.arrow_back_ios_new,
                size: 16,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
        ),
        title: Text(
          'Missed Requests',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        actions: [
          if (hasItems)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _clearingAll ? null : _showClearAllSheet,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 20, 0),
                child: Center(
                  child: Text(
                    'Clear All',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _clearingAll
                          ? AppColors.muted.withValues(alpha: 0.4)
                          : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const _MissedRequestsShimmer();
    if (_hasError) {
      return _ErrorState(onRetry: () {
        _sub?.cancel();
        _attachStream();
      });
    }
    if (_groups.isEmpty) return const _EmptyMissedRequests();

    return AnimatedList(
      key: _listKey,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 100),
      initialItemCount: _groups.length,
      itemBuilder: (context, index, animation) {
        if (index >= _groups.length) return const SizedBox.shrink();
        final g = _groups[index];
        return SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1.0,
          child: FadeTransition(
            opacity: animation,
            child: _MissedRequestCard(
              key: ValueKey(g.requesterId),
              group: g,
              isBusy:
                  _busyRequesterIds.contains(g.requesterId) || _clearingAll,
              onAvailable: () => _sendQuickReply(g),
              onType: () => _openCustomCompose(g),
              onDismiss: () => _showDismissSheet(g),
            ),
          ),
        );
      },
    );
  }
}

// ─── Card ──────────────────────────────────────────────────────

class _MissedRequestCard extends StatefulWidget {
  final _MissedGroup group;
  final bool isBusy;
  final VoidCallback onAvailable;
  final VoidCallback onType;
  final VoidCallback onDismiss;

  const _MissedRequestCard({
    super.key,
    required this.group,
    required this.isBusy,
    required this.onAvailable,
    required this.onType,
    required this.onDismiss,
  });

  @override
  State<_MissedRequestCard> createState() => _MissedRequestCardState();
}

class _MissedRequestCardState extends State<_MissedRequestCard> {
  double _scale = 1.0;

  // Stable per-card pick into the motivational tip pool. requesterId
  // is invariant for the lifetime of this card so picks don't
  // flicker on every rebuild.
  static const _singleTips = <String>[
    'Responding quickly increases repeat sessions by 3x',
    'A short message can bring them back',
    'Your words can make someone\'s day better',
    'Quick responses build trust with your community',
  ];

  static const _multiTips = <String>[
    "{name} really needs your guidance. A quick message means a lot!",
    "{name} has been trying to reach you. They're waiting for your response.",
    'This person clearly values your counsel. Don\'t miss this connection!',
  ];

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final firstName = g.firstName.isNotEmpty ? g.firstName : 'them';
    final isMulti = g.count >= 2;
    final initial = g.requesterName.trim().isNotEmpty
        ? g.requesterName.trim()[0].toUpperCase()
        : '?';
    final isVoice = g.latestSessionType == 'voice';
    final typeLabel = isVoice ? 'call' : 'chat';
    final typeIcon = isVoice
        ? Icons.phone_missed_rounded
        : Icons.chat_bubble_outline_rounded;

    // Subtitle copy diverges by attempt count.
    final attemptLine = isMulti
        ? 'Tried to reach you ${g.count} times'
        : 'Missed $typeLabel · ${g.timeAgo}';
    final secondaryLine =
        isMulti ? 'Last attempt: ${g.timeAgo}' : null;

    final tip = _pickTip(g, firstName);
    final primaryLabel = isMulti
        ? "I'm here, $firstName! 🙏"
        : "I'm available, $firstName";

    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.98),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.amberGold.withValues(alpha: 0.25),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.amberGold.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.amberGold,
                      AppColors.amberGold.withValues(alpha: 0.3),
                    ],
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Avatar with optional red count badge for
                        // multi-attempt cards.
                        SizedBox(
                          width: 52,
                          height: 52,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _Avatar(
                                photoUrl: g.requesterPhotoUrl,
                                initial: initial,
                              ),
                              if (isMulti)
                                Positioned(
                                  top: -4,
                                  right: -4,
                                  child: Container(
                                    constraints:
                                        const BoxConstraints(minWidth: 20),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.errorRed,
                                      borderRadius:
                                          BorderRadius.circular(10),
                                      border: Border.all(
                                        color: AppColors.surfaceWhite,
                                        width: 2,
                                      ),
                                    ),
                                    child: Text(
                                      g.count > 99 ? '99+' : '${g.count}',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
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
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 2),
                              Text(
                                g.requesterName.isNotEmpty
                                    ? g.requesterName
                                    : 'User',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.deepDarkBrown,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  Icon(
                                    typeIcon,
                                    size: 13,
                                    color: AppColors.amberGold,
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      attemptLine,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.inter(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.amberGold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (secondaryLine != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  secondaryLine,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w400,
                                    color:
                                        AppColors.muted.withValues(alpha: 0.75),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        _DismissButton(
                          onTap: widget.isBusy ? null : widget.onDismiss,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.amberGold.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline_rounded,
                            size: 14,
                            color: AppColors.amberGold.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tip,
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w400,
                                height: 1.3,
                                color: AppColors.amberGold
                                    .withValues(alpha: 0.78),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _PrimaryButton(
                            label: primaryLabel,
                            onTap: widget.isBusy ? null : widget.onAvailable,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _SecondaryIconButton(
                          icon: Icons.edit_outlined,
                          onTap: widget.isBusy ? null : widget.onType,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Stable across rebuilds: hashes the requesterId + count so the
  // tip stays the same for a single card session, but a NEW card
  // (different requesterId) gets a different tip — and a card that
  // gains more attempts (count change) re-rolls into the multi
  // pool with personalized text.
  String _pickTip(_MissedGroup g, String firstName) {
    final pool = g.count >= 2 ? _multiTips : _singleTips;
    final seed = g.requesterId.hashCode ^ g.count.hashCode;
    final idx = (seed.abs()) % pool.length;
    final raw = pool[math.min(idx, pool.length - 1)];
    return raw.replaceAll('{name}', firstName);
  }
}

class _Avatar extends StatelessWidget {
  final String photoUrl;
  final String initial;
  const _Avatar({required this.photoUrl, required this.initial});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFF7F5F2),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: photoUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: photoUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => _initial(),
            )
          : _initial(),
    );
  }

  Widget _initial() {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  const _PrimaryButton({required this.label, required this.onTap});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return Listener(
      onPointerDown: disabled ? null : (_) => setState(() => _scale = 0.97),
      onPointerUp: disabled ? null : (_) => setState(() => _scale = 1.0),
      onPointerCancel: disabled ? null : (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: disabled ? 0.5 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.primaryBrown,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryBrown.withValues(alpha: 0.18),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _SecondaryIconButton({required this.icon, required this.onTap});

  @override
  State<_SecondaryIconButton> createState() => _SecondaryIconButtonState();
}

class _SecondaryIconButtonState extends State<_SecondaryIconButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return Listener(
      onPointerDown: disabled ? null : (_) => setState(() => _scale = 0.97),
      onPointerUp: disabled ? null : (_) => setState(() => _scale = 1.0),
      onPointerCancel: disabled ? null : (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: disabled ? 0.5 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.surfaceWhite,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.primaryBrown.withValues(alpha: 0.2),
                ),
              ),
              child: Icon(
                widget.icon,
                size: 16,
                color: AppColors.primaryBrown,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissButton extends StatefulWidget {
  final VoidCallback? onTap;
  const _DismissButton({required this.onTap});

  @override
  State<_DismissButton> createState() => _DismissButtonState();
}

class _DismissButtonState extends State<_DismissButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return Listener(
      onPointerDown: disabled ? null : (_) => setState(() => _scale = 0.9),
      onPointerUp: disabled ? null : (_) => setState(() => _scale = 1.0),
      onPointerCancel: disabled ? null : (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.muted.withValues(alpha: 0.06),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 15,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Dismiss-sheet option row ───────────────────────────────

class _DismissOption extends StatefulWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  const _DismissOption({
    required this.icon,
    required this.text,
    required this.onTap,
  });

  @override
  State<_DismissOption> createState() => _DismissOptionState();
}

class _DismissOptionState extends State<_DismissOption> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.98),
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
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F5F2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: 18, color: AppColors.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.text,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppColors.muted.withValues(alpha: 0.3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetButton extends StatefulWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _SheetButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  State<_SheetButton> createState() => _SheetButtonState();
}

class _SheetButtonState extends State<_SheetButton> {
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
            height: 44,
            decoration: BoxDecoration(
              color: widget.filled
                  ? AppColors.primaryBrown
                  : AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(12),
              border: widget.filled
                  ? null
                  : Border.all(
                      color: AppColors.muted.withValues(alpha: 0.2),
                    ),
            ),
            child: Center(
              child: Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: widget.filled
                      ? Colors.white
                      : AppColors.deepDarkBrown,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Empty + error states ───────────────────────────────────

class _EmptyMissedRequests extends StatelessWidget {
  const _EmptyMissedRequests();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.success.withValues(alpha: 0.10),
              ),
              child: Icon(
                Icons.check_circle_outline_rounded,
                size: 36,
                color: AppColors.success.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'All caught up!',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.errorRed.withValues(alpha: 0.08),
              ),
              child: Icon(
                Icons.cloud_off_rounded,
                size: 32,
                color: AppColors.errorRed.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "Couldn't load missed requests",
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Check your connection or wait a moment if a Firestore '
              'index is still building.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 18),
            _RetryButton(onTap: onRetry),
          ],
        ),
      ),
    );
  }
}

class _RetryButton extends StatefulWidget {
  final VoidCallback onTap;
  const _RetryButton({required this.onTap});

  @override
  State<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<_RetryButton> {
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
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                'Tap to retry',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
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

// ─── Loading shimmer ────────────────────────────────────────

class _MissedRequestsShimmer extends StatelessWidget {
  const _MissedRequestsShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.08),
      highlightColor: AppColors.muted.withValues(alpha: 0.03),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        itemCount: 3,
        itemBuilder: (_, _) => Container(
          height: 200,
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}
