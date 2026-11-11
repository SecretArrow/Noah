import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/local_ai/external_ollama_scanner.dart';

void main() {
  group('ExternalOllamaScanner.probe', () {
    test(
      'scheme normalization: bare host gets http:// and /api/version',
      () async {
        final List<Uri> seen = <Uri>[];
        final ExternalOllamaScanner scanner = ExternalOllamaScanner(
          client: MockClient((http.Request request) async {
            seen.add(request.url);
            return http.Response('{"version":"0.12.6"}', 200);
          }),
        );

        final ExternalOllamaScan scan = await scanner.probe('127.0.0.1:11434');

        expect(seen.single.toString(), 'http://127.0.0.1:11434/api/version');
        expect(scan.ok, isTrue);
        expect(scan.version, '0.12.6');
        expect(scan.error, isNull);
      },
    );

    test('an explicit http:// scheme is not doubled, trailing slash and '
        'spaces are stripped', () async {
      final List<Uri> seen = <Uri>[];
      final ExternalOllamaScanner scanner = ExternalOllamaScanner(
        client: MockClient((http.Request request) async {
          seen.add(request.url);
          return http.Response('{"version":"0.9.0"}', 200);
        }),
      );

      final ExternalOllamaScan scan = await scanner.probe(
        '  http://192.168.1.42:11434/ ',
      );

      expect(seen.single.toString(), 'http://192.168.1.42:11434/api/version');
      expect(scan.ok, isTrue);
      expect(scan.version, '0.9.0');
      expect(scan.host, '  http://192.168.1.42:11434/ ');
    });

    test('an https:// scheme is respected', () async {
      final List<Uri> seen = <Uri>[];
      final ExternalOllamaScanner scanner = ExternalOllamaScanner(
        client: MockClient((http.Request request) async {
          seen.add(request.url);
          return http.Response('{"version":"0.12.6"}', 200);
        }),
      );

      await scanner.probe('https://ollama.lan:11434');

      expect(seen.single.toString(), 'https://ollama.lan:11434/api/version');
    });

    test('a timeout reports a failed scan with a reason', () async {
      final ExternalOllamaScanner scanner = ExternalOllamaScanner(
        client: MockClient(
          (http.Request request) => Completer<http.Response>().future,
        ),
        timeout: const Duration(milliseconds: 30),
      );

      final ExternalOllamaScan scan = await scanner.probe('10.255.255.1:11434');

      expect(scan.ok, isFalse);
      expect(scan.version, isEmpty);
      expect(scan.error, contains('timed out'));
    });

    test('a network error is reported, never thrown', () async {
      final ExternalOllamaScanner scanner = ExternalOllamaScanner(
        client: MockClient((http.Request request) async {
          throw Exception('connection refused');
        }),
      );

      final ExternalOllamaScan scan = await scanner.probe('127.0.0.1:1');

      expect(scan.ok, isFalse);
      expect(scan.error, contains('connection refused'));
    });

    test('non-200 statuses report the HTTP code', () async {
      final ExternalOllamaScanner scanner = ExternalOllamaScanner(
        client: MockClient(
          (http.Request request) async => http.Response('nope', 404),
        ),
      );

      final ExternalOllamaScan scan = await scanner.probe('127.0.0.1:11434');

      expect(scan.ok, isFalse);
      expect(scan.error, contains('404'));
    });

    test('a 200 without a version string still scans ok', () async {
      final ExternalOllamaScanner scanner = ExternalOllamaScanner(
        client: MockClient(
          (http.Request request) async => http.Response('{"other":1}', 200),
        ),
      );

      final ExternalOllamaScan scan = await scanner.probe('127.0.0.1:11434');

      expect(scan.ok, isTrue);
      expect(scan.version, isEmpty);
    });
  });
}
