import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../di.dart';
import '../../models/local_model.dart';
import 'model_catalog_data.dart';

/// Abstraction over the persisted Local AI store — v1.51.0. [load] is
/// synchronous on purpose (mirrors [CronRepository]) so the Riverpod
/// controller can build state without awaiting platform channels.
abstract class LocalModelRepository {
  LocalModelState load();
  Future<void> save(LocalModelState state);
}

/// Production [LocalModelRepository] backed by SharedPreferences under
/// `noah.localai.v1` (same shape as [PrefsCronRepository]): the
/// installed model list plus the llama-server config. A corrupted store
/// degrades to defaults rather than crashing boot.
class PrefsLocalModelRepository implements LocalModelRepository {
  PrefsLocalModelRepository(this._prefs);

  final SharedPreferences _prefs;

  static const String _key = 'noah.localai.v1';

  static Future<PrefsLocalModelRepository> create() async =>
      PrefsLocalModelRepository(await SharedPreferences.getInstance());

  @override
  LocalModelState load() {
    final String? raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const LocalModelState();
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const LocalModelState();
      return LocalModelState.fromJson(decoded);
    } catch (_) {
      // Corrupted store: fall back to defaults rather than crash boot.
      return const LocalModelState();
    }
  }

  @override
  Future<void> save(LocalModelState state) async {
    await _prefs.setString(_key, jsonEncode(state.toJson()));
  }
}

/// In-memory repository for unit and widget tests.
class MemoryLocalModelRepository implements LocalModelRepository {
  MemoryLocalModelRepository([LocalModelState? initial])
    : _state = initial ?? const LocalModelState();

  LocalModelState _state;

  @override
  LocalModelState load() => _state;

  @override
  Future<void> save(LocalModelState state) async => _state = state;
}

/// Riverpod controller mirroring the persisted [LocalModelState] —
/// v1.51.0. Owns the installed list (rows are added by the downloader's
/// completion callback / the importer, removed by the user) and the
/// llama-server config used by the Server tab. File deletion on
/// [removeInstalled] goes through the shared LocalModelIo provider so
/// the store and the downloader always agree on the models dir.
class LocalModelsController extends Notifier<LocalModelState> {
  @override
  LocalModelState build() => ref.watch(localModelRepositoryProvider).load();

  LocalModelRepository get _repo => ref.read(localModelRepositoryProvider);

  Future<void> _persist(LocalModelState next) async {
    state = next;
    try {
      await _repo.save(next);
    } catch (_) {
      // Degraded persistence: in-session state stays applied (same
      // trade-off as the cron/settings controllers).
    }
  }

  /// Adds or replaces [entry] (keyed by id — the downloader completes a
  /// queued model exactly once, but a re-download replaces its row).
  Future<void> addInstalled(LocalModelEntry entry) async {
    final List<LocalModelEntry> installed = <LocalModelEntry>[
      for (final LocalModelEntry existing in state.installed)
        existing.id == entry.id ? entry : existing,
    ];
    if (!installed.any((e) => e.id == entry.id)) installed.add(entry);
    await _persist(state.copyWith(installed: installed));
  }

  /// Removes the entry [id] and deletes its backing GGUF (best-effort —
  /// the entry disappears from the store even if the file is already
  /// gone).
  Future<void> removeInstalled(String id) async {
    LocalModelEntry? target;
    for (final LocalModelEntry entry in state.installed) {
      if (entry.id == id) {
        target = entry;
        break;
      }
    }
    await _persist(
      state.copyWith(
        installed: <LocalModelEntry>[
          for (final LocalModelEntry entry in state.installed)
            if (entry.id != id) entry,
        ],
      ),
    );
    if (target != null) {
      try {
        await ref.read(localModelIoProvider).deleteModelFile(target);
      } catch (_) {
        // Best-effort file deletion: the entry is already gone.
      }
    }
  }

  /// Stamps `lastUsedAtMs` (the Installed tab sorts by it).
  Future<void> markUsed(String id) async {
    await _persist(
      state.copyWith(
        installed: <LocalModelEntry>[
          for (final LocalModelEntry entry in state.installed)
            if (entry.id == id)
              entry.copyWith(
                lastUsedAtMs: DateTime.now().millisecondsSinceEpoch,
              )
            else
              entry,
        ],
      ),
    );
  }

  /// Persists the llama-server launch config (port / context / threads;
  /// null keeps the current value).
  Future<void> setServerConfig({
    int? port,
    int? contextSize,
    int? threads,
  }) async {
    await _persist(
      state.copyWith(
        serverPort: port,
        contextSize: contextSize,
        threads: threads,
      ),
    );
  }

  /// Fase 2 — auto-start the active model on boot.
  Future<void> setAutoStartOnBoot(bool enabled) async {
    await _persist(state.copyWith(autoStartOnBoot: enabled));
  }

  /// Fase 2 (v1.52.0) — stores the fetched remote-catalog overlay. An
  /// empty list clears it (the “Reset” action); persists like
  /// [setServerConfig] so the overlay survives restarts and reappears
  /// merged with the built-ins on the next Catalog tab render.
  Future<void> setRemoteCatalog(List<CatalogModelEntry> entries) async {
    await _persist(state.copyWith(remoteCatalog: entries));
  }
}
