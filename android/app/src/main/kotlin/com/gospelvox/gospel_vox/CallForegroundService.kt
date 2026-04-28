package com.gospelvox.gospel_vox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

// Foreground service that keeps the voice call alive when the user
// backgrounds the app or locks the screen. The persistent
// notification serves two jobs: (1) it tells the OS "this process
// is doing user-visible work, don't kill it", and (2) it gives the
// user a quick way back into the call from anywhere on the device.
//
// Lifecycle:
//   - Started from MainActivity via MethodChannel when the cubit
//     enters startCall (after Agora init succeeds).
//   - Stopped from MainActivity via the same channel when the call
//     ends, or implicitly when the cubit closes.
//
// This is the same pattern WhatsApp / Google Meet / Telegram use.
// We deliberately don't ship a third-party "foreground task" plugin
// because the contract here is two methods (start/stop a notification)
// and pulling in a 500KB plugin for that is silly.
class CallForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "gospel_vox_call_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.gospelvox.START_CALL_SERVICE"
        const val ACTION_STOP = "com.gospelvox.STOP_CALL_SERVICE"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Stop request: tear down the notification and the service.
        // Returning START_NOT_STICKY here so the OS doesn't try to
        // resurrect us on its own — the cubit owns the lifecycle.
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = buildNotification()

        // On Android 10+ a foreground service that captures audio
        // MUST declare the microphone type at startForeground time,
        // matching the manifest declaration. Older OS versions don't
        // accept the typed overload, so we branch.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        // Tapping the notification re-opens the app at whatever
        // route is currently mounted — usually the call screen.
        // FLAG_IMMUTABLE is required on Android 12+.
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Gospel Vox")
            .setContentText("Voice call in progress")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            // Bug #4: PRIORITY_LOW to match the channel's
            // IMPORTANCE_LOW. PRIORITY_HIGH only mattered on
            // Android 7- (channels didn't exist there) and would
            // cause a heads-up call notification on those devices —
            // not what we want for an ongoing-call indicator.
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun createNotificationChannel() {
        // Channels were introduced in Android 8 (API 26). Lower API
        // levels use the legacy notification system, no channel
        // needed.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Voice Calls",
                // LOW priority — no sound or pop-up. The notification
                // is informational only; it doesn't need to interrupt
                // the user.
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when a voice call is active"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
