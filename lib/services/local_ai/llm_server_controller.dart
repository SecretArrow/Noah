import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../di.dart';

/// Lifecycle of the bundled llama.cpp `llama-server` runtime — v1.51.0.
enum LlmServerStatus {
  /// No runtime on this device (armeabi-v7a build, missing .so).
  unavailable,

  /// Runtime present, not started.
  stopped,

  /// Launch requested, health endpoint not answering yet.
  starting,

  /// Serving requests on `127.0.0.1:<port>`.
  running,

  /// Stop requested, waiting for the service to settle.
  stopping,

  /// Start failed, crashed, or the health probe timed out; [LlmServerState.message]
  /// says why.
  failed,
}

/// Live snapshot of the llama-server runtime state — v1.51.0.
class LlmServerState {
  const LlmServerState({
    this.status = LlmServerStatus.stopped,
    this.activeModelName = '',
    this.activeModelPath = '',
    this.port = 11434,
    this.message = '',
    this.logTail = const <String>[],
  });

  final LlmServerStatus status;

  /// Display name (alias) of the model handed to the last start call.
  final String activeModelName;

  /// Absolute path of the GGUF file of the last start call.
  final String activeModelPath;

  final int port;

  /// Human-readable failure reason ('' when healthy); English — the UI
  /// localizes around the status, not this raw detail.
  final String message;

  /// Last runtime log lines (oldest first, capped by the platform at
  /// 200) — surfaced in the Server tab log view.
  final List<String> logTail;

  LlmServerState copyWith({
    LlmServerStatus? status,
    String? activeModelName,
    String? activeModelPath,
    int? port,
    String? message,
    List<String>? logTail,
  }) => LlmServerState(
    status: status ?? this.status,
    activeModelName: activeModelName ?? this.activeModelName,
    activeModelPath: activeModelPath ?? this.activeModelPath,
    port: port ?? this.port,
    message: message ?? this.message,
    logTail: logTail ?? this.logTail,
  );
}

/// Dart-side mirror of the `noah/llmserver` platform channel —
/// v1.51.0. Implementations must be defensive: never throw, degrade to
/// safe defaults (`false` / `0` / empty results), because a dead channel
/// must never crash the Ollama Manage screen.
abstract class LlmServerPlatform {
  /// Whether `libllamaserver.so` exists in the app's nativeLibraryDir.
  Future<bool> runtimeAvailable();

  /// Total device RAM in bytes (0 when unknown).
  Future<int> deviceTotalRamBytes();

  /// Launches the foreground service that spawns llama-server. Returns
  /// false when the runtime is missing or a server is already running.
  Future<bool> startServer({
    required String modelPath,
    required String alias,
    required int port,
    required int contextSize,
    required int threads,
    List<String> extraArgs,
  });

  /// Destroys the server process and stops the service.
  Future<bool> stopServer();

  /// Process liveness: `{running: bool, exitCode: int?, startedAtMs: int?}`.
  Future<Map<String, dynamic>> isRunning();

  /// Last ≤200 stdout+stderr lines, oldest first.
  Future<List<String>> getLogs();

  /// Fase 2 (v1.52.0) — battery state of the device: `{percent: int
  /// (0–100, -1 unknown), charging: bool}`. Polled by the Ollama Manage
  /// screen (NOT persisted state) so the Server tab can flag a low
  /// battery while llama-server runs.
  Future<Map<String, dynamic>> batteryStatus();
}

/// Production platform: the `noah/llmserver` method channel. Every
/// call is wrapped — a missing handler (tests) or platform failure
/// resolves to the documented safe default instead of throwing.
class MethodChannelLlmServerPlatform implements LlmServerPlatform {
  static const MethodChannel _channel = MethodChannel('noah/llmserver');

