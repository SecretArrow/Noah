import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/cron_job.dart';

/// Persistent cron store — Noah adaptation of the ZAgents cron
/// repository. The ONE deliberate difference: storage is scoped PER
/// CHAT SESSION (key `noah.cronjobs.v1.<sessionId>`), because in
/// Noah all personal data is isolated per chat and must never mix.
/// A chat only ever loads its own jobs, history and master switch.
///
/// [load] is synchronous on purpose — it mirrors the
/// [PrefsSettingsRepository] contract so the Riverpod controller can
/// build state without awaiting platform channels.
abstract class CronRepository {
  CronState load(String sessionId);
  Future<void> save(String sessionId, CronState state);
}

/// SharedPreferences-backed [CronRepository]. Each chat's store holds
/// an UNBOUNDED job list plus a run history capped at [historyCap]
/// entries (newest first).
class PrefsCronRepository implements CronRepository {
  PrefsCronRepository(this._prefs);

  final SharedPreferences _prefs;

  static String keyFor(String sessionId) => 'noah.cronjobs.v1.$sessionId';

  /// Maximum recorded runs kept per chat.
  static const int historyCap = 30;

  static Future<PrefsCronRepository> create() async =>
      PrefsCronRepository(await SharedPreferences.getInstance());

  @override
  CronState load(String sessionId) {
    if (sessionId.isEmpty) return const CronState();
    final String? raw = _prefs.getString(keyFor(sessionId));
    if (raw == null || raw.isEmpty) return const CronState();
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const CronState();
      return CronState.fromJson(decoded);
    } catch (_) {
      // Corrupted store: fall back to defaults rather than crash boot.
      return const CronState();
    }
  }

  @override
  Future<void> save(String sessionId, CronState state) async {
    if (sessionId.isEmpty) return;
    final List<CronRunEntry> history = state.history.length > historyCap
        ? state.history.sublist(0, historyCap)
        : state.history;
    await _prefs.setString(
      keyFor(sessionId),
      jsonEncode(state.copyWith(history: history).toJson()),
    );
  }
}

/// In-memory repository for unit and widget tests.
class MemoryCronRepository implements CronRepository {
  MemoryCronRepository([Map<String, CronState>? initial])
    : _states = initial ?? <String, CronState>{};

  final Map<String, CronState> _states;

  @override
  CronState load(String sessionId) => sessionId.isEmpty
      ? const CronState()
      : _states[sessionId] ?? const CronState();

  @override
  Future<void> save(String sessionId, CronState state) async {
    if (sessionId.isEmpty) return;
    _states[sessionId] = state;
  }
}
