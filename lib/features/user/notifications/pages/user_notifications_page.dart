// User-side in-app notifications list.
//
// Reads `notifications` where userId == currentUser.uid, ordered
// newest first, capped at 50. Behaviour:
//
//   • On page open: every loaded notification is silently marked
//     `isRead: true` in the background. The bell badge query
//     (`isRead == false`) clears as the batch lands. No visual
//     unread/read distinction in the list itself — every row reads
//     identically. Mirrors the "open inbox → badge clears" pattern
//     of most modern apps.
//
//   • Tap a row: routes by `type` (Bible session deep links, chat
//     history, etc.). The route push is the user-visible feedback;
//     no extra mark-as-read needed because the open-time batch
//     already covered it.
//
//   • Clear all (app-bar action): Firestore rules DENY `delete` on
//     /notifications, so "clear" is implemented as a 3-field UPDATE
//     marking each doc as dismissed:
//       isRead=true        → also drops it out of the unread badge,
//       dismissReason='cleared' → the load filter hides it,
//       dismissedAt=serverTimestamp() → audit trail.
//     This mirrors the priest-side notifications page exactly so the
//     two surfaces follow one contract. The clear is optimistic
//     (local list empties immediately); a server failure rolls back
//     the local state and surfaces an error snackbar so the UI never
//     lies about persistence.
//
//   • Load filter: docs whose `dismissReason` is non-null are hidden
//     from the visible list. Together with the dismiss-tag update,
//     this is how "clear" persists across refreshes, navigations,
//     and app restarts without a delete permission.
//
// FCM push delivery is handled by NotificationService — this page
// only renders what's already in the inbox.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/notifications/data/notification_model.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class UserNotificationsPage extends StatefulWidget {
  const UserNotificationsPage({super.key});

  @override
  State<UserNotificationsPage> createState() => _UserNotificationsPageState();
}

class _UserNotificationsPageState extends State<UserNotificationsPage> {
  bool _isLoading = true;
  bool _clearing = false;
  List<NotificationModel> _notifications = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Hard guard against the pull-to-refresh-during-clear race:
    // if a clear batch is mid-flight, a refetch would see the
    // not-yet-dismissed docs and bounce them back into the visible
    // list for a fraction of a second before the batch lands. We
    // skip the load entirely while the clear resolves; the user's
    // pull-down still completes (we return a resolved Future), they
    // just don't see the brief flash.
    if (_clearing) return;
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
      // Two filters on the loaded snapshot:
      //
      //   • `delivered` — drops free-message notifications written
      //     for muted priests (CF flagged delivered=false). The
      //     notification doc still exists so the priest can see
      //     their own outbox; the user shouldn't see anything from
      //     a muted speaker. No-op for every non-priest_message
      //     writer (delivered defaults to true).
      //
      //   • `dismissReason == null` — hides docs that were cleared
      //     via the Clear-all flow. Firestore rules deny delete on
      //     /notifications, so "clear" is implemented as an update
      //     with dismissReason='cleared'; without this filter the
      //     cleared docs would re-appear on every refresh.
      final notifications = snap.docs
          .map((d) => NotificationModel.fromFirestore(d.id, d.data()))
          .where((n) => n.delivered && n.dismissReason == null)
          .toList();
      setState(() {
        _notifications = notifications;
        _isLoading = false;
      });
      // Open-time mark-all-read: fire-and-forget batch write that
      // clears the bell badge for the user. Runs after the visible
      // list has rendered so the user never waits on this. Note we
      // pass the `uid`, not the visible `notifications` list — the
      // background job queries its OWN snapshot of every unread
      // doc so notifications outside the visible list (muted-priest
      // messages, anything past the 50-newest cutoff, etc.) also get
      // cleared. Otherwise the bell badge would stay stuck on items
      // the user never sees on screen.
      unawaited(_markAllReadInBackground(uid));
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

