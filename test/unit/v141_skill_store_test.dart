import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/chat_store.dart';
import 'package:noah/services/skill_registry.dart';
import 'package:noah/services/tool_executor.dart';

import '../support/test_doubles.dart';

/// v1.41.0 regression coverage:
///
///  1. ChatStore isolate job factories — every closure handed to
///     `Isolate.run` is now built in a TOP-LEVEL scope, so the serialized
///     context chain can never include `this` (whose `_writeChains` holds
///     unsendable `_Future`s while any save is in flight). The old inline
///     closures made save/load/list throw "object is unsendable" whenever
///     two chat storage operations overlapped.
///  2. skill_config unset (null removes a key; empty config deletes the
///     file) and installBundled config carry-over on reinstall.
///  3. skill_update — re-download, version compare, atomic replace with
///     config preserved, honest refusals for builtin/file sources.
///  4. GitHub branch-ROOT URL normalization (`tree/<branch>` with no path).
void main() {
  ar.ArchiveFile file(String path, List<int> bytes) =>
      ar.ArchiveFile(path, bytes.length, bytes);

  group('ChatStore isolate send-safety (v1.41.0)', () {
    late Directory base;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('v141_chat_store');
    });

    tearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });

    List<ChatMessage> transcript(String tag) => <ChatMessage>[
      ChatMessage.user('hello $tag'),
      ChatMessage.assistant('world $tag ' * 400),
    ];

    test(
      'a plain save succeeds while its own write-chain entry exists',
      () async {
        // offloadIsolate defaults to TRUE — the real-device path. Under the
        // pre-1.41.0 inline closures this save threw "object is unsendable"
        // because the closure's context chain carried `this` (with the live
        // `_writeChains` future).
        final ChatStore store = ChatStore(resolveBaseDir: () async => base);
        await store.save(id: 'a', title: 'Chat A', messages: transcript('a'));
        final List<ChatMessage>? loaded = await store.load('a');
        expect(loaded, isNotNull);
        expect(loaded, hasLength(2));
        expect(loaded!.first.content, 'hello a');
      },
    );

    test(
      'concurrent saves + load + summary read never trip the send',
      () async {
        final ChatStore store = ChatStore(resolveBaseDir: () async => base);
        await Future.wait(<Future<void>>[
          store.save(id: 'a', title: 'A', messages: transcript('a')),
          store.save(id: 'b', title: 'B', messages: transcript('b')),
          store.save(id: 'c', title: 'C', messages: transcript('c')),
        ]);
        // Read paths while another write may still be chaining.
        final List<ChatMessage>? loaded = await store.load('b');
        expect(loaded, isNotNull);
        expect(loaded, hasLength(2));
        final List<ChatSummary> summaries = await store.listSummaries();
        expect(summaries, hasLength(3));
        expect(summaries.map((ChatSummary s) => s.id).toSet(), <String>{
          'a',
          'b',
          'c',
        });
      },
    );

    test(
      'bundle roundtrip keeps todos/modules/wait flag under concurrency',
      () async {
        final ChatStore store = ChatStore(resolveBaseDir: () async => base);
        await Future.wait(<Future<void>>[
          store.save(
            id: 'plan',
            title: 'Planned',
            messages: transcript('plan'),
            modules: const <String>['mod'],
            waitingForSetup: true,
            todos: <TodoItem>[
              const TodoItem(content: 'step one', status: TodoStatus.completed),
              const TodoItem(
                content: 'step two',
                status: TodoStatus.inProgress,
              ),
            ],
          ),
          store.save(id: 'other', title: 'Other', messages: transcript('o')),
        ]);
        final SessionBundle? bundle = await store.loadBundle('plan');
        expect(bundle, isNotNull);
        expect(bundle!.waitingForSetup, isTrue);
        expect(bundle.modules, <String>['mod']);
        expect(bundle.todos, hasLength(2));
        expect(bundle.todos[1].status, TodoStatus.inProgress);
      },
    );

    test('searchAll works while saves are in flight', () async {
      final ChatStore store = ChatStore(resolveBaseDir: () async => base);
      await store.save(
        id: 'a',
        title: 'Chocolate cake',
        messages: transcript('a'),
      );
      final List<ChatSearchHit> hits = await store.searchAll('chocolate');
      expect(hits, isNotEmpty);
      expect(hits.first.sessionId, 'a');
    });
  });

  group('skill_config unset + validation (v1.41.0)', () {
    late Directory docs;
    late SkillRegistry registry;

    const String configFrontMatter =
        'config:\n  - name: API_KEY\n    secret: true\n    required: true\n'
        '  - name: REGION\n    required: false\n';

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('v141_skill_cfg');
      registry = SkillRegistry(resolveBaseDir: () async => docs);
    });

    tearDown(() async {
      if (await docs.exists()) await docs.delete(recursive: true);
    });

    Future<InstalledSkill> install() async {
      final ar.Archive archive = ar.Archive()
        ..addFile(
          file(
            'demo/SKILL.md',
            utf8.encode(
              '---\nname: demo-skill\ndescription: demo\nversion: 1.0.0\n'
              '$configFrontMatter---\n\n# Demo\n',
            ),
          ),
        );
      final SkillInstallReport report = await registry.installFromArchiveBytes(
        ar.ZipEncoder().encode(archive),
        source: 'test',
      );
      return report.skill;
    }

    test('a null value removes a stored key', () async {
      final InstalledSkill skill = await install();
      await registry.writeConfig(skill, <String, String?>{
        'API_KEY': 'S3CR3T',
        'REGION': 'ap-southeast-1',
      });
      await registry.writeConfig(skill, <String, String?>{'REGION': null});
      final Map<String, String> stored = await registry.readConfig(skill);
      expect(stored.containsKey('REGION'), isFalse);
      expect(stored['API_KEY'], 'S3CR3T');
    });

    test('removing the last key deletes the config file', () async {
      final InstalledSkill skill = await install();
      await registry.writeConfig(skill, <String, String?>{'API_KEY': 'K'});
      await registry.writeConfig(skill, <String, String?>{'API_KEY': null});
      final File cfg = File(
        '${skill.dirPath}${Platform.pathSeparator}.zconfig.json',
      );
      expect(cfg.existsSync(), isFalse);
    });
  });

  group('installBundled (v1.41.0)', () {
    late Directory docs;
    late SkillRegistry registry;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('v141_bundled');
      registry = SkillRegistry(resolveBaseDir: () async => docs);
    });

    tearDown(() async {
      if (await docs.exists()) await docs.delete(recursive: true);
    });

    const String bundledMd =
        '---\nname: demo-bundle\ndescription: bundled demo\nversion: 1.0.0\n'
        'config:\n  - name: TOKEN\n    secret: true\n    required: true\n'
        '---\n\n# Bundled\n';

    test('reinstall carries over the stored config', () async {
      final SkillInstallReport first = await registry.installBundled(
        bundledName: 'demo-bundle',
        skillMd: bundledMd,
      );
      await registry.writeConfig(first.skill, <String, String?>{
        'TOKEN': 'keep-me',
      });
      // Reinstall the SAME bundled content: the old code wiped .zconfig.json.
      final SkillInstallReport again = await registry.installBundled(
        bundledName: 'demo-bundle',
        skillMd: bundledMd,
      );
      final Map<String, String> stored = await registry.readConfig(again.skill);
      expect(stored['TOKEN'], 'keep-me');
      expect(again.notes.join(' '), contains('config was kept'));
    });

    test('update() refuses a bundled skill honestly', () async {
      await registry.installBundled(
        bundledName: 'demo-bundle',
        skillMd: bundledMd,
      );
      await expectLater(
        registry.update('demo-bundle'),
        throwsA(
          isA<SkillRegistryException>().having(
            (SkillRegistryException e) => e.message,
            'message',
            contains('bundled with the app'),
          ),
        ),
      );
    });
  });

  group('SkillRegistry.update (v1.41.0)', () {
    late Directory docs;
    late SkillRegistry installer;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('v141_skill_upd');
      installer = SkillRegistry(resolveBaseDir: () async => docs);
    });

    tearDown(() async {
      if (await docs.exists()) await docs.delete(recursive: true);
    });

    List<int> zipSkillVersion(String version) {
      final ar.Archive archive = ar.Archive()
        ..addFile(
          file(
            'demo/SKILL.md',
            utf8.encode(
              '---\nname: demo-skill\ndescription: demo\nversion: $version\n'
              'config:\n  - name: API_KEY\n    secret: true\n'
              '    required: true\n---\n\n# Demo v$version\n',
            ),
          ),
        );
      return ar.ZipEncoder().encode(archive);
    }

    SkillRegistry remoteRegistry(List<int> bytes) => SkillRegistry(
      resolveBaseDir: () async => docs,
      client: MockClient((http.Request request) async {
        expect(request.url.host, 'example.com');
        return http.Response.bytes(bytes, 200);
      }),
    );

    test('reports up-to-date when the remote version matches', () async {
      await installer.installFromArchiveBytes(
        zipSkillVersion('1.0.0'),
        source: 'https://example.com/skill.tar.gz',
      );
      final SkillRegistry remote = remoteRegistry(zipSkillVersion('1.0.0'));
      final SkillUpdateReport outcome = await remote.update('demo-skill');
      expect(outcome.upToDate, isTrue);
      expect(outcome.previousVersion, '1.0.0');
      expect(outcome.remoteVersion, '1.0.0');
    });

    test('installs a newer version and keeps the stored secrets', () async {
      final SkillInstallReport first = await installer.installFromArchiveBytes(
        zipSkillVersion('1.0.0'),
        source: 'https://example.com/skill.tar.gz',
      );
      await installer.writeConfig(first.skill, <String, String?>{
        'API_KEY': 'S3CR3T',
      });

      final SkillRegistry remote = remoteRegistry(zipSkillVersion('2.0.0'));
      final SkillUpdateReport outcome = await remote.update('demo-skill');
      expect(outcome.upToDate, isFalse);
      expect(outcome.previousVersion, '1.0.0');
      expect(outcome.remoteVersion, '2.0.0');
      expect(outcome.skill.version, '2.0.0');
      expect(outcome.report, isNotNull);

      // Post-update state. The registry cache is per-instance (refreshed by
      // its own writes — the ModuleRegistry pattern; production uses one
      // singleton), so freshness is asserted on the instance that performed
      // the update AND on a brand-new reader, which proves the on-disk
      // registry records the new version.
      final List<InstalledSkill> list = await remote.list();
      expect(list, hasLength(1));
      expect(list.first.version, '2.0.0');
      final SkillRegistry freshReader = SkillRegistry(
        resolveBaseDir: () async => docs,
      );
      final List<InstalledSkill> persisted = await freshReader.list();
      expect(persisted, hasLength(1));
      expect(persisted.first.version, '2.0.0');
      final Map<String, String> stored = await freshReader.readConfig(
        persisted.first,
      );
      expect(stored['API_KEY'], 'S3CR3T');
    });

    test('refuses a file-installed skill honestly', () async {
      await installer.installFromArchiveBytes(
        zipSkillVersion('1.0.0'),
        source: 'file:/tmp/somewhere.zip',
      );
      await expectLater(
        installer.update('demo-skill'),
        throwsA(
          isA<SkillRegistryException>().having(
            (SkillRegistryException e) => e.message,
            'message',
            contains('local archive'),
          ),
        ),
      );
    });

    test('unknown skill is an error, not a silent success', () async {
      final SkillRegistry remote = remoteRegistry(zipSkillVersion('1.0.0'));
      await expectLater(
        remote.update('ghost'),
        throwsA(isA<SkillRegistryException>()),
      );
    });
  });

  group('skill_* tool dispatch (v1.41.0, through ToolExecutor)', () {
    late Directory docs;
    late Directory workspace;
    late SkillRegistry registry;
    late ToolExecutor executor;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('v141_exec_docs');
      workspace = await Directory.systemTemp.createTemp('v141_exec_ws');
      // Deterministic 404: skill_update's re-download fails with a clear
      // registry error instead of a real network call.
      registry = SkillRegistry(
        resolveBaseDir: () async => docs,
        client: MockClient(
          (http.Request request) async => http.Response('nope', 404),
        ),
      );
      executor = ToolExecutor(
        browser: ScriptedBrowserAutomation(
          workspace.path,
          writeScreenshot: false,
        ),
        resolveBaseDir: (_) async => workspace,
        isAutomationEnabled: () => true,
        js: ScriptedJsRuntime(),
        skills: registry,
      );
    });

    tearDown(() async {
      if (await docs.exists()) await docs.delete(recursive: true);
      if (await workspace.exists()) await workspace.delete(recursive: true);
    });

    Future<InstalledSkill> installDemo() async {
      final ar.Archive archive = ar.Archive()
        ..addFile(
          file(
            'demo/SKILL.md',
            utf8.encode(
              '---\nname: demo-skill\ndescription: demo\nversion: 1.0.0\n'
              'config:\n  - name: API_KEY\n    secret: true\n'
              '    required: true\n---\n\n# Demo\n',
            ),
          ),
        );
      final SkillInstallReport report = await registry.installFromArchiveBytes(
        ar.ZipEncoder().encode(archive),
        source: 'https://example.com/skill.tar.gz',
      );
      return report.skill;
    }

    test('unknown config keys are rejected with the declared list', () async {
      await installDemo();
      final ToolResult result = await executor.execute('skill_config', {
        'name': 'demo-skill',
        'values': <String, dynamic>{'API_TYPO': 'oops'},
      });
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('Unknown config key(s)'));
      expect(result.llmOutput, contains('API_TYPO'));
      expect(result.llmOutput, contains('API_KEY'));
    });

    test('null values unset stored keys through the tool surface', () async {
      await installDemo();
      await executor.execute('skill_config', {
        'name': 'demo-skill',
        'values': <String, dynamic>{'API_KEY': 'temp'},
      });
      final ToolResult unset = await executor.execute('skill_config', {
        'name': 'demo-skill',
        'values': <String, dynamic>{'API_KEY': null},
      });
      expect(unset.ok, isTrue);
      expect(unset.llmOutput, contains('Null values removed'));
      final InstalledSkill skill = (await registry.list()).first;
      expect(await registry.readConfig(skill), isEmpty);
    });

    test(
      'skill_update dispatch reaches the registry and reports the bump',
      () async {
        await installDemo();
        // The mocked client answers 404 — the failure must surface as an
        // honest tool error, never a fake success.
        final ToolResult result = await executor.execute('skill_update', {
          'name': 'demo-skill',
        });
        expect(result.ok, isFalse);
        expect(result.llmOutput, contains('skill_update failed'));
      },
    );

    test('skill_update on an unknown skill fails cleanly', () async {
      final ToolResult result = await executor.execute('skill_update', {
        'name': 'ghost',
      });
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('not installed'));
    });
  });

  group('GitHub branch-root URL normalization (v1.41.0)', () {
    late Directory docs;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('v141_gh_url');
    });

    tearDown(() async {
      if (await docs.exists()) await docs.delete(recursive: true);
    });

    test('https://github.com/o/r/tree/branch installs the branch tarball', () async {
      final List<int> tarGz = ar.GZipEncoder().encode(
        ar.TarEncoder().encode(
          ar.Archive()..addFile(
            file(
              'repo-main/SKILL.md',
              utf8.encode(
                '---\nname: root-url-skill\ndescription: branch root\n---\nhi',
              ),
            ),
          ),
        ),
      );
      final SkillRegistry registry = SkillRegistry(
        resolveBaseDir: () async => docs,
        client: MockClient((http.Request request) async {
          // The OLD code produced subPath "tree/branch" and never reached a
          // valid tarball URL; the fix normalizes to o/r@branch.
          expect(request.url.host, 'codeload.github.com');
          expect(request.url.path, '/o/r/tar.gz/refs/heads/branch');
          return http.Response.bytes(tarGz, 200);
        }),
      );
      final SkillInstallReport report = await registry.install(
        'https://github.com/o/r/tree/branch',
      );
      expect(report.skill.name, 'root-url-skill');
      // The @branch suffix is preserved in the stored source so a later
      // skill_update re-downloads from the same branch.
      expect(report.skill.source, 'github:o/r@branch');
    });

    test('tree/<branch>/<path> still keeps the subpath', () async {
      final List<int> tarGz = ar.GZipEncoder().encode(
        ar.TarEncoder().encode(
          ar.Archive()..addFile(
            file(
              'repo-main/skills/demo/SKILL.md',
              utf8.encode(
                '---\nname: sub-skill\ndescription: with path\n---\nhi',
              ),
            ),
          ),
        ),
      );
      final SkillRegistry registry = SkillRegistry(
        resolveBaseDir: () async => docs,
        client: MockClient((http.Request request) async {
          expect(request.url.host, 'codeload.github.com');
          expect(request.url.path, '/o/r/tar.gz/refs/heads/main');
          return http.Response.bytes(tarGz, 200);
        }),
      );
      final SkillInstallReport report = await registry.install(
        'https://github.com/o/r/tree/main/skills/demo',
      );
      expect(report.skill.name, 'sub-skill');
      expect(report.skill.source, 'github:o/r/skills/demo@main');
    });
  });
}
