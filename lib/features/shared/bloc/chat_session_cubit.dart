// Runs the live chat session for one screen mount. Owns:
//   • a Firestore stream on the session doc (so we notice when the
//     other party or the watchdog ends the session)
//   • a Firestore stream on the messages subcollection
//   • a Stopwatch + 1s timer for the MM:SS display clock
//   • a 30s heartbeat timer (user side only)
//   • a 60s billingTick timer (user side only — only one client
//     can drive billing or we'd double-charge)
//
// Why user-only billing: billingTick increments `durationMinutes`
// and deducts coins in a single batch. If both the user and priest
// clients called it, a 5-minute session would debit 10 minutes. The
// priest side is purely passive here — it renders what the stream
// says and relies on the user's client for billing forward motion.
// If the user's phone dies mid-session, the sessionWatchdog CF is
// the safety net that still settles billing via endSession.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/bloc/chat_session_state.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';

class ChatSessionCubit extends Cubit<ChatSessionState> {
  final SessionRepository _repository;

  StreamSubscription<SessionModel>? _sessionSubscription;
  StreamSubscription<List<ChatMessage>>? _messagesSubscription;
  Timer? _elapsedTimer;
  Timer? _heartbeatTimer;
  Timer? _billingTimer;

  final Stopwatch _stopwatch = Stopwatch();
  int _lastKnownBalance = 0;
  String _sessionId = '';
  bool _isUserSide = true;
  bool _timersStarted = false;
  bool _endingDispatched = false;

  ChatSessionCubit(this._repository) : super(const ChatSessionInitial());

  Future<void> startSession({
    required String sessionId,
    required bool isUserSide,
  }) async {
    _sessionId = sessionId;
    _isUserSide = isUserSide;

    try {
      if (isClosed) return;
      emit(const ChatSessionLoading());

      _sessionSubscription =
          _repository.watchSession(sessionId).listen(_onSessionSnapshot,
              onError: (_) {
        if (isClosed) return;
        emit(const ChatSessionError(
            'Connection lost. Trying to reconnect…'));
      });

      _messagesSubscription =
          _repository.watchMessages(sessionId).listen(_onMessagesSnapshot);
    } catch (_) {
      if (isClosed) return;
      emit(const ChatSessionError('Failed to start session.'));
    }
  }

  void _onSessionSnapshot(SessionModel session) {
    if (isClosed) return;

    // Any non-active status means the session is done. Could be the
    // other side ending it, the watchdog completing a stale session,
    // or the CF auto-ending on balance-zero. The cubit collapses all
    // of these into a single "end" transition.
    if (session.status != 'active') {
      if (_endingDispatched) return;
      _endingDispatched = true;
      _stopAllTimers();
      _fetchSummaryAndEnd(
        session,
        session.status == 'completed' ? 'completed' : 'external',
      );
      return;
    }

    final current = state;
    if (current is ChatSessionActive) {
      emit(current.copyWith(session: session));
      return;
    }

    // First active snapshot — seed state and start the side-specific
    // timers. We only do this once per cubit lifetime.
    _lastKnownBalance = session.userBalance;
    if (!_timersStarted) {
      _timersStarted = true;
      _startTimers(_sessionId);
    }

    emit(ChatSessionActive(
      session: session,
      messages: const [],
      elapsedSeconds: 0,
      remainingBalance: session.userBalance,
      isLowBalance: session.userBalance <= 50,
    ));
  }

  void _onMessagesSnapshot(List<ChatMessage> messages) {
    if (isClosed) return;
    final current = state;
    if (current is ChatSessionActive) {
      emit(current.copyWith(messages: messages));
    }
  }

