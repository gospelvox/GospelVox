// Wraps the Agora RTC engine for one voice call's lifetime. The
// engine holds native audio resources, so we deliberately avoid
// making this a singleton — each call constructs a fresh service
// in the page's BlocProvider and disposes it when the cubit closes.
// Reusing a stale engine across calls produces audio glitches and
// occasional "channel already joined" errors that surface as silent
// calls on the other end.
//
// Lifecycle:
//   1. init() — request mic permission, create engine, register
//      event handlers, set audio profile.
//   2. joinChannel(token, channelName, uid) — enter the room with
//      a server-minted token.
//   3. renewToken(newToken) — called from onTokenPrivilegeWillExpire
//      so a long call doesn't drop when the 1h token rolls over.
//   4. dispose() — leaveChannel + release. Idempotent: safe to call
//      from multiple paths (cubit close, error, end-call confirm).
//
// All Agora errors land as logs + a callback to the cubit; we never
// crash the app from inside a native callback because that path is
// hard to reproduce and impossible to recover from.

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:gospel_vox/core/config/agora_config.dart';

class AgoraService {
  RtcEngine? _engine;

  // Callbacks the cubit wires up before joining. Kept as fields
  // (not constructor params) so we can null them out on dispose
  // and stop holding references to the closed cubit.
  void Function(RtcConnection connection, int remoteUid, int elapsed)?
      onUserJoined;
  void Function(RtcConnection connection, int remoteUid,
      UserOfflineReasonType reason)? onUserOffline;
  void Function(RtcConnection connection, RtcStats stats)? onRtcStats;
  void Function(RtcConnection connection)? onTokenExpiring;
  void Function(ErrorCodeType err, String msg)? onError;
  void Function(RtcConnection connection, ConnectionStateType state,
      ConnectionChangedReasonType reason)? onConnectionStateChanged;
  // Fires when the remote party has been silent for >= 15 seconds,
  // and again with `false` once their audio resumes. Drives the
  // "Can't hear the other person?" hint banner. See _silenceTicks
  // logic below.
  void Function(bool isSilent)? onRemoteSilenceDetected;
  // Network quality reports. The int is QualityType.value() — a
  // 0-6 scale where 1=excellent and 6=disconnected. Drives the
  // weak/poor signal indicator and the 30-second auto-end timer.
  void Function(int quality)? onNetworkQuality;

  bool _isInitialized = false;
  bool _isMuted = false;
  bool _isSpeakerOn = true;

  // Silence tracking. We count consecutive 1-second windows where
  // every reported remote speaker has volume == 0. Threshold is the
  // number of windows before we surface the warning.
  //
  // Why a separate active flag instead of just resetting the tick
  // counter: once we've fired `true`, we need to fire `false` when
  // audio comes back. If we only reset the counter, the "audio came
  // back" branch could never see ticks >= threshold and would never
  // dismiss the banner. The flag mirrors the on-screen state so the
  // transitions stay symmetric.
  int _silentTicks = 0;
  bool _silenceWarningActive = false;
  static const int _silenceThresholdTicks = 15;

  // Tracks whether at least one remote user is currently in the
  // channel. Drives two behaviours: (a) the silence detector skips
  // its tick logic until someone has joined — otherwise the user
  // would see "Can't hear the other person?" while waiting alone
  // for the priest to come online; (b) onUserOffline resets silence
  // state so the banner doesn't get stuck on after a drop.
  bool _remoteUserPresent = false;

  // Network quality state for the worst-across-both, 3-tick debounce
  // strategy. We keep the last per-uid worst (Agora reports
  // separately for the local user at uid=0 and each remote user)
  // and only forward a new value to the cubit when 3 consecutive
  // callbacks agree on it — that's ~6 seconds of consistent quality
  // at Agora's 2-second cadence, which is enough to filter the
  // single-spike flapping we'd otherwise show.
  final Map<int, int> _qualityByUid = {};
  int _lastEmittedQuality = 0;
  int? _pendingWorstQuality;
  int _pendingQualityCount = 0;
  static const int _qualityDebounceTicks = 3;

  bool get isInitialized => _isInitialized;
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;

