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
  //
  // We also flip the priest's isBusy=true atomically with the
  // session activation. isBusy is owned by the session system —
  // not by the dashboard or the availability page — so user-side
  // home rendering ("Busy · in session") matches the actual
  // session state without any client-side reconciliation.
  // endSession + sessionWatchdog clear isBusy=false when the
  // session terminates.
  Future<void> acceptSession(String sessionId) async {
    final sessionRef = _db.doc('sessions/$sessionId');
    final sessionSnap = await sessionRef
        .get()
        .timeout(const Duration(seconds: 10));
    final priestId = sessionSnap.data()?['priestId'] as String?;

    final batch = _db.batch();
    batch.update(sessionRef, {
      'status': 'active',
      'startedAt': FieldValue.serverTimestamp(),
      'lastHeartbeat': FieldValue.serverTimestamp(),
    });
    if (priestId != null && priestId.isNotEmpty) {
      batch.update(_db.doc('priests/$priestId'), {
        'isBusy': true,
      });
    }
    await batch.commit().timeout(const Duration(seconds: 10));
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

  // User taps Cancel while waiting. Best-effort — the session may
  // already be accepted/declined by the time this fires, in which
  // case the update throws and the caller swallows it.
  //
  // Note: 60-second client-side timeout uses expireSessionRequest
  // (CF) instead so the priest gets a "missed request" notification.
  // Active user-cancel writes 'cancelled' (no notification).
  Future<void> cancelSession(String sessionId) async {
    await _db
        .doc('sessions/$sessionId')
        .update({
          'status': 'cancelled',
          'endedAt': FieldValue.serverTimestamp(),
        })
        .timeout(const Duration(seconds: 10));
  }

  // Fires the expireSessionRequest CF when the user-side 60-second
  // countdown elapses without a priest response. The CF atomically
  // marks the session as expired AND writes a missed_request
  // notification + push to the priest, so a successful call always
  // produces a priest-side signal that someone tried to reach them.
  //
  // Fire-and-forget from the cubit — the user-visible state already
  // transitioned to "Session expired" locally before this resolves,
  // and the watchdog 5-minute cron is a safety net for any failed
  // call so the priest still gets notified.
  Future<void> expireSessionRequest(String sessionId) async {
    await _functions
        .httpsCallable('expireSessionRequest')
        .call({'sessionId': sessionId})
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
    // Optional quoted-message snapshot when the user swiped a prior
    // bubble to reply. Written as a nested map so a single read on
    // the message doc gives the renderer everything it needs.
    ReplyTarget? replyTo,
  }) async {
    await _db
        .collection('sessions/$sessionId/messages')
        .doc()
        .set({
          'senderId': senderId,
          'senderName': senderName,
          'text': text,
          'createdAt': FieldValue.serverTimestamp(),
          if (replyTo != null) 'replyTo': replyTo.toMap(),
        })
        .timeout(const Duration(seconds: 10));
  }

  // Live stream of messages ordered oldest → newest so ListView can
  // render top-down without having to reverse the list every tick.
  // Each message is stamped with its `sessionId` so the chat surface
  // can tell live bubbles apart from prefetched history when the two
  // are merged into a single list.
  Stream<List<ChatMessage>> watchMessages(String sessionId) {
    return _db
        .collection('sessions/$sessionId/messages')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => ChatMessage.fromFirestore(
                  doc.id,
                  doc.data(),
                  sessionId: sessionId,
                ))
            .toList());
  }

  // Prefetch every chat message from this user-priest pair's prior
  // completed sessions, capped to the most recent `cap`. Powers the
  // "WhatsApp-style continuity" inside the live chat — past bubbles
  // appear above the new ones with session dividers between them.
  //
  // Querying on the (userId, priestId) pair uses two equality
  // filters with no composite index needed; status / type / current-
  // session exclusion are applied client-side because the per-pair
  // result set is bounded.
  //
  // Returns a paired record:
  //   • messages — chronological, oldest first, with sessionId
  //     stamped on each so the view layer can split by session
  //     boundary for dividers.
  //   • meta     — { sessionId → PastSessionMeta(date, duration) }
  //     for divider rendering ("Session · May 1 · 15 min").
  Future<({
    List<ChatMessage> messages,
    Map<String, PastSessionMeta> meta,
  })> getPastChatMessages({
    required String userId,
    required String priestId,
    required String excludeSessionId,
    int cap = 200,
  }) async {
    final snap = await _db
        .collection('sessions')
        .where('userId', isEqualTo: userId)
        .where('priestId', isEqualTo: priestId)
        .get()
        .timeout(const Duration(seconds: 10));

    // Eligible = completed chat OR voice sessions, ordered oldest →
    // newest so older context reads top-down once we slice for the
    // cap. Voice sessions are synthesized as a single inline
    // call-entry row (WhatsApp-style) rather than expanded into
    // their (non-existent) messages subcollection.
    final eligible = snap.docs
        .map((d) => SessionModel.fromFirestore(d.id, d.data()))
        .where((s) {
          if (s.id == excludeSessionId) return false;
          if (s.status != 'completed') return false;
          if (s.type != 'chat' && s.type != 'voice') return false;
          final ended = s.endedAt ?? s.createdAt;
          return ended != null;
        })
        .toList()
      ..sort((a, b) {
        final aTime = a.endedAt ?? a.createdAt ?? DateTime(2000);
        final bTime = b.endedAt ?? b.createdAt ?? DateTime(2000);
        return aTime.compareTo(bTime);
      });

    if (eligible.isEmpty) {
      return (
        messages: const <ChatMessage>[],
        meta: const <String, PastSessionMeta>{},
      );
    }

    // Fan out subcollection reads in parallel — for a typical
    // user-priest pair (1–10 sessions) this lands in 200–400ms
    // regardless of count, way better than serial round-trips.
    // Voice sessions short-circuit to a single synthetic call row
    // and skip the Firestore round-trip entirely.
    final perSessionMessages = await Future.wait(eligible.map((s) async {
      if (s.type == 'voice') {
        return <ChatMessage>[
          ChatMessage.callEntry(
            sessionId: s.id,
            callerId: s.userId,
            callerName:
                s.userName.isNotEmpty ? s.userName : 'User',
            durationMinutes: s.durationMinutes,
            // Anchor at startedAt when present so the entry lands
            // chronologically next to the chat bubbles that came
            // before/after; fall back to endedAt / createdAt the
            // same way the sort key does.
            at: s.startedAt ?? s.endedAt ?? s.createdAt,
          ),
        ];
      }
      try {
        final msgSnap = await _db
            .collection('sessions/${s.id}/messages')
            .orderBy('createdAt', descending: false)
            .get()
            .timeout(const Duration(seconds: 8));
        return msgSnap.docs
            .map((d) => ChatMessage.fromFirestore(
                  d.id,
                  d.data(),
                  sessionId: s.id,
                ))
            .toList();
      } catch (_) {
        // A single failed subcollection read shouldn't blank the
        // entire history — return empty for that session and let
        // the rest render.
        return const <ChatMessage>[];
      }
    }));

    final all = <ChatMessage>[];
    for (final list in perSessionMessages) {
      all.addAll(list);
    }

    // Apply cap from the END (most recent kept). Keeps newer
    // context closest to the live conversation, drops the oldest
    // bubbles when the user has a very long history.
    final capped = all.length > cap ? all.sublist(all.length - cap) : all;

    // Build meta only for chat sessions whose messages survived
    // the cap — a divider for a session whose bubbles all got
    // truncated would dangle in the UI. Voice sessions are
    // excluded: the synthesized call-entry row already shows date
    // and duration, so a divider above it would just repeat the
    // same info.
    final survivingSessionIds = <String>{
      for (final m in capped) m.sessionId,
    };
    final meta = <String, PastSessionMeta>{};
    for (final s in eligible) {
      if (s.type != 'chat') continue;
      if (!survivingSessionIds.contains(s.id)) continue;
      final ts = s.endedAt ?? s.createdAt;
      if (ts == null) continue;
      meta[s.id] = PastSessionMeta(
        date: ts,
        durationMinutes: s.durationMinutes,
      );
    }

    return (messages: capped, meta: meta);
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

  // ─── Priest free messaging ──────────────────────────────

  // Fires the sendPriestMessage CF. Returns the full callable result
  // so the caller can decide what to do on `delivered: false` (the
  // CF reports this when the user has muted the priest — the send
  // technically succeeded but no notification or push went out).
  Future<({
    bool success,
    bool delivered,
    int remainingPerUserToday,
    int remainingTotalToday,
  })> sendPriestMessage({
    required String userId,
    required String text,
  }) async {
    final result = await _functions
        .httpsCallable('sendPriestMessage')
        .call({
          'userId': userId,
          'text': text,
        })
        .timeout(const Duration(seconds: 15));

    final raw = result.data;
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    return (
      success: data['success'] as bool? ?? false,
      delivered: data['delivered'] as bool? ?? false,
      remainingPerUserToday:
          (data['remainingPerUserToday'] as num?)?.toInt() ?? 0,
      remainingTotalToday:
          (data['remainingTotalToday'] as num?)?.toInt() ?? 0,
    );
  }

  // Reads every priest-initiated free message between this user and
  // this priest. Renders them as ChatMessages (kind=priestMessage)
  // so the chat thread can merge them by timestamp with session
  // bubbles. Includes both the new 'priest_message' type and the
  // legacy 'follow_up' type — old follow-up notifications stay
  // visible for backwards compatibility.
  //
  // We query without orderBy because pairing equality + orderBy
  // would require a composite index; one user-priest pair has at
  // most ~hundreds of free messages, so client-side sorting is
  // negligible. Same approach SessionHistoryRepository uses.
  Future<List<ChatMessage>> getPriestFreeMessages({
    required String userId,
    required String priestId,
  }) async {
    final snap = await _db
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('priestId', isEqualTo: priestId)
        .where('type', whereIn: ['priest_message', 'follow_up'])
        .get()
        .timeout(const Duration(seconds: 8));

    final messages = snap.docs
        .map((d) => ChatMessage.fromNotification(d.id, d.data()))
        .where((m) => m.text.isNotEmpty)
        .toList()
      ..sort((a, b) {
        final aTime = a.createdAt ?? DateTime(2000);
        final bTime = b.createdAt ?? DateTime(2000);
        return aTime.compareTo(bTime);
      });

    return messages;
  }

  // Live stream of free messages for this (user, priest) pair —
  // used by the priest-side per-user chat view AND the user-side
  // live chat so a freshly-sent free message lands on both screens
  // within ~1s without a manual refresh. Same query as
  // getPriestFreeMessages but as a snapshot stream.
  Stream<List<ChatMessage>> watchPriestFreeMessages({
    required String userId,
    required String priestId,
  }) {
    return _db
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('priestId', isEqualTo: priestId)
        .where('type', whereIn: ['priest_message', 'follow_up'])
        .snapshots()
        .map((snap) {
      final messages = snap.docs
          .map((d) => ChatMessage.fromNotification(d.id, d.data()))
          .where((m) => m.text.isNotEmpty)
          .toList()
        ..sort((a, b) {
          final aTime = a.createdAt ?? DateTime(2000);
          final bTime = b.createdAt ?? DateTime(2000);
          return aTime.compareTo(bTime);
        });
      return messages;
    });
  }

  // ─── User mute (per priest) ─────────────────────────────

  // Live stream of the current user's muted-priest list. Drives the
  // chat header's mute toggle state and lets the priest_message
  // merger filter out messages from muted priests purely on the
  // client (the CF also enforces this, so the filter is defence in
  // depth, not the only line of safety).
  Stream<Set<String>> watchMutedPriestIds(String userId) {
    return _db.doc('users/$userId').snapshots().map((snap) {
      final raw = snap.data()?['mutedPriestIds'];
      if (raw is List) {
        return raw.whereType<String>().toSet();
      }
      return const <String>{};
    });
  }

  Future<void> setPriestMuted({
    required String userId,
    required String priestId,
    required bool muted,
  }) async {
    await _db
        .doc('users/$userId')
        .set(
          {
            'mutedPriestIds': muted
                ? FieldValue.arrayUnion([priestId])
                : FieldValue.arrayRemove([priestId]),
          },
          SetOptions(merge: true),
        )
        .timeout(const Duration(seconds: 5));
  }

  // Files a report against a single priest free message. The admin
  // reports queue picks it up via the existing reports collection —
  // no admin-side changes needed.
  Future<void> reportPriestMessage({
    required String reportedPriestId,
    required String reportedPriestName,
    required String reporterUserId,
    required String reporterName,
    required String messageText,
    required String messageId,
  }) async {
    await _db.collection('reports').add({
      'reportedBy': reporterUserId,
      'reporterName': reporterName,
      'reportedUser': reportedPriestId,
      'reportedUserName': reportedPriestName,
      'reason': 'priest_message',
      'description': messageText,
      // Tag the source message id so the admin can correlate the
      // report back to the exact notifications/{id} doc.
      'sessionId': null,
      'messageId': messageId,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    }).timeout(const Duration(seconds: 8));
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
