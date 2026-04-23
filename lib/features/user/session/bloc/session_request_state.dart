// States for the user-side "request a session" flow. The sending →
// waiting → accepted/declined/expired/cancelled sequence matches the
// session document's status transitions so the page layer can blindly
// switch on the state without re-deriving meaning.

import 'package:gospel_vox/features/shared/data/session_model.dart';

sealed class SessionRequestState {
  const SessionRequestState();
}

class SessionRequestInitial extends SessionRequestState {
  const SessionRequestInitial();
}

// Firing createSessionRequest. Nothing to render yet besides a
// spinner — session doc does not exist on the client.
class SessionRequestSending extends SessionRequestState {
  const SessionRequestSending();
}

// Session doc exists, priest hasn't responded yet. secondsRemaining
// is re-emitted every second so the countdown UI can tick.
class SessionRequestWaiting extends SessionRequestState {
  final SessionModel session;
  final int secondsRemaining;

  const SessionRequestWaiting({
    required this.session,
    required this.secondsRemaining,
  });

  SessionRequestWaiting copyWith({
    SessionModel? session,
    int? secondsRemaining,
  }) =>
      SessionRequestWaiting(
        session: session ?? this.session,
        secondsRemaining: secondsRemaining ?? this.secondsRemaining,
      );
}

class SessionRequestAccepted extends SessionRequestState {
  final SessionModel session;
  const SessionRequestAccepted(this.session);
}

class SessionRequestDeclined extends SessionRequestState {
  final String priestName;
  const SessionRequestDeclined(this.priestName);
}

class SessionRequestExpired extends SessionRequestState {
  const SessionRequestExpired();
}

class SessionRequestCancelled extends SessionRequestState {
  const SessionRequestCancelled();
}

class SessionRequestError extends SessionRequestState {
  final String message;
  const SessionRequestError(this.message);
}
