import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Resolved download target of one Ollama registry model — v1.51.0.
class RegistryBlob {
  const RegistryBlob({
    required this.blobUrl,
    required this.sha256,
    required this.sizeBytes,
  });

  /// Absolute blob URL (`https://registry.ollama.ai/v2/<repo>/blobs/<digest>`).
  final String blobUrl;

  /// sha256 hex digest of the blob (the registry digest minus the
  /// `sha256:` prefix) — used by the downloader to verify the file.
  final String sha256;

  /// Blob size in bytes, as declared by the manifest layer.
  final int sizeBytes;
}

/// Raised for every resolvable failure while talking to the registry:
/// unknown model (HTTP 404), other HTTP statuses, network errors,
/// timeouts and malformed manifests. Always carries a human-readable
/// English message (kept non-localized — it surfaces through the
/// download queue row error, not directly in the UI).
class OllamaRegistryException implements Exception {
  const OllamaRegistryException(this.message);

  final String message;

  @override
  String toString() => 'OllamaRegistryException: $message';
}

/// Parsed Ollama model reference: repository path plus tag.
class _ParsedRef {
  const _ParsedRef(this.repo, this.tag);

  /// Repository path as used in registry URLs (`library/qwen3`,
  /// `hf.co/user/repo`).
  final String repo;

  /// Tag (`0.6b`, `latest`, …).
  final String tag;
}

/// Parses an Ollama model reference into repo + tag — v1.51.0.
///
/// Rules (mirroring `ollama pull` semantics closely enough for the
/// catalog use case):
/// * `qwen3:0.6b` → repo `library/qwen3`, tag `0.6b` (bare names live
///   in the `library` namespace);
/// * `hf.co/user/repo:tag` → repo `hf.co/user/repo` (already carries a
///   namespace, kept verbatim);
/// * a missing tag defaults to `latest`;
/// * a colon followed by a `/` is a registry host port
///   (`localhost:5000/repo`), not a tag separator.
_ParsedRef _parseRef(String raw) {
  final String ref = raw.trim();
  if (ref.isEmpty || ref.contains('://')) {
    throw OllamaRegistryException('invalid model reference: "$raw"');
  }
  String repo = ref;
  String tag = 'latest';
  final int colon = ref.lastIndexOf(':');
  if (colon > 0) {
    final String after = ref.substring(colon + 1);
    if (after.isNotEmpty && !after.contains('/')) {
      repo = ref.substring(0, colon);
      tag = after;
    }
  }
  if (!repo.contains('/')) repo = 'library/$repo';
  return _ParsedRef(repo, tag);
}

/// Resolves an Ollama model reference to its downloadable GGUF blob —
/// v1.51.0.
///
/// Talks to the public Docker-Registry-v2-compatible API of
/// `registry.ollama.ai`: fetches the manifest for `<repo>:<tag>`, picks
/// the largest non-config layer (the model weights — Ollama manifests
/// also carry small params/license/chat-template layers) and returns its
/// blob URL, sha256 digest and size. The [http.Client] is injectable so
/// unit tests plug in a [http.MockClient] (same pattern as
/// [UpdateChecker] and [TelegramSender]).
class OllamaRegistryClient {
  OllamaRegistryClient({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const String _registryBase = 'https://registry.ollama.ai/v2';

  /// Accept header offering both manifest flavors the registry serves.
  static const String _manifestAccept =
      'application/vnd.docker.distribution.manifest.v2+json, '
      'application/vnd.oci.image.manifest.v1+json';

  /// Hard cap for the manifest request (blobs are downloaded separately
  /// by the model downloader, never here).
  static const Duration requestTimeout = Duration(seconds: 15);

  /// Resolves [ref] (`qwen3:0.6b`, `hf.co/user/repo:tag`, …) to the
  /// model blob. Throws [OllamaRegistryException] on every failure —
  /// the caller (download queue) turns it into a failed row.
  Future<RegistryBlob> resolve(String ref) async {
    final _ParsedRef parsed = _parseRef(ref);
    final Uri uri = Uri.parse(
      '$_registryBase/${parsed.repo}/manifests/${parsed.tag}',
    );

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: <String, String>{'Accept': _manifestAccept})
          .timeout(requestTimeout);
    } on TimeoutException {
      throw OllamaRegistryException(
        'registry request timed out after ${requestTimeout.inSeconds}s',
      );
    } catch (error) {
      throw OllamaRegistryException('network error resolving "$ref": $error');
    }

    if (response.statusCode == 404) {
      throw OllamaRegistryException('model not found: "$ref" (HTTP 404)');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OllamaRegistryException(
        'registry returned HTTP ${response.statusCode} for "$ref"',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (error) {
      throw OllamaRegistryException(
        'manifest for "$ref" is not valid JSON: $error',
      );
    }
    if (decoded is! Map) {
      throw OllamaRegistryException('manifest for "$ref" is not a JSON object');
    }
    final Object? rawLayers = decoded['layers'];
    if (rawLayers is! List || rawLayers.isEmpty) {
      throw OllamaRegistryException('manifest for "$ref" has no layers');
    }

    // Largest non-config layer = the GGUF weights. Config layers
    // (docker container/oci config media types) and layers without a
    // sha256 digest are never the model.
    Map<String, dynamic>? best;
    for (final Object? layer in rawLayers) {
      if (layer is! Map) continue;
      final Object? mediaType = layer['mediaType'];
      if (mediaType is String &&
          (mediaType.contains('config') || mediaType.contains('container'))) {
        continue;
      }
      final Object? digest = layer['digest'];
      final Object? size = layer['size'];
      if (digest is! String || !digest.startsWith('sha256:')) continue;
      if (size is! int || size <= 0) continue;
      if (best == null || size > (best['size'] as int)) {
        best = Map<String, dynamic>.from(layer);
      }
    }
    if (best == null) {
      throw OllamaRegistryException(
        'manifest for "$ref" carries no model blob',
      );
    }

    final String digest = best['digest'] as String;
    return RegistryBlob(
      blobUrl: '$_registryBase/${parsed.repo}/blobs/$digest',
      sha256: digest.substring('sha256:'.length),
      sizeBytes: best['size'] as int,
    );
  }
}
