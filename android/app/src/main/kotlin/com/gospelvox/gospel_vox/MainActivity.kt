package com.gospelvox.gospel_vox

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Bridges Flutter ⇄ the Android foreground service so the voice
// call cubit can control it without depending on a plugin. The
// channel name is mirrored on the Dart side in
// CallKeepAliveService — keep the two literals in sync if you ever
// rename it.
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.gospelvox.gospel_vox/call_service"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCallService" -> {
                        val intent = Intent(this, CallForegroundService::class.java)
                        intent.action = CallForegroundService.ACTION_START
                        // startForegroundService requires the service
                        // to call startForeground() within ~5 seconds
                        // or the OS throws ANR — CallForegroundService
                        // does it in onStartCommand, so we're safe.
                        startForegroundService(intent)
                        result.success(null)
                    }
                    "stopCallService" -> {
                        val intent = Intent(this, CallForegroundService::class.java)
                        intent.action = CallForegroundService.ACTION_STOP
                        // Use plain startService (not startForegroundService)
                        // for the stop path — we're not promoting the
                        // service, we're telling it to tear down.
                        startService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
