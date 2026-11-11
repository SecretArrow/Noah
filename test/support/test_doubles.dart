import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/di.dart';
import 'package:noah/services/cron_repository.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/app_lock_service.dart';
import 'package:noah/services/background_service.dart';
import 'package:noah/services/backup_service.dart';
import 'package:noah/services/browser_automation.dart';
import 'package:noah/services/chat_store.dart';
import 'package:noah/services/context_repository.dart';
import 'package:noah/services/goal_repository.dart';
import 'package:noah/services/memory_repository.dart';
import 'package:noah/services/ip_guard.dart';
import 'package:noah/services/js_runtime.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/prompt_repository.dart';
import 'package:noah/services/reminder_repository.dart';
import 'package:noah/services/scheduled_job_repository.dart';
import 'package:noah/services/scheduled_job_runner.dart';
import 'package:noah/services/settings_repository.dart';

/// Minimal valid 1x1 PNG used as scripted screenshot bytes.
const String tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// Scripted LLM client for tests: returns queued turns in order
/// (last turn repeats when the queue is exhausted).
class ScriptedLlmClient implements LlmClient {
  ScriptedLlmClient(this.turns, {this.onFirstDelta, this.onTurnComplete});

  final List<AssistantTurn> turns;
  int _index = 0;

  /// Invoked just before the first content delta of a turn is emitted —
  /// lets tests trigger controller.stop() mid-stream.
  final void Function()? onFirstDelta;

  /// Invoked right before a turn is handed back to the controller — lets
  /// tests trigger controller.stop() between steps.
  final void Function()? onTurnComplete;

  /// Wire messages captured for every call.
  final List<List<Map<String, dynamic>>> calls = <List<Map<String, dynamic>>>[];

  /// Tool schemas captured for every call (null = plain chat mode).
  final List<List<Map<String, dynamic>>?> toolSets =
      <List<Map<String, dynamic>>?>[];

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    if (shouldAbort?.call() ?? false) {
      throw const LlmAbortedException('');
    }
    calls.add(messages);
    toolSets.add(tools);
    final AssistantTurn turn =
        turns[_index < turns.length - 1 ? _index++ : turns.length - 1];
    if (turn.content.isNotEmpty && onDelta != null) {
      var first = true;
      final buffer = StringBuffer();
      for (final String part in turn.content.split(' ')) {
        if (first) {
          onFirstDelta?.call();
          first = false;
        }
        buffer.write('$part ');
        onDelta('$part ');
        await Future<void>.delayed(Duration.zero);
        // Abort mid-stream: Stop must cut the turn short, keeping what
        // was already streamed.
        if (shouldAbort?.call() ?? false) {
          throw LlmAbortedException(buffer.toString());
        }
      }
    }
    onTurnComplete?.call();
    return turn;
  }
}

/// Scripted browser for tests: records every call and returns
/// deterministic page data. Screenshot writes a tiny PNG to disk
/// when [writeScreenshot] is true (real IO — only safe outside the async
/// test zone); otherwise it returns a path without touching the
/// filesystem.
class ScriptedBrowserAutomation implements BrowserAutomation {
  ScriptedBrowserAutomation(this.saveDir, {this.writeScreenshot = true});

  final String saveDir;
  final bool writeScreenshot;
  final List<String> calls = <String>[];

