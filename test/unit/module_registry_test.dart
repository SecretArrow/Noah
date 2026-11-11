import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/module_registry.dart';

/// Builds a ZIP in memory from {path: bytes}.
List<int> buildZip(Map<String, List<int>> files) {
  final Archive archive = Archive();
  files.forEach((String path, List<int> bytes) {
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

List<int> textZip(Map<String, String> files) => buildZip(<String, List<int>>{
  for (final MapEntry<String, String> e in files.entries)
    e.key: e.value.codeUnits,
});

void main() {
  late Directory tempDir;
  late ModuleRegistry registry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('module_registry_test');
    registry = ModuleRegistry(resolveBaseDir: () async => tempDir);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('ModuleManifest', () {
    test('sanitizes hostile names into safe directory names', () {
      expect(ModuleManifest.sanitizeName('My Cool Module!'), 'my-cool-module');
      expect(ModuleManifest.sanitizeName('../../etc/passwd'), 'etc-passwd');
      expect(ModuleManifest.sanitizeName('..'), 'module');
      expect(ModuleManifest.sanitizeName(''), 'module');
      expect(ModuleManifest.sanitizeName('A' * 60).length, 40);
      expect(ModuleManifest.sanitizeName('...'), 'module');
    });

    test('parses permissions defensively and drops unknown names', () {
      final ModuleManifest manifest = ModuleManifest.fromJson(<String, dynamic>{
        'name': 'demo',
        'permissions': <String>['storage', 'nonsense', 'network'],
      });
      expect(manifest.permissions, <ModulePermission>{
        ModulePermission.storage,
        ModulePermission.network,
      });
      expect(manifest.entry, 'main.js');
      expect(manifest.timeout, const Duration(seconds: 30));
    });

    test('clamps the timeout to the documented maximum', () {
      final ModuleManifest manifest = ModuleManifest.fromJson(<String, dynamic>{
        'name': 'demo',
        'timeoutSeconds': 9999,
      });
      expect(manifest.timeout.inSeconds, ModuleManifest.maxTimeoutSeconds);
    });
  });

  group('ModuleSetup (per-chat setup form)', () {
    test('parses fields defensively: types, keys, caps, dedupe', () {
      final ModuleSetup? setup = ModuleSetup.fromJson(<String, dynamic>{
        'title': 'Acct',
        'description': 'creds',
        'fields': <dynamic>[
          <String, dynamic>{'key': 'Email', 'label': 'Email', 'required': true},
          <String, dynamic>{'key': 'email', 'label': 'Duplicate dropped'},
          <String, dynamic>{
            'key': 'pass',
            'type': 'password',
            'required': true,
            'placeholder': 'hunter2',
          },
          <String, dynamic>{'key': 'retries', 'type': 'number'},
          <String, dynamic>{'key': 'verbose', 'type': 'boolean'},
          <String, dynamic>{'key': 'weird type', 'type': 'nonsense'},
          <String, dynamic>{'key': '', 'label': 'dropped (no key)'},
          'not-a-map',
        ],
      });
      expect(setup, isNotNull);
      // email, pass, retries, verbose, weird_type — duplicate/empty/
      // non-map entries dropped, keys sanitized, first duplicate wins.
      expect(setup!.fields, hasLength(5));
      expect(setup.fields.first.key, 'email');
      expect(setup.fields.first.required, isTrue);
      expect(setup.fields[1].type, ModuleSetupFieldType.password);
      expect(setup.fields[2].type, ModuleSetupFieldType.number);
      expect(setup.fields[3].type, ModuleSetupFieldType.boolean);
      // Unknown type degrades to text; key whitespace collapsed.
      expect(setup.fields.last.type, ModuleSetupFieldType.text);
      expect(setup.fields.last.key, 'weird_type');
      expect(setup.hasRequired, isTrue);
    });

    test('caps the field list at 12 and long text fields', () {
      final List<Map<String, dynamic>> many = <Map<String, dynamic>>[
        for (int i = 0; i < 20; i++)
          <String, dynamic>{'key': 'f$i', 'label': 'F$i'},
      ];
      final ModuleSetup? setup = ModuleSetup.fromJson(<String, dynamic>{
        'title': 'T' * 100,
        'fields': many,
      });
      expect(setup, isNotNull);
      expect(setup!.fields, hasLength(ModuleSetup.maxFields));
      expect(setup.title.length, 80);
    });

    test('empty or unusable blocks parse to null', () {
      expect(
        ModuleSetup.fromJson(<String, dynamic>{'fields': <dynamic>[]}),
        isNull,
      );
      expect(
        ModuleSetup.fromJson(<String, dynamic>{
          'fields': <dynamic>['x'],
        }),
        isNull,
      );
      expect(ModuleSetup.fromJson(<String, dynamic>{}), isNull);
    });

    test('satisfiedBy gates on required fields only', () {
      final ModuleSetup setup = ModuleSetup.fromJson(<String, dynamic>{
        'fields': <dynamic>[
          <String, dynamic>{'key': 'user', 'required': true},
          <String, dynamic>{'key': 'note'},
          <String, dynamic>{
            'key': 'retries',
            'type': 'number',
            'required': true,
          },
          <String, dynamic>{'key': 'verbose', 'type': 'boolean'},
        ],
      })!;
      expect(setup.satisfiedBy(null), isFalse);
      expect(setup.satisfiedBy(<String, dynamic>{}), isFalse);
      expect(
        setup.satisfiedBy(<String, dynamic>{'user': 'a'}),
        isFalse,
      ); // required number missing
      expect(
        setup.satisfiedBy(<String, dynamic>{'user': '  ', 'retries': 3}),
        isFalse,
      ); // blank text
      expect(
        setup.satisfiedBy(<String, dynamic>{'user': 'a', 'retries': 'x'}),
        isFalse,
      ); // wrong type
      expect(
        setup.satisfiedBy(<String, dynamic>{
          'user': 'a',
          'retries': 3,
          'verbose': false,
        }),
        isTrue,
      ); // boolean false counts as filled
      expect(
        setup.satisfiedBy(<String, dynamic>{'user': 'a', 'retries': 2.5}),
        isTrue,
      );
    });

    test('no required fields means never blocked', () {
      final ModuleSetup setup = ModuleSetup.fromJson(<String, dynamic>{
        'fields': <dynamic>[
          <String, dynamic>{'key': 'note'},
        ],
      })!;
      expect(setup.hasRequired, isFalse);
      expect(setup.satisfiedBy(null), isTrue);
    });

    test('manifest round-trips the setup block through toJson', () {
      final ModuleManifest manifest = ModuleManifest.fromJson(<String, dynamic>{
        'name': 'demo',
        'setup': <String, dynamic>{
          'title': 'Acct',
          'fields': <dynamic>[
            <String, dynamic>{'key': 'email', 'required': true},
            <String, dynamic>{
              'key': 'pass',
              'type': 'password',
              'required': true,
            },
          ],
        },
      });
      expect(manifest.setup, isNotNull);
      expect(manifest.setup!.fields, hasLength(2));
      final ModuleManifest restored = ModuleManifest.fromJson(
        manifest.toJson(),
      );
      expect(restored.setup, isNotNull);
      expect(restored.setup!.title, 'Acct');
      expect(restored.setup!.fields.map((f) => f.key), <String>[
        'email',
        'pass',
      ]);
      expect(restored.setup!.fields.every((f) => f.required), isTrue);
    });

    test('ChatModule persistence keeps the setup block', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}setup.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{
            'module.json':
                '{"name":"setupmod","setup":{"title":"Acct","fields":['
                '{"key":"email","type":"text","required":true},'
                '{"key":"pass","type":"password","required":true}]}}',
            'main.js': 'module.exports = 1;',
          }),
        );
      final ModuleInstallResult result = await registry.installFromZip(
        zip.path,
      );
      expect(result.ok, isTrue, reason: result.message);
      final List<ChatModule> installed = await registry.listInstalled();
      expect(installed.single.manifest.setup, isNotNull);
      expect(installed.single.manifest.setup!.fields, hasLength(2));
    });
  });

  group('installFromZip', () {
    test('installs a flat module with module.json', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}demo.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{
            'module.json':
                '{"name":"demo","version":"1.2.0","description":"Demo module",'
                '"permissions":["storage"],"entry":"main.js"}',
            'main.js': "console.log('hi');",
            'lib/util.js': 'module.exports = 1;',
          }),
        );
      final ModuleInstallResult result = await registry.installFromZip(
        zip.path,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(result.module!.name, 'demo');
      expect(result.module!.manifest.version, '1.2.0');
      expect(
        File(result.module!.entryPath).readAsStringSync(),
        contains('console.log'),
      );
      expect(
        File(
          '${result.module!.path}${Platform.pathSeparator}lib'
          '${Platform.pathSeparator}util.js',
        ).existsSync(),
        isTrue,
      );
      // Registry persistence: a fresh instance sees the module.
      final List<ChatModule> installed = await registry.listInstalled();
      expect(installed, hasLength(1));
      expect(installed.single.manifest.description, 'Demo module');
    });

    test(
      'getSync reflects installs and removals immediately (no reload)',
      () async {
        // Regression guard (v1.27.0): _saveRegistry must refresh the
        // synchronous view — the module-builder isNew check and the chat
        // system prompt read getSync() without awaiting a disk reload.
        expect(registry.getSync('demo'), isNull);
        final File zip =
            File('${tempDir.path}${Platform.pathSeparator}demo.zip')
              ..writeAsBytesSync(
                textZip(<String, String>{
                  'module.json':
                      '{"name":"demo","version":"1.0.0","entry":"main.js"}',
                  'main.js': 'module.exports = 1;',
                }),
              );
        expect((await registry.installFromZip(zip.path)).ok, isTrue);
        expect(registry.getSync('demo'), isNotNull);
        expect(registry.getSync('demo')!.manifest.version, '1.0.0');

        // Re-install replaces the sync view too.
        final File zip2 =
            File('${tempDir.path}${Platform.pathSeparator}demo2.zip')
              ..writeAsBytesSync(
                textZip(<String, String>{
                  'module.json':
                      '{"name":"demo","version":"2.0.0","entry":"main.js"}',
                  'main.js': 'module.exports = 2;',
                }),
              );
        expect((await registry.installFromZip(zip2.path)).ok, isTrue);
        expect(registry.getSync('demo')!.manifest.version, '2.0.0');

        // Removal clears it.
        expect(await registry.remove('demo'), isTrue);
        expect(registry.getSync('demo'), isNull);
      },
    );

    test('unwraps a single top-level directory (GitHub ZIP layout)', () async {
      final File zip =
          File('${tempDir.path}${Platform.pathSeparator}wrapped.zip')
            ..writeAsBytesSync(
              textZip(<String, String>{
                'wrapped-main/module.json': '{"name":"wrapped"}',
                'wrapped-main/main.js': 'module.exports = "ok";',
              }),
            );
      final ModuleInstallResult result = await registry.installFromZip(
        zip.path,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(result.module!.name, 'wrapped');
      expect(File(result.module!.entryPath).existsSync(), isTrue);
    });

    test('falls back to package.json (name/version/main)', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}pkged.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{
            'package.json':
                '{"name":"pkged","version":"0.1.0","main":"lib/entry.js"}',
            'lib/entry.js': 'module.exports = "entry";',
          }),
        );
      final ModuleInstallResult result = await registry.installFromZip(
        zip.path,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(result.module!.name, 'pkged');
      expect(result.module!.manifest.entry, 'lib/entry.js');
    });

    test('falls back to the ZIP file name without any manifest', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}bare.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{'main.js': 'module.exports = "bare";'}),
        );
      final ModuleInstallResult result = await registry.installFromZip(
        zip.path,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(result.module!.name, 'bare');
    });

    test('rejects a missing entry point with a clear message', () async {
      final File zip =
          File('${tempDir.path}${Platform.pathSeparator}broken.zip')
            ..writeAsBytesSync(
              textZip(<String, String>{
                'module.json': '{"name":"broken","entry":"start.js"}',
                'main.js': '// not the declared entry',
              }),
            );
      final ModuleInstallResult result = await registry.installFromZip(
        zip.path,
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('start.js'));
    });

    test('blocks zip-slip path traversal entries', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}evil.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{
            'module.json': '{"name":"evil"}',
            'main.js': '// ok',
            '../escaped.js': 'module.exports = "pwned";',
          }),
        );
      final ModuleInstallResult result = await registry.installFromZip(
        zip.path,
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('Unsafe ZIP entry'));
      // Nothing was installed.
      expect(await registry.listInstalled(), isEmpty);
      expect(
        File('${tempDir.path}${Platform.pathSeparator}escaped.js').existsSync(),
        isFalse,
      );
    });

    test('rejects invalid archives and empty ZIPs', () async {
      final File garbage = File(
        '${tempDir.path}${Platform.pathSeparator}garbage.zip',
      )..writeAsBytesSync(<int>[1, 2, 3, 4]);
      expect((await registry.installFromZip(garbage.path)).ok, isFalse);

      final File empty = File(
        '${tempDir.path}${Platform.pathSeparator}empty.zip',
      )..writeAsBytesSync(buildZip(<String, List<int>>{}));
      expect((await registry.installFromZip(empty.path)).ok, isFalse);

      final File missing = File(
        '${tempDir.path}${Platform.pathSeparator}nope.zip',
      );
      expect((await registry.installFromZip(missing.path)).ok, isFalse);
    });

    test('re-installing the same name replaces the module', () async {
      final File first =
          File('${tempDir.path}${Platform.pathSeparator}replace.zip')
            ..writeAsBytesSync(
              textZip(<String, String>{
                'module.json': '{"name":"replace","version":"1.0.0"}',
                'main.js': 'v1',
              }),
            );
      expect((await registry.installFromZip(first.path)).ok, isTrue);

      final File second =
          File('${tempDir.path}${Platform.pathSeparator}replace2.zip')
            ..writeAsBytesSync(
              textZip(<String, String>{
                'module.json': '{"name":"replace","version":"2.0.0"}',
                'main.js': 'v2',
                'extra.js': 'x',
              }),
            );
      expect((await registry.installFromZip(second.path)).ok, isTrue);

      final List<ChatModule> installed = await registry.listInstalled();
      expect(installed, hasLength(1));
      expect(installed.single.manifest.version, '2.0.0');
      expect(File(installed.single.entryPath).readAsStringSync(), 'v2');
      // No staging directories left behind.
      final Directory modules = await registry.modulesDir();
      expect(
        modules.listSync().where((e) => e.path.contains('.staging')),
        isEmpty,
      );
    });

    test(
      'remove deletes the directory but keeps chat sandboxes untouched',
      () async {
        final File zip =
            File('${tempDir.path}${Platform.pathSeparator}gone.zip')
              ..writeAsBytesSync(
                textZip(<String, String>{
                  'module.json': '{"name":"gone"}',
                  'main.js': '//',
                }),
              );
        final ChatModule module = (await registry.installFromZip(zip.path))
            .module!;
        // Simulated per-chat state elsewhere.
        final Directory chatState = Directory(
          '${tempDir.path}${Platform.pathSeparator}sessions'
          '${Platform.pathSeparator}s1${Platform.pathSeparator}modules'
          '${Platform.pathSeparator}gone',
        )..createSync(recursive: true);
        File('${chatState.path}${Platform.pathSeparator}storage.json')
            .writeAsStringSync('{"k":1}');

        expect(await registry.remove('gone'), isTrue);
        expect(Directory(module.path).existsSync(), isFalse);
        expect(
          File('${chatState.path}${Platform.pathSeparator}storage.json')
              .existsSync(),
          isTrue,
        );
        expect(await registry.remove('gone'), isFalse);
      },
    );

    test(
      'get() sanitizes lookups and returns null for unknown modules',
      () async {
        final File zip =
            File('${tempDir.path}${Platform.pathSeparator}named.zip')
              ..writeAsBytesSync(
                textZip(<String, String>{
                  'module.json': '{"name":"named"}',
                  'main.js': '//',
                }),
              );
        await registry.installFromZip(zip.path);
        expect((await registry.get('named'))!.name, 'named');
        expect(await registry.get('NAMED'), isNotNull);
        expect(await registry.get('unknown'), isNull);
      },
    );
  });

  group('validateZip (dry-run intake, no install)', () {
    test('a valid module zip validates and reports its manifest', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}good.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{
            'module.json': '{"name":"doctor","version":"2.0.0"}',
            'main.js': 'module.exports = 1;',
          }),
        );
      final ModuleInstallResult result = await registry.validateZip(zip.path);
      expect(result.ok, isTrue, reason: result.message);
      expect(result.message, contains('doctor v2.0.0'));
      expect(result.module!.manifest.name, 'doctor');
      // NOTHING was installed.
      expect(await registry.get('doctor'), isNull);
    });

    test('a zip with a missing entry fails validation', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}bad.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{'module.json': '{"name":"noentry"}'}),
        );
      final ModuleInstallResult result = await registry.validateZip(zip.path);
      expect(result.ok, isFalse);
      expect(result.message, contains('Entry point'));
    });

    test('a missing file / non-zip fails validation', () async {
      expect(
        (await registry.validateZip(
          '${tempDir.path}${Platform.pathSeparator}ghost.zip',
        )).ok,
        isFalse,
      );
      final File zip = File('${tempDir.path}${Platform.pathSeparator}junk.zip')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      expect((await registry.validateZip(zip.path)).ok, isFalse);
    });
  });

  group('exportToZip (module doctor export)', () {
    test('exports an installed module into a re-installable zip', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}orig.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{
            'module.json': '{"name":"exportme","version":"1.5.0"}',
            'main.js': 'module.exports = "hi";',
            'lib/util.js': 'exports.id = 7;',
          }),
        );
      await registry.installFromZip(zip.path);

      final String target =
          '${tempDir.path}${Platform.pathSeparator}out'
          '${Platform.pathSeparator}exportme.zip';
      final ModuleExportResult result = await registry.exportToZip(
        'exportme',
        target,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(result.fileCount, 3);
      expect(File(target).existsSync(), isTrue);

      // Roundtrip: the export installs again with the same manifest.
      final ModuleInstallResult reinstall = await registry.installFromZip(
        target,
      );
      expect(reinstall.ok, isTrue, reason: reinstall.message);
      final ChatModule? module = await registry.get('exportme');
      expect(module, isNotNull);
      expect(module!.manifest.version, '1.5.0');
      expect(
        File(
          '${module.path}${Platform.pathSeparator}lib${Platform.pathSeparator}util.js',
        ).existsSync(),
        isTrue,
      );
    });

    test('unknown or missing modules fail cleanly', () async {
      expect(
        (await registry.exportToZip(
          'ghost',
          '${tempDir.path}${Platform.pathSeparator}x.zip',
        )).ok,
        isFalse,
      );
    });
  });

  group('exportToZip freshness filter (v1.47.0 source-only export)', () {
    /// Installs the `freshy` module and plants stray runtime data INSIDE
    /// the installed module directory — the legacy-install situation the
    /// freshness filter must defend against (per-chat state now lives in
    /// the session sandbox, but old installs may still carry it in-place).
    Future<Directory> installFreshyWithRuntimeData() async {
      final File zip =
          File('${tempDir.path}${Platform.pathSeparator}freshy.zip')
            ..writeAsBytesSync(
              textZip(<String, String>{
                'module.json':
                    '{"name":"freshy","version":"2.1.0","entry":"main.js"}',
                'main.js': 'module.exports = "hi";',
                'README.md': '# freshy',
              }),
            );
      final ModuleInstallResult install = await registry.installFromZip(
        zip.path,
      );
      expect(install.ok, isTrue, reason: install.message);
      final Directory moduleDir = Directory(
        '${(await registry.modulesDir()).path}'
        '${Platform.pathSeparator}freshy',
      );
      expect(moduleDir.existsSync(), isTrue);
      void plant(String rel, String content) {
        final File f = File(
          '${moduleDir.path}${Platform.pathSeparator}'
          '${rel.replaceAll('/', Platform.pathSeparator)}',
        );
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(content);
      }

      plant('state/storage.json', '{"token":"secret"}');
      plant('debug.log', 'log line');
      plant('cache.db', 'junk bytes');
      plant('node_modules/dep.js', 'module.exports = 1;');
      // Hidden junk is dropped by the PRE-EXISTING hidden rule — it must
      // NOT be counted by the runtime-data counter below.
      plant('.hidden.txt', 'secret');
      return moduleDir;
    }

    test(
      'fresh export keeps source files only and counts excluded runtime data',
      () async {
        await installFreshyWithRuntimeData();
        final String target =
            '${tempDir.path}${Platform.pathSeparator}out'
            '${Platform.pathSeparator}freshy.zip';
        final ModuleExportResult result = await registry.exportToZip(
          'freshy',
          target,
        );
        expect(result.ok, isTrue, reason: result.message);
        // Exactly 4 runtime-data files were skipped (state/storage.json,
        // debug.log, cache.db, node_modules/dep.js). `.hidden.txt` is
        // dropped by the pre-existing hidden rule and stays OUT of the
        // runtime-data counter.
        expect(
          result.message,
          'Exported freshy v2.1.0 (3 files, 4 runtime-data files excluded)',
        );
        expect(result.fileCount, 3);
        final Archive exported = ZipDecoder().decodeBytes(
          File(target).readAsBytesSync(),
        );
        final Set<String> names = <String>{
          for (final ArchiveFile f in exported) f.name,
        };
        expect(names, <String>{'module.json', 'main.js', 'README.md'});
      },
    );

    test('presetZipFileName builds the <name>-v<version>.zip preset', () {
      expect(
        ModuleRegistry.presetZipFileName('rss-reader', '1.3.0'),
        'rss-reader-v1.3.0.zip',
      );
    });

    test('export → reinstall round-trip preserves the version', () async {
      final ModuleInstallResult install = await registry.installFromBytes(
        textZip(<String, String>{
          'module.json': '{"name":"roundtrip","version":"3.2.1"}',
          'main.js': 'module.exports = 1;',
        }),
        'roundtrip',
      );
      expect(install.ok, isTrue, reason: install.message);
      final String target =
          '${tempDir.path}${Platform.pathSeparator}out'
          '${Platform.pathSeparator}'
          '${ModuleRegistry.presetZipFileName('roundtrip', '3.2.1')}';
      final ModuleExportResult result = await registry.exportToZip(
        'roundtrip',
        target,
      );
      expect(result.ok, isTrue, reason: result.message);
      // Nothing was planted → no runtime-data note in the message.
      expect(result.message, 'Exported roundtrip v3.2.1 (2 files)');
      final ModuleInstallResult reinstall = await registry.installFromZip(
        target,
      );
      expect(reinstall.ok, isTrue, reason: reinstall.message);
      final ChatModule? module = await registry.get('roundtrip');
      expect(module, isNotNull);
      expect(module!.manifest.version, '3.2.1');
    });

    test('directory with only runtime data reports no source files', () async {
      final Directory moduleDir = await installFreshyWithRuntimeData();
      // Strip the source files so ONLY runtime data remains.
      for (final String rel in <String>[
        'module.json',
        'main.js',
        'README.md',
      ]) {
        final File f = File('${moduleDir.path}${Platform.pathSeparator}$rel');
        if (f.existsSync()) f.deleteSync();
      }
      final ModuleExportResult result = await registry.exportToZip(
        'freshy',
        '${tempDir.path}${Platform.pathSeparator}none.zip',
      );
      expect(result.ok, isFalse);
      expect(result.message, 'Module directory contains no source files');
    });
  });

  group('readModuleFile (read-only doctor access)', () {
    Future<void> installFixture() async {
      final File zip =
          File('${tempDir.path}${Platform.pathSeparator}readme.zip')
            ..writeAsBytesSync(
              textZip(<String, String>{
                'module.json': '{"name":"reader","version":"1.0.0"}',
                'main.js': 'module.exports = { run() {} };',
                'lib/helper.js': 'exports.f = () => 1;',
              }),
            );
      await registry.installFromZip(zip.path);
    }

    test('reads a file from the module directory', () async {
      await installFixture();
      final ModuleFileRead read = await registry.readModuleFile(
        'reader',
        'lib/helper.js',
      );
      expect(read.ok, isTrue);
      expect(read.content, contains('exports.f'));
    });

    test('an empty path lists the module files instead', () async {
      await installFixture();
      final ModuleFileRead listing = await registry.readModuleFile(
        'reader',
        '',
      );
      expect(listing.ok, isTrue);
      // 3 files + the lib/ directory line.
      expect(listing.listing, hasLength(4));
      expect(
        listing.listing.any((String l) => l.startsWith('main.js')),
        isTrue,
      );
      expect(
        listing.listing.any((String l) => l.startsWith('lib/helper.js')),
        isTrue,
      );
    });

    test('traversal outside the module directory is rejected', () async {
      await installFixture();
      expect(
        (await registry.readModuleFile('reader', '../registry.json')).ok,
        isFalse,
      );
      expect(
        (await registry.readModuleFile(
          'reader',
          '..${Platform.pathSeparator}x',
        )).ok,
        isFalse,
      );
      expect(
        (await registry.readModuleFile('reader', '/etc/passwd')).ok,
        isFalse,
      );
    });

    test('oversized content is truncated, not failed', () async {
      final File zip = File('${tempDir.path}${Platform.pathSeparator}big.zip')
        ..writeAsBytesSync(
          textZip(<String, String>{
            'module.json': '{"name":"bigmod","version":"1.0.0"}',
            'main.js': '// ${'x' * 30000}',
          }),
        );
      await registry.installFromZip(zip.path);
      final ModuleFileRead read = await registry.readModuleFile(
        'bigmod',
        'main.js',
      );
      expect(read.ok, isTrue);
      expect(read.content!.length, lessThan(21000));
      expect(read.content, contains('[truncated'));
    });
  });

  group('manifest commands + module command passthrough (v1.31.0)', () {
    test('moduleCommandKeyword extracts the slash keyword', () {
      expect(moduleCommandKeyword('/airplane on'), 'airplane');
      expect(moduleCommandKeyword('  /AIRPLANE off '), 'airplane');
      expect(moduleCommandKeyword('/make_plugins'), 'make_plugins');
      expect(moduleCommandKeyword('/my_cmd status'), 'my_cmd');
      expect(moduleCommandKeyword('/hyphen-ated x'), 'hyphen-ated');
      expect(moduleCommandKeyword('/airplane'), 'airplane');
      expect(moduleCommandKeyword('airplane on'), isNull);
      expect(moduleCommandKeyword('/'), isNull);
      expect(moduleCommandKeyword('/ spaced'), isNull);
      expect(moduleCommandKeyword(''), isNull);
      expect(moduleCommandKeyword(null), isNull);
    });

    test(
      'sanitizeCommands keeps valid keywords and strips a leading slash',
      () {
        expect(
          ModuleManifest.sanitizeCommands(<dynamic>['Airplane', '/status']),
          <String>['airplane', 'status'],
        );
        expect(ModuleManifest.sanitizeCommands(<dynamic>['  on  ']), <String>[
          'on',
        ]);
      },
    );

    test('sanitizeCommands drops hostile, reserved and overlong entries', () {
      // Reserved built-ins can never be claimed.
      expect(
        ModuleManifest.sanitizeCommands(<dynamic>[
          'plugins',
          'make_plugins',
          'doctor',
        ]),
        isEmpty,
      );
      // Overlong and character-hostile entries vanish; stripped variants
      // of legitimate words survive the sanitization pass.
      expect(
        ModuleManifest.sanitizeCommands(<dynamic>['a' * 25, '!!!', 'ok!']),
        <String>['ok'],
      );
      // Non-list payloads parse to the empty list.
      expect(ModuleManifest.sanitizeCommands('airplane'), isEmpty);
      expect(ModuleManifest.sanitizeCommands(null), isEmpty);
    });

    test('caps at four commands and dedupes', () {
      expect(
        ModuleManifest.sanitizeCommands(<dynamic>[
          'a',
          'b',
          'b',
          'c',
          'd',
          'e',
        ]),
        <String>['a', 'b', 'c', 'd'],
      );
    });

    test('manifest parses commands defensively and round-trips', () {
      final ModuleManifest manifest = ModuleManifest.fromJson(<String, dynamic>{
        'name': 'airplane-mode',
        'version': '1.0.0',
        'commands': <dynamic>['Airplane', 'doctor', 'ok'],
      });
      expect(manifest.commands, <String>['airplane', 'ok']);
      expect(manifest.declaresCommand('airplane'), isTrue);
      expect(manifest.declaresCommand('status'), isFalse);
      expect(
        ModuleManifest.fromJson(<String, dynamic>{
          'name': 'x',
          'commands': <dynamic>['a'],
        }).toJson()['commands'],
        <String>['a'],
      );
      // Manifests without commands stay back-compat: empty + never match.
      expect(
        ModuleManifest.fromJson(<String, dynamic>{'name': 'y'}).commands,
        isEmpty,
      );
    });
  });
}
