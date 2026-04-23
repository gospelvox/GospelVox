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
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        _secondsRemaining--;

        if (_secondsRemaining <= 0) {
          _countdownTimer?.cancel();
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
    if (!isActivated) {
      if (!isClosed) {
        emit(const IncomingRequestError('__needs_activation__'));
      }
      return;
    }

    final current = state;
    if (current is! IncomingRequestReceived) return;

    try {
      _countdownTimer?.cancel();
      if (isClosed) return;
      emit(IncomingRequestAccepting(current.session));

      await _repository.acceptSession(sessionId);

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
    return super.close();
  }
}
