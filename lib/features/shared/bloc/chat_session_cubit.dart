// Runs the live chat session for one screen mount. Owns:
//   • a Firestore stream on the session doc (so we notice when the
//     other party or the watchdog ends the session)
//   • a Firestore stream on the messages subcollection
//   • a Firestore stream on the user's coin balance (so an in-chat
//     top-up reflects instantly without waiting for next billingTick)
//   • a Stopwatch + 1s timer for the MM:SS display clock
//   • a 30s heartbeat timer (user side only)
//   • a 60s billingTick timer (user side only — only one client
//     can drive billing or we'd double-charge)
//   • typing presence (debounced 500ms write, auto-clear after 5s)
//   • optimistic message bubbles (visible the instant Send is
//     tapped, swapped for the canonical Firestore message when
//     the stream confirms)
//
// Why user-only billing: billingTick increments `durationMinutes`
// and deducts coins in a single batch. If both clients called it,
// a 5-minute session would debit 10 minutes. The priest side is
// purely passive here — it renders what the stream says and relies
// on the user's client for billing forward motion. If the user's
// phone dies mid-session, the sessionWatchdog CF settles billing.

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
  StreamSubscription<int>? _balanceSubscription;
  Timer? _elapsedTimer;
  Timer? _heartbeatTimer;
  Timer? _billingTimer;
  Timer? _typingIdleTimer;
  // Periodic check for the 90-second idle warning. Runs every 30s
  // — short enough to feel responsive without burning battery on
  // a 1Hz tick.
  Timer? _idleWarningTimer;

  // Most recent activity from the OTHER party. Falls back to the
  // session's startedAt when nobody has spoken yet — that way the
  // idle warning still surfaces if the priest accepts and goes
  // silent immediately.
  DateTime? _lastOtherActivityAt;

  final Stopwatch _stopwatch = Stopwatch();
  int _lastKnownBalance = 0;
  String _sessionId = '';
  bool _isUserSide = true;
  bool _timersStarted = false;
  bool _endingDispatched = false;

  // Tracks whether we've reported "actively typing" to the server.
  // Lets us debounce: a single transition write covers the whole
  // typing burst, instead of writing on every keystroke.
  bool _localTypingActive = false;

  // Optimistic outbound bubbles awaiting Firestore confirmation.
  // Each entry is keyed by a tempId; once the messages stream
  // returns a doc whose senderId+text+ts matches, we drop it.
  final List<ChatMessage> _pendingOutbound = [];

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

    // Any non-active status means the session is done. Could be
    // the other side ending it, the watchdog completing a stale
    // session, or the CF auto-ending on balance-zero. Collapse
    // all of these into a single "end" transition.
    if (session.status != 'active') {
      if (_endingDispatched) return;
      _endingDispatched = true;
      _stopAllTimers();
      // Prefer the precise endReason the CF wrote on the session
      // doc (balance_zero / watchdog_timeout / superseded…). Falls
      // back to a status-derived value only when the field is
      // missing — older docs from before the field existed.
      final reason = session.endReason.isNotEmpty
          ? session.endReason
          : (session.status == 'completed' ? 'completed' : 'external');
      _fetchSummaryAndEnd(session, reason);
      return;
    }

    final current = state;
    if (current is ChatSessionActive) {
      emit(current.copyWith(session: session));
      return;
    }

    // First active snapshot — seed state and start side-specific
    // timers. We only do this once per cubit lifetime.
    _lastKnownBalance = session.userBalance;
    // Seed the idle baseline with session.startedAt so the warning
    // can fire even if the other party never sends a single
    // message after accepting.
    _lastOtherActivityAt = session.startedAt ?? DateTime.now();
    if (!_timersStarted) {
      _timersStarted = true;
      _startTimers(_sessionId);
      // User-side: subscribe to live wallet balance so an in-chat
      // top-up reflects in `remainingBalance` within ~1 second
      // without waiting for the next minute's billingTick.
      if (_isUserSide) {
        _balanceSubscription = _repository
            .watchUserBalance(session.userId)
            .listen(_onBalanceSnapshot);
      }
    }

    emit(ChatSessionActive(
      session: session,
      messages: const [],
      elapsedSeconds: 0,
      remainingBalance: session.userBalance,
      isLowBalance: _isUserSide && session.userBalance <= 50,
    ));
  }

  void _onMessagesSnapshot(List<ChatMessage> messages) {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;

    // Reconcile optimistic bubbles: anything in _pendingOutbound
    // whose text now appears in the server list is settled — drop
    // it from the local pending queue. Anything still pending gets
    // appended at the end so the UI keeps showing it with the
    // "sending" status.
    if (_pendingOutbound.isNotEmpty) {
      _pendingOutbound.removeWhere((p) =>
          messages.any((m) =>
              m.senderId == p.senderId &&
              m.text == p.text &&
              !m.isPending));
    }

    final merged = <ChatMessage>[...messages, ..._pendingOutbound];

    // Update the idle baseline: if the OTHER party has a newer
    // confirmed message, advance our "last other activity"
    // timestamp. Lets the periodic idle checker drop the warning
    // immediately once they speak.
    final otherId =
        _isUserSide ? current.session.priestId : current.session.userId;
    DateTime? newestOtherAt;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.senderId == otherId &&
          !m.isPending &&
          m.createdAt != null) {
        newestOtherAt = m.createdAt;
        break;
      }
    }
    var clearIdle = false;
    if (newestOtherAt != null &&
        (_lastOtherActivityAt == null ||
            newestOtherAt.isAfter(_lastOtherActivityAt!))) {
      _lastOtherActivityAt = newestOtherAt;
      // Other party just spoke → drop the idle warning right away
      // instead of waiting for the next 30s tick.
      if (current.showIdleWarning) clearIdle = true;
    }

    emit(current.copyWith(
      messages: merged,
      showIdleWarning: clearIdle ? false : current.showIdleWarning,
    ));
  }

  void _onBalanceSnapshot(int newBalance) {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;
    _lastKnownBalance = newBalance;
    emit(current.copyWith(
      remainingBalance: newBalance,
      isLowBalance: newBalance <= 50,
    ));
  }

  void _startTimers(String sessionId) {
    _stopwatch.start();

    // 1-second display tick. Cheap — recomputes elapsed text and
    // re-emits with the same session/messages references.
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

    // Idle-warning checker (both sides). Runs every 30s and
    // toggles `showIdleWarning` whenever the OTHER party has been
    // silent for 90+ seconds. The `clearIdle` path in
    // _onMessagesSnapshot drops the warning instantly when they
    // speak, so the UI doesn't have to wait for the next tick.
    _idleWarningTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _evaluateIdleWarning(),
    );

    // Heartbeat + billing are user-side only (see top comment).
    if (_isUserSide) {
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) {
          // Silent — a failed heartbeat just means the next 30s
          // tick retries. If we stay offline long enough the
          // watchdog will mark the session stale.
          _repository.sendHeartbeat(sessionId).catchError((_) {});
        },
      );

      _billingTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _runBillingTick(),
      );
    }
  }

  // Toggles `showIdleWarning` based on the gap since the OTHER
  // party last spoke. 90 seconds is the product-defined threshold.
  void _evaluateIdleWarning() {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;
    final activityAt = _lastOtherActivityAt;
    if (activityAt == null) return;

    final gap = DateTime.now().difference(activityAt).inSeconds;
    final shouldShow = gap >= 90;
    if (shouldShow != current.showIdleWarning) {
      emit(current.copyWith(showIdleWarning: shouldShow));
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

      if (result.shouldEnd && !_endingDispatched) {
        await endSession(reason: 'balance_zero');
      }
    } catch (e) {
      debugPrint('[ChatSessionCubit] billingTick failed: $e');
    }
  }

  // ─── Typing presence ─────────────────────────────────────

  // Called from the input bar's onChange. Cheaply debounced: we
  // only write to Firestore on the leading edge (transition from
  // not-typing to typing) and on the trailing edge (5s of no
  // input). This keeps the write rate independent of keystroke
  // frequency — a 100-character message produces 2 writes total.
  void onUserTyping() {
    if (isClosed) return;

    if (!_localTypingActive) {
      _localTypingActive = true;
      _repository.setTyping(
        sessionId: _sessionId,
        isUserSide: _isUserSide,
        typing: true,
      );
    }

    _typingIdleTimer?.cancel();
    _typingIdleTimer = Timer(const Duration(seconds: 5), _stopTyping);
  }

  void _stopTyping() {
    if (!_localTypingActive) return;
    _localTypingActive = false;
    _typingIdleTimer?.cancel();
    _typingIdleTimer = null;
    if (isClosed) return;
    _repository.setTyping(
      sessionId: _sessionId,
      isUserSide: _isUserSide,
      typing: false,
    );
  }

  // ─── Send message (with optimistic bubble) ───────────────

  Future<void> sendMessage({
    required String senderId,
    required String senderName,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final current = state;
    if (current is! ChatSessionActive) return;

    // Drop typing indicator immediately on send — sending IS
    // committing, so "still typing" would be misleading.
    _stopTyping();

    // Build an optimistic bubble. Tagged with isPending=true so
    // the UI renders the small ⏱ status icon. tempId uses a
    // microsecond timestamp — colliding with a real Firestore
    // doc id is effectively impossible.
    final tempId =
        '__pending_${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = ChatMessage.pending(
      tempId: tempId,
      senderId: senderId,
      senderName: senderName,
      text: trimmed,
    );
    _pendingOutbound.add(optimistic);

    if (!isClosed) {
      emit(current.copyWith(
        messages: [...current.messages, optimistic],
        isSendingMessage: true,
      ));
    }

    try {
      await _repository.sendMessage(
        sessionId: _sessionId,
        senderId: senderId,
        senderName: senderName,
        text: trimmed,
      );
      // Settled — but we keep `optimistic` in _pendingOutbound
      // until the messages stream actually returns the canonical
      // doc. _onMessagesSnapshot reconciles that.
    } catch (_) {
      // Network failed. Yank the optimistic bubble so the user
      // doesn't see a permanent "sending" message and rethrow so
      // the page can show a snack.
      _pendingOutbound.remove(optimistic);
      if (!isClosed) {
        final s = state;
        if (s is ChatSessionActive) {
          emit(s.copyWith(
            messages:
                s.messages.where((m) => m.id != tempId).toList(),
            isSendingMessage: false,
          ));
        }
      }
      rethrow;
    } finally {
      if (!isClosed) {
        final s = state;
        if (s is ChatSessionActive) {
          emit(s.copyWith(isSendingMessage: false));
        }
      }
    }
  }

  // ─── Reactions ──────────────────────────────────────────

  // Toggle: tapping the same emoji a second time clears it. The
  // current reaction is read from the message itself so two rapid
  // taps don't race against an in-flight write.
  Future<void> toggleReaction({
    required String messageId,
    required String userId,
    required String emoji,
  }) async {
    final current = state;
    if (current is! ChatSessionActive) return;

    final msg = current.messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => const ChatMessage(
        id: '',
        senderId: '',
        senderName: '',
        text: '',
      ),
    );
    if (msg.id.isEmpty) return;

    final existing = msg.reactions[userId];
    final next = existing == emoji ? null : emoji;

    try {
      await _repository.setReaction(
        sessionId: _sessionId,
        messageId: messageId,
        userId: userId,
        emoji: next,
      );
    } catch (_) {
      // Reactions are non-critical UX — silent failure is fine.
    }
  }

  // ─── End session ────────────────────────────────────────

  Future<void> endSession({String reason = 'user_ended'}) async {
    final current = state;
    if (current is! ChatSessionActive || current.isEnding) return;
    if (_endingDispatched) return;
    _endingDispatched = true;

    if (isClosed) return;
    emit(current.copyWith(isEnding: true));
    _stopAllTimers();
    _stopTyping();

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
      // isn't stuck on the chat screen. The watchdog reconciles.
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
    _typingIdleTimer?.cancel();
    _typingIdleTimer = null;
    _idleWarningTimer?.cancel();
    _idleWarningTimer = null;
  }

  @override
  Future<void> close() {
    _stopAllTimers();
    _sessionSubscription?.cancel();
    _messagesSubscription?.cancel();
    _balanceSubscription?.cancel();
    // Best-effort: clear our typing flag on the way out so the
    // other side doesn't see a ghost "typing…" indicator.
    if (_localTypingActive && _sessionId.isNotEmpty) {
      _repository
          .setTyping(
            sessionId: _sessionId,
            isUserSide: _isUserSide,
            typing: false,
          )
          .catchError((_) {});
    }
    return super.close();
  }
}
