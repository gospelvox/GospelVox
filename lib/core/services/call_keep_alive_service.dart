// Thin wrapper around the platform-side foreground service that
// keeps a voice call alive when the app is backgrounded. On
// Android, this drives the persistent "Voice call in progress"
// notification (see CallForegroundService.kt). On iOS, the
// equivalent behaviour is handled declaratively by the
// UIBackgroundModes audio + voip keys in Info.plist — no Dart
// code needed there, so the start/stop calls become no-ops.
//
// We deliberately roll a 20-line MethodChannel instead of pulling
// in flutter_foreground_task or similar. The contract is two
// methods (start / stop a notification); a full plugin would add
// hundreds of KB of unused background-task scheduling we'd never
// touch.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CallKeepAliveService {
  // Channel name is mirrored on the Android side in MainActivity.
  // If you rename one, rename the other.
  static const _channel =
      MethodChannel('com.gospelvox.gospel_vox/call_service');

  // Promote the app process to a foreground service. Idempotent —
  // calling start twice in a row is harmless on Android (the second
  // call is absorbed by the existing service).
  static Future<void> start() async {
    if (!Platform.isAndroid) return; // iOS handled by Info.plist
    try {
      await _channel.invokeMethod('startCallService');
    } catch (e) {
      // Non-fatal: the call still works, the OS just might kill the
      // process when backgrounded on aggressive OEMs (Xiaomi/Oppo/
      // Samsung). Log so the failure is visible during dev.
      debugPrint('[CallKeepAlive] start failed: $e');
    }
  }

  // Tear down the foreground service. Safe to call from multiple
  // paths (cubit close, end-call, error recovery) — the platform
  // side ignores duplicate stop requests.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopCallService');
    } catch (e) {
      debugPrint('[CallKeepAlive] stop failed: $e');
    }
  }
}
