package com.gospelvox.gospel_vox

import android.content.Intent
import android.os.Bundle
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
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

    // Flipped to true the instant Flutter renders its first frame. Until
    // then the OS launch splash (beige + app icon, from styles.xml) is
    // held on screen, covering the short window where the Flutter render
    // surface would otherwise paint its default BLACK background while
    // main()'s async bootstrap (Firebase / connectivity / notifications /
    // DI) runs before runApp(). This is the "logo → black → home" gap;
    // holding the splash turns it into a seamless "logo → home".
    private var flutterUiReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must run before super.onCreate() so the splash hooks attach to
        // this Activity's window. setKeepOnScreenCondition suspends the
        // content view's first draw — keeping the splash up — until the
        // first Flutter frame flips the flag below.
        installSplashScreen().setKeepOnScreenCondition { !flutterUiReady }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Release the held splash the moment the first Flutter frame is on
        // screen — a direct hand-off from the OS logo splash to the app's
        // first (beige) frame, with no black gap between. If the engine is
        // already displaying, flip immediately; otherwise wait one-shot.
        val renderer = flutterEngine.renderer
        if (renderer.isDisplayingFlutterUi) {
            flutterUiReady = true
        } else {
            renderer.addIsDisplayingFlutterUiListener(object : FlutterUiDisplayListener {
                override fun onFlutterUiDisplayed() {
                    flutterUiReady = true
                    renderer.removeIsDisplayingFlutterUiListener(this)
                }

                override fun onFlutterUiNoLongerDisplayed() {}
            })
        }

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
