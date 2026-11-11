import '../tools/tool_defs.dart';
import 'llm_client.dart';
import 'tool_executor.dart';

/// One parallel subagent task requested through the `spawn_subagents`
/// tool: a self-contained prompt and an optional short label used to
/// identify the result.
class SubagentTaskSpec {
  const SubagentTaskSpec({required this.label, required this.prompt});

  final String label;
  final String prompt;
}

/// Outcome of one subagent run — [answer] is the subagent's final text
/// (or an error description when [ok] is false).
class SubagentOutcome {
  const SubagentOutcome({
    required this.label,
    required this.ok,
    required this.answer,
    this.steps = 0,
    this.toolCalls = 0,
  });

  final String label;
  final bool ok;
  final String answer;
  final int steps;
  final int toolCalls;
}

/// Fan-of-subagents runner (v1.28.0, browser contexts in v1.37.0):
/// executes several INDEPENDENT agent loops in parallel, each with the
/// chat's own model + connection settings and a workspace+browser toolset,
/// and returns their final answers together.
///
/// Design constraints:
/// * NO nested `spawn_subagents` — unbounded recursion is a run-away risk.
///   The workspace toolset (files, archives, node, web_fetch, local git)
///   is safe to use concurrently because every call is already sandboxed
///   per session, and since v1.37.0 the browser tools are safe too: every
///   subagent browses in its OWN browser context (private headless WebView
///   + per-context cookie/storage identity) instead of queueing behind the
///   chat's single engine.
/// * Each subagent loop is step-capped well below the main loop's limit:
///   subagents do focused work (research, summarize, transform, write a
///   file), not open-ended sessions.
/// * Tasks run [maxParallel] at a time; results keep the input order.
class SubagentRunner {
  SubagentRunner({
    required this.llm,
    required this.resolveConfig,
    required this.executeTool,
    this.maxTasks = 6,
    this.maxSteps = 15,
    this.maxParallel = 3,
    this.maxAnswerChars = 12000,
  });

  final LlmClient llm;
  final LlmConfig Function() resolveConfig;

  /// Tool execution callback — always the CALLING session's executor, so
  /// subagents work inside the same per-chat sandbox as the main agent
  /// ([sessionId] scopes file/zip/git calls to that session's workspace).
  /// The optional [browserContext] pins a subagent's browser tools to its
  /// own parallel browser context (v1.37.0).
  final Future<ToolResult> Function(
    String name,
    Map<String, dynamic> args,
    String? sessionId, {
    String? browserContext,
  })
  executeTool;

  final int maxTasks;
  final int maxSteps;
  final int maxParallel;
  final int maxAnswerChars;

  /// Toolset a subagent may use: workspace + web fetch + local git + the
  /// browser tools (each subagent in its own browser context, v1.37.0).
  /// The list is the SINGLE source of truth for the recursion guard —
  /// `spawn_subagents` is deliberately absent.
  static const Set<String> allowedTools = <String>{
    'read_file',
    'write_file',
    'unzip_file',
    'zip_file',
    'node_run',
    'node_install',
    'node_remove',
    'web_fetch',
    'git_clone',
    'git_status',
    'git_commit',
    'git_log',
    'browser_navigate',
    'browser_click',
    'browser_type',
    'browser_scroll',
    'browser_screenshot',
    'browser_extract_text',
    'run_js',
  };

  static const String systemPrompt =
      'You are a focused subagent spawned by a parent agent. Complete the '
      'task you are given fully and autonomously: use your tools when they '
      'help, verify results, and then write a clear, self-contained final '
      'answer with the outcome (facts, data, file paths of anything you '
      'created). You cannot ask the parent questions. You have your own '
      'isolated browser context (pages, logins and storage are private to '
      'you) plus the workspace tools. Keep the final answer concise but '
      'complete.';

  /// Tool schemas for the subagent loop, filtered from the full agent set.
  List<Map<String, dynamic>> buildTools() {
    final List<Map<String, dynamic>> all = buildAgentTools();
    return <Map<String, dynamic>>[
      for (final Map<String, dynamic> tool in all)
        if (allowedTools.contains(
          (tool['function'] as Map<String, dynamic>)['name'],
        ))
          tool,
    ];
  }

  /// Parses + validates the `tasks` argument of `spawn_subagents`.
  /// Returns (specs, error) — error is non-null when the call is invalid.
  (List<SubagentTaskSpec>, String?) parseTasks(Object? rawTasks) {
    if (rawTasks is! List || rawTasks.isEmpty) {
      return (<SubagentTaskSpec>[], 'tasks must be a non-empty array');
    }
    if (rawTasks.length > maxTasks) {
      return (<SubagentTaskSpec>[], 'at most $maxTasks tasks per call');
    }
    final List<SubagentTaskSpec> specs = <SubagentTaskSpec>[];
    for (var i = 0; i < rawTasks.length; i++) {
      final Object? raw = rawTasks[i];
      if (raw is! Map<String, dynamic>) {
        return (<SubagentTaskSpec>[], 'tasks[$i] must be an object');
      }
      final String prompt = raw['prompt']?.toString().trim() ?? '';
      if (prompt.isEmpty) {
        return (<SubagentTaskSpec>[], 'tasks[$i].prompt is required');
      }
      final String label = raw['label']?.toString().trim().isNotEmpty == true
          ? raw['label'].toString().trim()
          : 'Task ${i + 1}';
      specs.add(SubagentTaskSpec(label: label, prompt: prompt));
    }
    return (specs, null);
  }

