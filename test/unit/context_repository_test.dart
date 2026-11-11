import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/context_repository.dart';

void main() {
  group('MemoryContextRepository', () {
    test('seeds default entries and persists changes', () async {
      final MemoryContextRepository repo = MemoryContextRepository();
      final List<ContextEntry> seeded = repo.load();
      expect(seeded, isNotEmpty);
      expect(seeded.every((e) => !e.enabled), isTrue); // disabled by default

      await repo.save(<ContextEntry>[seeded.first.copyWith(enabled: true)]);
      expect(repo.load().first.enabled, isTrue);
    });
  });

  group('PrefsContextRepository', () {
    test('first load seeds defaults; save then load roundtrips', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final PrefsContextRepository repo = PrefsContextRepository(prefs);

      final List<ContextEntry> seeded = repo.load();
      expect(seeded.length, defaultContextEntries().length);
      expect(seeded.every((e) => !e.enabled), isTrue);

      final List<ContextEntry> modified = <ContextEntry>[
        ...seeded.take(1),
        ContextEntry(
          id: 'custom-1',
          name: 'My rule',
          content: 'Always answer in Markdown',
          enabled: true,
        ),
      ];
      await repo.save(modified);

      final List<ContextEntry> reloaded = repo.load();
      expect(reloaded.length, 2);
      expect(reloaded.last.name, 'My rule');
      expect(reloaded.last.enabled, isTrue);
    });

    test('corrupted store degrades to an empty list', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'zagents.contexts.v1': '{not json!!',
        'zagents.contexts.seeded': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final PrefsContextRepository repo = PrefsContextRepository(prefs);
      expect(repo.load(), isEmpty);
    });
  });
}
