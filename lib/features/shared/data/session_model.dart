// Shape of a session document. Shared between the user and priest
// sides because both read from — and the server writes to — the same
// sessions collection; keeping a single model stops the two halves
// from drifting as fields get added. The rate, commission, and user
// balance are denormalized at creation time so the billing flow is
// insulated from admins later rewriting app_config.

import 'package:cloud_firestore/cloud_firestore.dart';

class SessionModel {
  final String id;
  final String userId;
  final String priestId;
  // chat | voice
  final String type;
  // pending | active | completed | declined | expired | cancelled
  final String status;

  // Locked at creation so changes to app_config mid-session don't
  // retroactively alter what the user owes or what the priest earns.
  final int ratePerMinute;
  final int commissionPercent;

  // Balance snapshot at creation, used to cap the billable duration.
  final int userBalance;

  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final int durationMinutes;
  final int totalCharged;
  final int priestEarnings;
  final DateTime? lastHeartbeat;

  // Why the session terminated. Set by the Cloud Functions:
  //   • billingTick on insufficient balance → "balance_zero"
  //   • sessionWatchdog on stale heartbeat  → "watchdog_timeout"
  //   • endSession                          → endedBy field instead
  // The chat cubit reads this field so the post-session screens
  // can render the precise reason ("Your balance ran out") rather
  // than a generic "session ended".
  final String endReason;

  // Typing presence — each side updates its own field while the
  // user is composing. The `Since` timestamp is set when typing
  // begins and cleared on idle, letting the other side compute
  // "X has been typing for Y seconds" → "is composing a longer
  // response…" once Y exceeds 10s.
  final bool userTyping;
  final DateTime? userTypingSince;
  final bool priestTyping;
  final DateTime? priestTypingSince;

  // Denormalised user info so the priest's incoming screen renders
  // without an extra users/{uid} read.
  final String userName;
  final String userPhotoUrl;

  // Denormalised priest info for the user's waiting screen — same
  // reasoning, avoids a second priests/{uid} fetch on an anxious
  // screen where every network hop is a stall.
  final String priestName;
  final String priestPhotoUrl;
  final String priestDenomination;

  const SessionModel({
    required this.id,
    required this.userId,
    required this.priestId,
    required this.type,
    required this.status,
    required this.ratePerMinute,
    required this.commissionPercent,
    required this.userBalance,
    this.createdAt,
    this.startedAt,
    this.endedAt,
    this.durationMinutes = 0,
    this.totalCharged = 0,
    this.priestEarnings = 0,
    this.lastHeartbeat,
    this.endReason = '',
    this.userTyping = false,
    this.userTypingSince,
    this.priestTyping = false,
    this.priestTypingSince,
    required this.userName,
    required this.userPhotoUrl,
    required this.priestName,
    required this.priestPhotoUrl,
    required this.priestDenomination,
  });

  // createdAt and friends can land as null during the write-then-read
  // window where the server timestamp hasn't filled in yet — guard
  // against the plain `as Timestamp` cast blowing up in that gap.
  factory SessionModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    DateTime? ts(dynamic v) =>
        v is Timestamp ? v.toDate() : null;

