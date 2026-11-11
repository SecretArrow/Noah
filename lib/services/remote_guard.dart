import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown by [RemoteGuard] when a URL or download is rejected.
class RemoteGuardException implements Exception {
  const RemoteGuardException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// URL and download policy for user/agent supplied remote content (skills,
/// npm packages, module archives).
///
/// Two threats are handled here, both reachable from the chat:
///  * **SSRF** — a source like `https://127.0.0.1:8080` or
///    `http://192.168.1.1` would make the device fetch its own local
///    services or the user's LAN (routers, NAS, admin panels).
///  * **Resource exhaustion** — an endpoint that streams forever, or an
///    archive that expands without bound, must not be able to fill memory.
class RemoteGuard {
  const RemoteGuard._();

  static final RegExp _dottedQuad = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
  );

  /// True only for public endpoints.
  ///
  /// [requireHttps] is the default policy for downloaded code and
  /// archives. Callers that fetch user-visible pages (`web_fetch`, skill
  /// script `fetch`) pass `false`: plain `http` is allowed there, but the
  /// SSRF rules (no loopback, LAN, CGNAT, link-local, multicast or
  /// single-label host) still apply — a skill script must not be able to
  /// probe the user's router.
  static bool isAllowedUrl(String url, {bool requireHttps = true}) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    final bool schemeOk = requireHttps
        ? uri.scheme == 'https'
        : (uri.scheme == 'http' || uri.scheme == 'https');
    if (!schemeOk) return false;
    String host = uri.host.toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty) return false;
    if (host == 'localhost' || host.endsWith('.localhost')) return false;
    // A single-label host (`http://router/`, `http://metadata/`) resolves
    // on the local network only — there is no public site to fetch.
    if (!host.contains('.') && !host.contains(':')) return false;
    final Match? match = _dottedQuad.firstMatch(host);
    if (match != null) {
      final List<int> parts = <int>[
        for (int i = 1; i <= 4; i++) int.parse(match.group(i)!),
      ];
      if (parts.any((int p) => p > 255)) return false;
      return _isPublicIpv4(parts[0], parts[1], parts[2], parts[3]);
    }
    if (host.contains(':')) {
      // Strip an IPv6 zone id (`fe80::1%25eth0`): it does not change the
      // address the socket connects to.
      final List<int>? hextets = _ipv6Hextets(host.split('%').first);
      // A malformed literal is refused rather than guessed at.
      if (hextets == null) return false;
      // IPv4-mapped (`::ffff:127.0.0.1`) and IPv4-compatible (`::127.0.0.1`)
      // forms reach the same address as the bare literal, so they must be
      // judged by the IPv4 rules. NOTE: Dart canonicalises the mapped form
      // to hex (`::ffff:7f00:1`), so this cannot be a prefix match on the
      // dotted text.
      final bool zeroPrefix =
          hextets[0] == 0 &&
          hextets[1] == 0 &&
          hextets[2] == 0 &&
          hextets[3] == 0 &&
          hextets[4] == 0;
      if (zeroPrefix && (hextets[5] == 0 || hextets[5] == 0xffff)) {
        return _isPublicIpv4(
          (hextets[6] >> 8) & 0xff,
          hextets[6] & 0xff,
          (hextets[7] >> 8) & 0xff,
          hextets[7] & 0xff,
        );
      }
      // NAT64 well-known prefix `64:ff9b::/96` embeds an IPv4 address.
      if (hextets[0] == 0x64 &&
          hextets[1] == 0xff9b &&
          hextets[2] == 0 &&
          hextets[3] == 0 &&
          hextets[4] == 0 &&
          hextets[5] == 0) {
        return _isPublicIpv4(
          (hextets[6] >> 8) & 0xff,
          hextets[6] & 0xff,
          (hextets[7] >> 8) & 0xff,
          hextets[7] & 0xff,
        );
      }
      if ((hextets[0] & 0xffc0) == 0xfe80) return false; // link-local /10
      if ((hextets[0] & 0xfe00) == 0xfc00) return false; // unique-local /7
      if ((hextets[0] & 0xff00) == 0xff00) return false; // multicast /8
      // Unspecified (`::`) and loopback (`::1`).
      bool allZeroExceptLast = true;
      for (int i = 0; i < 7; i++) {
        if (hextets[i] != 0) {
          allZeroExceptLast = false;
          break;
        }
      }
      if (allZeroExceptLast && (hextets[7] == 0 || hextets[7] == 1)) {
        return false;
      }
    }
    return true;
  }

  /// Shared IPv4 policy for bare literals and addresses embedded in IPv6.
  static bool _isPublicIpv4(int a, int b, int c, int d) {
    if (a == 0 || a == 10 || a == 127) return false;
    if (a == 169 && b == 254) return false; // link-local
    if (a == 172 && b >= 16 && b <= 31) return false; // private
    if (a == 192 && b == 168) return false; // private
    if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
    if (a == 198 && (b == 18 || b == 19)) return false; // benchmarking
    if (a == 192 && b == 0 && c == 0) return false; // IETF protocol
    if (a >= 224) return false; // multicast / reserved
    return true;
  }

  /// Expands an IPv6 literal (no brackets, no zone id) into eight hextets.
  /// Returns null when the text is not a valid address.
  static List<int>? _ipv6Hextets(String host) {
    String text = host;
    // A trailing dotted quad (`::ffff:127.0.0.1`) stands for two hextets.
    if (text.contains('.')) {
      final int lastColon = text.lastIndexOf(':');
      if (lastColon < 0) return null;
      final Match? quad = _dottedQuad.firstMatch(text.substring(lastColon + 1));
      if (quad == null) return null;
      final List<int> octets = <int>[
        for (int i = 1; i <= 4; i++) int.parse(quad.group(i)!),
      ];
      if (octets.any((int o) => o > 255)) return null;
      text =
          '${text.substring(0, lastColon + 1)}'
          '${((octets[0] << 8) | octets[1]).toRadixString(16)}:'
          '${((octets[2] << 8) | octets[3]).toRadixString(16)}';
    }
    final int gap = text.indexOf('::');
    if (gap >= 0 && text.indexOf('::', gap + 1) >= 0) return null;
    final String left = gap < 0 ? text : text.substring(0, gap);
    final String right = gap < 0 ? '' : text.substring(gap + 2);
    final List<int> head = <int>[];
    final List<int> tail = <int>[];
    for (final String part
        in left.isEmpty ? const <String>[] : left.split(':')) {
      final int? value = int.tryParse(part, radix: 16);
      if (value == null || value < 0 || value > 0xffff) return null;
      head.add(value);
    }
    for (final String part
        in right.isEmpty ? const <String>[] : right.split(':')) {
      final int? value = int.tryParse(part, radix: 16);
      if (value == null || value < 0 || value > 0xffff) return null;
      tail.add(value);
    }
    if (gap < 0) {
      return head.length == 8 ? head : null;
    }
    final int zeros = 8 - head.length - tail.length;
    if (zeros < 1) return null;
    return <int>[...head, ...List<int>.filled(zeros, 0), ...tail];
  }

  /// Downloads [uri] with a hard byte cap and per-hop URL validation.
  ///
  /// The `http` client follows redirects on its own, which would let an
  /// allowed https URL bounce to `http://` or to `http://192.168.x.x` after
  /// the initial check. Redirects are therefore followed manually, and the
  /// body is capped while streaming so a hostile endpoint cannot exhaust
  /// memory by declaring a small Content-Length and then sending forever.
  static Future<List<int>> download(
    http.Client client,
    Uri uri, {
    Map<String, String>? headers,
    required int maxBytes,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    Uri current = uri;
    for (int hop = 0; hop < 5; hop++) {
      if (!isAllowedUrl(current.toString())) {
        throw RemoteGuardException(
          'Refusing to download from an untrusted URL: $current '
          '(https on a public host is required).',
        );
      }
      final http.Request request = http.Request('GET', current);
      if (headers != null) request.headers.addAll(headers);
      final http.StreamedResponse response = await client
          .send(request)
          .timeout(timeout);
      // NOTE: StreamedResponse.isRedirect is a constructor FIELD (default
      // false), not a status-code getter — hand-built responses and several
      // client wrappers never set it, so a 302 would fall through to the
      // not-200 branch. Detect redirects from the status code instead.
      if (const <int>{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final String? location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null || location.isEmpty) {
          throw RemoteGuardException(
            'Redirect without a Location header from $current',
          );
        }
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw RemoteGuardException(
          'Download failed: HTTP ${response.statusCode} for $current',
        );
      }
      final int? declared = response.contentLength;
      if (declared != null && declared > maxBytes) {
        await response.stream.drain<void>();
        throw RemoteGuardException(
          'Download exceeds the ${_mb(maxBytes)} MB limit.',
        );
      }
      final BytesBuilder builder = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.stream) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw RemoteGuardException(
            'Download exceeds the ${_mb(maxBytes)} MB limit.',
          );
        }
      }
      return builder.takeBytes();
    }
    throw RemoteGuardException('Too many redirects for $uri');
  }

  static int _mb(int bytes) => (bytes / (1024 * 1024)).round();
}
