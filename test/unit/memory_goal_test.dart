import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/goal_repository.dart';
import 'package:noah/services/goal_service.dart';
import 'package:noah/services/memory_repository.dart';
import 'package:noah/services/memory_service.dart';
import 'package:noah/services/tool_executor.dart';
import 'package:noah/tools/tool_defs.dart';

import '../support/test_doubles.dart';

MemoryEntry _mem(
  String text, {
  bool pinned = false,
  MemoryCategory category = MemoryCategory.fact,
  DateTime? at,
}) {
  final DateTime now = at ?? DateTime(2026, 1, 1);
  return MemoryEntry(
    id: newId(),
    text: text,
    category: category,
    pinned: pinned,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('PrefsMemoryRepository (per chat)', () {
    test('save then load roundtrips entries for that chat', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final PrefsMemoryRepository repo = PrefsMemoryRepository(prefs);
      await repo.save('chat-a', <MemoryEntry>[
        _mem('User likes tea', pinned: true),
        _mem('Project is Noah', category: MemoryCategory.project),
      ]);
      final List<MemoryEntry> loaded = repo.load('chat-a');
      expect(loaded, hasLength(2));
      expect(loaded.first.text, 'User likes tea');
      expect(loaded.first.pinned, isTrue);
      expect(loaded.last.category, MemoryCategory.project);
    });

    test(
      'ISOLATION: entries saved in chat A are invisible in chat B',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final prefs = await SharedPreferences.getInstance();
        final PrefsMemoryRepository repo = PrefsMemoryRepository(prefs);
        await repo.save('chat-a', <MemoryEntry>[_mem('secret of chat A')]);
        expect(repo.load('chat-a'), hasLength(1));
        expect(repo.load('chat-b'), isEmpty);
        expect(prefs.getString('noah.memory.v1.chat-b'), isNull);
      },
    );

    test('corrupted store degrades to an empty list', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'noah.memory.v1.chat-a': '{broken json',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(PrefsMemoryRepository(prefs).load('chat-a'), isEmpty);
    });
  });

  group('MemoryService (per chat)', () {
    test('add dedupes near-identical text (normalized)', () async {
      final MemoryService svc = MemoryService(InMemoryMemoryRepository());
      final MemoryEntry? a = await svc.add('chat-a', 'User  likes   Tea');
      final MemoryEntry? b = await svc.add('chat-a', 'user likes tea');
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(b!.id, a!.id);
      expect(svc.list('chat-a'), hasLength(1));
    });

    test(
      'ISOLATION: memory saved in chat A is not visible in chat B',
      () async {
        final MemoryService svc = MemoryService(InMemoryMemoryRepository());
        await svc.add('chat-a', 'chat A loves blue oceans', pinned: true);
        await svc.add('chat-b', 'chat B loves green forests');
        expect(svc.list('chat-a').single.text, contains('blue oceans'));
        expect(svc.list('chat-b').single.text, contains('green forests'));
        expect(
          svc.search('chat-b', 'blue oceans'),
          isNot(
            contains(predicate<MemoryEntry>((e) => e.text.contains('blue'))),
          ),
        );
        expect(
          svc.promptSummary('chat-b', 'blue oceans'),
          isNot(contains('blue')),
        );
        expect(
          svc.promptSummary('chat-a', 'blue oceans'),
          contains('blue oceans'),
        );
        // Forgetting in B must not touch A.
        final String bId = svc.list('chat-b').single.id;
        expect(await svc.forget('chat-b', bId), isTrue);
        expect(svc.list('chat-a'), hasLength(1));
      },
    );

    test('search ranks pinned first and by token overlap', () async {
      final MemoryService svc = MemoryService(
        InMemoryMemoryRepository(<String, List<MemoryEntry>>{
          'chat-a': <MemoryEntry>[
            _mem('banana bread recipe'),
            _mem('user favorite color is blue', pinned: true),
            _mem('blue ocean photo'),
          ],
        }),
      );
      final List<MemoryEntry> hits = svc.search('chat-a', 'blue');
      expect(hits.first.pinned, isTrue);
      expect(hits.map((MemoryEntry e) => e.text), contains('blue ocean photo'));
      expect(
        hits.map((MemoryEntry e) => e.text),
        isNot(contains('banana bread recipe')),
      );
    });

    test('promptSummary is empty without memories and bounded with', () async {
      final MemoryService svc = MemoryService(InMemoryMemoryRepository());
      expect(svc.promptSummary('chat-a', 'anything'), isEmpty);
      await svc.add('chat-a', 'User prefers dark mode', pinned: true);
      await svc.add('chat-a', 'User works on Noah project');
      final String summary = svc.promptSummary('chat-a', 'tell me about Noah');
      expect(summary, contains('dark mode'));
      expect(summary.length, lessThanOrEqualTo(MemoryService.promptMaxChars));
    });

    test('update and forget work', () async {
      final MemoryService svc = MemoryService(InMemoryMemoryRepository());
      final MemoryEntry? e = await svc.add('chat-a', 'draft note');
      expect(e, isNotNull);
      final MemoryEntry? updated = await svc.update(
        'chat-a',
        e!.id,
        pinned: true,
      );
      expect(updated!.pinned, isTrue);
      expect(await svc.forget('chat-a', e.id), isTrue);
      expect(svc.list('chat-a'), isEmpty);
      expect(await svc.forget('chat-a', e.id), isFalse);
    });
  });

  group('PrefsGoalRepository + GoalService (per chat)', () {
    test('save then load roundtrips; corrupted degrades empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final PrefsGoalRepository repo = PrefsGoalRepository(prefs);
      final GoalService svc = GoalService(repo);
      final GoalEntry? g = await svc.create(
        'chat-a',
        'Ship v1.50',
        progress: 40,
        dueDate: DateTime(2026, 11, 10),
      );
      expect(g, isNotNull);
      expect(repo.load('chat-a').single.title, 'Ship v1.50');
      expect(repo.load('chat-a').single.progress, 40);
      // ISOLATION: nothing leaks into chat B.
      expect(repo.load('chat-b'), isEmpty);

      SharedPreferences.setMockInitialValues(<String, Object>{
        'noah.goals.v1.chat-a': 'not json!!',
      });
      final prefs2 = await SharedPreferences.getInstance();
      expect(PrefsGoalRepository(prefs2).load('chat-a'), isEmpty);
    });

    test('overdue and dueSoon logic', () {
      final DateTime now = DateTime(2026, 11, 5, 12);
      GoalEntry make(DateTime? due, {GoalStatus status = GoalStatus.active}) =>
          GoalEntry(
            id: 'g',
            title: 't',
            status: status,
            dueDate: due,
            createdAt: now,
            updatedAt: now,
          );
      expect(
        make(now.subtract(const Duration(hours: 1))).isOverdue(now),
        isTrue,
      );
      expect(make(now.add(const Duration(hours: 24))).isDueSoon(now), isTrue);
      expect(make(now.add(const Duration(hours: 24))).isOverdue(now), isFalse);
      expect(make(now.add(const Duration(days: 7))).isDueSoon(now), isFalse);
      expect(
        make(
          now.subtract(const Duration(days: 1)),
          status: GoalStatus.done,
        ).isOverdue(now),
        isFalse,
      );
      expect(make(null).isOverdue(now), isFalse);
    });

    test('complete pins progress at 100; summary only lists active', () async {
      final GoalService svc = GoalService(InMemoryGoalRepository());
      expect(svc.promptSummary('chat-a'), isEmpty);
      final GoalEntry? g = await svc.create(
        'chat-a',
        'Learn Dart',
        progress: 10,
      );
      expect(svc.promptSummary('chat-a'), contains('Learn Dart'));
      expect(svc.promptSummary('chat-b'), isEmpty);
      final GoalEntry? done = await svc.complete('chat-a', g!.id);
      expect(done!.status, GoalStatus.done);
      expect(done.progress, 100);
      expect(svc.promptSummary('chat-a'), isEmpty);
    });

    test('progress is clamped to 0..100', () async {
      final GoalService svc = GoalService(InMemoryGoalRepository());
      final GoalEntry? g = await svc.create(
        'chat-a',
        'Clamp me',
        progress: 250,
      );
      expect(g!.progress, 100);
    });
  });

  group('tool defs + executor (memory & goals, per chat)', () {
    test('all eight new tools are defined exactly once', () {
      final List<String> names = <String>[
        for (final Map<String, dynamic> tool in buildAgentTools())
          (tool['function'] as Map<String, dynamic>)['name'] as String,
      ];
      for (final String name in <String>[
        'memory_save',
        'memory_recall',
        'memory_list',
        'memory_forget',
        'goal_create',
        'goal_list',
        'goal_update',
        'goal_complete',
      ]) {
        expect(
          names.where((String n) => n == name),
          hasLength(1),
          reason: name,
        );
      }
    });

    test('executor round-trips tools within the active chat only', () async {
      final Directory dir = await Directory.systemTemp.createTemp('mg_tools');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final MemoryService memSvc = MemoryService(InMemoryMemoryRepository());
      final GoalService goalSvc = GoalService(InMemoryGoalRepository());
      final ToolExecutor executor = ToolExecutor(
        browser: ScriptedBrowserAutomation(dir.path),
        resolveBaseDir: (_) async => dir,
        isAutomationEnabled: () => true,
        memory: memSvc,
        goals: goalSvc,
      );

      final ToolResult saved = await executor.execute(
        'memory_save',
        <String, dynamic>{
          'text': 'User prefers concise answers',
          'category': 'preference',
        },
        sessionId: 'chat-a',
      );
      expect(saved.ok, isTrue);
      final ToolResult recalled = await executor.execute(
        'memory_recall',
        <String, dynamic>{'query': 'concise answers'},
        sessionId: 'chat-a',
      );
      expect(recalled.ok, isTrue);
      expect(recalled.llmOutput, contains('concise answers'));
      // ISOLATION: the same recall inside another chat finds nothing.
      final ToolResult otherChat = await executor.execute(
        'memory_recall',
        <String, dynamic>{'query': 'concise answers'},
        sessionId: 'chat-b',
      );
      expect(otherChat.llmOutput, isNot(contains('concise answers')));

      final ToolResult created = await executor.execute(
        'goal_create',
        <String, dynamic>{'title': 'Finish Noah', 'progress': 20},
        sessionId: 'chat-a',
      );
      expect(created.ok, isTrue);
      final ToolResult listed = await executor.execute(
        'goal_list',
        <String, dynamic>{},
        sessionId: 'chat-a',
      );
      expect(listed.llmOutput, contains('Finish Noah'));
      final ToolResult listedB = await executor.execute(
        'goal_list',
        <String, dynamic>{},
        sessionId: 'chat-b',
      );
      expect(listedB.llmOutput, isNot(contains('Finish Noah')));
      final String goalId = goalSvc.list('chat-a').single.id;
      final ToolResult completed = await executor.execute(
        'goal_complete',
        <String, dynamic>{'id': goalId},
        sessionId: 'chat-a',
      );
      expect(completed.ok, isTrue);
      expect(goalSvc.list('chat-a').single.status, GoalStatus.done);
    });

    test('memory tools degrade gracefully without a service', () async {
      final Directory dir = await Directory.systemTemp.createTemp('mg_none');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final ToolExecutor executor = ToolExecutor(
        browser: ScriptedBrowserAutomation(dir.path),
        resolveBaseDir: (_) async => dir,
        isAutomationEnabled: () => true,
      );
      final ToolResult result = await executor.execute(
        'memory_list',
        <String, dynamic>{},
        sessionId: 'chat-a',
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('unavailable'));
    });
  });
}
