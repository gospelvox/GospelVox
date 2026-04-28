// Runs the live voice call for one screen mount. Owns:
//   • a Firestore stream on the session doc (so we notice when the
//     other party or the watchdog ends the session)
//   • a Firestore stream on the user's coin balance (so an in-call
//     top-up reflects instantly without waiting for next billingTick)
//   • an AgoraService instance (mic capture, channel join, token
//     refresh) — owned and disposed by this cubit
//   • a Stopwatch + 1s timer for the MM:SS display clock
//   • a 30s heartbeat timer (user side only)
//   • a 60s billingTick timer (user side only — only one client
//     can drive billing or we'd double-charge)
//
// The billing model is identical to chat: the user's client ticks
// once per minute, the priest's client just watches. If the user's
// device dies mid-call, the sessionWatchdog Cloud Function finalises
// billing from server-side state.
//
// Token refresh: Agora tokens are 1h TTL. The SDK fires
// onTokenPrivilegeWillExpire ~30s before expiry; we fetch a fresh
// token from the CF and hand it back via renewToken. A failed
// refresh logs but doesn't crash — the SDK gives a small grace
// window after expiry, and the watchdog catches anything truly
// stuck.

import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/core/services/agora_service.dart';
import 'package:gospel_vox/core/services/call_keep_alive_service.dart';
import 'package:gospel_vox/features/shared/bloc/voice_call_state.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';

class VoiceCallCubit extends Cubit<VoiceCallState> {
  final SessionRepository _repository;
  final AgoraService _agoraService;

  StreamSubscription<SessionModel>? _sessionSubscription;
  StreamSubscription<int>? _balanceSubscription;
  Timer? _elapsedTimer;
  Timer? _heartbeatTimer;
  Timer? _billingTimer;
  // CASE 6: When the SDK reports networkQuality=6 (disconnected),
  // we don't end the call instantly — momentary radio drops are
  // common on cellular and most resolve within a few seconds. We
  // arm a 30-second timer; if quality recovers below 6 within the
  // window, we cancel. If it doesn't, we end the call with a
  // dedicated "network_disconnected" reason so the dropped page
  // can render the right copy.
  Timer? _disconnectTimer;
  // Flag #7: remote-join supervisor. If the local user has joined
  // the Agora channel but the remote party never shows up, the
  // watchdog CF won't catch it (heartbeat is still flowing). Two
  // staged timers prevent users being stuck on "Waiting…":
  //   • _remoteJoinHintTimer  — at 45s, surface the
  //     "trouble connecting" hint banner.
  //   • _remoteJoinFailTimer  — at 60s, end the call with
  //     reason 'connection_failed'.
  // Both are armed once joinChannel returns and cancelled the
  // moment onUserJoined fires (or on close / endCall).
  Timer? _remoteJoinHintTimer;
  Timer? _remoteJoinFailTimer;
  final Stopwatch _stopwatch = Stopwatch();

  int _lastKnownBalance = 0;
  String _sessionId = '';
  bool _isUserSide = true;
  bool _timersStarted = false;
  bool _endingDispatched = false;

  VoiceCallCubit(this._repository, this._agoraService)
      : super(const VoiceCallInitial());

