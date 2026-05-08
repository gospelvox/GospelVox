// Globally-mounted listener that pushes /priest/incoming whenever a
// fresh pending session lands for the signed-in priest, NO MATTER
// which page they're currently on (settings, wallet, my-users,
// session summary, dashboard, anywhere).
//
// Replaces the dashboard-only listener that disappeared the moment
// the priest navigated away from /priest. That was a critical
// "missed call" bug: any user calling a priest who was on a session-
// summary, wallet, or settings page would silently expire after 60s
// without the priest ever seeing the incoming-request screen — the
// only path back was for the priest to manually return to the
// dashboard within the 60s window. Now the listener is owned by
// this service and lives for the whole signed-in lifetime of the
// priest's session, so the call routing is decoupled from whatever
// page they happen to be looking at.
//
// Lifecycle:
//   • init() is called once from main.dart after Firebase is ready.
//   • Subscribes to FirebaseAuth.authStateChanges and gates start /
//     stop on the signed-in user's role. Non-priests are ignored;
//     sign-out / role change cleanly tears every stream down.
//   • While a priest is active, two streams run:
//       priests/{uid}      — track isActivated so we can pass it
//                            into the incoming-request page extras
//                            (the activation gate inside the cubit
//                            decides whether Accept is allowed).
//       sessions where     — the actual pending-request listener.
//         priestId==uid &&  Same query the dashboard used; we just
//         status==pending   own it at a higher level.
//
// Push routing uses the global `appRouter` (GoRouter) directly
// rather than any in-tree BuildContext — same pattern the missed-
// request foreground banner already uses for the same reason
// (the listener has no Navigator ancestor).
//
// Dedupe + freshness: the same request id is only routed once per
// app lifetime (cleared on sign-out) and requests older than 60s
// are skipped because they're about to expire any second.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

class PriestIncomingRequestService {
  static PriestIncomingRequestService? _instance;
  factory PriestIncomingRequestService() =>
      _instance ??= PriestIncomingRequestService._();
  PriestIncomingRequestService._();

  StreamSubscription<User?>? _authSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _priestSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sessionSub;

  bool _isActivated = false;
  String? _activeUid;
  final Set<String> _seenRequestIds = <String>{};

  // Called once from main.dart after Firebase init. Idempotent —
  // multiple calls just re-bind the auth listener.
  void init() {
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }

  Future<void> _onAuthChanged(User? user) async {
    final uid = user?.uid;
    if (uid == _activeUid) return;

    // Tear down whatever was running for the previous user before
    // bringing up listeners for the new one. Always clear the seen-
    // ids set so a request from a previous account can't be deduped
    // against the new one.
    _stopStreams();
    _activeUid = null;
    _isActivated = false;
    _seenRequestIds.clear();

    if (uid == null) return;

    // Only attach for priests. Reading users/{uid}.role here is one
    // extra read per sign-in but keeps non-priest sessions from
    // paying the cost of two persistent streams.
    try {
      final userDoc = await FirebaseFirestore.instance
          .doc('users/$uid')
          .get()
          .timeout(const Duration(seconds: 5));
      final role = userDoc.data()?['role'] as String?;
      if (role != 'priest') return;
    } catch (e) {
      debugPrint('[PriestIncomingRequest] role lookup failed: $e');
      return;
    }

    _activeUid = uid;
    _attachPriestDocStream(uid);
    _attachSessionStream(uid);
  }

  void _attachPriestDocStream(String uid) {
    _priestSub = FirebaseFirestore.instance
        .doc('priests/$uid')
        .snapshots()
        .listen(
      (snap) {
        _isActivated = (snap.data()?['isActivated'] as bool?) ?? false;
      },
      onError: (e) {
        debugPrint('[PriestIncomingRequest] priest doc stream failed: $e');
      },
    );
  }

  void _attachSessionStream(String uid) {
    // Same query the dashboard used. NO orderBy on the server side
    // because pairing two equality filters with orderBy requires a
    // composite index that isn't always provisioned in fresh
    // environments — sort client-side instead.
    _sessionSub = FirebaseFirestore.instance
        .collection('sessions')
        .where('priestId', isEqualTo: uid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen(
      (snap) {
        if (snap.docs.isEmpty) return;

        final docs = snap.docs.toList()
          ..sort((a, b) {
            final aTime = a.data()['createdAt'] as Timestamp?;
            final bTime = b.data()['createdAt'] as Timestamp?;
            if (aTime == null && bTime == null) return 0;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });

        final doc = docs.first;
        if (_seenRequestIds.contains(doc.id)) return;

        final session = SessionModel.fromFirestore(doc.id, doc.data());

        // Skip stale requests — anything >60s old is about to
        // expire via the watchdog and routing to the incoming
        // screen would just flash the expired sheet immediately.
        if (session.createdAt != null) {
          final age = DateTime.now().difference(session.createdAt!);
          if (age.inSeconds > 60) return;
        }

        _seenRequestIds.add(doc.id);
        debugPrint(
          '[PriestIncomingRequest] Routing /priest/incoming for '
          'session ${doc.id} from ${session.userName}',
        );

        // Use the global appRouter — the service has no widget
        // tree and therefore no in-context GoRouter. push() (not
        // go) so the priest pops back to whatever page they were
        // on (summary, wallet, my-users, dashboard) after they
        // accept or decline the call.
        appRouter.push('/priest/incoming', extra: {
          'session': session,
          'isActivated': _isActivated,
        });
      },
      onError: (e) {
        debugPrint('[PriestIncomingRequest] session stream failed: $e');
      },
    );
  }

  void _stopStreams() {
    _priestSub?.cancel();
    _priestSub = null;
    _sessionSub?.cancel();
    _sessionSub = null;
  }

  void dispose() {
    _authSub?.cancel();
    _authSub = null;
    _stopStreams();
  }
}
