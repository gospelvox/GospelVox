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

  // Post-session feedback — written by post_session_page after the
  // user picks a star rating + types optional notes. Both nullable
  // because the user may close the post-session screen without
  // rating, in which case neither field is ever set on the doc.
  final double? userRating;
  final String? userFeedback;

  // Priest-initiated follow-up nudge state. Written exclusively by
  // the sendFollowUp CF — never by the client. `followUpSent` gates
  // the "Send Follow-up" button on the session detail page so each
  // completed session can be nudged at most once.
  final bool followUpSent;
  final int? followUpTemplate;
  final DateTime? followUpSentAt;

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
    this.userRating,
    this.userFeedback,
    this.followUpSent = false,
    this.followUpTemplate,
    this.followUpSentAt,
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
      userRating: (data['userRating'] as num?)?.toDouble(),
      userFeedback: data['userFeedback'] as String?,
      followUpSent: data['followUpSent'] as bool? ?? false,
      followUpTemplate: (data['followUpTemplate'] as num?)?.toInt(),
      followUpSentAt: ts(data['followUpSentAt']),
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

// A single chat bubble. Lives under sessions/{id}/messages for
// session-bound bubbles, OR is synthesized from notifications/{id}
// for priest-initiated free messages (kind == priestMessage). We
// keep one model for both because the chat thread merges them by
// timestamp and the view rendering is mostly the same — only the
// interaction surface differs (no reactions / no replies on free
// messages, plus a small badge to mark them).
//
// Why one model not two: a bubble is a bubble. Forking the type
// hierarchy would force every renderer downstream to switch on
// kind anyway, so we keep the discrimination on a single field.
enum ChatMessageKind {
  // Lives under sessions/{id}/messages, billed inside an active or
  // completed paid session. This is the default and covers every
  // bubble the chat surface has rendered prior to free messaging.
  session,
  // Priest-initiated free message written by sendPriestMessage CF
  // to the notifications collection. Read-only in the chat thread —
  // user can long-press to Report or tap the sticky CTA to Reply
  // (which opens a paid session). Reactions are blocked.
  priestMessage,
}

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

  // The sessions/{id} doc this message lives under. Stamped by the
  // chat cubit (never read from Firestore — the path implies it),
  // so the live chat surface can tell past-session bubbles apart
  // from current-session bubbles for divider placement and to
  // disable interactions on history. Empty for free messages
  // (kind == priestMessage) — they live outside any session.
  final String sessionId;

  // Distinguishes a session-bound bubble from a free message. The
  // chat view uses this to (a) place the small "Free message" badge,
  // (b) block long-press reactions, (c) suppress sender-side
  // interactions like edit/delete that don't make sense on a one-way
  // delivered message.
  final ChatMessageKind kind;

  // Only meaningful for `kind == priestMessage`. False when the user
  // had muted the sending priest at the time of write — the CF still
  // records the doc so the priest can see their own outbox, but the
  // user-side chat + inbox filter on this so a muted message never
  // surfaces to the recipient. Always true for session bubbles.
  final bool delivered;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    this.createdAt,
    this.reactions = const {},
    this.isPending = false,
    this.sessionId = '',
    this.kind = ChatMessageKind.session,
    this.delivered = true,
  });

  factory ChatMessage.fromFirestore(
    String docId,
    Map<String, dynamic> data, {
    String sessionId = '',
  }) {
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
      sessionId: sessionId,
    );
  }

  // Promotes a notifications/{id} doc of type 'priest_message' (or
  // legacy 'follow_up') into a ChatMessage so the chat surface can
  // render it inline alongside session bubbles. The notification
  // doc carries priestId/priestName/body — we map them to
  // senderId/senderName/text so the existing rendering code works
  // unchanged.
  factory ChatMessage.fromNotification(
    String docId,
    Map<String, dynamic> data,
  ) {
    return ChatMessage(
      id: docId,
      senderId: data['priestId'] as String? ?? '',
      senderName: data['priestName'] as String? ?? '',
      text: data['body'] as String? ?? '',
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
      kind: ChatMessageKind.priestMessage,
      // Defaults to true for legacy follow_up docs that pre-date the
      // delivered field — they were always delivered (mute didn't
      // exist when they were written), so missing-field === true is
      // the right interpretation.
      delivered: data['delivered'] as bool? ?? true,
    );
  }

  // Optimistic bubble used by the cubit between "tap Send" and
  // the moment Firestore returns the canonical message.
  factory ChatMessage.pending({
    required String tempId,
    required String senderId,
    required String senderName,
    required String text,
    required String sessionId,
  }) {
    return ChatMessage(
      id: tempId,
      senderId: senderId,
      senderName: senderName,
      text: text,
      createdAt: DateTime.now(),
      isPending: true,
      sessionId: sessionId,
    );
  }

  // Optimistic bubble for a priest-initiated free message awaiting
  // sendPriestMessage CF confirmation. Mirrors `pending` but flags
  // the kind so the bubble renders with the free-message visual
  // treatment (no reactions, "Free message" badge).
  factory ChatMessage.pendingPriestMessage({
    required String tempId,
    required String priestId,
    required String priestName,
    required String text,
  }) {
    return ChatMessage(
      id: tempId,
      senderId: priestId,
      senderName: priestName,
      text: text,
      createdAt: DateTime.now(),
      isPending: true,
      kind: ChatMessageKind.priestMessage,
    );
  }

  // Returns a copy with `sessionId` stamped — used by the cubit when
  // it merges the live messages stream (which doesn't carry the id
  // through the snapshot) with prefetched past messages.
  ChatMessage withSessionId(String sessionId) {
    if (this.sessionId == sessionId) return this;
    return ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      text: text,
      createdAt: createdAt,
      reactions: reactions,
      isPending: isPending,
      sessionId: sessionId,
      kind: kind,
      delivered: delivered,
    );
  }

  bool get isPriestMessage => kind == ChatMessageKind.priestMessage;
}

// Per-session metadata for past-session dividers in the live chat.
// Holds just what the divider widget needs — date and duration —
// so the chat state can carry a tiny lookup map without dragging
// the full SessionModel around.
class PastSessionMeta {
  final DateTime date;
  final int durationMinutes;

  const PastSessionMeta({
    required this.date,
    required this.durationMinutes,
  });
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