  // Boot the call: init Agora, fetch a token, join the channel,
  // start watching the session doc. The session stream drives the
  // active state — we only emit Active after the first snapshot.
  Future<void> startCall({
    required String sessionId,
    required bool isUserSide,
  }) async {
    _sessionId = sessionId;
    _isUserSide = isUserSide;

    try {
      if (isClosed) return;
      emit(const VoiceCallConnecting());

      await _agoraService.init();
      _wireAgoraCallbacks();

      // CASE 2 + 3: promote the app to a foreground service before
      // we join the channel. Doing it here (after init / mic
      // permission has been granted, before any network work) means
      // by the time the channel is up we already have OS-level
      // protection against being killed when backgrounded. Failure
      // is non-fatal — the call still works, the OS just might kill
      // us on aggressive OEMs. See CallKeepAliveService.
      await CallKeepAliveService.start();

      // Token + numeric Agora uid come from the Cloud Function. The
      // CF validates that the caller is a participant in the
      // session, so we don't need a second auth check here.
      final tokenData = await _repository.getAgoraToken(sessionId);
      final token = tokenData['token'] as String;
      final agoraUid = tokenData['uid'] as int;

      await _agoraService.joinChannel(
        channelName: sessionId,
        token: token,
        uid: agoraUid,
      );

      // Flag #7: now that we're "in" the channel locally, give the
      // remote party a bounded window to show up. _wireAgoraCallbacks
      // wires onUserJoined to cancel both timers; close / endCall
      // also stop them via _stopAllTimers.
      _armRemoteJoinTimers();

      _sessionSubscription = _repository.watchSession(sessionId).listen(
        _onSessionSnapshot,
        onError: (_) {
          if (isClosed) return;
          emit(const VoiceCallError('Connection lost.'));
        },
      );
    } catch (e, stack) {
      if (isClosed) return;
      // Surface the real cause in logcat. The on-screen text stays
      // user-friendly, but a developer reading `flutter logs` should
      // see exactly which CF code / Agora error / network failure
      // we hit instead of a generic "failed to connect."
      debugPrint('[VoiceCallCubit] startCall failed: $e\n$stack');
      final message = e.toString();
      await _agoraService.dispose();
      // Bug #2: drop the foreground notification too. If we got
      // past CallKeepAliveService.start() but failed before joining
      // (token fetch / joinChannel threw), the FGS would otherwise
      // linger until the cubit closes.
      await CallKeepAliveService.stop();
      if (isClosed) return;
      if (message.contains('Microphone permission denied')) {
        emit(const VoiceCallError(
            'Microphone permission is required for voice calls. '
            'Please enable it in your device settings.'));
      } else {
        emit(const VoiceCallError(
            'Failed to connect. Please try again.'));
      }
    }
  }

  void _onSessionSnapshot(SessionModel session) {
    if (isClosed) return;

    // Any non-active status means the session is done — same
    // collapse-to-end logic as chat. Could be the other side
    // ending it, the watchdog finishing a stale session, or the
    // billing CF auto-ending on balance-zero.
    if (session.status != 'active') {
      if (_endingDispatched) return;
      _endingDispatched = true;
      _stopAllTimers();
      // Fire-and-forget the engine teardown; we don't need to
      // await it before navigating away.
      _agoraService.dispose();
      final reason = session.endReason.isNotEmpty
          ? session.endReason
          : (session.status == 'completed' ? 'completed' : 'external');
      _fetchSummaryAndEnd(session, reason);
      return;
    }

    final current = state;
    if (current is VoiceCallActive) {
      emit(current.copyWith(session: session));
      return;
    }

    // First active snapshot — seed and start side-specific timers.
    _lastKnownBalance = session.userBalance;
    if (!_timersStarted) {
      _timersStarted = true;
      _startTimers(_sessionId);
      if (_isUserSide) {
        // Live wallet stream so an in-call top-up reflects
        // instantly instead of waiting for the next billingTick.
        _balanceSubscription = _repository
            .watchUserBalance(session.userId)
            .listen(_onBalanceSnapshot);
      }
    }

    emit(VoiceCallActive(
      session: session,
      elapsedSeconds: 0,
      remainingBalance: session.userBalance,
      isMuted: _agoraService.isMuted,
      isSpeakerOn: _agoraService.isSpeakerOn,
      isLowBalance: _isUserSide && session.userBalance <= 50,
    ));
  }

  void _onBalanceSnapshot(int newBalance) {
    if (isClosed) return;
    final current = state;
    if (current is! VoiceCallActive) return;
    _lastKnownBalance = newBalance;
    emit(current.copyWith(
      remainingBalance: newBalance,
      isLowBalance: newBalance <= 50,
    ));
  }

