import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/di.dart';
import 'package:noah/models/local_model.dart';
import 'package:noah/services/local_ai/local_model_io.dart';
import 'package:noah/services/local_ai/local_model_store.dart';

LocalModelEntry _entry(String id, {String name = 'Model'}) => LocalModelEntry(
  id: id,
  name: name,
  source: LocalModelSource.imported,
  fileName: '$id.gguf',
  addedAtMs: 5,
);

void main() {
  group('MemoryLocalModelRepository', () {
    test('roundtrips the whole state through save/load', () async {
      final MemoryLocalModelRepository repo = MemoryLocalModelRepository();
      final LocalModelState state = LocalModelState(
        installed: <LocalModelEntry>[_entry('a')],
        serverPort: 1234,
        contextSize: 4096,
        threads: 2,
        autoStartOnBoot: true,
      );
      await repo.save(state);

      final LocalModelState reloaded = repo.load();
      expect(reloaded.installed.single.id, 'a');
      expect(reloaded.serverPort, 1234);
      expect(reloaded.contextSize, 4096);
      expect(reloaded.threads, 2);
      expect(reloaded.autoStartOnBoot, isTrue);
    });

    test('starts from an optional seed', () {
      final MemoryLocalModelRepository repo = MemoryLocalModelRepository(
        LocalModelState(serverPort: 7),
      );
      expect(repo.load().serverPort, 7);
    });
  });

  group('PrefsLocalModelRepository', () {
    test('empty store loads contract defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final PrefsLocalModelRepository repo =
          await PrefsLocalModelRepository.create();

      final LocalModelState state = repo.load();
      expect(state.installed, isEmpty);
      expect(state.serverPort, 11434);
      expect(state.contextSize, 2048);
      expect(state.threads, 0);
      expect(state.autoStartOnBoot, isFalse);
    });

    test('save → load roundtrip keeps entries and config', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final PrefsLocalModelRepository repo =
          await PrefsLocalModelRepository.create();

      await repo.save(
        LocalModelState(
          installed: <LocalModelEntry>[
            _entry('x', name: 'Qwen3'),
            const LocalModelEntry(
              id: 'y',
              name: 'Custom',
              source: LocalModelSource.customUrl,
              customUrl: 'https://example.test/m.gguf',
              fileName: 'y.gguf',
              sizeBytes: 10,
              sha256: 'ab',
              addedAtMs: 6,
              lastUsedAtMs: 9,
            ),
          ],
          serverPort: 8080,
          contextSize: 8192,
          threads: 4,
          autoStartOnBoot: true,
        ),
      );

      final LocalModelState reloaded = repo.load();
      expect(reloaded.installed, hasLength(2));
      expect(reloaded.installed.first.name, 'Qwen3');
      expect(reloaded.installed.last.source, LocalModelSource.customUrl);
      expect(reloaded.installed.last.customUrl, 'https://example.test/m.gguf');
      expect(reloaded.installed.last.lastUsedAtMs, 9);
      expect(reloaded.serverPort, 8080);
      expect(reloaded.contextSize, 8192);
      expect(reloaded.threads, 4);
      expect(reloaded.autoStartOnBoot, isTrue);
    });

    test('corrupted JSON degrades to defaults instead of crashing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'noah.localai.v1': '{not json',
      });
      final PrefsLocalModelRepository repo =
          await PrefsLocalModelRepository.create();

      expect(repo.load().installed, isEmpty);
    });

    test('a non-map JSON payload also degrades to defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'noah.localai.v1': '[1,2,3]',
      });
      final PrefsLocalModelRepository repo =
          await PrefsLocalModelRepository.create();

      expect(repo.load().installed, isEmpty);
    });

    test('legacy store without config keys falls back to defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'noah.localai.v1':
            '{"installed":[{"id":"old","name":"Old","fileName":"old.gguf",'
            '"addedAtMs":9}]}',
      });
      final PrefsLocalModelRepository repo =
          await PrefsLocalModelRepository.create();

      final LocalModelState state = repo.load();
      expect(state.installed.single.id, 'old');
      expect(state.installed.single.source, LocalModelSource.imported);
      expect(state.serverPort, 11434);
      expect(state.contextSize, 2048);
      expect(state.threads, 0);
      expect(state.autoStartOnBoot, isFalse);
    });
  });

  group('LocalModelsController', () {
    late Directory tempDir;
    late MemoryLocalModelRepository repo;
    late ProviderContainer container;
    late LocalModelsController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('noah-store-');
      repo = MemoryLocalModelRepository();
      container = ProviderContainer(
        overrides: <Override>[
          localModelRepositoryProvider.overrideWithValue(repo),
          localModelIoProvider.overrideWithValue(
            LocalModelIo(modelsDir: tempDir),
          ),
        ],
      );
      controller = container.read(localModelsProvider.notifier);
    });

    tearDown(() async {
      container.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Already removed by the test itself.
      }
    });

    String p(String name) => '${tempDir.path}${Platform.pathSeparator}$name';

    test('addInstalled persists and replaces by id (no duplicates)', () async {
      await controller.addInstalled(_entry('a'));
      await controller.addInstalled(_entry('b', name: 'B'));
      await controller.addInstalled(_entry('a', name: 'A2'));

      expect(
        container.read(localModelsProvider).installed.map((e) => e.id),
        <String>['a', 'b'],
      );
      expect(repo.load().installed, hasLength(2));
      expect(repo.load().installed.first.name, 'A2');
    });

    test(
      'removeInstalled drops the row AND deletes the backing file',
      () async {
        File(p('a.gguf')).writeAsStringSync('gguf-bytes');
        await controller.addInstalled(_entry('a'));

        await controller.removeInstalled('a');

        expect(container.read(localModelsProvider).installed, isEmpty);
        expect(repo.load().installed, isEmpty);
        expect(await File(p('a.gguf')).exists(), isFalse);
      },
    );

    test('removeInstalled survives a missing file', () async {
      await controller.addInstalled(_entry('ghost'));

      await controller.removeInstalled('ghost');

      expect(container.read(localModelsProvider).installed, isEmpty);
    });

    test('markUsed stamps lastUsedAtMs', () async {
      await controller.addInstalled(_entry('a'));

      await controller.markUsed('a');

      final int? used = repo.load().installed.single.lastUsedAtMs;
      expect(used, isNotNull);
      expect(used, greaterThan(0));
    });

    test('setServerConfig and setAutoStartOnBoot persist', () async {
      await controller.setServerConfig(port: 1234, contextSize: 8192);
      await controller.setServerConfig(threads: 6);
      await controller.setAutoStartOnBoot(true);

      final LocalModelState state = repo.load();
      expect(state.serverPort, 1234);
      expect(state.contextSize, 8192);
      expect(state.threads, 6);
      expect(state.autoStartOnBoot, isTrue);
    });

    test('setServerConfig keeps untouched fields', () async {
      await controller.setServerConfig(port: 999);
      await controller.setServerConfig(threads: 3);

      final LocalModelState state = repo.load();
      expect(state.serverPort, 999);
      expect(state.contextSize, 2048);
      expect(state.threads, 3);
    });
  });
}
