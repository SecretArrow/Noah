import '../models/cron_job.dart';
import 'cron_parser.dart';
import '../models/models.dart';
import 'cron_repository.dart';
import 'scheduled_job_repository.dart';

/// Migration of legacy v1.51.0 [ScheduledJob]s (once/daily/weekly/
/// interval kinds) into cron-expression [CronJob]s — Noah port
/// Fase 1.
///
/// Mapping (best effort, exactly as specified):
/// * daily   → `m h * * *`
/// * weekly  → `m h * * dow` (legacy weekday 1=Mon..7=Sun → cron 1..6,0)
/// * interval n (<60) → `*/n * * * *`; whole hours (n%60==0, ≤23 h)
///   → `0 */h * * *`; any other interval is NOT migratable.
/// * once    → NOT migratable (no one-shot in the cron model): the job
///   stays in the legacy store and keeps firing through the legacy
///   runner until it fires once — it never silently disappears.
///
/// Actions: notify → notification job; telegram → telegram job (empty
/// per-job token/chat id = the global Noah Telegram config is the
/// fallback at dispatch time); both → TWO cron jobs (one telegram, one
/// notification) so no channel is lost.
class CronLegacyMigration {
  CronLegacyMigration({required this.cronRepo, required this.legacyRepo});

  final CronRepository cronRepo;
  final ScheduledJobRepository legacyRepo;

  /// Converts one legacy job into 0..2 cron jobs. Empty result = not
  /// migratable (once / odd interval). Pure — unit-tested directly.
  static List<CronJob> convert(ScheduledJob job) {
    final String? expression = expressionFor(job);
    if (expression == null) return const <CronJob>[];
    CronJob base(CronActionKind action, String suffix) => CronJob(
      id: '${job.id}-cron$suffix',
      sessionId: job.sessionId,
      name: job.title,
      expression: expression,
      action: action,
      messageText: job.message,
      notifTitle: job.title,
      notifText: job.message,
      enabled: job.enabled,
      createdAtMs: job.createdAt.millisecondsSinceEpoch,
      lastRunAtMs: job.lastRunAt?.millisecondsSinceEpoch,
    );
    switch (job.action) {
      case JobAction.notify:
        return <CronJob>[base(CronActionKind.notification, '')];
      case JobAction.telegram:
        return <CronJob>[base(CronActionKind.telegram, '')];
      case JobAction.both:
        return <CronJob>[
          base(CronActionKind.telegram, '-tg'),
          base(CronActionKind.notification, '-nt'),
        ];
    }
  }

  /// The cron expression for a legacy job, or null when unmigratable.
  static String? expressionFor(ScheduledJob job) {
    switch (job.kind) {
      case JobScheduleKind.daily:
        return '${job.minute} ${job.hour} * * *';
      case JobScheduleKind.weekly:
        return '${job.minute} ${job.hour} * * ${job.weekday % 7}';
      case JobScheduleKind.interval:
        final int n = job.intervalMinutes;
        if (n >= 1 && n < 60 && 60 % n == 0) return '*/$n * * * *';
        if (n >= 60 && n % 60 == 0 && n ~/ 60 <= 23) {
          return '0 */${n ~/ 60} * * *';
        }
        return null;
      case JobScheduleKind.once:
        return null;
    }
  }

  /// Migrates every migratable legacy job of ONE chat. Converted jobs
  /// are removed from the legacy store (so the legacy runner cannot
  /// double-fire them) and the conversion is recorded in
  /// [CronState.migratedLegacyIds], making repeat passes no-ops.
  /// Returns how many legacy jobs were converted.
  Future<int> migrate(String sessionId) async {
    if (sessionId.isEmpty) return 0;
    CronState state = cronRepo.load(sessionId);
    final Set<String> done = state.migratedLegacyIds.toSet();
    final List<ScheduledJob> legacy = legacyRepo.load(sessionId);
    int migrated = 0;
    final List<CronJob> jobs = <CronJob>[...state.jobs];
    for (final ScheduledJob job in legacy) {
      if (done.contains(job.id)) continue;
      final List<CronJob> converted = convert(job);
      if (converted.isEmpty) continue; // stays legacy (once / odd interval)
      // Stamp the first next run now — a migrated job with a null
      // nextRunAtMs would never become due.
      final DateTime now = DateTime.now();
      for (final CronJob c in converted) {
        int? nextMs;
        try {
          nextMs = CronExpression.parse(c.expression)
              .nextAfter(now)
              ?.millisecondsSinceEpoch;
        } on CronFormatException {
          nextMs = null;
        }
        jobs.add(c.copyWith(nextRunAtMs: nextMs));
      }
      done.add(job.id);
      migrated++;
      await legacyRepo.save(
        sessionId,
        legacyRepo
            .load(sessionId)
            .where((ScheduledJob j) => j.id != job.id)
            .toList(),
      );
    }
    if (migrated > 0) {
      state = state.copyWith(jobs: jobs, migratedLegacyIds: done.toList());
      await cronRepo.save(sessionId, state);
    }
    return migrated;
  }
}
