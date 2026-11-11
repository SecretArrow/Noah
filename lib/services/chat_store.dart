import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../models/models.dart';

/// One-shot snapshot of everything stored for a session (v1.38.1):
/// decoding the transcript JSON ONCE yields the messages, the active
/// module list, the setup-wait flag and the latest plan together —
/// openChat/_materializeSession used to decode the same file up to four
/// times (load + loadModules + loadWaitingForSetup + loadTodos).
class SessionBundle {
  const SessionBundle({
    required this.messages,
    this.modules = const <String>[],
    this.skills = const <String>[],
    this.waitingForSetup = false,
    this.todos = const <TodoItem>[],
  });

  final List<ChatMessage> messages;
  final List<String> modules;

  /// v1.49.0 (wave-2): the per-chat pinned skills (composer skill sheet).
  final List<String> skills;
  final bool waitingForSetup;
  final List<TodoItem> todos;
}

// v1.41.0 — isolate job factories (TOP-LEVEL, must stay out of the class).
//
// Every closure handed to `Isolate.run` serializes its whole LEXICAL scope
// chain. A closure written inline inside an instance method carries that
// method's context, which includes `this` (the ChatStore) — and while any
// save is in flight `_writeChains` holds `_Future` values, which are NOT
// sendable. The offload then throws "object is unsendable" (Random
// save/load/list failures whenever two chat operations overlapped: backup
// runs, delete-behind-save, multi-session chats). Building each job closure
// in a top-level scope guarantees the captured context contains ONLY the
// explicit arguments — strings, maps of primitives — so the send can never
// fail and copies far less data.

/// Serializes a fully built payload map off the UI isolate (save path).
String Function() chatEncodeJob(Map<String, dynamic> payload) =>
    () => jsonEncode(payload);

/// Decodes a raw transcript string into a JSON map (or null) off the UI
/// isolate (load / loadBundle path).
Map<String, dynamic>? Function() chatDecodeMapJob(String raw) => () {
  final Object? decoded = jsonDecode(raw);
  return decoded is Map<String, dynamic> ? decoded : null;
};

/// Decodes just the stored title ('' when absent/malformed).
String Function() chatDecodeTitleJob(String raw) => () {
  final Object? decoded = jsonDecode(raw);
  return decoded is Map ? (decoded['title']?.toString() ?? '') : '';
};

/// Decodes just the stored module list.
List<String>? Function() chatDecodeModulesJob(String raw) => () {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) return null;
  final Object? rawModules = decoded['modules'];
  if (rawModules is! List) return const <String>[];
  return <String>[
    for (final Object? name in rawModules)
      if (name != null && name.toString().trim().isNotEmpty)
        name.toString().trim(),
  ];
};

/// Decodes just the "waiting for module setup" flag.
bool Function() chatDecodeWaitFlagJob(String raw) => () {
  final Object? decoded = jsonDecode(raw);
  return decoded is Map && decoded['waitingForSetup'] == true;
};

/// Decodes just the persisted plan (loose-map tolerant, malformed-safe).
List<TodoItem> Function() chatDecodeTodosJob(String raw) => () {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) return const <TodoItem>[];
  return parseTodoList(decoded['todos']);
};

/// Read-modify-write job used by saveModules/rename: re-encodes the stored
/// transcript with [key] replaced by [value]. Null when the file is not a
/// JSON object (caller keeps the old bytes).
String? Function() chatPatchFieldJob(String raw, String key, Object? value) =>
    () {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      decoded[key] = value;
      return jsonEncode(decoded);
    };

