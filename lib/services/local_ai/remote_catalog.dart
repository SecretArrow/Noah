import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'model_catalog_data.dart';

/// Remote-catalog source — v1.52.0 (Fase 2).
///
/// The Catalog tab can overlay a JSON catalog fetched over HTTP on top
/// of the built-in [kLocalAiCatalog] (merged by [mergeCatalog]). The
/// default source lives in this repository (`assets/local_ai_catalog.json`
/// on `main`), so updating the app's model list ships without an app
/// release; the same file doubles as the wire-shape documentation.

/// Default remote catalog URL (raw GitHub content of this repository).
const String kRemoteCatalogUrl =
    'https://raw.githubusercontent.com/SecretArrow/Noah/main/'
    'assets/local_ai_catalog.json';

/// Clean failure of a remote-catalog fetch (HTTP error, timeout, bad
/// JSON, unsupported version, empty list).
class RemoteCatalogException implements Exception {
  RemoteCatalogException(this.message);

  final String message;

  @override
  String toString() => 'RemoteCatalogException: $message';
}

/// Wire mirror of one catalog row (the `models[]` element of the remote
/// JSON) — the tier travels as its wire NAME and converts to the enum
/// in [toEntry]; unknown spellings degrade to [CatalogTier.tier2].
class RemoteCatalogEntry {
  const RemoteCatalogEntry({
    required this.ollamaRef,
    required this.downloadBytes,
    required this.ramEstBytes,
    required this.contextTokens,
    required this.tierName,
    this.license = '',
  });

  /// Ollama registry reference (`qwen3:0.6b`); empty rows are dropped.
  final String ollamaRef;

  final int downloadBytes;

  /// Rough running footprint (weights + KV cache) in bytes.
  final int ramEstBytes;

  final int contextTokens;

  /// Tier wire name: `tier1` / `tier2` / `upperBound`.
  final String tierName;

  /// License label shown in the UI ('' = not yet vetted).
  final String license;

  /// Tolerant parse: missing keys degrade to defaults, an unknown tier
  /// name degrades to `tier2` in [toEntry].
  factory RemoteCatalogEntry.fromJson(Map<String, dynamic> json) =>
      RemoteCatalogEntry(
        ollamaRef: json['ollamaRef'] as String? ?? '',
        downloadBytes: (json['downloadBytes'] as num?)?.toInt() ?? 0,
        ramEstBytes: (json['ramEstBytes'] as num?)?.toInt() ?? 0,
        contextTokens: (json['contextTokens'] as num?)?.toInt() ?? 0,
        tierName: json['tier'] as String? ?? 'tier2',
        license: json['license'] as String? ?? '',
      );

  /// Converts the wire row into the catalog model used everywhere else.
  CatalogModelEntry toEntry() => CatalogModelEntry(
    ollamaRef: ollamaRef,
    downloadBytes: downloadBytes,
    ramEstBytes: ramEstBytes,
    contextTokens: contextTokens,
    tier: switch (tierName) {
      'tier1' => CatalogTier.tier1,
      'upperBound' => CatalogTier.upperBound,
      _ => CatalogTier.tier2, // 'tier2' and unknown spellings
    },
    license: license,
  );
}

/// Fetches and validates one remote catalog — v1.52.0 (Fase 2).
///
/// `GET <url>` with a 10 s timeout, expects
/// `{"version": 1, "models": [ … ]}`. An empty or invalid list raises
/// [RemoteCatalogException]; the [http.Client] is injectable (the shared
/// `llmHttpClientProvider` client in production, a MockClient in tests).
class RemoteCatalogService {
  RemoteCatalogService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Fetch timeout — a stalled CDN must not wedge the Catalog tab.
  static const Duration timeout = Duration(seconds: 10);

  Future<List<CatalogModelEntry>> fetch(String url) async {
    final Uri uri = Uri.parse(url.trim());
    try {
      final http.Response response = await _client.get(uri).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RemoteCatalogException('HTTP ${response.statusCode}');
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw RemoteCatalogException(
          'the catalog payload is not a JSON object',
        );
      }
      final Object? rawVersion = decoded['version'];
      final int? version = rawVersion is num ? rawVersion.toInt() : null;
      if (version != 1) {
        throw RemoteCatalogException(
          'unsupported catalog version: $rawVersion',
        );
      }
      final Object? models = decoded['models'];
      if (models is! List) {
        throw RemoteCatalogException('the catalog payload has no models list');
      }
      final List<CatalogModelEntry> entries = <CatalogModelEntry>[];
      for (final Object? item in models) {
        if (item is! Map) continue; // tolerant: skip junk rows
        final RemoteCatalogEntry row = RemoteCatalogEntry.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (row.ollamaRef.trim().isEmpty) continue; // ref-less rows are useless
        entries.add(row.toEntry());
      }
      if (entries.isEmpty) {
        throw RemoteCatalogException('the remote catalog is empty');
      }
      return entries;
    } on RemoteCatalogException {
      rethrow;
    } on TimeoutException {
      throw RemoteCatalogException(
        'the catalog request timed out after ${timeout.inSeconds}s',
      );
    } on FormatException catch (error) {
      throw RemoteCatalogException('invalid catalog JSON: $error');
    } catch (error) {
      throw RemoteCatalogException('catalog request failed: $error');
    }
  }
}