  // Fire-and-forget bell-badge clearer. Runs its OWN query for every
  // unread doc the user owns — not just the docs in the visible list
  // — so the bell badge actually drops to 0 on inbox open, even for:
  //
  //   • muted-priest messages (delivered=false; filtered out of the
  //     visible list but still isRead=false on the server)
  //   • notifications past the 50-newest cutoff applied to the
  //     visible list
  //
  // Without this, an inbox carrying any of the above would show a
  // permanently-stuck count on the home-screen bell — visiting the
  // page wouldn't drop it, because the prior implementation only
  // marked docs in the filtered visible list.
  //
  // We don't show a spinner, don't mutate _notifications, and silently
  // swallow any failure — a failed batch leaves the badge at whatever
  // the stream reports; the next inbox open retries. limit(500)
  // caps the query at the Firestore batch size (no realistic inbox
  // carries more; if one ever does, the remainder rolls over).
  Future<void> _markAllReadInBackground(String uid) async {
    try {
      final db = FirebaseFirestore.instance;
      final snap = await db
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .where('isRead', isEqualTo: false)
          .limit(500)
          .get()
          .timeout(const Duration(seconds: 10));
      if (snap.docs.isEmpty) return;
      final batch = db.batch();
      for (final d in snap.docs) {
        batch.update(d.reference, {'isRead': true});
      }
      await batch.commit();
    } catch (_) {
      // Silent — next inbox open retries.
    }
  }

  Future<void> _onTap(NotificationModel notif) async {
    // Route by type. Read-tracking already covered by the open-time
    // batch — no per-tap mark-as-read needed.
    //
    // Every user-facing bible_session_* type lands on the same
    // detail page (/bible/detail/$sessionId). The model defines a
    // wide set of variants — reminders, paid, registered, link
    // updates, lifecycle events — and the prior switch only
    // handled three of them. The bare `bible_session_reminder`
    // case in particular was a dead branch: the Cloud Function
    // writes the suffixed names `_24h` / `_1h` instead. Switching
    // to a set-membership check fixes both gaps.
    //
    // Priest-only variants (golive / starting_priest / first_
    // registration) are intentionally not in the set — the CF
    // writes those into priest inboxes only.
    const userBibleTypes = <String>{
      'bible_session_registered',
      'bible_session_paid',
      'bible_session_completed',
      'bible_session_auto_completed',
      'bible_session_live',
      'bible_session_cancelled',
      'bible_session_link_added',
      'bible_session_reminder_24h',
      'bible_session_reminder_1h',
      'bible_session_pay_reminder',
      'bible_session_starting',
      'bible_session_link_reminder',
      'bible_session_link_urgent',
      'bible_session_full',
      // Legacy / pre-suffix variant — kept in the set so old
      // notification docs written before the rename still route.
      'bible_session_reminder',
    };
    if (userBibleTypes.contains(notif.type)) {
      final id = notif.sessionId;
      if (id != null && id.isNotEmpty && mounted) {
        context.push('/bible/detail/$id');
      }
      return;
    }

    switch (notif.type) {
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

  // Clear-all = batch UPDATE marking each doc as dismissed (NOT a
  // delete). The Firestore rules on /notifications deny `delete` for
  // users; the priest-side notifications page already worked around
  // this with a 3-field dismiss update, and we mirror the exact same
  // shape here so the two surfaces share one contract.
  //
  // Flow:
  //   1. Optimistic local clear so the empty state appears instantly.
  //   2. Batch write: isRead=true + dismissReason='cleared' + dismissedAt.
  //   3. On success: a success snackbar confirms the action. The
  //      load filter (`dismissReason == null`) keeps these docs out
  //      of view on every subsequent fetch, so the clear PERSISTS
  //      across refresh, navigation, and app restart.
  //   4. On failure: roll the local list back to its previous state
  //      and show an error snackbar. The UI never lies about whether
  //      the clear stuck.
  Future<void> _clearAll() async {
    if (_clearing || _notifications.isEmpty) return;
    final previous = List<NotificationModel>.from(_notifications);
    setState(() {
      _clearing = true;
      _notifications = const [];
    });

    try {
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      for (final n in previous) {
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
      // Restore the previous list so the user sees the truth — the
      // clear did not stick on the server. The snackbar tells them
      // to retry; no silent lie about persistence.
      if (!mounted) return;
      setState(() => _notifications = previous);
      AppSnackBar.error(
        context,
        "Couldn't clear notifications. Try again.",
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canClear = _notifications.isNotEmpty && !_clearing;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leadingWidth: 56,
        leading: const Padding(
          padding: EdgeInsets.only(left: 12),
          child: Align(
            child: AppBackButton(),
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
          // Clear-all action lives in the app bar so it's reachable
          // from the top without competing with notification content
          // for visual weight. Hidden while the list is empty or a
          // clear is already running so users can't double-fire.
          if (_notifications.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _AppBarTextButton(
                label: 'Clear all',
                onTap: canClear ? _clearAll : null,
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
                  // ListView.separated paints a thin hairline between
                  // rows, indented under the text column so it reads
                  // as a "list" rather than a stack of boxes. The
                  // dividers are the entire visual structure — no
                  // per-row cards, no borders. Premium-minimal.
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.only(top: 4, bottom: 32),
                      itemCount: _notifications.length,
                      separatorBuilder: (_, _) => const _ItemDivider(),
                      itemBuilder: (_, i) => _Row(
                        notification: _notifications[i],
                        onTap: () => _onTap(_notifications[i]),
                      ),
                    ),
            ),
    );
  }
}

// Single row in the divider-list notifications inbox. No per-row card
// chrome, no unread highlight — the divider IS the visual separator.
// Press feedback: a subtle warm-tinted background flash + a 1 % opacity
// dim. We use GestureDetector with the gesture-arena callbacks
// (onTapDown / onTapUp / onTapCancel) so a future nested action button
// inside a row wouldn't trigger row-level press feedback.
class _Row extends StatefulWidget {
  final NotificationModel notification;
  final VoidCallback onTap;

  const _Row({required this.notification, required this.onTap});

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        // Warm-tinted highlight on press — much subtler than a scale
        // animation, which feels heavy on a list-item row. The wash
        // matches the rest of the cream parchment palette.
        color: _pressed
            ? AppColors.deepDarkBrown.withValues(alpha: 0.04)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _NotificationLeading(notification: n),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
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
                  const SizedBox(height: 8),
                  Text(
                    n.timeAgo,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                      color: AppColors.muted.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Hairline separator between rows. Indented to start at the text-column
// edge (page padding 20 + icon 40 + gap 14 = 74 px) so the dividers
// read as a typographic underline beneath each notification's content
// rather than a full-width edge-to-edge rule.
class _ItemDivider extends StatelessWidget {
  const _ItemDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 74, right: 20),
      child: Container(
        height: 1,
        color: AppColors.deepDarkBrown.withValues(alpha: 0.06),
      ),
    );
  }
}

// Lightweight text-style action for the app bar. Subtle opacity dim on
// press, fully fades when disabled (during a clear-all in flight) so
// the user sees the button is no longer interactive. Color is
// deepDarkBrown — minimal-premium, on-palette; the destructive intent
// is communicated by the label and the confirmation-by-action (the
// list visibly empties on tap).
class _AppBarTextButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;

  const _AppBarTextButton({required this.label, required this.onTap});

  @override
  State<_AppBarTextButton> createState() => _AppBarTextButtonState();
}

class _AppBarTextButtonState extends State<_AppBarTextButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      onTap: widget.onTap,
      child: AnimatedOpacity(
        opacity: !enabled ? 0.4 : (_pressed ? 0.6 : 1.0),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            widget.label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
      ),
    );
  }
}

// Leading visual on a notification card. For "a priest reached out"
// notifications (both `follow_up` and `priest_message`) with a priest
// photo we render the priest's avatar so the row reads as a person,
// not a system event. Every other type — and reach-out notifications
// without a photo — falls back to the colored type icon.
class _NotificationLeading extends StatelessWidget {
  final NotificationModel notification;