  void _wireAgoraCallbacks() {
    // Other party joined the Agora channel. Until this fires, the
    // call shows "Waiting…" — the priest's app may still be
    // booting Agora on the other end.
    _agoraService.onUserJoined = (connection, remoteUid, elapsed) {
      if (isClosed) return;
      // Flag #7: they made it within the window — kill the
      // remote-join supervisor and dismiss any "trouble connecting"
      // banner we may have already surfaced.
      _cancelRemoteJoinTimers();
      final current = state;
      if (current is VoiceCallActive) {
        emit(current.copyWith(
          isRemoteUserJoined: true,
          isReconnecting: false,
          showConnectionTrouble: false,
        ));
      }
    };

    // Other party left the channel — could be a network blip, a
    // backgrounded app, or a real drop. Show "Reconnecting…" but
    // DON'T end the session here: the watchdog catches a real
    // 2-minute disconnect, and the user might still want to hold
    // the line for a momentary network glitch.
    _agoraService.onUserOffline = (connection, remoteUid, reason) {
      if (isClosed) return;
      final current = state;
      if (current is VoiceCallActive) {
        emit(current.copyWith(
          isRemoteUserJoined: false,
          isReconnecting: true,
        ));
      }
    };

    // Token is about to expire — fetch a fresh one and hand it to
    // the engine. A failed refresh is logged but not surfaced; the
    // SDK has a short grace window and the watchdog handles a
    // permanent failure.
    _agoraService.onTokenExpiring = (connection) async {
      if (isClosed) return;
      try {
        final tokenData = await _repository.getAgoraToken(_sessionId);
        await _agoraService.renewToken(tokenData['token'] as String);
      } catch (e) {
        debugPrint('[VoiceCallCubit] Token refresh failed: $e');
      }
    };

    // Local connection state — drives the "Reconnecting…" banner
    // when our own client is in connectionStateReconnecting.
    _agoraService.onConnectionStateChanged =
        (connection, connState, reason) {
      if (isClosed) return;
      final current = state;
      if (current is! VoiceCallActive) return;
      final isReconnecting =
          connState == ConnectionStateType.connectionStateReconnecting;
      if (isReconnecting != current.isReconnecting) {
        emit(current.copyWith(isReconnecting: isReconnecting));
      }
    };

    // CASE 5: 15s of silence from the remote party. The Agora
    // service does the actual counting; we just translate the
    // boolean into UI state.
    _agoraService.onRemoteSilenceDetected = (isSilent) {
      if (isClosed) return;
      final current = state;
      if (current is VoiceCallActive) {
        emit(current.copyWith(showSilenceWarning: isSilent));
      }
    };

    // CASE 6: network quality + 30s disconnect grace timer. We
    // translate Agora's 0-6 scale into the state field, and arm /
    // disarm the disconnect timer based on the qualityDown (=6)
    // boundary. The timer itself only ends the call if quality is
    // STILL down after 30s.
    _agoraService.onNetworkQuality = (quality) {
      if (isClosed) return;
      final current = state;
      if (current is! VoiceCallActive) return;
      if (quality != current.networkQuality) {
        emit(current.copyWith(networkQuality: quality));
      }
      if (quality >= 6) {
        _armDisconnectTimer();
      } else {
        _cancelDisconnectTimer();
      }
    };
  }

  // Start a one-shot 30s timer. Idempotent — re-arming while the
  // timer is already running is a no-op so a stream of qualityDown
  // events doesn't keep resetting the deadline.
  void _armDisconnectTimer() {
    if (_disconnectTimer != null) return;
    _disconnectTimer = Timer(const Duration(seconds: 30), () {
      _disconnectTimer = null;
      if (isClosed) return;
      final current = state;
      if (current is VoiceCallActive && current.networkQuality >= 6) {
        // Still disconnected after 30s — give up. The reason
        // string is what session_dropped_page checks against.
        endCall(reason: 'network_disconnected');
      }
    });
  }

  void _cancelDisconnectTimer() {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
  }

  // Flag #7. Two staged timers covering the "remote never joined"
  // hole the watchdog can't see: heartbeat is still flowing from
  // the local side, so the watchdog won't kill the session even
  // though one party is missing.
  //   45s → flip showConnectionTrouble so the user sees something
  //         is wrong (instead of an indefinite "Waiting…").
  //   60s → end the call with reason 'connection_failed'.
  // Idempotent — re-arming while a timer is already running is a
  // no-op so a redundant call from another path can't shorten the
  // deadline.
  void _armRemoteJoinTimers() {
    _remoteJoinHintTimer ??= Timer(const Duration(seconds: 45), () {
      _remoteJoinHintTimer = null;
      if (isClosed) return;
      final current = state;
      if (current is VoiceCallActive && !current.isRemoteUserJoined) {
        emit(current.copyWith(showConnectionTrouble: true));
      }
    });
    _remoteJoinFailTimer ??= Timer(const Duration(seconds: 60), () {
      _remoteJoinFailTimer = null;
      if (isClosed) return;
      final current = state;
      if (current is VoiceCallActive && !current.isRemoteUserJoined) {
        endCall(reason: 'connection_failed');
      }
    });
  }

  void _cancelRemoteJoinTimers() {
    _remoteJoinHintTimer?.cancel();
    _remoteJoinHintTimer = null;
    _remoteJoinFailTimer?.cancel();
    _remoteJoinFailTimer = null;
  }

