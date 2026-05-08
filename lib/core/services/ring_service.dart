// Manages ringtone playback for incoming session requests and the
// outgoing call-waiting tone.
//
// Two distinct assets, two distinct moods:
//
//   incoming_ring.mp3  — the priest-side ringtone (full volume, looped,
//                        with a heavy-haptic vibration pulse). This is
//                        the user-supplied custom ringtone — keep it
//                        as MP3 because audioplayers' Android backend
//                        uses MediaPlayer which decodes it natively.
//
//   outgoing_ring.wav  — the user-side dial tone (0.6 volume, looped,
//                        no vibration). Generated WAV (16-bit PCM,
//                        44.1 kHz mono) so playback is bullet-proof
//                        across every Android decoder pipeline.
//
// Why audioplayers and not just_audio:
//
//   On Android, just_audio uses ExoPlayer's MP3Extractor sniff
//   routine, which rejected the user's 48 kHz/256 kbps MP3 with
//   UnrecognizedInputFormatException on a Samsung A05M (despite
//   the file being structurally valid). The same MP3 plays
//   cleanly through Android's system MediaPlayer, which is what
//   audioplayers uses by default. Switching libraries was simpler
//   than re-encoding the file — and lets the priest keep their
//   custom ringtone exactly as recorded.
//
//   The original concern about audioplayers and Agora's audio
//   session doesn't actually bite here: the ring is always
//   stopped before Agora joins a channel, and audioplayers'
//   default category on iOS is `playback` which is appropriate
//   for a ringtone.
//
// Each tone gets its own AudioPlayer instance — sharing one
// player would leave "is it currently playing?" state ambiguous
// if the priest accepts a call mid-ring.
//
// Every public method is fire-and-forget with try-catch — a
// missing or malformed asset must never crash the app.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// audioplayers' AssetSource paths are RELATIVE to the assets
// folder — no leading "assets/". The actual files live at
// assets/audio/{...} on disk and are declared in pubspec.yaml.
const String _kIncomingAsset = 'audio/incoming_ring.mp3';
const String _kOutgoingAsset = 'audio/outgoing_ring.wav';

// ── Audio routing profiles ────────────────────────────────────
//
// Each tone declares its own AudioContext so the OS classifies it
// correctly. Without this, audioplayers' default profile is "media"
// — which means the volume rocker controls the music slider, silent
// mode does not silence the ring, and Do Not Disturb does not
// suppress it. None of those are what a calling app wants on the
// callee side.
//
// INCOMING (priest side) — alert/ringer profile.
//   Android: contentType=sonification + usageType=notificationRingtone
//   routes the audio to STREAM_RING. The volume rocker now adjusts
//   the ringer slider, silent/vibrate mode silences playback (the
//   vibration loop still runs because it goes through the vibrator
//   API directly), and DND suppresses it for everyone outside the
//   user's bypass list. gainTransientMayDuck lets background music
//   duck under the ring without being killed outright.
//   iOS: category=playback with duckOthers — same intent (other
//   audio ducks). iOS rings always play through the silent switch
//   in playback mode; matching FaceTime's behaviour is acceptable
//   here since this is a paid-session alert, not a casual ping.
final AudioContext _kIncomingContext = AudioContext(
  android: AudioContextAndroid(
    contentType: AndroidContentType.sonification,
    usageType: AndroidUsageType.notificationRingtone,
    audioFocus: AndroidAudioFocus.gainTransientMayDuck,
  ),
  iOS: AudioContextIOS(
    category: AVAudioSessionCategory.playback,
    options: const {AVAudioSessionOptions.duckOthers},
  ),
);

// OUTGOING (user side) — media profile.
//   Android: music + media routes to STREAM_MUSIC, which is
//   exactly right: the dial tone is feedback for the caller, not a
//   ringer event. The caller's volume rocker controls media volume
//   while waiting, which matches every other "calling…" UI.
//   iOS: plain playback category, no duckOthers — the dial tone
//   is intentionally subtle (0.6 volume) and ducking other audio
//   for it would be over-aggressive.
final AudioContext _kOutgoingContext = AudioContext(
  android: AudioContextAndroid(
    contentType: AndroidContentType.music,
    usageType: AndroidUsageType.media,
    audioFocus: AndroidAudioFocus.gainTransientMayDuck,
  ),
  iOS: AudioContextIOS(
    category: AVAudioSessionCategory.playback,
  ),
);

class RingService {
  static final RingService _instance = RingService._();
  factory RingService() => _instance;
  RingService._();

