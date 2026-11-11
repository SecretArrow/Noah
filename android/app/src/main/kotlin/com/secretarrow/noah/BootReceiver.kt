/*
 * BootReceiver.kt — opt-in boot start of the Local AI server (v1.52.0).
 *
 * Manifest-registered receiver for BOOT_COMPLETED (contract §5,
 * lib/services/local_ai/README.md). When the user opted in with
 * `autoStartOnBoot`, the llama-server runtime exists and the most
 * recently used installed model is still on disk, it starts
 * LlmServerService (ACTION_START) with the stored server config — so the
 * server is already up before the user even opens the app.
 *
 * Design notes:
 *  - WHY reading the store in Kotlin: the receiver runs in a fresh app
 *    process BEFORE any Flutter engine exists — the Dart side cannot
 *    participate. The shared_preferences plugin persists into the
 *    `FlutterSharedPreferences` file with a `flutter.` key prefix, so
 *    the Dart key `noah.localai.v1` is simply
 *    `flutter.noah.localai.v1` there — read directly with
 *    getSharedPreferences + org.json (built into Android, no deps).
 *  - WHY never crash: a crashing boot receiver is recorded as an app
 *    crash by the system (and some OEMs then defer the next boot start).
 *    Every step is defensive: corrupt JSON, missing keys, vanished model
 *    files, unavailable external storage — everything resolves to a
 *    silent no-op; the server can always be started from the app.
 *  - WHY the notification fallback: Android 15 (targetSdk 35) refuses
 *    dataSync foreground-service starts from BOOT_COMPLETED, and several
 *    OEMs have their own background-start rules. When the start throws,
 *    a simple tap-to-start notification is posted instead — it just
 *    launches the app, where the Start button lives. If even that fails
 *    (e.g. POST_NOTIFICATIONS denied on 13+): no-op.
 *  - WHY exported="false" in the manifest: BOOT_COMPLETED is a protected
 *    broadcast — only the system may send it, so a non-exported receiver
 *    still receives it and no other app can ever spoof a boot start.
 */
