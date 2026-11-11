import '../models/cron_job.dart';
import 'cron_parser.dart';
import 'cron_repository.dart';

/// Repository-level cron operations behind the `cron_*` agent tools
/// (port Fase 1). Works directly on the per-session [CronRepository]
/// (no Riverpod), so the tool executor can create/list/toggle/delete
/// cron jobs for the CALLING chat only. Next-run computation mirrors
/// [CronJobsController.saveJob]: an invalid expression yields a null
/// next run (the job exists but never fires).
class CronToolService {
  CronToolService(this._repo, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final CronRepository _repo;
  final DateTime Function() _now;

  List<CronJob> list(String sessionId) => _repo.load(sessionId).jobs;

  CronState state(String sessionId) => _repo.load(sessionId);

  /// Adds [job] (owner forced to [sessionId]); returns the stored job
  /// with its computed next run, or null when the session is empty.
  Future<CronJob?> add(String sessionId, CronJob job) async {
    if (sessionId.isEmpty) return null;
    int? nextMs;
    try {
      nextMs = CronExpression.parse(job.expression)
          .nextAfter(_now())
          ?.millisecondsSinceEpoch;
    } on CronFormatException {
      nextMs = null;
    }
    final CronJob stamped = job.copyWith(
      sessionId: sessionId,
      nextRunAtMs: nextMs,
    );
    final CronState state = _repo.load(sessionId);
    await _repo.save(sessionId, state.copyWith(jobs: [...state.jobs, stamped]));
    return stamped;
  }

  Future<bool> setEnabled(String sessionId, String id, bool enabled) async {
    final CronState state = _repo.load(sessionId);
    bool found = false;
    final List<CronJob> jobs = <CronJob>[];
    for (final CronJob j in state.jobs) {
      if (j.id != id) {
        jobs.add(j);
        continue;
      }
      found = true;
      int? nextMs = j.nextRunAtMs;
      if (enabled) {
        try {
          nextMs = CronExpression.parse(j.expression)
              .nextAfter(_now())
              ?.millisecondsSinceEpoch;
        } on CronFormatException {
          nextMs = null;
        }
      }
      jobs.add(j.copyWith(enabled: enabled, nextRunAtMs: nextMs));
    }
    if (!found) return false;
    await _repo.save(sessionId, state.copyWith(jobs: jobs));
    return true;
  }

  Future<bool> remove(String sessionId, String id) async {
    final CronState state = _repo.load(sessionId);
    if (!state.jobs.any((j) => j.id == id)) return false;
    await _repo.save(
      sessionId,
      state.copyWith(
        jobs: [
          for (final j in state.jobs)
            if (j.id != id) j,
        ],
        history: [
          for (final h in state.history)
            if (h.jobId != id) h,
        ],
      ),
    );
    return true;
  }
}
