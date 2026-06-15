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

  // Two-way connection confirmation. Each side stamps its own field
  // the moment its client confirms a REAL connection to the other
  // party (voice: Agora onUserJoined; chat: both chat screens open).
  // Billing is gated server-side on BOTH being set — a session that
  // never reaches a confirmed connection is never charged and the
  // priest earns nothing. This is what stops a user being billed for
  // a call that never connected (priest stuck "Connecting…").
  final DateTime? userConnectedAt;
  final DateTime? priestConnectedAt;

  // Live presence heartbeats for CHAT sessions — each side stamps its
  // own field every few seconds while its chat screen is open, and
  // watches the OTHER side's field. If the peer's stamp goes stale
  // (they killed the app / lost the network / never showed up), the
  // watching side ends the chat so the meter stops and both are freed.
  // This is the chat-equivalent of voice's Agora onUserOffline. Kept
  // separate from lastHeartbeat (user-only, drives the watchdog) so a
  // priest's presence can never keep a user-abandoned session alive.
  final DateTime? userPresenceAt;
  final DateTime? priestPresenceAt;

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

  // Priest's public reply to the user's review. Owned by the
  // replyToReview CF — the client never writes here directly because
  // the 300-char cap and 24h edit window have to be enforced server-
  // side. createdAt stays stable across edits so the lock window
  // measures from first publish; updatedAt advances on every edit.
  final ReviewReply? priestReply;

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
    this.userConnectedAt,
    this.priestConnectedAt,
    this.userPresenceAt,
    this.priestPresenceAt,
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
    this.priestReply,
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
      userConnectedAt: ts(data['userConnectedAt']),
      priestConnectedAt: ts(data['priestConnectedAt']),
      userPresenceAt: ts(data['userPresenceAt']),
      priestPresenceAt: ts(data['priestPresenceAt']),
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
      priestReply: data['priestReply'] is Map
          ? ReviewReply.fromMap(
              Map<String, dynamic>.from(data['priestReply'] as Map),
            )
          : null,
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

// Priest's reply to a single rated session. Server-owned: written
// only by the replyToReview CF, which enforces the 300-character cap
// and the 24-hour edit window. The client uses `isEditable` to gate
// the Edit affordance — once the window closes, the UI hides the
// edit button instead of letting the CF reject the call.
class ReviewReply {
  final String text;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const ReviewReply({
    required this.text,
    this.createdAt,
    this.updatedAt,
  });

  factory ReviewReply.fromMap(Map<String, dynamic> data) {
    DateTime? ts(dynamic v) =>
        v is Timestamp ? v.toDate() : null;
    return ReviewReply(
      text: data['text'] as String? ?? '',
      createdAt: ts(data['createdAt']),
      updatedAt: ts(data['updatedAt']),
    );
  }

  // True for 24 hours after first publish. createdAt is null only
  // during the brief write-then-read window where the server stamp
  // hasn't been resolved yet — treat that as editable so the priest
  // doesn't see the affordance disappear momentarily after sending.
  bool get isEditable {
    final created = createdAt;
    if (created == null) return true;
    return DateTime.now().difference(created).inHours < 24;
  }

  bool get wasEdited {
    final c = createdAt;
    final u = updatedAt;
    if (c == null || u == null) return false;
    return u.difference(c).inSeconds > 5;
  }
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
  // to the notifications collection. Read-only in the chat thread.
  priestMessage,
  // Synthesized inline entry for a past voice (or future video)
  // session between the same user-priest pair. Renders as a
  // WhatsApp-style "Voice call · 5 min" row with a phone icon;
  // tap behavior is decided by the host page (user-side surfaces
  // redial via the existing waiting-page flow, priest-side and
  // live-chat surfaces leave it inert).
  callEntry,
}

// Denormalized "quoted message" snapshot stamped onto an outbound
// message when the sender tapped Reply on an earlier bubble. We
// store senderName + snippet + senderId inline (instead of joining
// against the original message at render time) so the reply
// preview renders without an extra Firestore read, and survives
// even if the original message is somehow deleted later. The
// snippet is server-truncated by the client to keep the doc small.
class ReplyTarget {
  final String messageId;
  final String text;
  final String senderName;
  final String senderId;

  const ReplyTarget({
    required this.messageId,
    required this.text,
    required this.senderName,
    required this.senderId,
  });

  factory ReplyTarget.fromMap(Map<String, dynamic> data) => ReplyTarget(
        messageId: data['messageId'] as String? ?? '',
        text: data['text'] as String? ?? '',
        senderName: data['senderName'] as String? ?? '',
        senderId: data['senderId'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'messageId': messageId,
        'text': text,
        'senderName': senderName,
        'senderId': senderId,
      };
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

  // Quoted message this bubble is replying to. Null for plain
  // messages. Stamped at send time so the preview renders without
  // any extra reads — see ReplyTarget for the layout reasoning.
  final ReplyTarget? replyTo;

  // Only meaningful for `kind == callEntry`. The duration the past
  // call lasted, in minutes — drives the "5 min" text in the call
  // row. Null on every other kind.
  final int? callDurationMinutes;

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
    this.replyTo,
    this.callDurationMinutes,
  });

  // Synthesizes an inline call-entry row from a past voice session.
  // No Firestore message doc backs this — the entry exists purely
  // in client memory, built once at prefetch time. The session doc
  // is the source of truth for caller (userId is always the
  // initiator in the current product) + duration + start time.
  factory ChatMessage.callEntry({
    required String sessionId,
    required String callerId,
    required String callerName,
    required int durationMinutes,
    DateTime? at,
  }) {
    return ChatMessage(
      // Prefix the id so the view layer can't accidentally collide
      // with a real message doc id when keying widgets.
      id: '__call_$sessionId',
      senderId: callerId,
      senderName: callerName,
      text: '',
      createdAt: at,
      sessionId: sessionId,
      kind: ChatMessageKind.callEntry,
      callDurationMinutes: durationMinutes,
    );
  }

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

    final rawReply = data['replyTo'];
    final replyTo = rawReply is Map
        ? ReplyTarget.fromMap(Map<String, dynamic>.from(rawReply))
        : null;

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
      replyTo: replyTo,
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
  // the moment Firestore returns the canonical message. Carries
  // the same replyTo snapshot the server write will get, so the
  // optimistic bubble renders the quoted preview before the
  // Firestore round-trip completes.
  factory ChatMessage.pending({
    required String tempId,
    required String senderId,
    required String senderName,
    required String text,
    required String sessionId,
    ReplyTarget? replyTo,
  }) {
    return ChatMessage(
      id: tempId,
      senderId: senderId,
      senderName: senderName,
      text: text,
      createdAt: DateTime.now(),
      isPending: true,
      sessionId: sessionId,
      replyTo: replyTo,
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
      replyTo: replyTo,
      callDurationMinutes: callDurationMinutes,
    );
  }

  bool get isPriestMessage => kind == ChatMessageKind.priestMessage;
  bool get isCallEntry => kind == ChatMessageKind.callEntry;
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