  // Initialise the native engine. Throws if mic permission is
  // denied — the caller turns that into a user-facing message and
  // routes back to the previous screen instead of joining a
  // silent channel.
  Future<void> init() async {
    final micStatus = await Permission.microphone.request();
    if (micStatus.isDenied || micStatus.isPermanentlyDenied) {
      throw Exception('Microphone permission denied');
    }

    _engine = createAgoraRtcEngine();
    await _engine!.initialize(RtcEngineContext(
      appId: AgoraConfig.appId,
      // Communication profile = optimized for two-way voice.
      // LiveBroadcasting adds latency for an audience tier we
      // don't have here.
      channelProfile: ChannelProfileType.channelProfileCommunication,
      // Pin SD-routing to the India edge cluster. Agora's default
      // is global and can route an India↔India call through
      // Singapore or Frankfurt, adding 50-200ms of avoidable
      // latency. Both our user base and priest base are in India,
      // so locking the area code is a free quality win.
      areaCode: AreaCode.areaCodeIn.value(),
    ));

    _engine!.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        debugPrint(
            '[Agora] Joined channel: ${connection.channelId} (${elapsed}ms)');
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        debugPrint('[Agora] Remote user joined: $remoteUid');
        // Remote is present — silence detection can start running,
        // and the cubit's remote-join timeout (Flag #7) will be
        // cancelled by the cubit's own onUserJoined handler.
        _remoteUserPresent = true;
        onUserJoined?.call(connection, remoteUid, elapsed);
      },
      onUserOffline: (connection, remoteUid, reason) {
        debugPrint(
            '[Agora] Remote user offline: $remoteUid, reason: $reason');
        // Remote left — drop the silence banner immediately so the
        // user doesn't see "Can't hear the other person?" pinned on
        // an already-empty channel, and stop the silence ticker.
        _remoteUserPresent = false;
        _silentTicks = 0;
        if (_silenceWarningActive) {
          _silenceWarningActive = false;
          onRemoteSilenceDetected?.call(false);
        }
        // Forget this remote's quality reading. Keeping it would
        // freeze the worst-across-both calculation at the dropped
        // user's last value forever.
        _qualityByUid.remove(remoteUid);
        onUserOffline?.call(connection, remoteUid, reason);
      },
      onRtcStats: (connection, stats) {
        onRtcStats?.call(connection, stats);
      },
      onTokenPrivilegeWillExpire: (connection, token) {
        // Fires ~30s before expiry so we have time to fetch and
        // hand back a fresh token via renewToken().
        debugPrint('[Agora] Token expiring soon — requesting refresh');
        onTokenExpiring?.call(connection);
      },
      onError: (err, msg) {
        debugPrint('[Agora] Error: $err — $msg');
        onError?.call(err, msg);
      },
      onConnectionStateChanged: (connection, state, reason) {
        debugPrint('[Agora] Connection: $state, reason: $reason');
        onConnectionStateChanged?.call(connection, state, reason);
      },
      onAudioRoutingChanged: (routing) {
        // Bluetooth headset plug/unplug, speakerphone toggle, etc.
        // Agora handles the actual routing; we just log so any
        // future "audio went silent" report can be triaged from
        // logcat without guessing.
        debugPrint('[Agora] Audio routing changed: $routing');
      },
      onAudioVolumeIndication:
          (connection, speakers, speakerNumber, totalVolume) {
        // Bug #1: gate on remote presence. Until someone has joined
        // the channel, we have nothing to be "silent about" — the
        // user would otherwise see the silence banner ~15s into
        // waiting for the priest to come online, which is misleading.
        if (!_remoteUserPresent) return;

        // Walk the reported speakers and decide whether ANY remote
        // user has voice on this tick. The SDK gives us local at
        // uid=0 and remote users by their Agora uid; we ignore the
        // local entry because muting ourselves shouldn't make us
        // think the other side dropped.
        var remoteSilent = true;
        for (final s in speakers) {
          if (s.uid != 0 && (s.volume ?? 0) > 0) {
            remoteSilent = false;
            break;
          }
        }

        if (remoteSilent) {
          _silentTicks++;
          if (_silentTicks >= _silenceThresholdTicks &&
              !_silenceWarningActive) {
            _silenceWarningActive = true;
            onRemoteSilenceDetected?.call(true);
          }
        } else {
          _silentTicks = 0;
          if (_silenceWarningActive) {
            _silenceWarningActive = false;
            onRemoteSilenceDetected?.call(false);
          }
        }
      },
      onNetworkQuality: (connection, remoteUid, txQuality, rxQuality) {
        // Flag #6, option (b): worst across BOTH local and remote,
        // with 3-tick debounce. Agora fires this every ~2 seconds
        // separately for the local user (remoteUid=0) and each
        // remote user. Naïvely emitting the per-callback value would
        // flap state.networkQuality between local-good and
        // remote-bad readings and arm/cancel the disconnect timer
        // on alternate ticks.
        //
        // Strategy:
        //   1. Track the worst-of-(tx,rx) per uid (last seen wins
        //      for that uid — picks up real-time degradation).
        //   2. Compute the worst across all known uids — if EITHER
        //      side has bad signal, the call IS bad even if our own
        //      uplink is fine, so this matches the audio reality.
        //   3. Only forward to the cubit after 3 consecutive
        //      callbacks agree on the same worst value (~6s of
        //      consistent quality). Single-spike outliers are
        //      filtered.
        final tx = txQuality.value();
        final rx = rxQuality.value();
        final perUidWorst = tx > rx ? tx : rx;
        _qualityByUid[remoteUid] = perUidWorst;

        var worst = 0;
        for (final v in _qualityByUid.values) {
          if (v > worst) worst = v;
        }

        if (worst == _lastEmittedQuality) {
          // Already settled there — abort any pending change.
          _pendingWorstQuality = null;
          _pendingQualityCount = 0;
          return;
        }
        if (worst == _pendingWorstQuality) {
          _pendingQualityCount++;
          if (_pendingQualityCount >= _qualityDebounceTicks) {
            _lastEmittedQuality = worst;
            _pendingWorstQuality = null;
            _pendingQualityCount = 0;
            onNetworkQuality?.call(worst);
          }
        } else {
          _pendingWorstQuality = worst;
          _pendingQualityCount = 1;
        }
      },
    ));

    // Profile choice: musicStandard (48 kHz, up to 64 kbps) over
    // the previous speechStandard (32 kHz, up to 18 kbps). The SDK
    // does not expose a speechHighQuality tier, so musicStandard is
    // the right upgrade for a paid consult — it's the same profile
    // Telegram and Discord use for voice calls, gives noticeably
    // clearer audio at a modest bandwidth bump, and holds up fine
    // on Indian cellular. Chatroom scenario keeps the engine tuned
    // for two-party voice rather than music playback or
    // live-stream.
    await _engine!.setAudioProfile(
      profile: AudioProfileType.audioProfileMusicStandard,
      scenario: AudioScenarioType.audioScenarioChatroom,
    );

    // Default route = speakerphone. The setDefaultAudioRouteToSpeakerphone
    // API is the right one for the pre-join phase: it tells the SDK
    // which output to use the moment the channel comes up. Calling
    // setEnableSpeakerphone here (or even right after joinChannel
    // returns) throws ERR_NOT_READY (-3) because joinChannel is
    // fire-and-forget — the connection is still negotiating when the
    // call returns. setEnableSpeakerphone is reserved for runtime
    // toggling once we're already in the call (see toggleSpeaker).
    await _engine!.setDefaultAudioRouteToSpeakerphone(true);

    // Enable Agora's AI noise suppression. The native extension is
    // already bundled (see iris loaded-extensions log) but the API
    // has to be flipped on explicitly. "Balanced" mode trades a
    // little CPU for noticeably cleaner voice when the caller is
    // in a noisy room — fans, traffic, kids, AC hum — which is the
    // realistic environment for an evening consultation. Wrapped in
    // try/catch because some older devices don't ship the AINS
    // module and the call would otherwise abort init().
    try {
      await _engine!.setAINSMode(
        enabled: true,
        mode: AudioAinsMode.ainsModeBalanced,
      );
    } catch (e) {
      debugPrint('[Agora] AINS not available on this device: $e');
    }

    // Drive onAudioVolumeIndication. 1000ms cadence is the lowest
    // useful interval — we count seconds of remote silence, so 1s
    // ticks line up with the threshold logic exactly. smooth=3 is
    // Agora's default and irons out the spiky volume metering.
    // reportVad=false: voice activity detection adds CPU work we
    // don't need; volume==0 already tells us "not speaking".
    await _engine!.enableAudioVolumeIndication(
      interval: 1000,
      smooth: 3,
      reportVad: false,
    );

    _isInitialized = true;
  }

  // Re-assert the live audio state after a system interruption
  // (incoming cellular call, app backgrounded long enough for the
  // OS to pause us, etc). Agora usually self-heals, but on some
  // devices the local track stays muted after the interruption ends
  // — calling enableAudio + re-applying our local mute/speaker
  // booleans forces the SDK back into the state the user expects.
  // Cheap to call defensively from didChangeAppLifecycleState.
  Future<void> resumeAudio() async {
    final engine = _engine;
    if (!_isInitialized || engine == null) return;
    try {
      await engine.enableAudio();
      // Re-apply our own mute state — if we were muted before the
      // interruption, stay muted. If not, ensure the stream is live.
      await engine.muteLocalAudioStream(_isMuted);
      // Speaker re-toggle is wrapped because the channel may still
      // be reconnecting; toggleSpeaker swallows -3 the same way.
      try {
        await engine.setEnableSpeakerphone(_isSpeakerOn);
      } catch (_) {
        // Ignored — handled by toggleSpeaker rationale.
      }
      debugPrint('[Agora] Audio resumed after interruption');
    } catch (e) {
      debugPrint('[Agora] resumeAudio failed: $e');
    }
  }

  // Enter the Agora channel with a token minted server-side. uid
  // is the numeric Agora id derived from the Firebase uid (the CF
  // hashes it so both sides land on a stable, distinct id).
  Future<void> joinChannel({
    required String channelName,
    required String token,
    required int uid,
  }) async {
    final engine = _engine;
    if (!_isInitialized || engine == null) {
      throw Exception('Agora not initialised — call init() first');
    }

    await engine.joinChannel(
      token: token,
      channelId: channelName,
      uid: uid,
      options: const ChannelMediaOptions(
        autoSubscribeAudio: true,
        publishMicrophoneTrack: true,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
      ),
    );
    // Don't call setEnableSpeakerphone here. joinChannel returns
    // before the channel is actually connected; the speaker route
    // isn't ready yet and the SDK will throw -3. The default route
    // we set in init() handles the initial output; runtime toggles
    // go through toggleSpeaker() which only runs after the user has
    // already interacted with an active call.
  }

  // Hand a fresh token to the SDK without leaving the channel.
  // Called from onTokenPrivilegeWillExpire after we've fetched a
  // new token from the Cloud Function.
  Future<void> renewToken(String newToken) async {
    await _engine?.renewToken(newToken);
    debugPrint('[Agora] Token renewed');
  }

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    await _engine?.muteLocalAudioStream(_isMuted);
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    // Wrapped: a fast tap immediately after joinChannel can still
    // hit -3 if the channel hasn't finished negotiating. Swallow
    // the throw — the local boolean is already flipped, the next
    // tap (or the SDK once it's ready) will reconcile.
    try {
      await _engine?.setEnableSpeakerphone(_isSpeakerOn);
    } catch (e) {
      debugPrint('[Agora] setEnableSpeakerphone deferred: $e');
    }
  }

  // Tear down the engine. Called from the cubit's close() AND from
  // any error path before emitting an end state. Idempotent — a
  // double dispose is safe; the second call hits a null engine.
  Future<void> dispose() async {
    _isInitialized = false;
    onUserJoined = null;
    onUserOffline = null;
    onRtcStats = null;
    onTokenExpiring = null;
    onError = null;
    onConnectionStateChanged = null;
    onRemoteSilenceDetected = null;
    onNetworkQuality = null;
    _silentTicks = 0;
    _silenceWarningActive = false;
    _remoteUserPresent = false;
    _qualityByUid.clear();
    _lastEmittedQuality = 0;
    _pendingWorstQuality = null;
    _pendingQualityCount = 0;

    final engine = _engine;
    _engine = null;
    if (engine == null) return;

    try {
      await engine.leaveChannel();
      await engine.release();
    } catch (e) {
      // Best-effort cleanup. The engine may already be in a
      // half-released state if we got here from an error path —
      // logging is enough.
      debugPrint('[Agora] Dispose error (safe to ignore): $e');
    }
  }
}
