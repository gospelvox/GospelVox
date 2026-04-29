// Read-only access to past sessions, shared between user and priest
// history pages. Both halves filter the same `sessions` collection by
// the appropriate uid field so we never need two parallel models.
//
// We sort client-side instead of asking Firestore for an ordered
// query because pairing `where userId/priestId` with
// `orderBy createdAt` requires a composite index that doesn't exist
// in a fresh Firebase project — without the index the whole stream
// throws FAILED_PRECONDITION on first fire and history would render
// blank. Sessions are bounded per-user, so the cost of sorting in
// Dart is negligible.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/features/shared/data/session_model.dart';

class SessionHistoryRepository {
  // All sessions where the signed-in user was the listener side.
  // Newest first.
  Future<List<SessionModel>> getUserSessions(String userId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions')
        .where('userId', isEqualTo: userId)
        .get()
        .timeout(const Duration(seconds: 15));

    final sessions = snap.docs
        .map((doc) => SessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    // Client-side sort to avoid the composite-index requirement
    // described in the file header. Docs whose server timestamp
    // hasn't filled in yet (a brief window after creation) are
    // pushed to the bottom by falling back to year 2000 — they'll
    // float up on the next refresh once Firestore stamps them.
    sessions.sort((a, b) {
      final aTime = a.createdAt ?? DateTime(2000);
      final bTime = b.createdAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return sessions;
  }

  // All sessions where the signed-in user was the speaker side.
  Future<List<SessionModel>> getPriestSessions(String priestId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions')
        .where('priestId', isEqualTo: priestId)
        .get()
        .timeout(const Duration(seconds: 15));

    final sessions = snap.docs
        .map((doc) => SessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    sessions.sort((a, b) {
      final aTime = a.createdAt ?? DateTime(2000);
      final bTime = b.createdAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return sessions;
  }

  // One-time fetch of the entire transcript. We deliberately do NOT
  // open a stream here — a finished session can't gain new messages,
  // so paying for a snapshot listener would just waste sockets.
  Future<List<ChatMessage>> getSessionMessages(String sessionId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions/$sessionId/messages')
        .orderBy('createdAt', descending: false)
        .get()
        .timeout(const Duration(seconds: 10));

    return snap.docs
        .map((doc) => ChatMessage.fromFirestore(doc.id, doc.data()))
        .toList();
  }
}
