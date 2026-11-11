import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/local_model.dart';
import 'package:noah/services/local_ai/model_catalog_data.dart';

LocalModelEntry _entry() => const LocalModelEntry(
  id: 'm-1',
  name: 'Qwen3 0.6B',
  source: LocalModelSource.catalog,
  ollamaRef: 'qwen3:0.6b',
  fileName: 'm-1.gguf',
  sizeBytes: 548407808,
  sha256: 'aa11',
  addedAtMs: 42,
  lastUsedAtMs: 99,
);

void main() {
  group('localModelSourceFromName', () {
    test('maps every wire name', () {
      expect(localModelSourceFromName('catalog'), LocalModelSource.catalog);
      expect(localModelSourceFromName('customUrl'), LocalModelSource.customUrl);
      expect(localModelSourceFromName('imported'), LocalModelSource.imported);
    });

    test('unknown and null spellings fall back to imported', () {
      expect(localModelSourceFromName('bogus'), LocalModelSource.imported);
      expect(localModelSourceFromName(null), LocalModelSource.imported);
      expect(localModelSourceFromName(''), LocalModelSource.imported);
    });
  });

  group('LocalModelEntry json roundtrip', () {
    test('survives toJson → fromJson with every field', () {
      final LocalModelEntry restored = LocalModelEntry.fromJson(
        _entry().toJson(),
      );
      expect(restored.id, 'm-1');
      expect(restored.name, 'Qwen3 0.6B');
      expect(restored.source, LocalModelSource.catalog);
      expect(restored.ollamaRef, 'qwen3:0.6b');
      expect(restored.customUrl, '');
      expect(restored.fileName, 'm-1.gguf');
      expect(restored.sizeBytes, 548407808);
      expect(restored.sha256, 'aa11');
      expect(restored.addedAtMs, 42);
      expect(restored.lastUsedAtMs, 99);
    });

    test('tolerant fromJson: missing keys degrade to defaults', () {
      final LocalModelEntry restored = LocalModelEntry.fromJson(
        <String, dynamic>{'id': 'x'},
      );
      expect(restored.id, 'x');
      expect(restored.name, '');
      expect(restored.source, LocalModelSource.imported);
      expect(restored.ollamaRef, '');
      expect(restored.customUrl, '');
      expect(restored.fileName, '');
      expect(restored.sizeBytes, 0);
      expect(restored.sha256, '');
      expect(restored.addedAtMs, 0);
      expect(restored.lastUsedAtMs, isNull);
    });

    test('an unknown source wire name degrades to imported', () {
      final Map<String, dynamic> json = _entry().toJson()
        ..['source'] = 'from-the-future';
      expect(LocalModelEntry.fromJson(json).source, LocalModelSource.imported);
    });
  });

  group('LocalModelEntry copyWith', () {
    test('replaces given fields and keeps the rest', () {
      final LocalModelEntry updated = _entry().copyWith(
        name: 'Renamed',
        sizeBytes: 1,
        lastUsedAtMs: 7,
      );
      expect(updated.name, 'Renamed');
      expect(updated.sizeBytes, 1);
      expect(updated.lastUsedAtMs, 7);
      expect(updated.id, 'm-1');
      expect(updated.ollamaRef, 'qwen3:0.6b');
      expect(updated.sha256, 'aa11');
    });

    test('an explicit null clears lastUsedAtMs (CronJob sentinel style)', () {
      final LocalModelEntry cleared = _entry().copyWith(lastUsedAtMs: null);
      expect(cleared.lastUsedAtMs, isNull);
    });
  });

  group('LocalModelState', () {
    test('defaults match the frozen contract', () {
      const LocalModelState state = LocalModelState();
      expect(state.installed, isEmpty);
      expect(state.serverPort, 11434);
      expect(state.contextSize, 2048);
      expect(state.threads, 0);
      expect(state.autoStartOnBoot, isFalse);
    });

    test('survives toJson → fromJson with entries and config', () {
      final LocalModelState state = LocalModelState(
        installed: <LocalModelEntry>[_entry()],
        serverPort: 8080,
        contextSize: 8192,
        threads: 4,
        autoStartOnBoot: true,
      );
      final LocalModelState restored = LocalModelState.fromJson(state.toJson());
      expect(restored.installed.single.id, 'm-1');
      expect(restored.serverPort, 8080);
      expect(restored.contextSize, 8192);
      expect(restored.threads, 4);
      expect(restored.autoStartOnBoot, isTrue);
    });

    test('tolerant fromJson: non-map entries are skipped, missing config '
        'falls back', () {
      final LocalModelState restored = LocalModelState.fromJson(
        <String, dynamic>{
          'installed': <dynamic>[
            _entry().toJson(),
            'not-a-map',
            <String, dynamic>{},
          ],
        },
      );
      expect(restored.installed, hasLength(2));
      expect(restored.installed.first.id, 'm-1');
      expect(restored.installed.last.id, '');
      expect(restored.serverPort, 11434);
      expect(restored.contextSize, 2048);
    });

    test('copyWith patches only the given fields', () {
      const LocalModelState state = LocalModelState();
      final LocalModelState next = state.copyWith(threads: 6);
      expect(next.serverPort, 11434);
      expect(next.threads, 6);
      expect(next.contextSize, 2048);
      expect(next.autoStartOnBoot, isFalse);
      expect(next.remoteCatalog, isEmpty);
    });

    test('defaults include an empty remoteCatalog (v1.52.0)', () {
      const LocalModelState state = LocalModelState();
      expect(state.remoteCatalog, isEmpty);
    });

    test('remoteCatalog survives a toJson → fromJson roundtrip', () {
      final LocalModelState state = LocalModelState(
        remoteCatalog: <CatalogModelEntry>[
          const CatalogModelEntry(
            ollamaRef: 'qwen3:0.6b',
            downloadBytes: 548405248,
            ramEstBytes: 1073741824,
            contextTokens: 40960,
            tier: CatalogTier.tier1,
            license: 'Apache-2.0',
          ),
          const CatalogModelEntry(
            ollamaRef: 'new-model:1b',
            downloadBytes: 306184192,
            ramEstBytes: 751619276,
            contextTokens: 32768,
            tier: CatalogTier.upperBound,
          ),
        ],
      );
      final LocalModelState restored = LocalModelState.fromJson(state.toJson());
      expect(restored.remoteCatalog, hasLength(2));
      expect(restored.remoteCatalog.first.ollamaRef, 'qwen3:0.6b');
      expect(restored.remoteCatalog.first.tier, CatalogTier.tier1);
      expect(restored.remoteCatalog.first.downloadBytes, 548405248);
      expect(restored.remoteCatalog.first.license, 'Apache-2.0');
      expect(restored.remoteCatalog.last.ollamaRef, 'new-model:1b');
      expect(restored.remoteCatalog.last.tier, CatalogTier.upperBound);
      expect(restored.remoteCatalog.last.license, '');
    });

    test('tolerant fromJson: missing remoteCatalog key → empty list; junk '
        'rows skipped; unknown tier → tier2', () {
      final LocalModelState noKey = LocalModelState.fromJson(<String, dynamic>{
        'serverPort': 8080,
      });
      expect(noKey.remoteCatalog, isEmpty);

      final LocalModelState junk = LocalModelState.fromJson(<String, dynamic>{
        'remoteCatalog': <dynamic>[
          <String, dynamic>{
            'ollamaRef': 'x:1b',
            'downloadBytes': 5,
            'tier': 'from-the-future',
          },
          'not-a-map',
        ],
      });
      expect(junk.remoteCatalog, hasLength(1));
      expect(junk.remoteCatalog.single.ollamaRef, 'x:1b');
      expect(junk.remoteCatalog.single.downloadBytes, 5);
      expect(junk.remoteCatalog.single.tier, CatalogTier.tier2);
      expect(junk.remoteCatalog.single.ramEstBytes, 0);
    });

    test('copyWith patches remoteCatalog independently of the rest', () {
      const LocalModelState state = LocalModelState(
        remoteCatalog: kLocalAiCatalog,
      );
      final LocalModelState next = state.copyWith(
        remoteCatalog: const <CatalogModelEntry>[],
      );
      expect(next.remoteCatalog, isEmpty);
      expect(next.serverPort, state.serverPort);
      expect(next.installed, state.installed);
    });
  });
}
