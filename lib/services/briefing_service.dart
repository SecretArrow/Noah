import '../models/models.dart';
import 'goal_service.dart';
import 'memory_service.dart';
import 'reminder_service.dart';
import '../models/cron_job.dart';
import 'cron_repository.dart';
import 'scheduled_job_service.dart';

/// Aggregated briefing for ONE chat (v1.51.0, Fase E/F): the personal-
/// agent greeting card — this chat's active goals, due reminders, next
/// scheduled job and pinned memories. Pure aggregation over the other
/// per-chat services, unit-testable without any UI.
class BriefingData {
  const BriefingData({
    required this.goals,
    required this.dueReminders,
    required this.nextJob,
    required this.pinnedMemories,
    this.nextCronJob,
  });

  final List<GoalEntry> goals;
  final List<ReminderEntry> dueReminders;
  final ScheduledJob? nextJob;
  final List<MemoryEntry> pinnedMemories;

  /// Earliest upcoming fire of the NEW cron engine (Fase 5) — legacy
  /// [nextJob] only covers the unmigratable once/odd-interval jobs.
  final CronJob? nextCronJob;

  bool get isEmpty =>
      goals.isEmpty &&
      dueReminders.isEmpty &&
      nextJob == null &&
      nextCronJob == null &&
      pinnedMemories.isEmpty;
}

class BriefingService {
  BriefingService({
    required this.goals,
    required this.reminders,
    required this.memory,
    required this.jobs,
    this.cron,
  });

  final GoalService goals;
  final ReminderService reminders;
  final MemoryService memory;
  final ScheduledJobService jobs;

  /// New cron engine store (optional — briefings built without it just
  /// skip the cron next-fire line).
  final CronRepository? cron;

  BriefingData build(String sessionId, {DateTime? now}) {
    final DateTime at = now ?? DateTime.now();
    return BriefingData(
      goals: goals.active(sessionId),
      dueReminders: reminders.due(sessionId, at),
      nextJob: jobs.nextUpcoming(sessionId, at),
      nextCronJob: _nextCron(sessionId),
      pinnedMemories: memory
          .list(sessionId)
          .where((MemoryEntry e) => e.pinned)
          .toList(),
    );
  }

  /// Earliest enabled cron job of THIS chat by stamped next run.
  CronJob? _nextCron(String sessionId) {
    final CronRepository? repo = cron;
    if (repo == null) return null;
    CronJob? best;
    for (final CronJob job in repo.load(sessionId).jobs) {
      if (!job.enabled || job.nextRunAtMs == null) continue;
      if (best == null || job.nextRunAtMs! < best.nextRunAtMs!) best = job;
    }
    return best;
  }
}
