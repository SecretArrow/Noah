import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'remote_guard.dart';

/// Result of one proxied script `fetch()` — crosses the JS bridge as a
/// plain JSON-serializable map.
///
/// Two body representations travel back: [bodyText] for textual payloads
/// (JSON-RPC, REST, HTML) and [bodyBase64] for binary ones (git packfiles,
/// protobufs). The JS side builds a Response object over whichever is
/// present, so `text()`, `json()` AND `arrayBuffer()` all work — the
/// minimum surface isomorphic-git's browser client and ethers/web3-style
/// libraries expect.
class ScriptFetchResult {
  const ScriptFetchResult({
    required this.status,
    this.statusText = '',
    this.bodyText = '',
    this.bodyBase64,
    this.headers = const <String, String>{},
  });

  final int status;
  final String statusText;
  final String bodyText;
  final String? bodyBase64;
  final Map<String, String> headers;

  Map<String, dynamic> toBridge() => <String, dynamic>{
    'status': status,
    'statusText': statusText,
    'body': bodyText,
    if (bodyBase64 != null) 'bodyBase64': bodyBase64,
    'headers': headers,
  };
}

/// Dart-side proxy for in-script `fetch()` calls (v1.38.0).
///
/// Before this existed the JS shim overrode `window.fetch` with a proxy
/// that was never wired — every script fetch rejected with "fetch is
/// unavailable", silently breaking git-over-HTTPS and any Web3/wallet
/// skill that needed JSON-RPC. This proxy performs REAL requests through
/// package:http (platform TLS trust store), passes request headers
/// through, follows redirects, applies the Settings → User Agent
/// identity, and caps the response so a runaway script cannot exhaust
/// memory.
class ScriptFetchProxy {
  ScriptFetchProxy({
    http.Client? client,
    this.resolveUserAgent,
    this.maxResponseBytes = 16 * 1024 * 1024,
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Releases the underlying HTTP client (DI container teardown).
  void dispose() => _client.close();

  /// Resolves the UA identity scripts present (same as the browser
  /// automation and modules — the user's Settings → User Agent pick).
  final String? Function()? resolveUserAgent;

  /// Hard cap on the response payload (before base64/text conversion).
  final int maxResponseBytes;

  final Duration timeout;

  /// Executes one request. [bodyBase64] marks the request body as
  /// binary (already base64-encoded by the JS shim); otherwise the body
  /// string is sent as UTF-8.
  Future<Map<String, dynamic>?> call(
    String url,
    String method,
    String? body, {
    Map<String, String> headers = const <String, String>{},
    bool bodyIsBase64 = false,
  }) async {
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null ||
        !parsed.hasScheme ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return const <String, dynamic>{
        'ok': false,
        'error': 'Only http(s) URLs are supported',
      };
    }

    // SECURITY (v1.41.0): the URL comes from third-party skill code. A
    // script could otherwise probe loopback/LAN services and read the
    // responses back (SSRF). Every redirect HOP is checked as well: the
    // client used to follow a public URL straight into `http://192.168.x.x`.
    Uri current = parsed;
    String currentMethod = method.toUpperCase();
    String? currentBody = body;
    http.StreamedResponse response;
    for (int hop = 0; ; hop++) {
      if (!RemoteGuard.isAllowedUrl(current.toString(), requireHttps: false)) {
        return <String, dynamic>{
          'ok': false,
          'error':
              'Blocked URL (only public http(s) hosts are allowed): $current',
        };
      }
      final http.Request request = http.Request(currentMethod, current)
        ..followRedirects = false;
      final String? ua = resolveUserAgent?.call();
      if (ua != null && ua.isNotEmpty) {
        request.headers['User-Agent'] = ua;
      }
      request.headers['Accept'] = '*/*';
      for (final MapEntry<String, String> e in headers.entries) {
        final String name = e.key.trim();
        if (name.isEmpty ||
            name.toLowerCase() == 'user-agent' ||
            name.toLowerCase() == 'host' ||
            name.toLowerCase() == 'content-length') {
          continue;
        }
        request.headers[name] = e.value;
      }
      final String? requestBody = currentBody;
      if (requestBody != null &&
          currentMethod != 'GET' &&
          currentMethod != 'HEAD') {
        if (bodyIsBase64) {
          try {
            request.bodyBytes = base64Decode(requestBody);
          } catch (_) {
            return const <String, dynamic>{
              'ok': false,
              'error': 'Request body is not valid base64',
            };
          }
        } else {
          request.bodyBytes = utf8.encode(requestBody);
        }
      }
      try {
        response = await _client.send(request).timeout(timeout);
      } catch (e) {
        return <String, dynamic>{'ok': false, 'error': 'fetch failed: $e'};
      }
      // NOTE: StreamedResponse.isRedirect is a constructor FIELD (default
      // false), not a status-code getter — hand-built responses and
      // several client wrappers never set it. Detect redirects from the
      // status code (the SSRF hop checks below must also run for those).
      if (!const <int>{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        break;
      }
      final String? location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null || location.trim().isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'error': 'Redirect without a Location header from $current',
        };
      }
      if (hop >= 4) {
        return <String, dynamic>{
          'ok': false,
          'error': 'Too many redirects for $url',
        };
      }
      current = current.resolve(location.trim());
      final int status = response.statusCode;
      if (status == 301 || status == 302 || status == 303) {
        // Browser semantics: these redirects turn the request into a GET.
        currentMethod = 'GET';
        currentBody = null;
      }
    }

    try {
      final List<int> bytes = await response.stream.fold(<int>[], (
        List<int> acc,
        List<int> chunk,
      ) {
        if (acc.length < maxResponseBytes) {
          acc.addAll(
            chunk.length > maxResponseBytes - acc.length
                ? chunk.sublist(0, maxResponseBytes - acc.length)
                : chunk,
          );
        }
        return acc;
      });
      final Uint8List payload = Uint8List.fromList(bytes);

      final Map<String, String> responseHeaders = <String, String>{
        for (final MapEntry<String, String> e in response.headers.entries)
          e.key.toLowerCase(): e.value,
      };
      final String contentType = responseHeaders['content-type'] ?? '';

      // Textual payloads travel as text (cheap, direct json()/text());
      // everything else (packfiles, images, protobufs) as base64 so
      // arrayBuffer() can reconstruct the exact bytes.
      final bool looksTextual =
          contentType.isEmpty ||
          contentType.startsWith('text/') ||
          contentType.contains('json') ||
          contentType.contains('xml') ||
          contentType.contains('javascript') ||
          contentType.contains('x-www-form-urlencoded');
      String bodyText = '';
      String? bodyBase64;
      if (looksTextual) {
        bodyText = utf8.decode(payload, allowMalformed: true);
      } else {
        bodyBase64 = base64Encode(payload);
      }

      return ScriptFetchResult(
        status: response.statusCode,
        statusText: response.reasonPhrase ?? '',
        bodyText: bodyText,
        bodyBase64: bodyBase64,
        headers: responseHeaders,
      ).toBridge();
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'fetch failed: $e'};
    }
  }
}
