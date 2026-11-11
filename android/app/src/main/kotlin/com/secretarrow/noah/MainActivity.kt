package com.secretarrow.noah

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Bridges the Dart agent loop to [NoahForegroundService] so a running
 * agent task survives backgrounding (foreground service + wake lock +
 * progress notification), and posts local "task finished" notifications
 * (v1.18.0) when a run completes while the app is in the background.
 *
 * Every method is defensive: failures resolve to `false` instead of
 * throwing, so a missing service or OEM-specific restriction can never
 * crash the app.
 *
 * FlutterFragmentActivity (not FlutterActivity) is required by the
 * biometric app-lock (local_auth needs a FragmentActivity host).
 */
class MainActivity : FlutterFragmentActivity() {

    private fun channelName(): String = "zagents/background"

    /// Session id from a tapped done-notification, waiting to be drained
    /// by the Dart side ("getPendingSession").
    private var pendingSessionId: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Local AI runtime (llama-server) channel — see
        // LlmServerChannel.kt (registered here so MainActivity stays thin).
        LlmServerChannel(this).register(flutterEngine)
        configureDeviceChannel(flutterEngine)
        pendingSessionId = intent?.getStringExtra(EXTRA_PENDING_SESSION)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName())
            .setMethodCallHandler { call, result ->
                val ok = try {
                    when (call.method) {
                        "start" -> {
                            // Foreground start: always launched from a user
                            // action in the foreground, so it is allowed on
                            // all Android versions. startForegroundService
                            // exists since API 26; below that a plain start
                            // (while the app is in the foreground) is legal.
                            val intent = serviceIntent(
                                NoahForegroundService.ACTION_START,
                                call.argument<String>("title"),
                                call.argument<String>("text"),
                            )
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            true
                        }
                        "update" -> {
                            // startService() (not startForegroundService()):
                            // only valid while the service is already running,
                            // which is exactly when update() is called.
                            startService(
                                serviceIntent(
                                    NoahForegroundService.ACTION_UPDATE,
                                    null,
                                    call.argument<String>("text"),
                                ),
                            )
                            true
                        }
                        "stop" -> {
                            stopService(
                                Intent(this, NoahForegroundService::class.java),
                            )
                            true
                        }
                        "startSession" -> {
                            // v1.42.0: per-chat running notification. The
                            // service is already foreground ("start" ran for
                            // the first session), so a plain startService
                            // delivery is enough. Also asks (once) for the
                            // Android 13+ POST_NOTIFICATIONS permission —
                            // without it every notification is silently
                            // dropped.
                            requestNotificationPermissionIfNeeded()
                            startService(sessionIntent(
                                NoahForegroundService.ACTION_START_SESSION,
                                call.argument<String>("sessionId"),
                                call.argument<String>("title"),
                                call.argument<String>("text"),
                            ))
                            true
                        }
                        "updateSession" -> {
                            startService(sessionIntent(
                                NoahForegroundService.ACTION_UPDATE_SESSION,
                                call.argument<String>("sessionId"),
                                null,
                                call.argument<String>("text"),
                            ))
                            true
                        }
                        "stopSession" -> {
                            startService(sessionIntent(
                                NoahForegroundService.ACTION_STOP_SESSION,
                                call.argument<String>("sessionId"),
                                null,
                                null,
                            ))
                            true
                        }
                        "requestNotificationPermission" -> {
                            requestNotificationPermissionIfNeeded()
                        }
                        "notifyDone" -> {
                            notifyDone(
                                title = call.argument<String>("title") ?: "Noah",
                                text = call.argument<String>("text") ?: "",
                                sessionId = call.argument<String>("sessionId"),
                            )
                        }
                        "getPendingSession" -> {
                            result.success(pendingSessionId)
                            pendingSessionId = null
                            true
                        }
                        "requestIgnoreBatteryOptimization" -> {
                            requestIgnoreBatteryOptimization()
                        }
                        "isIgnoringBatteryOptimizations" -> {
                            result.success(isIgnoringBatteryOptimizations())
                            true
                        }
                        "getSdkInt" -> {
                            result.success(Build.VERSION.SDK_INT)
                            true
                        }
                        "exportChatFolder" -> {
                            // v1.29.0: copy a chat workspace folder into
                            // Download/Noah/<name>/ via MediaStore (no
                            // permission needed on API 29+). Replies with
                            // the exported file count (its own result).
                            @Suppress("UNCHECKED_CAST")
                            val files = call.argument<ArrayList<Map<String, String>>>(
                                "files",
                            ) ?: ArrayList()
                            exportChatFolder(
                                name = call.argument<String>("name") ?: "",
                                files = files,
                                result = result,
                            )
                            true
                        }
                        else -> false
                    }
                } catch (_: Exception) {
                    false
                }
                if (call.method != "getPendingSession" &&
                    call.method != "isIgnoringBatteryOptimizations" &&
                    call.method != "getSdkInt" &&
                    call.method != "exportChatFolder"
                ) {
                    result.success(ok)
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_PENDING_SESSION)?.let {
            pendingSessionId = it
        }
    }

    /**
     * v1.31.0 — native shell runner for chat modules with the `device`
     * permission ("Device commands" master switch is enforced on the Dart
     * side on every call; this channel is intentionally dumb and only ever
     * reached through that gate). Runs ONE command via `sh -c`, or
     * `su -c` when root=true (rooted phones), with a hard time budget and
     * fully drained stdout/stderr (separate threads so a chatty command
     * can never deadlock on the pipe buffer).
     *
     * Always replies with a result map — failures (missing `su`, spawn
     * errors) land in the `error` field instead of an error reply, so the
     * module side can branch on the outcome uniformly.
     */
    private fun configureDeviceChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zagents/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exec" -> result.success(
                        execShell(
                            command = call.argument<String>("command") ?: "",
                            root = call.argument<Boolean>("root") ?: false,
                            timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 30_000L,
                        ),
                    )
                    "getAirplaneMode" -> result.success(isAirplaneModeOn())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * v1.32.0 — reads the airplane-mode state WITHOUT root.
     * `Settings.Global.AIRPLANE_MODE_ON` is a world-readable setting, so
     * this works on every device (rooted or not) and lets the airplane
     * module report the REAL state in manual (non-root) mode, and the
     * auto-retry loop detect an expected offline window. Never throws.
     */
    private fun isAirplaneModeOn(): Boolean = try {
        Settings.Global.getInt(
            contentResolver,
            Settings.Global.AIRPLANE_MODE_ON,
            0,
        ) == 1
    } catch (_: Exception) {
        false
    }

    private fun execShell(command: String, root: Boolean, timeoutMs: Long): Map<String, Any> {
        return try {
            val argv = if (root) listOf("su", "-c", command) else listOf("sh", "-c", command)
            val process = ProcessBuilder(argv).start()
            val stdout = StringBuilder()
            val stderr = StringBuilder()
            val outThread = Thread {
                try {
                    process.inputStream.bufferedReader().use { reader ->
                        reader.forEachLine { line -> stdout.appendLine(line) }
                    }
                } catch (_: Exception) {
                }
            }
            val errThread = Thread {
                try {
                    process.errorStream.bufferedReader().use { reader ->
                        reader.forEachLine { line -> stderr.appendLine(line) }
                    }
                } catch (_: Exception) {
                }
            }
            outThread.start()
            errThread.start()
            val budget = timeoutMs.coerceIn(1_000L, 120_000L)
            val finished = process.waitFor(budget, TimeUnit.MILLISECONDS)
            var timedOut = false
            if (!finished) {
                timedOut = true
                process.destroyForcibly()
            }
            outThread.join(2_000)
            errThread.join(2_000)
            mapOf(
                "exitCode" to (if (finished) process.exitValue() else -1),
                "stdout" to stdout.toString(),
                "stderr" to stderr.toString(),
                "timedOut" to timedOut,
            )
        } catch (e: Exception) {
            mapOf(
                "exitCode" to -1,
                "stdout" to "",
                "stderr" to (e.message ?: e.javaClass.simpleName),
                "timedOut" to false,
                "error" to (e.message ?: "shell failed"),
            )
        }
    }

    private fun notifyDone(title: String, text: String, sessionId: String?): Boolean {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_DONE,
                "Agent task results",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
            manager.createNotificationChannel(channel)
        }
        val openApp = Intent(this, MainActivity::class.java).apply {
            setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_PENDING_SESSION, sessionId)
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            sessionId?.hashCode() ?: 2001,
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder: Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_DONE)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
        val notification: Notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIF_DONE_ID, notification)
        return true
    }

    private fun serviceIntent(action: String, title: String?, text: String?): Intent =
        Intent(this, NoahForegroundService::class.java).apply {
            this.action = action
            putExtra(NoahForegroundService.EXTRA_TITLE, title)
            putExtra(NoahForegroundService.EXTRA_TEXT, text)
        }

    /// v1.42.0: service intent carrying the per-chat session id.
    private fun sessionIntent(action: String, sessionId: String?, title: String?, text: String?): Intent =
        Intent(this, NoahForegroundService::class.java).apply {
            this.action = action
            putExtra(NoahForegroundService.EXTRA_SESSION_ID, sessionId)
            putExtra(NoahForegroundService.EXTRA_TITLE, title)
            putExtra(NoahForegroundService.EXTRA_TEXT, text)
        }

    /// v1.42.0 — asks the user for POST_NOTIFICATIONS on Android 13+ (the
    /// manifest permission alone is not enough there). One-shot and
    /// best-effort: already-granted (or <13) returns true immediately; a
    /// denial simply keeps notifications silent like before. Never throws.
    private fun requestNotificationPermissionIfNeeded(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    2001,
                )
                false
            } else {
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    /// Opens the system "ignore battery optimizations" dialog (v1.28.0).
    /// The REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission is declared in
    /// the manifest; the user still decides — the dialog is dismissible.
    private fun requestIgnoreBatteryOptimization(): Boolean {
        return try {
            val intent = Intent(
                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                android.net.Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Exception) {
            // Some OEM builds ship without the settings activity.
            false
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Exception) {
            false
        }
    }

    /// Copies every given file into `Download/Noah/<name>/<rel>` via
    /// MediaStore (v1.29.0). Own previous export of the SAME folder is
    /// removed first, so re-exporting replaces it instead of piling up
    /// duplicates. Own-app MediaStore contributions need no permission on
    /// API 29+; below 29 the Dart side falls back to zip + share.
    /// Replies with the exported file count, or -1 when nothing exported.
    private fun exportChatFolder(
        name: String,
        files: List<Map<String, String>>,
        result: MethodChannel.Result,
    ): Boolean {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.success(-2) // Dart falls back to zip + share sheet
                return true
            }
            val safeName = name
                .replace(Regex("[^A-Za-z0-9 _().-]"), "_")
                .trim()
                .take(60)
                .ifEmpty { "chat" }
            val baseRel = "Download/Noah/$safeName/"
            val resolver = contentResolver
            val downloads = android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI
            // Replace the previous export of this exact folder (own files).
            try {
                resolver.query(
                    downloads,
                    arrayOf(android.provider.MediaStore.MediaColumns._ID),
                    "${android.provider.MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                    arrayOf("$baseRel%"),
                    null,
                )?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(0)
                        try {
                            resolver.delete(
                                android.content.ContentUris.withAppendedId(downloads, id),
                                null,
                                null,
                            )
                        } catch (_: Exception) {
                            // Someone else's entry or already gone — skip.
                        }
                    }
                }
            } catch (_: Exception) {
                // Query/delete cleanup is best-effort.
            }
            var count = 0
            for (file in files) {
                val rel = (file["rel"] ?: "").replace('\\', '/')
                val abs = file["abs"] ?: ""
                if (rel.isEmpty() || abs.isEmpty()) continue
                if (rel.split('/').any { it == ".." }) continue
                val src = File(abs)
                if (!src.isFile) continue
                val dirPart = if (rel.contains('/')) rel.substringBeforeLast('/') + "/" else ""
                val display = rel.substringAfterLast('/')
                if (display.isEmpty()) continue
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, display)
                    put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, baseRel + dirPart)
                    put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mimeFor(display))
                }
                val outUri = resolver.insert(downloads, values) ?: continue
                try {
                    resolver.openOutputStream(outUri)?.use { os ->
                        src.inputStream().use { it.copyTo(os) }
                    } ?: run {
                        resolver.delete(outUri, null, null)
                        continue
                    }
                    count++
                } catch (_: Exception) {
                    try { resolver.delete(outUri, null, null) } catch (_: Exception) {}
                }
            }
            result.success(count)
            return true
        } catch (e: Exception) {
            result.error("EXPORT_FAILED", e.message ?: "export failed", null)
            return false
        }
    }

    private fun mimeFor(name: String): String = when (
        name.substringAfterLast('.', "").lowercase()
    ) {
        "json" -> "application/json"
        "txt" -> "text/plain"
        "md" -> "text/markdown"
        "csv" -> "text/csv"
        "html" -> "text/html"
        "css" -> "text/css"
        "js" -> "text/javascript"
        "xml" -> "application/xml"
        "svg" -> "image/svg+xml"
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "pdf" -> "application/pdf"
        "zip" -> "application/zip"
        else -> "application/octet-stream"
    }

    companion object {
        private const val CHANNEL_DONE = "zagents_done"
        private const val NOTIF_DONE_ID = 2001
        const val EXTRA_PENDING_SESSION = "pending_session"
    }
}
