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
  // Live stream of priest-initiated free messages between this
  // (user, priest) pair. Started on the first active session
  // snapshot, same time the past-messages prefetch fires. The
  // subscription stays open for the cubit's lifetime so a free
  // message landing mid-session shows up in real time.
  StreamSubscription<List<ChatMessage>>? _freeMessagesSubscription;
  // Live stream of the user's mutedPriestIds. User-side only; the
  // free-message merger drops bubbles from any priest in this set
  // so a mid-session mute takes effect without a manual refresh.
  StreamSubscription<Set<String>>? _mutedPriestsSubscription;
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

  // ─── Mutual presence (chat-equivalent of voice onUserOffline) ───
  // _presenceTimer stamps MY presence; _presenceCheckTimer watches the
  // PEER's. Both run on BOTH sides (unlike billing/heartbeat which are
  // user-only). When the peer's presence goes stale we end the chat so
  // the meter stops and both are freed.
  Timer? _presenceTimer;
  Timer? _presenceCheckTimer;
  // Client-clock instant we last saw the peer's presence stamp ADVANCE.
  // Tracked in LOCAL time (not the server timestamp) so the staleness
  // check never trips on user↔server clock skew. Null until the peer
  // pings for the first time.
  DateTime? _peerLastSeenLocal;
  // The peer's last presence value we've observed — used only to detect
  // when it advances (the snapshot fires on our own writes too).
  DateTime? _peerLastPresenceValue;
  // Client-clock instant MY OWN presence write last SUCCEEDED. Proves
  // my connection to Firestore is actually healthy. Used to avoid
  // blaming the peer for what is really MY network being down: if I
  // can't even write my own presence, I also can't receive theirs, so
  // a "peer looks stale" reading is untrustworthy and must NOT end the
  // chat. Null until my first write lands.
  DateTime? _myLastPresenceOkLocal;

  static const int _kPresenceWriteSeconds = 8;
  // Peer considered gone after this much silence following their LAST
  // seen ping. At an 8s write cadence this is ~2 missed pings: still
  // rides out a single brief network blip (and the _myPresence guard
  // below ignores the signal entirely when MY OWN link is the suspect),
  // but ends an abandoned chat in ~15-20s incl. the 5s check tick so a
  // killed user frees the priest quickly. Lower than this starts false-
  // ending real chats on ordinary mobile-data hiccups.
  static const int _kPeerStaleSeconds = 15;
  // How recently MY OWN presence write must have succeeded for me to
  // trust the peer-stale signal. If my writes have been failing longer
  // than this, my connection is the suspect — defer the decision to
  // the side with the healthy link rather than false-ending the chat.
  static const int _kMyPresenceStaleSeconds = 15;

  final Stopwatch _stopwatch = Stopwatch();
  int _lastKnownBalance = 0;
  String _sessionId = '';
  bool _isUserSide = true;
  bool _timersStarted = false;
  bool _endingDispatched = false;
  // Connection-stamp latch: true once userConnectedAt/priestConnectedAt
  // has been written. Doubles as an in-flight guard; drops on failure
  // so the 30s heartbeat retries (see _confirmConnectionOnce).
  bool _connectionConfirmed = false;

  // Tracks whether we've reported "actively typing" to the server.
  // Lets us debounce: a single transition write covers the whole
  // typing burst, instead of writing on every keystroke.
  bool _localTypingActive = false;

  // When we last wrote typing:true. Used to periodically re-stamp
  // typingSince during a long typing burst so the receiver's 30s
  // staleness guard doesn't hide the indicator while the user is
  // genuinely still typing a long message.
  DateTime? _lastTypingWrite;

  // Optimistic outbound bubbles awaiting Firestore confirmation.
  // Each entry is keyed by a tempId; once the messages stream
  // returns a doc whose senderId+text+ts matches, we drop it.
  final List<ChatMessage> _pendingOutbound = [];

  // Past-session messages prefetched once when the chat opens, so
  // the live surface shows the user's prior conversation with this
  // priest above any new bubbles. Immutable after load — past
  // sessions can't gain messages.
  List<ChatMessage> _pastMessages = const [];
  Map<String, PastSessionMeta> _pastMeta = const {};
  // Cache of the most recent live snapshot so we can re-merge with
  // _pastMessages whenever the prefetch completes mid-session
  // without losing anything that arrived in between.
  List<ChatMessage> _liveMessages = const [];
  // Latest snapshot of priest-initiated free messages between the
  // two parties. Re-merged into the timeline whenever it changes
  // OR whenever past/live messages do, since interleaving is by
  // timestamp.
  List<ChatMessage> _freeMessages = const [];
  // User-side: priests the user has muted. Free messages from any
  // priest in this set are dropped client-side. Empty on the
  // priest side (their view never filters by mute).
  Set<String> _mutedPriestIds = const {};
  bool _pastFetchStarted = false;

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

  // Kicked off once on the first `active` session snapshot. Reads
  // every prior completed-chat message between this user and this
  // priest (capped at 200, oldest dropped first), then re-emits the
  // active state with past + live merged. Failures are swallowed —
  // a missing past doesn't break the live conversation.
  Future<void> _loadPastMessages({
    required String userId,
    required String priestId,
  }) async {
    if (_pastFetchStarted) return;
    _pastFetchStarted = true;

    try {
      final result = await _repository.getPastChatMessages(
        userId: userId,
        priestId: priestId,
        excludeSessionId: _sessionId,
      );
      if (isClosed) return;
      _pastMessages = result.messages;
      _pastMeta = result.meta;
      _emitMerged();
    } catch (_) {
      // Silent — past history is a nice-to-have. If it fails, the
      // chat still works as a fresh-only surface.
    }
  }

  // Re-emits ChatSessionActive with the full timeline merged:
  //   • past-session bubbles (oldest first, with sessionId stamped)
  //   • priest free messages (filtered by mute on user side)
  //   • current session's live bubbles
  //   • optimistic outbound bubbles awaiting confirmation
  // The first three are interleaved by createdAt so a free message
  // sent between two paid sessions lands in the right place
  // chronologically. Optimistic always tails because they have a
  // local "now" timestamp ahead of any server doc.
  void _emitMerged() {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;

    emit(current.copyWith(
      messages: _buildMergedTimeline(current.session.id),
      pastMeta: _pastMeta,
    ));
  }

  // Builds the chronological timeline. Pulled out so both the
  // emit-merged path and the optimistic-send path produce identical
  // ordering — duplicating this logic would let the two drift on
  // edge cases like "a free message arrives the same millisecond as
  // a live session bubble".
  List<ChatMessage> _buildMergedTimeline(String currentSessionId) {
    // Free messages from priests in the user's mute set are dropped
    // here as well as server-side, so a stale notification doc
    // already in the cache disappears the moment the user mutes.
    final visibleFree = _mutedPriestIds.isEmpty
        ? _freeMessages
        : _freeMessages
            .where((m) => !_mutedPriestIds.contains(m.senderId))
            .toList();

    // Past-session + free messages mix freely by timestamp; only
    // the live current session sits at the end (always the most
    // recent slice) and the optimistic queue tails after that.
    final timestamped = <ChatMessage>[..._pastMessages, ...visibleFree]
      ..sort((a, b) {
        final aTime = a.createdAt ?? DateTime(2000);
        final bTime = b.createdAt ?? DateTime(2000);
        return aTime.compareTo(bTime);
      });

    return <ChatMessage>[
      ...timestamped,
      ..._liveMessages,
      ..._pendingOutbound,
    ];
  }

  void _onFreeMessagesSnapshot(List<ChatMessage> messages) {
    if (isClosed) return;
    // User-side: drop free messages flagged delivered=false (the
    // user had muted the priest at send time). The CF writes these
    // anyway so the priest's own view keeps a record, but the user
    // should never see them. Priest-side keeps everything — they're
    // looking at their own outbox.
    _freeMessages = _isUserSide
        ? messages.where((m) => m.delivered).toList()
        : messages;
    _emitMerged();
  }

  void _onMutedPriestsSnapshot(Set<String> mutedIds) {
    if (isClosed) return;
    _mutedPriestIds = mutedIds;
    _emitMerged();
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
      // Surface the ending state to the UI immediately so the
      // input bar / end button visibly disable while
      // _fetchSummaryAndEnd races the endSession CF. Without
      // this, the priest sees a frozen chat with no feedback
      // that the session is wrapping up.
      final current = state;
      if (current is ChatSessionActive) {
        emit(current.copyWith(isEnding: true));
      }
      _fetchSummaryAndEnd(session, reason);
      return;
    }

    // Note when the peer's presence stamp advances (in LOCAL time) so
    // _checkPeerPresence can tell "still here" from "gone".
    _trackPeerPresence(session);

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
      // Real connection for a chat = both chat screens are open and
      // the session is active. This side is here now, so stamp its
      // connect marker ONCE. Billing CFs only charge once BOTH sides
      // have stamped, so a priest who accepted but never opened the
      // chat (app died) never causes a charge. The helper writes at
      // most once and, on failure, the 30s heartbeat retries it — so a
      // transient write failure can't strand a real chat unbillable
      // (the server would otherwise end it free at 75s).
      _confirmConnectionOnce();
      // User-side: subscribe to live wallet balance so an in-chat
      // top-up reflects in `remainingBalance` within ~1 second
      // without waiting for the next minute's billingTick.
      if (_isUserSide) {
        _balanceSubscription = _repository
            .watchUserBalance(session.userId)
            .listen(_onBalanceSnapshot);
      }
      // Fire the past-messages prefetch in parallel with whatever
      // the live messages stream is already doing. The merge in
      // _emitMerged tolerates either arriving first.
      unawaited(_loadPastMessages(
        userId: session.userId,
        priestId: session.priestId,
      ));

      // Subscribe to priest-initiated free messages between the
      // two parties. Lands in the timeline by timestamp alongside
      // session bubbles and past-session bubbles.
      _freeMessagesSubscription = _repository
          .watchPriestFreeMessages(
            userId: session.userId,
            priestId: session.priestId,
          )
          .listen(_onFreeMessagesSnapshot);

      // User-side only: track this user's mutedPriestIds so a
      // mid-session mute drops the priest's free messages from the
      // timeline immediately. The priest's own view never filters
      // by user-side mute (they're allowed to see their own sends).
      if (_isUserSide) {
        _mutedPriestsSubscription = _repository
            .watchMutedPriestIds(session.userId)
            .listen(_onMutedPriestsSnapshot);
      }
    }

    emit(ChatSessionActive(
      session: session,
      messages: _buildMergedTimeline(session.id),
      elapsedSeconds: 0,
      remainingBalance: session.userBalance,
      isLowBalance: _isUserSide &&
          _isLowBalanceAt(session.userBalance, session.ratePerMinute),
      pastMeta: _pastMeta,
    ));
  }

  void _onMessagesSnapshot(List<ChatMessage> messages) {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;

    // Cache the latest live snapshot so any subsequent re-merge
    // (past prefetch landing later, optimistic bubble settling)
    // reuses the freshest server list.
    _liveMessages = messages;

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

    final merged = _buildMergedTimeline(current.session.id);

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
      pastMeta: _pastMeta,
    ));
  }

  void _onBalanceSnapshot(int newBalance) {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;
    _lastKnownBalance = newBalance;
    emit(current.copyWith(
      remainingBalance: newBalance,
      isLowBalance:
          _isLowBalanceAt(newBalance, current.session.ratePerMinute),
    ));
    _maybePromptLowBalance();
  }

  // Latch + thresholds for the low-balance UX. Two levels:
  //   • 2 minutes left → strip card shows (gentle reminder)
  //   • 1 minute  left → urgent recharge sheet pops (one-shot)
  // Same edge-detection semantics as the voice-call cubit: pops
  // once per low-balance phase, re-arms when balance climbs above
  // the urgent threshold.
  bool _lowBalancePromptShown = false;
  static const int _kLowBalanceWarningMinutes = 2;
  static const int _kMinutesLeftThreshold = 1;

  // Returns true when balance buys ≤2 minutes at the locked chat
  // rate. Defensive: a zero/negative rate returns false so the
  // strip never pops on a misconfigured app_config.
  bool _isLowBalanceAt(int balance, int rate) {
    if (rate <= 0) return false;
    return (balance ~/ rate) <= _kLowBalanceWarningMinutes;
  }

  void _maybePromptLowBalance() {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;
    final rate = current.session.ratePerMinute;
    if (rate <= 0) return;
    final minutesLeft = current.remainingBalance ~/ rate;

    if (minutesLeft <= _kMinutesLeftThreshold) {
      if (!_lowBalancePromptShown && !current.showLowBalancePrompt) {
        _lowBalancePromptShown = true;
        emit(current.copyWith(showLowBalancePrompt: true));
      }
    } else {
      _lowBalancePromptShown = false;
    }
  }

  void acknowledgeLowBalancePrompt() {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;
    if (!current.showLowBalancePrompt) return;
    emit(current.copyWith(showLowBalancePrompt: false));
  }

  // Stamps the connection marker. The latch is BOTH a "write at most
  // once" guard and an in-flight guard: while a write is pending the
  // latch is true so re-entry is a no-op; on FAILURE it drops so the
  // next caller retries. Called when the chat goes active AND from the
  // 30s heartbeat, so even if early writes fail the heartbeat keeps
  // retrying until it lands — a transient failure can't strand a real
  // chat unbillable (which the server would end free at 75s).
  void _confirmConnectionOnce() {
    if (_connectionConfirmed) return;
    _connectionConfirmed = true;
    _repository
        .confirmConnection(_sessionId, isUserSide: _isUserSide)
        .catchError((_) {
      _connectionConfirmed = false;
    });
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

    // Mutual presence — BOTH sides. Stamp my own presence right away,
    // then every few seconds, AND watch the peer's. If the peer goes
    // stale (killed the app / lost network / never showed up), end the
    // chat so the meter stops and both sides are freed — the chat
    // equivalent of voice's onUserOffline.
    _sendPresence();
    _presenceTimer = Timer.periodic(
      const Duration(seconds: _kPresenceWriteSeconds),
      (_) => _sendPresence(),
    );
    _presenceCheckTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkPeerPresence(),
    );

    // Heartbeat + billing are user-side only (see top comment).
    if (_isUserSide) {
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) {
          // Safety net: if the connect stamp never landed (transient
          // write failure), keep retrying it here until it does —
          // otherwise the server ends the chat free at 75s. No-op once
          // confirmed.
          _confirmConnectionOnce();
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

  // Writes MY presence and, on success, records that my link to
  // Firestore is healthy (_myLastPresenceOkLocal). Fire-and-forget — a
  // failed write just means the next tick retries; and a SUSTAINED
  // failure is exactly the signal _checkPeerPresence uses to NOT trust
  // a "peer looks stale" reading (it may be my own network down).
  void _sendPresence() {
    _repository
        .sendChatPresence(_sessionId, isUserSide: _isUserSide)
        .then((_) {
      _myLastPresenceOkLocal = DateTime.now();
    }).catchError((_) {});
  }

  // Records, in LOCAL client time, the instant the peer's presence
  // stamp last advanced. The session snapshot fires on our OWN writes
  // too, so we only move the marker when the peer's value genuinely
  // moves forward. Comparing local-time-to-local-time in
  // _checkPeerPresence avoids any user↔server clock-skew false trips.
  void _trackPeerPresence(SessionModel session) {
    final peer = _isUserSide
        ? session.priestPresenceAt
        : session.userPresenceAt;
    if (peer == null) return;
    if (_peerLastPresenceValue == null ||
        peer.isAfter(_peerLastPresenceValue!)) {
      _peerLastPresenceValue = peer;
      _peerLastSeenLocal = DateTime.now();
    }
  }

  // Ends the chat when a peer who WAS present goes quiet on the wire —
  // the chat equivalent of voice's onUserOffline.
  //
  // ROLLOUT SAFETY: we only ever end after we've SEEN the peer ping at
  // least once (_peerLastSeenLocal != null). A peer on an older build
  // never writes presence at all; if we treated "no ping" as "gone",
  // we'd falsely kill every new-side ↔ old-side chat. By acting only
  // on a peer who was pinging and then STOPPED, an old-build peer
  // simply never triggers this path — that chat falls back to the
  // existing heartbeat/watchdog behaviour, with zero false ends.
  //
  // endSession is guarded (_endingDispatched) and the server settle is
  // transactional, so a simultaneous end from both sides is safe.
  void _checkPeerPresence() {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive || current.isEnding) return;

    final seen = _peerLastSeenLocal;
    if (seen == null) return;

    // FALSE-END GUARD: never blame the peer if it might be MY OWN
    // connection that's down. If my own presence writes aren't landing,
    // I also can't receive the peer's — so a "peer looks stale" reading
    // is untrustworthy. Stay in the chat; the side with the healthy
    // link makes the call. This stops a brief local blip from killing a
    // perfectly healthy chat (important on flaky mobile networks).
    final myOk = _myLastPresenceOkLocal;
    final now = DateTime.now();
    if (myOk == null ||
        now.difference(myOk).inSeconds > _kMyPresenceStaleSeconds) {
      return;
    }

    if (now.difference(seen).inSeconds > _kPeerStaleSeconds) {
      endSession(reason: 'peer_left');
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
        isLowBalance: _isLowBalanceAt(
          result.remainingBalance,
          current.session.ratePerMinute,
        ),
      ));
      _maybePromptLowBalance();

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

    final now = DateTime.now();
    // Write typing:true on the leading edge AND re-stamp it every 15s
    // of continuous typing. The re-stamp keeps typingSince fresh so the
    // receiver's 30s staleness guard never hides the indicator while
    // the user is still typing a long message. Short messages (typed in
    // under 15s) still produce just the one leading-edge write.
    if (!_localTypingActive ||
        _lastTypingWrite == null ||
        now.difference(_lastTypingWrite!).inSeconds >= 15) {
      _localTypingActive = true;
      _lastTypingWrite = now;
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
    _lastTypingWrite = null;
    _typingIdleTimer?.cancel();
    _typingIdleTimer = null;
    if (isClosed) return;
    _repository.setTyping(
      sessionId: _sessionId,
      isUserSide: _isUserSide,
      typing: false,
    );
  }

  // ─── Reply target ────────────────────────────────────────

  // Stash a bubble as the active reply target — driven by the swipe
  // gesture in the chat view. We refuse pending/past/free-message
  // bubbles here as defence in depth, even though the view layer
  // already gates the swipe to current-session bubbles only.
  void setReplyTarget(ChatMessage message) {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;
    if (message.isPending) return;
    if (message.isPriestMessage) return;
    if (message.sessionId.isNotEmpty &&
        message.sessionId != _sessionId) {
      return;
    }
    emit(current.copyWith(replyTarget: message));
  }

  void clearReplyTarget() {
    if (isClosed) return;
    final current = state;
    if (current is! ChatSessionActive) return;
    if (current.replyTarget == null) return;
    emit(current.copyWith(clearReplyTarget: true));
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

    // Snapshot the active reply target (if any) and freeze a
    // ReplyTarget payload for both the optimistic bubble and the
    // server write. Snippet capped at 140 chars so a 1000-char
    // long reply doesn't bloat the doc — the preview only ever
    // shows ~2 lines anyway.
    final replyMsg = current.replyTarget;
    ReplyTarget? replyPayload;
    if (replyMsg != null) {
      final snippet = replyMsg.text.length > 140
          ? '${replyMsg.text.substring(0, 140)}…'
          : replyMsg.text;
      replyPayload = ReplyTarget(
        messageId: replyMsg.id,
        text: snippet,
        senderName: replyMsg.senderName,
        senderId: replyMsg.senderId,
      );
    }

    // Build an optimistic bubble. Tagged with isPending=true so
    // the UI renders the small ⏱ status icon. tempId uses a
    // microsecond timestamp — colliding with a real Firestore
    // doc id is effectively impossible. sessionId is stamped so
    // the view treats it as a current-session bubble (long-press
    // reactions allowed) rather than a past-session bubble.
    final tempId =
        '__pending_${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = ChatMessage.pending(
      tempId: tempId,
      senderId: senderId,
      senderName: senderName,
      text: trimmed,
      sessionId: _sessionId,
      replyTo: replyPayload,
    );
    _pendingOutbound.add(optimistic);

    if (!isClosed) {
      // Clear the reply target the moment we queue the send so the
      // compose chip disappears immediately and the user can start
      // typing the next message without an extra tap.
      emit(current.copyWith(
        messages: _buildMergedTimeline(current.session.id),
        isSendingMessage: true,
        clearReplyTarget: true,
      ));
    }

    try {
      await _repository.sendMessage(
        sessionId: _sessionId,
        senderId: senderId,
        senderName: senderName,
        text: trimmed,
        replyTo: replyPayload,
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
            messages: _buildMergedTimeline(s.session.id),
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
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _presenceCheckTimer?.cancel();
    _presenceCheckTimer = null;
  }

  @override
  Future<void> close() {
    _stopAllTimers();
    _sessionSubscription?.cancel();
    _messagesSubscription?.cancel();
    _balanceSubscription?.cancel();
    _freeMessagesSubscription?.cancel();
    _mutedPriestsSubscription?.cancel();
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
