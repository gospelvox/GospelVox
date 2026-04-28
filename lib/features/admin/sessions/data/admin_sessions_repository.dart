// Data access for the admin session monitor.
//
// Active sessions stream live so the admin can watch a session
// transition (e.g. balance_zero forced end) without a refresh.
// Completed and All tabs use a one-shot fetch — no value in
// streaming history that doesn't change.
//
// Both queries deliberately omit `orderBy('createdAt')`. Pairing
// that with `where('status', ...)` would require a composite
// Firestore index that no deploy script currently creates — on
// first run in prod the query throws FAILED_PRECONDITION. We sort
// client-side instead. Matches the speakers repo pattern.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/features/admin/sessions/data/admin_session_model.dart';

class AdminSessionsRepository {
  // statusFilter: null or 'all' returns every status.
  Future<List<AdminSessionModel>> getSessions({String? statusFilter}) async {
    Query<Map<String, dynamic>> query =
        FirebaseFirestore.instance.collection('sessions');

    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('status', isEqualTo: statusFilter);
    }

    final snap = await query.get().timeout(const Duration(seconds: 10));

    final sessions = snap.docs
        .map((doc) =>
            AdminSessionModel.fromFirestore(doc.id, doc.data()))
        .toList();
    _sortNewestFirst(sessions);
    return sessions;
  }

  // Live stream of active sessions for the Active tab. Snapshots
  // arrive un-ordered (we dropped server-side orderBy to avoid the
  // composite-index requirement) and are sorted in the map step.
  Stream<List<AdminSessionModel>> watchActiveSessions() {
    return FirebaseFirestore.instance
        .collection('sessions')
        .where('status', isEqualTo: 'active')
        .snapshots()
        .map((snap) {
      final sessions = snap.docs
          .map((doc) =>
              AdminSessionModel.fromFirestore(doc.id, doc.data()))
          .toList();
      _sortNewestFirst(sessions);
      return sessions;
    });
  }

  // Newest first; nulls (pending server timestamp) sink to bottom
  // so a freshly created session doesn't vanish off-screen during
  // the brief write-then-read window.
  void _sortNewestFirst(List<AdminSessionModel> list) {
    list.sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
  }
}
