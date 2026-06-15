// Drives the priest-side incoming request screen. This cubit is
// handed a SessionModel up front (the dashboard's stream listener
// navigates to this screen only after a pending session is already
// visible), so there's no "loading" network dance — we immediately
// compute how much of the 60s window is left and start ticking.
//
// Accept is gated by the priest's activation state. The decision
// lives here (not in the page) so the cubit stays the single source
// of truth for "was this accept allowed?"; the page just renders the
// activation bottom sheet when the cubit surfaces the sentinel.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/features/priest/session/bloc/incoming_request_state.dart';

class IncomingRequestCubit extends Cubit<IncomingRequestState> {
  final SessionRepository _repository;

  Timer? _countdownTimer;
  int _secondsRemaining = 60;

  // Stream subscription on the session doc. We watch it so the
  // priest's screen auto-dismisses if the user cancels (or the
  // request expires server-side) instead of waiting for the local
  // 60s countdown to wind down to a request that no longer exists.
  StreamSubscription<SessionModel>? _sessionSubscription;

  // Once we've transitioned to ANY terminal state, we ignore
  // further session-doc snapshots. Without this, the snapshot
  // confirming our own accept would race the in-flight accept
  // and risk emitting Cancelled on top of Accepted.
  bool _terminalEmitted = false;

  IncomingRequestCubit(this._repository)
      : super(const IncomingRequestInitial());

  // Called once, right after the cubit is constructed. The session
  // might have been created seconds ago — we subtract that elapsed
  // time so priest and user screens roughly agree on the remaining
  // window. If the clocks are skewed we still clamp to [0, 60].
  void receiveRequest(SessionModel session) {
    _secondsRemaining = 60;

    if (session.createdAt != null) {
      final elapsed =
          DateTime.now().difference(session.createdAt!).inSeconds;
      _secondsRemaining = (60 - elapsed).clamp(0, 60);
    }

    if (_secondsRemaining <= 0) {
      _terminalEmitted = true;
      if (!isClosed) emit(const IncomingRequestExpired());
      return;
    }

    if (!isClosed) {
      emit(IncomingRequestReceived(
        session: session,
        secondsRemaining: _secondsRemaining,
      ));
    }

    _startCountdown();
    _attachSessionStream(session);
  }

