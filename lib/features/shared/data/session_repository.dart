// Shared data access for the sessions collection. The create path
// must go through a Cloud Function — the CF owns rate-locking,
// balance gating and the "priest is busy / offline" checks that the
// client cannot safely perform. Accept / decline / cancel are plain
// Firestore writes because they only flip the status on a doc that
// already exists and whose ownership is enforced by rules.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:gospel_vox/features/shared/data/session_model.dart';

// Same region as every other callable — mismatching regions is a
// confusing "function not found" instead of a clear error.
const String _kRegion = 'asia-south1';

class SessionRepository {
  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: _kRegion);

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  // Fires the createSessionRequest CF and returns the new sessionId.
  // Throws FirebaseFunctionsException on the server-side error codes
  // (insufficient-balance, priest-offline, priest-busy, …) so the
  // cubit can branch on `e.code` instead of string-matching.
  Future<String> createSessionRequest({
    required String priestId,
    required String type,
  }) async {
    final result = await _functions
        .httpsCallable('createSessionRequest')
        .call({
          'priestId': priestId,
          'type': type,
        })
        .timeout(const Duration(seconds: 15));

    final data = result.data;
    if (data is Map && data['sessionId'] is String) {
      return data['sessionId'] as String;
    }
    throw Exception('createSessionRequest: unexpected response shape');
  }

  // Real-time stream of the session doc. Consumers treat each
  // snapshot as the authoritative state — status flipping from
  // pending → active/declined/expired is what drives navigation.
  Stream<SessionModel> watchSession(String sessionId) {
    return _db.doc('sessions/$sessionId').snapshots().map((snap) {
      if (!snap.exists) {
        throw Exception('Session not found');
      }
      return SessionModel.fromFirestore(snap.id, snap.data()!);
    });
  }

  // Priest taps Accept. We flip status + stamp startedAt so the
  // billingTick CF can use it as the billing epoch. lastHeartbeat
  // gets the same timestamp so the watchdog doesn't kill a
  // session that's one second old.
  Future<void> acceptSession(String sessionId) async {
    await _db
        .doc('sessions/$sessionId')
        .update({
          'status': 'active',
          'startedAt': FieldValue.serverTimestamp(),
          'lastHeartbeat': FieldValue.serverTimestamp(),
        })
        .timeout(const Duration(seconds: 10));
  }

  Future<void> declineSession(String sessionId) async {
    await _db
        .doc('sessions/$sessionId')
        .update({
          'status': 'declined',
          'endedAt': FieldValue.serverTimestamp(),
        })
        .timeout(const Duration(seconds: 10));
  }

  // User taps Cancel while waiting, or the 60-second client-side
  // countdown hits zero. Best-effort — the session may already be
  // accepted/declined by the time this fires, in which case the
  // update throws and the caller swallows it.
  Future<void> cancelSession(String sessionId) async {
    await _db
        .doc('sessions/$sessionId')
        .update({
          'status': 'cancelled',
          'endedAt': FieldValue.serverTimestamp(),
        })
        .timeout(const Duration(seconds: 10));
  }

  // Stream of pending requests for a single priest. The dashboard
  // listens to this with a limit(1) so the first new request auto-
  // navigates to the incoming-request screen.
  Stream<List<SessionModel>> watchPendingRequests(String priestId) {
    return _db
        .collection('sessions')
        .where('priestId', isEqualTo: priestId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => SessionModel.fromFirestore(doc.id, doc.data()))
            .toList());
  }

  // ─── Live chat ───────────────────────────────────────────

  // Write a single message into sessions/{id}/messages. createdAt
  // is a server timestamp so the ordering is authoritative — ordering
  // by client clocks would mis-sort messages sent by two people with
  // skewed phones.
  Future<void> sendMessage({
    required String sessionId,
    required String senderId,
    required String senderName,
    required String text,
  }) async {
    await _db
        .collection('sessions/$sessionId/messages')
        .doc()
        .set({
          'senderId': senderId,
          'senderName': senderName,
          'text': text,
          'createdAt': FieldValue.serverTimestamp(),
        })
        .timeout(const Duration(seconds: 10));
  }

  // Live stream of messages ordered oldest → newest so ListView can
  // render top-down without having to reverse the list every tick.
  Stream<List<ChatMessage>> watchMessages(String sessionId) {
    return _db
        .collection('sessions/$sessionId/messages')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) =>
                ChatMessage.fromFirestore(doc.id, doc.data()))
            .toList());
  }

  // Deduct one minute's worth of coins and credit the priest. Kept
  // server-side because (a) we can't trust the client to bill
  // itself accurately, and (b) the user + priest writes must happen
  // atomically. Returns the fresh balance so the UI doesn't need a
  // second read right after.
  Future<BillingResult> callBillingTick(String sessionId) async {
    final result = await _functions
        .httpsCallable('billingTick')
        .call({'sessionId': sessionId})
        .timeout(const Duration(seconds: 10));

    final raw = result.data;
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    return BillingResult(
      remainingBalance: (data['remainingBalance'] as num?)?.toInt() ?? 0,
      totalCharged: (data['totalCharged'] as num?)?.toInt() ?? 0,
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 0,
      shouldEnd: data['shouldEnd'] as bool? ?? false,
    );
  }

  // Finalises the session. Either side may call — the CF checks
  // participation and idempotently returns the summary if the
  // session is already completed.
  Future<SessionSummary> endSession(String sessionId) async {
    final result = await _functions
        .httpsCallable('endSession')
        .call({'sessionId': sessionId})
        .timeout(const Duration(seconds: 15));

    final raw = result.data;
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    return SessionSummary(
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 0,
      totalCharged: (data['totalCharged'] as num?)?.toInt() ?? 0,
      priestEarnings: (data['priestEarnings'] as num?)?.toInt() ?? 0,
      newBalance: (data['newBalance'] as num?)?.toInt() ?? 0,
    );
  }

  // Keep-alive ping. The watchdog CF will mark a session stale if
  // lastHeartbeat is more than 2 minutes old — a 30s cadence on the
  // client gives us four chances to land the write before the
  // watchdog kicks.
  Future<void> sendHeartbeat(String sessionId) async {
    await _db
        .doc('sessions/$sessionId')
        .update({
          'lastHeartbeat': FieldValue.serverTimestamp(),
        })
        .timeout(const Duration(seconds: 5));
  }

  // ─── Typing presence ────────────────────────────────────

  // Mark this side as actively typing. `since` is set the FIRST
  // time we report typing in a session of activity — kept stable
  // across rapid keystrokes so the other side can compute "how
  // long has X been typing for". The cubit handles the debounce.
  Future<void> setTyping({
    required String sessionId,
    required bool isUserSide,
    required bool typing,
  }) async {
    final prefix = isUserSide ? 'user' : 'priest';
    final updates = <String, Object?>{
      '${prefix}Typing': typing,
    };
    if (typing) {
      // Only stamp `since` when transitioning from not-typing to
      // typing. The cubit guards against re-writing within an
      // active typing burst, so this single set captures the true
      // start time.
      updates['${prefix}TypingSince'] = FieldValue.serverTimestamp();
    } else {
      updates['${prefix}TypingSince'] = null;
    }
    try {
      await _db
          .doc('sessions/$sessionId')
          .update(updates)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Typing presence is purely cosmetic — never let a failed
      // write surface to the user.
    }
  }

  // ─── Reactions ──────────────────────────────────────────

  // Toggle a reaction on a single message. Writing a `null` value
  // via FieldValue.delete() removes the entry — Firestore merges
  // the dotted-path update into the existing map so we don't
  // overwrite anyone else's reaction.
  Future<void> setReaction({
    required String sessionId,
    required String messageId,
    required String userId,
    required String? emoji,
  }) async {
    await _db
        .doc('sessions/$sessionId/messages/$messageId')
        .update({
          'reactions.$userId': emoji ?? FieldValue.delete(),
        })
        .timeout(const Duration(seconds: 5));
  }

  // ─── Balance stream ─────────────────────────────────────

  // Real-time stream of the user's coin balance. The chat cubit
  // subscribes so a successful in-chat top-up reflects the new
  // balance instantly, instead of waiting for the next billingTick
  // to refresh remainingBalance.
  Stream<int> watchUserBalance(String userId) {
    return _db.doc('users/$userId').snapshots().map(
          (snap) => (snap.data()?['coinBalance'] as num?)?.toInt() ?? 0,
        );
  }

  // ─── Voice (Agora) ──────────────────────────────────────

  // Mint an Agora RTC token for this session's channel. The CF
  // validates that the caller is a participant in the session,
  // checks that the session is active and of type "voice", and
  // returns the token + a numeric Agora uid derived from the
  // caller's Firebase uid (Agora needs a 32-bit int, not a
  // string). Channel name on the SDK side is the sessionId.
  Future<Map<String, dynamic>> getAgoraToken(String sessionId) async {
    final result = await _functions
        .httpsCallable('generateAgoraToken')
        .call({'sessionId': sessionId})
        .timeout(const Duration(seconds: 10));

    final raw = result.data;
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    final token = data['token'];
    if (token is! String || token.isEmpty) {
      throw Exception('Failed to generate voice token');
    }
    return {
      'token': token,
      'uid': (data['uid'] as num?)?.toInt() ?? 0,
      'channelName': data['channelName'] as String? ?? sessionId,
    };
  }
}
