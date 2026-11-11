import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:noah/models/models.dart';
import 'package:noah/services/briefing_service.dart';
import 'package:noah/models/cron_job.dart';
import 'package:noah/services/cron_repository.dart';
import 'package:noah/services/goal_repository.dart';
import 'package:noah/services/goal_service.dart';
import 'package:noah/services/html_export.dart';
import 'package:noah/services/memory_repository.dart';
import 'package:noah/services/memory_service.dart';
import 'package:noah/services/reminder_repository.dart';
import 'package:noah/services/reminder_service.dart';
import 'package:noah/services/scheduled_job_repository.dart';
import 'package:noah/services/scheduled_job_runner.dart';
import 'package:noah/services/scheduled_job_service.dart';
import 'package:noah/services/skill_registry.dart';
import 'package:noah/services/telegram_sender.dart';
import 'package:noah/services/tool_executor.dart';
import 'package:noah/tools/tool_defs.dart';

import '../support/test_doubles.dart';

/// Fase E/F (v1.51.0): reminders, cron jobs (multi-job!), Telegram
/// payload, briefing aggregation, HTML export, and per-chat isolation
/// for every new store — the user's "data must never mix" rule.
void main() {
  group('reminders', () {
    test('repeat rolls to the next occurrence', () {
      ReminderEntry entry(ReminderRepeat repeat) => ReminderEntry(
        id: 'x',
        title: 'x',
        dueAt: DateTime(2026, 1, 1, 9),
        repeat: repeat,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      expect(
        entry(ReminderRepeat.daily).nextOccurrence(DateTime(2026, 1, 3, 10)),
        DateTime(2026, 1, 4, 9),
      );
      expect(
        entry(ReminderRepeat.weekly).nextOccurrence(DateTime(2026, 1, 2, 10)),
        DateTime(2026, 1, 8, 9),
      );
      expect(
        entry(ReminderRepeat.none).nextOccurrence(DateTime(2026, 1, 2, 10)),
        DateTime(2026, 1, 1, 9),
      );
    });

    test('create/list/complete + per-chat isolation', () async {
      final ReminderService svc = ReminderService(InMemoryReminderRepository());
      final ReminderEntry? a = await svc.create(
        'chat-a',
        'Pay rent',
        dueAt: DateTime.now().add(const Duration(hours: 2)),
        repeat: ReminderRepeat.daily,
      );
      expect(a, isNotNull);
      expect(svc.list('chat-b'), isEmpty, reason: 'chat B must not see chat A');
      final ReminderEntry? rolled = await svc.complete('chat-a', a!.id);
      expect(rolled, isNotNull);
      expect(rolled!.done, isFalse, reason: 'repeating rolls forward');
      expect(rolled.dueAt.isAfter(DateTime.now()), isTrue);
      final ReminderEntry? once = await svc.create(
        'chat-a',
        'One-off',
        dueAt: DateTime.now().add(const Duration(hours: 1)),
      );
      final ReminderEntry? done = await svc.complete('chat-a', once!.id);
      expect(done!.done, isTrue);
    });

    test('prefs repository round-trip is per-chat keyed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final PrefsReminderRepository repo =
          await PrefsReminderRepository.create();
      await repo.save('chat-a', <ReminderEntry>[
        ReminderEntry(
          id: 'r1',
          title: 'A',
          dueAt: DateTime(2026, 1, 1),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ]);
      expect(repo.load('chat-a').single.title, 'A');
      expect(repo.load('chat-b'), isEmpty);
    });
  });

  group('scheduled jobs — pure scheduling', () {
    final DateTime t0 = DateTime(2026, 3, 2, 8); // Monday 08:00

    ScheduledJob job({
      JobScheduleKind kind = JobScheduleKind.daily,
      int hour = 9,
      int minute = 30,
      int weekday = 1,
      int interval = 45,
      DateTime? runAt,
      bool enabled = true,
      DateTime? lastRunAt,
      DateTime? nextRunAt,
    }) => ScheduledJob(
      id: 'j',
      sessionId: 'chat-a',
      title: 't',
      message: 'm',
      kind: kind,
      hour: hour,
      minute: minute,
      weekday: weekday,
      intervalMinutes: interval,
      runAt: runAt,
      enabled: enabled,
      lastRunAt: lastRunAt,
      nextRunAt: nextRunAt,
      createdAt: t0,
      updatedAt: t0,
    );

    test('daily: later today, else tomorrow', () {
      expect(
        ScheduledJobService.computeNextRun(job(), from: t0),
        DateTime(2026, 3, 2, 9, 30),
      );
      expect(
        ScheduledJobService.computeNextRun(
          job(),
          from: DateTime(2026, 3, 2, 10),
        ),
        DateTime(2026, 3, 3, 9, 30),
      );
    });

    test('weekly: advances to the matching weekday', () {
      expect(
        ScheduledJobService.computeNextRun(
          job(kind: JobScheduleKind.weekly, weekday: 3),
          from: t0,
        ),
        DateTime(2026, 3, 4, 9, 30),
      );
      expect(
        ScheduledJobService.computeNextRun(
          job(kind: JobScheduleKind.weekly, weekday: 1),
          from: t0,
        ),
        DateTime(2026, 3, 2, 9, 30),
      );
    });

    test('once: future runAt only', () {
      expect(
        ScheduledJobService.computeNextRun(
          job(kind: JobScheduleKind.once, runAt: DateTime(2026, 3, 5)),
          from: t0,
        ),
        DateTime(2026, 3, 5),
      );
      expect(
        ScheduledJobService.computeNextRun(
          job(kind: JobScheduleKind.once, runAt: DateTime(2026, 3, 1)),
          from: t0,
        ),
        isNull,
      );
    });

    test('interval: steps from the anchor until after from', () {
      expect(
        ScheduledJobService.computeNextRun(
          job(kind: JobScheduleKind.interval),
          from: DateTime(2026, 3, 2, 8, 50),
        ),
        DateTime(2026, 3, 2, 9, 30),
      );
    });

    test('disabled jobs are never due; fresh repeating job is not due', () {
      expect(
        ScheduledJobService.isDue(job(enabled: false, nextRunAt: t0), t0),
        isFalse,
      );
      expect(ScheduledJobService.isDue(job(), t0), isFalse);
      expect(ScheduledJobService.isDue(job(nextRunAt: t0), t0), isTrue);
    });
  });

  group('scheduled jobs — multi-job behaviour', () {
    test('10 jobs in one chat all list; cap and isolation hold', () async {
      final ScheduledJobService svc = ScheduledJobService(
        InMemoryScheduledJobRepository(),
      );
      for (int i = 0; i < 10; i++) {
        final ScheduledJob? j = await svc.create(
          'chat-a',
          title: 'Job $i',
          message: 'm$i',
          kind: JobScheduleKind.daily,
        );
        expect(j, isNotNull);
      }
      expect(svc.list('chat-a'), hasLength(10));
      expect(svc.list('chat-b'), isEmpty, reason: 'jobs never leak chats');
    });

    test(
      'several jobs due at once all fire; one failure stops nothing',
      () async {
        final InMemoryScheduledJobRepository repo =
            InMemoryScheduledJobRepository();
        final ScheduledJobService svc = ScheduledJobService(repo);
        final DateTime past = DateTime.now().subtract(const Duration(hours: 1));
        for (int i = 0; i < 3; i++) {
          await repo.save('chat-a', <ScheduledJob>[
            ...repo.load('chat-a'),
            ScheduledJob(
              id: 'due-$i',
              sessionId: 'chat-a',
              title: 'Due $i',
              message: 'boom $i',
              kind: JobScheduleKind.once,
              runAt: past,
              nextRunAt: past,
              createdAt: past,
              updatedAt: past,
            ),
          ]);
        }
        final RecordingBackgroundRun recording = RecordingBackgroundRun();
        final ScheduledJobRunner runner = ScheduledJobRunner(
          jobs: svc,
          notifications: recording,
          telegram: TelegramSender(),
          configStore: MemoryTelegramConfigStore(),
          listSessionIds: () async => <String>['chat-a', 'chat-b'],
        );
        await runner.checkAll();
        expect(
          recording.doneNotifications,
          hasLength(3),
          reason: 'ALL due jobs fire',
        );
        final List<ScheduledJob> after = svc.list('chat-a');
        expect(
          after.every((ScheduledJob j) => !j.enabled),
          isTrue,
          reason: 'once jobs disable after firing',
        );
        expect(after.every((ScheduledJob j) => j.lastStatus == 'ok'), isTrue);
      },
    );

    test('telegram failure still notifies on action=both', () async {
      final InMemoryScheduledJobRepository repo =
          InMemoryScheduledJobRepository();
      final ScheduledJobService svc = ScheduledJobService(repo);
      final DateTime past = DateTime.now().subtract(const Duration(hours: 1));
      await repo.save('chat-a', <ScheduledJob>[
        ScheduledJob(
          id: 'both-1',
          sessionId: 'chat-a',
          title: 'Both',
          message: 'hello',
          kind: JobScheduleKind.once,
          action: JobAction.both,
          runAt: past,
          nextRunAt: past,
          createdAt: past,
          updatedAt: past,
        ),
      ]);
      final RecordingBackgroundRun recording = RecordingBackgroundRun();
      final ScheduledJobRunner runner = ScheduledJobRunner(
        jobs: svc,
        notifications: recording,
        telegram: TelegramSender(),
        // No token configured -> telegram errors, notify must still run.
        configStore: MemoryTelegramConfigStore(),
        listSessionIds: () async => <String>['chat-a'],
      );
      await runner.checkAll();
      expect(recording.doneNotifications, hasLength(1));
      expect(svc.list('chat-a').single.lastStatus, startsWith('error'));
    });
  });

  group('telegram payload & parsing (pure)', () {
    test('payload shape + 4096 clamp', () {
      final Map<String, Object?> p = buildSendMessagePayload(
        chatId: ' 42 ',
        text: 'x' * 5000,
      );
      expect(p['chat_id'], '42');
      expect((p['text']! as String).length, 4096);
    });

    test('response parsing', () {
      expect(parseTelegramResponse(200, '{"ok":true}').ok, isTrue);
      final TelegramResult bad = parseTelegramResponse(
        401,
        '{"ok":false,"description":"Unauthorized"}',
      );
      expect(bad.ok, isFalse);
      expect(bad.message, contains('Unauthorized'));
      expect(parseTelegramResponse(500, 'garbage').ok, isFalse);
    });
  });

  group('briefing aggregation (per chat)', () {
    test('collects goals, due reminders, next job, pinned memories', () async {
      final MemoryService mem = MemoryService(InMemoryMemoryRepository());
      await mem.add(
        'chat-a',
        'Pinned fact',
        category: MemoryCategory.fact,
        pinned: true,
      );
      await mem.add('chat-b', 'Other chat pinned', pinned: true);
      final GoalService goals = GoalService(InMemoryGoalRepository());
      await goals.create('chat-a', 'Ship it');
      final ReminderService reminders = ReminderService(
        InMemoryReminderRepository(),
      );
      await reminders.create(
        'chat-a',
        'Due soon',
        dueAt: DateTime.now().add(const Duration(hours: 1)),
      );
      final ScheduledJobService jobs = ScheduledJobService(
        InMemoryScheduledJobRepository(),
      );
      await jobs.create(
        'chat-a',
        title: 'Morning ping',
        message: 'hi',
        kind: JobScheduleKind.daily,
      );
      final MemoryCronRepository cronRepo = MemoryCronRepository(
        <String, CronState>{
          'chat-a': CronState(
            jobs: <CronJob>[
              CronJob(
                id: 'c-late',
                sessionId: 'chat-a',
                name: 'Later cron',
                expression: '0 9 * * *',
                action: CronActionKind.notification,
                nextRunAtMs: DateTime.now()
                    .add(const Duration(hours: 5))
                    .millisecondsSinceEpoch,
                createdAtMs: 0,
              ),
              CronJob(
                id: 'c-early',
                sessionId: 'chat-a',
                name: 'Early cron',
                expression: '*/30 * * * *',
                action: CronActionKind.agent,
                nextRunAtMs: DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch,
                createdAtMs: 0,
              ),
              CronJob(
                id: 'c-off',
                sessionId: 'chat-a',
                name: 'Disabled cron',
                expression: '* * * * *',
                action: CronActionKind.chat,
                enabled: false,
                nextRunAtMs: DateTime.now()
                    .add(const Duration(minutes: 5))
                    .millisecondsSinceEpoch,
                createdAtMs: 0,
              ),
            ],
          ),
          'chat-b': CronState(
            jobs: <CronJob>[
              CronJob(
                id: 'c-other',
                sessionId: 'chat-b',
                name: 'Other chat cron',
                expression: '* * * * *',
                action: CronActionKind.notification,
                nextRunAtMs: DateTime.now()
                    .add(const Duration(minutes: 1))
                    .millisecondsSinceEpoch,
                createdAtMs: 0,
              ),
            ],
          ),
        },
      );
      final BriefingService briefing = BriefingService(
        goals: goals,
        reminders: reminders,
        memory: mem,
        jobs: jobs,
        cron: cronRepo,
      );
      final BriefingData data = briefing.build('chat-a');
      expect(data.goals.single.title, 'Ship it');
      expect(data.dueReminders.single.title, 'Due soon');
      expect(data.nextJob?.title, 'Morning ping');
      // Fase 5(b): next-fire comes from the NEW cron engine — earliest
      // ENABLED job of this chat; the disabled and other-chat jobs lose.
      expect(data.nextCronJob?.name, 'Early cron');
      expect(briefing.build('chat-b').nextCronJob?.name, 'Other chat cron');
      expect(data.pinnedMemories.single.text, 'Pinned fact');
      expect(briefing.build('chat-b').goals, isEmpty);
      expect(
        briefing.build('chat-b').pinnedMemories.single.text,
        'Other chat pinned',
      );
    });
  });

  group('html export generator (pure)', () {
    test('self-contained, escaped, skips system/tool', () {
      final String html = buildChatHtml(
        title: 'T <script>',
        messages: <ChatMessage>[
          ChatMessage(
            id: '1',
            role: Role.user,
            content: 'Hi <b>there</b>',
            createdAt: DateTime(2026, 1, 1),
          ),
          ChatMessage(
            id: '2',
            role: Role.system,
            content: 'secret system',
            createdAt: DateTime(2026, 1, 1),
          ),
          ChatMessage(
            id: '3',
            role: Role.assistant,
            content: 'Answer',
            createdAt: DateTime(2026, 1, 1),
          ),
        ],
        exportedAt: DateTime(2026, 1, 2),
      );
      expect(html, contains('<style>'));
      expect(html, contains('Hi &lt;b&gt;there&lt;/b&gt;'));
      expect(html, isNot(contains('secret system')));
      expect(html, contains('Answer'));
    });
  });

  group('skill_save', () {
    test('saves a chat-authored skill with a chat: source', () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'noah_skill_save',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final SkillRegistry registry = SkillRegistry(
        resolveBaseDir: () async => dir,
      );
      final report = await registry.saveSkillFromChat(
        name: 'Morning Checklist',
        description: 'Use at the start of the day',
        instructions: '1. Check calendar\n2. Review goals',
      );
      expect(report.skill.name, 'morning-checklist');
      expect(report.skill.source, 'chat:morning-checklist');
      await expectLater(
        registry.saveSkillFromChat(
          name: 'Empty',
          description: 'x',
          instructions: '   ',
        ),
        throwsA(isA<SkillRegistryException>()),
      );
    });
  });

  group('new tools are defined and execute per-chat', () {
    test('tool defs include reminder/cron/skill tools', () {
      final Set<String> names = <String>{
        for (final Map<String, dynamic> t in buildAgentTools())
          (t['function'] as Map<String, dynamic>)['name'] as String,
      };
      expect(
        names,
        containsAll(<String>[
          'reminder_create',
          'reminder_list',
          'reminder_complete',
          'cron_create',
          'cron_list',
          'cron_update',
          'cron_delete',
          'skill_save',
        ]),
      );
    });

    test('cron tools: create twice, list both, other chat empty', () async {
      final ScheduledJobService jobs = ScheduledJobService(
        InMemoryScheduledJobRepository(),
      );
      final ReminderService reminders = ReminderService(
        InMemoryReminderRepository(),
      );
      final Directory dir = Directory.systemTemp.createTempSync('noah_fase_ef');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ToolExecutor executor = ToolExecutor(
        browser: ScriptedBrowserAutomation(dir.path),
        resolveBaseDir: (_) async => dir,
        isAutomationEnabled: () => true,
        reminders: reminders,
        cronJobs: jobs,
      );
      final ToolResult r1 = await executor.execute(
        'cron_create',
        <String, dynamic>{
          'title': 'One',
          'message': 'm1',
          'kind': 'daily',
          'hour': 8,
          'minute': 0,
        },
        sessionId: 'chat-a',
      );
      final ToolResult r2 = await executor.execute(
        'cron_create',
        <String, dynamic>{
          'title': 'Two',
          'message': 'm2',
          'kind': 'daily',
          'hour': 8,
          'minute': 0,
        },
        sessionId: 'chat-a',
      );
      expect(r1.ok, isTrue);
      expect(r2.ok, isTrue, reason: 'second create must not overwrite');
      final ToolResult listA = await executor.execute(
        'cron_list',
        <String, dynamic>{},
        sessionId: 'chat-a',
      );
      expect(listA.llmOutput, contains('One'));
      expect(listA.llmOutput, contains('Two'));
      final ToolResult listB = await executor.execute(
        'cron_list',
        <String, dynamic>{},
        sessionId: 'chat-b',
      );
      expect(listB.llmOutput, contains('No jobs'));
    });
  });
}
