import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of one external Ollama server probe — v1.51.0.
class ExternalOllamaScan {
  const ExternalOllamaScan({
    required this.host,
    this.ok = false,
    this.version = '',
    this.error,
  });

  /// The host exactly as the user typed it (echoed back in the UI).
  final String host;

  /// Whether an Ollama-compatible server answered `GET /api/version`.
  final bool ok;

  /// Server version string (`0.12.6`) when reported; '' otherwise.
  final String version;

  /// Human-readable failure reason (English — surfaced in the probe row
  /// detail, not localized); null when [ok] is true.
  final String? error;
}

/// Probes hosts for an external Ollama server — v1.51.0.
///
/// The Server tab lets the user check whether another Ollama instance
/// (on the device at `127.0.0.1:11434`, or on the LAN) is reachable, so
/// they can point the regular LLM provider at it instead of the bundled
/// runtime. One `GET /api/version` call with a short timeout; never
/// throws — every failure becomes [ExternalOllamaScan.error]. The
/// [http.Client] is injectable (same pattern as [UpdateChecker]).
class ExternalOllamaScanner {
  ExternalOllamaScanner({
    http.Client? client,
    this.timeout = const Duration(milliseconds: 2500),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Probe timeout — 2.5 s keeps an unreachable LAN host from blocking
  /// the UI row for long. Injectable so tests can shorten it.
  final Duration timeout;

  /// Normalizes a user-typed host into a base URL:
  /// * whitespace and trailing slashes are stripped;
  /// * a missing scheme gets `http://` (Ollama serves plain HTTP);
  /// * an explicit scheme (`https://…`) is respected.
  static String normalizeHost(String host) {
    String base = host.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isNotEmpty && !base.contains('://')) base = 'http://$base';
    return base;
  }

  /// Probes [host] for an Ollama-compatible `/api/version` endpoint.
  Future<ExternalOllamaScan> probe(String host) async {
    final String base = normalizeHost(host);
    if (base.isEmpty) {
      return const ExternalOllamaScan(host: '', error: 'host is empty');
    }
    final Uri uri = Uri.parse('$base/api/version');
    try {
      final http.Response response = await _client.get(uri).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return ExternalOllamaScan(
          host: host,
          error: 'HTTP ${response.statusCode}',
        );
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (error) {
        return ExternalOllamaScan(
          host: host,
          error: 'invalid JSON from /api/version: $error',
        );
      }
      final Object? version = decoded is Map ? decoded['version'] : null;
      return ExternalOllamaScan(
        host: host,
        ok: true,
        version: version is String ? version : '',
      );
    } on TimeoutException {
      return ExternalOllamaScan(
        host: host,
        error: 'probe timed out after ${timeout.inMilliseconds}ms',
      );
    } catch (error) {
      return ExternalOllamaScan(host: host, error: '$error');
    }
  }
}
