import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/chat_store.dart';

/// Writes a session file the way ChatStore.save would (plus raw variants
/// for corrupted-file coverage).
Future<void> _writeSession(
  Directory base,
  String id, {
  required String title,
  required List<Map<String, dynamic>> messages,
  String? rawUpdated,
}) async {
  final Directory dir = Directory('${base.path}/chats');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  await File('${dir.path}/$id.json').writeAsString(
    jsonEncode(<String, dynamic>{
      'id': id,
      'title': title,
      'updatedAt': rawUpdated ?? '2025-03-01T10:00:00.000',
      'messages': messages,
    }),
  );
}

Map<String, dynamic> _userJson(String content) =>
    ChatMessage.user(content).toJson();

Map<String, dynamic> _assistantJson(String content) =>
    ChatMessage.assistant(content).toJson();

void main() {
  late Directory tempDir;
  late ChatStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_chat_store');
    store = ChatStore(resolveBaseDir: () async => tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('searchAll (v1.15.0)', () {
    setUp(() async {
      await _writeSession(
        tempDir,
        's1',
        title: 'Resep kue cokelat',
        messages: <Map<String, dynamic>>[
          _userJson('Bagaimana cara membuat kue cokelat yang lembut?'),
          _assistantJson('Campur adonan, lalu panggang 30 menit.'),
        ],
      );
      await _writeSession(
        tempDir,
        's2',
        title: 'Jadwal kereta api',
        messages: <Map<String, dynamic>>[
          _userJson('Kapan jadwal KERETA terbaru keluar?'),
          _assistantJson('Besok pagi.'),
        ],
      );
      await _writeSession(
        tempDir,
        's3',
        title: 'Catatan rapat',
        messages: <Map<String, dynamic>>[
          _userJson('Tidak ada yang relevan di sini.'),
        ],
      );
      // Corrupted file: must be skipped without breaking the search.
      final Directory dir = Directory('${tempDir.path}/chats');
      await File('${dir.path}/bad.json').writeAsString('{not json!!');
    });

    test('title match keeps the session metadata, no role', () async {
      // 'resep' appears ONLY in s1's title.
      final List<ChatSearchHit> hits = await store.searchAll('resep');
      expect(hits, hasLength(1));
      expect(hits.single.sessionId, 's1');
      expect(hits.single.title, 'Resep kue cokelat');
      expect(hits.single.role, isNull, reason: 'title hits carry no role');
      expect(hits.single.snippet, isNotEmpty);
    });

    test('content match returns a snippet around the first hit', () async {
      // 'kapan' appears ONLY in s2's message content (title is different).
      final List<ChatSearchHit> hits = await store.searchAll('kapan');
      expect(hits, hasLength(1));
      expect(hits.single.sessionId, 's2');
      expect(hits.single.role, Role.user);
      expect(hits.single.snippet.toLowerCase(), contains('kapan'));
      // ~120 chars around the match, not the whole world.
      expect(hits.single.snippet.length, lessThan(140));
    });

    test('matching is case-insensitive in both directions', () async {
      // Query uppercase, content lowercase.
      final List<ChatSearchHit> upper = await store.searchAll('TERBARU KELUAR');
      expect(upper.single.sessionId, 's2');
      // Query lowercase, content uppercase.
      final List<ChatSearchHit> lower = await store.searchAll('panggang');
      expect(lower.single.sessionId, 's1');
    });

    test('no match returns an empty list; blank query too', () async {
      expect(await store.searchAll('quantum-flux-nonsense'), isEmpty);
      expect(await store.searchAll('   '), isEmpty);
    });

    test('corrupted files are skipped, not thrown', () async {
      final List<ChatSearchHit> hits = await store.searchAll('rapat');
      expect(hits, hasLength(1));
      expect(hits.single.sessionId, 's3');
    });

    test('title matches sort before content matches', () async {
      // Session A matches by TITLE, session B only by message content —
      // the same query 'zebra' must list the title hit first.
      await _writeSession(
        tempDir,
        'sA',
        title: 'Zebra spesial ulang tahun',
        messages: <Map<String, dynamic>>[_userJson('tolong dibantu')],
      );
      await _writeSession(
        tempDir,
        'sB',
        title: 'Pembahasan arsitektur',
        messages: <Map<String, dynamic>>[_userJson('hewan zebra apa terbaik?')],
      );
      final List<ChatSearchHit> hits = await store.searchAll('zebra');
      expect(hits, hasLength(2));
      expect(hits.first.sessionId, 'sA', reason: 'title hit ranks first');
      expect(hits.last.sessionId, 'sB');
      expect(hits.last.role, Role.user);
    });

    test('limit caps the result count', () async {
      await _writeSession(
        tempDir,
        'sA',
        title: 'Zebra spesial ulang tahun',
        messages: <Map<String, dynamic>>[_userJson('tolong dibantu')],
      );
      await _writeSession(
        tempDir,
        'sB',
        title: 'Pembahasan arsitektur',
        messages: <Map<String, dynamic>>[_userJson('hewan zebra apa terbaik?')],
      );
      final List<ChatSearchHit> hits = await store.searchAll('zebra', limit: 1);
      expect(hits, hasLength(1));
      expect(hits.single.sessionId, 'sA');
    });

    test('a session yields at most two hits (title + first message)', () async {
      await _writeSession(
        tempDir,
        's4',
        title: 'berulang berulang',
        messages: <Map<String, dynamic>>[
          _userJson('berulang satu'),
          _userJson('berulang dua'),
        ],
      );
      final List<ChatSearchHit> hits = await store.searchAll('berulang');
      expect(hits, hasLength(2));
      expect(
        hits.where((h) => h.sessionId == 's4'),
        hasLength(2),
        reason: 'one title hit + one (first) message hit',
      );
    });
  });

  group('isolate offload (v1.28.0 ANR hardening)', () {
    test(
      'a multi-megabyte session roundtrips through save/load/list',
      () async {
        // ~1.5 MB of message text: the JSON decode/encode of this payload
        // runs inside Isolate.run — the test doubles as a correctness check
        // for the isolate boundary (all data must survive the hop).
        final List<ChatMessage> big = <ChatMessage>[
          for (var i = 0; i < 400; i++)
            ChatMessage.assistant(
              'baris $i — ${'lorem ipsum dolor sit amet ' * 120}',
            ),
        ];
        await store.save(id: 'big-1', title: 'besar', messages: big);

        final List<ChatMessage>? loaded = await store.load('big-1');
        expect(loaded, hasLength(400));
        expect(loaded!.last.content, contains('baris 399'));

        final List<ChatSummary> summaries = await store.listSummaries();
        expect(summaries.single.id, 'big-1');

        final List<ChatSearchHit> hits = await store.searchAll('baris 399');
        expect(hits, isNotEmpty);
        expect(hits.first.sessionId, 'big-1');
      },
    );

    test('listSummaries skips corrupted files in big folders', () async {
      await _writeSession(
        tempDir,
        'ok-1',
        title: 'sehat',
        messages: [_userJson('halo')],
      );
      final Directory dir = Directory('${tempDir.path}/chats');
      await File('${dir.path}/broken.json').writeAsString('{not json');

      final List<ChatSummary> summaries = await store.listSummaries();
      expect(summaries, hasLength(1));
      expect(summaries.single.title, 'sehat');
    });
  });

  group('waiting-for-setup flag (v1.29.0)', () {
    test(
      'save persists the flag and loadWaitingForSetup reads it back',
      () async {
        await store.save(
          id: 'waiting-1',
          title: 't',
          messages: [ChatMessage.user('queued')],
          waitingForSetup: true,
        );
        expect(await store.loadWaitingForSetup('waiting-1'), isTrue);
        // Default is false when the flag is omitted.
        await store.save(
          id: 'waiting-2',
          title: 't',
          messages: [ChatMessage.user('normal')],
        );
        expect(await store.loadWaitingForSetup('waiting-2'), isFalse);
      },
    );

    test(
      'loadWaitingForSetup defaults to false for unknown/corrupt ids',
      () async {
        expect(await store.loadWaitingForSetup('missing'), isFalse);
        final Directory dir = Directory('${tempDir.path}/chats');
        await File('${dir.path}/broken.json').writeAsString('{not json');
        expect(await store.loadWaitingForSetup('broken'), isFalse);
      },
    );
  });

  group('todo plan persistence (v1.35.0 crash recovery)', () {
    test('save persists the plan and loadTodos reads it back', () async {
      const List<TodoItem> plan = <TodoItem>[
        TodoItem(content: 'research topic', status: TodoStatus.completed),
        TodoItem(content: 'draft report', status: TodoStatus.inProgress),
        TodoItem(content: 'review output', status: TodoStatus.pending),
      ];
      await store.save(
        id: 'plan-1',
        title: 't',
        messages: [ChatMessage.user('kerja')],
        todos: plan,
      );
      final List<TodoItem> loaded = await store.loadTodos('plan-1');
      expect(loaded, hasLength(3));
      expect(loaded[0].content, 'research topic');
      expect(loaded[0].status, TodoStatus.completed);
      expect(loaded[1].status, TodoStatus.inProgress);
      expect(loaded[2].status, TodoStatus.pending);
    });

    test(
      'saving without todos keeps loadTodos empty (overwrites stale)',
      () async {
        await store.save(
          id: 'plan-2',
          title: 't',
          messages: [ChatMessage.user('a')],
          todos: const [TodoItem(content: 'old plan')],
        );
        expect(await store.loadTodos('plan-2'), hasLength(1));
        // A later save without a plan (fresh run) must clear the stale one.
        await store.save(
          id: 'plan-2',
          title: 't',
          messages: [ChatMessage.user('b')],
        );
        expect(await store.loadTodos('plan-2'), isEmpty);
      },
    );

    test('loadTodos is empty for unknown ids and legacy sessions', () async {
      expect(await store.loadTodos('missing'), isEmpty);
      // A session written by an older app version has no 'todos' key.
      await _writeSession(
        tempDir,
        'legacy-1',
        title: 'lama',
        messages: [_userJson('halo')],
      );
      expect(await store.loadTodos('legacy-1'), isEmpty);
    });

    test('loadTodos skips malformed entries defensively', () async {
      final Directory dir = Directory('${tempDir.path}/chats')
        ..createSync(recursive: true);
      await File('${dir.path}/loose.json').writeAsString(
        jsonEncode(<String, dynamic>{
          'id': 'loose',
          'title': 't',
          'messages': <Object>[],
          'todos': <Object>[
            <String, dynamic>{'content': 'valid one', 'status': 'pending'},
            <String, dynamic>{'content': '   '}, // blank → dropped
            <String, dynamic>{'nope': true}, // malformed → dropped
            'just a string', // junk → dropped
          ],
        }),
      );
      final List<TodoItem> loaded = await store.loadTodos('loose');
      expect(loaded, hasLength(1));
      expect(loaded.single.content, 'valid one');
    });

    test('loadTodos survives a corrupted session file', () async {
      final Directory dir = Directory('${tempDir.path}/chats')
        ..createSync(recursive: true);
      await File('${dir.path}/broken.json').writeAsString('{not json');
      expect(await store.loadTodos('broken'), isEmpty);
    });
  });

  group('atomic writes & per-chat serialization (v1.40.0)', () {
    // No isolate offload: these tests exercise the write LOCK, and isolate
    // scheduling would make the call order nondeterministic.
    late ChatStore local;
    setUp(() {
      local = ChatStore(
        resolveBaseDir: () async => tempDir,
        offloadIsolate: false,
      );
    });

    test('loadTitle reads the stored title', () async {
      await local.save(
        id: 's1',
        title: 'Resep kue',
        messages: <ChatMessage>[ChatMessage.user('halo')],
      );
      expect(await local.loadTitle('s1'), 'Resep kue');
      expect(await local.loadTitle('missing'), '');
    });

    test('save leaves no temp file behind', () async {
      await local.save(
        id: 's1',
        title: 'A',
        messages: <ChatMessage>[ChatMessage.user('one')],
      );
      await local.save(
        id: 's1',
        title: 'A',
        messages: <ChatMessage>[
          ChatMessage.user('one'),
          ChatMessage.user('two'),
        ],
      );
      final List<String> files = Directory('${tempDir.path}/chats')
          .listSync()
          .map((FileSystemEntity e) => e.path)
          .toList();
      expect(
        files.where((String p) => p.endsWith('.tmp')),
        isEmpty,
        reason: 'the temp file must be renamed onto the session file',
      );
      expect((await local.load('s1'))!.length, 2);
    });

    test(
      'a rename queued behind a save cannot revert the transcript',
      () async {
        await local.save(
          id: 's1',
          title: 'old title',
          messages: <ChatMessage>[ChatMessage.user('one')],
        );

        // Both touch the same JSON file: rename is a read-modify-write and
        // used to decode the file BEFORE the save landed, then write the old
        // transcript back over it.
        final Future<void> saving = local.save(
          id: 's1',
          title: 'old title',
          messages: <ChatMessage>[
            ChatMessage.user('one'),
            ChatMessage.user('two'),
            ChatMessage.user('three'),
          ],
        );
        final Future<void> renaming = local.rename('s1', 'new title');
        await Future.wait<void>(<Future<void>>[saving, renaming]);

        final List<ChatMessage>? loaded = await local.load('s1');
        expect(loaded!.map((ChatMessage m) => m.content), <String>[
          'one',
          'two',
          'three',
        ], reason: 'the save must not be undone by the interleaved rename');
        expect(await local.loadTitle('s1'), 'new title');
      },
    );

    test('concurrent saves for one chat apply in call order', () async {
      final List<Future<void>> saves = <Future<void>>[
        for (int i = 0; i < 5; i++)
          local.save(
            id: 's1',
            title: 'v$i',
            messages: <ChatMessage>[
              for (int m = 0; m <= i; m++) ChatMessage.user('msg$m'),
            ],
          ),
      ];
      await Future.wait<void>(saves);

      final List<ChatMessage>? loaded = await local.load('s1');
      expect(loaded!.map((ChatMessage m) => m.content), <String>[
        'msg0',
        'msg1',
        'msg2',
        'msg3',
        'msg4',
      ], reason: 'the last queued save owns the final file contents');
      expect(await local.loadTitle('s1'), 'v4');
    });

    test('saveModules cannot clobber a concurrent transcript save', () async {
      await local.save(
        id: 's1',
        title: 't',
        messages: <ChatMessage>[ChatMessage.user('one')],
      );
      final Future<void> saving = local.save(
        id: 's1',
        title: 't',
        messages: <ChatMessage>[
          ChatMessage.user('one'),
          ChatMessage.user('two'),
        ],
      );
      final Future<void> modules = local.saveModules('s1', <String>[
        'plugin-a',
      ]);
      await Future.wait<void>(<Future<void>>[saving, modules]);

      final List<ChatMessage>? loaded = await local.load('s1');
      expect(loaded!.length, 2);
      expect(await local.loadModules('s1'), <String>['plugin-a']);
    });

    test('delete queued behind a save removes the file', () async {
      await local.save(
        id: 's1',
        title: 't',
        messages: <ChatMessage>[ChatMessage.user('one')],
      );
      final Future<void> saving = local.save(
        id: 's1',
        title: 't',
        messages: <ChatMessage>[
          ChatMessage.user('one'),
          ChatMessage.user('two'),
        ],
      );
      final Future<void> deleting = local.delete('s1');
      await Future.wait<void>(<Future<void>>[saving, deleting]);

      expect(await local.load('s1'), isNull);
    });
  });
}
