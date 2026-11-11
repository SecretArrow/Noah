/*
 * LlmServerService.kt — Local AI runtime host (v1.51.0; battery guard
 * added in v1.52.0).
 *
 * Dedicated foreground service that runs the bundled llama.cpp
 * `llama-server` binary as a child process and exposes it to Dart through
 * the `noah/llmserver` MethodChannel (see LlmServerChannel.kt; frozen
 * contract: lib/services/local_ai/README.md §1).
 *
 * Design notes:
 *  - WHY nativeLibraryDir: the runtime ships inside the APK as
 *    `android/app/src/main/jniLibs/<abi>/libllamaserver.so` (built per-ABI
 *    by CI, never committed). Android's installer extracts native libs of
 *    that shape into the app's `nativeLibraryDir` and marks them
 *    executable — the only app-accessible location that is both writable
 *    and not mounted noexec. Assets or internal storage would need a copy
 *    step onto a noexec mount, so the process is launched straight from
 *    `nativeLibraryDir`.
 *  - WHY foregroundServiceType="dataSync": Android has no foreground
 *    service type for "local inference server". dataSync is the general
 *    long-running data-processing type, its permission
 *    (FOREGROUND_SERVICE_DATA_SYNC) is already declared, and the agent
 *    loop service already uses it — no new permissions, no new battery
 *    exceptions.
 *  - WHY a dedicated service (not NoahForegroundService): different
 *    owner (Local AI screen vs the agent loop), different lifetime (a
 *    server runs until the user stops it), its own notification channel
 *    and notification id — stopping one must never tear down the other.
 *  - WHERE the state lives: the process handle and the log ring buffer
 *    live in the process-wide `LlmServerProcessHolder` singleton (bottom
 *    of this file), not in the Service instance — the system can destroy
 *    and recreate Service objects while the app process keeps running,
 *    and the Flutter engine can detach while the service keeps the
 *    process alive. The service below is a thin lifecycle shell around
 *    that holder.
 *  - BATTERY GUARD (v1.52.0, contract §5): while a live child is hosted
 *    the service arms a RUNTIME receiver for ACTION_BATTERY_LOW — never
 *    the manifest, so it exists only while a server actually runs and a
 *    device that never starts one is never woken for it. On critical
 *    battery the child + service are torn down through the very same
 *    shutdown() path as ACTION_STOP: llama-server inference is heavy,
 *    the remaining battery belongs to calls and messages. Registered
 *    only once a live process is confirmed, released on every teardown
 *    path, never registered twice.
 */
package com.secretarrow.noah

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * v1.51.0 — foreground service hosting the bundled llama.cpp llama-server
 * binary (see the file header for the design rationale).
 *
 * Driven only through intents (never bound):
 *  - ACTION_START (extras: modelPath, alias, port, contextSize, threads,
 *    extraArgs) → go foreground, acquire the wake lock, spawn the child.
 *  - ACTION_STOP → destroy the child, release everything, stop the
 *    service. Idempotent.
 *  - ACTION_BATTERY_LOW (runtime receiver, v1.52.0) → the same teardown
 *    as ACTION_STOP while a live child is hosted (battery guard, §5).
 *
 * Returns START_NOT_STICKY on purpose: if the OS kills the app process the
 * child dies with it, and only the Dart side knows how to restart a run
 * with the right model — a blind system auto-restart would be wrong.
 */
class LlmServerService : Service() {

