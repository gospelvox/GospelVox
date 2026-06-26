// Admin notification inbox — the surface that finally tells an admin
// "something needs you" without them having to remember to pull-to-
// refresh the dashboard.
//
// Reads notifications addressed to the signed-in admin's own uid
// (notifyAdmins fans out one doc per admin with userId = that admin's
// uid), so the existing notifications read rule — auth.uid == userId —
// covers it with NO rules change. Mirrors the priest inbox contract:
//   • tap → mark isRead:true, then deep-link to the doc's `route`
//   • mark-all-read → batch isRead:true on the unread set
//   • dismissed rows (dismissReason != null) are filtered out

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

class AdminNotificationsPage extends StatefulWidget {
  const AdminNotificationsPage({super.key});

  @override
  State<AdminNotificationsPage> createState() =>
      _AdminNotificationsPageState();
}

class _AdminNotificationsPageState extends State<AdminNotificationsPage> {
  bool _markingAll = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Query<Map<String, dynamic>> _query(String uid) => FirebaseFirestore.instance
      .collection('notifications')
      .where('userId', isEqualTo: uid)
      .orderBy('createdAt', descending: true);

  Future<void> _onTap(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final data = doc.data();
    // Best-effort mark-read — never block navigation on it.
    if (data['isRead'] != true) {
      try {
        await doc.reference.update({'isRead': true});
      } catch (_) {/* the deep link still matters more than the flag */}
    }
    final route = (data['route'] as String?)?.trim() ?? '';
    if (route.isNotEmpty && mounted) {
      context.push(route);
    }
  }

  Future<void> _markAllRead(List<QueryDocumentSnapshot> unread) async {
    if (unread.isEmpty || _markingAll) return;
    setState(() => _markingAll = true);
    try {
      final db = FirebaseFirestore.instance;
      // Firestore caps a batch at 500 writes; chunk to stay safe.
      for (var i = 0; i < unread.length; i += 450) {
        final batch = db.batch();
        for (final d in unread.skip(i).take(450)) {
          batch.update(d.reference, {'isRead': true});
        }
        await batch.commit();
      }
    } catch (_) {
      if (mounted) AppSnackBar.error(context, 'Could not mark all read.');
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    return Scaffold(
      backgroundColor: AdminColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leadingWidth: 60,
        leading: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/admin');
            }
          },
          child: const Padding(
            padding: EdgeInsets.only(left: 16),
            child: Icon(AppIcons.back, size: 20, color: AdminColors.textPrimary),
          ),
        ),
        title: Text(
          'Notifications',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AdminColors.textPrimary,
          ),
        ),
        centerTitle: false,
      ),
      body: uid == null
          ? _empty('Sign in as an admin to see notifications.')
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _query(uid).snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return const Center(
                    child: AppLoader(),
                  );
                }
                final docs = (snap.data?.docs ?? [])
                    // Hide rows the admin cleared. Stays a client-side
                    // filter (not a query clause) so we don't need a
                    // second composite index.
                    .where((d) => d.data()['dismissReason'] == null)
                    .toList();

                if (docs.isEmpty) {
                  return _empty("You're all caught up.");
                }

                final unread =
                    docs.where((d) => d.data()['isRead'] != true).toList();

                return Column(
                  children: [
                    if (unread.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 8, 12, 0),
                          child: TextButton(
                            onPressed: _markingAll
                                ? null
                                : () => _markAllRead(unread),
                            child: Text(
                              _markingAll ? 'Marking…' : 'Mark all read',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AdminColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: docs.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _AdminNotifTile(
                          doc: docs[i],
                          onTap: () => _onTap(docs[i]),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _empty(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              AppIcons.bellOutline,
              size: 40,
              color: AdminColors.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AdminColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminNotifTile extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onTap;

  const _AdminNotifTile({required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final isRead = data['isRead'] == true;
    final title = (data['title'] as String?) ?? 'Notification';
    final body = (data['body'] as String?) ?? '';
    final createdAt = data['createdAt'];
    final at = createdAt is Timestamp ? createdAt.toDate() : null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isRead
              ? Colors.white
              : AdminColors.warning.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isRead
                ? AdminColors.textMuted.withValues(alpha: 0.12)
                : AdminColors.warning.withValues(alpha: 0.30),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Unread dot.
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 10),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isRead
                      ? Colors.transparent
                      : AdminColors.warning,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight:
                                isRead ? FontWeight.w600 : FontWeight.w700,
                            color: AdminColors.textPrimary,
                          ),
                        ),
                      ),
                      if (at != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          df.formatTimeAgo(at),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: AdminColors.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        height: 1.4,
                        color: AdminColors.textBody,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
