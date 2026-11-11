import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/cron_job.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/cron_migration.dart';
import 'package:noah/services/cron_repository.dart';
import 'package:noah/services/cron_scheduler.dart';
import 'package:noah/services/cron_tool_service.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/scheduled_job_repository.dart';
import 'package:noah/services/scheduled_job_service.dart';
import 'package:noah/services/telegram_sender.dart';
import 'package:noah/services/tool_executor.dart';

import '../support/test_doubles.dart';

class FakeDispatcher implements CronActionDispatcher {
  FakeDispatcher([
    this.result = const CronDispatchResult(ok: true, detail: 'sent'),
  ]);

  CronDispatchResult result;
  final List<CronJob> calls = <CronJob>[];

  @override
  Future<CronDispatchResult> dispatch(CronJob job) async {
    calls.add(job);
    return result;
  }
}

CronJob _job(
  String id, {
  String sessionId = 's1',
  String expression = '* * * * *',
  int? nextRunAtMs,
  bool enabled = true,
  CronActionKind action = CronActionKind.telegram,
}) => CronJob(
  id: id,
  name: 'Job $id',
  sessionId: sessionId,
  expression: expression,
  action: action,
  telegramToken: 'tok',
  telegramChatId: 'chat',
  messageText: 'm',
  enabled: enabled,
  createdAtMs: 0,
  nextRunAtMs: nextRunAtMs,
);

