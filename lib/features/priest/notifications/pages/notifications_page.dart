// Priest in-app notifications list.
//
// Reads from the shared `notifications` collection (Cloud Functions are
// the only writers). Tap → mark as read + route by type. Pull-to-refresh
// re-queries the latest 50. FCM push registration is a separate concern
// (Week 5) and intentionally NOT wired here.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/notifications/data/notification_model.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool _isLoading = true;
  bool _markingAll = false;
  bool _clearingAll = false;
  List<NotificationModel> _notifications = const [];

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _notifications = const [];
        });
      }
      return;
    }

    try {
      final snap = await FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .get()
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      setState(() {
        // Filter out client-cleared docs. Firestore rules deny
        // delete on /notifications, so the Clear All / per-card
        // dismiss flows mark `dismissReason='cleared'` instead of
        // hard-deleting. Hiding them client-side gives the user
        // the same outcome (gone from view) without violating
        // the rule contract.
        _notifications = snap.docs
            .map((d) => NotificationModel.fromFirestore(d.id, d.data()))
            .where((n) => n.dismissReason == null)
            .toList();
        _isLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Loading timed out. Pull down to retry.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Could not load notifications.');
    }
  }

  Future<void> _onNotificationTap(NotificationModel notif) async {
    // Mark read locally first so the UI reacts without waiting on
    // the network round trip — Firestore write is best-effort.
    if (!notif.isRead) {
      _patchLocalRead(notif.id);
      unawaited(
        FirebaseFirestore.instance
            .doc('notifications/${notif.id}')
            .update({'isRead': true})
            .catchError((_) {}),
      );
    }

    // Route by type. Anything we don't recognise just stays on the
    // list (the read state itself is the user-visible feedback).
    switch (notif.type) {
      case 'session_request':
        // The dashboard owns the live pending-request listener, so the
        // correct landing for this notification is the dashboard
        // itself — its stream will surface the request and route to
        // /priest/incoming with the full SessionModel.
        if (mounted) context.go('/priest');
        return;
      case 'missed_request':
        // The user tried to reach this priest but the request
        // expired before they accepted. Land on the dedicated
        // missed-requests page where the priest can quick-reply
        // or dismiss without leaving the surface. Marking THIS
        // notification doc as read happens above (via _patchLocalRead
        // + the unawaited Firestore write); the dedicated page
        // re-runs its own stream so a doc that was already flipped
        // by this tap simply doesn't render there.
        if (mounted) context.push('/priest/missed-requests');
        return;
      case 'withdrawal_processed':
      case 'withdrawal_sent':
        if (mounted) context.push('/priest/wallet');
        return;
      // Bible session lifecycle notifications addressed to the priest.
      // Every type below has a sessionId — without one, fall through
      // to the no-op default rather than navigating to a broken
      // /priest/bible/ URL.
      case 'bible_session_completed':
      case 'bible_session_auto_completed':
      case 'bible_session_payment_received':
      case 'bible_session_full':
      case 'bible_session_first_registration':
      case 'bible_session_link_reminder':
      case 'bible_session_link_urgent':
      case 'bible_session_golive':
      case 'bible_session_starting_priest':
        final sessionId = notif.sessionId ?? '';
        if (sessionId.isNotEmpty && mounted) {
          context.push('/priest/bible/$sessionId');
        }
        return;
      // Session lifecycle — landing on the priest's session-history
      // matches the way these notifications are paired with past
      // earnings on the dashboard.
      case 'session_ended':
        if (mounted) context.push('/priest/session-history');
        return;
      // priest_message addressed to a priest is unusual (the type is
      // primarily a user-side inbox card), but if it ever reaches a
      // priest's inbox we land on My Users so the priest can act
      // from a familiar surface instead of a dead-end tap.
      case 'priest_message':
      case 'follow_up':
        if (mounted) context.push('/priest/my-users');
        return;
      default:
        return;
    }
  }

  void _patchLocalRead(String id) {
    setState(() {
      _notifications = _notifications
          .map((n) => n.id == id ? n.copyWith(isRead: true) : n)
          .toList();
    });
  }

  Future<void> _markAllRead() async {
    if (_markingAll) return;
    final unread = _notifications.where((n) => !n.isRead).toList();
    if (unread.isEmpty) return;

    setState(() => _markingAll = true);

    // Mark locally first; the batch write is best-effort.
    setState(() {
      _notifications =
          _notifications.map((n) => n.copyWith(isRead: true)).toList();
    });

    try {
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      for (final n in unread) {
        batch.update(db.doc('notifications/${n.id}'), {'isRead': true});
      }
      await batch.commit().timeout(const Duration(seconds: 10));
    } catch (_) {
      // Local state already flipped — even on failure the next refresh
      // will reconcile from the server. Don't surface a noisy error.
    }

    if (mounted) setState(() => _markingAll = false);
  }

  // Firestore rules deny `delete` on /notifications, so "clear" means
  // a 3-field update marking the doc as dismissed: isRead=true so it
  // also drops out of the unread badge, dismissReason='cleared' so
  // the load filter hides it, dismissedAt as an audit timestamp.
  // Both this method and _dismissOne use the same shape so a future
  // server-side reconciliation job can recognise either source.
  Future<void> _clearAll() async {
    if (_clearingAll) return;
    if (_notifications.isEmpty) return;

    final visible = List<NotificationModel>.from(_notifications);

    setState(() {
      _clearingAll = true;
      _notifications = const [];
    });

    try {
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      for (final n in visible) {
        batch.update(db.doc('notifications/${n.id}'), {
          'isRead': true,
          'dismissReason': 'cleared',
          'dismissedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      AppSnackBar.success(context, 'All notifications cleared.');
    } catch (_) {
      // Roll back the optimistic clear so the user isn't lied to.
      if (!mounted) return;
      setState(() => _notifications = visible);
      AppSnackBar.error(context, "Couldn't clear notifications. Try again.");
    } finally {
      if (mounted) setState(() => _clearingAll = false);
    }
  }

  Future<void> _dismissOne(NotificationModel notif) async {
    final index = _notifications.indexWhere((n) => n.id == notif.id);
    if (index == -1) return;

    setState(() {
      _notifications = List.of(_notifications)..removeAt(index);
    });

    try {
      await FirebaseFirestore.instance
          .doc('notifications/${notif.id}')
          .update({
            'isRead': true,
            'dismissReason': 'cleared',
            'dismissedAt': FieldValue.serverTimestamp(),
          })
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Roll back so the visible state stays honest.
      if (!mounted) return;
      setState(() {
        _notifications = List.of(_notifications)..insert(index, notif);
      });
      AppSnackBar.error(context, "Couldn't dismiss. Try again.");
    }
  }

  Future<void> _showClearAllSheet() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _ConfirmActionSheet(
        title: 'Clear all notifications?',
        message:
            'This will permanently clear every notification from your '
            "inbox. You won't be able to undo this.",
        confirmLabel: 'Clear All',
      ),
    );
    if (confirmed == true && mounted) {
      await _clearAll();
    }
  }

  Future<void> _showDismissSheet(NotificationModel notif) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _ConfirmActionSheet(
        title: 'Dismiss this notification?',
        message:
            "It will be removed from your inbox. You won't be able to "
            'undo this.',
        confirmLabel: 'Dismiss',
      ),
    );
    if (confirmed == true && mounted) {
      await _dismissOne(notif);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = _notifications.any((n) => !n.isRead);
    final hasAny = _notifications.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (context.canPop()) context.pop();
              },
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceWhite,
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                      color: Colors.black.withValues(alpha: 0.05),
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
        ),
        title: Text(
          'Notifications',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.deepDarkBrown,
          ),
        ),
        centerTitle: false,
        actions: [
          if (hasUnread)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _markingAll ? null : _markAllRead,
              child: Container(
                alignment: Alignment.center,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  'Mark all read',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.primaryBrown,
                  ),
                ),
              ),
            ),
          if (hasAny)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 16),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _clearingAll ? null : _showClearAllSheet,
                child: Container(
                  alignment: Alignment.center,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(
                    'Clear All',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.errorRed,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const _NotificationsShimmer()
          : RefreshIndicator(
              color: AppColors.primaryBrown,
              backgroundColor: AppColors.surfaceWhite,
              onRefresh: _loadNotifications,
              child: _notifications.isEmpty
                  ? const _EmptyNotifications()
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      itemCount: _notifications.length,
                      itemBuilder: (_, i) => _NotificationCard(
                        notification: _notifications[i],
                        onTap: () => _onNotificationTap(_notifications[i]),
                        onLongPress: () =>
                            _showDismissSheet(_notifications[i]),
                      ),
                    ),
            ),
    );
  }
}

