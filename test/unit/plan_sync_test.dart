import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/chat_store.dart' show SessionBundle;
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// Scripted LLM that SNAPSHOTS the wire at call time. The controller grows
/// ONE shared wire list for the whole run, so the base double's stored
/// references all end up showing the final wire. Plan-sync timing
/// assertions need the wire AS THE MODEL SAW IT at each call.
class _SnapshotLlmClient extends ScriptedLlmClient {
  _SnapshotLlmClient(super.turns);

  final List<List<Map<String, dynamic>>> snapshots =
      <List<Map<String, dynamic>>>[];

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    snapshots.add(List<Map<String, dynamic>>.of(messages));
    return super.complete(
      config: config,
      messages: messages,
      tools: tools,
      onDelta: onDelta,
      shouldAbort: shouldAbort,
      cancelKey: cancelKey,
    );
  }
}

/// v1.48.1 plan-sync enforcement tests: the agent's Plan (todos) must stay
/// current — a broken todo_write must never wipe it, and the loop must
/// actively pull the model back to todo_write when it drifts.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_plan_sync_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  int planIds = 0;

  ProviderContainer containerFor(LlmClient llm, AppSettings settings) {
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(llm: llm, dir: tempDir, settings: settings),
    );
    addTearDown(container.dispose);
    return container;
  }

  List<String> userTexts(List<Map<String, dynamic>> wire) => <String>[
    for (final Map<String, dynamic> m in wire)
      if (m['role'] == 'user') m['content'] as String,
  ];

  int remindersIn(List<Map<String, dynamic>> wire) => wire
      .where(
        (Map<String, dynamic> m) =>
            m['role'] == 'user' &&
            m['content'] is String &&
            (m['content'] as String).startsWith(todoSyncReminderPrefix),
      )
      .length;

  // Wire indexing: calls[k] is the LLM call made at step k, so it sees
  // every wire message appended through the END of step k-1. A reminder
  // appended at the tail of step j therefore shows up in calls[j + 1].
  AssistantTurn planWrite(List<Map<String, String>> items) => AssistantTurn(
    content: '',
    toolCalls: <ToolCallRequest>[
      ToolCallRequest(
        id: 'plan-${planIds++}',
        name: 'todo_write',
        argumentsJson: jsonEncode(<String, dynamic>{'todos': items}),
      ),
    ],
  );

  AssistantTurn navigate(String id) => AssistantTurn(
    content: '',
    toolCalls: <ToolCallRequest>[
      ToolCallRequest(
        id: id,
        name: 'browser_navigate',
        argumentsJson: jsonEncode(<String, dynamic>{'url': 'https://a.b'}),
      ),
    ],
  );

  group('plan sync (v1.48.1)', () {
    test(
      'a failed or empty todo_write never wipes the live or persisted plan',
      () async {
        final _SnapshotLlmClient llm = _SnapshotLlmClient(<AssistantTurn>[
          // 1. The model writes a valid plan.
          planWrite(<Map<String, String>>[
            <String, String>{
              'content': 'research topic',
              'status': 'in_progress',
            },
            <String, String>{'content': 'write report', 'status': 'pending'},
          ]),
          // 2. Real work (no plan sync needed yet — streak builds).
          navigate('n1'),
          // 3. BROKEN todo_write: malformed JSON args degrade to {} and
          //    the executor rejects the call.
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'p2',
                name: 'todo_write',
                argumentsJson: '{"todos": [broken',
              ),
            ],
          ),
          // 4. Valid JSON but an EMPTY todos array — also rejected.
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'p3',
                name: 'todo_write',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'todos': <dynamic>[],
                }),
              ),
            ],
          ),
          // 5. Final answer (nudge disabled via settings below).
          AssistantTurn(content: 'wrapped up'),
        ]);
        final ProviderContainer container = containerFor(
          llm,
          // Nudge off so the run ends cleanly; the wipe bug is independent
          // of plan-first (the controller tracks latestTodos regardless).
          AppSettings(
            apiKey: 'k',
            autoTitle: false,
            planFirst: false,
            runUntilDone: false,
          ),
        );

        await container.read(chatControllerProvider.notifier).send('do a task');
        expect(llm.snapshots, hasLength(5));

        // The live plan (UI) still shows the LAST GOOD plan.
        final ChatState state = container.read(chatControllerProvider);
        expect(state.todos, hasLength(2));
        expect(state.todos[0].content, 'research topic');
        expect(state.todos[0].status, TodoStatus.inProgress);
        expect(state.todos[1].content, 'write report');
        expect(state.todos[1].status, TodoStatus.pending);

        // The broken calls were reported to the model as failures.
        final List<ToolCall> todoCalls = <ToolCall>[
          for (final ChatMessage m in state.messages)
            for (final ToolCall c in m.toolCalls)
              if (c.name == 'todo_write') c,
        ];
        expect(todoCalls, hasLength(3));
        expect(todoCalls[0].status, ToolStatus.success);
        expect(todoCalls[1].status, ToolStatus.error);
        expect(todoCalls[2].status, ToolStatus.error);

        // The on-disk transcript still carries the plan (v1.35.0 crash
        // recovery writes latestTodos with every batch).
        final String id = state.sessionId!;
        final SessionBundle? bundle = await container
            .read(chatStoreProvider)
            .loadBundle(id);
        expect(bundle, isNotNull);
        expect(bundle!.todos, hasLength(2));
        expect(bundle.todos[0].content, 'research topic');
        expect(bundle.todos[0].status, TodoStatus.inProgress);
        expect(bundle.todos[1].content, 'write report');
        expect(bundle.todos[1].status, TodoStatus.pending);

        // A failed todo_write still counts as a sync ATTEMPT: no reminder.
        expect(remindersIn(llm.snapshots.last), 0);
      },
    );

    test(
      'todo-sync reminder fires after two tool batches without todo_write',
      () async {
        final _SnapshotLlmClient llm = _SnapshotLlmClient(<AssistantTurn>[
          planWrite(<Map<String, String>>[
            <String, String>{'content': 'collect data', 'status': 'completed'},
            <String, String>{
              'content': 'analyze data',
              'status': 'in_progress',
            },
            <String, String>{'content': 'write summary', 'status': 'pending'},
          ]),
          navigate('n1'), // streak 1
          navigate('n2'), // streak 2 -> reminder appended at batch tail
          navigate('n3'), // streak 1 — no new reminder
          AssistantTurn(content: 'wrapped up'),
        ]);
        final ProviderContainer container = containerFor(
          llm,
          AppSettings(
            apiKey: 'k',
            autoTitle: false,
            planFirst: false,
            runUntilDone: false,
          ),
        );

        await container.read(chatControllerProvider.notifier).send('do a task');
        // plan + 3 nav batches + final answer.
        expect(llm.snapshots, hasLength(5));

        // Streak needs TWO unsynced batches before the reminder fires, and
        // it rides the wire of the NEXT call (see indexing note above).
        expect(remindersIn(llm.snapshots[0]), 0);
        expect(remindersIn(llm.snapshots[1]), 0);
        expect(remindersIn(llm.snapshots[2]), 0, reason: 'streak only at 1');
        expect(remindersIn(llm.snapshots[3]), 1, reason: 'streak reached 2');
        expect(
          remindersIn(llm.snapshots[4]),
          1,
          reason: 'no premature duplicate',
        );

        // The reminder mirrors the FULL plan with all three statuses and
        // tells the model exactly what to sync.
        final String reminder = userTexts(llm.snapshots[3]).last;
        expect(reminder, startsWith(todoSyncReminderPrefix));
        expect(
          reminder,
          contains('Call todo_write NOW with the FULL updated list'),
        );
        expect(reminder, contains('- [completed] collect data'));
        expect(reminder, contains('- [in_progress] analyze data'));
        expect(reminder, contains('- [pending] write summary'));

        // Wire-only: the visible transcript keeps exactly one user message.
        final ChatState state = container.read(chatControllerProvider);
        expect(
          state.messages.where((ChatMessage m) => m.role == Role.user),
          hasLength(1),
        );
      },
    );

    test('a todo_write resets the reminder streak', () async {
      final _SnapshotLlmClient llm = _SnapshotLlmClient(<AssistantTurn>[
        planWrite(<Map<String, String>>[
          <String, String>{'content': 'step A', 'status': 'in_progress'},
          <String, String>{'content': 'step B', 'status': 'pending'},
        ]),
        navigate('n1'), // streak 1
        navigate('n2'), // streak 2 -> reminder #1 (rides calls[3])
        planWrite(<Map<String, String>>[
          <String, String>{'content': 'step A', 'status': 'completed'},
          <String, String>{'content': 'step B', 'status': 'in_progress'},
        ]), // streak reset
        navigate('n3'), // streak 1 — no new reminder
        AssistantTurn(content: 'wrapped up'),
      ]);
      final ProviderContainer container = containerFor(
        llm,
        AppSettings(
          apiKey: 'k',
          autoTitle: false,
          planFirst: false,
          runUntilDone: false,
        ),
      );

      await container.read(chatControllerProvider.notifier).send('do a task');
      expect(llm.snapshots, hasLength(6));
      expect(remindersIn(llm.snapshots[3]), 1, reason: 'first reminder fired');
      // Without the todo_write the streak would have hit 2 again and a
      // second reminder would be on this wire — one means the reset worked.
      expect(remindersIn(llm.snapshots[4]), 1);
      expect(remindersIn(llm.snapshots[5]), 1);
      expect(
        remindersIn(llm.snapshots[5]),
        lessThanOrEqualTo(maxPlanNudges),
        reason: 'reminder cap is respected',
      );

      // The reset batch DID move the plan forward.
      final ChatState state = container.read(chatControllerProvider);
      expect(state.todos, hasLength(2));
      expect(state.todos[0].status, TodoStatus.completed);
      expect(state.todos[1].status, TodoStatus.inProgress);
    });

    test('reminder count is capped at maxPlanNudges per run', () async {
      // 1 plan + 44 todo-less batches (_SnapshotLlmClient repeats the last
      // turn). 44 unsynced batches would naively fire 22 reminders; the
      // cap must hold it at maxPlanNudges.
      final _SnapshotLlmClient llm = _SnapshotLlmClient(<AssistantTurn>[
        planWrite(<Map<String, String>>[
          <String, String>{'content': 'collect data', 'status': 'completed'},
          <String, String>{'content': 'analyze data', 'status': 'in_progress'},
          <String, String>{'content': 'write summary', 'status': 'pending'},
        ]),
        navigate('n'),
      ]);
      final ProviderContainer container = containerFor(
        llm,
        AppSettings(
          apiKey: 'k',
          autoTitle: false,
          planFirst: false,
          runUntilDone: false,
          maxSteps: 45,
        ),
      );

      await container.read(chatControllerProvider.notifier).send('long task');
      expect(llm.snapshots, hasLength(45));
      expect(
        remindersIn(llm.snapshots.last),
        maxPlanNudges,
        reason: 'every reminder is capped by maxPlanNudges',
      );
    });

    test(
      'runUntilDone=true with planFirst=false still nudges an unfinished plan',
      () async {
        final _SnapshotLlmClient llm = _SnapshotLlmClient(<AssistantTurn>[
          // 1. The model plans on its own (plan-first OFF).
          planWrite(<Map<String, String>>[
            <String, String>{'content': 'only step', 'status': 'pending'},
          ]),
          // 2. Premature final answer.
          AssistantTurn(content: 'stopping early'),
          // 3. After the nudge it completes the plan.
          planWrite(<Map<String, String>>[
            <String, String>{'content': 'only step', 'status': 'completed'},
          ]),
          // 4. Real final answer.
          AssistantTurn(content: 'all done'),
        ]);
        final ProviderContainer container = containerFor(
          llm,
          AppSettings(
            apiKey: 'k',
            autoTitle: false,
            planFirst: false,
            runUntilDone: true,
          ),
        );

        await container.read(chatControllerProvider.notifier).send('do it');
        expect(llm.snapshots, hasLength(4)); // plan, premature, continue, final

        // The nudge reached the model even though planFirst is off.
        final List<String> nudged = userTexts(llm.snapshots[2]);
        expect(
          nudged.any((String t) => t.contains('plan is not finished')),
          isTrue,
          reason: 'a self-planned run must still be nudged to finish',
        );

        final ChatState state = container.read(chatControllerProvider);
        expect(
          state.messages.where((ChatMessage m) => m.role == Role.user),
          hasLength(1),
          reason: 'the nudge is wire-only',
        );
        expect(state.messages.last.content, 'all done');
        expect(state.todos.single.status, TodoStatus.completed);
      },
    );
  });

  group('blocked-aware nudges (v1.49.0 wave-2)', () {
    test('planNudgeText reports blocked steps with their reason', () {
      final String nudge = planNudgeText(<TodoItem>[
        const TodoItem(
          content: 'buy coins',
          status: TodoStatus.blocked,
          blockedReason: 'user has not funded the wallet',
        ),
        const TodoItem(content: 'idle step', status: TodoStatus.pending),
        const TodoItem(content: 'working step', status: TodoStatus.inProgress),
        const TodoItem(content: 'done step', status: TodoStatus.completed),
      ]);
      expect(
        nudge,
        contains('- [blocked — user has not funded the wallet] buy coins'),
      );
      expect(nudge, contains('- [pending] idle step'));
      expect(nudge, contains('- [in_progress] working step'));
      expect(
        nudge,
        isNot(contains('done step')),
        reason: 'completed steps are not listed',
      );
    });

    test('a blocked step without a reason still reads as blocked', () {
      final String nudge = planNudgeText(<TodoItem>[
        const TodoItem(content: 'stalled', status: TodoStatus.blocked),
      ]);
      expect(nudge, contains('- [blocked] stalled'));
    });

    test('todoSyncReminderText keeps completed steps visible and marks '
        'blocked ones', () {
      final String reminder = todoSyncReminderText(<TodoItem>[
        const TodoItem(content: 'done', status: TodoStatus.completed),
        const TodoItem(
          content: 'waiting on user',
          status: TodoStatus.blocked,
          blockedReason: 'needs API key',
        ),
      ]);
      expect(reminder, contains('- [completed] done'));
      expect(reminder, contains('- [blocked — needs API key] waiting on user'));
    });
  });
}
