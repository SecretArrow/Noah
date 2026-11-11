import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Abstraction over the persistent long-term memory storage (v1.50.0).
/// USER CORRECTION (v1.50.1): memory is scoped PER CHAT — every method
/// takes the owning session id and one chat can never see another
/// chat's entries (same isolation philosophy as files/browser/modules).
abstract class MemoryRepository {
  List<MemoryEntry> load(String sessionId);
  Future<void> save(String sessionId, List<MemoryEntry> entries);
}

/// SharedPreferences-backed store used in production. One key PER CHAT:
/// `noah.memory.v1.<sessionId>`. The short-lived global key from the
/// first v1.50.0 build is intentionally abandoned (never migrated into
/// any chat, so no data can leak across chats).
class PrefsMemoryRepository implements MemoryRepository {
  PrefsMemoryRepository(this._prefs);

  final SharedPreferences _prefs;

  static String keyFor(String sessionId) => 'noah.memory.v1.$sessionId';

  static Future<PrefsMemoryRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PrefsMemoryRepository(prefs);
  }

  @override
  List<MemoryEntry> load(String sessionId) {
    if (sessionId.isEmpty) return const <MemoryEntry>[];
    final raw = _prefs.getString(keyFor(sessionId));
    if (raw == null || raw.isEmpty) return const <MemoryEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <MemoryEntry>[
          for (final item in decoded)
            if (item is Map<String, dynamic>) MemoryEntry.fromJson(item),
        ];
      }
    } catch (_) {
      // Corrupted store: behave like an empty list, never crash.
    }
    return const <MemoryEntry>[];
  }

  @override
  Future<void> save(String sessionId, List<MemoryEntry> entries) async {
    if (sessionId.isEmpty) return;
    await _prefs.setString(
      keyFor(sessionId),
      jsonEncode(<Map<String, dynamic>>[
        for (final MemoryEntry e in entries) e.toJson(),
      ]),
    );
  }
}

/// In-memory repository for unit and widget tests (per-session map).
class InMemoryMemoryRepository implements MemoryRepository {
  InMemoryMemoryRepository([Map<String, List<MemoryEntry>>? initial])
    : _bySession = initial ?? <String, List<MemoryEntry>>{};

  final Map<String, List<MemoryEntry>> _bySession;

  @override
  List<MemoryEntry> load(String sessionId) =>
      List<MemoryEntry>.of(_bySession[sessionId] ?? const <MemoryEntry>[]);

  @override
  Future<void> save(String sessionId, List<MemoryEntry> entries) async {
    _bySession[sessionId] = List<MemoryEntry>.of(entries);
  }
}
