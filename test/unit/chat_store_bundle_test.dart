import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/chat_store.dart';

/// v1.38.1 — SessionBundle round-trip: ONE decode must restore messages,
/// active modules, the setup-wait flag and the latest plan together.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_bundle_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ChatStore store() =>
      ChatStore(resolveBaseDir: () async => tempDir, offloadIsolate: false);

  test('loadBundle restores everything from a single read', () async {
    final ChatStore st = store();
    const String id = 'session-bundle-1';
    await st.save(
      id: id,
      title: 'Bundle test',
      messages: <ChatMessage>[
        ChatMessage.user('halo'),
        ChatMessage.assistant('halo juga'),
      ],
      modules: <String>['onhomeroom-daily', 'counter'],
      waitingForSetup: true,
      todos: const <TodoItem>[
        TodoItem(content: 'step one', status: TodoStatus.completed),
        TodoItem(content: 'step two', status: TodoStatus.inProgress),
      ],
    );

    final SessionBundle? bundle = await st.loadBundle(id);
    expect(bundle, isNotNull);
    expect(bundle!.messages, hasLength(2));
    expect(bundle.messages.first.role, Role.user);
    expect(bundle.messages.first.content, 'halo');
    expect(bundle.messages.last.content, 'halo juga');
    expect(bundle.modules, <String>['onhomeroom-daily', 'counter']);
    expect(bundle.waitingForSetup, isTrue);
    expect(bundle.todos, hasLength(2));
    expect(bundle.todos.first.status, TodoStatus.completed);
    expect(bundle.todos.last.status, TodoStatus.inProgress);
  });

  test('loadBundle of a missing session yields null', () async {
    final SessionBundle? bundle = await store().loadBundle('does-not-exist');
    expect(bundle, isNull);
  });

  test('loadBundle tolerates a corrupted file', () async {
    final Directory chats = Directory('${tempDir.path}/chats');
    chats.createSync(recursive: true);
    File('${chats.path}/broken.json').writeAsStringSync('{not json');
    final SessionBundle? bundle = await store().loadBundle('broken');
    expect(bundle, isNull);
  });

  test(
    'loadBundle of a session saved without extras yields defaults',
    () async {
      final ChatStore st = store();
      const String id = 'session-bundle-2';
      await st.save(
        id: id,
        title: 'Minimal',
        messages: <ChatMessage>[ChatMessage.user('ping')],
      );
      final SessionBundle? bundle = await st.loadBundle(id);
      expect(bundle, isNotNull);
      expect(bundle!.messages, hasLength(1));
      expect(bundle.modules, isEmpty);
      expect(bundle.skills, isEmpty);
      expect(bundle.waitingForSetup, isFalse);
      expect(bundle.todos, isEmpty);
    },
  );

  // -- v1.49.0 (wave-2): per-chat pinned skills ---------------------------

  test('skills round-trip through save → loadBundle', () async {
    final ChatStore st = store();
    const String id = 'session-skills-1';
    await st.save(
      id: id,
      title: 'Skills test',
      messages: <ChatMessage>[ChatMessage.user('hi')],
      skills: <String>['web3-wallet-basics', 'binance-agentic-wallet'],
    );
    final SessionBundle? bundle = await st.loadBundle(id);
    expect(bundle, isNotNull);
    expect(bundle!.skills, <String>[
      'web3-wallet-basics',
      'binance-agentic-wallet',
    ]);
    // Re-saving with a DIFFERENT selection replaces it (apply = replace).
    await st.save(
      id: id,
      title: 'Skills test',
      messages: <ChatMessage>[ChatMessage.user('hi')],
      skills: <String>['web3-wallet-basics'],
    );
    final SessionBundle? updated = await st.loadBundle(id);
    expect(updated!.skills, <String>['web3-wallet-basics']);
  });

  test(
    'a stored file without the skills key loads empty (legacy tolerant)',
    () async {
      final ChatStore st = store();
      const String id = 'session-skills-legacy';
      await st.save(
        id: id,
        title: 'Legacy',
        messages: <ChatMessage>[ChatMessage.user('hi')],
      );
      // Rewrite the payload WITHOUT the skills key, exactly like a transcript
      // written by an older app version.
      final File file = File('${tempDir.path}/chats/$id.json');
      final dynamic decoded = const JsonDecoder().convert(
        file.readAsStringSync(),
      );
      (decoded as Map<String, dynamic>).remove('skills');
      file.writeAsStringSync(jsonEncode(decoded));
      final SessionBundle? bundle = await st.loadBundle(id);
      expect(bundle, isNotNull);
      expect(bundle!.skills, isEmpty);
      expect(bundle.messages, hasLength(1));
    },
  );
}