  @override
  Future<BrowserPageInfo> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    String? sessionId,
  }) async {
    calls.add('navigate:$url${sessionId == null ? '' : ' @$sessionId'}');
    if (url.trim().isEmpty) {
      return BrowserPageInfo(url: '', title: '', text: '', error: 'URL kosong');
    }
    return BrowserPageInfo(
      url: url,
      title: 'Example Domain',
      text: 'Example Domain\nThis domain is for use in illustrative examples.',
    );
  }

  @override
  Future<Map<String, dynamic>> click({
    String? selector,
    String? text,
    String? sessionId,
  }) async {
    calls.add('click:${text ?? selector}');
    return <String, dynamic>{'ok': true, 'clicked': text ?? selector ?? ''};
  }

  @override
  Future<Map<String, dynamic>> type(
    String text, {
    String? selector,
    bool clear = true,
    String? sessionId,
  }) async {
    calls.add('type:$text');
    return <String, dynamic>{'ok': true, 'typed': text};
  }

  @override
  Future<Map<String, dynamic>> scroll({
    String direction = 'down',
    int amount = 800,
    String? sessionId,
  }) async {
    calls.add('scroll:$direction:$amount');
    return <String, dynamic>{'ok': true, 'scrollY': amount};
  }

  @override
  Future<String?> screenshot({
    required String saveDir,
    String? sessionId,
  }) async {
    calls.add('screenshot');
    final String path =
        '$saveDir${Platform.pathSeparator}test_shot_${DateTime.now().microsecondsSinceEpoch}.png';
    if (!writeScreenshot) return path;
    final Directory dir = Directory(saveDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await File(path).writeAsBytes(base64Decode(tinyPngBase64));
    return path;
  }

  @override
  Future<String> extractText({int maxLength = 8000, String? sessionId}) async {
    calls.add('extract');
    const String text =
        'Example Domain\nThis domain is for use in illustrative examples.';
    return text.length > maxLength ? text.substring(0, maxLength) : text;
  }

  @override
  Future<String> runJs(String code, {String? sessionId}) async {
    calls.add('run_js:$code');
    return '"ok"';
  }

  @override
  Future<void> purgeSiteData() async {
    calls.add('purge_site_data');
  }

  @override
  Future<String> reconcileOriginStorage(String payloadJson) async {
    calls.add('reconcile_origin:$payloadJson');
    return 'reconciled';
  }

  @override
  @override
  BrowserAutomation withContext(String contextId) => this;

  @override
  Future<void> resetSession() async {}

  @override
  void dispose() {}
}

/// ChatStore test double whose [load]/[delete] throw — proves the chat
/// controller converts storage failures into localized error messages
/// instead of crashing (these futures are invoked without await from the
/// UI).
class ThrowingChatStore implements ChatStore {
  @override
  Future<Directory> Function() get resolveBaseDir => _explode;

  @override
  bool get offloadIsolate => false;

  Future<Directory> _explode() async =>
      throw const FileSystemException('disk exploded');

  @override
  Future<List<ChatSummary>> listSummaries() async => <ChatSummary>[];

  @override
  Future<List<ChatSearchHit>> searchAll(String query, {int limit = 50}) async =>
      <ChatSearchHit>[];

  @override
  Future<void> save({
    required String id,
    required String title,
    required List<ChatMessage> messages,
    List<String> modules = const <String>[],
    List<String> skills = const <String>[],
    bool waitingForSetup = false,
    List<TodoItem> todos = const <TodoItem>[],
  }) async {}

  @override
  Future<List<ChatMessage>?> load(String id) async =>
      throw const FileSystemException('disk exploded');

  @override
  Future<SessionBundle?> loadBundle(String id) async =>
      throw const FileSystemException('disk exploded');

  @override
  Future<List<String>> loadModules(String id) async => const <String>[];

  @override
  Future<String> loadTitle(String id) async => '';

  @override
  Future<void> saveModules(String id, List<String> modules) async {}

  @override
  Future<bool> loadWaitingForSetup(String id) async => false;

  @override
  Future<List<TodoItem>> loadTodos(String id) async =>
      throw const FileSystemException('disk exploded');

  @override
  Future<void> delete(String id) async =>
      throw const FileSystemException('disk exploded');

  @override
  Future<void> rename(String id, String title) async =>
      throw const FileSystemException('disk exploded');
}

/// In-memory [ChatStore] for WIDGET tests.
///
/// The real store's file IO never completes inside a `testWidgets`
/// FakeAsync zone (the same reason the harness already replaces the
/// background service and the JS runtime), which leaves `restoreLastChat`
/// and `openChat` stuck in `isLoading` forever — and an indeterminate
/// spinner then makes every `pumpAndSettle` time out. This double answers
/// immediately from a map and behaves like the disk store for the purposes
/// of the UI (sessions persist across screens within one test).
class MemoryChatStore implements ChatStore {
  MemoryChatStore([Map<String, SessionBundle>? seed])
    : _sessions = <String, SessionBundle>{...?seed};

