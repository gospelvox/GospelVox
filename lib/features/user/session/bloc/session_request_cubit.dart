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
      } else if (reason.contains('priest-in-bible-session')) {
        // Distinct from priest-busy so the user gets honest copy
        // about WHY the speaker is unreachable. Checked BEFORE the
        // generic priest-busy branch because the CF only throws
        // one code at a time, but ordering keeps grep-by-string
        // matching deterministic if the message format ever changes.
        emit(const SessionRequestError(
            'This speaker is teaching a Bible session right now. '
            'Please try again once the session ends.'));
      } else if (reason.contains('priest-busy')) {
        emit(const SessionRequestError(
            'This speaker is currently in another session.'));
      } else if (reason.contains('priest-blocked')) {
        // User has this speaker on their block list. The feed already
        // hides them, so the only way to hit this is a stale view (the
        // user navigated to the profile before the home stream caught
        // up). Tell them honestly so they don't keep retrying.
        emit(const SessionRequestError(
            "You've blocked this speaker. Unblock from "
            'Settings to start a session again.'));
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
          // Fire-and-forget call to expireSessionRequest. The CF
          // marks the session 'expired' AND writes a missed_request
          // notification + push to the priest in one atomic op, so
          // the priest always gets a signal that someone tried to
          // reach them. If this call fails (network blip, app
          // killed before it lands), the watchdog's 5-minute cron
          // catches the stuck pending session as a safety net.
          //
          // This deliberately does NOT use cancelSession — that
          // writes status='cancelled' which we reserve for the
          // user actively tapping Cancel. The two are
          // semantically different: 'expired' means the priest
          // didn't respond in time, 'cancelled' means the user
          // changed their mind.
          unawaited(_repository
              .expireSessionRequest(sessionId)
              .catchError((_) {}));
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
  //
  // Every cancel — at any elapsed time, including 1-second mistaps —
  // routes through expireSessionRequest so the priest gets a
  // missed_request notification. The intent ladder is:
  //   1. The user opened the priest's profile.
  //   2. They tapped Chat or Call.
  //   3. They saw the rate, the wait UI, the connection animation.
  //   4. They cancelled.
  // That is intent. The priest deserves to know someone tried.
  //
  // We deliberately don't gate this on elapsed time. A previous
  // 8-second threshold treated <8s as "real cancel, no notify"
  // and >8s as "user waited and gave up", but it under-counted
  // missed opportunities — most users who change their mind in
  // 3 seconds still represent a priest who wasn't responsive
  // enough. Routing every cancel through the expire path turns
  // ~95% of all "user tried to reach me" events into visible
  // missed-request cards.
  Future<void> cancelRequest() async {
    _terminalEmitted = true;
    _stopCountdown();

    final current = state;
    if (current is SessionRequestWaiting) {
      try {
        await _repository.expireSessionRequest(current.session.id);
      } catch (_) {
        // Swallow — the session may already be accepted/expired. The
        // stream listener will reconcile whatever the real state is.
        // Watchdog catches anything this missed.
      }
    }

    if (!isClosed) emit(const SessionRequestCancelled());
  }

  @override
  Future<void> close() {
    _stopCountdown();
    _sessionSubscription?.cancel();

    // If the widget dies while we're still in Waiting (user backs
    // out, taps a deep link, navigates elsewhere, etc.), fire
    // expireSessionRequest the same way cancelRequest does so the
    // priest gets a missed_request notification. Fire-and-forget —
    // close() can't await; the watchdog 5-minute cron is the
    // safety net.
    final current = state;
    if (current is SessionRequestWaiting) {
      _repository
          .expireSessionRequest(current.session.id)
          .catchError((_) {});
    }

    return super.close();
  }
}