    return SessionModel(
      id: docId,
      userId: data['userId'] as String? ?? '',
      priestId: data['priestId'] as String? ?? '',
      type: data['type'] as String? ?? 'chat',
      status: data['status'] as String? ?? 'pending',
      ratePerMinute: (data['ratePerMinute'] as num?)?.toInt() ?? 10,
      commissionPercent:
          (data['commissionPercent'] as num?)?.toInt() ?? 20,
      userBalance: (data['userBalance'] as num?)?.toInt() ?? 0,
      createdAt: ts(data['createdAt']),
      startedAt: ts(data['startedAt']),
      endedAt: ts(data['endedAt']),
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 0,
      totalCharged: (data['totalCharged'] as num?)?.toInt() ?? 0,
      priestEarnings: (data['priestEarnings'] as num?)?.toInt() ?? 0,
      lastHeartbeat: ts(data['lastHeartbeat']),
      endReason: data['endReason'] as String? ?? '',
      userTyping: data['userTyping'] as bool? ?? false,
      userTypingSince: ts(data['userTypingSince']),
      priestTyping: data['priestTyping'] as bool? ?? false,
      priestTypingSince: ts(data['priestTypingSince']),
      userName: data['userName'] as String? ?? '',
      userPhotoUrl: data['userPhotoUrl'] as String? ?? '',
      priestName: data['priestName'] as String? ?? '',
      priestPhotoUrl: data['priestPhotoUrl'] as String? ?? '',
      priestDenomination: data['priestDenomination'] as String? ?? '',
    );
  }

  bool get isPending => status == 'pending';
  bool get isActive => status == 'active';
  bool get isCompleted => status == 'completed';
  bool get isDeclined => status == 'declined';
  bool get isExpired => status == 'expired';
  bool get isCancelled => status == 'cancelled';
  bool get isChat => type == 'chat';
  bool get isVoice => type == 'voice';

  // How many whole minutes the locked balance buys at the locked
  // rate. Used by the chat/voice UI to decide when to warn "you have
  // N minutes left" without having to re-derive the math each time.
  int get affordableMinutes =>
      ratePerMinute > 0 ? userBalance ~/ ratePerMinute : 0;
}

// A single chat bubble. Lives under sessions/{id}/messages — we keep
// it as a subcollection (not a single messages array on the session
// doc) so we can paginate long chats and stream only new messages
// without re-downloading the whole transcript on every snapshot.
class ChatMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime? createdAt;
  // {uid → emoji}. Each participant can leave one reaction per
  // message; tapping the same emoji again clears it. Stored as a
  // map (not a subcollection) so the chat stream picks reactions
  // up in the same snapshot as the message itself — no second
  // fetch needed to render a bubble with its reactions.
  final Map<String, String> reactions;
  // True for client-side optimistic bubbles that haven't been
  // confirmed by the Firestore stream yet. Drives the small ⏱
  // status icon under outbound bubbles.
  final bool isPending;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    this.createdAt,
    this.reactions = const {},
    this.isPending = false,
  });

  factory ChatMessage.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    final raw = data['reactions'];
    final reactions = raw is Map
        ? Map<String, String>.from(
            raw.map((k, v) => MapEntry(k.toString(), v.toString())),
          )
        : const <String, String>{};

    return ChatMessage(
      id: docId,
      senderId: data['senderId'] as String? ?? '',
      senderName: data['senderName'] as String? ?? '',
      text: data['text'] as String? ?? '',
      // Server timestamps briefly land as null right after a write,
      // before the server has stamped them — guard the cast.
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
      reactions: reactions,
    );
  }

  // Optimistic bubble used by the cubit between "tap Send" and
  // the moment Firestore returns the canonical message.
  factory ChatMessage.pending({
    required String tempId,
    required String senderId,
    required String senderName,
    required String text,
  }) {
    return ChatMessage(
      id: tempId,
      senderId: senderId,
      senderName: senderName,
      text: text,
      createdAt: DateTime.now(),
      isPending: true,
    );
  }
}

// Return shape of the billingTick Cloud Function. `shouldEnd` is
// the authoritative signal — the client stops its local timers and
// transitions to the post-session flow whenever the server says so.
class BillingResult {
  final int remainingBalance;
  final int totalCharged;
  final int durationMinutes;
  final bool shouldEnd;

  const BillingResult({
    required this.remainingBalance,
    required this.totalCharged,
    required this.durationMinutes,
    required this.shouldEnd,
  });
}

// Return shape of endSession, reused by both the post-session screen
// (user side) and the session-summary screen (priest side).
class SessionSummary {
  final int durationMinutes;
  final int totalCharged;
  final int priestEarnings;
  final int newBalance;

  const SessionSummary({
    required this.durationMinutes,
    required this.totalCharged,
    required this.priestEarnings,
    required this.newBalance,
  });
}
