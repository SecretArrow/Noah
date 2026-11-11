import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Per-chat scheduled-job storage (v1.51.0, Fase F cronjobs):
/// key `noah.jobs.v1.<sessionId>` holds a LIST of jobs — many
/// independent jobs per chat are the norm (cap enforced by the service).
abstract class ScheduledJobRepository {
  List<ScheduledJob> load(String sessionId);
  Future<void> save(String sessionId, List<ScheduledJob> jobs);
}

class PrefsScheduledJobRepository implements ScheduledJobRepository {
  PrefsScheduledJobRepository(this._prefs);

  final SharedPreferences _prefs;

  static String keyFor(String sessionId) => 'noah.jobs.v1.$sessionId';

  static Future<PrefsScheduledJobRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PrefsScheduledJobRepository(prefs);
  }

  @override
  List<ScheduledJob> load(String sessionId) {
    if (sessionId.isEmpty) return const <ScheduledJob>[];
    final raw = _prefs.getString(keyFor(sessionId));
    if (raw == null || raw.isEmpty) return const <ScheduledJob>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <ScheduledJob>[
          for (final item in decoded)
            if (item is Map<String, dynamic>) ScheduledJob.fromJson(item),
        ];
      }
    } catch (_) {
      // Corrupted store: behave like an empty list, never crash.
    }
    return const <ScheduledJob>[];
  }

  @override
  Future<void> save(String sessionId, List<ScheduledJob> jobs) async {
    if (sessionId.isEmpty) return;
    await _prefs.setString(
      keyFor(sessionId),
      jsonEncode(<Map<String, dynamic>>[
        for (final ScheduledJob j in jobs) j.toJson(),
      ]),
    );
  }
}

/// In-memory repository for tests (per-session map).
class InMemoryScheduledJobRepository implements ScheduledJobRepository {
  InMemoryScheduledJobRepository([Map<String, List<ScheduledJob>>? initial])
    : _bySession = initial ?? <String, List<ScheduledJob>>{};

  final Map<String, List<ScheduledJob>> _bySession;

  @override
  List<ScheduledJob> load(String sessionId) =>
      List<ScheduledJob>.of(_bySession[sessionId] ?? const <ScheduledJob>[]);

  @override
  Future<void> save(String sessionId, List<ScheduledJob> jobs) async {
    _bySession[sessionId] = List<ScheduledJob>.of(jobs);
  }
}
