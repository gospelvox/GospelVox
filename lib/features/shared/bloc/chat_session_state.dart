// States for the live chat session. Both user and priest sides use
// the same state hierarchy — the only difference between them is
// which timers the cubit starts (user ticks billing + heartbeat;
// priest just watches). Keeping one state machine means the chat
// UI stays a single widget instead of two near-identical copies.

import 'package:gospel_vox/features/shared/data/session_model.dart';

sealed class ChatSessionState {
  const ChatSessionState();
}

class ChatSessionInitial extends ChatSessionState {
  const ChatSessionInitial();
}

class ChatSessionLoading extends ChatSessionState {
  const ChatSessionLoading();
}

class ChatSessionActive extends ChatSessionState {
  final SessionModel session;
  // Flat list of bubbles, oldest first. Past-session bubbles are at
  // the front (each carries its own sessionId so the view can render
  // a divider at every session boundary), live-session bubbles + any
  // optimistic outbound bubbles are at the end. The view uses each
  // bubble's `sessionId` to decide whether long-press reactions are
  // allowed (current session only) — past bubbles render exactly the
  // same as live ones, just inert.
  final List<ChatMessage> messages;
  final int elapsedSeconds;
  final int remainingBalance;
  final bool isLowBalance;
  final bool isSendingMessage;
  final bool isEnding;

  // True when the OTHER party hasn't sent a message in 90+ seconds
  // (or hasn't sent any since the session started). Drives the
  // local-only system message in the chat list. Reset whenever
  // their next message arrives.
  final bool showIdleWarning;

  // { pastSessionId → date + duration } for the divider widget.
  // Built once at session start by the cubit's prefetch and then
  // immutable for the lifetime of the chat — past sessions can't
  // gain new messages, so there's nothing to update.
  final Map<String, PastSessionMeta> pastMeta;

  // The message the user is currently composing a reply to. Set
  // by setReplyTarget when a bubble is swiped, cleared on send or
  // when the user dismisses the compose chip. Null when the user
  // is composing a plain message.
  final ChatMessage? replyTarget;

  // One-shot signal: cubit flips this to true the first time the
  // user's remaining balance crosses below 2 minutes of chat time
  // at the locked rate. The view's BlocListener fires the urgent
  // recharge sheet on this transition (once per low-balance
  // phase), then calls acknowledgeLowBalancePrompt to reset it.
  // Default false so every existing copyWith call is unaffected.
  final bool showLowBalancePrompt;

  const ChatSessionActive({
    required this.session,
    required this.messages,
    required this.elapsedSeconds,
    required this.remainingBalance,
    this.isLowBalance = false,
    this.isSendingMessage = false,
    this.isEnding = false,
    this.showIdleWarning = false,
    this.pastMeta = const {},
    this.replyTarget,
    this.showLowBalancePrompt = false,
  });

  // MM:SS used by the top-bar timer pill. We pad both halves so the
  // string width stays constant and the pill doesn't reflow as the
  // clock ticks.
  String get formattedTime {
    final minutes = elapsedSeconds ~/ 60;
    final seconds = elapsedSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // Approximate current cost based on the ceiling of the elapsed
  // minutes — matches the server's "round up to next minute" rule so
  // the End Session confirmation sheet isn't off by 10 coins at the
  // point the user decides to hang up.
  int get currentCost {
    if (elapsedSeconds <= 0) return 0;
    final minutes = (elapsedSeconds / 60).ceil();
    return minutes * session.ratePerMinute;
  }

  ChatSessionActive copyWith({
    SessionModel? session,
    List<ChatMessage>? messages,
    int? elapsedSeconds,
    int? remainingBalance,
    bool? isLowBalance,
    bool? isSendingMessage,
    bool? isEnding,
    bool? showIdleWarning,
    Map<String, PastSessionMeta>? pastMeta,
    ChatMessage? replyTarget,
    // The `??` pattern can't express "set this field to null".
    // Pass clearReplyTarget: true to drop the current reply target
    // (used when the user sends or dismisses the chip).
    bool clearReplyTarget = false,
    bool? showLowBalancePrompt,
  }) {
    return ChatSessionActive(
      session: session ?? this.session,
      messages: messages ?? this.messages,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      remainingBalance: remainingBalance ?? this.remainingBalance,
      isLowBalance: isLowBalance ?? this.isLowBalance,
      isSendingMessage: isSendingMessage ?? this.isSendingMessage,
      isEnding: isEnding ?? this.isEnding,
      showIdleWarning: showIdleWarning ?? this.showIdleWarning,
      pastMeta: pastMeta ?? this.pastMeta,
      replyTarget:
          clearReplyTarget ? null : (replyTarget ?? this.replyTarget),
      showLowBalancePrompt:
          showLowBalancePrompt ?? this.showLowBalancePrompt,
    );
  }
}

// Terminal state. endReason is informational — the page uses it to
// pick copy ("Session ended by priest" vs "Your balance ran out")
// but the navigation decision is the same in every case.
class ChatSessionEnded extends ChatSessionState {
  final SessionSummary summary;
  final SessionModel session;
  final String endReason;

  const ChatSessionEnded({
    required this.summary,
    required this.session,
    required this.endReason,
  });
}

class ChatSessionError extends ChatSessionState {
  final String message;
  const ChatSessionError(this.message);
}