  AudioPlayer? _incomingPlayer;
  AudioPlayer? _outgoingPlayer;
  bool _isIncomingPlaying = false;
  bool _isOutgoingPlaying = false;
  Timer? _vibrationTimer;

  // ── INCOMING RING (priest side) ──
  // Loops until explicitly stopped. A 1.5 s heavy-haptic pulse runs
  // alongside so the priest still gets a "phone is ringing" cue
  // even on silent mode where the audio output is muted.
  //
  // The _isIncomingPlaying flag is flipped to true *before* the
  // awaits intentionally. The session listeners can re-fire on
  // every countdown tick, so without this guard a second call
  // sneaks in during the ~100 ms of setup and disposes the
  // in-flight player from the first call.
  Future<void> startIncomingRing() async {
    if (_isIncomingPlaying) return;
    _isIncomingPlaying = true;
    try {
      await _incomingPlayer?.dispose();
      _incomingPlayer = AudioPlayer();

      // Audio context must be applied BEFORE play() so the player
      // is created with the right AudioAttributes/AVAudioSession
      // category from the first frame — switching mid-stream would
      // route the first ~0.5 s of audio to the wrong stream.
      await _incomingPlayer!.setAudioContext(_kIncomingContext);
      await _incomingPlayer!.setReleaseMode(ReleaseMode.loop);
      await _incomingPlayer!.setVolume(1.0);
      await _incomingPlayer!.play(AssetSource(_kIncomingAsset));

      _startVibrationLoop();

      debugPrint('[Ring] Incoming ring started');
    } catch (e, st) {
      debugPrint('[Ring] Failed to play incoming ring: $e');
      debugPrint('[Ring] stack: $st');
      _isIncomingPlaying = false;
      _stopVibrationLoop();
    }
  }

  Future<void> stopIncomingRing() async {
    if (!_isIncomingPlaying) return;
    _isIncomingPlaying = false;
    _stopVibrationLoop();
    try {
      await _incomingPlayer?.stop();
      await _incomingPlayer?.dispose();
      _incomingPlayer = null;
      debugPrint('[Ring] Incoming ring stopped');
    } catch (e) {
      debugPrint('[Ring] Error stopping incoming ring: $e');
    }
  }

  // ── OUTGOING RING (user side) ──
  // Classic PSTN waiting tone at 0.6 volume so it reads as a soft
  // "calling…" cue rather than a sharp ringer. No vibration loop —
  // the user chose to start this, no need to jolt them.
  Future<void> startOutgoingRing() async {
    if (_isOutgoingPlaying) return;
    _isOutgoingPlaying = true;
    try {
      await _outgoingPlayer?.dispose();
      _outgoingPlayer = AudioPlayer();

      // Apply the media-stream profile before play(); see the
      // matching comment in startIncomingRing for the rationale.
      await _outgoingPlayer!.setAudioContext(_kOutgoingContext);
      await _outgoingPlayer!.setReleaseMode(ReleaseMode.loop);
      await _outgoingPlayer!.setVolume(0.6);
      await _outgoingPlayer!.play(AssetSource(_kOutgoingAsset));

      debugPrint('[Ring] Outgoing ring started');
    } catch (e, st) {
      debugPrint('[Ring] Failed to play outgoing ring: $e');
      debugPrint('[Ring] stack: $st');
      _isOutgoingPlaying = false;
    }
  }

  Future<void> stopOutgoingRing() async {
    if (!_isOutgoingPlaying) return;
    _isOutgoingPlaying = false;
    try {
      await _outgoingPlayer?.stop();
      await _outgoingPlayer?.dispose();
      _outgoingPlayer = null;
      debugPrint('[Ring] Outgoing ring stopped');
    } catch (e) {
      debugPrint('[Ring] Error stopping outgoing ring: $e');
    }
  }

  // Safety net — used on sign-out and any unexpected teardown.
  // Idempotent: each stopper short-circuits on a quiet player.
  Future<void> stopAll() async {
    await stopIncomingRing();
    await stopOutgoingRing();
  }

  // HapticFeedback.heavyImpact is one short buzz, not a sustained
  // vibration. Pulsing it on a 1.5 s timer is what gives the page a
  // phone-ringer cadence. Cancelled in lockstep with the audio.
  void _startVibrationLoop() {
    _vibrationTimer?.cancel();
    HapticFeedback.heavyImpact();
    _vibrationTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) {
        if (_isIncomingPlaying) {
          HapticFeedback.heavyImpact();
        } else {
          _stopVibrationLoop();
        }
      },
    );
  }

  void _stopVibrationLoop() {
    _vibrationTimer?.cancel();
    _vibrationTimer = null;
  }
}
