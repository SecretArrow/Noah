import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/subagents.dart';
import 'package:noah/services/tool_executor.dart';
import 'package:noah/tools/tool_defs.dart';

import '../support/test_doubles.dart';

/// LLM double keyed by the LAST user message of the wire: each task gets
/// its own scripted turn sequence, so parallel fan-out stays deterministic.
class _TaskKeyedLlm implements LlmClient {
  final Map<String, List<AssistantTurn>> scripted;
  final List<String> started = <String>[];
  final List<String> finished = <String>[];

  /// When set, complete() waits until [minConcurrent] calls are in flight
  /// before resolving — proves the tasks actually run in parallel.
  final int? minConcurrent;
  Completer<void>? _barrier;
  var _inFlight = 0;

  _TaskKeyedLlm(this.scripted, {this.minConcurrent});

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    final String taskPrompt = messages
        .firstWhere((Map<String, dynamic> m) => m['role'] == 'user')['content']
        .toString();
    started.add(taskPrompt);
    _inFlight++;
    final int concurrent = _inFlight;
    if (minConcurrent != null && concurrent >= minConcurrent!) {
      _barrier?.complete();
      _barrier = null;
    }
    if (minConcurrent != null) {
      _barrier ??= Completer<void>();
      // Wait until enough subagents are in flight, or 2s as a deadlock
      // guard (a serial runner would time out here and fail the test).
      await _barrier!.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    try {
      final List<AssistantTurn> turns =
          scripted[taskPrompt] ??
          <AssistantTurn>[AssistantTurn(content: 'default answer')];
      final AssistantTurn turn = turns.removeAt(0);
      await Future<void>.delayed(Duration.zero);
      return turn;
    } finally {
      _inFlight--;
      finished.add(taskPrompt);
    }
  }
}

