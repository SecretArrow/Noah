import '../models/models.dart';
import 'scheduled_job_repository.dart';

/// Scheduled-job (cronjob) logic (v1.51.0, Fase F), per chat. All time
/// math is PURE and unit-tested: next-run computation for every kind,
/// due listing, and the post-fire transition (once → disabled,
/// repeating → advance). The engine that calls [dueJobs]/[markFired]
/// lives in the runner service; this class never fires side effects.
class ScheduledJobService {
  ScheduledJobService(this._repo);

  final ScheduledJobRepository _repo;

  /// Loose safety cap per chat (user emphasis: many jobs are fine).
  static const int maxJobsPerChat = 100;

  List<ScheduledJob> list(String sessionId) => _repo.load(sessionId);

  /// Computes the next fire time strictly after [from] for a job with
  /// the given schedule fields. Returns null only for a one-shot job
  /// whose time has passed (it is due NOW, handled by [dueJobs]).
  static DateTime? computeNextRun(ScheduledJob job, {required DateTime from}) {
    switch (job.kind) {
      case JobScheduleKind.once:
        final DateTime? at = job.runAt;
        if (at == null) return null;
        return at.isAfter(from) ? at : null;
      case JobScheduleKind.interval:
        final int step = job.intervalMinutes < 1 ? 1 : job.intervalMinutes;
        final DateTime anchor = job.lastRunAt ?? job.createdAt;
        DateTime t = anchor.add(Duration(minutes: step));
        while (!t.isAfter(from)) {
          t = t.add(Duration(minutes: step));
        }
        return t;
      case JobScheduleKind.daily:
        DateTime t = DateTime(
          from.year,
          from.month,
          from.day,
          job.hour,
          job.minute,
        );
        if (!t.isAfter(from)) t = t.add(const Duration(days: 1));
        return t;
      case JobScheduleKind.weekly:
        DateTime t = DateTime(
          from.year,
          from.month,
          from.day,
          job.hour,
          job.minute,
        );
        while (t.weekday != job.weekday || !t.isAfter(from)) {
          t = t.add(const Duration(days: 1));
        }
        return t;
    }
  }

  /// A job is due when it is enabled and its stored nextRunAt (or, for a
  /// fresh one-shot, its runAt) is at or before [now]. A fresh repeating
  /// job without nextRunAt is scheduled FROM now instead of firing
  /// immediately (no surprise catch-up storms on creation).
  static bool isDue(ScheduledJob job, DateTime now) {
    if (!job.enabled) return false;
    final DateTime? next =
        job.nextRunAt ?? (job.kind == JobScheduleKind.once ? job.runAt : null);
    return next != null && !next.isAfter(now);
  }

  /// ALL jobs of this chat that must fire at [now] (never just one).
  List<ScheduledJob> dueJobs(String sessionId, DateTime now) =>
      _repo.load(sessionId).where((ScheduledJob j) => isDue(j, now)).toList();

  /// The soonest upcoming fire across this chat's enabled jobs.
  ScheduledJob? nextUpcoming(String sessionId, DateTime now) {
    ScheduledJob? best;
    for (final ScheduledJob j in _repo.load(sessionId)) {
      if (!j.enabled) continue;
      final DateTime? next = j.nextRunAt ?? computeNextRun(j, from: now);
      if (next == null) continue;
      if (best == null ||
          next.isBefore(best.nextRunAt ?? computeNextRun(best, from: now)!)) {
        best = j.copyWith(nextRunAt: next);
      }
    }
    return best;
  }

