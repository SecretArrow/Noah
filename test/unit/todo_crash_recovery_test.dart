import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// Scripted LLM that freezes forever on its SECOND call — stands in for an
/// app killed mid-run: turn 0 (todo_write) fully executes, then the loop
/// never reaches a final persist, so whatever is on disk afterwards came
/// from the new per-step persistence.
class _FreezeAfterFirstTurn extends ScriptedLlmClient {
  _FreezeAfterFirstTurn(super.turns);

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    if (calls.isNotEmpty) {
      // The "crash": this future never completes.
      await Completer<void>().future;
    }
    return super.complete(
      config: config,
      messages: messages,
      tools: tools,
      onDelta: onDelta,
      shouldAbort: shouldAbort,
    );
  }
}

AssistantTurn _planTurn({
  String id = 'p1',
  List<Map<String, String>>? todos,
}) => AssistantTurn(
  content: '',
  toolCalls: <ToolCallRequest>[
    ToolCallRequest(
      id: id,
      name: 'todo_write',
      argumentsJson: jsonEncode(<String, dynamic>{
        'todos':
            todos ??
            <Map<String, String>>[
              <String, String>{
                'content': 'research topic',
                'status': 'pending',
              },
              <String, String>{'content': 'draft report', 'status': 'pending'},
              <String, String>{'content': 'review output', 'status': 'pending'},
            ],
      }),
    ),
  ],
);

