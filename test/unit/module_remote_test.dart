import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/services/module_remote.dart';

/// Builds a ZIP in memory from {path: bytes} (same helper pattern as the
/// registry tests).
List<int> buildZip(Map<String, List<int>> files) {
  final Archive archive = Archive();
  files.forEach((String path, List<int> bytes) {
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

List<int> counterZip(String version) => buildZip(<String, List<int>>{
  'module.json': utf8.encode(
    jsonEncode(<String, dynamic>{
      'name': 'counter',
      'version': version,
      'title': 'Counter',
      'description': 'demo',
      'entry': 'main.js',
      'permissions': <String>['storage'],
    }),
  ),
  'main.js': utf8.encode('module.exports = function () {}'),
});

/// v1.46.0 — ModuleRemote: URL/samples intake. The loopback fixtures run
/// a real dart:io HttpServer (plain http is allowed ONLY for loopback —
/// exactly the production gate), so the whole download → install →
/// update path is exercised without touching any external network.
void main() {
  late Directory tempDir;
  late ModuleRegistry registry;
  late ModuleRemote remote;
  late HttpServer server;
  final Map<String, List<int>> routes = <String, List<int>>{};

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('module_remote_test');
    registry = ModuleRegistry(resolveBaseDir: () async => tempDir);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    remote = ModuleRemote(
      registry: registry,
      rawBaseOverride: 'http://127.0.0.1:${server.port}',
    );
    routes.clear();
    server.listen((HttpRequest request) async {
      final List<int>? body = routes[request.uri.path];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.add(body);
      await request.response.flush();
      await request.response.close();
    });
  });

  tearDown(() async {
    server.close(force: true);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  String urlOf(String path) => 'http://127.0.0.1:${server.port}$path';

  group('URL gate (isAllowedUrl)', () {
    test('accepts https and loopback http, rejects everything else', () {
      expect(ModuleRemote.isAllowedUrl('https://example.com/mod.zip'), isTrue);
      expect(
        ModuleRemote.isAllowedUrl('http://localhost:9000/mod.zip'),
        isTrue,
      );
      expect(
        ModuleRemote.isAllowedUrl('http://127.0.0.1:9000/mod.zip'),
        isTrue,
      );
      // Plain http off-device is refused (user-driven installs go https).
      expect(ModuleRemote.isAllowedUrl('http://example.com/mod.zip'), isFalse);
      expect(ModuleRemote.isAllowedUrl('ftp://example.com/mod.zip'), isFalse);
      expect(ModuleRemote.isAllowedUrl('file:///tmp/mod.zip'), isFalse);
      expect(ModuleRemote.isAllowedUrl('not a url'), isFalse);
      expect(ModuleRemote.isAllowedUrl(''), isFalse);
      expect(
        ModuleRemote.isAllowedUrl('https://example.com/${'a' * 3000}.zip'),
        isFalse,
      );
    });

    test('sanitizes sample names before they reach a URL', () {
      expect(ModuleRemote.sanitizeSampleName('Counter Demo'), 'counterdemo');
      expect(ModuleRemote.sanitizeSampleName('../../etc/passwd'), 'etcpasswd');
      expect(ModuleRemote.sanitizeSampleName('twitter-x'), 'twitter-x');
      expect(remote.sampleZipUrl('Counter Demo'), isNot(contains(' ')));
      expect(
        remote.sampleZipUrl('a/b'),
        'http://127.0.0.1:${server.port}/samples/ab.zip',
      );
    });
  });

  group('installFromUrl', () {
    test(
      'downloads and installs a valid module ZIP from a loopback URL',
      () async {
        routes['/counter.zip'] = counterZip('1.0.0');
        final ModuleInstallResult result = await remote.installFromUrl(
          urlOf('/counter.zip'),
        );
        expect(result.ok, isTrue, reason: result.message);
        expect(result.module!.name, 'counter');
        final ChatModule? installed = await registry.get('counter');
        expect(installed, isNotNull);
        expect(installed!.manifest.version, '1.0.0');
      },
    );

    test('re-installing a newer version via URL UPDATES the module', () async {
      routes['/counter.zip'] = counterZip('1.0.0');
      final ModuleInstallResult first = await remote.installFromUrl(
        urlOf('/counter.zip'),
      );
      expect(first.ok, isTrue, reason: first.message);
      routes['/counter.zip'] = counterZip('2.1.0');
      final ModuleInstallResult second = await remote.installFromUrl(
        urlOf('/counter.zip'),
      );
      expect(second.ok, isTrue, reason: second.message);
      expect(second.message, 'Updated counter v1.0.0 → v2.1.0');
      expect((await registry.get('counter'))!.manifest.version, '2.1.0');
    });

    test(
      'a hostile ZIP (zip-slip entry) is refused like a local install',
      () async {
        routes['/evil.zip'] = buildZip(<String, List<int>>{
          'module.json': utf8.encode(
            jsonEncode(<String, dynamic>{'name': 'evil', 'entry': 'main.js'}),
          ),
          'main.js': utf8.encode('module.exports = function () {}'),
          '../escaped.js': utf8.encode('pwn'),
        });
        final ModuleInstallResult result = await remote.installFromUrl(
          urlOf('/evil.zip'),
        );
        expect(result.ok, isFalse);
        expect(result.message, contains('Unsafe ZIP entry rejected'));
        expect(registry.getSync('evil'), isNull);
      },
    );

    test('HTTP error statuses surface a readable failure', () async {
      final ModuleInstallResult result = await remote.installFromUrl(
        urlOf('/missing.zip'),
      );
      expect(result.ok, isFalse);
      expect(result.message, 'Download failed: HTTP 404');
    });

    test('an empty 200 response is refused', () async {
      routes['/empty.zip'] = <int>[];
      final ModuleInstallResult result = await remote.installFromUrl(
        urlOf('/empty.zip'),
      );
      expect(result.ok, isFalse);
      expect(result.message, 'Download failed: empty response');
    });

    test('non-https off-device URLs are refused before any request', () async {
      // No route registered on the fixture AND a non-loopback host — the
      // gate must refuse this without any network activity.
      final ModuleInstallResult result = await remote.installFromUrl(
        'http://example.invalid/mod.zip',
      );
      expect(result.ok, isFalse);
      expect(result.message, 'Only HTTPS module URLs are allowed');
    });
  });

  group('installSample / sampleRemoteVersion', () {
    test('installSample installs the official catalog ZIP by name', () async {
      // rawBaseOverride points the catalog at the loopback fixture, so
      // the client requests /samples/<name>.zip here — no real network.
      routes['/samples/counter.zip'] = counterZip('3.0.0');
      final ModuleInstallResult result = await remote.installSample('counter');
      expect(result.ok, isTrue, reason: result.message);
      expect(result.module!.manifest.version, '3.0.0');
    });

    test('installSample refuses an empty sanitized name', () async {
      final ModuleInstallResult result = await remote.installSample('///');
      expect(result.ok, isFalse);
      expect(result.message, 'Invalid module name');
    });

    test('sampleRemoteVersion reads the manifest version', () async {
      routes['/samples/counter/module.json'] = utf8.encode(
        jsonEncode(<String, dynamic>{'name': 'counter', 'version': '9.9.9'}),
      );
      expect(await remote.sampleRemoteVersion('counter'), '9.9.9');
    });

    test('sampleRemoteVersion returns null on 404 / malformed body', () async {
      expect(await remote.sampleRemoteVersion('missing'), isNull);
      routes['/samples/broken/module.json'] = utf8.encode('not json{');
      expect(await remote.sampleRemoteVersion('broken'), isNull);
    });
  });

  group('ModuleRegistry.compareVersions', () {
    test('compares dotted versions numerically', () {
      expect(ModuleRegistry.compareVersions('1.10.0', '1.9.0'), 1);
      expect(ModuleRegistry.compareVersions('1.9.0', '1.10.0'), -1);
      expect(ModuleRegistry.compareVersions('2.0.0', '2.0.0'), 0);
      expect(ModuleRegistry.compareVersions('2.0', '1.9.9'), 1);
      expect(ModuleRegistry.compareVersions('1.0', '1.0.0'), 0);
      expect(ModuleRegistry.compareVersions('1.0.1', '1.0'), 1);
    });
  });
}