  final Map<String, SessionBundle> _sessions;
  final Map<String, DateTime> _updatedAt = <String, DateTime>{};

  @override
  Future<Directory> Function() get resolveBaseDir => _explode;

  @override
  bool get offloadIsolate => false;

  Future<Directory> _explode() async =>
      throw const FileSystemException('memory store has no directory');

  /// Titles are kept alongside the bundles: [SessionBundle] carries no
  /// title (the real store keeps it in the file's JSON header).
  final Map<String, String> _titles = <String, String>{};

  @override
  Future<List<ChatSummary>> listSummaries() async {
    final List<ChatSummary> out = <ChatSummary>[
      for (final MapEntry<String, SessionBundle> entry in _sessions.entries)
        ChatSummary(
          id: entry.key,
          title: _titles[entry.key] ?? 'Untitled',
          updatedAt:
              _updatedAt[entry.key] ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
    ];
    out.sort(
      (ChatSummary a, ChatSummary b) => b.updatedAt.compareTo(a.updatedAt),
    );
    return out;
  }

  @override
  Future<List<ChatSearchHit>> searchAll(String query, {int limit = 50}) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return <ChatSearchHit>[];
    return <ChatSearchHit>[
      for (final ChatSummary summary in await listSummaries())
        if (summary.title.toLowerCase().contains(q))
          ChatSearchHit(
            sessionId: summary.id,
            title: summary.title,
            snippet: summary.title,
            role: null,
            createdAt: summary.updatedAt,
          ),
    ].take(limit).toList();
  }

  @override
  Future<void> save({
    required String id,
    required String title,
    required List<ChatMessage> messages,
    List<String> modules = const <String>[],
    List<String> skills = const <String>[],
    bool waitingForSetup = false,
    List<TodoItem> todos = const <TodoItem>[],
  }) async {
    _sessions[id] = SessionBundle(
      messages: List<ChatMessage>.unmodifiable(messages),
      modules: List<String>.unmodifiable(modules),
      waitingForSetup: waitingForSetup,
      todos: List<TodoItem>.unmodifiable(todos),
    );
    _titles[id] = title;
    _updatedAt[id] = DateTime.now();
  }

  @override
  Future<List<ChatMessage>?> load(String id) async => _sessions[id]?.messages;

  @override
  Future<SessionBundle?> loadBundle(String id) async => _sessions[id];

  @override
  Future<List<String>> loadModules(String id) async =>
      _sessions[id]?.modules ?? const <String>[];

  @override
  Future<String> loadTitle(String id) async => _titles[id] ?? '';

  @override
  Future<void> saveModules(String id, List<String> modules) async {
    final SessionBundle? old = _sessions[id];
    if (old == null) return;
    _sessions[id] = SessionBundle(
      messages: old.messages,
      modules: List<String>.unmodifiable(modules),
      waitingForSetup: old.waitingForSetup,
      todos: old.todos,
    );
  }

  @override
  Future<bool> loadWaitingForSetup(String id) async =>
      _sessions[id]?.waitingForSetup ?? false;

  @override
  Future<List<TodoItem>> loadTodos(String id) async =>
      _sessions[id]?.todos ?? const <TodoItem>[];

  @override
  Future<void> delete(String id) async {
    _sessions.remove(id);
    _titles.remove(id);
    _updatedAt.remove(id);
  }

  @override
  Future<void> rename(String id, String title) async {
    if (!_sessions.containsKey(id)) return;
    _titles[id] = title;
  }
}

