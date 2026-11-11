import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/settings_repository.dart';

const String _settingsKey = 'zagents.settings.v1';

/// In-memory [SecretBox] fake that can be told to fail individual
/// operations, simulating a broken secure-storage platform channel.
class FakeSecretBox implements SecretBox {
  FakeSecretBox({Map<String, String>? initial})
    : _values = initial != null ? Map<String, String>.of(initial) : {};

  final Map<String, String> _values;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  int writeCount = 0;
  int deleteCount = 0;

  String? operator [](String key) => _values[key];

  @override
  Future<String?> read(String key) async {
    if (failRead) throw const FakeSecretBoxException('read failed');
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw const FakeSecretBoxException('write failed');
    writeCount++;
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw const FakeSecretBoxException('delete failed');
    deleteCount++;
    _values.remove(key);
  }
}

class FakeSecretBoxException implements Exception {
  const FakeSecretBoxException(this.message);

  final String message;

  @override
  String toString() => 'FakeSecretBoxException: $message';
}

/// [SecretBox] fake whose every operation blocks on a [Completer] — lets a
/// test observe what [PrefsSettingsRepository.save] has already persisted
/// WHILE the secure-storage operation is still in flight (the v1.47.1
/// save-ordering regression).
class GatingSecretBox implements SecretBox {
  GatingSecretBox();

  final Completer<void> readGate = Completer<void>();
  final Completer<void> writeGate = Completer<void>();
  final Completer<void> deleteGate = Completer<void>();
  final Map<String, String> _values = <String, String>{};
  bool writeCalled = false;
  bool deleteCalled = false;

  String? operator [](String key) => _values[key];

  @override
  Future<String?> read(String key) async {
    await readGate.future;
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCalled = true;
    await writeGate.future;
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCalled = true;
    await deleteGate.future;
    _values.remove(key);
  }
}

/// Lets pending fire-and-forget futures (secure read/write + prefs rewrite)
/// run to completion before the assertions inspect the fake storages.
Future<void> flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