  /// Runs every task (bounded concurrency, stable result order). Each task
  /// gets its own browser context id (v1.37.0) so parallel subagents never
  /// queue behind one another in the embedded browser.
  Future<List<SubagentOutcome>> run(
    List<SubagentTaskSpec> tasks, {
    String? sessionId,
    bool Function()? shouldAbort,
  }) async {
    final String runStamp = DateTime.now().microsecondsSinceEpoch.toString();
    String contextFor(int index) => 'subagent-$runStamp-$index';
    final List<SubagentOutcome?> results = List<SubagentOutcome?>.filled(
      tasks.length,
      null,
    );
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final int index = cursor++;
        if (index >= tasks.length) return;
        results[index] = await _runOne(
          tasks[index],
          sessionId: sessionId,
          browserContext: contextFor(index),
          shouldAbort: shouldAbort,
        );
      }
    }

    await Future.wait(<Future<void>>[
      for (var w = 0; w < maxParallel && w < tasks.length; w++) worker(),
    ]);
    return <SubagentOutcome>[
      for (final SubagentOutcome? outcome in results)
        outcome ??
            SubagentOutcome(
              label: '?',
              ok: false,
              answer: 'subagent produced no result',
            ),
    ];
  }

  Future<SubagentOutcome> _runOne(
    SubagentTaskSpec task, {
    String? sessionId,
    String? browserContext,
    bool Function()? shouldAbort,
  }) async {
    final LlmConfig config = resolveConfig();
    final List<Map<String, dynamic>> tools = buildTools();
    final List<Map<String, dynamic>> wire = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': systemPrompt},
      <String, dynamic>{'role': 'user', 'content': task.prompt},
    ];
    var steps = 0;
    var toolCalls = 0;
    try {
      for (var step = 0; step < maxSteps; step++) {
        if (shouldAbort?.call() ?? false) {
          return SubagentOutcome(
            label: task.label,
            ok: false,
            answer: 'aborted by the user',
            steps: steps,
            toolCalls: toolCalls,
          );
        }
        final AssistantTurn turn = await llm.complete(
          config: config,
          messages: wire,
          tools: tools,
        );
        steps++;
        if (turn.toolCalls.isEmpty) {
          return SubagentOutcome(
            label: task.label,
            ok: true,
            answer: _cap(turn.content.trim()),
            steps: steps,
            toolCalls: toolCalls,
          );
        }
        wire.add(<String, dynamic>{
          'role': 'assistant',
          if (turn.content.isNotEmpty) 'content': turn.content,
          'tool_calls': <Map<String, dynamic>>[
            for (final ToolCallRequest tc in turn.toolCalls)
              <String, dynamic>{
                'id': tc.id,
                'type': 'function',
                'function': <String, dynamic>{
                  'name': tc.name,
                  'arguments': tc.argumentsJson,
                },
              },
          ],
        });
        for (final ToolCallRequest tc in turn.toolCalls) {
          toolCalls++;
          if (!allowedTools.contains(tc.name)) {
            wire.add(<String, dynamic>{
              'role': 'tool',
              'tool_call_id': tc.id,
              'content':
                  'Tool "${tc.name}" is not available to subagents '
                  '(nested subagents are excluded). Use the workspace, '
                  'web_fetch or browser tools instead.',
            });
            continue;
          }
          final ToolResult result = await executeTool(
            tc.name,
            tc.args,
            sessionId,
            browserContext: browserContext,
          );
          wire.add(<String, dynamic>{
            'role': 'tool',
            'tool_call_id': tc.id,
            'content': result.llmOutput,
          });
        }
      }
      return SubagentOutcome(
        label: task.label,
        ok: false,
        answer:
            'reached the $maxSteps-step limit without a final answer '
            '(last partial output: ${_cap(wire.isEmpty ? '' : _lastAssistantText(wire))})',
        steps: steps,
        toolCalls: toolCalls,
      );
    } on LlmAbortedException {
      return SubagentOutcome(
        label: task.label,
        ok: false,
        answer: 'aborted by the user',
        steps: steps,
        toolCalls: toolCalls,
      );
    } catch (e) {
      return SubagentOutcome(
        label: task.label,
        ok: false,
        answer: 'subagent failed: $e',
        steps: steps,
        toolCalls: toolCalls,
      );
    }
  }

  String _lastAssistantText(List<Map<String, dynamic>> wire) {
    for (final Map<String, dynamic> message in wire.reversed) {
      if (message['role'] == 'assistant') {
        return message['content']?.toString() ?? '';
      }
    }
    return '';
  }

  String _cap(String text) => text.length <= maxAnswerChars
      ? text
      : '${text.substring(0, maxAnswerChars)}…[truncated]';

  /// Formats the outcomes as the tool's llmOutput.
  String formatOutcomes(List<SubagentOutcome> outcomes) {
    final StringBuffer buffer = StringBuffer();
    for (final SubagentOutcome outcome in outcomes) {
      buffer
        ..writeln('## ${outcome.label}')
        ..writeln(outcome.answer)
        ..writeln(
          '_(steps: ${outcome.steps}, tool calls: ${outcome.toolCalls})_',
        )
        ..writeln();
    }
    return buffer.toString().trim();
  }
}
