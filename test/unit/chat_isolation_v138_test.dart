import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/skill_registry.dart';
import 'package:noah/services/tool_executor.dart';

import '../support/test_doubles.dart';

/// v1.38.0 regressions: cross-chat isolation while parallel tasks run,
/// streaming message-id stability (Plan panel + rebuild contract), and
/// the request_confirmation approval flow.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_v138_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<ProviderContainer> containerWith(
    LlmClient llm, {
    AppSettings? settings,
    List<Override> extra = const <Override>[],
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: llm,
          dir: tempDir,
          settings: settings ?? AppSettings(apiKey: 'k', autoTitle: false),
        ),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'streaming keeps ONE stable message id across deltas and finalize',
    () async {
      // A long answer streamed word by word: every throttled sync used to
      // mint a fresh id (ValueKey churn, subtree teardown, panel state
      // loss).
      late ProviderContainer container;
      final List<String> ids = <String>[];
      final ScriptedLlmClient llm = ScriptedLlmClient(
        <AssistantTurn>[
          AssistantTurn(
            content:
                'alpha beta gamma delta epsilon zeta eta theta iota kappa '
                'lambda mu nu xi omicron pi rho sigma tau upsilon phi chi '
                'psi omega end',
          ),
        ],
        onFirstDelta: () {
          ids.add(container.read(chatControllerProvider).messages.last.id);
        },
      );

      container = await containerWith(llm);
      await container.read(chatControllerProvider.notifier).send('hello');
      final ChatState state = container.read(chatControllerProvider);
      expect(state.isRunning, isFalse);

      // Deltas fired at least once (long content) — every observed id,
      // plus the finalized message, is THE SAME identity.
      expect(ids, isNotEmpty);
      expect(
        state.messages.last.id,
        ids.first,
        reason: 'finalize must not re-mint the streaming message id',
      );
      expect(
        state.messages.map((ChatMessage m) => m.id).toSet().length,
        state.messages.length,
        reason: 'no duplicate ids in the transcript',
      );
    },
  );

  test(
    'a background session never leaks its output into the displayed chat',
    () async {
      final List<Completer<AssistantTurn>> gates =
          List<Completer<AssistantTurn>>.generate(
            2,
            (_) => Completer<AssistantTurn>(),
          );
      int turn = 0;
      final _GatedLlmClient llm = _GatedLlmClient(gates, () => turn++);
      final ProviderContainer container = await containerWith(llm);

      final Future<void> runA = container
          .read(chatControllerProvider.notifier)
          .send('task A');
      await Future<void>.delayed(Duration.zero);
      final String idA = container.read(chatControllerProvider).sessionId!;

      // Switch away while A is parked mid-turn: A becomes a background
      // run and B becomes the displayed chat.
      await container.read(chatControllerProvider.notifier).newChat();
      final Future<void> runB = container
          .read(chatControllerProvider.notifier)
          .send('task B');
      await Future<void>.delayed(Duration.zero);
      final String idB = container.read(chatControllerProvider).sessionId!;
      expect(idB, isNot(idA));

      // A's answer lands while B is on screen — it must reach A's OWN
      // transcript and never B's UI state.
      gates[0].complete(
        AssistantTurn(content: 'SECRET-ANSWER-A only for chat A'),
      );
      await runA;

      final ChatState state = container.read(chatControllerProvider);
      expect(state.sessionId, idB);
      expect(
        state.messages.map((ChatMessage m) => m.content).join('\n'),
        isNot(contains('SECRET-ANSWER-A')),
      );

      // A's transcript (persisted by the background run) has the answer.
      final List<ChatMessage> aMessages = (await container
          .read(chatStoreProvider)
          .load(idA))!;
      expect(
        aMessages.map((ChatMessage m) => m.content).join('\n'),
        contains('SECRET-ANSWER-A'),
      );

      gates[1].complete(AssistantTurn(content: 'B answer'));
      await runB;
      expect(
        container.read(chatControllerProvider).messages.last.content,
        'B answer',
      );
    },
  );

  group('request_confirmation', () {
    ToolCallRequest confirmCall(String id) => ToolCallRequest(
      id: id,
      name: 'request_confirmation',
      argumentsJson: jsonEncode(<String, dynamic>{
        'title': 'Send 0.05 ETH',
        'details': <String>[
          'network: ethereum',
          'asset: 0.05 ETH (~120 USD)',
          'to: 0xABC...DEF',
          'estimated fee: 0.0007 ETH',
        ],
        'danger': true,
      }),
    );

    test(
      'approve unblocks the run and reports APPROVED to the model',
      () async {
        final ProviderContainer container = await containerWith(
          ScriptedLlmClient(<AssistantTurn>[
            AssistantTurn(
              content: '',
              toolCalls: <ToolCallRequest>[confirmCall('c1')],
            ),
            AssistantTurn(content: 'done'),
          ]),
        );
        final Future<void> run = container
            .read(chatControllerProvider.notifier)
            .send('swap please');
        await Future<void>.delayed(Duration.zero);

        final ChatState pending = container.read(chatControllerProvider);
        expect(pending.pendingConfirmation, isNotNull);
        expect(pending.pendingConfirmation!.title, 'Send 0.05 ETH');
        expect(pending.pendingConfirmation!.danger, isTrue);
        expect(pending.pendingConfirmation!.details, hasLength(4));
        expect(
          pending.isRunning,
          isTrue,
          reason: 'the loop is parked waiting for the user',
        );

        container
            .read(chatControllerProvider.notifier)
            .resolveConfirmation('c1', true);
        await run;

        final ChatState state = container.read(chatControllerProvider);
        expect(state.pendingConfirmation, isNull);
        expect(state.isRunning, isFalse);
        final ChatMessage toolTurn = state.messages.firstWhere(
          (ChatMessage m) => m.toolCalls.isNotEmpty,
        );
        expect(
          toolTurn.toolCalls.single.resultText,
          contains('APPROVED by the user'),
        );
        expect(state.messages.last.content, 'done');
      },
    );

    test(
      'deny reports DENIED and the loop continues without the action',
      () async {
        final ProviderContainer container = await containerWith(
          ScriptedLlmClient(<AssistantTurn>[
            AssistantTurn(
              content: '',
              toolCalls: <ToolCallRequest>[confirmCall('c2')],
            ),
            AssistantTurn(content: 'understood, not sending'),
          ]),
        );
        final Future<void> run = container
            .read(chatControllerProvider.notifier)
            .send('send it');
        await Future<void>.delayed(Duration.zero);
        container
            .read(chatControllerProvider.notifier)
            .resolveConfirmation('c2', false);
        await run;

        final ChatState state = container.read(chatControllerProvider);
        expect(
          state.messages
              .firstWhere((ChatMessage m) => m.toolCalls.isNotEmpty)
              .toolCalls
              .single
              .resultText,
          contains('DENIED by the user'),
        );
        expect(state.messages.last.content, 'understood, not sending');
      },
    );

    test('Stop while the prompt is open fails closed (deny + stop)', () async {
      final ProviderContainer container = await containerWith(
        ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[confirmCall('c3')],
          ),
        ]),
      );
      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('transfer');
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(chatControllerProvider).pendingConfirmation,
        isNotNull,
      );
      container.read(chatControllerProvider.notifier).stop();
      await run;

      final ChatState state = container.read(chatControllerProvider);
      expect(state.pendingConfirmation, isNull);
      expect(
        state.messages
            .firstWhere((ChatMessage m) => m.toolCalls.isNotEmpty)
            .toolCalls
            .single
            .resultText,
        contains('DENIED by the user'),
      );
    });

    test('background session cannot raise a prompt (fails closed with '
        'guidance)', () async {
      // Turn order: A#1 (confirmation call), B#1, A#2 (final).
      final List<Completer<AssistantTurn>> gates =
          List<Completer<AssistantTurn>>.generate(
            3,
            (_) => Completer<AssistantTurn>(),
          );
      int turn = 0;
      final _GatedLlmClient llm = _GatedLlmClient(gates, () => turn++);
      final ProviderContainer container = await containerWith(llm);

      final Future<void> runA = container
          .read(chatControllerProvider.notifier)
          .send('A asks approval');
      await Future<void>.delayed(Duration.zero);
      final String idA = container.read(chatControllerProvider).sessionId!;

      // Switch away; A becomes a background run.
      await container.read(chatControllerProvider.notifier).newChat();
      final Future<void> runB = container
          .read(chatControllerProvider.notifier)
          .send('B task');
      await Future<void>.delayed(Duration.zero);

      // A's tool turn completes while B is displayed.
      gates[0].complete(
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[confirmCall('c4')],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // No prompt may surface, and B's state stays clean.
      expect(
        container.read(chatControllerProvider).pendingConfirmation,
        isNull,
      );
      expect(container.read(chatControllerProvider).sessionId, isNot(idA));

      // A's loop gets its continuation and finishes without the action.
      gates[2].complete(AssistantTurn(content: 'A finished without action'));
      await runA;
      gates[1].complete(AssistantTurn(content: 'B answer'));
      await runB;

      final List<ChatMessage> aMessages = (await container
          .read(chatStoreProvider)
          .load(idA))!;
      final ChatMessage aToolTurn = aMessages.firstWhere(
        (ChatMessage m) => m.toolCalls.isNotEmpty,
      );
      expect(aToolTurn.toolCalls.single.resultText, contains('not on screen'));
    });

    test('a denial is a FAILED tool call, not a green check', () async {
      final ProviderContainer container = await containerWith(
        ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[confirmCall('c5')],
          ),
          AssistantTurn(content: 'understood'),
        ]),
      );
      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('send it');
      await Future<void>.delayed(Duration.zero);
      container
          .read(chatControllerProvider.notifier)
          .resolveConfirmation('c5', false);
      await run;

      final ToolCall call = container
          .read(chatControllerProvider)
          .messages
          .firstWhere((ChatMessage m) => m.toolCalls.isNotEmpty)
          .toolCalls
          .single;
      expect(
        call.status,
        ToolStatus.error,
        reason:
            'the user refused the action; the transcript must not show '
            'a success check for it',
      );
      expect(call.resultText, contains('DENIED'));
    });

    test('details accepts a bare string from the model', () async {
      final ProviderContainer container = await containerWith(
        ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'c6',
                name: 'request_confirmation',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'title': 'Send 1 BNB',
                  'details': 'network: bsc, to: 0xabc, amount: 1 BNB',
                }),
              ),
            ],
          ),
          AssistantTurn(content: 'done'),
        ]),
      );
      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('go');
      await Future<void>.delayed(Duration.zero);

      final ConfirmationRequest pending = container
          .read(chatControllerProvider)
          .pendingConfirmation!;
      expect(pending.details, <String>[
        'network: bsc, to: 0xabc, amount: 1 BNB',
      ]);
      expect(pending.danger, isTrue, reason: 'danger defaults to true');

      container
          .read(chatControllerProvider.notifier)
          .resolveConfirmation('c6', true);
      await run;
      expect(
        container.read(chatControllerProvider).messages.last.content,
        'done',
      );
    });

    test('skill_install is gated on approval and a denial never reaches '
        'the executor', () async {
      final _RecordingExecutor executor = _RecordingExecutor(tempDir);
      final ProviderContainer container = await containerWith(
        ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'c7',
                name: 'skill_install',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'source':
                      'binance/binance-skills-hub/skills/'
                      'binance-web3/binance-agentic-wallet',
                }),
              ),
            ],
          ),
          AssistantTurn(content: 'install declined, not retrying'),
        ]),
        extra: <Override>[toolExecutorProvider.overrideWithValue(executor)],
      );
      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('install the binance wallet skill');
      await Future<void>.delayed(Duration.zero);

      final ConfirmationRequest pending = container
          .read(chatControllerProvider)
          .pendingConfirmation!;
      expect(pending.title, contains('Install'));
      expect(
        pending.details.join('\n'),
        contains('binance/binance-skills-hub'),
        reason:
            'the user must see the source before third-party code is '
            'downloaded',
      );
      expect(
        executor.executed,
        isEmpty,
        reason: 'nothing may be downloaded before the user approves',
      );

      container
          .read(chatControllerProvider.notifier)
          .resolveConfirmation('install:c7', false);
      await run;

      expect(executor.executed, isEmpty);
      final ToolCall call = container
          .read(chatControllerProvider)
          .messages
          .firstWhere((ChatMessage m) => m.toolCalls.isNotEmpty)
          .toolCalls
          .single;
      expect(call.status, ToolStatus.error);
      expect(call.resultText, contains('declined'));
    });

    test('an approved skill_install reaches the executor', () async {
      final _RecordingExecutor executor = _RecordingExecutor(tempDir);
      final ProviderContainer container = await containerWith(
        ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'c8',
                name: 'skill_install',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'source': 'owner/repo',
                }),
              ),
            ],
          ),
          AssistantTurn(content: 'installed'),
        ]),
        extra: <Override>[toolExecutorProvider.overrideWithValue(executor)],
      );
      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('install it');
      await Future<void>.delayed(Duration.zero);
      container
          .read(chatControllerProvider.notifier)
          .resolveConfirmation('install:c8', true);
      await run;

      expect(executor.executed, <String>['skill_install']);
      expect(
        container
            .read(chatControllerProvider)
            .messages
            .firstWhere((ChatMessage m) => m.toolCalls.isNotEmpty)
            .toolCalls
            .single
            .status,
        ToolStatus.success,
      );
    });

    test('Stop between approval and execution prevents the action', () async {
      final _RecordingExecutor executor = _RecordingExecutor(tempDir);
      final ProviderContainer container = await containerWith(
        ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'c11',
                name: 'skill_install',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'source': 'owner/repo',
                }),
              ),
            ],
          ),
          AssistantTurn(content: 'stopped'),
        ]),
        extra: <Override>[toolExecutorProvider.overrideWithValue(executor)],
      );
      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('install it');
      await Future<void>.delayed(Duration.zero);

      final ChatController notifier = container.read(
        chatControllerProvider.notifier,
      );
      // Approve, then Stop in the SAME synchronous block: the loop resumes
      // on a later microtask, so this is exactly the window in which the
      // action used to run anyway.
      notifier.resolveConfirmation('install:c11', true);
      notifier.stop();
      await run;

      expect(
        executor.executed,
        isEmpty,
        reason: 'a stopped chat must never install/execute after approval',
      );
      final ToolCall call = container
          .read(chatControllerProvider)
          .messages
          .firstWhere((ChatMessage m) => m.toolCalls.isNotEmpty)
          .toolCalls
          .single;
      expect(call.status, ToolStatus.error);
      expect(call.resultText, contains('NOT performed'));
    });

    test('skill_run on a wallet skill is gated: a denial never reaches the '
        'executor and the call is reported as failed', () async {
      final SkillRegistry registry = SkillRegistry(
        resolveBaseDir: () async => tempDir,
      );
      await registry.installBundled(
        bundledName: 'wallet-skill',
        skillMd: _walletSkillMd,
      );
      final _RecordingExecutor executor = _RecordingExecutor(tempDir);
      final ProviderContainer container = await containerWith(
        ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'c9',
                name: 'skill_run',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'name': 'wallet-skill',
                  'script': 'scripts/send.js',
                }),
              ),
            ],
          ),
          AssistantTurn(content: 'denied, nothing sent'),
        ]),
        extra: <Override>[
          toolExecutorProvider.overrideWithValue(executor),
          skillRegistryProvider.overrideWithValue(registry),
        ],
      );
      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('send 1 BNB');
      await Future<void>.delayed(Duration.zero);

      final ConfirmationRequest pending = container
          .read(chatControllerProvider)
          .pendingConfirmation!;
      expect(pending.title, contains('wallet'));
      expect(
        pending.details.join('\n'),
        allOf(contains('wallet-skill'), contains('scripts/send.js')),
        reason: 'the user must see WHICH value-moving script will run',
      );
      expect(
        executor.executed,
        isEmpty,
        reason: 'a value-moving script must not start before approval',
      );

      container
          .read(chatControllerProvider.notifier)
          .resolveConfirmation('wallet:c9', false);
      await run;

      expect(executor.executed, isEmpty);
      final ToolCall call = container
          .read(chatControllerProvider)
          .messages
          .firstWhere((ChatMessage m) => m.toolCalls.isNotEmpty)
          .toolCalls
          .single;
      expect(call.status, ToolStatus.error);
      expect(call.resultText, contains('DENIED'));
    });

    test(
      'skill_run on a non-wallet skill runs without an approval prompt',
      () async {
        final SkillRegistry registry = SkillRegistry(
          resolveBaseDir: () async => tempDir,
        );
        await registry.installBundled(
          bundledName: 'readonly-skill',
          skillMd: _readonlySkillMd,
        );
        final _RecordingExecutor executor = _RecordingExecutor(tempDir);
        final ProviderContainer container = await containerWith(
          ScriptedLlmClient(<AssistantTurn>[
            AssistantTurn(
              content: '',
              toolCalls: <ToolCallRequest>[
                ToolCallRequest(
                  id: 'c10',
                  name: 'skill_run',
                  argumentsJson: jsonEncode(<String, dynamic>{
                    'name': 'readonly-skill',
                    'script': 'scripts/report.js',
                  }),
                ),
              ],
            ),
            AssistantTurn(content: 'done'),
          ]),
          extra: <Override>[
            toolExecutorProvider.overrideWithValue(executor),
            skillRegistryProvider.overrideWithValue(registry),
          ],
        );

        await container.read(chatControllerProvider.notifier).send('report');

        expect(
          container.read(chatControllerProvider).pendingConfirmation,
          isNull,
          reason: 'read-only skills must stay frictionless',
        );
        expect(executor.executed, <String>['skill_run']);
      },
    );
  });
}