void main() {
  // Fixed anchor: Wednesday 2026-01-14 10:30 local.
  final DateTime now = DateTime(2026, 1, 14, 10, 30);

  group('CronSchedulerCore.dueJobs', () {
    test('returns enabled jobs whose nextRunAt is due', () {
      const CronSchedulerCore core = CronSchedulerCore();
      final CronState state = CronState(
        jobs: <CronJob>[
          _job('due', nextRunAtMs: now.millisecondsSinceEpoch - 1),
          _job('future', nextRunAtMs: now.millisecondsSinceEpoch + 60000),
          _job(
            'disabled',
            nextRunAtMs: now.millisecondsSinceEpoch - 1,
            enabled: false,
          ),
          _job('unscheduled', nextRunAtMs: null),
        ],
      );
      final List<CronJob> due = core.dueJobs(state, now);
      expect(due.map((j) => j.id), <String>['due']);
    });

    test('master switch off pauses everything without touching jobs', () {
      const CronSchedulerCore core = CronSchedulerCore();
      final CronState state = CronState(
        enabled: false,
        jobs: <CronJob>[_job('due', nextRunAtMs: now.millisecondsSinceEpoch)],
      );
      expect(core.dueJobs(state, now), isEmpty);
    });
  });

  group('CronSchedulerCore.rescheduleMissed', () {
    test('re-anchors past jobs WITHOUT firing them', () {
      const CronSchedulerCore core = CronSchedulerCore();
      final CronState state = CronState(
        jobs: <CronJob>[
          _job(
            'missed',
            expression: '0 8 * * *',
            nextRunAtMs: DateTime(2026, 1, 14, 8).millisecondsSinceEpoch,
          ),
        ],
      );
      final CronState? next = core.rescheduleMissed(state, now);
      expect(next, isNotNull);
      expect(
        next!.jobs.single.nextRunAtMs,
        DateTime(2026, 1, 15, 8).millisecondsSinceEpoch,
      );
    });

    test('future and disabled jobs are left untouched', () {
      const CronSchedulerCore core = CronSchedulerCore();
      final CronState state = CronState(
        jobs: <CronJob>[
          _job('future', nextRunAtMs: now.millisecondsSinceEpoch + 1),
          _job(
            'disabled',
            nextRunAtMs: now.millisecondsSinceEpoch - 1,
            enabled: false,
          ),
        ],
      );
      expect(core.rescheduleMissed(state, now), isNull);
    });

    test(
      'an invalid stored expression clears nextRunAt instead of crashing',
      () {
        const CronSchedulerCore core = CronSchedulerCore();
        final CronState state = CronState(
          jobs: <CronJob>[
            _job(
              'bad',
              expression: '99 * * * *',
              nextRunAtMs: now.millisecondsSinceEpoch - 1,
            ),
          ],
        );
        final CronState? next = core.rescheduleMissed(state, now);
        expect(next!.jobs.single.nextRunAtMs, isNull);
      },
    );
  });

  group('CronSchedulerService (per-chat families)', () {
    late ProviderContainer container;
    late MemoryCronRepository repo;
    late FakeDispatcher dispatcher;
    late CronSchedulerService scheduler;

    void boot({Map<String, CronState>? seed}) {
      repo = MemoryCronRepository(seed);
      container = ProviderContainer(
        overrides: <Override>[
          cronRepositoryProvider.overrideWithValue(repo),
          cronClockProvider.overrideWithValue(() => now),
        ],
      );
      dispatcher = FakeDispatcher();
      scheduler = CronSchedulerService(
        controllerFor: (String sid) =>
            container.read(cronJobsProvider(sid).notifier),
        stateFor: (String sid) => container.read(cronJobsProvider(sid)),
        sessionIds: () => container.read(cronKnownSessionsProvider),
        dispatcher: dispatcher,
        now: () => now,
      );
    }

    tearDown(() {
      scheduler.stop();
      container.dispose();
    });

    test(
      'tick fires a due job, records history and advances nextRun',
      () async {
        boot(
          seed: <String, CronState>{
            's1': CronState(
              jobs: <CronJob>[
                _job('a', nextRunAtMs: now.millisecondsSinceEpoch - 1),
              ],
            ),
          },
        );
        container.read(cronJobsProvider('s1')); // register s1 with the ticker

        await scheduler.tick();

        expect(dispatcher.calls, hasLength(1));
        final CronState state = repo.load('s1');
        expect(state.history, hasLength(1));
        expect(state.history.single.jobId, 'a');
        expect(state.history.single.ok, isTrue);
        expect(state.history.single.detail, 'sent');
        expect(
          state.jobs.single.nextRunAtMs,
          greaterThan(now.millisecondsSinceEpoch),
        );
        expect(state.jobs.single.lastResultOk, isTrue);
      },
    );

    test('a failed dispatch is recorded as a failure, not thrown', () async {
      boot(
        seed: <String, CronState>{
          's1': CronState(
            jobs: <CronJob>[
              _job('b', nextRunAtMs: now.millisecondsSinceEpoch - 1),
            ],
          ),
        },
      );
      dispatcher.result = const CronDispatchResult(
        ok: false,
        detail: 'HTTP 400: chat not found',
      );
      container.read(cronJobsProvider('s1')); // register s1 with the ticker

      await scheduler.tick();

      final CronState state = repo.load('s1');
      expect(state.history.single.ok, isFalse);
      expect(state.history.single.detail, contains('chat not found'));
      expect(state.jobs.single.lastResultOk, isFalse);
      expect(
        state.jobs.single.nextRunAtMs,
        greaterThan(now.millisecondsSinceEpoch),
      );
    });

    test('tick skips a chat whose master switch is off', () async {
      boot(
        seed: <String, CronState>{
          's1': CronState(
            enabled: false,
            jobs: <CronJob>[
              _job('c', nextRunAtMs: now.millisecondsSinceEpoch - 1),
            ],
          ),
        },
      );
      await scheduler.tick();
      expect(dispatcher.calls, isEmpty);
      expect(repo.load('s1').history, isEmpty);
    });

    test('jobs of one chat never fire from another chats pass', () async {
      boot(
        seed: <String, CronState>{
          's1': CronState(
            jobs: <CronJob>[
              _job('a', nextRunAtMs: now.millisecondsSinceEpoch - 1),
            ],
          ),
          's2': CronState(
            jobs: <CronJob>[
              _job(
                'b',
                sessionId: 's2',
                nextRunAtMs: now.millisecondsSinceEpoch - 1,
              ),
            ],
          ),
        },
      );
      container.read(cronJobsProvider('s1')); // register s1 only
      await scheduler.tick();
      expect(dispatcher.calls.map((j) => j.id), <String>['a']);
      expect(repo.load('s2').history, isEmpty);
    });

    test('start() applies missed-run recovery before ticking', () async {
      boot(
        seed: <String, CronState>{
          's1': CronState(
            jobs: <CronJob>[
              _job(
                'd',
                expression: '0 8 * * *',
                nextRunAtMs: DateTime(2026, 1, 14, 8).millisecondsSinceEpoch,
              ),
            ],
          ),
        },
      );
      container.read(cronJobsProvider('s1'));

      await scheduler.start();

      final CronState state = repo.load('s1');
      expect(
        state.jobs.single.nextRunAtMs,
        DateTime(2026, 1, 15, 8).millisecondsSinceEpoch,
      );
      expect(dispatcher.calls, isEmpty); // recovery never fires
      expect(scheduler.isRunning, isTrue);
    });

    test('runNow fires immediately and records history', () async {
      boot(
        seed: <String, CronState>{
          's1': CronState(jobs: <CronJob>[_job('e', expression: '0 0 * * *')]),
        },
      );
      container.read(cronJobsProvider('s1'));

      final CronDispatchResult result = await scheduler.runNow(
        repo.load('s1').jobs.single,
      );

      expect(result.ok, isTrue);
      expect(dispatcher.calls, hasLength(1));
      expect(repo.load('s1').history, hasLength(1));
    });

    test('controller families are isolated per chat', () async {
      boot();
      await container
          .read(cronJobsProvider('s1').notifier)
          .saveJob(_job('f', expression: '0 8 * * *'));
      expect(
        repo.load('s1').jobs.single.nextRunAtMs,
        DateTime(2026, 1, 15, 8).millisecondsSinceEpoch,
      );
      expect(container.read(cronJobsProvider('s2')).jobs, isEmpty);
      expect(repo.load('s2').jobs, isEmpty);
    });
  });

  group('DefaultCronDispatcher — chat action (Noah per-chat rule)', () {
    CronJob chatJob({String owner = 'owner-1', String target = ''}) => CronJob(
      id: 'chat-1',
      name: 'Chat job',
      sessionId: owner,
      expression: '0 9 * * *',
      action: CronActionKind.chat,
      agentPrompt: 'summarize the news',
      chatSessionId: target,
      createdAtMs: 0,
    );

    DefaultCronDispatcher dispatcher(
      Future<String?> Function(String sessionId, String prompt) runner,
    ) => DefaultCronDispatcher(
      llm: LlmClient(),
      telegram: TelegramSender(),
      background: RecordingBackgroundRun(),
      executeTool: (
        String name,
        Map<String, dynamic> args, {
        String? sessionId,
        String? browserContext,
      }) async => const ToolResult(ok: true, llmOutput: 'unused'),
      resolveConfig: () => const LlmConfig(
        baseUrl: 'https://example.invalid',
        apiKey: 'k',
        model: 'm',
      ),
      runInChat: runner,
    );

    test('an explicit target wins over the owner chat', () async {
      String? seenSession;
      String? seenPrompt;
      final CronDispatchResult result = await dispatcher((
        session,
        prompt,
      ) async {
        seenSession = session;
        seenPrompt = prompt;
        return null;
      }).dispatch(chatJob(target: 'session-42'));

      expect(result.ok, isTrue);
      expect(result.detail, 'prompt sent to chat');
      expect(seenSession, 'session-42');
      expect(seenPrompt, 'summarize the news');
    });

    test(
      'empty target defaults to the OWNING chat (never a new chat)',
      () async {
        String? seenSession;
        await dispatcher((session, prompt) async {
          seenSession = session;
          return null;
        }).dispatch(chatJob());

        expect(seenSession, 'owner-1');
      },
    );

    test('a refusal reason becomes a recorded failure detail', () async {
      final CronDispatchResult result = await dispatcher(
        (session, prompt) async => 'chat busy',
      ).dispatch(chatJob(target: 's1'));

      expect(result.ok, isFalse);
      expect(result.detail, 'chat busy');
    });

    test('a null runner fails the fire instead of crashing', () async {
      final CronDispatchResult result = await DefaultCronDispatcher(
        llm: LlmClient(),
        telegram: TelegramSender(),
        background: RecordingBackgroundRun(),
        executeTool: (
          String name,
          Map<String, dynamic> args, {
          String? sessionId,
          String? browserContext,
        }) async => const ToolResult(ok: true, llmOutput: 'unused'),
        resolveConfig: () => const LlmConfig(
          baseUrl: 'https://example.invalid',
          apiKey: 'k',
          model: 'm',
        ),
      ).dispatch(chatJob());

      expect(result.ok, isFalse);
      expect(result.detail, 'chat runner unavailable');
    });
  });

  group('CronLegacyMigration', () {
    ScheduledJob legacy({
      required String id,
      JobScheduleKind kind = JobScheduleKind.daily,
      JobAction action = JobAction.notify,
      int hour = 7,
      int minute = 30,
      int weekday = 1,
      int intervalMinutes = 60,
    }) => ScheduledJob(
      id: id,
      sessionId: 's1',
      title: 'Legacy $id',
      message: 'body $id',
      kind: kind,
      action: action,
      hour: hour,
      minute: minute,
      weekday: weekday,
      intervalMinutes: intervalMinutes,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    test('expression mapping', () {
      expect(CronLegacyMigration.expressionFor(legacy(id: 'a')), '30 7 * * *');
      expect(
        CronLegacyMigration.expressionFor(
          legacy(id: 'b', kind: JobScheduleKind.weekly, weekday: 7),
        ),
        '30 7 * * 0',
      );
      expect(
        CronLegacyMigration.expressionFor(
          legacy(id: 'c', kind: JobScheduleKind.interval, intervalMinutes: 15),
        ),
        '*/15 * * * *',
      );
      expect(
        CronLegacyMigration.expressionFor(
          legacy(id: 'd', kind: JobScheduleKind.interval, intervalMinutes: 120),
        ),
        '0 */2 * * *',
      );
      expect(
        CronLegacyMigration.expressionFor(
          legacy(id: 'e', kind: JobScheduleKind.once),
        ),
        isNull,
      );
      expect(
        CronLegacyMigration.expressionFor(
          legacy(id: 'f', kind: JobScheduleKind.interval, intervalMinutes: 90),
        ),
        isNull,
      );
    });

    test('migrate moves mappable jobs, keeps one-shots legacy, is '
        'idempotent and per-chat', () async {
      final MemoryCronRepository cronRepo = MemoryCronRepository();
      final InMemoryScheduledJobRepository legacyRepo =
          InMemoryScheduledJobRepository(<String, List<ScheduledJob>>{
            's1': <ScheduledJob>[
              legacy(id: 'daily1'),
              legacy(id: 'both1', action: JobAction.both),
              legacy(id: 'once1', kind: JobScheduleKind.once),
            ],
            's2': <ScheduledJob>[legacy(id: 'other')],
          });
      final CronLegacyMigration migration = CronLegacyMigration(
        cronRepo: cronRepo,
        legacyRepo: legacyRepo,
      );

      expect(await migration.migrate('s1'), 2); // daily + both (3 cron jobs)
      final List<CronJob> jobs = cronRepo.load('s1').jobs;
      expect(jobs, hasLength(3));
      expect(jobs.every((j) => j.sessionId == 's1'), isTrue);
      expect(
        jobs.map((j) => j.action).toSet(),
        containsAll(<CronActionKind>{
          CronActionKind.notification,
          CronActionKind.telegram,
        }),
      );
      // Only the one-shot remains in the legacy store of s1.
      expect(
        ScheduledJobService(legacyRepo).list('s1').map((j) => j.id),
        <String>['once1'],
      );
      // Other chats are untouched.
      expect(cronRepo.load('s2').jobs, isEmpty);
      expect(
        ScheduledJobService(legacyRepo).list('s2').map((j) => j.id),
        <String>['other'],
      );
      // Second pass moves nothing.
      expect(await migration.migrate('s1'), 0);
      expect(cronRepo.load('s1').jobs, hasLength(3));
    });
  });

  group('CronToolService', () {
    test('add/list/toggle/remove stay inside the owning chat', () async {
      final MemoryCronRepository repo = MemoryCronRepository();
      final CronToolService svc = CronToolService(repo, now: () => now);
      final CronJob? added = await svc.add(
        's1',
        CronJob(
          id: 't1',
          name: 'Tool job',
          expression: '0 8 * * *',
          action: CronActionKind.notification,
          createdAtMs: 0,
        ),
      );
      expect(added, isNotNull);
      expect(added!.sessionId, 's1');
      expect(
        added.nextRunAtMs,
        DateTime(2026, 1, 15, 8).millisecondsSinceEpoch,
      );
      expect(svc.list('s1'), hasLength(1));
      expect(svc.list('s2'), isEmpty);

      expect(await svc.setEnabled('s2', 't1', false), isFalse);
      expect(await svc.setEnabled('s1', 't1', false), isTrue);
      expect(svc.list('s1').single.enabled, isFalse);

      expect(await svc.remove('s2', 't1'), isFalse);
      expect(await svc.remove('s1', 't1'), isTrue);
      expect(svc.list('s1'), isEmpty);
    });
  });
}
