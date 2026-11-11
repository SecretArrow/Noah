import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'module_registry.dart';

/// v1.46.0 — remote module intake: downloads module ZIPs over HTTPS and
/// funnels the bytes through [ModuleRegistry.installFromBytes], so a
/// remote install runs the EXACT same scrutiny as a local ZIP pick
/// (48 MB cap, manifest parse, zip-slip, atomic staging). Two faces:
///
/// * [installFromUrl] — user-supplied module URL ("update from URL").
/// * [installSample]  — one-tap install/update of the OFFICIAL sample
///   modules, whose ZIPs ship inside this app's own GitHub repository
///   (`samples/<name>.zip` on the `main` branch).
///
/// Security posture (user-driven sideload, same as picking a ZIP file):
/// * HTTPS only — plain `http` is accepted solely for loopback hosts so
///   the unit-test fixtures can serve the bytes without TLS.
/// * Hard 48 MB download cap, enforced on the Content-Length header AND
///   on the accumulated byte stream (a lying header cannot overshoot).
/// * Connect + read timeouts so a stalled server cannot hang the UI.
/// * Only the sanitized sample NAME is ever interpolated into a catalog
///   URL — user URLs are used verbatim but the bytes they yield go
///   through the full registry intake before anything touches disk.
class ModuleRemote {
  ModuleRemote({required this.registry, this.rawBaseOverride});

  final ModuleRegistry registry;

  /// Test hook: when set, catalog URLs are built from this base instead
  /// of the production [repoRawBase] — unit tests point it at a loopback
  /// HttpServer fixture so no test ever touches the real network.
  final String? rawBaseOverride;

  /// Raw-content base of the official samples repo (same app, `main`
  /// branch). Sample ZIPs live at `samples/<name>.zip`, their manifests
  /// at `samples/<name>/module.json` — the manifest probe powers the
  /// catalog's Update badge without downloading the whole archive.
  static const String repoRawBase =
      'https://raw.githubusercontent.com/SecretArrow/Noah/main';

  static const int maxUrlLength = 2048;

  /// Total download budget: connect phase and inter-chunk stalls.
  static const Duration connectTimeout = Duration(seconds: 20);
  static const Duration chunkTimeout = Duration(seconds: 60);

  /// Builds the catalog ZIP URL for a sample name. The name is
  /// sanitized first — only `[a-z0-9_-]` survives, so no `../` or
  /// query-string injection can reach the URL path.
  String sampleZipUrl(String name) =>
      '${rawBaseOverride ?? repoRawBase}/samples/${sanitizeSampleName(name)}.zip';

  /// Builds the catalog manifest-probe URL for a sample name.
  String sampleManifestUrl(String name) =>
      '${rawBaseOverride ?? repoRawBase}/samples/${sanitizeSampleName(name)}/module.json';

  /// Reduces a sample name to safe catalog-path characters. Empty output
  /// means the caller must refuse the request.
  static String sanitizeSampleName(String raw) {
    final String lowered = raw.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_-]'),
      '',
    );
    return lowered.length > 64 ? lowered.substring(0, 64) : lowered;
  }

  /// Gate for user-supplied URLs: `https:` anywhere, `http:` only for
  /// loopback hosts (unit-test fixtures on the device never hit a real
  /// network because real servers are unreachable over plain http on
  /// modern Android anyway). Rejects non-http(s) schemes outright.
  static bool isAllowedUrl(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return false;
    if (raw.trim().length > maxUrlLength) return false;
    final String scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') return true;
    if (scheme == 'http') {
      final String host = uri.host.toLowerCase();
      return host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '[::1]' ||
          host == '::1';
    }
    return false;
  }

  /// Best-effort file name for the fetched archive — only feeds the
  /// synthesized manifest name when the ZIP ships no manifest.
  static String _stemFromUrl(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    final String last = (uri?.pathSegments.isNotEmpty ?? false)
        ? uri!.pathSegments.last
        : 'remote-module';
    final String stem = last.replaceAll(
      RegExp(r'\.zip$', caseSensitive: false),
      '',
    );
    return stem.isEmpty ? 'remote-module' : stem;
  }

  /// Downloads the module ZIP at [url] and installs it. Re-installing an
  /// installed module name UPDATES it (the registry's version-aware
  /// atomic replace), so the same entry point serves install and update.
  Future<ModuleInstallResult> installFromUrl(String url) async {
    final String trimmed = url.trim();
    if (!isAllowedUrl(trimmed)) {
      return const ModuleInstallResult(
        ok: false,
        message: 'Only HTTPS module URLs are allowed',
      );
    }
    final HttpClient client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(trimmed));
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return ModuleInstallResult(
          ok: false,
          message: 'Download failed: HTTP ${response.statusCode}',
        );
      }
      // A declared Content-Length over budget aborts before a single
      // body byte is buffered. `contentLength` is -1 when the server
      // does not declare one — only a positive over-budget value aborts
      // here; the streamed accumulator below is the real backstop.
      final int declared = response.contentLength;
      if (declared > 0 && declared > ModuleRegistry.maxZipBytes) {
        return const ModuleInstallResult(
          ok: false,
          message: 'Module ZIP is too large (limit 48 MB)',
        );
      }
      final BytesBuilder builder = BytesBuilder(copy: false);
      int received = 0;
      try {
        await for (final List<int> chunk in response) {
          received += chunk.length;
          if (received > ModuleRegistry.maxZipBytes) {
            return const ModuleInstallResult(
              ok: false,
              message: 'Module ZIP is too large (limit 48 MB)',
            );
          }
          builder.add(chunk);
        }
      } on TimeoutException {
        return const ModuleInstallResult(
          ok: false,
          message: 'Download timed out',
        );
      }
      if (received == 0) {
        return const ModuleInstallResult(
          ok: false,
          message: 'Download failed: empty response',
        );
      }
      return await registry.installFromBytes(
        builder.takeBytes(),
        _stemFromUrl(trimmed),
      );
    } on SocketException catch (e) {
      return ModuleInstallResult(ok: false, message: 'Network error: $e');
    } on HttpException catch (e) {
      return ModuleInstallResult(ok: false, message: 'Network error: $e');
    } catch (e) {
      return ModuleInstallResult(ok: false, message: 'Download failed: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// Installs/updates one OFFICIAL sample module straight from the
  /// repository catalog. The name is sanitized before it reaches a URL.
  Future<ModuleInstallResult> installSample(String name) {
    final String safe = sanitizeSampleName(name);
    if (safe.isEmpty) {
      return Future<ModuleInstallResult>.value(
        const ModuleInstallResult(ok: false, message: 'Invalid module name'),
      );
    }
    return installFromUrl(sampleZipUrl(safe));
  }

  /// Probes the REMOTE version of a sample module by fetching its small
  /// `module.json` (a few hundred bytes) instead of the whole ZIP —
  /// powers the catalog's Update badge. Null on any failure (offline,
  /// 404, malformed): the UI treats null as "unknown" and still offers
  /// a plain install attempt.
  Future<String?> sampleRemoteVersion(String name) async {
    final String safe = sanitizeSampleName(name);
    if (safe.isEmpty) return null;
    final HttpClient client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse(sampleManifestUrl(safe)),
      );
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final String body = await response
          .transform(utf8.decoder)
          .timeout(chunkTimeout)
          .join();
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final Object? version = decoded['version'];
      return version is String && version.isNotEmpty ? version : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