  @override
  Future<bool> runtimeAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('runtimeAvailable') ?? false;
    } catch (_) {
      // No channel (tests/desktop) or platform error: no runtime.
      return false;
    }
  }

  @override
  Future<int> deviceTotalRamBytes() async {
    try {
      return await _channel.invokeMethod<int>('deviceTotalRamBytes') ?? 0;
    } catch (_) {
      // Unknown RAM is fine — the UI hides the line at 0.
      return 0;
    }
  }

  @override
  Future<bool> startServer({
    required String modelPath,
    required String alias,
    required int port,
    required int contextSize,
    required int threads,
    List<String> extraArgs = const <String>[],
  }) async {
    try {
      return await _channel.invokeMethod<bool>('startServer', <String, dynamic>{
            'modelPath': modelPath,
            'alias': alias,
            'port': port,
            'contextSize': contextSize,
            'threads': threads,
            'extraArgs': extraArgs,
          }) ??
          false;
    } catch (_) {
      // Missing runtime / already running / channel unavailable.
      return false;
    }
  }

  @override
  Future<bool> stopServer() async {
    try {
      return await _channel.invokeMethod<bool>('stopServer') ?? false;
    } catch (_) {
      // The Dart side treats the server as stopped regardless.
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> isRunning() async {
    try {
      final Object? raw = await _channel.invokeMethod('isRunning');
      if (raw is Map) return Map<String, dynamic>.from(raw);
      return const <String, dynamic>{'running': false};
    } catch (_) {
      return const <String, dynamic>{'running': false};
    }
  }

  @override
  Future<List<String>> getLogs() async {
    try {
      final Object? raw = await _channel.invokeMethod('getLogs');
      if (raw is List) {
        return <String>[for (final Object? line in raw) line?.toString() ?? ''];
      }
      return const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  Future<Map<String, dynamic>> batteryStatus() async {
    try {
      final Object? raw = await _channel.invokeMethod('batteryStatus');
      if (raw is Map) return Map<String, dynamic>.from(raw);
      return const <String, dynamic>{'percent': -1, 'charging': false};
    } catch (_) {
      // No channel (tests/desktop) or platform error: unknown battery.
      return const <String, dynamic>{'percent': -1, 'charging': false};
    }
  }
}

/// Scriptable in-memory [LlmServerPlatform] for unit tests — v1.51.0.
///
/// Tests flip the public knobs ([available], [running], [exitCode],
/// [logs], [startResult], …) and the fake reports them verbatim, exactly
/// like the Kotlin side would. [startServer] flips [running] on when it
/// returns `true`, [stopServer] clears it — so health-poll scenarios
/// behave realistically without a real process.
class FakeLlmServerPlatform implements LlmServerPlatform {
  FakeLlmServerPlatform({
    this.available = true,
    this.totalRamBytes = 8 * 1024 * 1024 * 1024,
    this.startResult = true,
    this.stopResult = true,
  });

  /// Reported by [runtimeAvailable].
  bool available;

  /// Reported by [deviceTotalRamBytes].
  int totalRamBytes;

  /// What [startServer] returns (false = platform refused to launch).
  bool startResult;

  /// What [stopServer] returns.
  bool stopResult;

  /// Process liveness reported by [isRunning].
  bool running = false;

  /// Recorded exit code (non-null = the process died); see [simulateCrash].
  int? exitCode;

  /// Reported `startedAtMs` while running (set on each accepted start).
  int? startedAtMs;

  /// Log lines reported by [getLogs].
  final List<String> logs = <String>[];

  /// Fase 2 — battery percent reported by [batteryStatus] (0–100).
  int batteryPercent = -1;

  /// Fase 2 — charging flag reported by [batteryStatus].
  bool batteryCharging = false;

  /// One recorded `startServer` argument map per call.
  final List<Map<String, Object?>> startCalls = <Map<String, Object?>>[];

  /// Number of `stopServer` calls.
  int stopCalls = 0;

  /// Marks the process as dead with an exit code (crash scenarios).
  void simulateCrash(int code) {
    running = false;
    exitCode = code;
  }

  @override
  Future<bool> runtimeAvailable() async => available;

  @override
  Future<int> deviceTotalRamBytes() async => totalRamBytes;

  @override
  Future<bool> startServer({
    required String modelPath,
    required String alias,
    required int port,
    required int contextSize,
    required int threads,
    List<String> extraArgs = const <String>[],
  }) async {
    startCalls.add(<String, Object?>{
      'modelPath': modelPath,
      'alias': alias,
      'port': port,
      'contextSize': contextSize,
      'threads': threads,
      'extraArgs': extraArgs,
    });
    if (startResult) {
      running = true;
      exitCode = null;
      startedAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    return startResult;
  }

  @override
  Future<bool> stopServer() async {
    stopCalls++;
    running = false;
    return stopResult;
  }

  @override
  Future<Map<String, dynamic>> isRunning() async => <String, dynamic>{
    'running': running,
    if (exitCode != null) 'exitCode': exitCode,
    if (startedAtMs != null) 'startedAtMs': startedAtMs,
  };

  @override
  Future<List<String>> getLogs() async => List<String>.of(logs);

  @override
  Future<Map<String, dynamic>> batteryStatus() async => <String, dynamic>{
    'percent': batteryPercent,
    'charging': batteryCharging,
  };
}

/// Riverpod controller for the bundled llama-server lifecycle — v1.51.0.
///
/// Dependencies (platform channel + http client) are read through the
/// injectable providers so tests override providers, not constructors.
/// [start] launches the runtime and then polls its `/health` endpoint —
/// llama-server only answers once the model is fully loaded, so
/// "starting" can legitimately take tens of seconds for big GGUFs; the
/// poll also watches the process handle so a native crash fails fast
/// instead of burning the whole timeout.
class LlmServerController extends Notifier<LlmServerState> {
  LlmServerController({
    this.startTimeout = defaultStartTimeout,
    this.healthPollInterval = defaultHealthPollInterval,
  });

  /// How long [start] waits for `/health` to answer 200 before failing
  /// (model load included).
  static const Duration defaultStartTimeout = Duration(seconds: 90);

  /// Poll cadence while starting.
  static const Duration defaultHealthPollInterval = Duration(milliseconds: 500);

  /// Per-request health timeout (a hung request must not eat the whole
  /// start budget on its own).
  static const Duration healthRequestTimeout = Duration(milliseconds: 2500);

  /// Port used when [start] gets no explicit port — the Ollama default,
  /// matching the persisted server config default (the UI passes the
  /// configured value explicitly).
  static const int defaultPort = 11434;

  /// Context window used when [start] gets none — matching the persisted
  /// server config default (2048 keeps the KV cache small).
  static const int defaultContextSize = 2048;

  /// Injectable timing knobs (tests shorten them to stay fast).
  final Duration startTimeout;
  final Duration healthPollInterval;

  @override
  LlmServerState build() => const LlmServerState();

  /// One `GET /health` against the local server; false on any error.
  Future<bool> _healthOk(int port) async {
    try {
      final http.Response response = await ref
          .read(llmHttpClientProvider)
          .get(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(healthRequestTimeout);
      return response.statusCode == 200;
    } catch (_) {
      // Connection refused (still loading), timeout, malformed URL —
      // every miss just means "not healthy yet".
      return false;
    }
  }

  Future<List<String>> _logs() async {
    try {
      return await ref.read(llmServerPlatformProvider).getLogs();
    } catch (_) {
      // Defensive platform contract: never throw.
      return const <String>[];
    }
  }

  Future<Map<String, dynamic>> _isRunning() async {
    try {
      return await ref.read(llmServerPlatformProvider).isRunning();
    } catch (_) {
      return const <String, dynamic>{'running': false};
    }
  }

  /// Coherent status recovery — call when the Server tab opens: maps
  /// the raw platform state (runtime present? process alive? health?)
  /// onto [LlmServerStatus]. A process that died with an exit code
  /// while we believed it was running is reported as failed (crash
  /// recovery), not silently stopped.
  Future<void> refresh() async {
    bool runtime = false;
    try {
      runtime = await ref.read(llmServerPlatformProvider).runtimeAvailable();
    } catch (_) {
      // Defensive platform contract: never throw.
    }
    if (!runtime) {
      state = state.copyWith(
        status: LlmServerStatus.unavailable,
        message: 'llama-server runtime is not available on this device',
      );
      return;
    }
    final Map<String, dynamic> run = await _isRunning();
    if (run['running'] == true) {
      if (await _healthOk(state.port)) {
        state = state.copyWith(status: LlmServerStatus.running, message: '');
      } else {
        // Process alive but not answering yet: the model is loading.
        state = state.copyWith(
          status: LlmServerStatus.starting,
          message: 'server is loading the model',
        );
      }
      return;
    }
    final int? exitCode = run['exitCode'] as int?;
    if (exitCode != null && state.status == LlmServerStatus.running) {
      state = state.copyWith(
        status: LlmServerStatus.failed,
        message: 'server exited with code $exitCode',
        logTail: await _logs(),
      );
      return;
    }
    state = state.copyWith(status: LlmServerStatus.stopped);
  }

  /// Launches llama-server for [modelPath] and waits until it is
  /// actually serving: `starting` → platform start → poll `/health`
  /// every [healthPollInterval] until 200 or [startTimeout]. Returns
  /// true once running; false (status `failed`, message + logTail set)
  /// when the platform refuses, the process dies, or health never
  /// answers in time.
  Future<bool> start({
    required String modelPath,
    required String modelName,
    int? port,
    int? contextSize,
    int? threads,
  }) async {
    if (state.status == LlmServerStatus.running ||
        state.status == LlmServerStatus.starting) {
      return false; // Already up (or a start is still in flight).
    }
    final int effectivePort = port ?? defaultPort;
    state = state.copyWith(
      status: LlmServerStatus.starting,
      activeModelName: modelName,
      activeModelPath: modelPath,
      port: effectivePort,
      message: '',
      logTail: const <String>[],
    );
    bool launched = false;
    try {
      launched = await ref
          .read(llmServerPlatformProvider)
          .startServer(
            modelPath: modelPath,
            alias: modelName,
            port: effectivePort,
            contextSize: contextSize ?? defaultContextSize,
            threads: threads ?? 0,
          );
    } catch (_) {
      // Defensive platform contract: never throw.
      launched = false;
    }
    if (!launched) {
      state = state.copyWith(
        status: LlmServerStatus.failed,
        message: 'llama-server failed to start (runtime missing or busy)',
        logTail: await _logs(),
      );
      return false;
    }

    final Stopwatch watch = Stopwatch()..start();
    while (watch.elapsed < startTimeout) {
      // A native crash fails fast instead of burning the timeout.
      final Map<String, dynamic> run = await _isRunning();
      if (run['running'] != true) {
        final int? exitCode = run['exitCode'] as int?;
        if (exitCode != null) {
          state = state.copyWith(
            status: LlmServerStatus.failed,
            message: 'server exited with code $exitCode',
            logTail: await _logs(),
          );
          return false;
        }
      }
      if (await _healthOk(effectivePort)) {
        state = state.copyWith(status: LlmServerStatus.running, message: '');
        return true;
      }
      await Future<void>.delayed(healthPollInterval);
      // Surface the boot log while the model loads.
      state = state.copyWith(logTail: await _logs());
    }
    state = state.copyWith(
      status: LlmServerStatus.failed,
      message:
          'health check timed out after ${startTimeout.inSeconds}s — '
          'the model may be too large for this device',
      logTail: await _logs(),
    );
    return false;
  }

  /// Stops the runtime. The Dart side always lands on `stopped` — a
  /// refused platform stop is surfaced in [LlmServerState.message] but
  /// never leaves the UI stuck on `stopping`.
  Future<bool> stop() async {
    if (state.status == LlmServerStatus.stopped) return true;
    state = state.copyWith(status: LlmServerStatus.stopping);
    bool stopped = false;
    try {
      stopped = await ref.read(llmServerPlatformProvider).stopServer();
    } catch (_) {
      // Defensive platform contract: never throw.
      stopped = false;
    }
    state = state.copyWith(
      status: LlmServerStatus.stopped,
      message: stopped ? '' : 'stopServer was refused by the platform',
    );
    return stopped;
  }

  /// One liveness pass for the UI's 3 s log/health timer: only acts
  /// while `running`; a dead process flips the status to `failed`
  /// (with the log tail), otherwise the logs are refreshed in place.
  Future<void> pollNow() async {
    if (state.status != LlmServerStatus.running) return;
    final Map<String, dynamic> run = await _isRunning();
    final List<String> logs = await _logs();
    if (run['running'] != true) {
      final int? exitCode = run['exitCode'] as int?;
      state = state.copyWith(
        status: LlmServerStatus.failed,
        message: exitCode == null
            ? 'server exited unexpectedly'
            : 'server exited with code $exitCode',
        logTail: logs,
      );
      return;
    }
    // Alive: refresh the log tail; a transient health miss (e.g. the
    // socket momentarily saturated by a big prompt) must not flip the
    // status — pollNow stays optimistic, only process death fails.
    state = state.copyWith(logTail: logs);
  }
}
