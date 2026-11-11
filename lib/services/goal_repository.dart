import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Abstraction over the persistent goals storage (v1.50.0).
/// USER CORRECTION (v1.50.1): goals are scoped PER CHAT, exactly like
/// memory — one key per session, no cross-chat visibility.
abstract class GoalRepository {
  List<GoalEntry> load(String sessionId);
  Future<void> save(String sessionId, List<GoalEntry> entries);
}

/// SharedPreferences-backed store used in production (per-chat key).
class PrefsGoalRepository implements GoalRepository {
  PrefsGoalRepository(this._prefs);

  final SharedPreferences _prefs;

  static String keyFor(String sessionId) => 'noah.goals.v1.$sessionId';

  static Future<PrefsGoalRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PrefsGoalRepository(prefs);
  }

  @override
  List<GoalEntry> load(String sessionId) {
    if (sessionId.isEmpty) return const <GoalEntry>[];
    final raw = _prefs.getString(keyFor(sessionId));
    if (raw == null || raw.isEmpty) return const <GoalEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <GoalEntry>[
          for (final item in decoded)
            if (item is Map<String, dynamic>) GoalEntry.fromJson(item),
        ];
      }
    } catch (_) {
      // Corrupted store: behave like an empty list, never crash.
    }
    return const <GoalEntry>[];
  }

  @override
  Future<void> save(String sessionId, List<GoalEntry> entries) async {
    if (sessionId.isEmpty) return;
    await _prefs.setString(
      keyFor(sessionId),
      jsonEncode(<Map<String, dynamic>>[
        for (final GoalEntry e in entries) e.toJson(),
      ]),
    );
  }
}

/// In-memory repository for unit and widget tests (per-session map).
class InMemoryGoalRepository implements GoalRepository {
  InMemoryGoalRepository([Map<String, List<GoalEntry>>? initial])
    : _bySession = initial ?? <String, List<GoalEntry>>{};

  final Map<String, List<GoalEntry>> _bySession;

  @override
  List<GoalEntry> load(String sessionId) =>
      List<GoalEntry>.of(_bySession[sessionId] ?? const <GoalEntry>[]);

  @override
  Future<void> save(String sessionId, List<GoalEntry> entries) async {
    _bySession[sessionId] = List<GoalEntry>.of(entries);
  }
}
