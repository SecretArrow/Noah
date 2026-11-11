import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/web_fetcher.dart';

http.Client _clientWith({
  int status = 200,
  String body = '',
  Map<String, String> headers = const <String, String>{},
  Exception? throwOnSend,
}) => MockClient((http.Request request) async {
  if (throwOnSend != null) throw throwOnSend;
  return http.Response(body, status, headers: headers);
});

void main() {
  test('HTML is stripped to readable text (scripts/styles/tags/entities)', () async {
    final WebFetcher fetcher = WebFetcher(
      client: _clientWith(
        headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
        body:
            '<html><head><style>.x{color:red}</style><script>evil()</script>'
            '</head><body><h1>Selamat&nbsp;Datang</h1><p>A &amp; B &#65;&#x42;'
            '</p><script>more()</script><div>Baris<br/>kedua</div></body></html>',
      ),
    );
    final WebFetchResult result = await fetcher.fetch('https://x.test/a');
    expect(result.ok, isTrue);
    expect(result.output, contains('Selamat Datang'));
    expect(result.output, contains('A & B AB'));
    expect(result.output, contains('Baris'));
    expect(result.output, contains('kedua'));
    expect(result.output, isNot(contains('evil')));
    expect(result.output, isNot(contains('<h1>')));
    expect(result.output, isNot(contains('.x{color')));
  });

  test('JSON bodies are pretty-printed with two-space indent', () async {
    final WebFetcher fetcher = WebFetcher(
      client: _clientWith(
        headers: <String, String>{'content-type': 'application/json'},
        body: '{"b":1,"a":{"c":[1,2]}}',
      ),
    );
    final WebFetchResult result = await fetcher.fetch('https://x.test/api');
    expect(result.ok, isTrue);
    expect(
      result.output,
      contains(
        '{\n  "b": 1,\n  "a": {\n    "c": [\n      1,\n      2\n    ]\n  }\n}',
      ),
    );
  });

  test(
    'non-2xx responses return an error result with status and preview',
    () async {
      final WebFetcher fetcher = WebFetcher(
        client: _clientWith(status: 404, body: 'not here'),
      );
      final WebFetchResult result = await fetcher.fetch(
        'https://x.test/missing',
      );
      expect(result.ok, isFalse);
      expect(result.output, contains('HTTP 404'));
      expect(result.output, contains('not here'));
    },
  );

  test('maxLength truncates with a clear marker', () async {
    final WebFetcher fetcher = WebFetcher(
      client: _clientWith(
        headers: <String, String>{'content-type': 'text/plain'},
        body: 'x' * 500,
      ),
    );
    final WebFetchResult result = await fetcher.fetch(
      'https://x.test/long',
      maxLength: 100,
    );
    expect(result.ok, isTrue);
    expect(result.output.length, 100 + '\n…[truncated]'.length);
    expect(result.output, endsWith('…[truncated]'));
  });

  test('unsupported content types and bad schemes are rejected', () async {
    final WebFetcher binary = WebFetcher(
      client: _clientWith(
        headers: <String, String>{'content-type': 'application/octet-stream'},
        body: 'zzz',
      ),
    );
    final WebFetchResult badType = await binary.fetch('https://x.test/bin');
    expect(badType.ok, isFalse);
    expect(badType.output, contains('unsupported content-type'));

    final WebFetcher fetcher = WebFetcher(client: _clientWith());
    final WebFetchResult ftp = await fetcher.fetch('ftp://x.test/f');
    expect(ftp.ok, isFalse);
    expect(ftp.output, contains('http(s)'));
  });

  test('SSRF: loopback, private and single-label hosts '
      'are refused', () async {
    int calls = 0;
    final WebFetcher fetcher = WebFetcher(
      client: MockClient((http.Request request) async {
        calls++;
        return http.Response('secret', 200);
      }),
    );
    for (final String url in <String>[
      'http://127.0.0.1:8080/admin',
      'http://localhost/',
      'http://192.168.1.1/',
      'http://10.0.0.5/',
      'http://169.254.169.254/latest/meta-data/',
      'http://router/',
      'http://[::1]/',
    ]) {
      final WebFetchResult result = await fetcher.fetch(url);
      expect(result.ok, isFalse, reason: url);
      expect(result.output, contains('Refusing to fetch'), reason: url);
    }
    expect(calls, 0, reason: 'no request may leave the device');
  });

  test('SSRF: a public URL redirecting to a private host '
      'is refused', () async {
    final List<String> hits = <String>[];
    final WebFetcher fetcher = WebFetcher(
      client: MockClient((http.Request request) async {
        hits.add(request.url.toString());
        return http.Response(
          '',
          302,
          headers: <String, String>{'location': 'http://192.168.1.1/admin'},
        );
      }),
    );
    final WebFetchResult result = await fetcher.fetch('https://x.test/go');
    expect(result.ok, isFalse);
    expect(result.output, contains('Refusing to fetch'));
    expect(hits, <String>['https://x.test/go']);
  });
}
