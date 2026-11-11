import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/remote_guard.dart';

/// v1.40.0: every user/agent supplied remote source (skills, npm packages)
/// goes through [RemoteGuard]. These tests pin the two guarantees the chat
/// depends on: the device must never be pointed at a private/loopback
/// address, and no endpoint may stream without bound.
void main() {
  group('isAllowedUrl', () {
    test('accepts public https endpoints', () {
      expect(RemoteGuard.isAllowedUrl('https://example.com/skill.zip'), isTrue);
      expect(
        RemoteGuard.isAllowedUrl('https://registry.npmjs.org/left-pad'),
        isTrue,
      );
      expect(RemoteGuard.isAllowedUrl('https://8.8.8.8/x'), isTrue);
      expect(
        RemoteGuard.isAllowedUrl('https://codeload.github.com/a/b/tar.gz/main'),
        isTrue,
      );
    });

    test('rejects non-https schemes', () {
      expect(RemoteGuard.isAllowedUrl('http://example.com/x'), isFalse);
      expect(RemoteGuard.isAllowedUrl('file:///etc/passwd'), isFalse);
      expect(RemoteGuard.isAllowedUrl('ftp://example.com/x'), isFalse);
      expect(RemoteGuard.isAllowedUrl(''), isFalse);
      expect(RemoteGuard.isAllowedUrl('not a url'), isFalse);
    });

    test('requireHttps: false allows public http, still blocks '
        'local targets', () {
      // web_fetch and skill-script fetch() fetch user-visible pages over
      // plain http too — the SSRF rules must survive that relaxation.
      expect(
        RemoteGuard.isAllowedUrl(
          'http://example.com/page',
          requireHttps: false,
        ),
        isTrue,
      );
      expect(
        RemoteGuard.isAllowedUrl('http://127.0.0.1:8080/', requireHttps: false),
        isFalse,
      );
      expect(
        RemoteGuard.isAllowedUrl('http://192.168.1.1/', requireHttps: false),
        isFalse,
      );
      expect(
        RemoteGuard.isAllowedUrl('http://router/', requireHttps: false),
        isFalse,
      );
      expect(
        RemoteGuard.isAllowedUrl('ftp://example.com/', requireHttps: false),
        isFalse,
      );
    });

    test('rejects single-label (LAN-only) hostnames', () {
      for (final String host in <String>[
        'router',
        'nas',
        'metadata',
        'intranet',
      ]) {
        expect(
          RemoteGuard.isAllowedUrl('https://$host/x'),
          isFalse,
          reason: host,
        );
      }
    });

    test('rejects loopback and private IPv4 literals', () {
      for (final String host in <String>[
        'localhost',
        'app.localhost',
        '127.0.0.1',
        '127.10.0.5',
        '0.0.0.0',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.1',
        '169.254.169.254', // cloud metadata endpoint
        '100.64.0.1', // CGNAT
        '224.0.0.1', // multicast
        '255.255.255.255',
        '999.1.1.1', // invalid octet
      ]) {
        expect(
          RemoteGuard.isAllowedUrl('https://$host/x'),
          isFalse,
          reason: '$host must never be fetched',
        );
      }
    });

    test('rejects loopback, link-local and unique-local IPv6 literals', () {
      for (final String host in <String>[
        '[::1]',
        '[::]',
        '[fe80::1]',
        '[febf::1]', // last address of fe80::/10
        '[fd00::1]',
        '[fc00::1]',
        '[ff02::1]', // multicast
        // IPv4-mapped: dotted AND the canonical hex form Dart produces
        // after parsing (`::ffff:7f00:1`). Both reach 127.0.0.1.
        '[::ffff:127.0.0.1]',
        '[::ffff:192.168.0.1]',
        '[::ffff:7f00:1]',
        '[::ffff:c0a8:1]',
        '[::127.0.0.1]',
        // NAT64 well-known prefix embedding a loopback / private address.
        '[64:ff9b::7f00:1]',
        '[64:ff9b::a00:1]',
      ]) {
        expect(
          RemoteGuard.isAllowedUrl('https://$host/x'),
          isFalse,
          reason: '$host must never be fetched',
        );
      }
      // A malformed literal is refused, not guessed at.
      expect(RemoteGuard.isAllowedUrl('https://[not:an:ip]/x'), isFalse);
      expect(
        RemoteGuard.isAllowedUrl('https://[1:2:3:4:5:6:7:8:9]/x'),
        isFalse,
      );
      expect(
        RemoteGuard.isAllowedUrl('https://[2001:4860:4860::8888]/x'),
        isTrue,
      );
      // NAT64 wrapping a PUBLIC address is allowed.
      expect(RemoteGuard.isAllowedUrl('https://[64:ff9b::808:808]/x'), isTrue);
    });
  });

  group('download', () {
    test('returns the body for an allowed endpoint', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response('hello', 200),
      );
      final List<int> bytes = await RemoteGuard.download(
        client,
        Uri.parse('https://example.com/x'),
        maxBytes: 1024,
      );
      expect(utf8.decode(bytes), 'hello');
    });

    test('rejects a URL that resolves to a private address', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response('secret', 200),
      );
      await expectLater(
        RemoteGuard.download(
          client,
          Uri.parse('https://192.168.0.1/admin'),
          maxBytes: 1024,
        ),
        throwsA(isA<RemoteGuardException>()),
      );
    });

    test('follows an allowed redirect', () async {
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path == '/start') {
          return http.Response(
            '',
            302,
            headers: <String, String>{
              'location': 'https://cdn.example.com/final.zip',
            },
          );
        }
        return http.Response('payload', 200);
      });
      final List<int> bytes = await RemoteGuard.download(
        client,
        Uri.parse('https://example.com/start'),
        maxBytes: 1024,
      );
      expect(utf8.decode(bytes), 'payload');
    });

    test('refuses a redirect into http or a private host', () async {
      for (final String target in <String>[
        'http://example.com/final',
        'https://169.254.169.254/latest/meta-data',
        'https://localhost:8080/x',
      ]) {
        final MockClient client = MockClient((http.Request request) async {
          if (request.url.path == '/start') {
            return http.Response(
              '',
              302,
              headers: <String, String>{'location': target},
            );
          }
          return http.Response('should not be fetched', 200);
        });
        await expectLater(
          RemoteGuard.download(
            client,
            Uri.parse('https://example.com/start'),
            maxBytes: 1024,
          ),
          throwsA(isA<RemoteGuardException>()),
          reason: 'redirect to $target must be refused',
        );
      }
    });

    test('rejects a body larger than the declared cap', () async {
      final MockClient client = MockClient(
        (http.Request request) async =>
            http.Response.bytes(List<int>.filled(4096, 65), 200),
      );
      await expectLater(
        RemoteGuard.download(
          client,
          Uri.parse('https://example.com/big'),
          maxBytes: 1024,
        ),
        throwsA(
          isA<RemoteGuardException>().having(
            (RemoteGuardException e) => e.message,
            'message',
            contains('limit'),
          ),
        ),
      );
    });

    test('caps a stream that lies about its length', () async {
      final MockClient client = MockClient.streaming((
        http.BaseRequest request,
        http.ByteStream body,
      ) async {
        // No content-length header: the only defense is the streaming cap.
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            List<int>.filled(800, 65),
            List<int>.filled(800, 65),
          ]),
          200,
        );
      });
      await expectLater(
        RemoteGuard.download(
          client,
          Uri.parse('https://example.com/forever'),
          maxBytes: 1024,
        ),
        throwsA(isA<RemoteGuardException>()),
      );
    });

    test('rejects a non-200 response', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response('nope', 404),
      );
      await expectLater(
        RemoteGuard.download(
          client,
          Uri.parse('https://example.com/missing'),
          maxBytes: 1024,
        ),
        throwsA(
          isA<RemoteGuardException>().having(
            (RemoteGuardException e) => e.message,
            'message',
            contains('404'),
          ),
        ),
      );
    });

    test('gives up after too many redirects', () async {
      final MockClient client = MockClient((http.Request request) async {
        return http.Response(
          '',
          302,
          headers: <String, String>{'location': 'https://example.com/again'},
        );
      });
      await expectLater(
        RemoteGuard.download(
          client,
          Uri.parse('https://example.com/loop'),
          maxBytes: 1024,
        ),
        throwsA(
          isA<RemoteGuardException>().having(
            (RemoteGuardException e) => e.message,
            'message',
            contains('Too many redirects'),
          ),
        ),
      );
    });
  });
}
