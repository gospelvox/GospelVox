// Repository for Bible session reads/writes. Client-side queries use
// `where(...).get()` (one-shot) rather than streams because the
// browse/list views aren't expected to update in real time — a manual
// pull-to-refresh is enough, and avoiding a long-lived listener keeps
// Firestore quota predictable.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:gospel_vox/features/shared/data/bible_session_model.dart';

class BibleSessionRepository {
  static const _timeout = Duration(seconds: 10);

  CollectionReference<Map<String, dynamic>> get _sessions =>
      FirebaseFirestore.instance.collection('bible_sessions');

  // ── Reads ────────────────────────────────────────────────────────

  // Sessions visible to users on the Bible tab — anything still
  // marked "upcoming". Sorted client-side because Firestore can't
  // sort by a field whose presence isn't guaranteed (scheduledAt
  // is nullable on the model).
  Future<List<BibleSessionModel>> getUpcomingSessions() async {
    final snap = await _sessions
        .where('status', isEqualTo: 'upcoming')
        .get()
        .timeout(_timeout);

    final sessions = snap.docs
        .map((doc) => BibleSessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    sessions.sort((a, b) {
      final aTime = a.scheduledAt ?? DateTime(2099);
      final bTime = b.scheduledAt ?? DateTime(2099);
      return aTime.compareTo(bTime);
    });

    return sessions;
  }

  // The "All" tab — every session regardless of status, newest first.
  Future<List<BibleSessionModel>> getAllSessions() async {
    final snap = await _sessions.get().timeout(_timeout);

    final sessions = snap.docs
        .map((doc) => BibleSessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    sessions.sort((a, b) {
      final aTime = a.scheduledAt ?? DateTime(2000);
      final bTime = b.scheduledAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return sessions;
  }

  // The "Past" tab — completed or cancelled.
  Future<List<BibleSessionModel>> getPastSessions() async {
    final snap = await _sessions
        .where('status', whereIn: ['completed', 'cancelled'])
        .get()
        .timeout(_timeout);

    final sessions = snap.docs
        .map((doc) => BibleSessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    sessions.sort((a, b) {
      final aTime = a.scheduledAt ?? DateTime(2000);
      final bTime = b.scheduledAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return sessions;
  }

  // The priest's own sessions, newest first. Used by the priest-side
  // list page; admin views use a separate query path.
  Future<List<BibleSessionModel>> getPriestSessions(
      String priestId) async {
    final snap = await _sessions
        .where('priestId', isEqualTo: priestId)
        .get()
        .timeout(_timeout);

    final sessions = snap.docs
        .map((doc) => BibleSessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    sessions.sort((a, b) {
      final aTime = a.scheduledAt ?? DateTime(2000);
      final bTime = b.scheduledAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return sessions;
  }

  // Hydrate a single session by id — used by both detail pages.
  Future<BibleSessionModel?> getSession(String sessionId) async {
    final doc = await _sessions.doc(sessionId).get().timeout(_timeout);
    if (!doc.exists) return null;
    return BibleSessionModel.fromFirestore(doc.id, doc.data()!);
  }

  // ── Priest-side mutations ───────────────────────────────────────

  Future<String> createSession({
    required String priestId,
    required String priestName,
    required String priestPhotoUrl,
    required String title,
    required String description,
    required String category,
    required DateTime scheduledAt,
    required int durationMinutes,
    required int maxParticipants,
    required int price,
    String meetingLink = '',
  }) async {
    final docRef = _sessions.doc();
    await docRef.set({
      'priestId': priestId,
      'priestName': priestName,
      'priestPhotoUrl': priestPhotoUrl,
      'title': title,
      'description': description,
      'category': category,
      'scheduledAt': Timestamp.fromDate(scheduledAt),
      'durationMinutes': durationMinutes,
      'maxParticipants': maxParticipants,
      'price': price,
      'meetingLink': meetingLink,
      'status': 'upcoming',
      'registrationCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
    return docRef.id;
  }

  Future<void> updateMeetingLink(String sessionId, String link) async {
    await _sessions
        .doc(sessionId)
        .update({'meetingLink': link})
        .timeout(_timeout);
  }

  // Priest-initiated cancel. Three orchestrated steps, ordered for
  // safety rather than speed:
  //
  //   1. Flip the session's status to "cancelled" — this MUST land,
  //      and lands first, so even if every downstream step fails the
  //      session is at least authoritatively cancelled.
  //   2. Best-effort: write per-user "session cancelled" notification
  //      docs into /notifications. This is what the in-app inbox
  //      shows. V1 lets the priest's client write these directly;
  //      W6 will move the writes into a CF for stricter rules.
  //   3. Best-effort: kick the notifyBibleSessionCancellation CF so
  //      registered users get an OS-level push even if their app is
  //      backgrounded. The CF re-checks that the session is actually
  //      cancelled (gate against spam-pushing).
  //
  // Per V1 design we DO NOT touch any user's registration row here —
  // paid users (only possible in the 15-min join window) keep their
  // `paid` status and admin processes refunds offline.
  //
  // Returns the number of registrations we attempted to notify so
  // the UI can surface a count in the success snackbar. A return of
  // 0 means either there were no registrations or we couldn't read
  // them — we don't differentiate at the UI layer.
  Future<int> cancelSession({
    required String sessionId,
    required String sessionTitle,
    required String priestName,
  }) async {
    // Step 1: flip the status. Awaited and not wrapped in try/catch —
    // if this fails the entire cancel fails and the priest sees the
    // error.
    await _sessions.doc(sessionId).update({
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);

    // Step 2: enumerate active registrations. Wrapped because rules
    // could conceivably reject the read for the priest; we'd still
    // want to return success on the cancel itself.
    List<QueryDocumentSnapshot<Map<String, dynamic>>> activeRegs;
    try {
      final regsSnap = await _sessions
          .doc(sessionId)
          .collection('registrations')
          .get()
          .timeout(_timeout);
      activeRegs = regsSnap.docs
          .where(
            (d) => (d.data()['status'] as String?) != 'cancelled',
          )
          .toList();
    } catch (_) {
      activeRegs = const [];
    }

    if (activeRegs.isNotEmpty) {
      // Batched notification-doc writes. If rules deny these (the
      // expected long-term posture once W6 moves to a CF), we still
      // return success — the cancel itself stuck, the in-app inbox
      // just won't reflect it. The push CF below is independent.
      try {
        final batch = FirebaseFirestore.instance.batch();
        final notifications =
            FirebaseFirestore.instance.collection('notifications');
        final body = '$priestName has cancelled "$sessionTitle". '
            'Check out other upcoming sessions!';
        for (final reg in activeRegs) {
          final ref = notifications.doc();
          batch.set(ref, {
            'userId': reg.id,
            'type': 'bible_session_cancelled',
            'title': 'Session cancelled',
            'body': body,
            'data': {'sessionId': sessionId},
            'isRead': false,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit().timeout(_timeout);
      } catch (_) {
        // Swallow — cancel itself succeeded, push fanout is next.
      }
    }

    // Step 3: trigger the OS-level push fanout via CF. Best-effort:
    // registration docs and notifications are already written, so a
    // CF outage doesn't break the user-visible cancellation flow.
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'asia-south1')
          .httpsCallable('notifyBibleSessionCancellation');
      await callable.call({'sessionId': sessionId}).timeout(
        const Duration(seconds: 15),
      );
    } catch (_) {
      // Swallow.
    }

    return activeRegs.length;
  }

  Future<void> completeSession(String sessionId) async {
    await _sessions.doc(sessionId).update({
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
  }

  // ── User-side registration ──────────────────────────────────────

  // Free registration. Tries to bump the session's registrationCount
  // in the same batch, but the deployed rules may only allow the
  // priest to update the session doc — in that case we fall back to
  // creating the registration doc alone. The count is cosmetic and
  // can be re-derived from the subcollection size; the registration
  // itself is the source of truth for "is this user signed up".
  Future<void> registerForSession({
    required String sessionId,
    required String userId,
    required String userName,
    required String userPhotoUrl,
  }) async {
    final regRef = _sessions
        .doc(sessionId)
        .collection('registrations')
        .doc(userId);
    final sessionRef = _sessions.doc(sessionId);

    final regData = {
      'userName': userName,
      'userPhotoUrl': userPhotoUrl,
      'status': 'registered',
      'registeredAt': FieldValue.serverTimestamp(),
    };

    try {
      final batch = FirebaseFirestore.instance.batch();
      batch.set(regRef, regData);
      batch.update(sessionRef, {
        'registrationCount': FieldValue.increment(1),
      });
      await batch.commit().timeout(_timeout);
    } on FirebaseException catch (e) {
      // permission-denied means rules don't let users update the
      // parent session doc. Fall back to creating just the
      // registration — the count stays slightly out of date, but
      // the user is correctly registered, which is what matters.
      if (e.code == 'permission-denied') {
        await regRef.set(regData).timeout(_timeout);
      } else {
        rethrow;
      }
    }
  }

  // Same fallback shape as register: try to decrement, accept that
  // the count may drift if rules disallow.
  Future<void> cancelRegistration({
    required String sessionId,
    required String userId,
  }) async {
    final regRef = _sessions
        .doc(sessionId)
        .collection('registrations')
        .doc(userId);
    final sessionRef = _sessions.doc(sessionId);

    final cancelData = {
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
    };

    try {
      final batch = FirebaseFirestore.instance.batch();
      batch.update(regRef, cancelData);
      batch.update(sessionRef, {
        'registrationCount': FieldValue.increment(-1),
      });
      await batch.commit().timeout(_timeout);
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        await regRef.update(cancelData).timeout(_timeout);
      } else {
        rethrow;
      }
    }
  }

  // ── Registration reads ──────────────────────────────────────────

  // Fetch a single user's registration. Returns null if they've
  // never registered. The detail page calls this to decide which
  // CTA to show (Register / Join & Pay / Open Link).
  Future<BibleRegistration?> getRegistration(
      String sessionId, String userId) async {
    final doc = await _sessions
        .doc(sessionId)
        .collection('registrations')
        .doc(userId)
        .get()
        .timeout(_timeout);

    if (!doc.exists) return null;
    return BibleRegistration.fromFirestore(doc.id, doc.data()!);
  }

  // Priest-side: list all non-cancelled registrations on a session.
  // Sorted by registration time so the priest sees the order people
  // signed up in.
  Future<List<BibleRegistration>> getRegistrations(
      String sessionId) async {
    final snap = await _sessions
        .doc(sessionId)
        .collection('registrations')
        .get()
        .timeout(_timeout);

    final regs = snap.docs
        .map((doc) =>
            BibleRegistration.fromFirestore(doc.id, doc.data()))
        .where((r) => !r.isCancelled)
        .toList();

    regs.sort((a, b) {
      final aTime = a.registeredAt ?? DateTime(2000);
      final bTime = b.registeredAt ?? DateTime(2000);
      return aTime.compareTo(bTime);
    });

    return regs;
  }

  // ── Payment ─────────────────────────────────────────────────────

  // Hands the captured paymentId to the CF. The CF re-fetches the
  // payment from Razorpay (trust no client value) and flips the
  // registration to "paid" if everything matches the session price.
  Future<void> verifyPayment({
    required String sessionId,
    required String paymentId,
    required int amount,
  }) async {
    final callable = FirebaseFunctions.instanceFor(region: 'asia-south1')
        .httpsCallable('verifyBibleSessionPayment');
    await callable.call({
      'sessionId': sessionId,
      'paymentId': paymentId,
      'amount': amount,
    }).timeout(const Duration(seconds: 15));
  }
}
