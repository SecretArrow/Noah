import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:noah/services/module_registry.dart';
import 'package:noah/ui/screens/modules_screen.dart';

/// Guard for the module development kit that lives in the repository:
///
/// * `sdk/`       — official SDK shim, TypeScript definitions, package metadata
/// * `samples/`   — complete, installable example modules
/// * `docs/modules/` — official SDK reference (EN + ID), shipped in-app
///
/// These directories are developer-facing AND partially bundled into the
/// app as assets (pubspec.yaml). This suite fails when any piece goes
/// missing, drifts out of the app bundle, or ships a broken sample —
/// so the folders can never silently disappear again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sdk/ — official SDK package', () {
    test('shim is bundled as an app asset (pubspec wiring intact)', () async {
      final String source = await rootBundle.loadString('sdk/zagents-sdk.js');
      expect(source, contains('module.exports = zagents'));
      expect(source, contains("require('zagents-sdk')"));
    });

    test('package.json points at the real files', () async {
      // package.json is developer metadata, NOT an app asset — read it
      // from disk; only the shim and the docs ride inside the APK.
      final Map<String, dynamic> json = jsonDecode(
        await File('sdk/package.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(json['name'], 'zagents-sdk');
      expect(json['main'], 'zagents-sdk.js');
      expect(json['types'], 'index.d.ts');
      expect(
        File('sdk/zagents-sdk.js').existsSync(),
        isTrue,
        reason: 'sdk/package.json main file must exist',
      );
      expect(
        File('sdk/index.d.ts').existsSync(),
        isTrue,
        reason: 'sdk/package.json types file must exist',
      );
    });

    test(
      'TypeScript definitions cover the full documented API surface',
      () async {
        final String dts = await File('sdk/index.d.ts').readAsString();
        expect(dts, contains('interface ZAgentsSdk'));
        // Every capability from the reference docs is typed.
        for (final String member in <String>[
          'info',
          'log',
          'chat',
          'http',
          'storage',
          'fs',
          'agent',
          'device',
        ]) {
          expect(dts, contains(member), reason: 'missing SDK member: $member');
        }
        for (final String method in <String>[
          'emit',
          'request',
          'set',
          'get',
          'keys',
          'remove',
          'readFile',
          'writeFile',
          'appendFile',
          'readdir',
          'mkdir',
          'unlink',
          'stat',
          'compose',
          'shell',
          'airplane',
          'airplaneCycle',
        ]) {
          expect(
            dts,
            contains(method),
            reason: 'missing SDK method in typings: $method',
          );
        }
      },
    );

    test('README links the other development-kit folders', () async {
      final String readme = await File('sdk/README.md').readAsString();
      expect(readme, contains('docs/modules/sdk-reference-en.md'));
      expect(readme, contains('samples/'));
    });
  });

  group('docs/modules/ — official reference (EN + ID)', () {
    for (final String asset in <String>[
      SdkDocsScreen.docAssetEn,
      SdkDocsScreen.docAssetId,
    ]) {
      test('$asset is bundled and complete', () async {
        final String doc = await rootBundle.loadString(asset);
        expect(doc, isNotEmpty);
        // The in-app viewer and the repo doc share one source; keep the
        // documented API sections in place.
        for (final String section in <String>[
          'zagents.storage',
          'zagents.fs',
          'zagents.http',
          'zagents.chat',
          'zagents.agent',
          'zagents.device',
          'agent.compose',
          'allowedHosts',
          'module.json',
          'appendFile',
          'samples/',
          'sdk/',
          'onhomeroom-daily',
          'airplane-mode',
        ]) {
          expect(
            doc,
            contains(section),
            reason: '$asset is missing section: $section',
          );
        }
      });
    }

    test('reference README indexes both languages', () async {
      final String readme = await File('docs/modules/README.md').readAsString();
      expect(readme, contains('sdk-reference-en.md'));
      expect(readme, contains('sdk-reference-id.md'));
    });
  });

  group('samples/ — installable example modules', () {
    final Directory samplesDir = Directory('samples');
    final List<String> sampleNames =
        samplesDir
            .listSync()
            .whereType<Directory>()
            .map(
              (Directory d) => d.uri.pathSegments.reversed
                  .skip(1)
                  .firstWhere((String s) => s.isNotEmpty),
            )
            .toList()
          ..sort();

    test('all five permission-covering samples are present', () {
      expect(
        sampleNames,
        containsAll(<String>[
          'counter',
          'network-fetcher',
          'file-notes',
          'chat-streamer',
          'onhomeroom-daily',
        ]),
      );
    });

    for (final String sample in sampleNames) {
      test('sample "$sample" is a valid, installable module', () async {
        final File manifestFile = File('samples/$sample/module.json');
        expect(
          manifestFile.existsSync(),
          isTrue,
          reason: 'samples/$sample must ship module.json',
        );
        final Map<String, dynamic> manifest = jsonDecode(
          await manifestFile.readAsString(),
        ) as Map<String, dynamic>;

        // Name is canonical (already sanitized) and stable.
        final String name = manifest['name'] as String;
        expect(
          name,
          ModuleManifest.sanitizeName(name),
          reason: 'manifest name must already be canonical',
        );
        expect(name.length, lessThanOrEqualTo(ModuleManifest.maxNameLength));
        expect(
          (manifest['version'] as String? ?? '').isNotEmpty,
          isTrue,
          reason: 'samples must declare a version',
        );

        // Entry point exists inside the sample.
        final String entry = manifest['entry'] as String? ?? 'main.js';
        expect(
          File('samples/$sample/$entry').existsSync(),
          isTrue,
          reason: 'samples/$sample entry "$entry" must exist',
        );

        // Permissions are real (unknown names would be silently dropped
        // by the runtime — a sample must never rely on that).
        final Object? permissions = manifest['permissions'];
        expect(permissions, isA<List<dynamic>>());
        for (final Object? permission in permissions! as List<dynamic>) {
          expect(
            modulePermissionFromName(permission.toString()),
            isNotNull,
            reason:
                'sample "$sample" requests unknown permission '
                '"$permission"',
          );
        }

        // Network samples must declare their allowlist — UNLESS the
        // sample is deliberately unrestricted (a browser/reader must
        // reach any host), which it may only express through the
        // explicit `unrestrictedNetwork` manifest marker plus a
        // description that says so. No silent unrestricted network.
        if ((permissions as List<dynamic>).contains('network')) {
          final bool allowlisted =
              (manifest['allowedHosts'] as List<dynamic>? ?? const <dynamic>[])
                  .isNotEmpty;
          final bool declaredUnrestricted =
              manifest['unrestrictedNetwork'] == true &&
              (manifest['description'] as String? ?? '').toUpperCase().contains(
                'UNRESTRICTED',
              );
          expect(
            allowlisted || declaredUnrestricted,
            isTrue,
            reason:
                'network sample "$sample" must declare allowedHosts, '
                'or deliberately declare unrestrictedNetwork: true and '
                'document it (no silent unrestricted network)',
          );
        }

        // Every sample documents itself.
        expect(
          File('samples/$sample/README.md').existsSync(),
          isTrue,
          reason: 'samples/$sample must ship a README',
        );
      });
    }

    test('samples README explains packaging + install', () async {
      final String readme = await File('samples/README.md').readAsString();
      expect(readme, contains('zip'));
      expect(readme, contains('/plugins'));
      expect(readme, contains('Install module'));
    });
  });

  group('samples/ — installable ZIPs (one per sample, always fresh)', () {
    final Directory samplesDir = Directory('samples');
    final List<String> zipSampleNames =
        samplesDir
            .listSync()
            .whereType<Directory>()
            .map(
              (Directory d) => d.uri.pathSegments.reversed
                  .skip(1)
                  .firstWhere((String s) => s.isNotEmpty),
            )
            .toList()
          ..sort();

    for (final String sample in zipSampleNames) {
      test('samples/$sample.zip exists and matches its folder', () async {
        final File zipFile = File('samples/$sample.zip');
        expect(
          zipFile.existsSync(),
          isTrue,
          reason:
              'samples/$sample.zip is missing — re-zip the sample folder '
              '(the repo ships one ready-to-install zip per sample)',
        );

        final Archive archive = ZipDecoder().decodeBytes(
          await zipFile.readAsBytes(),
        );

        // the archive must carry exactly the folder's files: a missing
        // file means a stale zip; an extra file means a stale zip too
        final List<String> folderFiles =
            Directory('samples/$sample')
                .listSync(recursive: true)
                .whereType<File>()
                .map(
                  (File f) =>
                      '$sample/${f.path.substring('samples/$sample/'.length).replaceAll('\\', '/')}'
                          .replaceAll('//', '/'),
                )
                .toList()
              ..sort();
        final Set<String> archiveFileNames = archive.files
            .where((ArchiveFile e) => e.isFile)
            .map((ArchiveFile e) => e.name.replaceAll('\\', '/'))
            .toSet();
        expect(
          archiveFileNames,
          folderFiles.toSet(),
          reason:
              'samples/$sample.zip drifted from samples/$sample/ — '
              're-zip the folder',
        );

        // the manifest inside the zip must declare a canonical module
        // name (the folder and the module name may legitimately differ,
        // e.g. samples/counter ships the hello-counter module)
        final ArchiveFile manifestFile = archive.files.firstWhere(
          (ArchiveFile e) => e.name == '$sample/module.json',
        );
        final Map<String, dynamic> manifest = jsonDecode(
          utf8.decode(manifestFile.content as List<int>),
        ) as Map<String, dynamic>;
        final String moduleName = manifest['name'] as String;
        expect(
          moduleName,
          ModuleManifest.sanitizeName(moduleName),
          reason: 'zip manifest name must already be canonical',
        );
      });
    }

    test('samples README points at the ready-made zips', () async {
      final String readme = await File('samples/README.md').readAsString();
      expect(readme, contains('.zip'));
    });
  });

  group('samples/onhomeroom-daily — fully agent-composed (no templates)', () {
    const String mainJsPath = 'samples/onhomeroom-daily/main.js';

    test('no canned text pools or hand-written idea tables remain', () async {
      final String source = await File(mainJsPath).readAsString();
      // the removed idea table must stay gone — reintroducing a pool of
      // pre-written concepts would break the "full agent" contract
      expect(source, isNot(contains('const IDEAS')));
      const List<String> cannedIdeas = <String>[
        'Study Timer',
        'Flashcard Quiz',
        'Class Poll',
        'Reading Log',
        'Habit Tracker',
        'Group Scheduler',
        'Word of the Day',
      ];
      for (final String canned in cannedIdeas) {
        expect(
          source,
          isNot(contains(canned)),
          reason: 'canned idea leaked back into the sample: $canned',
        );
      }
    });

    test(
      'every sentence flows through the single gated compose call',
      () async {
        final String source = await File(mainJsPath).readAsString();
        // exactly ONE zagents.agent.compose call site: the Composer.compose
        // helper that applies the host gate — every text path must ride it
        expect(
          RegExp(r'zagents\.agent\.compose\(').allMatches(source).length,
          1,
          reason: 'all composed text must pass through the one gated helper',
        );
        // the build-request concept is invented live by the agent
        expect(source, contains("'build-request-concept'"));
        expect(source, contains("'build-request-body'"));
        expect(source, contains("'build-request-title'"));
        // the go-ahead DM is composed when the site ships no button label
        expect(source, contains("'go-ahead'"));
        expect(source, isNot(contains("|| 'Go ahead'")));
      },
    );

    test(
      'main.js parses as JavaScript (node --check, skipped without node)',
      () async {
        bool nodeAvailable = false;
        try {
          final ProcessResult probe = await Process.run('node', const <String>[
            '--version',
          ]);
          nodeAvailable = probe.exitCode == 0;
        } catch (_) {
          nodeAvailable = false;
        }
        if (!nodeAvailable) return; // environments without node rely on CI
        final ProcessResult result = await Process.run('node', const <String>[
          '--check',
          mainJsPath,
        ]);
        expect(
          result.exitCode,
          0,
          reason: 'node --check failed:\n${result.stderr}',
        );
      },
    );
  });
}
