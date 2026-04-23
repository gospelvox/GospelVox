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
  final List<ChatMessage> messages;
  final int elapsedSeconds;
  final int remainingBalance;
  final bool isLowBalance;
  final bool isSendingMessage;
  final bool isEnding;

  const ChatSessionActive({
    required this.session,
    required this.messages,
    required this.elapsedSeconds,
    required this.remainingBalance,
    this.isLowBalance = false,
    this.isSendingMessage = false,
    this.isEnding = false,
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
  }) {
    return ChatSessionActive(
      session: session ?? this.session,
      messages: messages ?? this.messages,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      remainingBalance: remainingBalance ?? this.remainingBalance,
      isLowBalance: isLowBalance ?? this.isLowBalance,
      isSendingMessage: isSendingMessage ?? this.isSendingMessage,
      isEnding: isEnding ?? this.isEnding,
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
