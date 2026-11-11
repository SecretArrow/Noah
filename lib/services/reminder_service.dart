import '../models/models.dart';
import 'reminder_repository.dart';

/// Reminder logic (v1.51.0), per chat: CRUD + due/overdue/upcoming
/// queries + pure repeat advancement. Completing a repeating reminder
/// advances it to its next occurrence instead of closing it.
class ReminderService {
  ReminderService(this._repo);

  final ReminderRepository _repo;

  List<ReminderEntry> list(String sessionId) {
    final List<ReminderEntry> entries = _repo.load(sessionId).toList();
    entries.sort((ReminderEntry a, ReminderEntry b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      return a.dueAt.compareTo(b.dueAt);
    });
    return entries;
  }

  Future<ReminderEntry?> create(
    String sessionId,
    String title, {
    String detail = '',
    required DateTime dueAt,
    ReminderRepeat repeat = ReminderRepeat.none,
  }) async {
    final String cleaned = title.trim();
    if (cleaned.isEmpty || sessionId.isEmpty) return null;
    final DateTime now = DateTime.now();
    final ReminderEntry entry = ReminderEntry(
      id: newId(),
      title: cleaned,
      detail: detail.trim(),
      dueAt: dueAt,
      repeat: repeat,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.save(sessionId, <ReminderEntry>[
      ..._repo.load(sessionId),
      entry,
    ]);
    return entry;
  }

  Future<ReminderEntry?> update(
    String sessionId,
    String id, {
    String? title,
    String? detail,
    DateTime? dueAt,
    ReminderRepeat? repeat,
    bool? done,
  }) async {
    ReminderEntry? updated;
    final List<ReminderEntry> next = <ReminderEntry>[
      for (final ReminderEntry e in _repo.load(sessionId))
        if (e.id == id)
          updated = e.copyWith(
            title: title?.trim(),
            detail: detail?.trim(),
            dueAt: dueAt,
            repeat: repeat,
            done: done,
            updatedAt: DateTime.now(),
          )
        else
          e,
    ];
    if (updated == null) return null;
    await _repo.save(sessionId, next);
    return updated;
  }

  /// Completes a reminder. Repeating reminders roll forward to the next
  /// occurrence after [now] and stay open; one-shot reminders close.
  Future<ReminderEntry?> complete(
    String sessionId,
    String id, {
    DateTime? now,
  }) async {
    final DateTime at = now ?? DateTime.now();
    ReminderEntry? result;
    final List<ReminderEntry> next = <ReminderEntry>[
      for (final ReminderEntry e in _repo.load(sessionId))
        if (e.id == id)
          result = e.repeat == ReminderRepeat.none
              ? e.copyWith(done: true, updatedAt: at)
              : e.copyWith(dueAt: e.nextOccurrence(at), updatedAt: at)
        else
          e,
    ];
    if (result == null) return null;
    await _repo.save(sessionId, next);
    return result;
  }

  Future<bool> remove(String sessionId, String id) async {
    final List<ReminderEntry> entries = _repo.load(sessionId);
    final List<ReminderEntry> next = entries
        .where((ReminderEntry e) => e.id != id)
        .toList();
    if (next.length == entries.length) return false;
    await _repo.save(sessionId, next);
    return true;
  }

  /// Open reminders already due (overdue + due within [window]).
  List<ReminderEntry> due(
    String sessionId,
    DateTime now, {
    Duration window = const Duration(hours: 24),
  }) {
    return list(sessionId)
        .where(
          (ReminderEntry e) => !e.done && e.dueAt.isBefore(now.add(window)),
        )
        .toList();
  }

  /// Next open reminder for this chat, if any.
  ReminderEntry? next(String sessionId) {
    final List<ReminderEntry> open = list(sessionId)
        .where((ReminderEntry e) => !e.done)
        .toList();
    return open.isEmpty ? null : open.first;
  }
}