AppSettings baseSettings({String apiKey = ''}) => AppSettings(
  providerName: 'Together',
  baseUrl: 'https://api.together.xyz/v1',
  apiKey: apiKey,
  model: 'meta-llama/Llama-3-70B',
  maxSteps: 9,
  runUntilDone: false,
  planFirst: false,
  languageCode: 'id',
  themeMode: ThemeModeSetting.light,
  presets: <ProviderPreset>[
    const ProviderPreset(
      id: 'preset-1',
      name: 'Together',
      baseUrl: 'https://api.together.xyz/v1',
      apiKey: 'preset-key-1',
      model: 'meta-llama/Llama-3-70B',
      modelsCache: <String>['meta-llama/Llama-3-70B'],
    ),
  ],
);

Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  group('InMemorySecretBox', () {
    test('read/write/delete behave like a plain map', () async {
      final InMemorySecretBox box = InMemorySecretBox();
      expect(await box.read('k'), isNull);
      await box.write('k', 'v');
      expect(await box.read('k'), 'v');
      await box.delete('k');
      expect(await box.read('k'), isNull);
    });
  });

  group('PrefsSettingsRepository.save', () {
    test('stores apiKey in SecretBox and strips it from prefs JSON', () async {
      final FakeSecretBox box = FakeSecretBox();
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      await repo.save(baseSettings(apiKey: 'sk-secret-123'));

      final Map<String, dynamic> json =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(
        json.containsKey('apiKey'),
        isFalse,
        reason: 'apiKey must never be persisted as plaintext JSON',
      );
      expect(box[PrefsSettingsRepository.apiKeySecretKey], 'sk-secret-123');
      expect(repo.lastSecretStorageError, isNull);
    });

    test('saving an empty apiKey deletes the secret from the box', () async {
      final FakeSecretBox box = FakeSecretBox(
        initial: <String, String>{
          PrefsSettingsRepository.apiKeySecretKey: 'sk-stale',
        },
      );
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      await repo.save(baseSettings(apiKey: ''));

      expect(box[PrefsSettingsRepository.apiKeySecretKey], isNull);
      expect(box.deleteCount, 1);
    });

    test('secure-storage failure does not throw and keeps the key as legacy '
        'plaintext fallback', () async {
      final FakeSecretBox box = FakeSecretBox()..failWrite = true;
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      await repo.save(baseSettings(apiKey: 'sk-keep'));

      expect(box[PrefsSettingsRepository.apiKeySecretKey], isNull);
      expect(repo.lastSecretStorageError, contains('write failed'));
      final Map<String, dynamic> json =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(
        json['apiKey'],
        'sk-keep',
        reason: 'the key must not be lost when secure storage fails',
      );
      expect(
        repo.load().apiKey,
        'sk-keep',
        reason: 'legacy plaintext fallback stays readable',
      );
    });
  });

  group('save ordering (v1.47.1)', () {
    test('non-secret settings land in prefs while the secure write is still '
        'in flight', () async {
      final GatingSecretBox box = GatingSecretBox();
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      final AppSettings settings = baseSettings(apiKey: 'secret-key')
          .copyWith(checkUpdatesOnStart: false);
      final Future<void> done = repo.save(settings);
      await flushMicrotasks();

      // THE regression test: the toggle is already on disk even though
      // the Keystore write has not finished. The pre-1.47.1 order awaited
      // the box BEFORE the prefs write, so at this point NOTHING was
      // persisted and the change was lost on process death (the user's
      // "toggle resets to ON after reopening the app" bug).
      expect(box.writeCalled, isTrue);
      final Map<String, dynamic> json =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(json['checkUpdatesOnStart'], isFalse);

      box.writeGate.complete();
      await done;

      final Map<String, dynamic> settled =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(
        settled.containsKey('apiKey'),
        isFalse,
        reason: 'plaintext fallback must be stripped once secured',
      );
      expect(repo.lastSettingsWriteError, isNull);
    });

    test(
      'empty apiKey: prefs still land before the gated delete completes',
      () async {
        // The common case — no API key configured, save only deletes from
        // the box. The settings JSON must not wait for that either.
        final GatingSecretBox box = GatingSecretBox();
        final SharedPreferences prefs = await prefsWith(<String, Object>{});
        final PrefsSettingsRepository repo = PrefsSettingsRepository(
          prefs,
          secretBox: box,
        );

        final Future<void> done = repo.save(
          baseSettings().copyWith(checkUpdatesOnStart: false),
        );
        await flushMicrotasks();

        expect(box.deleteCalled, isTrue);
        final Map<String, dynamic> json =
            jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
        expect(json['checkUpdatesOnStart'], isFalse);

        box.deleteGate.complete();
        await done;
        expect(repo.lastSettingsWriteError, isNull);
      },
    );

    test('a throwing SecretBox still persists the toggle and keeps the key '
        'as plaintext fallback', () async {
      // Simulated broken Keystore: the prefs write must already have
      // happened by the time the secure step fails.
      final FakeSecretBox box = FakeSecretBox()..failWrite = true;
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      await repo.save(
        baseSettings(apiKey: 'sk-keep').copyWith(checkUpdatesOnStart: false),
      );

      final Map<String, dynamic> json =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(json['checkUpdatesOnStart'], isFalse);
      expect(
        json['apiKey'],
        'sk-keep',
        reason: 'fallback semantics: the key must not be lost',
      );
      expect(repo.lastSecretStorageError, contains('write failed'));
      expect(repo.lastSettingsWriteError, isNull);
    });
  });

  group('SettingsController.update', () {
    test('does not throw when the repository save fails', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          settingsRepositoryProvider.overrideWithValue(
            ThrowingSettingsRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(settingsProvider.notifier)
          .update(
            container
                .read(settingsProvider)
                .copyWith(checkUpdatesOnStart: false),
          );

      expect(
        container.read(settingsProvider).checkUpdatesOnStart,
        isFalse,
        reason: 'in-session state must apply even when persistence fails',
      );
    });
  });

  group('PrefsSettingsRepository.load', () {
    test('returns the apiKey stored in the SecretBox', () async {
      final FakeSecretBox box = FakeSecretBox(
        initial: <String, String>{
          PrefsSettingsRepository.apiKeySecretKey: 'sk-box-key',
        },
      );
      final AppSettings previous = baseSettings(apiKey: 'sk-box-key');
      await prefsWith(<String, Object>{
        _settingsKey: jsonEncode(previous.toJson()..remove('apiKey')),
      });

      final PrefsSettingsRepository repo = await PrefsSettingsRepository.create(
        secretBox: box,
      );

      expect(repo.load().apiKey, 'sk-box-key');
    });

    test('save then load round-trips the key without a cold start', () async {
      final FakeSecretBox box = FakeSecretBox();
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      await repo.save(baseSettings(apiKey: 'sk-rt'));
      expect(repo.load().apiKey, 'sk-rt');
    });

    test('empty store degrades to defaults', () async {
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: FakeSecretBox(),
      );

      final AppSettings loaded = repo.load();
      expect(loaded.apiKey, '');
      expect(loaded.providerName, 'OpenRouter');
    });

    test('corrupted JSON degrades to defaults', () async {
      final SharedPreferences prefs = await prefsWith(<String, Object>{
        _settingsKey: '{not json!!',
      });
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: FakeSecretBox(),
      );

      expect(repo.load().apiKey, '');
    });
  });

  group('PrefsSettingsRepository legacy migration', () {
    test(
      'moves a plaintext legacy key into the box and cleans prefs',
      () async {
        final FakeSecretBox box = FakeSecretBox();
        final SharedPreferences prefs = await prefsWith(<String, Object>{
          _settingsKey: jsonEncode(baseSettings(apiKey: 'sk-legacy').toJson()),
        });
        final PrefsSettingsRepository repo = PrefsSettingsRepository(
          prefs,
          secretBox: box,
        );

        // The synchronous first load already serves the legacy key.
        expect(repo.load().apiKey, 'sk-legacy');

        await flushMicrotasks();

        expect(box[PrefsSettingsRepository.apiKeySecretKey], 'sk-legacy');
        final Map<String, dynamic> json =
            jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
        expect(
          json.containsKey('apiKey'),
          isFalse,
          reason: 'plaintext copy must be stripped after the secure write',
        );
        expect(
          json['model'],
          'meta-llama/Llama-3-70B',
          reason: 'non-secret fields survive the migration rewrite',
        );
      },
    );

    test(
      'is idempotent: a second load neither duplicates nor corrupts',
      () async {
        final FakeSecretBox box = FakeSecretBox();
        final SharedPreferences prefs = await prefsWith(<String, Object>{
          _settingsKey: jsonEncode(baseSettings(apiKey: 'sk-legacy').toJson()),
        });
        final PrefsSettingsRepository repo = PrefsSettingsRepository(
          prefs,
          secretBox: box,
        );

        expect(repo.load().apiKey, 'sk-legacy');
        await flushMicrotasks();
        final int writesAfterFirstLoad = box.writeCount;

        expect(repo.load().apiKey, 'sk-legacy');
        await flushMicrotasks();

        expect(
          box.writeCount,
          writesAfterFirstLoad,
          reason: 'the already-migrated key must not be rewritten',
        );
        expect(box[PrefsSettingsRepository.apiKeySecretKey], 'sk-legacy');
        final Map<String, dynamic> json =
            jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
        expect(json.containsKey('apiKey'), isFalse);
      },
    );

    test(
      'a failed migration keeps the plaintext and retries next load',
      () async {
        final FakeSecretBox box = FakeSecretBox()..failWrite = true;
        final SharedPreferences prefs = await prefsWith(<String, Object>{
          _settingsKey: jsonEncode(baseSettings(apiKey: 'sk-legacy').toJson()),
        });
        final PrefsSettingsRepository repo = PrefsSettingsRepository(
          prefs,
          secretBox: box,
        );

        expect(repo.load().apiKey, 'sk-legacy');
        await flushMicrotasks();

        expect(box[PrefsSettingsRepository.apiKeySecretKey], isNull);
        expect(repo.lastSecretStorageError, contains('write failed'));
        Map<String, dynamic> json =
            jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
        expect(
          json['apiKey'],
          'sk-legacy',
          reason: 'never strip before the secure write is confirmed',
        );

        // Secure storage recovers: the very next load finishes the migration.
        box.failWrite = false;
        expect(repo.load().apiKey, 'sk-legacy');
        await flushMicrotasks();

        expect(box[PrefsSettingsRepository.apiKeySecretKey], 'sk-legacy');
        json =
            jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
        expect(json.containsKey('apiKey'), isFalse);
      },
    );

    test('an existing secure copy wins over the stale plaintext', () async {
      // Crash-state simulation: a newer save wrote the box but the prefs
      // rewrite failed, so an older plaintext key is still present.
      final FakeSecretBox box = FakeSecretBox(
        initial: <String, String>{
          PrefsSettingsRepository.apiKeySecretKey: 'sk-newer',
        },
      );
      final SharedPreferences prefs = await prefsWith(<String, Object>{
        _settingsKey: jsonEncode(baseSettings(apiKey: 'sk-older').toJson()),
      });
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      repo.load();
      await flushMicrotasks();

      expect(
        box[PrefsSettingsRepository.apiKeySecretKey],
        'sk-newer',
        reason: 'migration must never overwrite a newer secure value',
      );
      expect(box.writeCount, 0);
      final Map<String, dynamic> json =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(json.containsKey('apiKey'), isFalse);
      expect(repo.load().apiKey, 'sk-newer');
    });
  });

  group('PrefsSettingsRepository non-secret round trip', () {
    test('every non-secret field survives save + load', () async {
      final FakeSecretBox box = FakeSecretBox();
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );
      final AppSettings settings = baseSettings(apiKey: 'sk-round-trip');

      await repo.save(settings);
      final AppSettings loaded = repo.load();

      expect(loaded.apiKey, 'sk-round-trip');
      expect(loaded.providerName, 'Together');
      expect(loaded.baseUrl, 'https://api.together.xyz/v1');
      expect(loaded.model, 'meta-llama/Llama-3-70B');
      expect(loaded.maxSteps, 9);
      expect(loaded.runUntilDone, isFalse);
      expect(loaded.planFirst, isFalse);
      expect(loaded.languageCode, 'id');
      expect(loaded.themeMode, ThemeModeSetting.light);
      expect(loaded.checkUpdatesOnStart, isTrue);
      expect(loaded.ipSwitchWarnEnabled, isFalse);
      // fromJson runs the pre-1.4.0 preset migration, which seeds every
      // built-in provider preset and merges the stored one by name — the
      // round trip preserves the stored preset's DATA, not its list shape.
      final ProviderPreset together = loaded.presets.singleWhere(
        (ProviderPreset p) => p.name == 'Together',
      );
      expect(together.id, 'preset-1');
      expect(
        together.apiKey,
        'preset-key-1',
        reason: 'preset keys are out of scope and stay in the JSON',
      );
      final Map<String, dynamic> json =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(json.containsKey('apiKey'), isFalse);
    });

    test(
      'checkUpdatesOnStart survives a full app restart (v1.47.1 regression)',
      () async {
        final FakeSecretBox box = FakeSecretBox();
        final SharedPreferences prefs = await prefsWith(<String, Object>{});
        final PrefsSettingsRepository repo = PrefsSettingsRepository(
          prefs,
          secretBox: box,
        );

        await repo.save(
          baseSettings(apiKey: 'sk-rt').copyWith(checkUpdatesOnStart: false),
        );

        // "Reopen the app": a brand-new repository instance over the same
        // store. Before the fix the toggle could reset to ON because the
        // save had never reached the prefs JSON.
        final PrefsSettingsRepository reopened =
            await PrefsSettingsRepository.create(secretBox: box);

        expect(
          reopened.load().checkUpdatesOnStart,
          isFalse,
          reason: 'the toggle must not reset to ON after reopening the app',
        );
      },
    );

    test('ipSwitchWarnEnabled survives a full app restart (v1.48.0, '
        'incl. _withPresetMigration)', () async {
      final FakeSecretBox box = FakeSecretBox();
      final SharedPreferences prefs = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository repo = PrefsSettingsRepository(
        prefs,
        secretBox: box,
      );

      // Toggle ON and persist, then "reopen the app" over the same store.
      // AppSettings.fromJson routes through _withPresetMigration, which
      // rebuilds the whole object — a field missing there resets on EVERY
      // restart (the exact v1.47.1 bug class this test locks out).
      await repo.save(
        baseSettings(apiKey: 'sk-rt').copyWith(ipSwitchWarnEnabled: true),
      );
      final Map<String, dynamic> onDisk =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(onDisk['ipSwitchWarnEnabled'], isTrue);

      final PrefsSettingsRepository reopened =
          await PrefsSettingsRepository.create(secretBox: box);
      final AppSettings loaded = reopened.load();

      expect(
        loaded.ipSwitchWarnEnabled,
        isTrue,
        reason: 'the toggle must not reset to OFF after reopening the app',
      );

      // The default stays OFF for stores that never carried the key
      // (fresh installs and pre-1.48.0 settings JSON).
      final SharedPreferences fresh = await prefsWith(<String, Object>{});
      final PrefsSettingsRepository freshRepo = PrefsSettingsRepository(
        fresh,
        secretBox: FakeSecretBox(),
      );
      expect(freshRepo.load().ipSwitchWarnEnabled, isFalse);
    });
  });
}

/// Repository double whose persistence always fails — drives the
/// [SettingsController] error-swallowing contract (v1.47.1).
class ThrowingSettingsRepository extends MemorySettingsRepository {
  @override
  Future<void> save(AppSettings settings) async {
    throw Exception('disk full');
  }
}
