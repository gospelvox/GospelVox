// Drives the user-facing session request flow. The cubit owns three
// pieces of state:
//   • a FirebaseFunctions callable result (sessionId)
//   • a Firestore snapshot stream on that session doc
//   • a local 60s countdown
//
// The priest's response flips the session's status field; the stream
// wakes us up, we map the new status to a state, navigation happens.
// If nothing arrives before the countdown hits zero the cubit
// cancels the session itself so the server doesn't accrue zombie
// pending requests. The countdown is client-side because the CF
// watchdog runs on a slower schedule and this screen must feel
// responsive.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/features/user/session/bloc/session_request_state.dart';

class SessionRequestCubit extends Cubit<SessionRequestState> {
  final SessionRepository _repository;

  StreamSubscription<SessionModel>? _sessionSubscription;
  Timer? _countdownTimer;
  int _secondsRemaining = 60;

  // Once we hit any terminal state (accepted / declined / expired /
  // cancelled) we ignore every further Firestore snapshot. Without
  // this, a stale "pending" snapshot arriving after the local 60s
  // timer elapsed (Firestore write latency between our cancel and
  // the status flip) would re-emit Waiting, spin up a fresh timer,
  // and make the counter tick into negatives before the status
  // finally lands.
  bool _terminalEmitted = false;

  SessionRequestCubit(this._repository)
      : super(const SessionRequestInitial());

  // Step 1: hit the CF, then step 2: listen to the resulting doc.
  Future<void> sendRequest({
    required String priestId,
    required String type,
  }) async {
    try {
      if (isClosed) return;
      emit(const SessionRequestSending());

      final sessionId = await _repository.createSessionRequest(
        priestId: priestId,
        type: type,
      );

      _startWatching(sessionId);
    } on TimeoutException {
      if (isClosed) return;
      emit(const SessionRequestError(
          'Request timed out. Check your connection.'));
    } on FirebaseFunctionsException catch (e) {
      // The CF throws HttpsError with specific `message` codes so the
      // client can render a precise reason rather than a generic
      // failure. Fall back to the generic copy for anything else.
      // Log the raw error so we can diagnose unexpected codes in the
      // console without having to crack open the catch in a debugger.
      debugPrint(
        '[SessionRequestCubit] createSessionRequest failed: '
        'code=${e.code} message=${e.message} details=${e.details}',
      );
      if (isClosed) return;
      final reason = '${e.code} ${e.message ?? ''}';
      if (reason.contains('insufficient-balance')) {
        emit(const SessionRequestError('Insufficient coin balance.'));
      } else if (reason.contains('priest-offline')) {
        emit(const SessionRequestError(
            'This speaker just went offline.'));
      } else if (reason.contains('priest-busy')) {
        emit(const SessionRequestError(
            'This speaker is currently in another session.'));
      } else if (reason.contains('unimplemented')) {
        emit(const SessionRequestError(
            'Server not deployed yet. Run: firebase deploy '
            '--only functions:createSessionRequest'));
      } else {
        emit(SessionRequestError(
            'Request failed: ${e.message ?? e.code}'));
      }
    } catch (e, st) {
      debugPrint('[SessionRequestCubit] unexpected error: $e\n$st');
      if (isClosed) return;
      emit(SessionRequestError('Unexpected error: $e'));
    }
  }

  void _startWatching(String sessionId) {
    _secondsRemaining = 60;
    _terminalEmitted = false;

    _sessionSubscription?.cancel();
    _sessionSubscription = _repository.watchSession(sessionId).listen(
      (session) {
        if (isClosed) return;
        // Once we've transitioned to a terminal state, every
        // subsequent snapshot is noise. Swallow it — the page has
        // already moved on (sheet shown / route changed).
        if (_terminalEmitted) return;

        switch (session.status) {
          case 'pending':
            // Emitting inside pending keeps the session object fresh
            // in state (e.g. if server back-fills createdAt a moment
            // later). Countdown kicks off lazily so a burst of
            // snapshots doesn't reset the ticker.
            emit(SessionRequestWaiting(
              session: session,
              secondsRemaining: _secondsRemaining,
            ));
            _startCountdown(sessionId);
            break;

          case 'active':
            _terminalEmitted = true;
            _stopCountdown();
            emit(SessionRequestAccepted(session));
            break;

          case 'declined':
            _terminalEmitted = true;
            _stopCountdown();
            emit(SessionRequestDeclined(session.priestName));
            break;

          case 'expired':
            _terminalEmitted = true;
            _stopCountdown();
            emit(const SessionRequestExpired());
            break;

          case 'cancelled':
            _terminalEmitted = true;
            _stopCountdown();
            emit(const SessionRequestCancelled());
            break;
        }
      },
      onError: (_) {
        if (isClosed || _terminalEmitted) return;
        emit(const SessionRequestError(
            'Connection lost. Please try again.'));
      },
    );
  }

  void _startCountdown(String sessionId) {
    // Don't restart the timer after we've already terminated —
    // a late-arriving "pending" snapshot should not revive the
    // countdown. This is the guard that keeps the timer from
    // ticking into negatives after the 0→expired transition.
    if (_terminalEmitted) return;
    if (_countdownTimer != null) return;

    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        _secondsRemaining--;

        if (_secondsRemaining <= 0) {
          _terminalEmitted = true;
          _stopCountdown();
          // Best-effort cancel — the CF might beat us to it with an
          // "expired" flip, in which case this write harmlessly
          // errors on the already-terminal doc.
          unawaited(_repository.cancelSession(sessionId).catchError((_) {}));
          if (!isClosed) emit(const SessionRequestExpired());
          return;
        }

        final current = state;
        if (current is SessionRequestWaiting && !isClosed) {
          emit(current.copyWith(secondsRemaining: _secondsRemaining));
        }
      },
    );
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  // User taps "Cancel Request" in the waiting UI.
  Future<void> cancelRequest() async {
    _terminalEmitted = true;
    _stopCountdown();

    final current = state;
    if (current is SessionRequestWaiting) {
      try {
        await _repository.cancelSession(current.session.id);
      } catch (_) {
        // Swallow — the session may already be accepted/expired. The
        // stream listener will reconcile whatever the real state is.
      }
    }

    if (!isClosed) emit(const SessionRequestCancelled());
  }

  @override
  Future<void> close() {
    _stopCountdown();
    _sessionSubscription?.cancel();

    // If the widget dies while we're still in Waiting (user kills
    // app, taps a deep link, etc.), fire a best-effort cancel so
    // the session doc doesn't sit pending forever. Without this
    // the next Chat tap would hit "already-exists" on the CF
    // until the server's 60s auto-expire kicks in.
    final current = state;
    if (current is SessionRequestWaiting) {
      _repository
          .cancelSession(current.session.id)
          .catchError((_) {
        // Swallow — nothing to recover from here; the server-side
        // stale-pending cleanup in createSessionRequest is the
        // authoritative safety net.
      });
    }

    return super.close();
  }
}
