import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/cron_job.dart';
import 'package:noah/services/cron_repository.dart';

/// Port Fase 1 — per-session cron repository: Noah keeps cron data
/// isolated per chat (the user's rule), so every test here keys state
/// by session id and asserts one chat can never see another's jobs.
void main() {
  CronJob job(String id, {String sessionId = 's1', String name = 'Job'}) {
    return CronJob(
      id: id,
      name: name,
      sessionId: sessionId,
      expression: '0 9 * * *',
      action: CronActionKind.notification,
      createdAtMs: 1000,
    );
  }

  group('MemoryCronRepository', () {
    test('load of an unknown session is empty', () {
      final CronState state = MemoryCronRepository().load('nope');
      expect(state.jobs, isEmpty);
      expect(state.enabled, isTrue);
      expect(state.history, isEmpty);
    });

    test('round-trip per session', () async {
      final MemoryCronRepository repo = MemoryCronRepository();
      await repo.save(
        's1',
        CronState(jobs: <CronJob>[job('a')], enabled: false),
      );
      final CronState loaded = repo.load('s1');
      expect(loaded.jobs.single.id, 'a');
      expect(loaded.enabled, isFalse);
    });

    test('sessions are isolated from each other', () async {
      final MemoryCronRepository repo = MemoryCronRepository();
      await repo.save('s1', CronState(jobs: <CronJob>[job('a')]));
      await repo.save(
        's2',
        CronState(jobs: <CronJob>[job('b', sessionId: 's2')]),
      );
      expect(repo.load('s1').jobs.single.id, 'a');
      expect(repo.load('s2').jobs.single.id, 'b');
      expect(repo.load('s3').jobs, isEmpty);
    });

    test('empty session id never reads or writes', () async {
      final MemoryCronRepository repo = MemoryCronRepository();
      await repo.save('', CronState(jobs: <CronJob>[job('a')]));
      expect(repo.load('').jobs, isEmpty);
    });

    test('round trip via toJson/fromJson keeps the new fields', () {
      final CronState state = CronState(
        jobs: <CronJob>[job('a')],
        migratedLegacyIds: const <String>['legacy-1'],
        history: <CronRunEntry>[
          CronRunEntry(
            jobId: 'a',
            jobName: 'Job',
            atMs: 5,
            ok: true,
            detail: 'ran',
          ),
        ],
      );
      final CronState back = CronState.fromJson(state.toJson());
      expect(back.jobs.single.sessionId, 's1');
      expect(back.migratedLegacyIds, <String>['legacy-1']);
      expect(back.history.single.detail, 'ran');
    });
  });

  group('PrefsCronRepository key contract', () {
    test('storage key is scoped by session id', () {
      expect(PrefsCronRepository.keyFor('abc'), 'noah.cronjobs.v1.abc');
    });
  });
}
