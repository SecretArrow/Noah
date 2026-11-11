import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_composer.dart';
import 'agent_polisher.dart';
import 'device_shell.dart';
import 'js_runtime.dart';
import 'module_registry.dart';

/// Outbound transport for `zagents.http` — permission + host allowlist are
/// already enforced by [ModuleRuntime] before this call. [headers] carries
/// the module's extra request headers (hop-by-hop fields filtered out);
/// [timeoutMs] caps the whole request (null = no extra cap); [headOnly]
/// skips the body read (SSE kick-off: return as soon as headers arrive).
/// The result maps carry `status`, `body` and lowercase `headers`.
typedef ModuleHttpTransport = Future<Map<String, dynamic>?> Function(
  String url,
  String method,
  String? body,
  Map<String, String> headers, {
  int? timeoutMs,
  bool headOnly,
});

/// Agent-backed text composer for `zagents.agent.compose`. Implementations
/// run the request through the chat's own LLM plus the composer gate.
typedef ModuleAgentCompose = Future<String> Function(
  AgentComposeRequest request,
);

/// Agent-backed reply polisher for `zagents.agent.polish` (v1.45.0).
/// Implementations run the request through the chat's own LLM plus the
/// reply-polish gate.
typedef ModuleAgentPolish = Future<String> Function(AgentPolishRequest request);

/// Resolves the User-Agent identity modules must use — always the one the
/// user picked in Settings → User Agent (resolved at run start).
typedef ModuleUserAgentResolver = String? Function();

/// Outcome of one airplane-mode transition inside the IP-rotation cycle
/// (`device.airplaneCycle`, v1.34.0). The distinction drives the failure
/// policy: `notRun` (not rooted / `su` denied) answers with the actionable
/// root error, `mismatch` (command ran, verification failed after the
/// single retry) triggers the best-effort OFF restore.
enum _AirplaneSetOutcome {
  /// The read-back matches the requested state.
  verified,

  /// The shell command could not run at all — nothing changed.
  notRun,

  /// The command ran but the state never matched after the retry.
  mismatch,
}

/// Outcome of one chat-module execution.
class ModuleRunResult {
  const ModuleRunResult({
    required this.output,
    this.error,
    this.result,
    this.terminated = false,
  });

  /// Captured console output (capped).
  final String output;
  final String? error;
  final String? result;

  /// True when the user terminated the module while it was running; the
  /// captured output is then discarded on purpose.
  final bool terminated;

  bool get ok => error == null && !terminated;
}

/// True when a finished module run self-reports that it is missing its
/// per-chat setup input — e.g. "no account configured — setup required
/// before any cycle" from a module zip installed BEFORE the host-side
/// setup form existed (installed modules persist across app updates, so
/// a stale zip keeps failing on every chat until the host reacts).
///
/// The controller uses this to surface the per-chat setup form when the
/// (reinstalled) manifest now declares one, or to post actionable
/// guidance (update the module zip / use the module's setup command)
/// when it does not — never a dead-end "run failed" line alone.
bool moduleRunNeedsSetup(ModuleRunResult result) {
  if (result.ok || result.terminated) return false;
  final RegExp pattern = RegExp(
    r'no account configured|setup required|needs? your account|'
    r'needs? setup|not set up yet|account is not configured|'
    r'account not configured',
    caseSensitive: false,
  );
  if (result.error != null && pattern.hasMatch(result.error!)) return true;
  return pattern.hasMatch(result.output);
}

/// One in-flight module execution with its per-chat security context.
class _RunContext {
  _RunContext({
    required this.sessionId,
    required this.moduleName,
    required this.permissions,
    required this.allowedHosts,
  });

  final String sessionId;
  final String moduleName;
  final Set<String> permissions;
  final List<String>? allowedHosts;

  /// Console lines captured through the bridge (`zagents.log`) — the same
  /// delivery path as every other SDK call.
  final List<String> consoleLines = <String>[];
  bool cancelled = false;
  void Function(String text)? onChatEmit;
}

/// Runs chat modules inside the per-chat "private window" sandbox.
///
/// Isolation guarantees (browser-private-window semantics):
/// * **Process/context** — every run boots a fresh embedded-JS context;
///   nothing (module cache, globals, previous secrets) survives between
///   runs, chats or modules.
/// * **State & storage** — each (chat, module) pair gets its own directory
///   `<session-sandbox>/modules/<name>/` with `state/` as the only
///   writable file scope and `storage.json` as a per-chat key/value store.
///   Chat A's module can never read chat B's storage, files or config.
/// * **Configuration** — the module manifest is read-only and comes from
///   the module's own install directory.
/// * **Permissions** — the manifest declares capabilities; the user
///   approves them at activation; the JS SDK hides unauthorized APIs AND
///   the Dart bridge re-checks every call (defense in depth).
/// * **Network** — requires the `network` permission; a manifest
///   `allowedHosts` list further restricts destinations.
/// * **Agent** — requires the `agent` permission; text generation goes
///   through the chat's own agent and the host-side composer gate, so a
///   module can never stuff raw arbitrary model output into a platform.
/// * **Resources** — per-run timeout, console-output cap, storage caps,
///   file-scope confinement.
/// * **Safe termination** — [terminate] cancels an in-flight run: output
///   delivery stops immediately, already-persisted storage is kept.
class ModuleRuntime implements ModuleBridge {
  ModuleRuntime({
    required this.js,
    required this.resolveSandboxRoot,
    required this.resolveModulePath,
    required this.resolveSdkSource,
    required this.resolveNpmModulesRoot,
    this.httpTransport,
    this.agentCompose,
    this.agentPolish,
    this.resolveUserAgent,
    this.deviceCommandsEnabled,
    this.deviceShell,
    this.airplaneProbe,
    this.sleepFn,
  });