  Future<ScheduledJob?> create(
    String sessionId, {
    required String title,
    String message = '',
    JobScheduleKind kind = JobScheduleKind.once,
    int hour = 9,
    int minute = 0,
    int weekday = 1,
    int intervalMinutes = 60,
    DateTime? runAt,
    JobAction action = JobAction.notify,
    DateTime? now,
  }) async {
    final String cleaned = title.trim();
    if (cleaned.isEmpty || sessionId.isEmpty) return null;
    final List<ScheduledJob> existing = _repo.load(sessionId);
    if (existing.length >= maxJobsPerChat) return null;
    final DateTime at = now ?? DateTime.now();
    ScheduledJob job = ScheduledJob(
      id: newId(),
      sessionId: sessionId,
      title: cleaned,
      message: message.trim(),
      kind: kind,
      hour: ScheduledJob.clampHour(hour),
      minute: ScheduledJob.clampMinute(minute),
      weekday: ScheduledJob.clampWeekday(weekday),
      intervalMinutes: ScheduledJob.clampInterval(intervalMinutes),
      runAt: runAt,
      action: action,
      createdAt: at,
      updatedAt: at,
    );
    job = job.copyWith(nextRunAt: computeNextRun(job, from: at));
    await _repo.save(sessionId, <ScheduledJob>[...existing, job]);
    return job;
  }

  Future<ScheduledJob?> update(
    String sessionId,
    String id, {
    String? title,
    String? message,
    JobScheduleKind? kind,
    int? hour,
    int? minute,
    int? weekday,
    int? intervalMinutes,
    DateTime? runAt,
    JobAction? action,
    bool? enabled,
    DateTime? now,
  }) async {
    final DateTime at = now ?? DateTime.now();
    ScheduledJob? updated;
    final List<ScheduledJob> next = <ScheduledJob>[
      for (final ScheduledJob j in _repo.load(sessionId))
        if (j.id == id)
          updated = j.copyWith(
            title: title?.trim(),
            message: message?.trim(),
            kind: kind,
            hour: hour == null ? null : ScheduledJob.clampHour(hour),
            minute: minute == null ? null : ScheduledJob.clampMinute(minute),
            weekday: weekday == null
                ? null
                : ScheduledJob.clampWeekday(weekday),
            intervalMinutes: intervalMinutes == null
                ? null
                : ScheduledJob.clampInterval(intervalMinutes),
            runAt: runAt,
            action: action,
            enabled: enabled,
            updatedAt: at,
          )
        else
          j,
    ];
    if (updated == null) return null;
    // Any schedule-affecting edit reschedules from now.
    updated = updated.copyWith(nextRunAt: computeNextRun(updated, from: at));
    final int idx = next.indexWhere((ScheduledJob j) => j.id == id);
    if (idx >= 0) next[idx] = updated;
    await _repo.save(sessionId, next);
    return updated;
  }

  Future<bool> remove(String sessionId, String id) async {
    final List<ScheduledJob> entries = _repo.load(sessionId);
    final List<ScheduledJob> next = entries
        .where((ScheduledJob j) => j.id != id)
        .toList();
    if (next.length == entries.length) return false;
    await _repo.save(sessionId, next);
    return true;
  }

  /// Post-fire transition: records the run + status, then once → disabled
  /// (nextRun cleared), repeating → advanced to its next occurrence.
  Future<ScheduledJob?> markFired(
    String sessionId,
    String id, {
    required DateTime firedAt,
    required String status,
  }) async {
    ScheduledJob? updated;
    final List<ScheduledJob> next = <ScheduledJob>[
      for (final ScheduledJob j in _repo.load(sessionId))
        if (j.id == id)
          updated = j.kind == JobScheduleKind.once
              ? j.copyWith(
                  enabled: false,
                  lastRunAt: firedAt,
                  lastStatus: status,
                  clearNextRunAt: true,
                  updatedAt: firedAt,
                )
              : j.copyWith(
                  lastRunAt: firedAt,
                  lastStatus: status,
                  nextRunAt: computeNextRun(
                    j.copyWith(lastRunAt: firedAt),
                    from: firedAt,
                  ),
                  updatedAt: firedAt,
                )
        else
          j,
    ];
    if (updated == null) return null;
    await _repo.save(sessionId, next);
    return updated;
  }
}
