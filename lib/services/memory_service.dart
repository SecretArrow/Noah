import '../models/models.dart';
import 'memory_repository.dart';

/// Long-term memory logic (v1.50.0; PER-CHAT scope since v1.50.1 per
/// the user's correction — data never mixes between chats): add/edit/remove with near-duplicate
/// dedupe, token-overlap relevance search (pinned first), a hard entry
/// cap, and a bounded prompt summary. Pure logic over [MemoryRepository]
/// so it is fully unit-testable.
class MemoryService {
  MemoryService(this._repo);

  final MemoryRepository _repo;

  static const int maxEntries = 500;
  static const int promptMaxEntries = 8;
  static const int promptMaxChars = 1500;

  List<MemoryEntry> list(String sessionId) => _repo.load(sessionId);

  /// Normalizes text for dedupe/search: lowercase, collapsed whitespace.
  static String normalize(String text) =>
      text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  static Set<String> tokenize(String text) =>
      normalize(text)
          .split(RegExp(r'[^a-z0-9]+'))
          .where((String t) => t.length > 1)
          .toSet();

  /// Adds a memory. Returns the stored entry, the EXISTING entry when a
  /// near-duplicate (same normalized text) already exists, or null when
  /// the text is empty or the store is at [maxEntries].
  Future<MemoryEntry?> add(
    String sessionId,
    String text, {
    MemoryCategory category = MemoryCategory.fact,
    bool pinned = false,
  }) async {
    final String cleaned = MemoryEntry.clampText(text);
    if (cleaned.isEmpty) return null;
    final List<MemoryEntry> entries = _repo.load(sessionId);
    final String norm = normalize(cleaned);
    for (final MemoryEntry e in entries) {
      if (normalize(e.text) == norm) return e;
    }
    if (entries.length >= maxEntries) return null;
    final DateTime now = DateTime.now();
    final MemoryEntry entry = MemoryEntry(
      id: newId(),
      text: cleaned,
      category: category,
      pinned: pinned,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.save(sessionId, <MemoryEntry>[...entries, entry]);
    return entry;
  }

  Future<MemoryEntry?> update(
    String sessionId,
    String id, {
    String? text,
    MemoryCategory? category,
    bool? pinned,
  }) async {
    final List<MemoryEntry> entries = _repo.load(sessionId);
    MemoryEntry? updated;
    final List<MemoryEntry> next = <MemoryEntry>[
      for (final MemoryEntry e in entries)
        if (e.id == id)
          updated = e.copyWith(
            text: text == null ? null : MemoryEntry.clampText(text),
            category: category,
            pinned: pinned,
            updatedAt: DateTime.now(),
          )
        else
          e,
    ];
    if (updated == null) return null;
    await _repo.save(sessionId, next);
    return updated;
  }

  Future<bool> forget(String sessionId, String id) async {
    final List<MemoryEntry> entries = _repo.load(sessionId);
    final List<MemoryEntry> next = entries
        .where((MemoryEntry e) => e.id != id)
        .toList();
    if (next.length == entries.length) return false;
    await _repo.save(sessionId, next);
    return true;
  }

  /// Relevance score of [entry] for [queryTokens]: fraction of distinct
  /// query tokens present in the entry text (0 when the query is empty).
  static double score(MemoryEntry entry, Set<String> queryTokens) {
    if (queryTokens.isEmpty) return 0;
    final Set<String> entryTokens = tokenize(entry.text);
    final int hits = queryTokens.where(entryTokens.contains).length;
    return hits / queryTokens.length;
  }

  /// Search: pinned first, then relevance, then most recently updated.
  /// An empty query returns pinned + most recent entries.
  List<MemoryEntry> search(String sessionId, String query, {int limit = 20}) {
    final List<MemoryEntry> entries = _repo.load(sessionId);
    final Set<String> q = tokenize(query);
    final List<MemoryEntry> ranked = entries.toList();
    ranked.sort((MemoryEntry a, MemoryEntry b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final double sa = score(a, q);
      final double sb = score(b, q);
      if (sa != sb) return sb.compareTo(sa);
      return b.updatedAt.compareTo(a.updatedAt);
    });
    if (q.isEmpty) return ranked.take(limit).toList();
    return ranked
        .where((MemoryEntry e) => e.pinned || score(e, q) > 0)
        .take(limit)
        .toList();
  }

  /// Bounded block for the system prompt: pinned entries plus the top
  /// search hits for [lastUserText]. Empty string when there is nothing
  /// worth injecting — callers then change NOTHING (legacy behavior).
  String promptSummary(String sessionId, String lastUserText) {
    final List<MemoryEntry> all = _repo.load(sessionId);
    if (all.isEmpty) return '';
    final List<MemoryEntry> picked = <MemoryEntry>[];
    final Set<String> seen = <String>{};
    for (final MemoryEntry e in search(
      sessionId,
      lastUserText,
      limit: promptMaxEntries,
    )) {
      if (seen.add(e.id)) picked.add(e);
    }
    final StringBuffer out = StringBuffer();
    for (final MemoryEntry e in picked.take(promptMaxEntries)) {
      final String line =
          '- [${e.category.name}]${e.pinned ? ' (pinned)' : ''} ${e.text}';
      if (out.length + line.length + 1 > promptMaxChars) break;
      if (out.isNotEmpty) out.writeln();
      out.write(line);
    }
    return out.toString();
  }
}