  void _startTimers(String sessionId) {
    _stopwatch.start();

    // 1-second display tick. Intentionally cheap — just recomputes
    // the elapsed text and re-emits.
    _elapsedTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (isClosed) return;
        final current = state;
        if (current is ChatSessionActive) {
          emit(current.copyWith(
            elapsedSeconds: _stopwatch.elapsed.inSeconds,
          ));
        }
      },
    );

    // Heartbeat + billing are user-side only. See top comment for
    // why we avoid letting the priest client drive these.
    if (_isUserSide) {
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) {
          // Silent — a failed heartbeat just means the next 30s
          // tick retries. If we stay offline long enough the
          // watchdog will mark the session stale and endSession
          // will reconcile.
          _repository.sendHeartbeat(sessionId).catchError((_) {});
        },
      );

      _billingTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _runBillingTick(),
      );
    }
  }

  Future<void> _runBillingTick() async {
    if (isClosed) return;
    try {
      final result = await _repository.callBillingTick(_sessionId);
      if (isClosed) return;

      final current = state;
      if (current is! ChatSessionActive) return;

      _lastKnownBalance = result.remainingBalance;
      emit(current.copyWith(
        remainingBalance: result.remainingBalance,
        isLowBalance: result.remainingBalance <= 50,
      ));

      // Server says the user can't afford another minute. Collapse
      // immediately so the UI doesn't keep ticking a session the
      // CF already ended.
      if (result.shouldEnd && !_endingDispatched) {
        await endSession(reason: 'balance_zero');
      }
    } catch (e) {
      // A single bad tick isn't fatal — the next tick will retry,
      // and the server is authoritative about totals. We just log
      // so it's visible during dev.
      debugPrint('[ChatSessionCubit] billingTick failed: $e');
    }
  }

  Future<void> sendMessage({
    required String senderId,
    required String senderName,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final current = state;
    if (current is! ChatSessionActive) return;

    if (isClosed) return;
    emit(current.copyWith(isSendingMessage: true));

    try {
      await _repository.sendMessage(
        sessionId: _sessionId,
        senderId: senderId,
        senderName: senderName,
        text: trimmed,
      );
    } catch (_) {
      // Leave the input populated so the user can retry — the page
      // only clears the field after awaiting this method returns
      // without throwing.
      rethrow;
    } finally {
      if (!isClosed) {
        final latest = state;
        if (latest is ChatSessionActive) {
          emit(latest.copyWith(isSendingMessage: false));
        }
      }
    }
  }

  Future<void> endSession({String reason = 'user_ended'}) async {
    final current = state;
    if (current is! ChatSessionActive || current.isEnding) return;
    if (_endingDispatched) return;
    _endingDispatched = true;

    if (isClosed) return;
    emit(current.copyWith(isEnding: true));
    _stopAllTimers();

    try {
      final summary = await _repository.endSession(_sessionId);
      if (isClosed) return;
      emit(ChatSessionEnded(
        summary: summary,
        session: current.session,
        endReason: reason,
      ));
    } catch (_) {
      // CF failed. Stop the session locally with a best-effort
      // summary computed from the last state we saw, so the user
      // isn't stuck on the chat screen. The server will reconcile
      // via the watchdog.
      if (isClosed) return;
      emit(ChatSessionEnded(
        summary: SessionSummary(
          durationMinutes: (_stopwatch.elapsed.inSeconds / 60).ceil(),
          totalCharged: current.currentCost,
          priestEarnings: 0,
          newBalance: _lastKnownBalance,
        ),
        session: current.session,
        endReason: reason,
      ));
    }
  }

  Future<void> _fetchSummaryAndEnd(
    SessionModel session,
    String reason,
  ) async {
    try {
      final summary = await _repository.endSession(_sessionId);
      if (isClosed) return;
      emit(ChatSessionEnded(
        summary: summary,
        session: session,
        endReason: reason,
      ));
    } catch (_) {
      if (isClosed) return;
      emit(ChatSessionEnded(
        summary: SessionSummary(
          durationMinutes: session.durationMinutes,
          totalCharged: session.totalCharged,
          priestEarnings: session.priestEarnings,
          newBalance: _lastKnownBalance,
        ),
        session: session,
        endReason: reason,
      ));
    }
  }

  void _stopAllTimers() {
    if (_stopwatch.isRunning) _stopwatch.stop();
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _billingTimer?.cancel();
    _billingTimer = null;
  }

  @override
  Future<void> close() {
    _stopAllTimers();
    _sessionSubscription?.cancel();
    _messagesSubscription?.cancel();
    return super.close();
  }
}