  // Subscribes to the session doc so a remote status change
  // (user-cancel, server-expire, etc.) immediately dismisses the
  // priest's incoming screen. Without this the priest would be
  // staring at a request that no longer exists for up to 60s.
  void _attachSessionStream(SessionModel session) {
    _sessionSubscription?.cancel();
    _sessionSubscription =
        _repository.watchSession(session.id).listen((snap) {
      if (isClosed || _terminalEmitted) return;

      switch (snap.status) {
        case 'pending':
          // Still waiting for our action — nothing to do.
          break;
        case 'cancelled':
          _terminalEmitted = true;
          _countdownTimer?.cancel();
          emit(IncomingRequestUserCancelled(snap.userName));
          break;
        case 'expired':
          _terminalEmitted = true;
          _countdownTimer?.cancel();
          emit(const IncomingRequestExpired());
          break;
        // 'active' / 'completed' / 'declined' all imply the
        // priest's accept/decline already landed — the local
        // emit covers those, the snapshot just confirms.
        default:
          break;
      }
    }, onError: (_) {
      // Silent — session-doc reads can fail transiently. The
      // local 60s timer is the safety net.
    });
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        _secondsRemaining--;

        if (_secondsRemaining <= 0) {
          _terminalEmitted = true;
          _countdownTimer?.cancel();
          // Release the request server-side so the session is marked
          // 'expired' and the priest's isBusy flag clears (via
          // onSessionTerminal). CRITICAL when the USER's app was
          // killed mid-ring: their countdown can't fire, so without
          // this the request sits 'pending' and the priest stays Busy
          // until the 5-minute watchdog. The priest's app is alive
          // here (this very timer fired), so the call reliably lands.
          // Fire-and-forget; the CF is idempotent + notify-once, so
          // racing the user's countdown can't double-charge or
          // double-notify.
          final current = state;
          if (current is IncomingRequestReceived) {
            _repository
                .expireSessionRequest(current.session.id)
                .catchError((_) {});
          }
          if (!isClosed) emit(const IncomingRequestExpired());
          return;
        }

        final current = state;
        if (current is IncomingRequestReceived && !isClosed) {
          emit(current.copyWith(secondsRemaining: _secondsRemaining));
        }
      },
    );
  }

  // Accept is a two-step: activation gate, then Firestore write. If
  // the priest isn't activated we emit the sentinel error so the
  // page opens the activation bottom sheet instead of writing a
  // session the priest can't legally take.
  Future<void> acceptRequest(String sessionId, bool isActivated) async {
    final current = state;
    if (current is! IncomingRequestReceived) return;

    // The isActivated flag handed in can be STALE. On a cold app
    // launch (priest reopened after a kill) the activation stream
    // hadn't loaded yet, so the incoming screen received false — which
    // would wrongly throw a genuinely-activated priest into the ₹500
    // paywall and block them from accepting their own call. Only when
    // the flag is false do we pay for one fresh read to confirm before
    // blocking; an already-true flag accepts with no extra latency.
    var activated = isActivated;
    if (!activated) {
      try {
        activated =
            await _repository.isPriestActivated(current.session.priestId);
      } catch (e) {
        debugPrint('[IncomingRequestCubit] activation re-check failed: $e');
      }
    }
    if (!activated) {
      if (!isClosed) {
        emit(const IncomingRequestError('__needs_activation__'));
      }
      return;
    }

    try {
      _countdownTimer?.cancel();
      if (isClosed) return;
      emit(IncomingRequestAccepting(current.session));

      await _repository.acceptSession(sessionId);

      _terminalEmitted = true;
      if (isClosed) return;
      emit(IncomingRequestAccepted(current.session));
    } on TimeoutException {
      debugPrint('[IncomingRequestCubit] acceptSession timed out');
      if (isClosed) return;
      emit(const IncomingRequestError(
          'Accept timed out. Try again.'));
    } catch (e, st) {
      // Surface the real Firestore error. The most common cause is
      // a restrictive security rule on the sessions collection —
      // without logging, the priest just sees "Failed to accept"
      // with no way to know what to fix.
      debugPrint('[IncomingRequestCubit] acceptSession failed: $e\n$st');
      if (isClosed) return;
      emit(IncomingRequestError('Failed to accept: $e'));
    }
  }

  Future<void> declineRequest(String sessionId) async {
    try {
      _countdownTimer?.cancel();
      await _repository.declineSession(sessionId);
      _terminalEmitted = true;
      if (!isClosed) emit(const IncomingRequestDeclined());
    } catch (e, st) {
      debugPrint('[IncomingRequestCubit] declineSession failed: $e\n$st');
      if (!isClosed) {
        emit(IncomingRequestError('Failed to decline: $e'));
      }
    }
  }

  @override
  Future<void> close() {
    _countdownTimer?.cancel();
    _sessionSubscription?.cancel();

    // If the priest leaves the incoming-ring screen WITHOUT answering
    // (app killed / swiped away / navigated off while still ringing),
    // expire the request now so the waiting user is released INSTANTLY
    // — mirroring the user-side cubit, which expires on close. We only
    // do this while still actively ringing (state == Received): once
    // the priest has tapped Accept/Decline, or the user already
    // cancelled/expired it, the state has moved on and _terminalEmitted
    // is set, so we never clobber an accepted call or double-fire.
    // Fire-and-forget — close() can't await; the user's 60s countdown
    // and the watchdog remain the backstops for a hard force-stop where
    // this write can't land.
    final current = state;
    if (current is IncomingRequestReceived && !_terminalEmitted) {
      _repository
          .expireSessionRequest(current.session.id)
          .catchError((_) {});
    }

    return super.close();
  }
}