/// Summarizes every stored conversation for the drawer list.
List<ChatSummary> Function() chatSummariesJob(List<String> raws) => () {
  final List<ChatSummary> summaries = <ChatSummary>[];
  for (final String raw in raws) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) continue;
      summaries.add(
        ChatSummary(
          id: decoded['id'] as String,
          title: (decoded['title'] as String?) ?? 'Untitled',
          updatedAt:
              DateTime.tryParse(decoded['updatedAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    } catch (_) {
      // Skip corrupted files.
    }
  }
  summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return summaries;
};

/// Full-corpus search job: decode + match every session off the main
/// isolate; returns plain records — all isolate-sendable.
List<(ChatSearchHit, bool)> Function() chatSearchJob(
  List<String> raws,
  String q,
) => () {
  final List<(ChatSearchHit, bool)> hits = <(ChatSearchHit, bool)>[];
  for (final String raw in raws) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) continue;
      final String id = decoded['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final String title = (decoded['title'] as String?) ?? 'Untitled';
      final DateTime updatedAt =
          DateTime.tryParse(decoded['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bool titleMatch = title.toLowerCase().contains(q);
      if (titleMatch) {
        hits.add((
          ChatSearchHit(
            sessionId: id,
            title: title,
            snippet: ChatStore._previewOf(decoded['messages'], fallback: title),
            role: null,
            createdAt: updatedAt,
          ),
          true,
        ));
      }
      // First matching message of the session (one hit per conversation
      // keeps the result list diverse).
      final Object? rawMessages = decoded['messages'];
      if (rawMessages is List) {
        for (final raw in rawMessages) {
          if (raw is! Map<String, dynamic>) continue;
          final String content = raw['content']?.toString() ?? '';
          if (!content.toLowerCase().contains(q)) continue;
          Role? role;
          for (final Role r in Role.values) {
            if (r.name == raw['role']) {
              role = r;
              break;
            }
          }
          hits.add((
            ChatSearchHit(
              sessionId: id,
              title: title,
              snippet: ChatStore._snippetFor(content, q),
              role: role,
              createdAt:
                  DateTime.tryParse(raw['createdAt']?.toString() ?? '') ??
                  updatedAt,
            ),
            false,
          ));
          break;
        }
      }
    } catch (_) {
      // Skip corrupted files.
    }
  }
  hits.sort((a, b) {
    if (a.$2 != b.$2) return a.$2 ? -1 : 1; // title matches first
    return b.$1.createdAt.compareTo(a.$1.createdAt); // then newest
  });
  return hits;
};

/// Persists chat sessions as JSON files under `<documents>/chats/`.
///
/// ANR hardening (v1.28.0): every JSON decode/encode of chat payloads runs
/// inside [Isolate.run] — conversation files grow into the megabytes, and
/// `jsonDecode` of several megabytes on the MAIN isolate freezes the UI
/// long enough to trigger Android's "app isn't responding" dialog. File
/// bytes stay plain primitives so they cross the isolate boundary safely.
class ChatStore {
  ChatStore({required this.resolveBaseDir, this.offloadIsolate = true});

  final Future<Directory> Function() resolveBaseDir;

  /// When true (production), heavy JSON work runs inside [Isolate.run] so
  /// the UI thread never blocks on megabyte payloads. Widget tests run in
  /// a FakeAsync zone where real isolate replies can never arrive — there
  /// the flag is switched off (payloads are tiny) via testOverrides.
  final bool offloadIsolate;

  /// Runs [work] off the main isolate when enabled, synchronously (in a
  /// future) otherwise — the result is identical either way.
  Future<T> _offload<T>(T Function() work) =>
      offloadIsolate ? Isolate.run(work) : Future<T>.value(work());

  Future<Directory> _chatsDir() async {
    final base = await resolveBaseDir();
    final dir = Directory('${base.path}${Platform.pathSeparator}chats');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<List<ChatSummary>> listSummaries() async {
    final Directory dir = await _chatsDir();
    final List<File> files = <File>[
      await for (final entity in dir.list())
        if (entity is File && entity.path.endsWith('.json')) entity,
    ];
    // Read (async IO) on the main isolate, decode+extract off it. The job
    // closure comes from a top-level factory — see the note above.
    final List<String> raws = <String>[
      for (final File file in files) await file.readAsString(),
    ];
    final List<ChatSummary> out = await _offload(chatSummariesJob(raws));
    return out;
  }

  Future<void> save({
    required String id,
    required String title,
    required List<ChatMessage> messages,
    List<String> modules = const <String>[],
    // v1.49.0 (wave-2): the per-chat pinned skills, stored with the same
    // lifecycle as [modules] (round-trips through loadBundle).
    List<String> skills = const <String>[],
    bool waitingForSetup = false,
    // v1.35.0 crash recovery: the latest agent plan written via todo_write
    // is stored WITH the transcript, so a mid-run crash can no longer wipe
    // the plan the user was watching (it used to live in memory only).
    List<TodoItem> todos = const <TodoItem>[],
  }) {
    // v1.40.1: acquire the per-chat lock FIRST — before any async pre-work —
    // so the lock queue order matches the CALL order. The body used to do
    // async directory resolution + encoding before taking the lock, letting
    // a delete called LATER overtake the save and then watch it resurrect
    // the file (delete-queued-behind-a-save regression).
    return _withLock<void>(id, () async {
      final dir = await _chatsDir();
      final file = File('${dir.path}${Platform.pathSeparator}$id.json');
      // toJson maps stay on the main isolate (cheap, one pass over the
      // list); the megabyte-scale jsonEncode itself runs off the UI
      // thread. The job closure MUST come from the top-level factory: an
      // inline closure here would capture `this`, and a concurrent save's
      // entry in `_writeChains` makes that unsendable (v1.41.0 fix).
      final Map<String, dynamic> payload = <String, dynamic>{
        'id': id,
        'title': title,
        'updatedAt': DateTime.now().toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
        'modules': modules,
        // v1.49.0 (wave-2): per-chat pinned skills (composer skill sheet).
        'skills': skills,
        // v1.29.0: true while a sent message WAITS for a module's required
        // setup input — the agent must not process it until the form is
        // submitted. Persisted so the wait survives app restarts.
        'waitingForSetup': waitingForSetup,
        'todos': todos.map((t) => t.toJson()).toList(),
      };
      final String encoded = await _offload(chatEncodeJob(payload));
      await _atomicWrite(file, encoded);
    });
  }

  /// Per-chat write serialization. `save` / `saveModules` / `rename` /
  /// `delete` all touch the same JSON file, and the two read-modify-write
  /// ones decode the whole transcript first: without this, a rename landing
  /// between a save's read and its write silently reverted the transcript to
  /// the pre-save contents.
  final Map<String, Future<void>> _writeChains = <String, Future<void>>{};

  Future<T> _withLock<T>(String id, Future<T> Function() action) {
    final Future<void> previous = _writeChains[id] ?? Future<void>.value();
    final Completer<void> release = Completer<void>();
    final Future<void> chain = release.future;
    _writeChains[id] = chain;
    return previous.then((_) => action()).whenComplete(() {
      if (identical(_writeChains[id], chain)) _writeChains.remove(id);
      if (!release.isCompleted) release.complete();
    });
  }

  /// Writes [contents] to [file] through a temp file + rename, so a process
  /// kill mid-write can never leave a truncated transcript behind (the old
  /// `writeAsString` truncated the target before writing the new bytes).
  Future<void> _atomicWrite(File file, String contents) async {
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Platforms that refuse to rename over an existing file.
      await file.writeAsString(contents, flush: true);
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // Leftover temp file: harmless, overwritten by the next save.
      }
    }
  }

  Future<List<ChatMessage>?> load(String id) async {
    final dir = await _chatsDir();
    final file = File('${dir.path}${Platform.pathSeparator}$id.json');
    if (!await file.exists()) return null;
    try {
      final String raw = await file.readAsString();
      final Map<String, dynamic>? data = await _offload(chatDecodeMapJob(raw));
      if (data == null) return null;
      final rawMessages = data['messages'];
      if (rawMessages is! List) return null;
      return <ChatMessage>[
        for (final raw in rawMessages)
          if (raw is Map<String, dynamic>) ChatMessage.fromJson(raw),
      ];
    } catch (_) {
      return null;
    }
  }

  /// v1.38.1 — loads the WHOLE stored session state in ONE file read and
  /// ONE decode: messages + active modules + setup-wait flag + latest
  /// plan. Null when the session has no stored file. The narrow getters
  /// above remain for compatibility.
  Future<SessionBundle?> loadBundle(String id) async {
    final dir = await _chatsDir();
    final file = File('${dir.path}${Platform.pathSeparator}$id.json');
    if (!await file.exists()) return null;
    try {
      final String raw = await file.readAsString();
      final Map<String, dynamic>? data = await _offload(chatDecodeMapJob(raw));
      if (data == null) return null;
      final rawMessages = data['messages'];
      return SessionBundle(
        messages: <ChatMessage>[
          if (rawMessages is List)
            for (final raw in rawMessages)
              if (raw is Map<String, dynamic>) ChatMessage.fromJson(raw),
        ],
        modules: <String>[
          if (data['modules'] is List)
            for (final Object? name in (data['modules'] as List<dynamic>))
              if (name != null && name.toString().trim().isNotEmpty)
                name.toString().trim(),
        ],
        skills: <String>[
          if (data['skills'] is List)
            for (final Object? name in (data['skills'] as List<dynamic>))
              if (name != null && name.toString().trim().isNotEmpty)
                name.toString().trim(),
        ],
        waitingForSetup: data['waitingForSetup'] == true,
        todos: parseTodoList(data['todos']),
      );
    } catch (_) {
      return null;
    }
  }

  /// Loads the stored title of [sessionId] ('' when unknown). Used when a
  /// session is materialized in the background: the on-screen title belongs
  /// to another chat.
  Future<String> loadTitle(String id) async {
    final dir = await _chatsDir();
    final file = File('${dir.path}${Platform.pathSeparator}$id.json');
    if (!await file.exists()) return '';
    try {
      final String raw = await file.readAsString();
      return await _offload(chatDecodeTitleJob(raw));
    } catch (_) {
      return '';
    }
  }

  /// Loads the list of chat modules activated for [sessionId] (plugins
  /// are a per-session private-window scope). Empty when unknown.
  Future<List<String>> loadModules(String id) async {
    final dir = await _chatsDir();
    final file = File('${dir.path}${Platform.pathSeparator}$id.json');
    if (!await file.exists()) return const <String>[];
    try {
      // v1.34.0: full-transcript decode off the UI isolate (openChat used
      // to decode the whole file on main a second/third time here).
      final String raw = await file.readAsString();
      final List<String>? modules = await _offload(chatDecodeModulesJob(raw));
      return modules ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// Loads the v1.29.0 "waiting for module setup" flag of [sessionId]:
  /// true while a queued user message is blocked behind a module's
  /// required setup form. False when unknown/corrupted.
  Future<bool> loadWaitingForSetup(String id) async {
    final dir = await _chatsDir();
    final file = File('${dir.path}${Platform.pathSeparator}$id.json');
    if (!await file.exists()) return false;
    try {
      final String raw = await file.readAsString();
      return await _offload(chatDecodeWaitFlagJob(raw));
    } catch (_) {
      return false;
    }
  }

  /// Loads the latest agent plan (todos) persisted for [sessionId]
  /// (v1.35.0 crash recovery). Empty when the session predates plan
  /// persistence, the file is unreadable or the payload is malformed —
  /// a broken plan must never block opening a chat.
  Future<List<TodoItem>> loadTodos(String id) async {
    final dir = await _chatsDir();
    final file = File('${dir.path}${Platform.pathSeparator}$id.json');
    if (!await file.exists()) return const <TodoItem>[];
    try {
      final String raw = await file.readAsString();
      // parseTodoList inside the factory accepts loose maps and skips
      // malformed entries — the same defensive path the todo_write tool
      // call uses.
      return await _offload(chatDecodeTodosJob(raw));
    } catch (_) {
      return const <TodoItem>[];
    }
  }

  /// Persists the module list of [sessionId] without touching messages.
  Future<void> saveModules(String id, List<String> modules) {
    // v1.40.1: lock FIRST (see save) — call order == lock order.
    return _withLock<void>(id, () async {
      final dir = await _chatsDir();
      final file = File('${dir.path}${Platform.pathSeparator}$id.json');
      if (!await file.exists()) return;
      try {
        // v1.34.0: decode + re-encode of the full transcript off the UI
        // isolate — only the resulting JSON string crosses back.
        final String raw = await file.readAsString();
        final String? updated = await _offload(
          chatPatchFieldJob(raw, 'modules', modules),
        );
        if (updated != null) await _atomicWrite(file, updated);
      } catch (_) {
        // Corrupted file: module bookkeeping must never crash the caller.
      }
    });
  }

  Future<void> delete(String id) {
    // v1.40.1: lock FIRST (see save) — call order == lock order.
    return _withLock<void>(id, () async {
      final dir = await _chatsDir();
      final file = File('${dir.path}${Platform.pathSeparator}$id.json');
      if (await file.exists()) await file.delete();
    });
  }

  /// Updates the stored title of a session (keeps messages untouched).
  Future<void> rename(String id, String title) {
    // v1.40.1: lock FIRST (see save) — call order == lock order.
    return _withLock<void>(id, () async {
      final dir = await _chatsDir();
      final file = File('${dir.path}${Platform.pathSeparator}$id.json');
      if (!await file.exists()) return;
      try {
        // v1.34.0: decode + re-encode of the full transcript off the UI
        // isolate.
        final String raw = await file.readAsString();
        final String? updated = await _offload(
          chatPatchFieldJob(raw, 'title', title),
        );
        if (updated != null) await _atomicWrite(file, updated);
      } catch (_) {
        // Corrupted file: renaming must never crash the caller.
      }
    });
  }

  /// Global search across every stored conversation. A session matches
  /// when its title or any message content contains [query]
  /// case-insensitively; each session yields at most two hits (the title
  /// hit + the first matching message). Title matches rank first, newest
  /// conversations first within each group. Corrupted files are skipped.
  Future<List<ChatSearchHit>> searchAll(String query, {int limit = 50}) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty || limit <= 0) return const <ChatSearchHit>[];
    final Directory dir = await _chatsDir();
    final List<File> files = <File>[
      await for (final entity in dir.list())
        if (entity is File && entity.path.endsWith('.json')) entity,
    ];
    final List<String> raws = <String>[
      for (final File file in files) await file.readAsString(),
    ];
    // Decode + match every session off the main isolate; the job factory
    // keeps the closure free of `this` (send-safe) and works on strings
    // only, returning plain records — all isolate-sendable.
    final List<(ChatSearchHit, bool)> ranked = await _offload(
      chatSearchJob(raws, q),
    );
    return <ChatSearchHit>[
      for (final (ChatSearchHit, bool) entry in ranked.take(limit)) entry.$1,
    ];
  }

  /// Short preview used for title-only hits: the first non-empty message
  /// content, truncated; falls back to [fallback] when none exists.
  static String _previewOf(Object? rawMessages, {required String fallback}) {
    if (rawMessages is List) {
      for (final raw in rawMessages) {
        if (raw is! Map<String, dynamic>) continue;
        final String content = raw['content']?.toString() ?? '';
        final String trimmed = content.trim();
        if (trimmed.isEmpty) continue;
        return trimmed.length <= 120
            ? trimmed
            : '${trimmed.substring(0, 120)}…';
      }
    }
    return fallback;
  }

  /// Up to ~120 characters of [content] around the first (case-insensitive)
  /// occurrence of [query], always keeping the matched substring intact.
  static String _snippetFor(String content, String query) {
    final int index = content.toLowerCase().indexOf(query);
    if (index < 0) {
      // Defensive: the caller already verified a match — this only guards
      // against case-mapping edge cases.
      return content.length <= 120 ? content : '${content.substring(0, 120)}…';
    }
    int start = index - 40;
    if (start < 0) start = 0;
    int end = index + query.length + 80;
    if (end > content.length) end = content.length;
    final String prefix = start > 0 ? '…' : '';
    final String suffix = end < content.length ? '…' : '';
    return '$prefix${content.substring(start, end).trim()}$suffix';
  }
}