  final JsRuntime js;

  /// Session sandbox root resolver (`SessionSandbox.rootFor`).
  final Future<Directory> Function(String? sessionId) resolveSandboxRoot;

  /// Resolves a module's install directory (null = unknown module).
  final Future<String?> Function(String name) resolveModulePath;

  /// Loads the official SDK shim source (`require('zagents-sdk')`).
  final Future<String> Function() resolveSdkSource;

  /// Shared npm library root, usable through `require()` alongside the
  /// module's own directory.
  final Future<String> Function() resolveNpmModulesRoot;

  /// Outbound HTTP for `zagents.http` (see [ModuleHttpTransport]).
  final ModuleHttpTransport? httpTransport;

  /// Resolves the User-Agent exposed to modules as `zagents.info.userAgent`
  /// — the identity the user picked in Settings → User Agent. Modules can
  /// read it, but they can never override it (see [_blockedRequestHeaders]).
  final ModuleUserAgentResolver? resolveUserAgent;

  /// Text composer for `zagents.agent.compose` (see [ModuleAgentCompose]).
  final ModuleAgentCompose? agentCompose;

  /// Reply polisher for `zagents.agent.polish` (see [ModuleAgentPolish]).
  final ModuleAgentPolish? agentPolish;

  /// Master switch for `zagents.device.shell` (v1.31.0): read on EVERY
  /// call — the Settings → Modules toggle turns the capability off live.
  /// Null resolver (tests) counts as disabled.
  final bool Function()? deviceCommandsEnabled;

  /// Native shell executor for `zagents.device.shell` (see
  /// [DeviceShellService]). Null (tests without the seam) counts as
  /// unavailable — the op degrades into a clean error.
  final Future<DeviceShellResult> Function(
    String command,
    bool root,
    int timeoutMs,
  )?
  deviceShell;

  /// Read-only airplane-mode probe for `zagents.device.airplane`
  /// (v1.32.0): no root, no master switch — a world-readable setting.
  /// Null (tests without the seam) degrades to `available: false` so a
  /// module can branch on the capability instead of crashing. The probe
  /// returns null when the platform cannot answer ("unknown").
  final Future<bool?> Function()? airplaneProbe;

  /// Injectable wait for the airplane IP-rotation cycle
  /// (`device.airplaneCycle`, v1.34.0) — the hold-ON and settle waits.
  /// Defaults to [Future.delayed]; tests inject a recording/immediate
  /// fake so the suite never really waits seconds.
  final Future<void> Function(int ms)? sleepFn;

  /// Shell-command caps for `device.shell`: a hostile module can neither
  /// smuggle in megabyte-long command lines nor pin the executor beyond
  /// the 120s ceiling (mirrored by the native side).
  static const int maxShellCommandChars = 2000;
  static const int defaultShellTimeoutMs = 30000;
  static const int maxShellTimeoutMs = 120000;
  static const int maxShellStreamChars = 32 * 1024;

  /// Airplane-cycle wait clamps for `device.airplaneCycle` (v1.34.0):
  /// the ON hold gives the radio time to fully deregister; the settle
  /// wait gives the carrier time to hand out the new IP after the radio
  /// re-registers. A hold below the minimum would risk cycling while the
  /// radio never left the network (no IP rotation).
  static const int defaultAirplaneCycleHoldMs = 2500;
  static const int minAirplaneCycleHoldMs = 500;
  static const int maxAirplaneCycleHoldMs = 15000;
  static const int defaultAirplaneCycleSettleMs = 8000;
  static const int maxAirplaneCycleSettleMs = 30000;