/// Browser test double whose every method throws — used to prove the tool
/// executor degrades platform failures into error results instead of
/// crashing the agent loop.
class ThrowingBrowserAutomation implements BrowserAutomation {
  @override
  Future<BrowserPageInfo> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    String? sessionId,
  }) async => throw const SocketException('browser exploded');

  @override
  Future<Map<String, dynamic>> click({
    String? selector,
    String? text,
    String? sessionId,
  }) async => throw const SocketException('browser exploded');

  @override
  Future<Map<String, dynamic>> type(
    String text, {
    String? selector,
    bool clear = true,
    String? sessionId,
  }) async => throw const SocketException('browser exploded');

  @override
  Future<Map<String, dynamic>> scroll({
    String direction = 'down',
    int amount = 800,
    String? sessionId,
  }) async => throw const SocketException('browser exploded');

  @override
  Future<String?> screenshot({
    required String saveDir,
    String? sessionId,
  }) async => throw const SocketException('browser exploded');

  @override
  Future<String> extractText({int maxLength = 8000, String? sessionId}) async =>
      throw const SocketException('browser exploded');

  @override
  Future<String> runJs(String code, {String? sessionId}) async =>
      throw const SocketException('browser exploded');

  @override
  Future<void> purgeSiteData() async =>
      throw const SocketException('browser exploded');

  @override
  Future<String> reconcileOriginStorage(String payloadJson) async =>
      throw const SocketException('browser exploded');

  @override
  @override
  BrowserAutomation withContext(String contextId) => this;

  @override
  Future<void> resetSession() async {}

  @override
  void dispose() {}
}

/// Recording test double for the background-run hold: captures every call
/// so tests can assert the foreground service is started/stopped around
/// the agent loop and receives per-step progress updates.
class RecordingBackgroundRun implements BackgroundRun {
  final List<String> calls = <String>[];
  bool _active = false;

  /// Recorded "task finished" notifications (v1.18.0).
  final List<String> doneNotifications = <String>[];

  /// Value returned by [drainPendingSession].
  String? pendingSession;

  @override
  bool get isActive => _active;

  @override
  Future<void> start({required String title, required String text}) async {
    calls.add('start:$title|$text');
    _active = true;
  }

  @override
  Future<void> updateStatus(String text) async {
    calls.add('update:$text');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _active = false;
  }

  /// Sessions with a live per-chat notification (v1.42.0 assertions).
  final Set<String> activeSessions = <String>{};

  @override
  Future<void> startSession({
    required String sessionId,
    required String title,
    required String text,
  }) async {
    calls.add('startSession:$sessionId|$title|$text');
    activeSessions.add(sessionId);
  }

  @override
  Future<void> updateSessionStatus({
    required String sessionId,
    required String text,
  }) async {
    calls.add('updateSession:$sessionId|$text');
  }

  @override
  Future<void> stopSession(String sessionId) async {
    calls.add('stopSession:$sessionId');
    activeSessions.remove(sessionId);
  }

  @override
  Future<bool> notifyDone({
    required String title,
    required String text,
    String? sessionId,
  }) async {
    doneNotifications.add('$title|$text|$sessionId');
    return true;
  }

  @override
  Future<String?> drainPendingSession() async {
    final String? value = pendingSession;
    pendingSession = null;
    return value;
  }

  /// Battery-optimization state reported to the settings screen (v1.28.0).
  bool batteryExempted = false;
  int batteryRequests = 0;

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    batteryRequests++;
    calls.add('battery:request');
    batteryExempted = true; // simulate the user granting it
    return true;
  }

  @override
  Future<bool> isIgnoringBatteryOptimization() async => batteryExempted;
}

/// Scripted JS runtime for tests: records executed code and module
/// invocations instead of spinning up a WebView, returning either queued
/// results or a fixed [nextResult].
class ScriptedJsRuntime implements JsRuntime {
  ScriptedJsRuntime([this.nextResult]);

  JsRunResult? nextResult;

  /// Queue of results consumed by [run]/[runModule] before falling back
  /// to [nextResult] (which itself defaults to a successful no-op).
  final List<JsRunResult> resultQueue = <JsRunResult>[];

  final List<String> runs = <String>[];

  /// Every module invocation captured by [runModule], in order.
  final List<ModuleInvocation> moduleInvocations = <ModuleInvocation>[];

  /// Optional async hook awaited INSIDE [runModule] while the caller's
  /// execution context is still live — lets tests drive the module bridge
  /// exactly like a real serialized execution would.
  Future<void> Function(ModuleInvocation invocation)? onModuleInvocation;

  JsRunResult _pop() {
    if (resultQueue.isNotEmpty) return resultQueue.removeAt(0);
    return nextResult ?? JsRunResult(output: 'ok', result: '"ok"');
  }

