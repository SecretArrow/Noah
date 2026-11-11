import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ar;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/skill_registry.dart';

/// v1.38.0: the Skills system — REAL install pipeline (archive decoding,
/// zip-slip protection, caps, atomic staging), secret-safe config and
/// skill_run env injection.
void main() {
  late Directory docs;
  late SkillRegistry registry;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('skills_test');
    registry = SkillRegistry(resolveBaseDir: () async => docs);
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  ar.ArchiveFile file(String path, List<int> bytes) =>
      ar.ArchiveFile(path, bytes.length, bytes);

  List<int> zipSkill({
    String name = 'demo-skill',
    String description = 'A demo skill',
    String extraFrontMatter = '',
    String body = '# Demo\nDo things.\n',
    Map<String, List<int>> extraFiles = const <String, List<int>>{},
    String wrapDir = 'skill-main/',
  }) {
    final ar.Archive archive = ar.Archive();
    archive.addFile(
      file(
        '$wrapDir$name/SKILL.md',
        utf8.encode(
          '---\nname: $name\ndescription: $description\nversion: 1.2.0\n'
          '$extraFrontMatter---\n\n$body',
        ),
      ),
    );
    archive.addFile(
      file('$wrapDir$name/scripts/main.js', utf8.encode('console.log("hi");')),
    );
    extraFiles.forEach((String path, List<int> bytes) {
      archive.addFile(file('$wrapDir$name/$path', bytes));
    });
    return ar.ZipEncoder().encode(archive);
  }

  group('SkillRegistry.install', () {
    test('installs from a zip archive: files land, registry records, '
        'status ready', () async {
      final SkillInstallReport report = await registry.installFromArchiveBytes(
        zipSkill(),
        source: 'test:zip',
      );
      expect(report.skill.name, 'demo-skill');
      expect(report.skill.version, '1.2.0');
      expect(report.skill.description, 'A demo skill');
      final Directory dir = Directory(report.skill.dirPath);
      expect(dir.existsSync(), isTrue);
      expect(
        File(
          '${dir.path}${Platform.pathSeparator}scripts'
          '${Platform.pathSeparator}main.js',
        ).existsSync(),
        isTrue,
      );
      final List<InstalledSkill> list = await registry.list();
      expect(list, hasLength(1));
      expect(list.first.status(const <String>{}), SkillStatus.ready);
      // The wrapping dirs are unwrapped and no staging leftovers remain.
      final Directory skillsRoot = await registry.skillsDir();
      expect(
        skillsRoot.listSync().map(
          (FileSystemEntity e) => e.path.split(Platform.pathSeparator).last,
        ),
        everyElement(isNot(contains('.staging'))),
      );
    });

    test(
      'updates an installed skill in place (reinstall keeps one entry)',
      () async {
        await registry.installFromArchiveBytes(zipSkill(), source: 'a');
        await registry.installFromArchiveBytes(
          zipSkill(description: 'Updated'),
          source: 'b',
        );
        final List<InstalledSkill> list = await registry.list();
        expect(list, hasLength(1));
        expect(list.first.description, 'Updated');
        expect(list.first.source, 'b');
      },
    );

    test(
      'reinstall keeps the secrets stored by the previous install',
      () async {
        const String config =
            'config:\n  - name: API_KEY\n'
            '    secret: true\n    required: true\n';
        final SkillInstallReport first = await registry.installFromArchiveBytes(
          zipSkill(extraFrontMatter: config),
          source: 'a',
        );
        await registry.writeConfig(first.skill, <String, String>{
          'API_KEY': 'S3CR3T',
        });

        final SkillInstallReport again = await registry.installFromArchiveBytes(
          zipSkill(description: 'Updated', extraFrontMatter: config),
          source: 'b',
        );

        expect(
          await registry.readConfig(again.skill),
          <String, String>{'API_KEY': 'S3CR3T'},
          reason: 'the user must not have to re-enter secrets after an update',
        );
        expect(again.notes.join('\n'), contains('config was kept'));
        expect(
          again.notes.join('\n'),
          isNot(contains('S3CR3T')),
          reason: 'secret values are never echoed into reports',
        );
      },
    );

    test('a gzip archive declaring an absurd unpacked size is refused '
        'before decoding', () async {
      final List<int> gz = ar.GZipEncoder().encode(
        ar.TarEncoder().encode(
          ar.Archive()..addFile(
            file(
              'skill-main/demo-skill/SKILL.md',
              utf8.encode('---\nname: demo-skill\ndescription: d\n---\n'),
            ),
          ),
        ),
      );
      final Uint8List bomb = Uint8List.fromList(gz);
      // The ISIZE trailer (last 4 bytes, little endian) is the declared
      // uncompressed size: patch it to 200 MB. NOTE: patch the SAME buffer
      // that is handed to the installer, and `sublistView` takes an END
      // INDEX, not a length.
      ByteData.sublistView(
        bomb,
        bomb.length - 4,
      ).setUint32(0, 200 * 1024 * 1024, Endian.little);

      await expectLater(
        registry.installFromArchiveBytes(bomb, source: 'test'),
        throwsA(
          isA<SkillRegistryException>().having(
            (SkillRegistryException e) => e.message,
            'message',
            contains('32 MB'),
          ),
        ),
      );
    });

    test('rejects archives without SKILL.md', () async {
      final ar.Archive archive = ar.Archive()
        ..addFile(file('x/README.md', utf8.encode('nope')));
      final List<int> bytes = ar.ZipEncoder().encode(archive);
      await expectLater(
        registry.installFromArchiveBytes(bytes, source: 'test'),
        throwsA(isA<SkillRegistryException>()),
      );
    });

    test('rejects zip-slip entries (../ escapes)', () async {
      final ar.Archive archive = ar.Archive()
        ..addFile(
          file(
            'evil/SKILL.md',
            utf8.encode('---\nname: evil\ndescription: x\n---\n'),
          ),
        )
        ..addFile(file('evil/../../../../etc/evil.txt', utf8.encode('x')));
      final List<int> bytes = ar.ZipEncoder().encode(archive);
      await expectLater(
        registry.installFromArchiveBytes(bytes, source: 'test'),
        throwsA(
          isA<SkillRegistryException>().having(
            (SkillRegistryException e) => e.message,
            'message',
            contains('unsafe path'),
          ),
        ),
      );
      // Nothing outside may exist.
      expect(
        Directory(
          '${docs.path}${Platform.pathSeparator}skills'
          '${Platform.pathSeparator}evil',
        ).existsSync(),
        isFalse,
      );
    });

    test('rejects reserved names', () async {
      final List<int> bytes = zipSkill(name: 'sessions');
      await expectLater(
        registry.installFromArchiveBytes(bytes, source: 'test'),
        throwsA(isA<SkillRegistryException>()),
      );
    });

    test('github shorthand parsing covers repo/subpath/branch/url forms', () {
      GitHubSkillRef ref = registry.parseGitHubSource(
        'binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet',
      );
      expect(ref.owner, 'binance');
      expect(ref.repo, 'binance-skills-hub');
      expect(ref.subPath, 'skills/binance-web3/binance-agentic-wallet');
      expect(ref.branch, isEmpty);

      ref = registry.parseGitHubSource('owner/repo@dev');
      expect(ref.branch, 'dev');

      ref = registry.parseGitHubSource('https://github.com/o/r.git');
      expect(ref.owner, 'o');
      expect(ref.repo, 'r');
    });

    test(
      'install() from a URL really downloads and installs (mock http)',
      () async {
        final List<int> tarGz = ar.GZipEncoder().encode(
          ar.TarEncoder().encode(
            ar.Archive()..addFile(
              file(
                'repo-main/SKILL.md',
                utf8.encode(
                  '---\nname: url-skill\ndescription: from url\n---\nhi',
                ),
              ),
            ),
          ),
        );
        final SkillRegistry withHttp = SkillRegistry(
          resolveBaseDir: () async => docs,
          client: MockClient((http.Request request) async {
            expect(request.url.host, 'example.com');
            return http.Response.bytes(tarGz, 200);
          }),
        );
        final SkillInstallReport report = await withHttp.install(
          'https://example.com/skill.tar.gz',
        );
        expect(report.skill.name, 'url-skill');
      },
    );

    test('a bundled .zconfig.json is never installed '
        '(config is user-owned)', () async {
      final SkillInstallReport report = await registry.installFromArchiveBytes(
        zipSkill(
          extraFiles: <String, List<int>>{
            '.zconfig.json': utf8.encode('{"API_KEY":"attacker-value"}'),
          },
        ),
        source: 'test',
      );
      final File planted = File(
        '${report.skill.dirPath}${Platform.pathSeparator}.zconfig.json',
      );
      expect(
        planted.existsSync(),
        isFalse,
        reason: 'third-party code must not ship the stored config',
      );
      expect(
        report.notes.join('\n'),
        contains('.zconfig.json'),
        reason: 'the install report says the entry was ignored',
      );
      // The skill itself is installed normally.
      expect(await registry.get('demo-skill'), isNotNull);
    });
  });

  group('SkillRegistry config (secrets)', () {
    late InstalledSkill skill;
    setUp(() async {
      final SkillInstallReport report = await registry.installFromArchiveBytes(
        zipSkill(
          extraFrontMatter: 'config:\n  - name: API_KEY\n    secret: true\n    required: true\n  - name: NETWORK\n    secret: false\n    required: false\n',
        ),
        source: 'test',
      );
      skill = report.skill;
    });

    test('missing required config detected; writeConfig persists; values '
        'never appear in describeConfig', () async {
      expect(registry.missingRequiredConfig(skill), <String>{'API_KEY'});
      expect(
        registry.describeConfig(skill, const <String, String>{}),
        contains('API_KEY(required, unset)'),
      );

      await registry.writeConfig(skill, <String, String>{'API_KEY': 'S3CR3T'});
      final Map<String, String> stored = await registry.readConfig(skill);
      expect(stored['API_KEY'], 'S3CR3T');
      expect(await registry.statusOf(skill), SkillStatus.ready);

      // The LLM-visible summary NEVER contains the value.
      expect(registry.describeConfig(skill, stored), isNot(contains('S3CR3T')));
      // The config file is local-only; nothing else should have it.
      expect(
        File(
          '${docs.path}${Platform.pathSeparator}skills'
          '${Platform.pathSeparator}registry.json',
        ).readAsStringSync(),
        isNot(contains('S3CR3T')),
      );
    });

    test('remove deletes files + registry entry', () async {
      await registry.writeConfig(skill, <String, String>{'API_KEY': 'x'});
      await registry.remove('demo-skill');
      expect(Directory(skill.dirPath).existsSync(), isFalse);
      expect(await registry.list(), isEmpty);
    });
  });
}
