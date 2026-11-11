import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Default context entries seeded on first launch. They are DISABLED by
/// default so upgrading users see no behavior change; the Context Manager
/// lets them edit, enable or delete everything.
List<ContextEntry> defaultContextEntries() => <ContextEntry>[
  ContextEntry(
    id: 'ctx-assistant-style',
    name: 'Assistant style',
    content:
        'Answer concisely and use Markdown headings and bullet lists '
        'when the response is longer than a few sentences.',
  ),
  ContextEntry(
    id: 'ctx-language-id',
    name: 'Always answer in Bahasa Indonesia',
    content:
        'Always respond in Bahasa Indonesia regardless of the language '
        'the user writes in.',
  ),
];

/// Abstraction over the persistent Context Manager storage.
abstract class ContextRepository {
  List<ContextEntry> load();
  Future<void> save(List<ContextEntry> entries);
}

/// SharedPreferences-backed store used in production. Entries are kept in a
/// dedicated key so large prompt blocks never bloat the settings blob.
class PrefsContextRepository implements ContextRepository {
  PrefsContextRepository(this._prefs);

  final SharedPreferences _prefs;
  static const String _key = 'zagents.contexts.v1';
  static const String _seededKey = 'zagents.contexts.seeded';

  static Future<PrefsContextRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PrefsContextRepository(prefs);
  }

  @override
  List<ContextEntry> load() {
    // First run: seed the default entries (disabled).
    if (!(_prefs.getBool(_seededKey) ?? false)) {
      return defaultContextEntries();
    }
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const <ContextEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <ContextEntry>[
          for (final item in decoded)
            if (item is Map<String, dynamic>) ContextEntry.fromJson(item),
        ];
      }
    } catch (_) {
      // Corrupted store: behave like an empty list, never crash.
    }
    return const <ContextEntry>[];
  }

  @override
  Future<void> save(List<ContextEntry> entries) async {
    await _prefs.setString(
      _key,
      jsonEncode(<Map<String, dynamic>>[
        for (final ContextEntry e in entries) e.toJson(),
      ]),
    );
    await _prefs.setBool(_seededKey, true);
  }
}

/// In-memory repository for unit and widget tests.
class MemoryContextRepository implements ContextRepository {
  MemoryContextRepository([List<ContextEntry>? initial])
    : _entries = initial ?? defaultContextEntries();

  List<ContextEntry> _entries;

  @override
  List<ContextEntry> load() => _entries;

  @override
  Future<void> save(List<ContextEntry> entries) async {
    _entries = List<ContextEntry>.of(entries);
  }
}