AssistantTurn _final(String content) => AssistantTurn(content: content);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_subagents_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ToolExecutor executor({LlmClient? llm, SubagentRunner? runner}) {
    final SubagentRunner sub =
        runner ??
        SubagentRunner(
          llm: llm ?? _TaskKeyedLlm(<String, List<AssistantTurn>>{}),
          resolveConfig: () =>
              const LlmConfig(baseUrl: 'https://test', apiKey: 'k', model: 'm'),
          executeTool: (
            String name,
            Map<String, dynamic> args,
            String? sessionId, {
            String? browserContext,
          }) async => const ToolResult(ok: true, llmOutput: 'ok'),
        );
    return ToolExecutor(
      browser: ScriptedBrowserAutomation('${tempDir.path}/shots'),
      resolveBaseDir: (_) async => tempDir,
      isAutomationEnabled: () => true,
      subagents: sub,
    );
  }

  group('SubagentRunner.parseTasks', () {
    late SubagentRunner runner;

    setUp(() {
      runner = SubagentRunner(
        llm: _TaskKeyedLlm(<String, List<AssistantTurn>>{}),
        resolveConfig: () =>
            const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
        executeTool: (
          String n,
          Map<String, dynamic> a,
          String? s, {
          String? browserContext,
        }) async => const ToolResult(ok: true, llmOutput: ''),
      );
    });

    test('accepts labeled + unlabeled tasks', () {
      final (List<SubagentTaskSpec> specs, String? error) = runner.parseTasks(
        <dynamic>[
          <String, dynamic>{'label': 'Research', 'prompt': 'do research'},
          <String, dynamic>{'prompt': 'write the file'},
        ],
      );
      expect(error, isNull);
      expect(specs, hasLength(2));
      expect(specs.first.label, 'Research');
      expect(specs.last.label, 'Task 2');
      expect(specs.last.prompt, 'write the file');
    });

    test('rejects empty, non-array and missing-prompt payloads', () {
      expect(runner.parseTasks(null).$2, isNotNull);
      expect(runner.parseTasks(<dynamic>[]).$2, isNotNull);
      expect(runner.parseTasks(<dynamic>['nope']).$2, isNotNull);
      expect(
        runner.parseTasks(<dynamic>[
          <String, dynamic>{'label': 'no prompt'},
        ]).$2,
        isNotNull,
      );
    });

    test('rejects more than maxTasks entries', () {
      final SubagentRunner tiny = SubagentRunner(
        llm: runner.llm,
        resolveConfig: runner.resolveConfig,
        executeTool: runner.executeTool,
        maxTasks: 2,
      );
      expect(
        tiny.parseTasks(<dynamic>[
          <String, dynamic>{'prompt': 'a'},
          <String, dynamic>{'prompt': 'b'},
          <String, dynamic>{'prompt': 'c'},
        ]).$2,
        contains('at most 2'),
      );
    });
  });

  test(
    'buildTools exposes workspace + browser tools (no recursion, no todos)',
    () {
      final List<String> names = <String>[
        for (final Map<String, dynamic> tool in SubagentRunner(
          llm: _TaskKeyedLlm(<String, List<AssistantTurn>>{}),
          resolveConfig: () =>
              const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
          executeTool: (
            String n,
            Map<String, dynamic> a,
            String? s, {
            String? browserContext,
          }) async => const ToolResult(ok: true, llmOutput: ''),
        ).buildTools())
          (tool['function'] as Map<String, dynamic>)['name'] as String,
      ];
      expect(names, contains('read_file'));
      expect(names, contains('write_file'));
      expect(names, contains('node_run'));
      expect(names, contains('web_fetch'));
      // v1.38.0: every subagent browses in its own browser context.
      expect(
        names,
        containsAll(<String>[
          'browser_navigate',
          'browser_click',
          'browser_type',
          'browser_scroll',
          'browser_screenshot',
          'browser_extract_text',
          'run_js',
        ]),
      );
      expect(names, isNot(contains('spawn_subagents')));
      expect(names, isNot(contains('todo_write')));
      // Every subagent tool exists in the full agent set too.
      final Set<String> mainNames = <String>{
        for (final Map<String, dynamic> tool in buildAgentTools())
          (tool['function'] as Map<String, dynamic>)['name'] as String,
      };
      expect(mainNames.containsAll(names), isTrue);
    },
  );

  test('every parallel task gets its OWN distinct browser context', () async {
    // The executor records the browserContext each nested tool call was
    // pinned to; a fan of three must produce three distinct contexts and
    // every call of one task must reuse that task's context.
    final Map<String, Set<String>> contextsByTask = <String, Set<String>>{};
    final _TaskKeyedLlm llm = _TaskKeyedLlm(<String, List<AssistantTurn>>{
      't-a': <AssistantTurn>[
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 'a1',
              name: 'browser_navigate',
              argumentsJson: '{"url": "https://a.test"}',
            ),
          ],
        ),
        _final('done a'),
      ],
      't-b': <AssistantTurn>[
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 'b1',
              name: 'browser_navigate',
              argumentsJson: '{"url": "https://b.test"}',
            ),
          ],
        ),
        _final('done b'),
      ],
      't-c': <AssistantTurn>[
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 'c1',
              name: 'browser_navigate',
              argumentsJson: '{"url": "https://c.test"}',
            ),
          ],
        ),
        _final('done c'),
      ],
    });
    final SubagentRunner runner = SubagentRunner(
      llm: llm,
      resolveConfig: () =>
          const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
      executeTool:
          (
            String name,
            Map<String, dynamic> args,
            String? sessionId, {
            String? browserContext,
          }) async {
            final String key = browserContext ?? '';
            contextsByTask.putIfAbsent(key, () => <String>{});
            contextsByTask[key]!.add(args['url'].toString());
            return const ToolResult(ok: true, llmOutput: 'page');
          },
    );
    final List<SubagentOutcome> outcomes = await runner.run(<SubagentTaskSpec>[
      const SubagentTaskSpec(label: 'A', prompt: 't-a'),
      const SubagentTaskSpec(label: 'B', prompt: 't-b'),
      const SubagentTaskSpec(label: 'C', prompt: 't-c'),
    ], sessionId: 'sess-ctx');
    expect(outcomes.every((SubagentOutcome o) => o.ok), isTrue);
    // Three tasks -> three distinct context ids, each carrying exactly its
    // own task's navigation.
    expect(contextsByTask.keys, hasLength(3));
    for (final Set<String> urls in contextsByTask.values) {
      expect(urls, hasLength(1));
    }
    final Set<String> contextIds = contextsByTask.keys.toSet();
    expect(contextIds.every((String id) => id.startsWith('subagent-')), isTrue);
    expect(contextIds.map((String id) => id.split('-').last).toSet(), <String>{
      '0',
      '1',
      '2',
    });
  });

  group('SubagentRunner.run', () {
    test(
      'fan-out: three tasks run in parallel, results keep input order',
      () async {
        final _TaskKeyedLlm llm = _TaskKeyedLlm(<String, List<AssistantTurn>>{
          'alpha': <AssistantTurn>[_final('answer alpha')],
          'beta': <AssistantTurn>[_final('answer beta')],
          'gamma': <AssistantTurn>[_final('answer gamma')],
        }, minConcurrent: 3);
        final SubagentRunner runner = SubagentRunner(
          llm: llm,
          resolveConfig: () =>
              const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
          executeTool: (
            String n,
            Map<String, dynamic> a,
            String? s, {
            String? browserContext,
          }) async => const ToolResult(ok: true, llmOutput: ''),
        );
        final List<SubagentOutcome> outcomes = await runner.run(
          <SubagentTaskSpec>[
            const SubagentTaskSpec(label: 'A', prompt: 'alpha'),
            const SubagentTaskSpec(label: 'B', prompt: 'beta'),
            const SubagentTaskSpec(label: 'C', prompt: 'gamma'),
          ],
        );
        expect(outcomes.map((SubagentOutcome o) => o.label).toList(), <String>[
          'A',
          'B',
          'C',
        ]);
        expect(outcomes.map((SubagentOutcome o) => o.answer).toList(), <String>[
          'answer alpha',
          'answer beta',
          'answer gamma',
        ]);
        expect(outcomes.every((SubagentOutcome o) => o.ok), isTrue);
        // All three entered the LLM before any of them finished.
        expect(llm.started, hasLength(3));
      },
    );

    test('nested tools execute inside the session executor', () async {
      final _TaskKeyedLlm llm = _TaskKeyedLlm(<String, List<AssistantTurn>>{
        'write it': <AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'w1',
                name: 'write_file',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'path': 'sub/out.txt',
                  'content': 'from a subagent',
                }),
              ),
            ],
          ),
          _final('file written'),
        ],
      });
      late final ToolExecutor exec;
      exec = ToolExecutor(
        browser: ScriptedBrowserAutomation('${tempDir.path}/shots'),
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        subagents: SubagentRunner(
          llm: llm,
          resolveConfig: () =>
              const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
          executeTool:
              (
                String name,
                Map<String, dynamic> args,
                String? sessionId, {
                String? browserContext,
              }) => exec.execute(
                name,
                args,
                sessionId: sessionId,
                browserContext: browserContext,
              ),
        ),
      );
      final SubagentRunner runner = exec.subagents!;
      final List<SubagentOutcome> outcomes = await runner.run(
        <SubagentTaskSpec>[
          const SubagentTaskSpec(label: 'W', prompt: 'write it'),
        ],
        sessionId: 'sess-1',
      );
      expect(outcomes.single.ok, isTrue);
      expect(outcomes.single.answer, 'file written');
      expect(
        File('${tempDir.path}/sub/out.txt').readAsStringSync(),
        'from a subagent',
      );
    });

    test(
      'recursion guard: spawn_subagents is refused inside a subagent',
      () async {
        var spawnCalls = 0;
        final _TaskKeyedLlm llm = _TaskKeyedLlm(<String, List<AssistantTurn>>{
          'nested': <AssistantTurn>[
            AssistantTurn(
              content: '',
              toolCalls: <ToolCallRequest>[
                ToolCallRequest(
                  id: 's1',
                  name: 'spawn_subagents',
                  argumentsJson: jsonEncode(<String, dynamic>{
                    'tasks': <dynamic>[
                      <String, dynamic>{'prompt': 'deep'},
                    ],
                  }),
                ),
              ],
            ),
            _final('gave up on nesting'),
          ],
        });
        final SubagentRunner runner = SubagentRunner(
          llm: llm,
          resolveConfig: () =>
              const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
          executeTool:
              (
                String n,
                Map<String, dynamic> a,
                String? s, {
                String? browserContext,
              }) async {
                spawnCalls++;
                return const ToolResult(
                  ok: true,
                  llmOutput: 'should not happen',
                );
              },
        );
        final List<SubagentOutcome> outcomes = await runner.run(
          <SubagentTaskSpec>[
            const SubagentTaskSpec(label: 'N', prompt: 'nested'),
          ],
        );
        expect(spawnCalls, 0);
        expect(outcomes.single.ok, isTrue);
        expect(outcomes.single.answer, 'gave up on nesting');
      },
    );

    test(
      'step cap: a runaway subagent ends with an explanatory failure',
      () async {
        final _TaskKeyedLlm llm = _TaskKeyedLlm(
          <String, List<AssistantTurn>>{},
        ); // defaults to endless plain answers — use endless tool calls below
        final SubagentRunner runner = SubagentRunner(
          llm: _EndlessToolCallLlm(),
          resolveConfig: () =>
              const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
          executeTool: (
            String n,
            Map<String, dynamic> a,
            String? s, {
            String? browserContext,
          }) async => const ToolResult(ok: true, llmOutput: 'ok'),
          maxSteps: 3,
        );
        final List<SubagentOutcome> outcomes = await runner.run(
          <SubagentTaskSpec>[
            const SubagentTaskSpec(label: 'R', prompt: 'loop'),
          ],
        );
        expect(outcomes.single.ok, isFalse);
        expect(outcomes.single.answer, contains('3-step limit'));
        expect(outcomes.single.toolCalls, 3);
        // Sanity: the keyed llm was never consulted.
        expect(llm.started, isEmpty);
      },
    );

    test('abort: user Stop propagates into the subagent loop', () async {
      var abortChecks = 0;
      final SubagentRunner runner = SubagentRunner(
        llm: _TaskKeyedLlm(<String, List<AssistantTurn>>{}),
        resolveConfig: () =>
            const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
        executeTool: (
          String n,
          Map<String, dynamic> a,
          String? s, {
          String? browserContext,
        }) async => const ToolResult(ok: true, llmOutput: ''),
      );
      final List<SubagentOutcome> outcomes = await runner.run(
        <SubagentTaskSpec>[const SubagentTaskSpec(label: 'S', prompt: 'x')],
        shouldAbort: () {
          abortChecks++;
          return true;
        },
      );
      expect(outcomes.single.ok, isFalse);
      expect(outcomes.single.answer, 'aborted by the user');
      expect(abortChecks, 1);
    });

    test('formatOutcomes renders labeled markdown sections', () {
      final SubagentRunner runner = SubagentRunner(
        llm: _TaskKeyedLlm(<String, List<AssistantTurn>>{}),
        resolveConfig: () =>
            const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
        executeTool: (
          String n,
          Map<String, dynamic> a,
          String? s, {
          String? browserContext,
        }) async => const ToolResult(ok: true, llmOutput: ''),
      );
      final String out = runner.formatOutcomes(<SubagentOutcome>[
        const SubagentOutcome(
          label: 'A',
          ok: true,
          answer: 'result a',
          steps: 1,
          toolCalls: 2,
        ),
      ]);
      expect(out, contains('## A'));
      expect(out, contains('result a'));
      expect(out, contains('tool calls: 2'));
    });
  });

  group('tool spawn_subagents', () {
    test('runs the runner and returns formatted answers', () async {
      final ToolExecutor exec = executor(
        runner: SubagentRunner(
          llm: _TaskKeyedLlm(<String, List<AssistantTurn>>{
            't1': <AssistantTurn>[_final('one')],
            't2': <AssistantTurn>[_final('two')],
          }),
          resolveConfig: () =>
              const LlmConfig(baseUrl: 'x', apiKey: 'k', model: 'm'),
          executeTool: (
            String n,
            Map<String, dynamic> a,
            String? s, {
            String? browserContext,
          }) async => const ToolResult(ok: true, llmOutput: ''),
        ),
      );
      final ToolResult result = await exec.execute(
        'spawn_subagents',
        <String, dynamic>{
          'tasks': <dynamic>[
            <String, dynamic>{'label': 'First', 'prompt': 't1'},
            <String, dynamic>{'label': 'Second', 'prompt': 't2'},
          ],
        },
        sessionId: 'sess-9',
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('## First'));
      expect(result.llmOutput, contains('one'));
      expect(result.llmOutput, contains('## Second'));
      expect(result.llmOutput, contains('two'));
    });

    test('validation errors surface as failed tool results', () async {
      final ToolResult empty = await executor().execute(
        'spawn_subagents',
        <String, dynamic>{'tasks': <dynamic>[]},
      );
      expect(empty.ok, isFalse);
      expect(empty.llmOutput, contains('non-empty'));

      final ToolResult missing = await executor().execute(
        'spawn_subagents',
        <String, dynamic>{},
      );
      expect(missing.ok, isFalse);
    });

    test('aborts before spawning when Stop was already pressed', () async {
      final ToolResult result = await executor().execute(
        'spawn_subagents',
        <String, dynamic>{
          'tasks': <dynamic>[
            <String, dynamic>{'prompt': 'x'},
          ],
        },
        shouldAbort: () => true,
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('aborted'));
    });

    test('degrades gracefully without a configured runner', () async {
      final ToolExecutor bare = ToolExecutor(
        browser: ScriptedBrowserAutomation('${tempDir.path}/shots'),
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
      );
      final ToolResult result = await bare.execute(
        'spawn_subagents',
        <String, dynamic>{
          'tasks': <dynamic>[
            <String, dynamic>{'prompt': 'x'},
          ],
        },
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('unavailable'));
    });
  });

  test('the full agent toolset includes spawn_subagents once', () {
    final List<String> names = <String>[
      for (final Map<String, dynamic> tool in buildAgentTools())
        (tool['function'] as Map<String, dynamic>)['name'] as String,
    ];
    expect(names.where((String n) => n == 'spawn_subagents'), hasLength(1));
    expect(agentSystemPrompt, contains('fan of subagents'));
  });
}

/// LLM double that always requests another (harmless) tool call — drives
/// the subagent loop into its step cap.
class _EndlessToolCallLlm implements LlmClient {
  var _id = 0;

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    _id++;
    return AssistantTurn(
      content: '',
      toolCalls: <ToolCallRequest>[
        ToolCallRequest(
          id: 'e$_id',
          name: 'read_file',
          argumentsJson: jsonEncode(<String, dynamic>{'path': 'x.txt'}),
        ),
      ],
    );
  }
}
