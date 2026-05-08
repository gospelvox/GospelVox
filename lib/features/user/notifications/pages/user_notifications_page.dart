// User-side in-app notifications list.
//
// Mirrors the priest notifications page: reads `notifications` where
// userId == currentUser.uid, ordered newest first, capped at 50. Tap
// marks as read and routes by type (Bible session deep links,
// session-end summaries, etc). FCM push delivery is handled by
// NotificationService — this page only renders what's already in the
// inbox.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/notifications/data/notification_model.dart';

class UserNotificationsPage extends StatefulWidget {
  const UserNotificationsPage({super.key});

  @override
  State<UserNotificationsPage> createState() => _UserNotificationsPageState();
}

class _UserNotificationsPageState extends State<UserNotificationsPage> {
  bool _isLoading = true;
  bool _markingAll = false;
  List<NotificationModel> _notifications = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
        // Drop free-message notifications written for muted priests
        // (CF flagged delivered=false). The notification doc still
        // exists so the priest can see their own outbox; the user
        // shouldn't see anything from a muted speaker. Other types
        // pass through unchanged — `delivered` defaults to true for
        // every non-priest_message writer, so this filter is a no-op
        // for everything except the muted edge case.
        _notifications = snap.docs
            .map((d) => NotificationModel.fromFirestore(d.id, d.data()))
            .where((n) => n.delivered)
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

  Future<void> _onTap(NotificationModel notif) async {
    if (!notif.isRead) {
      _patchLocalRead(notif.id);
      unawaited(
        FirebaseFirestore.instance
            .doc('notifications/${notif.id}')
            .update({'isRead': true})
            .catchError((_) {}),
      );
    }

    // Route by type. Anything not handled stays on the list — the read
    // state itself is the user-visible feedback.
    switch (notif.type) {
      case 'bible_session_cancelled':
      case 'bible_session_reminder':
      case 'bible_session_link_added':
        final id = notif.sessionId;
        if (id != null && id.isNotEmpty && mounted) {
          context.push('/bible/detail/$id');
        }
        return;
      case 'follow_up':
      case 'priest_message':
        // Deep link from a priest's free message OR a legacy
        // templated nudge — both land on the user's chat history
        // with that priest, where the message is rendered inline
        // and the sticky "Reply · Start Session" CTA is one tap
        // away if the user wants to respond.
        final priestId = notif.priestId;
        if (priestId != null && priestId.isNotEmpty && mounted) {
          context.push(
            '/user/chat-history/$priestId',
            extra: <String, dynamic>{
              'priestName': notif.priestName ?? '',
              'priestPhotoUrl': notif.priestPhotoUrl ?? '',
            },
          );
        }
        return;
      case 'session_ended':
      case 'low_balance':
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
      // Local state already flipped — next refresh will reconcile.
    }

    if (mounted) setState(() => _markingAll = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = _notifications.any((n) => !n.isRead);

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
                child: const Icon(
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
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
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
            ),
        ],
      ),
      body: _isLoading
          ? const _Shimmer()
          : RefreshIndicator(
              color: AppColors.primaryBrown,
              backgroundColor: AppColors.surfaceWhite,
              onRefresh: _load,
              child: _notifications.isEmpty
                  ? const _Empty()
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      itemCount: _notifications.length,
                      itemBuilder: (_, i) => _Card(
                        notification: _notifications[i],
                        onTap: () => _onTap(_notifications[i]),
                      ),
                    ),
            ),
    );
  }
}

class _Card extends StatefulWidget {
  final NotificationModel notification;
  final VoidCallback onTap;

  const _Card({required this.notification, required this.onTap});

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
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
                _NotificationLeading(notification: n),
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
                              decoration: const BoxDecoration(
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

// Leading visual on a notification card. For `follow_up` notifications
// with a priest photo we render the priest's avatar so the card reads
// as "a person reached out". Every other type — and follow_ups with no
// photo — falls back to the colored type icon.
class _NotificationLeading extends StatelessWidget {
  final NotificationModel notification;

  const _NotificationLeading({required this.notification});

  @override
  Widget build(BuildContext context) {
    final isFollowUp = notification.type == 'follow_up';
    final photoUrl = notification.priestPhotoUrl;

    if (isFollowUp && photoUrl != null && photoUrl.isNotEmpty) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: notification.accentColor.withValues(alpha: 0.08),
          border: Border.all(
            color: notification.accentColor.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedNetworkImage(
          imageUrl: photoUrl,
          fit: BoxFit.cover,
          placeholder: (_, _) => const SizedBox.shrink(),
          errorWidget: (_, _, _) => _buildIconFallback(),
        ),
      );
    }

    return _buildIconFallback();
  }

  Widget _buildIconFallback() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: notification.accentColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        notification.icon,
        size: 18,
        color: notification.accentColor,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
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
            "You'll be notified about session updates, "
            'reminders, and account activity here.',
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

class _Shimmer extends StatelessWidget {
  const _Shimmer();

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