/// Waits until [predicate] holds, polling every 20 ms; fails after
/// [timeout] so a regression fails the test instead of hanging it.
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'condition not met within ${timeout.inMilliseconds}ms: '
        '${reason ?? ''}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_todo_crash');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  File sessionFile(String id) => File(
    '${tempDir.path}${Platform.pathSeparator}chats'
    '${Platform.pathSeparator}$id.json',
  );

  test('plan + transcript hit disk mid-run and survive an app crash', () async {
    // ── "App run" ────────────────────────────────────────────────────────
    final ProviderContainer crashed = ProviderContainer(
      overrides: testOverrides(
        llm: _FreezeAfterFirstTurn(<AssistantTurn>[
          _planTurn(),
          AssistantTurn(content: 'tidak pernah sampai sini'),
        ]),
        dir: tempDir,
        settings: AppSettings(apiKey: 'k', autoTitle: false),
      ),
    );
    addTearDown(crashed.dispose);

    unawaited(crashed.read(chatControllerProvider.notifier).send('kerjakan'));
    await _waitFor(
      () => crashed.read(chatControllerProvider).sessionId != null,
      reason: 'session created',
    );
    final String id = crashed.read(chatControllerProvider).sessionId!;

    // The plan card + todos must land on disk WHILE the run is still
    // blocked mid-flight — previously nothing after the opening user
    // message was persisted until the whole run finished.
    await _waitFor(
      () =>
          sessionFile(id).existsSync() &&
          sessionFile(id).readAsStringSync().contains('research topic'),
      reason: 'mid-run persist of plan card + todos',
    );
    final String rawMidRun = sessionFile(id).readAsStringSync();
    expect(rawMidRun, contains('todo_write'), reason: 'plan card persisted');
    expect(rawMidRun, contains('"todos"'), reason: 'plan state persisted');

    // Switching away and back DURING the run keeps the live plan panel.
    await crashed
        .read(chatControllerProvider.notifier)
        .openChat(
          ChatSummary(id: id, title: 'kerjakan', updatedAt: DateTime.now()),
        );
    ChatState live = crashed.read(chatControllerProvider);
    expect(live.isRunning, isTrue);
    expect(live.todos, hasLength(3));
    expect(live.todos.first.content, 'research topic');

    // ── "App crash" → relaunch ───────────────────────────────────────────
    crashed.dispose();
    final ProviderContainer relaunched = ProviderContainer(
      overrides: testOverrides(
        llm: ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(content: 'ok lanjut'),
        ]),
        dir: tempDir,
        settings: AppSettings(
          apiKey: 'k',
          autoTitle: false,
          // Keep the nudge/resume machinery out of this continuation; the
          // test asserts the RESTORED plan, not the resume loop.
          planFirst: false,
        ),
      ),
    );
    addTearDown(relaunched.dispose);

    final List<ChatSummary> summaries = await relaunched.read(
      chatListProvider.future,
    );
    expect(summaries, hasLength(1));
    await relaunched
        .read(chatControllerProvider.notifier)
        .openChat(summaries.single);

    final ChatState reopened = relaunched.read(chatControllerProvider);
    expect(reopened.sessionId, id);
    // The plan the user was watching comes back from disk.
    expect(reopened.todos, hasLength(3));
    expect(reopened.todos.map((t) => t.content).toList(), <String>[
      'research topic',
      'draft report',
      'review output',
    ]);
    // The transcript keeps the plan card too (mid-run persist).
    final ChatMessage planMessage = reopened.messages.firstWhere(
      (m) => m.toolCalls.any((c) => c.name == 'todo_write'),
    );
    expect(
      planMessage.toolCalls.single.arguments['todos'],
      isA<List<dynamic>>(),
    );

    // ── Continuing the crashed task keeps the plan alive ────────────────
    await relaunched.read(chatControllerProvider.notifier).send('lanjutkan');
    final ChatState continued = relaunched.read(chatControllerProvider);
    expect(continued.sessionId, id, reason: 'continuation, not a fork');
    expect(continued.isRunning, isFalse);
    expect(continued.todos, hasLength(3), reason: 'plan survives the continue');
    expect(continued.todos.first.content, 'research topic');
  });

  test(
    'finished run: reopening the chat restores the completed plan',
    () async {
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: ScriptedLlmClient(<AssistantTurn>[
            _planTurn(
              id: 'p1',
              todos: <Map<String, String>>[
                <String, String>{'content': 'step satu', 'status': 'completed'},
                <String, String>{
                  'content': 'step dua',
                  'status': 'in_progress',
                },
                <String, String>{'content': 'step tiga', 'status': 'pending'},
              ],
            ),
            AssistantTurn(content: 'Selesai.'),
          ]),
          dir: tempDir,
          // planFirst off: this test asserts plan PERSISTENCE, not the
          // run-until-done nudge/resume loop (an incomplete plan with the
          // default settings intentionally keeps re-engaging the agent).
          settings: AppSettings(
            apiKey: 'k',
            autoTitle: false,
            planFirst: false,
          ),
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('mulai');
      expect(container.read(chatControllerProvider).todos, hasLength(3));

      // Fresh container = app restart.
      final ProviderContainer restarted = ProviderContainer(
        overrides: testOverrides(
          llm: ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(restarted.dispose);

      final List<ChatSummary> summaries = await restarted.read(
        chatListProvider.future,
      );
      await restarted
          .read(chatControllerProvider.notifier)
          .openChat(summaries.single);
      final ChatState state = restarted.read(chatControllerProvider);
      expect(state.todos, hasLength(3));
      expect(state.todos[0].status, TodoStatus.completed);
      expect(state.todos[1].status, TodoStatus.inProgress);
      expect(state.todos[2].status, TodoStatus.pending);
    },
  );

  test(
    'a session without a persisted plan opens with an empty panel',
    () async {
      // Chat WITHOUT any todo_write: openChat must not invent todos.
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: ScriptedLlmClient(<AssistantTurn>[
            AssistantTurn(content: 'jawaban biasa'),
          ]),
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('halo');

      final ProviderContainer restarted = ProviderContainer(
        overrides: testOverrides(
          llm: ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(restarted.dispose);

      final List<ChatSummary> summaries = await restarted.read(
        chatListProvider.future,
      );
      await restarted
          .read(chatControllerProvider.notifier)
          .openChat(summaries.single);
      expect(restarted.read(chatControllerProvider).todos, isEmpty);
    },
  );
}
