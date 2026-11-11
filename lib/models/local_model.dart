/// Local AI model model — v1.51.0 (state extended in v1.52.0).
///
/// A [LocalModelEntry] is ONE GGUF model file managed by the Ollama Manage
/// screen: either downloaded from the Ollama registry (the bundled catalog
/// or any custom ref), fetched from a direct URL, or imported from a user
/// file. The repository stores an UNBOUNDED list of entries; every entry
/// keeps the provenance needed to re-download it later (registry ref or
/// direct URL) plus the sha256 recorded at download time so integrity can
/// be re-verified.
///
/// [LocalModelState] is the whole persisted store of the feature: the
/// installed list plus the llama-server configuration (port / context
/// size / threads) shared by every start — and, since v1.52.0, the
/// fetched remote-catalog overlay kept in sync with the built-ins.
library;

import '../services/local_ai/model_catalog_data.dart'
    show CatalogModelEntry, catalogEntryFromJson, catalogEntryToJson;

/// Where a local model came from.
enum LocalModelSource { catalog, customUrl, imported }

/// Resolves a wire name to [LocalModelSource]; unknown spellings fall
/// back to [LocalModelSource.imported] (the safest default — an unknown
/// provenance is treated as a plain user file with no re-download info).
LocalModelSource localModelSourceFromName(String? name) {
  switch (name) {
    case 'catalog':
      return LocalModelSource.catalog;
    case 'customUrl':
      return LocalModelSource.customUrl;
    case 'imported':
    default:
      return LocalModelSource.imported;
  }
}

/// One installed local model (a GGUF file inside the models dir).
class LocalModelEntry {
  const LocalModelEntry({
    required this.id,
    required this.name,
    this.source = LocalModelSource.imported,
    this.ollamaRef = '',
    this.customUrl = '',
    required this.fileName,
    this.sizeBytes = 0,
    this.sha256 = '',
    required this.addedAtMs,
    this.lastUsedAtMs,
  });

  final String id;

  /// Display name — also used as the `--alias` when llama-server starts.
  final String name;

  final LocalModelSource source;

  /// Ollama registry reference (`qwen3:0.6b`); empty when not sourced
  /// from the registry.
  final String ollamaRef;

  /// Direct GGUF download URL; empty when not a custom-URL download.
  final String customUrl;

  /// File name inside the models dir, always `<id>.gguf` so every entry
  /// maps to exactly one file regardless of its display name.
  final String fileName;

  /// Size on disk in bytes; filled by the downloader/importer (0 while
  /// only queued).
  final int sizeBytes;

  /// Lowercase hex sha256 recorded when the file was written; empty when
  /// unknown (custom URL without a digest, or a legacy entry).
  final String sha256;

  final int addedAtMs;

  /// Last time the model was started; null = never used yet.
  final int? lastUsedAtMs;

  /// Sentinel for "keep the current value" in copyWith — passing an
  /// explicit null CLEARS the field (mirrors [CronJob.copyWith]).
  static const Object _unset = Object();

  LocalModelEntry copyWith({
    String? id,
    String? name,
    LocalModelSource? source,
    String? ollamaRef,
    String? customUrl,
    String? fileName,
    int? sizeBytes,
    String? sha256,
    int? addedAtMs,
    Object? lastUsedAtMs = _unset,
  }) => LocalModelEntry(
    id: id ?? this.id,
    name: name ?? this.name,
    source: source ?? this.source,
    ollamaRef: ollamaRef ?? this.ollamaRef,
    customUrl: customUrl ?? this.customUrl,
    fileName: fileName ?? this.fileName,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    sha256: sha256 ?? this.sha256,
    addedAtMs: addedAtMs ?? this.addedAtMs,
    lastUsedAtMs: lastUsedAtMs == _unset
        ? this.lastUsedAtMs
        : lastUsedAtMs as int?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'source': source.name,
    'ollamaRef': ollamaRef,
    'customUrl': customUrl,
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'addedAtMs': addedAtMs,
    'lastUsedAtMs': lastUsedAtMs,
  };

  factory LocalModelEntry.fromJson(Map<String, dynamic> json) =>
      LocalModelEntry(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        source: localModelSourceFromName(json['source'] as String?),
        ollamaRef: json['ollamaRef'] as String? ?? '',
        customUrl: json['customUrl'] as String? ?? '',
        fileName: json['fileName'] as String? ?? '',
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        sha256: json['sha256'] as String? ?? '',
        addedAtMs: json['addedAtMs'] as int? ?? 0,
        lastUsedAtMs: json['lastUsedAtMs'] as int?,
      );
}

/// Whole persisted Local AI store: the installed model list plus the
/// llama-server configuration (v1.51.0), plus the remote-catalog overlay
/// (v1.52.0 Fase 2 — empty until the user refreshes the Catalog tab).
class LocalModelState {
  const LocalModelState({
    this.installed = const <LocalModelEntry>[],
    this.serverPort = 11434,
    this.contextSize = 2048,
    this.threads = 0,
    this.autoStartOnBoot = false,
    this.remoteCatalog = const <CatalogModelEntry>[],
  });

  final List<LocalModelEntry> installed;

  /// llama-server port — 11434 by default so an external Ollama client
  /// pointed at the device keeps working.
  final int serverPort;

  /// `-c` context window passed to llama-server; 2048 keeps the KV cache
  /// small on low-RAM devices (the UI can raise it per model).
  final int contextSize;

  /// `-t` thread count; 0 = let the Kotlin side pick a sensible default
  /// (`availableProcessors / 2`, min 1).
  final int threads;

  /// Fase 2 — start the active model automatically after boot.
  final bool autoStartOnBoot;

  /// Fase 2 (v1.52.0) — the last fetched remote catalog, overlaid onto
  /// the built-in [kLocalAiCatalog] by `mergeCatalog` in the Catalog tab.
  /// Empty until the first successful refresh; cleared by “Reset”.
  final List<CatalogModelEntry> remoteCatalog;

  LocalModelState copyWith({
    List<LocalModelEntry>? installed,
    int? serverPort,
    int? contextSize,
    int? threads,
    bool? autoStartOnBoot,
    List<CatalogModelEntry>? remoteCatalog,
  }) => LocalModelState(
    installed: installed ?? this.installed,
    serverPort: serverPort ?? this.serverPort,
    contextSize: contextSize ?? this.contextSize,
    threads: threads ?? this.threads,
    autoStartOnBoot: autoStartOnBoot ?? this.autoStartOnBoot,
    remoteCatalog: remoteCatalog ?? this.remoteCatalog,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'installed': installed.map((e) => e.toJson()).toList(),
    'serverPort': serverPort,
    'contextSize': contextSize,
    'threads': threads,
    'autoStartOnBoot': autoStartOnBoot,
    'remoteCatalog': [
      for (final CatalogModelEntry e in remoteCatalog) catalogEntryToJson(e),
    ],
  };

  factory LocalModelState.fromJson(Map<String, dynamic> json) =>
      LocalModelState(
        installed: (json['installed'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(LocalModelEntry.fromJson)
            .toList(),
        serverPort: json['serverPort'] as int? ?? 11434,
        contextSize: json['contextSize'] as int? ?? 2048,
        threads: json['threads'] as int? ?? 0,
        autoStartOnBoot: json['autoStartOnBoot'] as bool? ?? false,
        remoteCatalog:
            (json['remoteCatalog'] as List<dynamic>? ?? const <dynamic>[])
                .whereType<Map<String, dynamic>>()
                .map(catalogEntryFromJson)
                .toList(),
      );
}
