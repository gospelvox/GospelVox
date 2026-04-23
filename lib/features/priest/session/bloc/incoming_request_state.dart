// States for the priest-side incoming request screen. The flow is
// smaller than the user's: a single inbound session, with Accept or
// Decline, plus a shared timeout. We still use a sealed hierarchy
// because the activation gate short-circuits the accept path with
// an error-shaped state (see IncomingRequestError handling).

import 'package:gospel_vox/features/shared/data/session_model.dart';

sealed class IncomingRequestState {
  const IncomingRequestState();
}

class IncomingRequestInitial extends IncomingRequestState {
  const IncomingRequestInitial();
}

class IncomingRequestLoading extends IncomingRequestState {
  const IncomingRequestLoading();
}

// The priest is looking at the request. secondsRemaining ticks down
// the same 60s window the user is counting on their side.
class IncomingRequestReceived extends IncomingRequestState {
  final SessionModel session;
  final int secondsRemaining;

  const IncomingRequestReceived({
    required this.session,
    required this.secondsRemaining,
  });

  IncomingRequestReceived copyWith({
    SessionModel? session,
    int? secondsRemaining,
  }) =>
      IncomingRequestReceived(
        session: session ?? this.session,
        secondsRemaining: secondsRemaining ?? this.secondsRemaining,
      );
}

// Intermediate state while the accept network call is in flight, so
// the UI can show a spinner on the accept button instead of double-
// tapping racing the write.
class IncomingRequestAccepting extends IncomingRequestState {
  final SessionModel session;
  const IncomingRequestAccepting(this.session);
}

class IncomingRequestAccepted extends IncomingRequestState {
  final SessionModel session;
  const IncomingRequestAccepted(this.session);
}

class IncomingRequestDeclined extends IncomingRequestState {
  const IncomingRequestDeclined();
}

class IncomingRequestExpired extends IncomingRequestState {
  const IncomingRequestExpired();
}

// Dual-purpose: generic failures carry a user-facing message, while
// the sentinel `__needs_activation__` is the contract between cubit
// and page for "show the activation bottom sheet". Using a state
// instead of a callback keeps the cubit pure / testable.
class IncomingRequestError extends IncomingRequestState {
  final String message;
  const IncomingRequestError(this.message);
}