  /// Default wait seam when [sleepFn] is not injected.
  static Future<void> _defaultSleep(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// Cooperative per-chat setup key inside the (chat, module) storage:
  /// the host writes the submitted setup-form values here; modules may
  /// mirror their own configured state into the same key (e.g. after a
  /// text-command setup) so the host's setup gate reflects reality on
  /// every path. Exposed to modules as `zagents.info.setup` at run start.
  static const String setupStorageKey = 'zagentsSetup';

  /// Per-key JSON-size cap for `zagents.storage.set` (encoded).
  static const int maxStorageValueBytes = 64 * 1024;

  /// Total storage.json budget per (chat, module).
  static const int maxStorageTotalBytes = 1024 * 1024;

  /// Console-output caps for one module run.
  static const int maxOutputBytes = 32 * 1024;
  static const int maxOutputLines = 400;

  /// In-flight module executions keyed by correlation token (v1.38.0).
  /// Two chats may queue module runs concurrently (the JS runtime still
  /// executes them one at a time, but `run()` overlaps queueing with
  /// execution), so a single live-context slot let chat B overwrite chat
  /// A's context — chat.emit, storage and stop all misrouted. Every
  /// bridge request now carries its run's token (`__zctx`) and resolves
  /// exactly one context.
  final Map<String, _RunContext> _contexts = <String, _RunContext>{};

  int _ctxSeq = 0;

  /// Absolute path of the (chat, module) instance directory:
  /// `<session-sandbox>/modules/<name>/`. Created on demand. Holds
  /// `storage.json` (per-chat key/value store) and `state/` (the only
  /// writable file scope for this module in THIS chat).
  Future<Directory> instanceDirFor(String sessionId, String name) async {
    final Directory root = await resolveSandboxRoot(sessionId);
    final Directory dir = Directory(
      '${root.path}${Platform.pathSeparator}modules'
      '${Platform.pathSeparator}$name',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Executes the module entry point for [sessionId]. [granted] is the
  /// user-approved subset of the manifest permissions. [onChatEmit]
  /// receives every `zagents.chat.emit(text)` call while the run is live.
  /// [activationPrompt] is the user message that triggered the activation
  /// (staged-module path); modules read it as `zagents.info.prompt` to
  /// implement setup commands — null on every other path.
  Future<ModuleRunResult> run({
    required String sessionId,
    required ChatModule module,
    required Set<ModulePermission> granted,
    void Function(String text)? onChatEmit,
    String? activationPrompt,
  }) async {
    // Register the security context BEFORE any await (v1.38.0): the user
    // must be able to stop a run even while it is still resolving module
    // paths/setup, and the correlation token must exist for every bridge
    // call from the first moment.
    final String token =
        'mctx-${DateTime.now().microsecondsSinceEpoch}-${_ctxSeq++}';
    final _RunContext context = _RunContext(
      sessionId: sessionId,
      moduleName: module.name,
      permissions: granted.map((ModulePermission p) => p.name).toSet(),
      allowedHosts: module.manifest.allowedHosts,
    )..onChatEmit = onChatEmit;
    _contexts[token] = context;

    // Resolve FIRST so an uninstalled/removed module degrades into a
    // clean error instead of a raw file-not-found exception.
    final String? moduleDir = await resolveModulePath(module.name);
    if (moduleDir == null) {
      return ModuleRunResult(
        output: '',
        error: 'Module "${module.name}" is not installed',
      );
    }
    final String entrySource;
    try {
      entrySource = await File(module.entryPath).readAsString();
    } catch (e) {
      return ModuleRunResult(
        output: '',
        error:
            'Cannot read module entry "${module.manifest.entry}": '
            '${e is FormatException ? 'the file is not valid UTF-8 — save it as UTF-8 and reinstall the module' : e}',
      );
    }
    final Directory instance = await instanceDirFor(sessionId, module.name);
    final Directory stateDir = Directory(
      '${instance.path}${Platform.pathSeparator}state',
    );
    if (!stateDir.existsSync()) stateDir.createSync(recursive: true);
    final String npmRoot = await resolveNpmModulesRoot();
    // Setup-form values submitted for THIS chat (host-owned cooperative
    // key) — exposed as `zagents.info.setup` so modules can consume the
    // collected input without touching storage themselves.
    final Map<String, dynamic> storedSetup = await readStoredSetup(
      sessionId,
      module.name,
    );

    String output = '';
    String? error;
    String? result;
    try {
      final JsRunResult run = await js.runModule(
        ModuleInvocation(
          entrySource: entrySource,
          moduleRoots: <String>[moduleDir, if (npmRoot.isNotEmpty) npmRoot],
          workingDir: stateDir.path,
          permissions: context.permissions,
          info: <String, dynamic>{
            'name': module.name,
            'version': module.manifest.version,
            'title': module.manifest.title,
            'sessionId': sessionId,
            'entry': module.manifest.entry,
            // Per-chat setup-form values (empty when not set up yet).
            'setup': storedSetup,
            // Settings → User Agent integration: modules read the identity
            // they present (same string the transport sends via zagents.http).
            if (resolveUserAgent?.call() case final String ua
                when ua.isNotEmpty)
              'userAgent': ua,
            if (activationPrompt != null && activationPrompt.isNotEmpty)
              'prompt': activationPrompt,
          },
          allowedHosts: module.manifest.allowedHosts,
          bridge: this,
          sdkSource: await resolveSdkSource(),
          timeout: module.manifest.timeout,
          contextToken: token,
        ),
      );
      // Console lines captured through the bridge + whatever the runtime
      // itself captured (core console.log frames).
      final List<String> outputParts = <String>[
        ...context.consoleLines,
        if (run.output.trim().isNotEmpty) run.output,
      ];
      output = _capOutput(outputParts.join('\n'));
      error = run.error;
      result = run.result;
    } finally {
      _contexts.remove(token);
    }

    if (context.cancelled) {
      return ModuleRunResult(
        output: '',
        terminated: true,
        error: 'Module terminated by user',
      );
    }
    return ModuleRunResult(output: output, error: error, result: result);
  }

  /// Safely terminates the in-flight execution of (chat, module): live
  /// `zagents.chat.emit` delivery and the final output are discarded,
  /// persisted storage stays intact. Returns true when a run was active.
  bool terminate(String sessionId, String moduleName) {
    bool any = false;
    for (final _RunContext context in _contexts.values) {
      if (context.sessionId != sessionId || context.moduleName != moduleName) {
        continue;
      }
      context.cancelled = true;
      any = true;
    }
    return any;
  }

  /// Terminates every module currently running for [sessionId] (used when
  /// a session is stopped or deleted). Returns the terminated module
  /// names (one per in-flight run — normally one).
  List<String> terminateSession(String sessionId) {
    final List<String> terminated = <String>[];
    for (final _RunContext context in _contexts.values) {
      if (context.sessionId != sessionId) continue;
      context.cancelled = true;
      terminated.add(context.moduleName);
    }
    return terminated;
  }

  /// Caps one shell output stream (`device.shell` stdout/stderr) so a
  /// chatty command cannot blow up the module message or the bridge frame.
  String _capShellStream(String stream) {
    if (stream.length <= maxShellStreamChars) return stream;
    return '${stream.substring(0, maxShellStreamChars)}'
        '…[truncated at $maxShellStreamChars chars]';
  }

  String _capOutput(String output) {
    if (output.isEmpty) return output;
    final List<String> lines = output.split('\n');
    if (lines.length > maxOutputLines) {
      lines.removeRange(maxOutputLines, lines.length);
      lines.add('…[output truncated at $maxOutputLines lines]');
    }
    String capped = lines.join('\n');
    if (capped.length > maxOutputBytes) {
      capped =
          '${capped.substring(0, maxOutputBytes)}…[output truncated at '
          '$maxOutputBytes bytes]';
    }
    return capped;
  }

  // -- ModuleBridge (Dart-side enforcement) -------------------------------

  @override
  Future<Map<String, dynamic>?> handleOp(Map<String, dynamic> request) async {
    // v1.38.0: resolve the context by the run's correlation token, so
    // ops from queued/overlapping runs land on the right (chat, module).
    // Legacy fallback: requests without a token (direct test calls) may
    // address the single live context when exactly one exists.
    final Object? rawToken = request['__zctx'];
    _RunContext? context;
    if (rawToken != null) {
      context = _contexts[rawToken.toString()];
    } else if (_contexts.length == 1) {
      context = _contexts.values.first;
    }
    if (context == null) {
      return const <String, dynamic>{
        'ok': false,
        'error': 'No module execution is active',
      };
    }
    final String op = request['zop']?.toString() ?? '';
    switch (op) {
      case 'log':
        // Always available (no permission): mirrors console output into
        // the run result. Yield once so the reply is never instantaneous.
        await Future<void>.delayed(Duration.zero);
        context.consoleLines.add(request['text']?.toString() ?? '');
        return const <String, dynamic>{'ok': true};
      case 'chat.emit':
        if (!context.permissions.contains('chat')) return _denied('chat');
        if (context.cancelled) return const <String, dynamic>{'ok': true};
        context.onChatEmit?.call(request['text']?.toString() ?? '');
        return const <String, dynamic>{'ok': true};
      case 'http.request':
        if (!context.permissions.contains('network')) return _denied('network');
        final String url = request['url']?.toString() ?? '';
        if (!_isHostAllowed(context, url)) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'Host is not allowed by this module (allowedHosts)',
          };
        }
        final transport = httpTransport;
        if (transport == null) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'Network transport is unavailable',
          };
        }
        final Map<String, String> moduleHeaders = _sanitizeHeaders(
          request['headers'],
        );
        final Object? rawTimeout = request['timeoutMs'];
        final int? timeoutMs = rawTimeout is int && rawTimeout > 0
            ? (rawTimeout > 60000 ? 60000 : rawTimeout)
            : null;
        final Map<String, dynamic>? response = await transport(
          url,
          request['method']?.toString() ?? 'GET',
          request['body']?.toString(),
          moduleHeaders,
          timeoutMs: timeoutMs,
          headOnly: request['headOnly'] == true,
        );
        return <String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{
            'status': (response?['status'] as int?) ?? 200,
            'body': response?['body']?.toString() ?? '',
            'headers':
                (response?['headers'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
          },
        };
      case 'agent.compose':
        if (!context.permissions.contains('agent')) return _denied('agent');
        if (context.cancelled) {
          return const <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{'text': ''},
          };
        }
        final compose = agentCompose;
        if (compose == null) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'Agent composer is unavailable',
          };
        }
        final Object? rawContext = request['context'];
        final String contextText = rawContext?.toString() ?? '';
        if (contextText.trim().isEmpty) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'agent.compose requires a non-empty context',
          };
        }
        final Object? rawAvoid = request['avoid'];
        final List<String> avoid = <String>[
          if (rawAvoid is List)
            for (final Object? item in rawAvoid)
              if (item != null && item.toString().trim().isNotEmpty)
                item.toString(),
        ].take(20).toList();
        final Object? rawMaxWords = request['maxWords'];
        final int maxWords = rawMaxWords is int && rawMaxWords > 0
            ? rawMaxWords
            : AgentComposeRequest.defaultMaxWords;
        try {
          final String text = await compose(
            AgentComposeRequest(
              task: request['task']?.toString() ?? '',
              context: contextText,
              instruction: request['instruction']?.toString() ?? '',
              maxWords: maxWords,
              avoid: avoid,
              trailingPeriod: request['trailingPeriod'] == true,
            ),
          );
          return <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{'text': text},
          };
        } on AgentComposeException catch (e) {
          return <String, dynamic>{'ok': false, 'error': e.message};
        } catch (e) {
          return <String, dynamic>{
            'ok': false,
            'error': 'Agent compose failed: $e',
          };
        }
      case 'agent.polish':
        if (!context.permissions.contains('agent')) return _denied('agent');
        if (context.cancelled) {
          return const <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{'text': ''},
          };
        }
        final polish = agentPolish;
        if (polish == null) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'Agent polisher is unavailable',
          };
        }
        final Object? rawTemplate = request['template'];
        final String templateText = rawTemplate?.toString() ?? '';
        if (templateText.trim().isEmpty) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'agent.polish requires a non-empty template',
          };
        }
        final Object? rawReplyContext = request['context'];
        final String replyContext = rawReplyContext?.toString() ?? '';
        if (replyContext.trim().isEmpty) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'agent.polish requires a non-empty context',
          };
        }
        final Object? rawAvoid = request['avoid'];
        final List<String> avoid = <String>[
          if (rawAvoid is List)
            for (final Object? item in rawAvoid)
              if (item != null && item.toString().trim().isNotEmpty)
                item.toString(),
        ].take(8).toList();
        final Object? rawMaxChars = request['maxChars'];
        final int maxChars = rawMaxChars is int && rawMaxChars > 0
            ? rawMaxChars
            : AgentPolishRequest.defaultMaxChars;
        try {
          final String text = await polish(
            AgentPolishRequest(
              template: templateText,
              context: replyContext,
              language: request['language']?.toString() ?? '',
              tone: request['tone']?.toString() ?? '',
              maxChars: maxChars,
              allowEmoji: request['allowEmoji'] == true,
              avoid: avoid,
            ),
          );
          return <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{'text': text},
          };
        } on AgentPolishException catch (e) {
          return <String, dynamic>{'ok': false, 'error': e.message};
        } catch (e) {
          return <String, dynamic>{
            'ok': false,
            'error': 'Agent polish failed: $e',
          };
        }
      case 'device.shell':
        // v1.31.0 — root-capable device commands for modules (airplane
        // mode, VPN toggles, …). Triple gate: manifest permission →
        // Settings master switch → bridge availability, then size/timeout
        // caps before anything reaches the OS.
        if (!context.permissions.contains('device')) return _denied('device');
        if (context.cancelled) {
          return const <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'exitCode': -1,
              'stdout': '',
              'stderr': '',
              'timedOut': false,
            },
          };
        }
        if (!(deviceCommandsEnabled?.call() ?? false)) {
          return const <String, dynamic>{
            'ok': false,
            'error':
                'Device commands are disabled — enable "Device commands" '
                'under Settings → Modules (rooted phones only)',
          };
        }
        final String command = (request['command']?.toString() ?? '').trim();
        if (command.isEmpty) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'device.shell requires a non-empty command',
          };
        }
        if (command.length > maxShellCommandChars) {
          return <String, dynamic>{
            'ok': false,
            'error':
                'Command exceeds the $maxShellCommandChars-character limit',
          };
        }
        final Object? rawShellTimeout = request['timeoutMs'];
        final int timeoutMs = rawShellTimeout is int && rawShellTimeout > 0
            ? (rawShellTimeout > maxShellTimeoutMs
                  ? maxShellTimeoutMs
                  : rawShellTimeout)
            : defaultShellTimeoutMs;
        final shell = deviceShell;
        if (shell == null) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'Shell bridge is unavailable',
          };
        }
        try {
          final DeviceShellResult result = await shell(
            command,
            request['root'] == true,
            timeoutMs,
          );
          return <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'exitCode': result.exitCode,
              'stdout': _capShellStream(result.stdout),
              'stderr': _capShellStream(result.stderr),
              'timedOut': result.timedOut,
              if (result.error != null) 'error': result.error,
            },
          };
        } catch (e) {
          return <String, dynamic>{'ok': false, 'error': 'Shell failed: $e'};
        }
      case 'device.airplane':
        // v1.32.0 — read-only airplane-mode state (manual mode of the
        // airplane module, auto-retry awareness). NO root and NO master
        // switch: `Settings.Global.AIRPLANE_MODE_ON` is world-readable
        // and the probe cannot change anything. The manifest `device`
        // permission still gates it (declared intent, uniform surface).
        if (!context.permissions.contains('device')) return _denied('device');
        final Future<bool?> Function()? probe = airplaneProbe;
        if (probe == null) {
          return const <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{'available': false, 'on': false},
          };
        }
        if (context.cancelled) {
          return const <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{'available': true, 'on': false},
          };
        }
        try {
          final bool? on = await probe();
          return <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'available': on != null,
              'on': on == true,
            },
          };
        } catch (e) {
          return <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{'available': false, 'on': false},
          };
        }
      case 'device.airplaneCycle':
        // v1.34.0 — ONE-command airplane-mode cycle that rotates the
        // carrier IP. Physics: the phone's data IP changes when the radio
        // RE-REGISTERS, i.e. when airplane mode goes back OFF — so the
        // cycle is: ensure airplane ON (radio deregisters) → hold →
        // airplane OFF (re-register, carrier assigns a new IP) → settle.
        // It ALWAYS ends with airplane OFF (online, new IP). Reuses the
        // device.shell triple gate: manifest permission → Settings master
        // switch → bridge availability. Every transition is verified by
        // reading the setting back; a failing verification escalates to a
        // best-effort OFF restore so the device is never left silently
        // in airplane mode.
        if (!context.permissions.contains('device')) return _denied('device');
        if (context.cancelled) {
          return const <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'wasOn': false,
              'finalOn': false,
              'heldMs': 0,
              'settleMs': 0,
              'verified': false,
            },
          };
        }
        if (!(deviceCommandsEnabled?.call() ?? false)) {
          return const <String, dynamic>{
            'ok': false,
            'error':
                'Device commands are disabled — enable "Device commands" '
                'under Settings → Modules (rooted phones only)',
          };
        }
        final shell = deviceShell;
        if (shell == null) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'Shell bridge is unavailable',
          };
        }
        final int cycleHoldMs = _clampCycleWait(
          request['holdMs'],
          defaultMs: defaultAirplaneCycleHoldMs,
          minMs: minAirplaneCycleHoldMs,
          maxMs: maxAirplaneCycleHoldMs,
        );
        final int cycleSettleMs = _clampCycleWait(
          request['settleMs'],
          defaultMs: defaultAirplaneCycleSettleMs,
          minMs: 0,
          maxMs: maxAirplaneCycleSettleMs,
        );
        try {
          return await _runAirplaneCycle(
            context,
            shell,
            holdMs: cycleHoldMs,
            settleMs: cycleSettleMs,
          );
        } catch (e) {
          return <String, dynamic>{
            'ok': false,
            'error': 'Airplane cycle failed: $e',
          };
        }
      case 'storage.get':
        if (!context.permissions.contains('storage')) return _denied('storage');
        final Map<String, dynamic> store = await _readStorage(
          context.sessionId,
          context.moduleName,
        );
        return <String, dynamic>{
          'ok': true,
          'data': store[request['key']?.toString() ?? ''],
        };
      case 'storage.set':
        if (!context.permissions.contains('storage')) return _denied('storage');
        final String key = request['key']?.toString() ?? '';
        if (key.isEmpty) {
          return const <String, dynamic>{
            'ok': false,
            'error': 'Storage key must not be empty',
          };
        }
        final Object? value = request['value'];
        final String encoded = jsonEncode(value);
        if (encoded.length > maxStorageValueBytes) {
          return <String, dynamic>{
            'ok': false,
            'error':
                'Storage value exceeds the $maxStorageValueBytes-byte limit',
          };
        }
        final Map<String, dynamic> store = await _readStorage(
          context.sessionId,
          context.moduleName,
        );
        store[key] = value;
        final String serialized = jsonEncode(store);
        if (serialized.length > maxStorageTotalBytes) {
          return <String, dynamic>{
            'ok': false,
            'error':
                'Module storage exceeds the $maxStorageTotalBytes-byte budget',
          };
        }
        await _writeStorage(context.sessionId, context.moduleName, store);
        return const <String, dynamic>{'ok': true};
      case 'storage.keys':
        if (!context.permissions.contains('storage')) return _denied('storage');
        final Map<String, dynamic> store = await _readStorage(
          context.sessionId,
          context.moduleName,
        );
        return <String, dynamic>{'ok': true, 'data': store.keys.toList()};
      case 'storage.remove':
        if (!context.permissions.contains('storage')) return _denied('storage');
        final Map<String, dynamic> store = await _readStorage(
          context.sessionId,
          context.moduleName,
        );
        store.remove(request['key']?.toString() ?? '');
        await _writeStorage(context.sessionId, context.moduleName, store);
        return const <String, dynamic>{'ok': true};
      default:
        return <String, dynamic>{'ok': false, 'error': 'Unknown module API'};
    }
  }

  Map<String, dynamic> _denied(String permission) => <String, dynamic>{
    'ok': false,
    'error': 'Permission denied: $permission',
  };

  // -- device.airplaneCycle (v1.34.0) --------------------------------------

  /// Clamps one airplane-cycle wait. A non-int (missing/garbage) value
  /// falls back to [defaultMs]; a provided int is clamped into
  /// [minMs, maxMs] — so `settleMs: 0` is a legal "no settle" while
  /// `holdMs: 0` still holds the documented minimum (the radio must
  /// really deregister or no IP is rotated).
  int _clampCycleWait(
    Object? raw, {
    required int defaultMs,
    required int minMs,
    required int maxMs,
  }) {
    if (raw is! int) return defaultMs;
    if (raw < minMs) return minMs;
    if (raw > maxMs) return maxMs;
    return raw;
  }

  /// Runs the airplane-mode IP-rotation cycle. Sequence: read the
  /// verified current state → ensure airplane ON (verified, one retry) →
  /// hold ON ([holdMs], radio deregisters) → airplane OFF (verified, one
  /// retry, radio re-registers and the carrier assigns the new IP) →
  /// settle ([settleMs]). Always ends with airplane OFF; a failed
  /// verification escalates to a best-effort OFF restore.
  Future<Map<String, dynamic>> _runAirplaneCycle(
    _RunContext context,
    Future<DeviceShellResult> Function(String, bool, int) shell, {
    required int holdMs,
    required int settleMs,
  }) async {
    final Future<void> Function(int ms) wait = sleepFn ?? _defaultSleep;
    // a. Verified current state: root `settings get` first, the
    // world-readable probe as fallback — never cycle blind.
    bool? on = await _readAirplaneState(shell);
    if (on == null) {
      final Future<bool?> Function()? probe = airplaneProbe;
      if (probe != null) {
        try {
          on = await probe();
        } catch (_) {
          on = null;
        }
      }
    }
    if (on == null) {
      return const <String, dynamic>{
        'ok': false,
        'error':
            'Airplane cycle could not read the airplane-mode state — '
            'the cycle needs a rooted phone; fall back to the guided '
            'manual mode',
      };
    }
    final bool wasOn = on;
    // b. Ensure airplane ON (settings put + legacy broadcast as one
    // command), verified by reading back; one retry on a mismatch.
    if (!wasOn) {
      final _AirplaneSetOutcome onOutcome = await _setAirplaneMode(
        shell,
        on: true,
      );
      if (onOutcome != _AirplaneSetOutcome.verified) {
        if (onOutcome == _AirplaneSetOutcome.mismatch) {
          // The state is uncertain — force the safe OFF state.
          await _restoreAirplaneOff(shell);
        }
        return <String, dynamic>{
          'ok': false,
          'error': onOutcome == _AirplaneSetOutcome.notRun
              ? 'Airplane cycle needs a rooted phone — the device command '
                    'failed (su unavailable or denied). Fall back to the '
                    'guided manual mode.'
              : 'Airplane cycle failed: the device did not confirm airplane '
                    'ON — no rotation happened, airplane mode is OFF',
        };
      }
    }
    // Cancelled before the hold: restore the safe OFF state, return the
    // cancelled-safe result (mirrors the other bridge ops).
    if (context.cancelled) {
      await _restoreAirplaneOff(shell);
      return _airplaneCycleCancelled(wasOn);
    }
    // c. Hold ON — the radio deregisters.
    await wait(holdMs);
    // d. Airplane OFF — the radio re-registers and the carrier assigns
    // the new IP. Verified; one retry on a mismatch; then the recovery
    // pass so the phone is never left silently in airplane mode.
    final _AirplaneSetOutcome offOutcome = await _setAirplaneMode(
      shell,
      on: false,
    );
    if (offOutcome != _AirplaneSetOutcome.verified) {
      if (offOutcome == _AirplaneSetOutcome.mismatch) {
        // The state is uncertain — force the safe OFF state.
        await _restoreAirplaneOff(shell);
      }
      return <String, dynamic>{
        'ok': false,
        'error': offOutcome == _AirplaneSetOutcome.notRun
            ? 'Airplane cycle needs a rooted phone — the device command '
                  'failed (su unavailable or denied); airplane mode may '
                  'still be ON. Check the phone and fall back to the '
                  'guided manual mode.'
            : 'Airplane cycle failed: the device did not confirm airplane '
                  'OFF — check the phone (airplane mode may still be ON)',
      };
    }
    // Cancelled mid-cycle: the safe OFF state is in place — skip the
    // settle wait and return the cancelled-safe result.
    if (context.cancelled) {
      return _airplaneCycleCancelled(wasOn, heldMs: holdMs);
    }
    // e. Settle — give the carrier time to hand out the new IP.
    await wait(settleMs);
    // f. Done: online again, airplane OFF, IP rotated.
    return <String, dynamic>{
      'ok': true,
      'data': <String, dynamic>{
        'wasOn': wasOn,
        'finalOn': false,
        'heldMs': holdMs,
        'settleMs': settleMs,
        'verified': true,
      },
    };
  }

  /// Cancelled-safe result shape for a cycle interrupted by [terminate].
  Map<String, dynamic> _airplaneCycleCancelled(bool wasOn, {int heldMs = 0}) =>
      <String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{
          'wasOn': wasOn,
          'finalOn': false,
          'heldMs': heldMs,
          'settleMs': 0,
          'verified': false,
        },
      };

  /// Reads the airplane-mode state through a root `settings get` —
  /// null when the shell cannot answer (not rooted, `su` denied, garbage
  /// output). The caller falls back to the world-readable probe.
  Future<bool?> _readAirplaneState(
    Future<DeviceShellResult> Function(String, bool, int) shell,
  ) async {
    try {
      final DeviceShellResult result = await shell(
        'settings get global airplane_mode_on',
        true,
        defaultShellTimeoutMs,
      );
      if (result.error != null || result.timedOut || result.exitCode != 0) {
        return null;
      }
      final String out = result.stdout.trim();
      if (out == '1') return true;
      if (out == '0') return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// One airplane-mode transition: `settings put global
  /// airplane_mode_on 0|1 && am broadcast -a android.intent.action
  /// .AIRPLANE_MODE --ez state true|false` (one joined command), then a
  /// verification read-back. The set is retried ONCE on a verification
  /// mismatch. Returns [_AirplaneSetOutcome.notRun] when the command
  /// could not run at all (not rooted / `su` denied), `mismatch` when
  /// the state never matched after the retry, `verified` on success.
  Future<_AirplaneSetOutcome> _setAirplaneMode(
    Future<DeviceShellResult> Function(String, bool, int) shell, {
    required bool on,
  }) async {
    final String command = _airplaneSetCommand(on);
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final DeviceShellResult put = await shell(
          command,
          true,
          defaultShellTimeoutMs,
        );
        final bool ran =
            put.error == null && !put.timedOut && put.exitCode == 0;
        if (!ran) return _AirplaneSetOutcome.notRun;
        final bool? now = await _readAirplaneState(shell);
        if (now == on) return _AirplaneSetOutcome.verified;
        // Verification mismatch → the single retry (second pass).
      } catch (_) {
        return _AirplaneSetOutcome.notRun;
      }
    }
    return _AirplaneSetOutcome.mismatch;
  }

  /// Best-effort recovery after a failed verification: attempt the OFF
  /// command one more time (fire-and-forget) so a failed cycle never
  /// leaves the phone silently in airplane mode.
  Future<void> _restoreAirplaneOff(
    Future<DeviceShellResult> Function(String, bool, int) shell,
  ) async {
    try {
      await shell(_airplaneSetCommand(false), true, defaultShellTimeoutMs);
    } catch (_) {
      // Best effort only — the caller already reports the failure.
    }
  }

  /// The airplane transition command: settings write + legacy broadcast
  /// joined into one `su -c` line so the radio switch is atomic-ish.
  String _airplaneSetCommand(bool on) =>
      'settings put global airplane_mode_on ${on ? 1 : 0} && '
      'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state '
      '${on ? 'true' : 'false'}';

  /// Hop-by-hop / transport-owned headers a module may not set, plus the
  /// identity headers owned by the host: `user-agent` ALWAYS carries the
  /// identity the user picked in Settings → User Agent — a module cannot
  /// override it. Everything else passes through so real API integrations
  /// can send Cookie, Authorization or Content-Type.
  static const Set<String> _blockedRequestHeaders = <String>{
    'host',
    'content-length',
    'connection',
    'accept-encoding',
    'transfer-encoding',
    'upgrade',
    'keep-alive',
    'user-agent',
  };

  /// Normalizes the JS header object into a plain string map. Caps the
  /// count and size so a hostile manifest cannot balloon one request.
  Map<String, String> _sanitizeHeaders(Object? raw) {
    final Map<String, String> out = <String, String>{};
    if (raw is! Map) return out;
    for (final MapEntry<dynamic, dynamic> entry in raw.entries) {
      final String name = entry.key?.toString().trim().toLowerCase() ?? '';
      if (name.isEmpty || _blockedRequestHeaders.contains(name)) continue;
      final String value = entry.value?.toString() ?? '';
      if (value.length > 8 * 1024) continue;
      out[name] = value;
      if (out.length >= 24) break;
    }
    return out;
  }

  bool _isHostAllowed(_RunContext context, String url) {
    final List<String>? allowlist = context.allowedHosts;
    if (allowlist == null || allowlist.isEmpty) return true;
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    for (final String pattern in allowlist) {
      final String host = pattern.trim().toLowerCase();
      if (host.isEmpty) continue;
      if (uri.host.toLowerCase() == host) return true;
      // Subdomain wildcard: "*.example.com" style suffix match on
      // dot-boundary ("api.example.com" matches "example.com" only when
      // the pattern explicitly starts with "*.").
      if (host.startsWith('*.')) {
        final String suffix = host.substring(1); // ".example.com"
        if (uri.host.toLowerCase().endsWith(suffix)) return true;
      }
    }
    return false;
  }

  // -- per-chat setup values (host-owned cooperative storage key) --------

  /// Reads the setup-form values stored for (chat, module). Empty map when
  /// the user has not submitted the form (and the module has not mirrored
  /// its own configured state) yet.
  Future<Map<String, dynamic>> readStoredSetup(
    String sessionId,
    String moduleName,
  ) async {
    final Map<String, dynamic> store = await _readStorage(
      sessionId,
      moduleName,
    );
    final Object? raw = store[setupStorageKey];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  /// Persists the setup-form values for (chat, module) under the
  /// cooperative [setupStorageKey]. Called when the user submits the
  /// setup form; modules can write the same key through `zagents.storage`.
  Future<void> writeStoredSetup(
    String sessionId,
    String moduleName,
    Map<String, dynamic> values,
  ) async {
    final Map<String, dynamic> store = await _readStorage(
      sessionId,
      moduleName,
    );
    store[setupStorageKey] = values;
    await _writeStorage(sessionId, moduleName, store);
  }

  // -- storage io ---------------------------------------------------------

  Future<File> _storageFileFor(String sessionId, String name) async {
    final Directory dir = await instanceDirFor(sessionId, name);
    return File('${dir.path}${Platform.pathSeparator}storage.json');
  }

  Future<Map<String, dynamic>> _readStorage(
    String sessionId,
    String module,
  ) async {
    final File file = await _storageFileFor(sessionId, module);
    // v1.34.0: async stat — existsSync() blocked the UI isolate on every
    // storage.get/set and every setup read on the module run path.
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _writeStorage(
    String sessionId,
    String module,
    Map<String, dynamic> store,
  ) async {
    final File file = await _storageFileFor(sessionId, module);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(store));
  }
}