    companion object {
        const val ACTION_START = "com.secretarrow.noah.llmserver.action.START"
        const val ACTION_STOP = "com.secretarrow.noah.llmserver.action.STOP"
        const val EXTRA_MODEL_PATH = "modelPath"
        const val EXTRA_ALIAS = "alias"
        const val EXTRA_PORT = "port"
        const val EXTRA_CONTEXT_SIZE = "contextSize"
        const val EXTRA_THREADS = "threads"
        const val EXTRA_EXTRA_ARGS = "extraArgs"

        /// The llama-server runtime file name inside nativeLibraryDir.
        const val RUNTIME_FILE = "libllamaserver.so"

        const val CHANNEL_ID = "noah_llm_server"

        /// Distinct from every other notification id in the app on purpose:
        /// the agent foreground service (20251012), per-chat session
        /// notifications (20251101+) and done-notifications (2001) must
        /// never collide with — or cancel — the Local AI server
        /// notification (and vice versa).
        const val NOTIFICATION_ID = 20251107

        private const val WAKELOCK_TAG = "Noah::llmServer"

        /// Safety valve only (a real server run is stopped by the user):
        /// if Dart ever disappears without calling stopServer (app crash,
        /// process kill), the OS reclaims the CPU after 6 h instead of
        /// draining the battery indefinitely.
        private const val WAKELOCK_TIMEOUT_MS = 6 * 60 * 60 * 1000L // 6 h

        /// Fallbacks for malformed/absent intent extras. The Dart side
        /// validates everything before starting, so these only matter for
        /// a stale or hand-crafted redelivered intent — they mirror the
        /// LocalModelState defaults (port 11434, context 2048).
        private const val DEFAULT_PORT = 11434
        private const val DEFAULT_CONTEXT_SIZE = 2048
    }

    private var wakeLock: PowerManager.WakeLock? = null

    /// v1.52.0 battery guard: the runtime ACTION_BATTERY_LOW receiver
    /// while a live child is hosted by THIS service instance, null
    /// otherwise (see [registerBatteryGuard] / [unregisterBatteryGuard]).
    private var batteryLowReceiver: BroadcastReceiver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> shutdown()
            ACTION_START -> handleStart(intent)
            else -> {
                // Unknown action or a null redelivered intent — cannot
                // happen with START_NOT_STICKY, but stay defensive: never
                // leave the service foreground without a purpose.
                shutdown()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // The service object going away must never orphan the child
        // process — llama-server dies with its host service.
        shutdown()
        super.onDestroy()
    }

    /// ACTION_START. Order matters:
    ///  1. go foreground immediately — startForegroundService gives the
    ///     service ~5 s to call startForeground, before any work;
    ///  2. hold a partial wake lock — inference must survive the screen
    ///     going off;
    ///  3. double-guard the runtime binary and the model file (Dart
    ///     checked `runtimeAvailable` before sending the intent, but the
    ///     state can change in between; on failure latch the reason where
    ///     `getLogs` can read it and stop cleanly);
    ///  4. spawn via the holder — its start() is synchronized, so even a
    ///     rapid double-start can never produce two llama-server
    ///     processes. The spawn itself (fork+exec) runs inline like the
    ///     rest of this code base: it is milliseconds — model loading
    ///     happens inside the child and is logged asynchronously by the
    ///     reader thread.
    private fun handleStart(intent: Intent) {
        try {
            val modelPath = intent.getStringExtra(EXTRA_MODEL_PATH) ?: ""
            val alias = intent.getStringExtra(EXTRA_ALIAS) ?: ""
            val port = intent.getIntExtra(EXTRA_PORT, 0)
                .let { if (it in 1..65535) it else DEFAULT_PORT }
            val contextSize = intent.getIntExtra(EXTRA_CONTEXT_SIZE, 0)
                .let { if (it > 0) it else DEFAULT_CONTEXT_SIZE }
            // Contract §1: threads <= 0 → auto = half the cores, min 1.
            val threads = intent.getIntExtra(EXTRA_THREADS, 0).let {
                if (it > 0) it else maxOf(1, Runtime.getRuntime().availableProcessors() / 2)
            }
            val extraArgs = (intent.getStringArrayListExtra(EXTRA_EXTRA_ARGS) ?: ArrayList())
                .filter { it.isNotBlank() }

            goForeground(
                if (alias.isEmpty()) "Local AI server running"
                else "Local AI server - $alias",
            )
            acquireWakeLock()

            val binary = File(applicationInfo.nativeLibraryDir, RUNTIME_FILE)
            if (!binary.isFile) {
                // Torn state (Dart checked availability first): latch the
                // reason instead of spawning nothing silently.
                LlmServerProcessHolder.fail(
                    "[noah] llama-server runtime missing from nativeLibraryDir",
                )
                shutdown()
                return
            }
            if (modelPath.isEmpty() || !File(modelPath).isFile) {
                LlmServerProcessHolder.fail("[noah] model file not found: $modelPath")
                shutdown()
                return
            }
            if (LlmServerProcessHolder.isRunning()) {
                // Duplicate start while a server is already alive: keep the
                // service + existing process, never spawn a second one.
                return
            }
            val started = LlmServerProcessHolder.start(
                binary.absolutePath,
                listOf(
                    "-m", modelPath,
                    "--host", "127.0.0.1",
                    "--port", port.toString(),
                    "--alias", alias,
                    "-c", contextSize.toString(),
                    "-t", threads.toString(),
                ) + extraArgs,
            )
            if (!started && !LlmServerProcessHolder.isRunning()) {
                // The spawn itself failed — the holder latched exitCode -1
                // plus the reason into the log. Nothing to host: stop
                // cleanly. (When a racing start won, isRunning() is true
                // and the service simply keeps serving that process.)
                shutdown()
            } else {
                // v1.52.0 (contract §5): a live child is now hosted by THIS
                // service instance — either we spawned it just now or a
                // racing start won — arm the battery guard. Idempotent, so
                // a service object recreated by the system re-arms it
                // exactly once; see registerBatteryGuard().
                registerBatteryGuard()
            }
        } catch (e: Exception) {
            LlmServerProcessHolder.fail(
                "[noah] failed to start llama-server: " +
                    (e.message ?: e.javaClass.simpleName),
            )
            shutdown()
        }
    }

