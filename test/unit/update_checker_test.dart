import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/update_checker.dart';

const String _tagUrl =
    'https://github.com/SecretArrow/Noah/releases/tag/v1.44.0';

const String _universalApkUrl =
    'https://github.com/SecretArrow/Noah/releases/download/v1.44.0/'
    'Noah-1.44.0-v1.44.0.apk';

/// Builds a GitHub `/releases/latest`-shaped payload.
Map<String, Object?> _release({
  String tag = 'v1.44.0',
  String? htmlUrl = _tagUrl,
  List<Object?> assets = const <Object?>[],
}) => <String, Object?>{'tag_name': tag, 'html_url': htmlUrl, 'assets': assets};

Map<String, String> _apk(String name, String url) => <String, String>{
  'name': name,
  'browser_download_url': url,
};

http.Client _responding(int status, String body) =>
    MockClient((http.Request request) async => http.Response(body, status));

void main() {
  group('UpdateChecker.check', () {
    test('detects an update and selects the universal APK asset', () async {
      final List<http.Request> requests = <http.Request>[];
      final Map<String, Object?> payload = _release(
        assets: <Object?>[
          _apk(
            'Noah-1.44.0-v1.44.0-arm64-v8a.apk',
            'https://example.test/zagents-arm64-v8a.apk',
          ),
          _apk('Noah-1.44.0-v1.44.0.apk', _universalApkUrl),
          _apk(
            'Noah-1.44.0-v1.44.0-x86_64.apk',
            'https://example.test/zagents-x86_64.apk',
          ),
        ],
      );
      final UpdateChecker checker = UpdateChecker(
        client: MockClient((http.Request request) async {
          requests.add(request);
          return http.Response(jsonEncode(payload), 200);
        }),
      );

      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.43.1+59',
      );

      expect(result.ok, isTrue);
      expect(result.error, isNull);
      expect(result.latestTag, 'v1.44.0');
      expect(result.releaseUrl, _tagUrl);
      expect(result.apkDownloadUrl, _universalApkUrl);
      expect(result.updateAvailable, isTrue);
      expect(requests, hasLength(1));
      expect(
        requests.single.url.toString(),
        'https://api.github.com/repos/SecretArrow/Noah/releases/latest',
      );
      expect(requests.single.headers['Accept'], 'application/vnd.github+json');
      expect(requests.single.headers['User-Agent'], 'Noah-UpdateChecker');
    });

    test('repo parameter drives the API endpoint', () async {
      final List<Uri> seen = <Uri>[];
      final UpdateChecker checker = UpdateChecker(
        repo: 'octocat/hello-world',
        client: MockClient((http.Request request) async {
          seen.add(request.url);
          return http.Response(jsonEncode(_release()), 200);
        }),
      );

      await checker.check(currentVersion: '1.0.0');

      expect(
        seen.single.toString(),
        'https://api.github.com/repos/octocat/hello-world/releases/latest',
      );
    });

    test('no update when latest equals or trails the current', () async {
      Future<UpdateCheckResult> checkAgainst(String tag) {
        final UpdateChecker checker = UpdateChecker(
          client: _responding(200, jsonEncode(_release(tag: tag))),
        );
        return checker.check(currentVersion: '1.44.0+59');
      }

      final UpdateCheckResult same = await checkAgainst('v1.44.0');
      expect(same.ok, isTrue);
      expect(same.updateAvailable, isFalse);

      final UpdateCheckResult older = await checkAgainst('v1.43.0');
      expect(older.ok, isTrue);
      expect(older.updateAvailable, isFalse);

      final UpdateCheckResult buildOnly = await checkAgainst('v1.44.0+60');
      expect(buildOnly.ok, isTrue);
      expect(
        buildOnly.updateAvailable,
        isFalse,
        reason: 'a different +build number alone is not an update',
      );
    });

    test('HTTP 403 rate limit yields ok:false with clear error', () async {
      final UpdateChecker checker = UpdateChecker(
        client: _responding(403, '{"message":"API rate limit exceeded"}'),
      );
      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.43.1+59',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('403'));
      expect(result.latestTag, '');
      expect(result.updateAvailable, isFalse);
      expect(result.apkDownloadUrl, isNull);
    });

    test('HTTP 404 yields ok:false when no release exists', () async {
      final UpdateChecker checker = UpdateChecker(
        client: _responding(404, '{"message":"Not Found"}'),
      );
      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.43.1+59',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('404'));
    });

    test('non-JSON body yields ok:false with a parse error', () async {
      final UpdateChecker checker = UpdateChecker(
        client: _responding(200, '<html>502 Bad Gateway</html>'),
      );
      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.43.1+59',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('JSON'));
    });

    test('payload without tag_name yields ok:false', () async {
      final UpdateChecker checker = UpdateChecker(
        client: _responding(200, '{"message":"unexpected shape"}'),
      );
      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.43.1+59',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('tag_name'));
    });

    test('network failure yields ok:false with the cause', () async {
      final UpdateChecker checker = UpdateChecker(
        client: MockClient(
          (http.Request request) async =>
              throw http.ClientException('connection refused'),
        ),
      );
      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.43.1+59',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Network error'));
    });

    test('fallback to the first .apk asset when only ABI splits', () async {
      final Map<String, Object?> payload = _release(
        assets: <Object?>[
          _apk(
            'Noah-1.44.0-v1.44.0-arm64-v8a.apk',
            'https://example.test/zagents-arm64-v8a.apk',
          ),
          _apk(
            'Noah-1.44.0-v1.44.0-x86_64.apk',
            'https://example.test/zagents-x86_64.apk',
          ),
        ],
      );
      final UpdateChecker checker = UpdateChecker(
        client: _responding(200, jsonEncode(payload)),
      );

      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.44.0',
      );

      expect(result.ok, isTrue);
      expect(
        result.apkDownloadUrl,
        'https://example.test/zagents-arm64-v8a.apk',
      );
    });

    test('release without APK assets yields a null APK URL', () async {
      final UpdateChecker checker = UpdateChecker(
        client: _responding(200, jsonEncode(_release(assets: <Object?>[]))),
      );

      final UpdateCheckResult result = await checker.check(
        currentVersion: '1.44.0',
      );

      expect(result.ok, isTrue);
      expect(result.latestTag, 'v1.44.0');
      expect(result.apkDownloadUrl, isNull);
      expect(result.updateAvailable, isFalse);
    });
  });

  group('isNewerVersion (semver compare)', () {
    test('compares numerically, not lexically', () {
      expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
      expect(isNewerVersion('1.9.0', '1.10.0'), isFalse);
      expect(isNewerVersion('1.10.0', '1.9.9'), isTrue);
      expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
    });

    test('strips v/V prefixes and +build metadata', () {
      expect(isNewerVersion('v1.44.0', '1.43.1+59'), isTrue);
      expect(isNewerVersion('V1.44.0', 'v1.43.1+59'), isTrue);
      expect(isNewerVersion('v1.44.0', '1.44.0'), isFalse);
      expect(isNewerVersion('1.44.0+60', '1.44.0+59'), isFalse);
    });

    test('missing and non-numeric core segments count as 0', () {
      expect(isNewerVersion('1.44', '1.43.9'), isTrue);
      expect(isNewerVersion('1.43', '1.43.0'), isFalse);
      expect(isNewerVersion('1.44.x', '1.44.0'), isFalse);
    });

    test('prerelease suffixes follow the documented rules', () {
      // Prerelease of the installed version → not an update.
      expect(isNewerVersion('1.44.0-beta', '1.44.0'), isFalse);
      // Stable shipping over an installed prerelease → update.
      expect(isNewerVersion('1.44.0', '1.44.0-beta'), isTrue);
      // Both prereleases: identifier comparison, numeric-aware.
      expect(isNewerVersion('1.44.0-rc.2', '1.44.0-rc.1'), isTrue);
      expect(isNewerVersion('1.44.0-beta.10', '1.44.0-beta.9'), isTrue);
      expect(isNewerVersion('1.44.0-rc.1', '1.44.0-beta.9'), isTrue);
      // A lower core never wins, whatever the suffixes.
      expect(isNewerVersion('1.43.9', '1.44.0-beta'), isFalse);
    });
  });
}
