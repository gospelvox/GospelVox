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
  // Safety bound so the Completed / All tabs can never hang or hit the 10s
  // timeout as the sessions collection grows (the fastest-growing table —
  // one doc per chat/call ever). Caps the one-shot fetch instead of pulling
  // every session. At current scale (under the cap) behaviour is identical
  // to before. `where` + `limit` with no `orderBy` uses the automatic
  // single-field index, so it never throws FAILED_PRECONDITION.
  static const int _fetchLimit = 1000;

  // statusFilter: null or 'all' returns every status.
  Future<List<AdminSessionModel>> getSessions({String? statusFilter}) async {
    Query<Map<String, dynamic>> query =
        FirebaseFirestore.instance.collection('sessions');

    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('status', isEqualTo: statusFilter);
    }

    final snap =
        await query.limit(_fetchLimit).get().timeout(const Duration(seconds: 10));

    final sessions = _parseDocs(snap.docs);
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
      final sessions = _parseDocs(snap.docs);
      _sortNewestFirst(sessions);
      return sessions;
    });
  }

  // Parses each doc independently so one malformed session row (a field
  // written as the wrong type, a half-written doc) is skipped instead
  // of throwing out of the .map and taking the whole list / live stream
  // down. The model's own accessors are already type-safe; this is the
  // outer guard for anything they can't anticipate (e.g. a null
  // data()).
  List<AdminSessionModel> _parseDocs(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final out = <AdminSessionModel>[];
    for (final doc in docs) {
      try {
        out.add(AdminSessionModel.fromFirestore(doc.id, doc.data()));
      } catch (_) {
        // Skip the single bad row; the rest of the monitor still loads.
      }
    }
    return out;
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
