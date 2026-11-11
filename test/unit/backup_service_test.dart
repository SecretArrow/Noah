import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/backup_service.dart';
import 'package:noah/services/chat_store.dart';
import 'package:noah/services/context_repository.dart';
import 'package:noah/services/settings_repository.dart';
import 'package:noah/services/session_export.dart';
import 'package:noah/services/token_stats.dart';

void main() {
  late Directory tempDir;
  late ChatStore store;
  late MemorySettingsRepository settings;
  late MemoryContextRepository context;
  late BackupService backup;
  late SessionExporter exporter;
  late TokenStatsService stats;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_backup_test');
    store = ChatStore(resolveBaseDir: () async => tempDir);
    settings = MemorySettingsRepository();
    context = MemoryContextRepository();
    backup = BackupService(
      store: store,
      settingsRepository: settings,
      contextRepository: context,
      resolveBaseDir: () async => tempDir,
    );
    exporter = SessionExporter(
      store: store,
      resolveBaseDir: () async => tempDir,
    );
    stats = TokenStatsService(store: store);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ChatMessage assistantWithUsage(String content, String model, int p, int c) =>
      ChatMessage.assistant(
        content,
        model: model,
        usage: TokenUsage(promptTokens: p, completionTokens: c),
      );

  group('encrypted backup (.zabak)', () {
    test(
      'create writes a magic-prefixed file; restore replaces all state',
      () async {
        await store.save(
          id: 's1',
          title: 'Old chat',
          messages: <ChatMessage>[ChatMessage.user('old')],
        );
        await context.save(<ContextEntry>[
          const ContextEntry(id: 'c1', name: 'N', content: 'C'),
        ]);

        final File file = await backup.createBackup(
          passphrase: 'correct horse battery',
          saltOverride: Uint8List.fromList(List<int>.filled(16, 7)),
        );
        expect(file.existsSync(), isTrue);
        final List<String> lines = file.readAsLinesSync();
        expect(lines.first, 'ZABAK1');
        expect(lines[1].length, greaterThan(100));

        // Mutate state after the backup so restore has something to replace.
        await store.save(
          id: 's2',
          title: 'Later chat',
          messages: <ChatMessage>[ChatMessage.user('new')],
        );
        await store.delete('s1');
        await context.save(<ContextEntry>[]);

        final BackupRestoreResult result = await backup.restore(
          file.path,
          passphrase: 'correct horse battery',
        );
        expect(result.sessions, 1);
        expect(result.settingsApplied, isTrue);
        expect(result.contextEntries, 1);

        final List<ChatSummary> summaries = await store.listSummaries();
        expect(summaries.map((ChatSummary s) => s.id), <String>['s1']);
        expect(summaries.first.title, 'Old chat');
      },
    );

    test('wrong passphrase throws BackupAuthException', () async {
      await store.save(
        id: 's1',
        title: 'Secret',
        messages: <ChatMessage>[ChatMessage.user('x')],
      );
      final File file = await backup.createBackup(passphrase: 'right-pass-1');
      await expectLater(
        backup.restore(file.path, passphrase: 'wrong-pass-1'),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('tampered ciphertext is rejected before decryption', () async {
      await store.save(
        id: 's1',
        title: 'T',
        messages: <ChatMessage>[ChatMessage.user('x')],
      );
      final File file = await backup.createBackup(passphrase: 'right-pass-1');
      final List<String> lines = file.readAsLinesSync();
      final Uint8List body = base64Decode(lines[1]);
      body[20 + 5] ^= 0xFF; // flip a byte inside the ciphertext region
      final File tampered = File(
        '${file.parent.path}${Platform.pathSeparator}tampered.zabak',
      );
      await tampered.writeAsString('${lines.first}\n${base64Encode(body)}\n');
      await expectLater(
        backup.restore(tampered.path, passphrase: 'right-pass-1'),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('non-backup file is rejected with BackupFormatException', () async {
      final File junk = File(
        '${tempDir.path}${Platform.pathSeparator}junk.zabak',
      );
      await junk.writeAsString('hello world\n');
      await expectLater(
        backup.restore(junk.path, passphrase: 'whatever-pass'),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('token statistics', () {
    test('aggregates usage per model and skips turns without usage', () async {
      await store.save(
        id: 's1',
        title: 'Chat',
        messages: <ChatMessage>[
          ChatMessage.user('hi'),
          assistantWithUsage('a', 'model-a', 10, 5),
          assistantWithUsage('b', 'model-a', 20, 8),
          ChatMessage.assistant('no-usage-here'),
        ],
      );
      await store.save(
        id: 's2',
        title: 'Chat 2',
        messages: <ChatMessage>[
          ChatMessage.user('q'),
          assistantWithUsage('c', 'model-b', 100, 50),
        ],
      );

      final TokenStatsResult result = await stats.compute();
      expect(result.sessions, 2);
      expect(result.assistantTurns, 4);
      expect(result.turnsWithUsage, 3);
      expect(result.promptTokens, 130);
      expect(result.completionTokens, 63);
      expect(result.totalTokens, 193);
      expect(result.perModel.first.model, 'model-b');
      expect(result.perModel.first.totalTokens, 150);
      expect(result.perModel.last.model, 'model-a');
      expect(result.perModel.last.totalTokens, 43);
    });

    test('empty store produces zeroed stats', () async {
      final TokenStatsResult result = await stats.compute();
      expect(result.sessions, 0);
      expect(result.totalTokens, 0);
      expect(result.perModel, isEmpty);
    });
  });

  group('markdown export', () {
    test('writes a readable Markdown file for one session', () async {
      await store.save(
        id: 's1',
        title: 'Riset & "Laporan"',
        messages: <ChatMessage>[
          ChatMessage.user('Tolong riset X'),
          assistantWithUsage('Berikut hasilnya.', 'glm-4.6', 12, 30),
        ],
      );

      final File? file = await exporter.exportMarkdown('s1');
      expect(file, isNotNull);
      final String md = file!.readAsStringSync();
      expect(md.startsWith('# Riset & "Laporan"'), isTrue);
      expect(md, contains('**You**'));
      expect(md, contains('Tolong riset X'));
      expect(md, contains('**glm-4.6**'));
      expect(md, contains('Berikut hasilnya.'));
      expect(md, contains('Exported from Noah'));
      expect(md, contains('2 messages'));
    });

    test('unknown session id returns null', () async {
      expect(await exporter.exportMarkdown('missing'), isNull);
    });
  });

  group('usage persistence on ChatMessage', () {
    test('model + usage survive a JSON roundtrip (backward compatible)', () {
      final ChatMessage withUsage = assistantWithUsage('a', 'm1', 3, 4);
      final ChatMessage restored = ChatMessage.fromJson(withUsage.toJson());
      expect(restored.model, 'm1');
      expect(restored.usage!.totalTokens, 7);

      // Legacy messages (no usage/model) keep parsing cleanly.
      final Map<String, dynamic> legacy = ChatMessage.assistant('old').toJson()
        ..remove('model');
      final ChatMessage parsed = ChatMessage.fromJson(legacy);
      expect(parsed.model, isNull);
      expect(parsed.usage, isNull);
    });
  });
}
