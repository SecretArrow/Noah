import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/chat_store.dart';
import 'package:noah/services/session_export.dart';

void main() {
  late Directory tempDir;
  late ChatStore store;
  late SessionExporter exporter;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_export_test');
    store = ChatStore(resolveBaseDir: () async => tempDir);
    exporter = SessionExporter(
      store: store,
      resolveBaseDir: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('export writes a JSON file containing all sessions', () async {
    await store.save(
      id: 's1',
      title: 'First',
      messages: <ChatMessage>[ChatMessage.user('hi')],
    );
    await store.save(
      id: 's2',
      title: 'Second',
      messages: <ChatMessage>[
        ChatMessage.user('q'),
        ChatMessage.assistant('a'),
      ],
    );

    final File file = await exporter.exportAll();
    expect(await file.exists(), isTrue);
    expect(file.path, contains('exports'));
    expect(file.path, endsWith('.json'));

    final Object? decoded = jsonDecode(await file.readAsString());
    expect(decoded, isA<Map>());
    final Map<String, dynamic> map = decoded! as Map<String, dynamic>;
    expect(map['app'], 'Noah');
    expect((map['sessions'] as List).length, 2);
  });

  test(
    'import restores sessions under NEW ids and returns the count',
    () async {
      await store.save(
        id: 's1',
        title: 'First',
        messages: <ChatMessage>[ChatMessage.user('hi')],
      );
      final File file = await exporter.exportAll();
      final String exportedJson = await file.readAsString();

      // Simulate a fresh device: wipe the store.
      final Directory chats = Directory('${tempDir.path}/chats');
      await chats.delete(recursive: true);

      // Write the export payload to a standalone file (like a picked file).
      final File importFile = File('${tempDir.path}/picked.json');
      await importFile.writeAsString(exportedJson);

      final int count = await exporter.importFrom(importFile.path);
      expect(count, 1);

      final List<ChatSummary> summaries = await store.listSummaries();
      expect(summaries, hasLength(1));
      expect(summaries.single.title, 'First');
      // New id, not the old one.
      expect(summaries.single.id, isNot('s1'));
      final List<ChatMessage>? messages = await store.load(summaries.single.id);
      expect(messages, isNotNull);
      expect(messages!.first.content, 'hi');
    },
  );

  test('import rejects files that are not session exports', () async {
    final File bad = File('${tempDir.path}/bad.json');
    await bad.writeAsString(jsonEncode(<String, dynamic>{'hello': 1}));
    expect(
      () => exporter.importFrom(bad.path),
      throwsA(isA<FormatException>()),
    );
  });

  test('import skips malformed session entries without dying', () async {
    final File file = File('${tempDir.path}/mixed.json');
    await file.writeAsString(
      jsonEncode(<String, dynamic>{
        'app': 'Noah',
        'format': 1,
        'sessions': <dynamic>[
          <String, dynamic>{
            'title': 'Good',
            'messages': <dynamic>[
              <String, dynamic>{
                'role': 'user',
                'content': 'works',
                'createdAt': DateTime.now().toIso8601String(),
              },
            ],
          },
          <String, dynamic>{'title': 'No messages'},
          'not even an object',
        ],
      }),
    );
    final int count = await exporter.importFrom(file.path);
    expect(count, 1);
  });
}