  // Called from VoiceCallView's didChangeAppLifecycleState when the
  // app returns to foreground. Re-asserts our local audio state in
  // case a system interruption (incoming cellular call, OS pause)
  // left Agora's track muted — see AgoraService.resumeAudio for
  // the recovery details.
  Future<void> onAppResumed() async {
    if (isClosed) return;
    await _agoraService.resumeAudio();
  }

  void _startTimers(String sessionId) {
    _stopwatch.start();

    // 1-second display tick. Cheap re-emit with the same session
    // reference and the new elapsed seconds.
    _elapsedTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (isClosed) return;
        final current = state;
        if (current is VoiceCallActive) {
          emit(current.copyWith(
            elapsedSeconds: _stopwatch.elapsed.inSeconds,
          ));
        }
      },
    );

    // Heartbeat + billing are user-side only — see top comment for
    // why double-billing must not happen.
    if (_isUserSide) {
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) {
          // Silent failure — the next 30s tick retries. If we stay
          // offline long enough the watchdog marks the session
          // stale.
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
      if (current is! VoiceCallActive) return;

      _lastKnownBalance = result.remainingBalance;
      emit(current.copyWith(
        remainingBalance: result.remainingBalance,
        isLowBalance: result.remainingBalance <= 50,
      ));

      if (result.shouldEnd && !_endingDispatched) {
        await endCall(reason: 'balance_zero');
      }
    } catch (e) {
      debugPrint('[VoiceCallCubit] billingTick failed: $e');
    }
  }

  // Mute toggle — flips the local mic publish flag inside Agora.
  // Doesn't affect billing; muting is a UX courtesy, not a way to
  // pause the meter.
  Future<void> toggleMute() async {
    await _agoraService.toggleMute();
    if (isClosed) return;
    final current = state;
    if (current is VoiceCallActive) {
      emit(current.copyWith(isMuted: _agoraService.isMuted));
    }
  }

  // Toggle between speakerphone and earpiece. Keeps the local
  // boolean in sync so the icon flips immediately, even before
  // the native call returns.
  Future<void> toggleSpeaker() async {
    await _agoraService.toggleSpeaker();
    if (isClosed) return;
    final current = state;
    if (current is VoiceCallActive) {
      emit(current.copyWith(isSpeakerOn: _agoraService.isSpeakerOn));
    }
  }

  // End the call. Either side may call this. The CF is idempotent,
  // so a stray duplicate from a slow Firestore stream is harmless.
  Future<void> endCall({String reason = 'user_ended'}) async {
    final current = state;
    if (current is! VoiceCallActive || current.isEnding) return;
    if (_endingDispatched) return;
    _endingDispatched = true;

    if (isClosed) return;
    emit(current.copyWith(isEnding: true));
    _stopAllTimers();
    await _agoraService.dispose();
    // Drop the foreground notification — call is genuinely over,
    // we don't need the OS to keep us alive any longer.
    await CallKeepAliveService.stop();

    try {
      final summary = await _repository.endSession(_sessionId);
      if (isClosed) return;
      emit(VoiceCallEnded(
        summary: summary,
        session: current.session,
        endReason: reason,
      ));
    } catch (_) {
      // CF failed. Don't strand the user on the call screen —
      // synthesize a best-effort summary from local state and let
      // the watchdog reconcile on the server.
      if (isClosed) return;
      emit(VoiceCallEnded(
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
    // Drop the foreground service before we navigate — staying
    // promoted past the end of the call would leave the
    // notification stuck.
    await CallKeepAliveService.stop();
    try {
      final summary = await _repository.endSession(_sessionId);
      if (isClosed) return;
      emit(VoiceCallEnded(
        summary: summary,
        session: session,
        endReason: reason,
      ));
    } catch (_) {
      if (isClosed) return;
      emit(VoiceCallEnded(
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
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _cancelRemoteJoinTimers();
  }

  @override
  Future<void> close() {
    _stopAllTimers();
    _sessionSubscription?.cancel();
    _balanceSubscription?.cancel();
    // Fire-and-forget — close() shouldn't await native cleanup.
    _agoraService.dispose();
    // Belt-and-braces stop in case the cubit is closed without
    // hitting endCall / _fetchSummaryAndEnd (e.g. user navigated
    // away mid-connect via a deep link). Idempotent.
    CallKeepAliveService.stop();
    return super.close();
  }
}
