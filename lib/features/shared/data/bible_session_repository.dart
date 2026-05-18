// Repository for Bible session reads/writes. Client-side queries use
// `where(...).get()` (one-shot) rather than streams because the
// browse/list views aren't expected to update in real time — a manual
// pull-to-refresh is enough, and avoiding a long-lived listener keeps
// Firestore quota predictable.
//
// Counter handling: `bible_sessions/{id}.registrationCount` is
// maintained server-side by the `onBibleRegistrationWrite` Firestore
// trigger. Clients write only to the registration subcollection; the
// trigger reconciles the parent count via Admin SDK (which bypasses
// the rule that blocks user-side writes on the session doc). Don't
// reintroduce client-side increments here — the rule will reject them
// and the count will silently drift back to zero.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:gospel_vox/features/shared/data/bible_session_model.dart';

class BibleSessionRepository {
  static const _timeout = Duration(seconds: 10);

  CollectionReference<Map<String, dynamic>> get _sessions =>
      FirebaseFirestore.instance.collection('bible_sessions');

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

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

  // The "Live" bucket — sessions the priest has actually started.
  // Mirrors getUpcomingSessions but on `status == 'live'`. The user-
  // side bible tab will surface these at the top because they're the
  // ones a user can pay-and-join right now. A priest is constrained
  // to one live session at a time (enforced server-side in
  // startBibleSession), so this list is typically very small.
  //
  // Local stale-deadline filter:
  //   The auto-complete cron (bibleSessionReminders.ts) flips status
  //   from 'live' → 'completed' at startedAt + duration + 15min, but
  //   it runs on a 5-minute schedule. Between the deadline and the
  //   next cron tick, a finished session is still status='live' on
  //   the server. Without this client-side filter the user would see
  //   a "LIVE NOW" card for a session that's actually over.
  //   `BibleSessionModel.isJoinable` returns false the moment the
  //   deadline passes (uses the same offset as the cron) — drop
  //   anything that fails that check.
  Future<List<BibleSessionModel>> getLiveSessions() async {
    final snap = await _sessions
        .where('status', isEqualTo: 'live')
        .get()
        .timeout(_timeout);

    final sessions = snap.docs
        .map((doc) => BibleSessionModel.fromFirestore(doc.id, doc.data()))
        .where((s) => s.isJoinable)
        .toList();

    // Newest live first — a priest who started two sessions back-to-
    // back is rare but possible; the most recently started one is
    // what users should see at the top.
    sessions.sort((a, b) {
      final aTime = a.startedAt ?? a.scheduledAt ?? DateTime(2000);
      final bTime = b.startedAt ?? b.scheduledAt ?? DateTime(2000);
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

  // Live-updating stream of a single session. Used by the detail
  // pages (priest + user) so the UI reacts immediately when the
  // status flips upcoming → live → completed without needing a
  // manual pull-to-refresh. List pages still use one-shot reads —
  // a live listener per visible card would be wasteful.
  //
  // Emits an error to the stream if the doc disappears (deleted),
  // which isn't a path we expect in V1 (rules block delete) but the
  // map function guards against it anyway by returning a stub model
  // with empty fields rather than throwing.
  Stream<BibleSessionModel> watchSession(String sessionId) {
    return _firestore
        .doc('bible_sessions/$sessionId')
        .snapshots()
        .map((snap) {
      final data = snap.data() ?? <String, dynamic>{};
      return BibleSessionModel.fromFirestore(snap.id, data);
    });
  }

  // ── Priest-side mutations ───────────────────────────────────────

  // Routes through the `createBibleSession` CF instead of writing
  // the session doc directly. The CF owns three things the client
  // can't:
  //   1. Server-validated input (length / range / duration whitelist
  //      / price band ₹49–₹499). The form already enforces these
  //      but the CF is the authoritative copy.
  //   2. Overlap detection against the priest's other upcoming +
  //      live sessions. A near-simultaneous tap on two devices, or
  //      a session created days ago that wasn't started, both need
  //      a server-side block — the client can't see other devices'
  //      pending writes.
  //   3. Approved + activated priest gate. Rules already enforce
  //      this on direct writes; the CF re-asserts it because the
  //      Admin SDK bypasses rules.
  //
  // `priestId` is accepted (and ignored by the CF — it trusts auth.uid)
  // for backwards-compat with the existing call site signature. The
  // CF throws `already-exists` on overlap and `invalid-argument` on
  // shape failures; the caller is responsible for surfacing those
  // codes as user-readable copy.
  //
  // Throws `FirebaseFunctionsException` on CF rejection — callers
  // should catch and surface the human-readable `.message`.
  Future<String> createSession({
    // ignore: unused_element_parameter
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
    final result = await FirebaseFunctions.instanceFor(region: 'asia-south1')
        .httpsCallable('createBibleSession')
        .call({
      'title': title,
      'description': description,
      'category': category,
      // ISO-8601 UTC string — the CF parses with `new Date(iso)`,
      // which understands the trailing Z (UTC) reliably across
      // Node.js runtimes. Sending a local string would risk a
      // timezone-skew bug at the day boundary.
      'scheduledAt': scheduledAt.toUtc().toIso8601String(),
      'durationMinutes': durationMinutes,
      'price': price,
      'maxParticipants': maxParticipants,
      'meetingLink': meetingLink,
      'priestName': priestName,
      'priestPhotoUrl': priestPhotoUrl,
    }).timeout(const Duration(seconds: 20));

    final data = result.data;
    if (data is Map) {
      final id = data['sessionId'];
      if (id is String && id.isNotEmpty) return id;
    }
    throw Exception('Session created but id missing from response');
  }

  // Status guard prevents priests from editing the link on a session
  // that's already in a terminal state. The UI is supposed to hide
  // the edit affordance there, but the repo enforces it as defense
  // in depth — once a session is cancelled or completed, the link
  // is immutable.
  //
  // When the priest actually SETS a link (non-empty value) we kick
  // the `notifyMeetLinkAdded` CF to fan an inbox doc + push out to
  // every active registrant. Best-effort: the link is already saved,
  // so a CF outage doesn't break the user-visible state, it just
  // means registrants will see the link on next refresh instead of
  // via a push.
  //
  // Clearing the link (passing empty string) does NOT fan out — we
  // only fire when there's news worth sharing.
  Future<void> updateMeetingLink(String sessionId, String link) async {
    final snap = await _sessions.doc(sessionId).get().timeout(_timeout);
    if (!snap.exists) {
      throw Exception('Session not found');
    }
    final status = snap.data()?['status'] as String? ?? '';
    if (status != 'upcoming') {
      throw Exception('Cannot update link on a $status session');
    }
    await _sessions
        .doc(sessionId)
        .update({'meetingLink': link})
        .timeout(_timeout);

    if (link.isNotEmpty) {
      try {
        await FirebaseFunctions.instanceFor(region: 'asia-south1')
            .httpsCallable('notifyMeetLinkAdded')
            .call({'sessionId': sessionId})
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        // Best-effort: the link write has already landed.
      }
    }
  }

  // Priest-initiated cancel. Two orchestrated steps:
  //
  //   1. Read + flip the session's status to "cancelled" — this MUST
  //      land. The pre-read status check rejects re-cancellation of
  //      an already-terminal session (UI already gates this; the
  //      repo enforces it as defense in depth).
  //   2. Best-effort: invoke notifyBibleSessionCancellation, which
  //      now owns BOTH halves of the fanout — the in-app /notifications
  //      docs (Admin SDK, bypasses rules) and the OS-level pushes.
  //      A CF outage doesn't break the user-visible cancel because
  //      step 1 has already landed.
  //
  // Per V1 design we DO NOT touch any user's registration row here —
  // paid users (only possible in the 15-min join window) keep their
  // `paid` status and admin processes refunds offline.
  //
  // The legacy client-side notification batch was removed: Firestore
  // rules deny `notifications.create` from clients (correctly), so
  // that batch was silently failing in production and leaving the
  // in-app inbox empty for cancellations.
  //
  // Returns the number of registrations the CF attempted to notify
  // so the priest UI can surface a count in the success snackbar.
  // A return of 0 means either there were no active registrations
  // or the CF failed (logged, not bubbled) — the UI doesn't
  // differentiate.
  Future<int> cancelSession({
    required String sessionId,
    // ignore: unused_element
    required String sessionTitle,
    // ignore: unused_element
    required String priestName,
  }) async {
    // Step 1a: read current status. Cancellation is only legal from
    // 'upcoming'. A live session may have paid users, and silently
    // flipping it to cancelled would strand their money with no
    // refund signal. The priest UI already hides the cancel CTA
    // outside the upcoming state; this is defense in depth so a
    // stale-state tap or a tampered client can't bypass it.
    final snap = await _sessions.doc(sessionId).get().timeout(_timeout);
    if (!snap.exists) {
      throw Exception('Session not found');
    }
    final currentStatus = snap.data()?['status'] as String? ?? '';
    if (currentStatus != 'upcoming') {
      throw Exception(
        currentStatus.isEmpty
            ? 'Session is in an unknown state'
            : 'Can only cancel upcoming sessions — this one is $currentStatus',
      );
    }

    // Step 1b: flip the status. Awaited and not wrapped in try/catch —
    // if this fails the entire cancel fails and the priest sees the
    // error.
    await _sessions.doc(sessionId).update({
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);

    // Step 2: trigger the CF that fans out in-app notifications +
    // OS pushes. The CF re-checks the session is actually cancelled
    // (gate against spam-pushing) and returns `attempted` so the
    // priest UI can surface a count. Best-effort: a CF outage
    // doesn't break the user-visible cancellation — the status flip
    // has already landed. Generous timeout to accommodate large
    // sessions where the CF chunks the fanout.
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'asia-south1')
          .httpsCallable('notifyBibleSessionCancellation');
      final result = await callable.call({'sessionId': sessionId}).timeout(
        const Duration(seconds: 60),
      );
      final data = result.data;
      if (data is Map) {
        final attempted = data['attempted'];
        if (attempted is num) return attempted.toInt();
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // Routed through the `completeBibleSession` CF instead of a direct
  // status flip so the server can do three things the client can't
  // (without a second round-trip): re-validate ownership + status,
  // count paid registrations to compute revenue, and write the
  // priest-facing inbox summary (notifications.create is rule-denied
  // for clients).
  //
  // The CF returns {paidCount, totalRevenue}; we discard it here
  // because the priest UI's snackbar copy doesn't surface those
  // numbers yet — but they're available for a future "Session
  // completed: ₹{N} from {M} attendees" snackbar without another
  // read.
  Future<void> completeSession(String sessionId) async {
    await FirebaseFunctions.instanceFor(region: 'asia-south1')
        .httpsCallable('completeBibleSession')
        .call({'sessionId': sessionId})
        .timeout(const Duration(seconds: 15));
  }

  // ── User-side registration ──────────────────────────────────────

  // Free registration. Single doc write — `registrationCount` on the
  // parent session doc is maintained by the onBibleRegistrationWrite
  // CF trigger (rules deny user-side writes to that field anyway).
  //
  // `set` (non-merge) is intentional so re-registration after a
  // cancel cleanly overwrites the prior `cancelled` doc with a fresh
  // `registered` row. The matching rule allows that transition for
  // the doc owner; the trigger sees status 'cancelled' → 'registered'
  // and bumps the count back up.
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

    await regRef.set({
      'userName': userName,
      'userPhotoUrl': userPhotoUrl,
      'status': 'registered',
      'registeredAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
  }

  // User self-cancel. Single status update — the count decrement is
  // server-side via the onBibleRegistrationWrite trigger. The rule
  // permits the doc owner to flip `status` to 'cancelled'.
  Future<void> cancelRegistration({
    required String sessionId,
    required String userId,
  }) async {
    final regRef = _sessions
        .doc(sessionId)
        .collection('registrations')
        .doc(userId);

    await regRef.update({
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
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

  // ── New-flow CFs ───────────────────────────────────────────────

  // Priest "Start Meeting" → server-side status flip + call-like
  // push to every active registrant. The CF re-checks ownership +
  // status + that no other live session exists for this priest, so
  // a confused double-tap on a stale UI can't put a priest into
  // two-simultaneous-live state.
  //
  // Returns the count of registrants the CF attempted to notify —
  // the priest snackbar surfaces this so they know how many people
  // got the "live now" push.
  Future<int> startBibleSession(String sessionId) async {
    final result = await FirebaseFunctions.instanceFor(region: 'asia-south1')
        .httpsCallable('startBibleSession')
        .call({'sessionId': sessionId}).timeout(const Duration(seconds: 30));

    final data = result.data;
    if (data is Map) {
      final notified = data['notified'];
      if (notified is num) return notified.toInt();
    }
    return 0;
  }

  // User pays to join a LIVE session. Handles two shapes inside the
  // CF:
  //   (a) user was already registered → flips their reg to "paid"
  //   (b) user was never registered → creates the reg as "paid" in
  //       one step (this is the "non-registered user joins by paying
  //       directly" path from the new flow).
  // Both shapes are idempotent: a retry with the same paymentId
  // returns the meeting link without re-charging.
  //
  // Returns the meeting link on success. The CF throws
  // `failed-precondition` if the session is not live (e.g. priest
  // already marked it completed) so the UI can show the right error.
  Future<String> payAndJoinBibleSession({
    required String sessionId,
    required String paymentId,
    required String orderId,
    required String signature,
  }) async {
    final result = await FirebaseFunctions.instanceFor(region: 'asia-south1')
        .httpsCallable('payAndJoinBibleSession')
        .call({
      'sessionId': sessionId,
      'paymentId': paymentId,
      'orderId': orderId,
      'signature': signature,
    }).timeout(const Duration(seconds: 30));

    final data = result.data;
    if (data is Map) {
      final link = data['meetingLink'];
      if (link is String && link.isNotEmpty) return link;
    }
    // CF returned without a link — shouldn't happen on a captured
    // payment but treat as a soft failure rather than silently
    // succeed-with-empty.
    throw Exception('Meeting link not returned by server');
  }

  // Post-session rating. Direct Firestore write — rules permit the
  // owner of the registration doc to write the rating triplet. The
  // server timestamp on `ratedAt` is the authoritative ordering
  // value if we later build a "recent reviews" feed.
  //
  // Rules do NOT gate on session.status, so it's the UI's job to
  // only show the rating sheet after a session has completed. V1
  // accepts this trade-off — adding a status-aware rule means an
  // extra rule-time `get()` for a low-value safety check.
  Future<void> rateBibleSession({
    required String sessionId,
    required int rating,
    String? feedback,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw Exception('Not signed in');
    }
    if (rating < 1 || rating > 5) {
      throw Exception('Rating must be 1–5');
    }

    await _firestore
        .doc('bible_sessions/$sessionId/registrations/$uid')
        .update({
      'rating': rating,
      'feedback': feedback,
      'ratedAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
  }
}