package com.secretarrow.noah

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * v1.52.0 — opt-in boot start of the Local AI server (see the file header
 * for the design rationale). Fully defensive: any failure anywhere is a
 * silent no-op — boot must never crash.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        // Outer guard: a boot receiver must NEVER crash (file header).
        try {
            if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
            val appContext = context.applicationContext

            // 1. Stored state — corrupt/absent → silent no-op.
            val state = readPrefsState(appContext) ?: return

            // 2. The opt-in gate (contract §5) — default false.
            if (!state.optBoolean(KEY_AUTO_START, false)) return

            // 3. The runtime must exist (armeabi-v7a ships without it) —
            //    the same file the channel's runtimeAvailable checks.
            if (!File(
                    appContext.applicationInfo.nativeLibraryDir,
                    LlmServerService.RUNTIME_FILE,
                ).isFile
            ) return

            // 4. The model to boot with: most recently used, else first.
            val entry = pickModel(state.optJSONArray(KEY_INSTALLED)) ?: return
            val fileName = entry.optString(KEY_FILE_NAME, "")
            // Path-traversal guard: fileName comes from our own store, but
            // a corrupt/hand-edited blob must never start a server on an
            // arbitrary path outside local_models.
            if (fileName.isEmpty() || fileName.contains('/') ||
                fileName.contains('\\') || fileName.contains("..")
            ) return
            val modelsRoot = appContext.getExternalFilesDir(null) ?: return
            val modelFile = File(File(modelsRoot, MODELS_DIR), fileName)
            if (!modelFile.isFile) return

            // 5. Server config with the contract defaults for absent or
            //    invalid values (mirrors LocalModelState, §2.1). The
            //    service re-validates everything in handleStart — the
            //    receiver only pre-filters.
            val port = state.optInt(KEY_SERVER_PORT, DEFAULT_PORT)
                .let { if (it in 1..65535) it else DEFAULT_PORT }
            val contextSize = state.optInt(KEY_CONTEXT_SIZE, DEFAULT_CONTEXT_SIZE)
                .let { if (it > 0) it else DEFAULT_CONTEXT_SIZE }
            val threads = state.optInt(KEY_THREADS, 0).coerceAtLeast(0) // 0 = auto
            val alias = entry.optString(KEY_NAME, "")

            // 6. Start the foreground service.
            val startIntent = Intent(appContext, LlmServerService::class.java).apply {
                action = LlmServerService.ACTION_START
                putExtra(LlmServerService.EXTRA_MODEL_PATH, modelFile.absolutePath)
                putExtra(LlmServerService.EXTRA_ALIAS, alias)
                putExtra(LlmServerService.EXTRA_PORT, port)
                putExtra(LlmServerService.EXTRA_CONTEXT_SIZE, contextSize)
                putExtra(LlmServerService.EXTRA_THREADS, threads)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appContext.startForegroundService(startIntent)
                } else {
                    appContext.startService(startIntent)
                }
            } catch (_: Exception) {
                // Android 15+ blocks dataSync FGS from BOOT_COMPLETED; OEM
                // background-start rules bite here too. Fall back to a
                // tap-to-start notification; if even that fails: no-op.
                postFallbackNotification(appContext)
            }
        } catch (_: Exception) {
            // Anything unexpected — silent no-op, boot must never crash.
        }
    }

    /// Reads the Local AI state JSON from the Flutter SharedPreferences
    /// store. The plugin persists into the `FlutterSharedPreferences`
    /// file with every key prefixed `flutter.` (contract §5), so the Dart
    /// key `noah.localai.v1` lives at `flutter.noah.localai.v1`.
    /// Returns null on anything missing or corrupt — the caller treats
    /// that as "not starting".
    private fun readPrefsState(appContext: Context): JSONObject? = try {
        val raw = appContext
            .getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            .getString(PREFS_KEY, null)
        if (raw.isNullOrBlank()) null else JSONObject(raw)
    } catch (_: Exception) {
        // Corrupt JSON (org.json throws) or storage failure → no-op.
        null
    }

    /// Picks the installed entry to boot with: the one with the highest
    /// `lastUsedAtMs` (contract §5). When NO entry carries a lastUsedAtMs
    /// at all, the first valid entry is the fallback. Returns null when
    /// the list is empty/fully corrupt. Rows that are not JSON objects
    /// are skipped — tolerant, like the Dart fromJson.
    private fun pickModel(installed: JSONArray?): JSONObject? {
        if (installed == null || installed.length() == 0) return null
        var best: JSONObject? = null
        var bestUsed = -1L
        var first: JSONObject? = null
        for (i in 0 until installed.length()) {
            val entry = installed.optJSONObject(i) ?: continue
            if (first == null) first = entry
            // JSON null / absent / non-numeric → -1: never beats a real
            // timestamp, and an all--1 list falls back to `first`.
            val used = if (entry.isNull(KEY_LAST_USED)) {
                -1L
            } else {
                entry.optLong(KEY_LAST_USED, -1L)
            }
            if (used > bestUsed) {
                bestUsed = used
                best = entry
            }
        }
        return best ?: first
    }

    /// Fallback when the service start was refused (Android 15+ blocks
    /// dataSync FGS from BOOT_COMPLETED; OEMs have their own rules): a
    /// simple notification that launches the app — the Start button
    /// lives there. POST_NOTIFICATIONS may be denied on 13+ (then this
    /// is silently dropped, which is the final no-op). Never throws.
    private fun postFallbackNotification(appContext: Context) {
        try {
            val manager =
                appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Local AI",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply { setShowBadge(false) },
                )
            }
            val contentIntent = PendingIntent.getActivity(
                appContext,
                NOTIFICATION_ID, // unique request code — no PendingIntent collisions
                appContext.packageManager.getLaunchIntentForPackage(appContext.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(appContext, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(appContext)
            }
            manager.notify(
                NOTIFICATION_ID,
                builder
                    .setContentTitle(appContext.getString(R.string.app_name))
                    .setContentText("Tap to start the Local AI server")
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentIntent(contentIntent)
                    .setAutoCancel(true)
                    .build(),
            )
        } catch (_: Exception) {
            // Notification manager missing / permission denied: no-op.
        }
    }

    companion object {
        /// shared_preferences on Android: file `FlutterSharedPreferences`,
        /// every key prefixed `flutter.` — the Dart key `noah.localai.v1`
        /// (contract §2.2) is stored as `flutter.noah.localai.v1`.
        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val PREFS_KEY = "flutter.noah.localai.v1"

        /// JSON field names of the persisted LocalModelState (§2.1/§2.2).
        private const val KEY_INSTALLED = "installed"
        private const val KEY_AUTO_START = "autoStartOnBoot"
        private const val KEY_SERVER_PORT = "serverPort"
        private const val KEY_CONTEXT_SIZE = "contextSize"
        private const val KEY_THREADS = "threads"
        private const val KEY_FILE_NAME = "fileName"
        private const val KEY_NAME = "name"
        private const val KEY_LAST_USED = "lastUsedAtMs"

        /// Mirror of the Dart LocalModelState defaults (§2.1) for
        /// absent/invalid stored values.
        private const val DEFAULT_PORT = 11434
        private const val DEFAULT_CONTEXT_SIZE = 2048

        /// Where the Dart downloader puts models (§2.2): subfolder of
        /// getExternalFilesDir(null) — the same path as Flutter's
        /// getExternalStorageDirectory(), so the receiver finds exactly
        /// the files the downloader wrote.
        private const val MODELS_DIR = "local_models"

        /// Distinct from every other notification id in the app on
        /// purpose (agent 20251012, sessions 20251101+, done 2001, llm
        /// server 20251107): canceling one must never hit another.
        private const val NOTIFICATION_ID = 20251108
        private const val CHANNEL_ID = "noah_llm_boot"
    }
}