    /// Creates the dedicated `noah_llm_server` channel (IMPORTANCE_LOW:
    /// a running local server is a background fact, not an alert — and
    /// distinct from the agent loop's `noah_agent` channel so users can
    /// configure both independently) and promotes the service to
    /// foreground with its own notification id.
    private fun goForeground(text: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Local AI server",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) },
            )
        }
        val notif = notification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // dataSync matches the manifest declaration (file header).
            startForeground(
                NOTIFICATION_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notif)
        }
    }

    private fun notification(text: String): Notification {
        // Tapping the notification brings the app back to the foreground.
        val contentIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID, // unique request code — no PendingIntent collisions
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
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    /// PARTIAL wake lock so inference keeps working with the screen off.
    /// Acquired once on start, released on stop/destroy — no re-arm
    /// pattern here (a server is meant to run until the user stops it,
    /// unlike the step-by-step agent loop). The 6-hour timeout is a
    /// safety valve, mirroring Android 14+'s own dataSync time cap.
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        wakeLock = try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
                setReferenceCounted(false)
                acquire(WAKELOCK_TIMEOUT_MS)
            }
        } catch (_: Exception) {
            // e.g. too many wake locks on some OEM builds: the server keeps
            // running without the lock.
            null
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

    /// v1.52.0 (contract §5) — arms the ACTION_BATTERY_LOW guard while a
    /// live child is hosted. Runtime-registered on purpose (never in the
    /// manifest): the receiver must only exist while a server actually
    /// runs, so a phone that never starts the Local AI server is never
    /// woken by battery broadcasts for it. On critical battery the child
    /// + service are torn down via the shared shutdown() path. Guarded
    /// against double registration (handleStart can run again after the
    /// system recreated the service object) and null-safe; a failed
    /// registration never breaks the server start.
    private fun registerBatteryGuard() {
        if (batteryLowReceiver != null) return
        // BroadcastReceiver is an abstract class (no SAM constructor) —
        // a plain anonymous object with the onReceive override is the
        // only correct form.
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                try {
                    // Diagnosability: the Dart UI polls getLogs — leave the
                    // reason as the last line, mirroring fail()'s philosophy.
                    LlmServerProcessHolder.appendLog(
                        "[noah] battery low - stopping Local AI server",
                    )
                } catch (_: Exception) {
                    // appendLog is synchronized and cannot really throw; if
                    // it ever does, the stop below still happens.
                }
                // Same full teardown as ACTION_STOP. Delivered on the main
                // thread like onStartCommand, so it can never race a
                // start/stop delivery.
                shutdown()
            }
        }
        try {
            val filter = IntentFilter(Intent.ACTION_BATTERY_LOW)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // API 33+: flag the receiver explicitly. NOT_EXPORTED: only
                // this app and the system may deliver to it — the system
                // still delivers protected broadcasts such as BATTERY_LOW,
                // and no other app can ever spoof a critical-battery stop.
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
            batteryLowReceiver = receiver
        } catch (_: Exception) {
            // Practically unreachable (system broadcast, main thread); if
            // it ever fires the server simply runs without the guard.
            batteryLowReceiver = null
        }
    }

    /// Disarms the battery guard. Idempotent and null-safe; called from
    /// shutdown() FIRST so no battery broadcast can arrive mid-teardown
    /// and an orphaned runtime receiver can never outlive the service
    /// component it belongs to.
    private fun unregisterBatteryGuard() {
        val receiver = batteryLowReceiver ?: return
        batteryLowReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (_: Exception) {
            // Already unregistered (double teardown) or the system already
            // dropped it — nothing left to do.
        }
    }

    /// Full teardown, shared by ACTION_STOP, onDestroy and the battery
    /// guard: kill the child (idempotent), drop the wake lock, remove the
    /// notification, stop the service.
    private fun shutdown() {
        // v1.52.0: drop the battery guard before anything else — no
        // battery broadcast may arrive mid-teardown (see
        // unregisterBatteryGuard).
        unregisterBatteryGuard()
        LlmServerProcessHolder.stopProcess()
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

/**
 * v1.51.0 — process-wide state of the llama-server child process.
 *
 * Deliberately OUTSIDE the Service instance (chosen over holding state in
 * the service): the system may destroy and recreate Service objects at
 * will while the app process — Flutter engine and `noah/llmserver`
 * channel included — keeps running, and conversely the Flutter engine may
 * detach while the foreground service keeps the process alive. A plain
 * singleton is the single source of truth for "is the server running,
 * what did it print, why did it stop" no matter which lifecycle is
 * asking. All state is guarded by this object's monitor (@Synchronized);
 * workers are plain daemon threads only — no coroutines, matching the
 * rest of the Kotlin code base.
 */
object LlmServerProcessHolder {

    /// Ring-buffer cap (contract §1: last ≤200 lines).
    private const val LOG_CAP = 200

    /// Per-line truncation: llama.cpp tensor dumps can emit huge lines;
    /// capping each line keeps the buffer bounded (~400 KB worst case).
    private const val LOG_LINE_MAX = 2000

    /// SIGTERM→SIGKILL grace when stopping. On Android destroy() already
    /// sends SIGKILL, so this escalation is belt-and-braces only.
    private const val STOP_GRACE_MS = 2_000L

    private val logs = ArrayList<String>(LOG_CAP + 8)
    private var process: Process? = null
    private var exitCode: Int? = null
    private var startedAtMs: Long? = null

    /// Whether the llama-server child is alive right now.
    @Synchronized
    fun isRunning(): Boolean = process?.isAlive == true

    /// Spawns `binaryPath argvTail…` with stderr merged into stdout
    /// (redirectErrorStream) and starts two daemon workers:
    ///  - a stdout reader feeding the ring buffer (`getLogs`);
    ///  - an exit watcher latching the exit code (`isRunning`).
    ///
    /// Returns false when a process is already alive or the spawn failed.
    /// A failed spawn latches a synthetic exitCode of -1 (real Linux exit
    /// codes are 0..255) plus the reason in the log, so the Dart poller
    /// can fail fast instead of waiting out its health-check timeout.
    @Synchronized
    fun start(binaryPath: String, argvTail: List<String>): Boolean {
        if (process?.isAlive == true) return false
        // Fresh run: drop the previous run's logs and latched state.
        logs.clear()
        exitCode = null
        startedAtMs = null
        return try {
            val proc = ProcessBuilder(listOf(binaryPath) + argvTail)
                .redirectErrorStream(true)
                .start()
            process = proc
            startedAtMs = System.currentTimeMillis()
            Thread {
                try {
                    // llama.cpp prints loading progress with '\r' (readLine
                    // splits those into separate lines) and can be chatty —
                    // exactly what the capped ring buffer is for.
                    proc.inputStream.bufferedReader().use { reader ->
                        reader.forEachLine { line -> appendLog(line) }
                    }
                } catch (_: Exception) {
                    // Process destroyed mid-read — the watcher latches the
                    // exit code, nothing else to do.
                }
            }.apply {
                name = "llama-server-stdout"
                isDaemon = true
            }.start()
            Thread {
                try {
                    // Blocks until the child exits — on its own or via
                    // destroy() from stopServer. The service is kept alive
                    // on purpose afterwards (contract §1): Dart polls
                    // isRunning, sees the latched exit code and then calls
                    // stopServer to tear the service down.
                    recordExit(proc, proc.waitFor())
                } catch (_: Exception) {
                }
            }.apply {
                name = "llama-server-watcher"
                isDaemon = true
            }.start()
            true
        } catch (e: Exception) {
            process = null
            fail(
                "[noah] failed to start llama-server: " +
                    (e.message ?: e.javaClass.simpleName),
            )
            false
        }
    }

    /// Best-effort stop of the child: destroy() (SIGKILL on Android) right
    /// away, with a destroyForcibly escalation after a short grace on a
    /// daemon thread — so neither the UI thread nor the service main
    /// thread ever blocks. Idempotent (a no-op when nothing runs); the
    /// exit code is latched by the watcher thread like any other exit.
    fun stopProcess() {
        val proc = synchronized(this) { process } ?: return
        try {
            proc.destroy()
        } catch (_: Exception) {
        }
        Thread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !proc.waitFor(STOP_GRACE_MS, TimeUnit.MILLISECONDS)
                ) {
                    // Below API 26 there is no timed waitFor/destroyForcibly
                    // — destroy() above is already final there.
                    proc.destroyForcibly()
                }
            } catch (_: Exception) {
            }
        }.apply {
            name = "llama-server-kill"
            isDaemon = true
        }.start()
    }

    /// Latches a start failure: synthetic exitCode -1 with the reason as
    /// the only log line, so `getLogs` explains the failure and
    /// `isRunning` reports `{running: false, exitCode: -1}` without a
    /// live process ever having existed.
    @Synchronized
    fun fail(message: String) {
        logs.clear()
        exitCode = -1
        startedAtMs = null
        appendLog(message)
    }

    /// Appends one merged stdout/stderr line to the ring buffer (oldest
    /// first); trims from the head past [LOG_CAP] and truncates overly
    /// long lines so the buffer stays bounded.
    @Synchronized
    fun appendLog(line: String) {
        logs.add(if (line.length > LOG_LINE_MAX) line.take(LOG_LINE_MAX) else line)
        while (logs.size > LOG_CAP) logs.removeAt(0)
    }

    /// Copy of the ring buffer, oldest first. A copy — never the live list
    /// — so the reader thread can keep appending while Dart serializes it.
    @Synchronized
    fun snapshotLogs(): List<String> = ArrayList(logs)

    /// State snapshot for the channel's `isRunning` call (contract §1):
    /// `running`, latched `exitCode` (null = unknown / never exited) and
    /// `startedAtMs` (null = never started).
    @Synchronized
    fun snapshotState(): Map<String, Any?> = mapOf(
        "running" to (process?.isAlive == true),
        "exitCode" to exitCode,
        "startedAtMs" to startedAtMs,
    )

    /// Latches the exit code of exactly [proc] — ignored when a newer run
    /// has already replaced the handle (start-after-exit race).
    @Synchronized
    private fun recordExit(proc: Process, code: Int) {
        if (process !== proc) return
        exitCode = code
    }
}
