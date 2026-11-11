import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Per-chat reminder storage (v1.51.0): key `noah.reminders.v1.<sid>`.
abstract class ReminderRepository {
  List<ReminderEntry> load(String sessionId);
  Future<void> save(String sessionId, List<ReminderEntry> entries);
}

class PrefsReminderRepository implements ReminderRepository {
  PrefsReminderRepository(this._prefs);

  final SharedPreferences _prefs;

  static String keyFor(String sessionId) => 'noah.reminders.v1.$sessionId';

  static Future<PrefsReminderRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PrefsReminderRepository(prefs);
  }

  @override
  List<ReminderEntry> load(String sessionId) {
    if (sessionId.isEmpty) return const <ReminderEntry>[];
    final raw = _prefs.getString(keyFor(sessionId));
    if (raw == null || raw.isEmpty) return const <ReminderEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <ReminderEntry>[
          for (final item in decoded)
            if (item is Map<String, dynamic>) ReminderEntry.fromJson(item),
        ];
      }
    } catch (_) {
      // Corrupted store: behave like an empty list, never crash.
    }
    return const <ReminderEntry>[];
  }

  @override
  Future<void> save(String sessionId, List<ReminderEntry> entries) async {
    if (sessionId.isEmpty) return;
    await _prefs.setString(
      keyFor(sessionId),
      jsonEncode(<Map<String, dynamic>>[
        for (final ReminderEntry e in entries) e.toJson(),
      ]),
    );
  }
}

/// In-memory repository for tests (per-session map).
class InMemoryReminderRepository implements ReminderRepository {
  InMemoryReminderRepository([Map<String, List<ReminderEntry>>? initial])
    : _bySession = initial ?? <String, List<ReminderEntry>>{};

  final Map<String, List<ReminderEntry>> _bySession;

  @override
  List<ReminderEntry> load(String sessionId) =>
      List<ReminderEntry>.of(_bySession[sessionId] ?? const <ReminderEntry>[]);

  @override
  Future<void> save(String sessionId, List<ReminderEntry> entries) async {
    _bySession[sessionId] = List<ReminderEntry>.of(entries);
  }
}
