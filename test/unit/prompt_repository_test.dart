import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/prompt_repository.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_prompt_repo');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('PromptRepository (v1.15.0)', () {
    test('file-backed CRUD roundtrip persists across instances', () async {
      final FilePromptRepository first = FilePromptRepository(
        resolveBaseDir: () async => tempDir,
      );
      // Seeded empty.
      expect(await first.load(), isEmpty);

      final PromptEntry entry = PromptEntry(
        id: 'p1',
        title: 'Code review',
        content: 'Review this code for bugs and style issues.',
        createdAt: DateTime(2025, 5, 1),
      );
      await first.save(<PromptEntry>[entry]);
      expect(await first.load(), hasLength(1));

      // A NEW repository instance (fresh cache) reads the same file.
      final FilePromptRepository second = FilePromptRepository(
        resolveBaseDir: () async => tempDir,
      );
      final List<PromptEntry> loaded = await second.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'p1');
      expect(loaded.single.title, 'Code review');
      expect(
        loaded.single.content,
        'Review this code for bugs and style issues.',
      );
      expect(loaded.single.createdAt, DateTime(2025, 5, 1));

      // Update (overwrite) then delete (save without the entry).
      await second.save(<PromptEntry>[
        PromptEntry(
          id: entry.id,
          title: 'Code review (v2)',
          content: entry.content,
          createdAt: entry.createdAt,
        ),
      ]);
      expect((await second.load()).single.title, 'Code review (v2)');

      await second.save(<PromptEntry>[]);
      expect(await second.load(), isEmpty);
    });

    test('corrupted store degrades to an empty library', () async {
      await File('${tempDir.path}${Platform.pathSeparator}prompts.json')
          .writeAsString('{definitely not json');
      final FilePromptRepository repo = FilePromptRepository(
        resolveBaseDir: () async => tempDir,
      );
      expect(await repo.load(), isEmpty);
    });

    test('memory repository roundtrip (used by widget tests)', () async {
      final MemoryPromptRepository repo = MemoryPromptRepository();
      expect(await repo.load(), isEmpty);
      await repo.save(<PromptEntry>[
        PromptEntry(
          id: 'x',
          title: 'T',
          content: 'C',
          createdAt: DateTime.now(),
        ),
      ]);
      expect((await repo.load()).single.title, 'T');
    });

    test('PromptEntry.fromJson clamps oversized content', () {
      final String big = 'a' * (PromptEntry.maxContentLength + 500);
      final PromptEntry decoded = PromptEntry.fromJson(<String, dynamic>{
        'id': 'p',
        'title': 'Big',
        'content': big,
        'createdAt': '2025-01-01T00:00:00.000',
      });
      expect(decoded.content.length, PromptEntry.maxContentLength);
    });
  });
}