const String _walletSkillMd = '''
---
name: wallet-skill
title: Wallet Skill
description: Moves value on-chain.
version: "1.0"
wallet: true
permissions:
  - network
---

# Wallet Skill

Every asset-moving action requires explicit user confirmation.
''';

const String _readonlySkillMd = '''
---
name: readonly-skill
title: Read-only Skill
description: Produces a report.
version: "1.0"
permissions:
  - network
---

# Read-only Skill

Reports only; never moves value.
''';

/// ToolExecutor double: records the tool names the controller hands to the
/// executor so approval gates can be asserted without touching the network
/// or the filesystem.
class _RecordingExecutor extends ToolExecutor {
  _RecordingExecutor(Directory dir)
    : super(
        browser: ScriptedBrowserAutomation(dir.path, writeScreenshot: false),
        resolveBaseDir: (String? _) async => dir,
        isAutomationEnabled: () => false,
      );

  final List<String> executed = <String>[];

  @override
  Future<ToolResult> execute(
    String name,
    Map<String, dynamic> args, {
    String? sessionId,
    String? browserContext,
    bool Function()? shouldAbort,
  }) async {
    executed.add(name);
    return ToolResult(ok: true, llmOutput: 'EXECUTED $name');
  }
}

/// Gated LLM client (local copy so suites stay independent): turn N
/// resolves through gates[N], handed out in call order.
class _GatedLlmClient implements LlmClient {
  _GatedLlmClient(this.gates, this.nextTurn);

  final List<Completer<AssistantTurn>> gates;
  final int Function() nextTurn;

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    final AssistantTurn turn = await gates[nextTurn()].future;
    return turn;
  }
}
