// States for the live voice call. Mirror of ChatSessionState — both
// sides share this state machine and only differ in which timers
// the cubit starts (user ticks billing + heartbeat, priest watches
// passively). One state hierarchy keeps the voice UI a single
// widget instead of two near-identical copies.

import 'package:gospel_vox/features/shared/data/session_model.dart';

sealed class VoiceCallState {
  const VoiceCallState();
}

class VoiceCallInitial extends VoiceCallState {
  const VoiceCallInitial();
}

// We're fetching the Agora token + initialising the engine.
class VoiceCallConnecting extends VoiceCallState {
  const VoiceCallConnecting();
}

class VoiceCallActive extends VoiceCallState {
  final SessionModel session;
  final int elapsedSeconds;
  final int remainingBalance;
  final bool isMuted;
  final bool isSpeakerOn;
  // True once the OTHER party joins the Agora channel. Until then,
  // the call shows "Waiting…" instead of "Connected" — useful for
  // the user to see whether the priest's app is actually live.
  final bool isRemoteUserJoined;
  final bool isLowBalance;
  final bool isEnding;
  // True while Agora is in connectionStateReconnecting OR after the
  // remote user dropped off the channel. Surfaces the amber banner.
  final bool isReconnecting;
  // Surfaces the "Can't hear the other person?" hint after the
  // remote party has been silent for ≥15s with the channel still
  // connected — covers the muted-mic / OS-blocked-mic case where
  // there's no error to show, just unhelpful silence.
  final bool showSilenceWarning;
  // Worst of (txQuality, rxQuality) from Agora, on the documented
  // 0-6 scale (1=excellent, 6=disconnected, 0=unknown). Drives
  // both the top-bar signal indicator and the 30-second
  // auto-disconnect timer in the cubit.
  final int networkQuality;
  // Surfaces a "trouble connecting" hint when the local user has
  // joined the Agora channel but the remote party hasn't shown up
  // within 45 seconds. The cubit auto-ends the call at 60 seconds
  // total (reason: connection_failed); this flag drives the
  // 45→60 second warning window.
  final bool showConnectionTrouble;

  const VoiceCallActive({
    required this.session,
    required this.elapsedSeconds,
    required this.remainingBalance,
    this.isMuted = false,
    this.isSpeakerOn = true,
    this.isRemoteUserJoined = false,
    this.isLowBalance = false,
    this.isEnding = false,
    this.isReconnecting = false,
    this.showSilenceWarning = false,
    // Default to 1 (excellent) so the indicator stays hidden until
    // Agora actually reports a degradation. 0 (unknown) would also
    // be safe but is visually identical and slightly noisier
    // semantically.
    this.networkQuality = 1,
    this.showConnectionTrouble = false,
  });

  // MM:SS used by the top timer pill. Padded so the pill width
  // doesn't reflow once we tick from 9:59 to 10:00.
  String get formattedTime {
    final minutes = elapsedSeconds ~/ 60;
    final seconds = elapsedSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // Approximate cost so far — ceiling of elapsed minutes, matching
  // the server's "round up to next minute" billing rule. Used in
  // the End Call confirmation sheet.
  int get currentCost {
    if (elapsedSeconds <= 0) return 0;
    final minutes = (elapsedSeconds / 60).ceil();
    return minutes * session.ratePerMinute;
  }

  VoiceCallActive copyWith({
    SessionModel? session,
    int? elapsedSeconds,
    int? remainingBalance,
    bool? isMuted,
    bool? isSpeakerOn,
    bool? isRemoteUserJoined,
    bool? isLowBalance,
    bool? isEnding,
    bool? isReconnecting,
    bool? showSilenceWarning,
    int? networkQuality,
    bool? showConnectionTrouble,
  }) {
    return VoiceCallActive(
      session: session ?? this.session,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      remainingBalance: remainingBalance ?? this.remainingBalance,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      isRemoteUserJoined: isRemoteUserJoined ?? this.isRemoteUserJoined,
      isLowBalance: isLowBalance ?? this.isLowBalance,
      isEnding: isEnding ?? this.isEnding,
      isReconnecting: isReconnecting ?? this.isReconnecting,
      showSilenceWarning: showSilenceWarning ?? this.showSilenceWarning,
      networkQuality: networkQuality ?? this.networkQuality,
      showConnectionTrouble:
          showConnectionTrouble ?? this.showConnectionTrouble,
    );
  }
}

// Terminal state. The page reads endReason to pick post-session
// copy (priest_ended → priest summary, anything else → dropped).
class VoiceCallEnded extends VoiceCallState {
  final SessionSummary summary;
  final SessionModel session;
  final String endReason;

  const VoiceCallEnded({
    required this.summary,
    required this.session,
    required this.endReason,
  });
}

class VoiceCallError extends VoiceCallState {
  final String message;
  const VoiceCallError(this.message);
}