  const _NotificationLeading({required this.notification});

  @override
  Widget build(BuildContext context) {
    // Both follow_up and priest_message carry the same priest-photo
    // payload from their respective CFs. The prior code only honored
    // follow_up, which left direct priest messages stuck with the
    // generic chat icon even when the avatar was available.
    final isPriestOutreach = notification.type == 'follow_up' ||
        notification.type == 'priest_message';
    final photoUrl = notification.priestPhotoUrl;

    if (isPriestOutreach && photoUrl != null && photoUrl.isNotEmpty) {
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
        // Circle instead of the previous rounded square — all leading
        // glyphs now share the same silhouette as the priest-avatar
        // variant above, so every row's leading column has identical
        // geometry. Reads as one consistent list.
        shape: BoxShape.circle,
        color: notification.accentColor.withValues(alpha: 0.10),
      ),
      child: AppIcon(
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
            child: AppIcon(
              AppIcons.bellOff,
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

// Placeholder rows for the divider-list. Mirrors the production
// _Row layout exactly — same icon circle, same column widths, same
// vertical rhythm — so the shimmer → real-content swap doesn't shift
// any pixels.
class _Shimmer extends StatelessWidget {
  const _Shimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.10),
      highlightColor: AppColors.muted.withValues(alpha: 0.04),
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        itemCount: 6,
        separatorBuilder: (_, _) => const _ItemDivider(),
        itemBuilder: (_, _) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title placeholder — matches the 14 px font line
                    // height roughly.
                    Container(
                      width: 180,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Two body lines — roughly mirror two ellipsised
                    // lines of body text.
                    Container(
                      width: double.infinity,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 220,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 60,
                      height: 9,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
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
}
