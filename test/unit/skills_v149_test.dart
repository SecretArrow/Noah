import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/settings_repository.dart';
import 'package:noah/services/skill_registry.dart';

/// v1.49.0 Skills manager coverage (temp-dir SkillRegistry, no widgets):
///
///  1. the `enabled` flag — default, JSON roundtrip, legacy default,
///     setEnabled persistence across registry re-construction, unknown
///     names as a no-op, disabled precedence in statusOf, reinstall
///     carry-over;
///  2. encrypted secret config — readConfig masking / revealSecrets,
///     writeConfig storing secrets ONLY in the SecretBox (never in the
///     plaintext .zconfig.json), null removals clearing both stores;
///  3. the one-shot legacy plaintext migration (box wins, idempotent);
///  4. readSecret decryption and the secure-storage-unavailable fallback;
///  5. remove() purging the encrypted secrets of an uninstalled skill.
void main() {
  late Directory docs;
  late InMemorySecretBox box;
  late SkillRegistry registry;

  // One secret + one plain declared config field — the v1.49 fixture shape.
  const String skillMd =
      '---\nname: demo-skill\ntitle: Demo Skill\ndescription: demo\n'
      'version: 1.2.0\nconfig:\n'
      '  - name: API_KEY\n    secret: true\n    required: true\n'
      '  - name: REGION\n    required: false\n'
      '---\n\n# Demo\nInstructions.\n';

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('skills_v149');
    box = InMemorySecretBox();
    registry = SkillRegistry(resolveBaseDir: () async => docs, secretBox: box);
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  ar.ArchiveFile zipFile(String path, List<int> bytes) =>
      ar.ArchiveFile(path, bytes.length, bytes);

  Future<InstalledSkill> install() async {
    final ar.Archive archive = ar.Archive()
      ..addFile(zipFile('demo/SKILL.md', utf8.encode(skillMd)));
    final SkillInstallReport report = await registry.installFromArchiveBytes(
      ar.ZipEncoder().encode(archive),
      source: 'test:zip',
    );
    return report.skill;
  }

  File configFile(InstalledSkill skill) =>
      File('${skill.dirPath}${Platform.pathSeparator}.zconfig.json');

  File registryFile() => File(
    '${docs.path}${Platform.pathSeparator}skills'
    '${Platform.pathSeparator}${SkillRegistry.registryFileName}',
  );

  group('enabled flag (v1.49)', () {
    test(
      'defaults to true, roundtrips through JSON, missing key → true',
      () async {
        final InstalledSkill skill = await install();
        expect(skill.enabled, isTrue, reason: 'a fresh install is enabled');

        final Map<String, dynamic> json = skill.toJson();
        expect(json['enabled'], isTrue);

        // Pre-1.49 registry entries carry no 'enabled' key at all.
        final Map<String, dynamic> legacy = Map<String, dynamic>.of(json)
          ..remove('enabled');
        expect(InstalledSkill.fromJson(legacy, skill.dirPath).enabled, isTrue);
        expect(
          InstalledSkill.fromJson(<String, dynamic>{
            ...json,
            'enabled': false,
          }, skill.dirPath).enabled,
          isFalse,
        );
      },
    );

    test('setEnabled persists to registry.json and survives a fresh registry '
        'on the same directory', () async {
      await install();
      await registry.setEnabled('demo-skill', false);

      // The instance cache is updated in place.
      expect(registry.listSync().single.enabled, isFalse);

      // The flag really hit the on-disk index.
      final Map<String, dynamic> decoded =
          jsonDecode(registryFile().readAsStringSync()) as Map<String, dynamic>;
      final Map<String, dynamic> entry =
          (decoded['skills'] as Map<String, dynamic>)['demo-skill']
              as Map<String, dynamic>;
      expect(entry['enabled'], isFalse);

      // A re-constructed registry (fresh instance, same dir) reads it back.
      final SkillRegistry fresh = SkillRegistry(
        resolveBaseDir: () async => docs,
        secretBox: InMemorySecretBox(),
      );
      expect((await fresh.list()).single.enabled, isFalse);
    });

    test('setEnabled on an unknown name is a silent no-op', () async {
      await install();
      await registry.setEnabled('ghost-skill', false);
      expect(await registry.list(), hasLength(1));
      expect((await registry.list()).single.enabled, isTrue);
      // The on-disk index still describes exactly the one real install.
      final Map<String, dynamic> decoded =
          jsonDecode(registryFile().readAsStringSync()) as Map<String, dynamic>;
      expect((decoded['skills'] as Map<String, dynamic>).keys, <String>{
        'demo-skill',
      });
    });

    test('statusOf: disabled overrides missing required config; re-enable '
        'restores needsConfig and then ready', () async {
      await install();
      InstalledSkill skill = (await registry.get('demo-skill'))!;

      // API_KEY is required and unset → needsConfig.
      expect(await registry.statusOf(skill), SkillStatus.needsConfig);

      // A disabled skill reports disabled even with the config missing.
      await registry.setEnabled('demo-skill', false);
      skill = (await registry.get('demo-skill'))!;
      expect(await registry.statusOf(skill), SkillStatus.disabled);

      // Re-enabling restores the config-driven state.
      await registry.setEnabled('demo-skill', true);
      skill = (await registry.get('demo-skill'))!;
      expect(await registry.statusOf(skill), SkillStatus.needsConfig);

      // Filling the required value flips it to ready — and disabled STILL
      // wins once the user turns the skill off again.
      await registry.writeConfig(skill, <String, String>{'API_KEY': 'K1'});
      skill = (await registry.get('demo-skill'))!;
      expect(await registry.statusOf(skill), SkillStatus.ready);
      await registry.setEnabled('demo-skill', false);
      skill = (await registry.get('demo-skill'))!;
      expect(await registry.statusOf(skill), SkillStatus.disabled);
    });

    test('a reinstall carries the user\'s enabled=false choice over', () async {
      await install();
      await registry.setEnabled('demo-skill', false);

      final ar.Archive archive = ar.Archive()
        ..addFile(zipFile('demo/SKILL.md', utf8.encode(skillMd)));
      final SkillInstallReport again = await registry.installFromArchiveBytes(
        ar.ZipEncoder().encode(archive),
        source: 'test:zip2',
      );
      expect(again.skill.enabled, isFalse);
      expect((await registry.list()).single.enabled, isFalse);
    });
  });

  group('encrypted secret config (v1.49)', () {
    test('secretBoxKey names the box entry zagents.skill.<skill>.<field>', () {
      expect(
        SkillRegistry.secretBoxKey('demo-skill', 'API_KEY'),
        'zagents.skill.demo-skill.API_KEY',
      );
    });

    test(
      'readConfig masks declared-secret values and reveals on demand',
      () async {
        final InstalledSkill skill = await install();
        await registry.writeConfig(skill, <String, String>{
          'API_KEY': 'S3CR3T',
          'REGION': 'ap-southeast-1',
        });

        final Map<String, String> masked = await registry.readConfig(skill);
        expect(masked['API_KEY'], SkillRegistry.secretMask);
        expect(masked['REGION'], 'ap-southeast-1');

        final Map<String, String> revealed = await registry.readConfig(
          skill,
          revealSecrets: true,
        );
        expect(revealed['API_KEY'], 'S3CR3T');
        expect(revealed['REGION'], 'ap-southeast-1');
      },
    );

    test('a written secret never lands in the plain config file; the box '
        'holds the encrypted copy', () async {
      final InstalledSkill skill = await install();
      await registry.writeConfig(skill, <String, String>{
        'API_KEY': 'S3CR3T',
        'REGION': 'ap-southeast-1',
      });

      // The file exists (REGION is a plain value) but must not contain the
      // secret — byte-level assertion, not a masked read.
      final File file = configFile(skill);
      expect(file.existsSync(), isTrue);
      final String raw = utf8.decode(file.readAsBytesSync());
      expect(raw, isNot(contains('S3CR3T')));
      expect(raw, contains('ap-southeast-1'));

      // The encrypted store holds the real value under the namespaced key.
      expect(
        await box.read(SkillRegistry.secretBoxKey('demo-skill', 'API_KEY')),
        'S3CR3T',
      );
    });

    test('a null secret removal clears the box AND the file entry', () async {
      final InstalledSkill skill = await install();
      await registry.writeConfig(skill, <String, String>{
        'API_KEY': 'S3CR3T',
        'REGION': 'ap-southeast-1',
      });
      await registry.writeConfig(skill, <String, String?>{'API_KEY': null});

      expect(
        await box.read(SkillRegistry.secretBoxKey('demo-skill', 'API_KEY')),
        isNull,
      );
      final Map<String, String> stored = await registry.readConfig(
        skill,
        revealSecrets: true,
      );
      expect(stored.containsKey('API_KEY'), isFalse);
      expect(stored['REGION'], 'ap-southeast-1');
      // The file survives (REGION is still there) without the secret.
      expect(
        utf8.decode(configFile(skill).readAsBytesSync()),
        isNot(contains('S3CR3T')),
      );
    });

    test('a null non-secret removal clears the file entry (an emptied file '
        'is deleted)', () async {
      final InstalledSkill skill = await install();
      await registry.writeConfig(skill, <String, String>{'REGION': 'eu-1'});
      expect(configFile(skill).existsSync(), isTrue);
      await registry.writeConfig(skill, <String, String?>{'REGION': null});
      expect(configFile(skill).existsSync(), isFalse);
      expect(await registry.readConfig(skill), isEmpty);
    });
  });

  group('legacy plaintext migration (v1.49)', () {
    test('a plaintext secret moves into the box and out of the file on the '
        'first config access', () async {
      final InstalledSkill skill = await install();
      // Pre-encryption install: the secret sits in the plain config file.
      await configFile(skill).writeAsString('{"API_KEY":"legacy-secret"}');

      final Map<String, String> masked = await registry.readConfig(skill);
      expect(masked['API_KEY'], SkillRegistry.secretMask);
      expect(
        await box.read(SkillRegistry.secretBoxKey('demo-skill', 'API_KEY')),
        'legacy-secret',
      );
      // It was the only key — the emptied file is gone entirely.
      expect(configFile(skill).existsSync(), isFalse);
      final Map<String, String> revealed = await registry.readConfig(
        skill,
        revealSecrets: true,
      );
      expect(revealed['API_KEY'], 'legacy-secret');
    });

    test('migration is idempotent: a second access (same or fresh registry) '
        'changes nothing', () async {
      final InstalledSkill skill = await install();
      await configFile(skill).writeAsString('{"API_KEY":"legacy-secret"}');

      await registry.readConfig(skill);
      // Second read on the same instance: stable state, no rewrite.
      expect(
        (await registry.readConfig(skill))['API_KEY'],
        SkillRegistry.secretMask,
      );
      expect(
        await box.read(SkillRegistry.secretBoxKey('demo-skill', 'API_KEY')),
        'legacy-secret',
      );
      expect(configFile(skill).existsSync(), isFalse);

      // And a FRESH registry on the same dir (+ shared box) re-checks,
      // finds nothing left to move and leaves the box value untouched.
      final SkillRegistry fresh = SkillRegistry(
        resolveBaseDir: () async => docs,
        secretBox: box,
      );
      final InstalledSkill freshSkill = (await fresh.get('demo-skill'))!;
      expect(
        (await fresh.readConfig(freshSkill))['API_KEY'],
        SkillRegistry.secretMask,
      );
      expect(
        await box.read(SkillRegistry.secretBoxKey('demo-skill', 'API_KEY')),
        'legacy-secret',
      );
      expect(configFile(freshSkill).existsSync(), isFalse);
    });

    test(
      'a box value already present wins over a stale plaintext copy',
      () async {
        final InstalledSkill skill = await install();
        await registry.writeConfig(skill, <String, String>{
          'API_KEY': 'boxed-value',
        });
        // Crash-window shape: a stale plaintext copy reappears next to the
        // NEWER encrypted copy.
        await configFile(skill).writeAsString('{"API_KEY":"stale-legacy"}');

        final SkillRegistry fresh = SkillRegistry(
          resolveBaseDir: () async => docs,
          secretBox: box,
        );
        final InstalledSkill freshSkill = (await fresh.get('demo-skill'))!;
        expect(
          (await fresh.readConfig(freshSkill))['API_KEY'],
          SkillRegistry.secretMask,
        );
        expect(
          await box.read(SkillRegistry.secretBoxKey('demo-skill', 'API_KEY')),
          'boxed-value',
          reason: 'the encrypted copy is newer and must never be overwritten',
        );
        expect(configFile(freshSkill).existsSync(), isFalse);
        expect(await fresh.readSecret(freshSkill, 'API_KEY'), 'boxed-value');
      },
    );
  });

  group('readSecret (v1.49)', () {
    test('decrypts the boxed secret and falls back to plain values', () async {
      final InstalledSkill skill = await install();
      await registry.writeConfig(skill, <String, String>{
        'API_KEY': 'S3CR3T',
        'REGION': 'eu-1',
      });
      expect(await registry.readSecret(skill, 'API_KEY'), 'S3CR3T');
      expect(await registry.readSecret(skill, 'REGION'), 'eu-1');
      expect(await registry.readSecret(skill, 'NEVER_SET'), isNull);
    });
  });

  group('secure storage unavailable (v1.49 fallback)', () {
    test('a broken box degrades to plaintext without ever throwing', () async {
      final SkillRegistry degraded = SkillRegistry(
        resolveBaseDir: () async => docs,
        secretBox: const _BrokenSecretBox(),
      );
      final ar.Archive archive = ar.Archive()
        ..addFile(zipFile('demo/SKILL.md', utf8.encode(skillMd)));
      final SkillInstallReport report = await degraded.installFromArchiveBytes(
        ar.ZipEncoder().encode(archive),
        source: 'test:zip',
      );
      final InstalledSkill skill = report.skill;

      await degraded.writeConfig(skill, <String, String>{
        'API_KEY': 'fallback-secret',
      });
      // Documented trade-off: the value survives as plaintext in the file.
      expect(
        utf8.decode(configFile(skill).readAsBytesSync()),
        contains('fallback-secret'),
      );
      // Reads keep the skill working (returned as-is until the box
      // recovers) and the internal consumers still see the real value.
      expect((await degraded.readConfig(skill))['API_KEY'], 'fallback-secret');
      expect(await degraded.readSecret(skill, 'API_KEY'), 'fallback-secret');
    });
  });

  group('remove purges encrypted secrets (v1.49)', () {
    test('uninstalling a skill deletes its box entries and files', () async {
      final InstalledSkill skill = await install();
      await registry.writeConfig(skill, <String, String>{'API_KEY': 'S3CR3T'});
      await registry.remove('demo-skill');

      expect(Directory(skill.dirPath).existsSync(), isFalse);
      expect(await registry.list(), isEmpty);
      expect(
        await box.read(SkillRegistry.secretBoxKey('demo-skill', 'API_KEY')),
        isNull,
        reason:
            'encrypted secrets are keyed outside the skill folder and '
            'would silently outlive an uninstall',
      );
    });
  });
}

/// A [SecretBox] whose read/write always fail — the "secure storage
/// unavailable" degradation path (platform channel / Keystore trouble).
class _BrokenSecretBox implements SecretBox {
  const _BrokenSecretBox();

  @override
  Future<String?> read(String key) async => throw const _BoxUnavailable();

  @override
  Future<void> write(String key, String value) async =>
      throw const _BoxUnavailable();

  @override
  Future<void> delete(String key) async {
    // Deleting an already-absent key is harmless even on a broken box.
  }
}

class _BoxUnavailable implements Exception {
  const _BoxUnavailable();
}