// ─── Card ──────────────────────────────────────────────────

class _NotificationCard extends StatefulWidget {
  final NotificationModel notification;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _NotificationCard({
    required this.notification,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    final unread = !n.isRead;

    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.98),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: () {
          HapticFeedback.mediumImpact();
          widget.onLongPress();
        },
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: unread
                  ? AppColors.primaryBrown.withValues(alpha: 0.04)
                  : AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: unread
                    ? AppColors.primaryBrown.withValues(alpha: 0.1)
                    : AppColors.muted.withValues(alpha: 0.06),
              ),
              boxShadow: [
                BoxShadow(
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                  color: Colors.black.withValues(alpha: 0.02),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: n.accentColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(n.icon, size: 18, color: n.accentColor),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              n.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.deepDarkBrown,
                              ),
                            ),
                          ),
                          if (unread) ...[
                            const SizedBox(width: 8),
                            Container(
                              margin: const EdgeInsets.only(top: 6),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primaryBrown,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        n.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          height: 1.4,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        n.timeAgo,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
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

// ─── Empty state ─────────────────────────────────────────

class _EmptyNotifications extends StatelessWidget {
  const _EmptyNotifications();

  @override
  Widget build(BuildContext context) {
    // Wrapping in ListView keeps RefreshIndicator's pull-to-refresh
    // gesture working when the list is empty — a Center alone has
    // no scroll surface for the indicator to attach to.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.muted.withValues(alpha: 0.08),
            ),
            child: Icon(
              Icons.notifications_off_outlined,
              size: 32,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: Text(
            'No notifications yet',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            "You'll be notified about session requests, "
            'approvals, and withdrawals here.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: AppColors.muted.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Loading shimmer ─────────────────────────────────────

class _NotificationsShimmer extends StatelessWidget {
  const _NotificationsShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.08),
      highlightColor: AppColors.muted.withValues(alpha: 0.03),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        itemCount: 5,
        itemBuilder: (_, _) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 12,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 8),
                    Container(width: 220, height: 10, color: Colors.white),
                    const SizedBox(height: 6),
                    Container(width: 180, height: 10, color: Colors.white),
                    const SizedBox(height: 8),
                    Container(width: 60, height: 9, color: Colors.white),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Confirm action sheet (shared by Clear All + Dismiss One) ──
//
// Lightweight bottom-sheet confirmation for destructive notification
// actions. Returns true via Navigator.pop() when the user confirms,
// false on cancel, null on dismiss. Caller treats anything other than
// `true` as "user backed out" so a swipe-down can't trigger a delete.
class _ConfirmActionSheet extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;

  const _ConfirmActionSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.errorRed.withValues(alpha: 0.08),
              ),
              child: const Icon(
                Icons.delete_sweep_outlined,
                size: 28,
                color: AppColors.errorRed,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(false),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.muted.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Text(
                        'Cancel',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(true),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.errorRed,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        confirmLabel,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
