import '../models/models.dart';
import 'goal_repository.dart';

/// Goals logic (v1.50.0): CRUD plus due-date reasoning and a bounded
/// prompt summary of ACTIVE goals. Pure logic over [GoalRepository].
class GoalService {
  GoalService(this._repo);

  final GoalRepository _repo;

  static const int promptMaxGoals = 5;

  List<GoalEntry> list(String sessionId) => _repo.load(sessionId);

  List<GoalEntry> active(String sessionId) => _repo
      .load(sessionId)
      .where((GoalEntry g) => g.status == GoalStatus.active)
      .toList();

  Future<GoalEntry?> create(
    String sessionId,
    String title, {
    String detail = '',
    DateTime? dueDate,
    int progress = 0,
  }) async {
    final String cleaned = title.trim();
    if (cleaned.isEmpty) return null;
    final DateTime now = DateTime.now();
    final GoalEntry goal = GoalEntry(
      id: newId(),
      title: cleaned,
      detail: detail.trim(),
      progress: GoalEntry.clampProgress(progress),
      dueDate: dueDate,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.save(sessionId, <GoalEntry>[..._repo.load(sessionId), goal]);
    return goal;
  }

  Future<GoalEntry?> update(
    String sessionId,
    String id, {
    String? title,
    String? detail,
    GoalStatus? status,
    int? progress,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    GoalEntry? updated;
    final List<GoalEntry> next = <GoalEntry>[
      for (final GoalEntry g in _repo.load(sessionId))
        if (g.id == id)
          updated = g.copyWith(
            title: title?.trim(),
            detail: detail?.trim(),
            status: status,
            progress: progress == null
                ? null
                : GoalEntry.clampProgress(progress),
            dueDate: dueDate,
            clearDueDate: clearDueDate,
            updatedAt: DateTime.now(),
          )
        else
          g,
    ];
    if (updated == null) return null;
    // Completing a goal pins its progress at 100.
    if (updated.status == GoalStatus.done && updated.progress != 100) {
      updated = updated.copyWith(progress: 100);
      final int idx = next.indexWhere((GoalEntry g) => g.id == id);
      if (idx >= 0) next[idx] = updated;
    }
    await _repo.save(sessionId, next);
    return updated;
  }

  Future<GoalEntry?> complete(String sessionId, String id) =>
      update(sessionId, id, status: GoalStatus.done, progress: 100);

  Future<bool> remove(String sessionId, String id) async {
    final List<GoalEntry> entries = _repo.load(sessionId);
    final List<GoalEntry> next = entries
        .where((GoalEntry g) => g.id != id)
        .toList();
    if (next.length == entries.length) return false;
    await _repo.save(sessionId, next);
    return true;
  }

  /// Bounded block for the system prompt: up to [promptMaxGoals] active
  /// goals, overdue first, then nearest due date. Empty when no active
  /// goals exist — callers then change NOTHING (legacy behavior).
  String promptSummary(String sessionId, {DateTime? now}) {
    final DateTime at = now ?? DateTime.now();
    final List<GoalEntry> goals = active(sessionId);
    if (goals.isEmpty) return '';
    goals.sort((GoalEntry a, GoalEntry b) {
      final bool ao = a.isOverdue(at);
      final bool bo = b.isOverdue(at);
      if (ao != bo) return ao ? -1 : 1;
      if (a.dueDate == null && b.dueDate == null) {
        return b.updatedAt.compareTo(a.updatedAt);
      }
      if (a.dueDate == null) return 1;
      if (b.dueDate == null) return -1;
      return a.dueDate!.compareTo(b.dueDate!);
    });
    final StringBuffer out = StringBuffer();
    for (final GoalEntry g in goals.take(promptMaxGoals)) {
      final String due = g.dueDate == null
          ? ''
          : g.isOverdue(at)
          ? ' — OVERDUE (due ${g.dueDate!.toIso8601String().substring(0, 10)})'
          : g.isDueSoon(at)
          ? ' — due soon (${g.dueDate!.toIso8601String().substring(0, 10)})'
          : ' — due ${g.dueDate!.toIso8601String().substring(0, 10)}';
      if (out.isNotEmpty) out.writeln();
      out.write('- ${g.title} (${g.progress}%)$due');
    }
    return out.toString();
  }
}
