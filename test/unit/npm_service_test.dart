import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/npm_service.dart';

/// Builds a gzip tarball like the npm registry serves: a `package/` root
/// containing the given files.
List<int> tarGz(Map<String, String> files) {
  final Archive archive = Archive();
  files.forEach((String path, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  return GZipEncoder().encode(TarEncoder().encode(archive));
}

http.Response jsonRes(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  late Directory tempDir;
  late NpmService service;
  late Map<String, dynamic> registryDb;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_npm_test');
    registryDb = <String, dynamic>{
      'left-pad': <String, dynamic>{
        'dist-tags': <String, dynamic>{'latest': '1.0.0'},
        'versions': <String, dynamic>{
          '1.0.0': <String, dynamic>{
            'dist': <String, dynamic>{
              'tarball':
                  'https://registry.npmjs.org/left-pad/-/left-pad-1.0.0.tgz',
            },
          },
        },
      },
      'tiny-dep': <String, dynamic>{
        'dist-tags': <String, dynamic>{'latest': '2.1.0'},
        'versions': <String, dynamic>{
          '2.1.0': <String, dynamic>{
            'dist': <String, dynamic>{
              'tarball':
                  'https://registry.npmjs.org/tiny-dep/-/tiny-dep-2.1.0.tgz',
            },
          },
        },
      },
    };

    final MockClient client = MockClient((http.Request request) async {
      final String url = request.url.toString();
      if (url.contains('/-/v1/search')) {
        return jsonRes(<String, dynamic>{
          'objects': <dynamic>[
            <String, dynamic>{
              'package': <String, dynamic>{
                'name': 'left-pad',
                'version': '1.0.0',
                'description': 'String left pad',
              },
            },
          ],
        });
      }
      for (final MapEntry<String, dynamic> entry in registryDb.entries) {
        if (url.endsWith('/${entry.key}')) {
          return jsonRes(entry.value);
        }
      }
      if (url.contains('left-pad-1.0.0.tgz')) {
        return http.Response.bytes(
          tarGz(<String, String>{
            'package/package.json': jsonEncode(<String, dynamic>{
              'name': 'left-pad',
              'version': '1.0.0',
              'main': 'index.js',
              'dependencies': <String, dynamic>{'tiny-dep': '^2.0.0'},
            }),
            'package/index.js': 'module.exports = (s, n) => s.padStart(n);',
          }),
          200,
        );
      }
      if (url.contains('tiny-dep-2.1.0.tgz')) {
        return http.Response.bytes(
          tarGz(<String, String>{
            'package/package.json': jsonEncode(<String, dynamic>{
              'name': 'tiny-dep',
              'version': '2.1.0',
              'main': 'index.js',
            }),
            'package/index.js': 'module.exports = 42;',
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    service = NpmService(resolveBaseDir: () async => tempDir, client: client);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('install downloads the package AND its dependencies', () async {
    final NpmInstallResult result = await service.install('left-pad');
    expect(result.ok, isTrue, reason: result.message);
    expect(result.installed, contains('left-pad@1.0.0'));
    expect(result.installed, contains('tiny-dep@2.1.0'));

    expect(
      await File('${tempDir.path}/node_modules/left-pad/index.js')
          .readAsString(),
      contains('padStart'),
    );
    expect(
      await File('${tempDir.path}/node_modules/tiny-dep/index.js')
          .readAsString(),
      contains('42'),
    );
  });

  test('install is idempotent when the package already exists', () async {
    await service.install('left-pad');
    final NpmInstallResult again = await service.install('left-pad');
    expect(again.ok, isTrue);
    expect(again.installed, isEmpty); // nothing new was downloaded
  });

  test('install failure surfaces a readable message', () async {
    final NpmInstallResult result = await service.install('nope-not-here');
    expect(result.ok, isFalse);
    expect(result.message, contains('404'));
  });

  test('remove deletes an installed package', () async {
    await service.install('left-pad');
    expect(await service.remove('left-pad'), isTrue);
    expect(
      Directory('${tempDir.path}/node_modules/left-pad').existsSync(),
      isFalse,
    );
    expect(await service.remove('left-pad'), isFalse);
  });

  test('listInstalled reports name@version pairs', () async {
    await service.install('left-pad');
    final List<InstalledModule> modules = await service.listInstalled();
    expect(modules, hasLength(2));
    expect(
      modules.map((m) => '${m.name}@${m.version}'),
      containsAll(<String>['left-pad@1.0.0', 'tiny-dep@2.1.0']),
    );
  });

  test('search parses registry results', () async {
    final List<Map<String, String>> hits = await service.search('pad');
    expect(hits, hasLength(1));
    expect(hits.first['name'], 'left-pad');
  });

  group('tarball & name safety (v1.40.0)', () {
    NpmService serviceFor(List<int> tarball) {
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/evil-pkg')) {
          return jsonRes(<String, dynamic>{
            'dist-tags': <String, dynamic>{'latest': '1.0.0'},
            'versions': <String, dynamic>{
              '1.0.0': <String, dynamic>{
                'dist': <String, dynamic>{
                  'tarball': 'https://registry.npmjs.org/evil-pkg/-/evil.tgz',
                },
              },
            },
          });
        }
        return http.Response.bytes(tarball, 200);
      });
      return NpmService(resolveBaseDir: () async => tempDir, client: client);
    }

    test('a tarball entry that escapes node_modules is rejected', () async {
      final NpmService evil = serviceFor(
        tarGz(<String, String>{
          'package/package.json': jsonEncode(<String, dynamic>{
            'name': 'evil-pkg',
            'version': '1.0.0',
          }),
          'package/../../skills/pwned/SKILL.md': '# pwned',
        }),
      );
      final NpmInstallResult result = await evil.install('evil-pkg');
      expect(result.ok, isFalse);
      expect(result.message, contains('unsafe path'));
      expect(
        Directory('${tempDir.path}/skills').existsSync(),
        isFalse,
        reason: 'nothing may be written outside node_modules',
      );
      expect(
        Directory('${tempDir.path}/node_modules/evil-pkg').existsSync(),
        isFalse,
        reason: 'a rejected archive must not be half-installed',
      );
    });

    test('an absolute entry path is rejected', () async {
      final NpmService evil = serviceFor(
        tarGz(<String, String>{
          'package/package.json': '{"name":"evil-pkg","version":"1.0.0"}',
          '/etc/passwd': 'root:x:0:0',
        }),
      );
      final NpmInstallResult result = await evil.install('evil-pkg');
      expect(result.ok, isFalse);
      expect(result.message, contains('unsafe path'));
    });

    test('package names cannot escape the modules directory', () async {
      for (final String name in <String>[
        '../../skills/x',
        '..',
        '@scope/../../x',
        r'C:\windows',
        'a/b/c',
      ]) {
        final NpmInstallResult result = await service.install(name);
        expect(result.ok, isFalse, reason: '"$name" must be rejected');
        expect(result.message, contains('Invalid package name'));
      }
      await expectLater(service.remove('..'), throwsA(isA<String>()));
    });

    test(
      'a hostile metadata payload is a readable error, not a crash',
      () async {
        final MockClient client = MockClient(
          (http.Request request) async => jsonRes(<String, dynamic>{
            'dist-tags': <String, dynamic>{'latest': '1.0.0'},
            'versions': <String, dynamic>{'1.0.0': 'not-a-map'},
          }),
        );
        final NpmService broken = NpmService(
          resolveBaseDir: () async => tempDir,
          client: client,
        );
        final NpmInstallResult result = await broken.install('weird');
        expect(result.ok, isFalse);
        expect(result.message, contains('no tarball'));
      },
    );
  });
}