  @override
  Future<JsRunResult> run(
    String code, {
    List<String> moduleRoots = const <String>[],
    String? workingDir,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    runs.add(code);
    return _pop();
  }

  @override
  Future<JsRunResult> runModule(ModuleInvocation invocation) async {
    moduleInvocations.add(invocation);
    await onModuleInvocation?.call(invocation);
    return _pop();
  }

  @override
  void dispose() {}
}

/// Standard test overrides for the app's provider scope.
///
/// Set [writeScreenshots] to false for widget tests: the async test zone
/// cannot complete real file IO or image codec decoding.
/// In-memory SharedPreferences stand-in: AppLockService only needs
/// getString/setString/remove; everything else is explicitly unsupported.
class _MemoryPrefs implements SharedPreferences {
  final Map<String, String> _store = <String, String>{};

  @override
  String? getString(String key) => _store[key];

  @override
  Future<bool> setString(String key, String value) async {
    _store[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _store.remove(key);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used in tests');
}

/// Biometric test double for widget tests: never available, never
/// prompts.
class _LockedOutBiometric implements BiometricAuth {
  @override
  Future<bool> canAuthenticate() async => false;

  @override
  Future<bool> authenticate(String localizedReason) async => false;
}

List<Override> testOverrides({
  LlmClient? llm,
  required Directory dir,
  AppSettings? settings,
  bool writeScreenshots = true,
  List<ContextEntry>? contexts,
  List<PromptEntry>? prompts,
  Map<String, List<MemoryEntry>>? memoriesBySession,
  Map<String, List<GoalEntry>>? goalsBySession,
  Map<String, List<ReminderEntry>>? remindersBySession,
  Map<String, List<ScheduledJob>>? jobsBySession,
  TelegramConfig? telegramConfig,
  ScriptedJsRuntime? js,
}) => <Override>[
  settingsRepositoryProvider.overrideWithValue(
    MemorySettingsRepository(settings),
  ),
  contextRepositoryProvider.overrideWithValue(
    MemoryContextRepository(contexts),
  ),
  promptRepositoryProvider.overrideWithValue(MemoryPromptRepository(prompts)),
  memoryRepositoryProvider.overrideWithValue(
    InMemoryMemoryRepository(memoriesBySession),
  ),
  goalRepositoryProvider.overrideWithValue(
    InMemoryGoalRepository(goalsBySession),
  ),
  reminderRepositoryProvider.overrideWithValue(
    InMemoryReminderRepository(remindersBySession),
  ),
  scheduledJobRepositoryProvider.overrideWithValue(
    InMemoryScheduledJobRepository(jobsBySession),
  ),
  cronRepositoryProvider.overrideWithValue(MemoryCronRepository()),
  telegramConfigStoreProvider.overrideWithValue(
    MemoryTelegramConfigStore(telegramConfig ?? const TelegramConfig()),
  ),
  documentsDirProvider.overrideWithValue(() async => dir),
  if (llm != null) llmClientProvider.overrideWithValue(llm),
  // Widget tests run in an async test zone: awaiting the real method
  // channel would hang forever (the engine reply never arrives inside
  // the zone). Always plug in the recording double instead; tests that
  // assert on the background hold override it again explicitly.
  backgroundRunServiceProvider.overrideWithValue(RecordingBackgroundRun()),
  appLockServiceProvider.overrideWith(
    (Ref ref) =>
        AppLockService(prefs: _MemoryPrefs(), biometric: _LockedOutBiometric()),
  ),
  // v1.48.0 — the chat-switch IP guard would otherwise read the real
  // network (fetch) and the production prefs provider (which throws in
  // tests). Plug in an INERT guard: fetch → null degrades to "no warning,
  // proceed", so switches behave exactly like the pre-guard flow. Tests
  // that exercise the guard override ipGuardProvider again explicitly.
  ipGuardProvider.overrideWith(
    (Ref ref) => IpGuard(prefs: _MemoryPrefs(), fetchIp: () async => null),
  ),
  browserAutomationProvider.overrideWithValue(
    ScriptedBrowserAutomation(
      '${dir.path}${Platform.pathSeparator}shots',
      writeScreenshot: writeScreenshots,
    ),
  ),
  // The real JS runtime spins up a headless WebView — never available in
  // the test zone. Every test gets a deterministic scripted double by
  // default.
  jsRuntimeProvider.overrideWithValue(js ?? ScriptedJsRuntime()),
  // Isolate-offloaded JSON/crypto (v1.28.0 ANR hardening) hangs inside a
  // FakeAsync widget-test zone (real isolate replies never arrive), and
  // the tiny test payloads need no offloading anyway. The store is built
  // against the same [dir] as the rest of the harness.
  chatStoreProvider.overrideWith(
    (Ref ref) =>
        ChatStore(resolveBaseDir: () async => dir, offloadIsolate: false),
  ),
  backupServiceProvider.overrideWith(
    (Ref ref) => BackupService(
      store: ref.watch(chatStoreProvider),
      settingsRepository: ref.watch(settingsRepositoryProvider),
      contextRepository: ref.watch(contextRepositoryProvider),
      resolveBaseDir: () async => dir,
      offloadIsolate: false,
    ),
  ),
];

/// v1.40.1 — fully in-memory ChatStore for WIDGET tests that render the
/// shell: `restoreLastChat`/`openChat` read this store, and the real
/// store's disk IO never completes inside the async test zone (which left
/// `isLoading` — and the send button's spinner — stuck on forever, timing
/// out every pumpAndSettle).
class InMemoryChatStore implements ChatStore {
  InMemoryChatStore({
    Map<String, List<ChatMessage>>? sessions,
    this.summaries = const <ChatSummary>[],
  }) : _sessions = sessions ?? <String, List<ChatMessage>>{};

  final Map<String, List<ChatMessage>> _sessions;
  final List<ChatSummary> summaries;
  final Map<String, String> _titles = <String, String>{};
  final Map<String, List<String>> _modules = <String, List<String>>{};
  final Map<String, bool> _waiting = <String, bool>{};
  final Map<String, List<TodoItem>> _todos = <String, List<TodoItem>>{};

  @override
  Future<Directory> Function() get resolveBaseDir => _dummyDir;

  Future<Directory> _dummyDir() async =>
      Directory.systemTemp.createTemp('zagents_inmem');

  @override
  bool get offloadIsolate => false;

  @override
  Future<List<ChatSummary>> listSummaries() async => summaries;

  @override
  Future<List<ChatSearchHit>> searchAll(String query, {int limit = 50}) async =>
      const <ChatSearchHit>[];

  @override
  Future<void> save({
    required String id,
    required String title,
    required List<ChatMessage> messages,
    List<String> modules = const <String>[],
    List<String> skills = const <String>[],
    bool waitingForSetup = false,
    List<TodoItem> todos = const <TodoItem>[],
  }) async {
    _sessions[id] = messages;
    _titles[id] = title;
    _modules[id] = modules;
    _waiting[id] = waitingForSetup;
    _todos[id] = todos;
  }

  @override
  Future<List<ChatMessage>?> load(String id) async => _sessions[id];

  @override
  Future<SessionBundle?> loadBundle(String id) async {
    final List<ChatMessage>? messages = _sessions[id];
    if (messages == null) return null;
    return SessionBundle(
      messages: messages,
      modules: _modules[id] ?? const <String>[],
      waitingForSetup: _waiting[id] ?? false,
      todos: _todos[id] ?? const <TodoItem>[],
    );
  }

  @override
  Future<String> loadTitle(String id) async => _titles[id] ?? '';

  @override
  Future<List<String>> loadModules(String id) async =>
      _modules[id] ?? const <String>[];

  @override
  Future<void> saveModules(String id, List<String> modules) async {
    _modules[id] = modules;
  }

  @override
  Future<bool> loadWaitingForSetup(String id) async => _waiting[id] ?? false;

  @override
  Future<List<TodoItem>> loadTodos(String id) async =>
      _todos[id] ?? const <TodoItem>[];

  @override
  Future<void> delete(String id) async {
    _sessions.remove(id);
  }

  @override
  Future<void> rename(String id, String title) async {
    _titles[id] = title;
  }
}
