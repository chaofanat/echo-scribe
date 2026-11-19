package com.example.echo_scribe

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process alive while a recording runs, so mic capture and the
 * streaming recognition (running on the Flutter engine) continue with the
 * app in the background or the screen off:
 *  - a microphone-type foreground service (background mic access requires
 *    this on Android 11+, and it exempts the app from being frozen), plus
 *  - a partial wake lock (the CPU would otherwise sleep with the screen
 *    off and the audio stream would stall).
 *
 * Started/stopped from [MainActivity] when the Dart session starts/stops.
 */
class RecordingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "录音", NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION") Notification.Builder(this)
            }
        val notification = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("EchoScribe 正在录音")
            .setContentText("后台录音与实时转写进行中")
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // e.g. background-start restrictions; without the foreground
            // promotion the service dies with the app, so don't linger.
            stopSelf()
            return START_NOT_STICKY
        }
        if (wakeLock?.isHeld != true) {
            val pm = getSystemService(PowerManager::class.java)
            wakeLock =
                pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "EchoScribe::recording")
                    .apply {
                        setReferenceCounted(false)
                        acquire()
                    }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "recording"
        private const val NOTIFICATION_ID = 1
    }
}
