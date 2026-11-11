import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'remote_guard.dart';

/// Outcome of a [WebFetcher.fetch] call.
class WebFetchResult {
  const WebFetchResult({required this.ok, required this.output});

  final bool ok;
  final String output;
}

/// Fetches a URL server-side (HTML page, JSON API or plain text) and turns
/// the body into readable text for the agent.
///
/// Kept as a small pure class so the whole pipeline — response caps,
/// content-type dispatch, HTML→text stripping, entity decoding and
/// truncation — is unit-testable with a mocked [http.Client].
class WebFetcher {
  WebFetcher({http.Client? client, this.resolveUserAgent})
    : _client = client ?? http.Client();

  /// Resolves the User-Agent for outgoing requests so they carry the same
  /// identity the embedded browser uses (Settings → User Agent). Falls
  /// back to a constant modern Chrome mobile UA when absent.
  final String? Function()? resolveUserAgent;

  final http.Client _client;

  static const Duration requestTimeout = Duration(seconds: 20);

  /// Responses larger than this are cut off mid-stream — no unbounded
  /// downloads into the chat.
  static const int maxBodyBytes = 1024 * 1024;

  static const int defaultMaxLength = 8000;
  static const int maxMaxLength = 20000;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  /// Message for a URL that [RemoteGuard] refused (SSRF policy).
  static String _blockedMessage(Uri uri) =>
      'Refusing to fetch $uri — only public http(s) hosts are allowed '
      '(loopback, private/LAN and single-label hosts are blocked).';

  Future<WebFetchResult> fetch(
    String url, {
    int maxLength = defaultMaxLength,
  }) async {
    final int limit = maxLength < 1
        ? defaultMaxLength
        : (maxLength > maxMaxLength ? maxMaxLength : maxLength);
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null ||
        !parsed.hasScheme ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return const WebFetchResult(
        ok: false,
        output: 'Only http(s) URLs are supported.',
      );
    }

    // SECURITY (v1.41.0): the URL is model-authored. Without a policy the
    // agent could make the device fetch its own loopback services or the
    // user's LAN (routers, NAS, admin panels) — classic SSRF. Redirects
    // are followed manually so every HOP is checked too: the http client
    // used to follow a public URL straight into `http://192.168.x.x`.
    Uri current = parsed;
    http.StreamedResponse response;
    for (int hop = 0; ; hop++) {
      if (!RemoteGuard.isAllowedUrl(current.toString(), requireHttps: false)) {
        return WebFetchResult(ok: false, output: _blockedMessage(current));
      }
      final http.Request request = http.Request('GET', current)
        ..followRedirects = false;
      request.headers['Accept'] =
          'text/html,application/json;q=0.9,text/plain;q=0.8,*/*;q=0.5';
      request.headers['User-Agent'] =
          resolveUserAgent?.call() ?? defaultUserAgent;
      try {
        response = await _client.send(request).timeout(requestTimeout);
      } on TimeoutException {
        return WebFetchResult(
          ok: false,
          output:
              'Request timed out after ${requestTimeout.inSeconds}s: '
              '$current',
        );
      } catch (e) {
        return WebFetchResult(ok: false, output: 'Request failed: $e');
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
        return WebFetchResult(
          ok: false,
          output: 'Redirect without a Location header from $current',
        );
      }
      if (hop >= 4) {
        return WebFetchResult(ok: false, output: 'Too many redirects for $url');
      }
      current = current.resolve(location.trim());
    }
    final Uri uri = current;

    // Read the body with a hard cap so oversized responses never blow up
    // memory (the loop stops pulling once the cap is reached).
    final BytesBuilder builder = BytesBuilder(copy: false);
    try {
      await for (final List<int> chunk in response.stream) {
        builder.add(chunk);
        if (builder.length >= maxBodyBytes) break;
      }
    } catch (e) {
      return WebFetchResult(
        ok: false,
        output: 'Request failed while reading the body: $e',
      );
    }
    final Uint8List body = builder.takeBytes();
    final String text = utf8.decode(body, allowMalformed: true);

    final int status = response.statusCode;
    if (status < 200 || status >= 300) {
      final String preview = text.length > 300
          ? '${text.substring(0, 300)}…'
          : text;
      return WebFetchResult(
        ok: false,
        output: 'HTTP $status for $uri. Body: $preview',
      );
    }

    final String mime = (response.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    String converted;
    if (mime == 'application/json' ||
        mime == 'text/json' ||
        mime.endsWith('+json')) {
      converted = prettyJson(text);
    } else if (mime == 'text/html' || mime == 'application/xhtml+xml') {
      converted = htmlToText(text);
    } else if (mime == 'text/plain' || mime.isEmpty) {
      converted = text;
    } else {
      return WebFetchResult(
        ok: false,
        output: 'unsupported content-type: $mime (url: $uri)',
      );
    }
    return WebFetchResult(ok: true, output: truncate(converted, limit));
  }

  /// Pretty-prints a JSON body (indented by 2). Falls back to the raw text
  /// when parsing fails.
  static String prettyJson(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  /// Appends a clear truncation marker when [text] exceeds [limit].
  static String truncate(String text, int limit) =>
      text.length > limit ? '${text.substring(0, limit)}\n…[truncated]' : text;

  static final RegExp _scriptRe = RegExp(
    r'<script\b[\s\S]*?</script\s*>',
    caseSensitive: false,
  );
  static final RegExp _styleRe = RegExp(
    r'<style\b[\s\S]*?</style\s*>',
    caseSensitive: false,
  );
  static final RegExp _noscriptRe = RegExp(
    r'<noscript\b[\s\S]*?</noscript\s*>',
    caseSensitive: false,
  );
  static final RegExp _commentRe = RegExp(r'<!--[\s\S]*?-->');
  static final RegExp _blockTagRe = RegExp(
    r'<br\s*/?>|</(p|div|h[1-6]|li|tr|ul|ol|table|section|article|blockquote|pre|header|footer|main|nav|form)\s*>',
    caseSensitive: false,
  );
  static final RegExp _anyTagRe = RegExp(r'<[^>]*>');
  static final RegExp _hexEntityRe = RegExp(r'&#x([0-9a-fA-F]+);?');
  static final RegExp _decEntityRe = RegExp(r'&#(\d+);?');
  static final RegExp _spacesRe = RegExp(r'[ \t\xa0]+');

  /// Converts an HTML document to readable plain text: script/style/
  /// noscript/comment blocks are dropped, block-level tags become line
  /// breaks, remaining tags are stripped, common entities are decoded and
  /// runs of blank lines are collapsed.
  static String htmlToText(String html) {
    String s = html
        .replaceAll(_scriptRe, ' ')
        .replaceAll(_styleRe, ' ')
        .replaceAll(_noscriptRe, ' ')
        .replaceAll(_commentRe, ' ');
    s = s.replaceAll(_blockTagRe, '\n');
    s = s.replaceAll(_anyTagRe, ' ');
    s = _decodeEntities(s);
    final List<String> out = <String>[];
    for (String line in s.split('\n')) {
      line = line.replaceAll(_spacesRe, ' ').trim();
      if (line.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
      out.add(line);
    }
    return out.join('\n').trim();
  }

  static String _decodeEntities(String input) {
    String s = input.replaceAllMapped(_hexEntityRe, (Match m) {
      final int? code = int.tryParse(m.group(1)!, radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    s = s.replaceAllMapped(_decEntityRe, (Match m) {
      final int? code = int.tryParse(m.group(1)!);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&'); // ampersand last (double-escape safety)
  }
}
