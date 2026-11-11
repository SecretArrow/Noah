package com.secretarrow.noah

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the Flutter process (and therefore the
 * Dart agent loop + headless WebView automation) alive while the user is
 * away from the app.
 *
 * Without this, Android treats the app as a cached process once it leaves
 * the screen and may freeze or kill it within minutes — aborting a running
 * agent task mid-flight. With it, the task keeps running in the background
 * and the user sees a persistent status notification they can trust.
 *
 * Contract (driven from Dart over the "zagents/background" MethodChannel):
 *  - ACTION_START  : create the channel, go foreground, acquire a partial
 *                    wake lock so the CPU keeps working with the screen off.
 *  - ACTION_UPDATE : replace the notification text (current agent step).
 *  - ACTION_STOP   : release everything and stop the service.
 */
class NoahForegroundService : Service() {

    companion object {
        const val ACTION_START = "com.secretarrow.noah.action.START"
        const val ACTION_UPDATE = "com.secretarrow.noah.action.UPDATE"
        const val ACTION_STOP = "com.secretarrow.noah.action.STOP"
        // v1.42.0: per-chat running notifications — one notification per
        // ACTIVE chat, tap opens exactly that conversation.
        const val ACTION_START_SESSION = "com.secretarrow.noah.action.START_SESSION"
        const val ACTION_UPDATE_SESSION = "com.secretarrow.noah.action.UPDATE_SESSION"
        const val ACTION_STOP_SESSION = "com.secretarrow.noah.action.STOP_SESSION"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_SESSION_ID = "sessionId"

        const val CHANNEL_ID = "noah_agent"
        const val NOTIFICATION_ID = 20251012
        // Base for per-session notification ids: distinct from the service
        // notification (20251012) and the done-notification (2001).
        private const val SESSION_NOTIF_BASE = 20251101
        private const val WAKELOCK_TAG = "Noah::agentLoop"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    /// sessionId -> notification id, alive for the service lifetime.
    private val sessionNotifIds = LinkedHashMap<String, Int>()
    private var nextSessionNotifId = SESSION_NOTIF_BASE

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                cancelAllSessionNotifications()
                stopForegroundService()
                return START_NOT_STICKY
            }
            ACTION_START_SESSION, ACTION_UPDATE_SESSION -> {
                // Per-chat running notification (v1.42.0). The service is
                // already foreground at this point (ACTION_START ran for the
                // first session), so a plain notify() is enough — no
                // startForegroundService round-trip needed.
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
                if (!sessionId.isNullOrEmpty()) {
                    val title = intent.getStringExtra(EXTRA_TITLE)
                        ?: getString(R.string.app_name)
                    val text = intent.getStringExtra(EXTRA_TEXT) ?: ""
                    upsertSessionNotification(sessionId, title, text)
                    // Every progress step re-arms the wake lock, same as the
                    // aggregate ACTION_UPDATE path.
                    acquireWakeLock()
                }
            }
            ACTION_STOP_SESSION -> {
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
                if (!sessionId.isNullOrEmpty()) {
                    cancelSessionNotification(sessionId)
                }
            }
            ACTION_UPDATE -> {
                val text = intent.getStringExtra(EXTRA_TEXT) ?: ""
                if (text.isNotEmpty()) {
                    notification(text).let {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            startForeground(
                                NOTIFICATION_ID,
                                it,
                                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                            )
                        } else {
                            startForeground(NOTIFICATION_ID, it)
                        }
                    }
                }
                // Reliability (v1.28.0): every progress step re-arms the
                // wake lock. With a non-reference-counted lock this simply
                // refreshes the timeout — so very long "run until done"
                // sessions (and OEM power managers that silently drop
                // locks) never leave the CPU asleep mid-run.
                acquireWakeLock()
            }
            else -> {
                // ACTION_START (also the default when the intent is null).
                val title = intent?.getStringExtra(EXTRA_TITLE)
                    ?: getString(R.string.app_name)
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
                val notif = notification(title, text)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notif,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notif)
                }
                acquireWakeLock()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        cancelAllSessionNotifications()
        releaseWakeLock()
        super.onDestroy()
    }

    /// v1.42.0: posts (or refreshes) the running notification of ONE active
    /// chat. The tap intent carries the session id through the existing
    /// pending-session deep link (MainActivity.onNewIntent →
    /// LockGate._openPendingSession), so tapping opens exactly that chat.
    private fun upsertSessionNotification(sessionId: String, title: String, text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.app_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) },
            )
        }
        val notifId = sessionNotifIds[sessionId]
            ?: nextSessionNotifId++.also { sessionNotifIds[sessionId] = it }
        // Tapping the notification reopens THIS chat (not just the app).
        val openChat = Intent(this, MainActivity::class.java).apply {
            setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(MainActivity.EXTRA_PENDING_SESSION, sessionId)
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            notifId, // unique per session slot — no PendingIntent collisions.
            openChat,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        try {
            manager.notify(notifId, notification)
        } catch (_: Exception) {
            // POST_NOTIFICATIONS denied (API 33+): notifications are simply
            // not shown; the run itself is unaffected.
        }
    }

    private fun cancelSessionNotification(sessionId: String) {
        val notifId = sessionNotifIds.remove(sessionId) ?: return
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(notifId)
        } catch (_: Exception) {
        }
    }

    private fun cancelAllSessionNotifications() {
        if (sessionNotifIds.isEmpty()) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for (notifId in sessionNotifIds.values) {
            try {
                manager.cancel(notifId)
            } catch (_: Exception) {
            }
        }
        sessionNotifIds.clear()
    }

    private fun notification(title: String, text: String = ""): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.app_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) },
            )
        }

        // Tapping the notification brings the app back to the foreground.
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
            setReferenceCounted(false)
            // Safety valve: if Dart ever fails to stop the service (crash,
            // process kill), the CPU is not held forever. Real agent runs
            // finish in minutes; 2 hours is a generous upper bound.
            acquire(2 * 60 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        } finally {
            wakeLock = null
        }
    }

    private fun stopForegroundService() {
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }
}
