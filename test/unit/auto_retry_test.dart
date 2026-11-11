import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/device_shell.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// LLM double that throws a scripted error for the first [failures] calls
/// and then serves [turns] (last turn repeats). Records call count.
class _FlakyLlmClient implements LlmClient {
  _FlakyLlmClient(this.failures, this.turns, {this.errorBuilder});

  final int failures;
  final List<AssistantTurn> turns;
  final Object Function()? errorBuilder;

  int calls = 0;
  int _served = 0;

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    if (shouldAbort?.call() ?? false) {
      throw const LlmAbortedException('');
    }
    calls++;
    if (calls <= failures) {
      final Object error =
          errorBuilder?.call() ??
          LlmException('Could not connect to provider: network unreachable');
      throw error;
    }
    final AssistantTurn turn =
        turns[_served < turns.length - 1 ? _served++ : turns.length - 1];
    onDelta?.call(turn.content);
    return turn;
  }
}

Future<ProviderContainer> _container(
  LlmClient llm,
  Directory dir,
  AppSettings settings,
) async {
  final ProviderContainer container = ProviderContainer(
    overrides: testOverrides(llm: llm, dir: dir, settings: settings),
  );
  addTearDown(container.dispose);
  return container;
}

/// Scripted `zagents/device` invoker: answers only the airplane probe,
/// handing out the given sequence (last value repeats). Used to simulate
/// the manual airplane window opening/closing around retry attempts.
class _ScriptedAirplane {
  _ScriptedAirplane(this.answers);

  final List<bool?> answers;
  int index = 0;

  Future<Object?> call(String method, Map<String, Object?> args) async {
    if (method != 'getAirplaneMode') {
      throw MissingPluginException('not scripted: $method');
    }
    if (index >= answers.length) {
      return answers.isEmpty ? null : answers.last;
    }
    return answers[index++];
  }
}

Future<ProviderContainer> _airplaneContainer(
  LlmClient llm,
  Directory dir,
  AppSettings settings,
  List<bool?> probes,
) async {
  final _ScriptedAirplane airplane = _ScriptedAirplane(probes);
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      ...testOverrides(llm: llm, dir: dir, settings: settings),
      deviceShellServiceProvider.overrideWithValue(
        DeviceShellService(invoker: airplane.call),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

AppSettings _retrySettings({
  bool enabled = true,
  int attempts = 3,
  int delay = 0,
  bool planFirst = false,
  int maxSteps = defaultMaxSteps,
  bool runUntilDone = false,
}) => AppSettings(
  apiKey: 'test-key',
  autoTitle: false,
  autoRetryEnabled: enabled,
  autoRetryAttempts: attempts,
  autoRetryDelay: delay,
  planFirst: planFirst,
  maxSteps: maxSteps,
  runUntilDone: runUntilDone,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_retry_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('isRetryableLlmError classification', () {
    test('transient HTTP statuses are retryable', () {
      for (final int code in <int>[408, 425, 429, 500, 502, 503, 504, 529]) {
        expect(
          isRetryableLlmError(LlmException('HTTP $code: x', statusCode: code)),
          isTrue,
          reason: 'HTTP $code should be retryable',
        );
      }
    });

    test('permanent HTTP statuses are NOT retryable', () {
      for (final int code in <int>[400, 401, 403, 404, 422]) {
        expect(
          isRetryableLlmError(LlmException('HTTP $code: x', statusCode: code)),
          isFalse,
          reason: 'HTTP $code must not be retried',
        );
      }
    });

    test('transport failures are retryable', () {
      expect(
        isRetryableLlmError(
          LlmException('Could not connect to provider: boom'),
        ),
        isTrue,
      );
      expect(
        isRetryableLlmError(
          LlmException('Connection lost while streaming: socket cut'),
        ),
        isTrue,
      );
      expect(isRetryableLlmError(const SocketException('down')), isTrue);
      expect(isRetryableLlmError(TimeoutException('timed out')), isTrue);
    });

    test('Stop and unknown errors are never retried', () {
      expect(isRetryableLlmError(const LlmAbortedException('')), isFalse);
      expect(
        isRetryableLlmError(LlmException('Unknown response format: {}')),
        isFalse,
      );
      expect(isRetryableLlmError(Exception('anything')), isFalse);
      expect(isRetryableLlmError(null), isFalse);
    });
  });

  group('per-call auto retry (v1.30.0)', () {
    test('a retryable failure is re-attempted and the run completes', () async {
      final _FlakyLlmClient llm = _FlakyLlmClient(2, <AssistantTurn>[
        AssistantTurn(content: 'recovered answer'),
      ]);
      final ProviderContainer container = await _container(
        llm,
        tempDir,
        _retrySettings(),
      );

      await container.read(chatControllerProvider.notifier).send('hello');
      final ChatState state = container.read(chatControllerProvider);

      expect(state.isRunning, isFalse);
      expect(state.error, isNull);
      expect(llm.calls, 3); // 2 failures + 1 success
      expect(state.messages.last.content, 'recovered answer');
      // The retry notes were replaced by the real answer — nothing
      // mentioning "reconnecting" survives in the transcript.
      expect(state.messages.every((ChatMessage m) => !m.isStreaming), isTrue);
      expect(
        state.messages
            .where((ChatMessage m) => m.role == Role.assistant)
            .every((ChatMessage m) => !m.content.contains('reconnecting')),
        isTrue,
      );
    });

    test(
      'exhausted retries surface the error and finalize the stream',
      () async {
        final _FlakyLlmClient llm = _FlakyLlmClient(
          99,
          <AssistantTurn>[AssistantTurn(content: 'never')],
          errorBuilder: () =>
              LlmException('Could not connect to provider: offline'),
        );
        final ProviderContainer container = await _container(
          llm,
          tempDir,
          _retrySettings(attempts: 2),
        );

        await container.read(chatControllerProvider.notifier).send('hello');
        final ChatState state = container.read(chatControllerProvider);

        expect(state.isRunning, isFalse);
        expect(state.error, isNotNull);
        expect(llm.calls, greaterThanOrEqualTo(2));
        // No eternal "thinking" placeholder is left behind.
        expect(state.messages.every((ChatMessage m) => !m.isStreaming), isTrue);
      },
    );

    test('permanent (non-retryable) errors fail fast — single call', () async {
      final _FlakyLlmClient llm = _FlakyLlmClient(
        99,
        <AssistantTurn>[AssistantTurn(content: 'never')],
        errorBuilder: () => LlmException('HTTP 401: bad key', statusCode: 401),
      );
      final ProviderContainer container = await _container(
        llm,
        tempDir,
        _retrySettings(attempts: 3),
      );

      await container.read(chatControllerProvider.notifier).send('hello');
      final ChatState state = container.read(chatControllerProvider);

      expect(state.error, isNotNull);
      expect(llm.calls, 1); // no retries burned on a 401
    });

    test('retry is disabled when the setting is off', () async {
      final _FlakyLlmClient llm = _FlakyLlmClient(99, <AssistantTurn>[
        AssistantTurn(content: 'never'),
      ]);
      final ProviderContainer container = await _container(
        llm,
        tempDir,
        _retrySettings(enabled: false),
      );

      await container.read(chatControllerProvider.notifier).send('hello');
      final ChatState state = container.read(chatControllerProvider);

      expect(state.error, isNotNull);
      expect(llm.calls, 1);
    });
  });

  group('run-level auto retry (v1.30.0)', () {
    test('an interrupted run is resumed with a visible note', () async {
      // attempts=2: the FIRST _runLoop burns both per-call attempts and
      // dies; the run-level resume then gets a successful turn.
      final _FlakyLlmClient llm = _FlakyLlmClient(2, <AssistantTurn>[
        AssistantTurn(content: 'task finished after retry'),
      ]);
      final ProviderContainer container = await _container(
        llm,
        tempDir,
        _retrySettings(attempts: 2),
      );

      await container.read(chatControllerProvider.notifier).send('do work');
      final ChatState state = container.read(chatControllerProvider);

      expect(state.isRunning, isFalse);
      expect(state.error, isNull);
      expect(state.messages.last.content, 'task finished after retry');
      final AppStrings en = appStringsFor('en');
      expect(
        state.messages.any(
          (ChatMessage m) => m.content == en.autoRetryResumeNote(1, 2),
        ),
        isTrue,
        reason: 'the transcript should explain the automatic resume',
      );
    });

    test('an unfinished plan is picked back up automatically', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 't1',
              name: 'todo_write',
              argumentsJson: jsonEncode(<String, dynamic>{
                'todos': <Map<String, dynamic>>[
                  <String, dynamic>{'content': 'step one', 'status': 'done'},
                  <String, dynamic>{'content': 'step two', 'status': 'pending'},
                ],
              }),
            ),
          ],
        ),
        // Premature final answer while a todo is still pending.
        AssistantTurn(content: 'I think I am done early.'),
      ]);
      final ProviderContainer container = await _container(
        llm,
        tempDir,
        _retrySettings(attempts: 1, planFirst: true, maxSteps: 2),
      );

      await container.read(chatControllerProvider.notifier).send('do work');
      final ChatState state = container.read(chatControllerProvider);

      expect(state.isRunning, isFalse);
      expect(state.error, isNull);
      final AppStrings en = appStringsFor('en');
      expect(
        state.messages.any(
          (ChatMessage m) => m.content == en.autoRetryPlanNote(1, 1),
        ),
        isTrue,
        reason: 'the stalled plan should trigger an automatic resume note',
      );
    });
  });

  group('airplane-aware auto retry (v1.32.0)', () {
    setUp(() {
      ChatController.airplanePollInterval = Duration.zero;
    });

    tearDown(() {
      ChatController.airplanePollInterval = const Duration(seconds: 2);
      ChatController.airplaneWaitCap = const Duration(minutes: 10);
    });

    test(
      'an airplane-ON failure HOLDS without burning the attempt budget',
      () async {
        // attempts=1: the plain v1.30.0 loop would exhaust on the first
        // failure. With airplane mode ON the hold passes the failure
        // through WITHOUT consuming an attempt, so the retry succeeds.
        final _FlakyLlmClient llm = _FlakyLlmClient(1, <AssistantTurn>[
          AssistantTurn(content: 'continued after airplane'),
        ]);
        final ProviderContainer container = await _airplaneContainer(
          llm,
          tempDir,
          _retrySettings(attempts: 1),
          <bool?>[true], // every probe reports airplane ON
        );

        await container.read(chatControllerProvider.notifier).send('hello');
        final ChatState state = container.read(chatControllerProvider);

        expect(state.isRunning, isFalse);
        expect(state.error, isNull, reason: state.error);
        expect(llm.calls, 2); // failure + post-hold retry
        expect(state.messages.last.content, 'continued after airplane');
      },
    );

    test('airplane OFF keeps the plain v1.30.0 accounting', () async {
      final _FlakyLlmClient llm = _FlakyLlmClient(99, <AssistantTurn>[
        AssistantTurn(content: 'never'),
      ]);
      final AppStrings en = appStringsFor('en');
      final ProviderContainer container = await _airplaneContainer(
        llm,
        tempDir,
        _retrySettings(attempts: 1),
        <bool?>[false], // airplane OFF → no hold
      );

      await container.read(chatControllerProvider.notifier).send('hello');
      final ChatState state = container.read(chatControllerProvider);

      expect(state.error, isNotNull);
      // One per-call failure + the single v1.30.0 run-level resume; the
      // airplane note must NEVER appear when the radio is off.
      expect(llm.calls, 2);
      expect(
        state.messages.any(
          (ChatMessage m) => m.content == en.autoRetryAirplaneResumeNote,
        ),
        isFalse,
      );
    });

    test(
      'an unanswerable probe never holds (tests / non-Android keep v1.30.0)',
      () async {
        final _FlakyLlmClient llm = _FlakyLlmClient(99, <AssistantTurn>[
          AssistantTurn(content: 'never'),
        ]);
        final AppStrings en = appStringsFor('en');
        final ProviderContainer container = await _airplaneContainer(
          llm,
          tempDir,
          _retrySettings(attempts: 1),
          <bool?>[null], // probe cannot answer
        );

        await container.read(chatControllerProvider.notifier).send('hello');
        final ChatState state = container.read(chatControllerProvider);

        expect(state.error, isNotNull);
        expect(llm.calls, 2);
        expect(
          state.messages.any(
            (ChatMessage m) => m.content == en.autoRetryAirplaneResumeNote,
          ),
          isFalse,
        );
      },
    );

    test(
      'run-level hold adds the airplane note and resumes the task',
      () async {
        // Probe script: the stream-level checks see airplane OFF (both
        // per-call attempts burn), the RUN-level check then sees it ON —
        // the manual airplane window opened right after the stream gave
        // up. The hold must add the airplane note and resume without
        // consuming the resume budget.
        final _FlakyLlmClient llm = _FlakyLlmClient(2, <AssistantTurn>[
          AssistantTurn(content: 'resumed after the radio came back'),
        ]);
        final ProviderContainer container = await _airplaneContainer(
          llm,
          tempDir,
          _retrySettings(attempts: 2),
          <bool?>[false, false, true],
        );

        await container.read(chatControllerProvider.notifier).send('hello');
        final ChatState state = container.read(chatControllerProvider);

        expect(state.isRunning, isFalse);
        expect(state.error, isNull, reason: state.error);
        final AppStrings en = appStringsFor('en');
        expect(
          state.messages.any(
            (ChatMessage m) => m.content == en.autoRetryAirplaneResumeNote,
          ),
          isTrue,
          reason: 'the transcript should explain the airplane hold',
        );
        expect(
          state.messages.any(
            (ChatMessage m) => m.content == en.autoRetryResumeNote(1, 2),
          ),
          isTrue,
          reason: 'the resume note must still appear after the hold',
        );
        expect(
          state.messages.last.content,
          'resumed after the radio came back',
        );
      },
    );

    test('Stop during the airplane hold aborts instantly', () async {
      ChatController.airplanePollInterval = const Duration(milliseconds: 10);
      ChatController.airplaneWaitCap = const Duration(milliseconds: 80);
      final _FlakyLlmClient llm = _FlakyLlmClient(99, <AssistantTurn>[
        AssistantTurn(content: 'never'),
      ]);
      final ProviderContainer container = await _airplaneContainer(
        llm,
        tempDir,
        _retrySettings(attempts: 3, delay: 60),
        <bool?>[true],
      );
      // Press Stop a moment after the first failure — while the hold is
      // polling. The wait must abort instead of retrying.
      Timer(const Duration(milliseconds: 25), () {
        container.read(chatControllerProvider.notifier).stop();
      });

      await container.read(chatControllerProvider.notifier).send('hello');
      final ChatState state = container.read(chatControllerProvider);

      expect(state.isRunning, isFalse);
      expect(state.error, isNull, reason: 'Stop must win over the hold');
      expect(llm.calls, 1, reason: 'no retry may start after Stop');
    });
  });

  group('auto retry settings', () {
    test('round-trips through JSON and clamps out-of-range values', () {
      final AppSettings base = AppSettings(
        apiKey: 'k',
        autoRetryEnabled: false,
        autoRetryAttempts: 7,
        autoRetryDelay: 12,
      );
      final AppSettings restored = AppSettings.fromJson(base.toJson());
      expect(restored.autoRetryEnabled, isFalse);
      expect(restored.autoRetryAttempts, 7);
      expect(restored.autoRetryDelay, 12);

      // Defaults when the keys are missing (older backups).
      final AppSettings legacy = AppSettings.fromJson(<String, dynamic>{});
      expect(legacy.autoRetryEnabled, isTrue);
      expect(legacy.autoRetryAttempts, defaultAutoRetryAttempts);
      expect(legacy.autoRetryDelay, defaultAutoRetryDelay);

      // Clamping on the way in — copyWith and fromJson (the constructor
      // stores raw values, the same contract as maxSteps).
      expect(
        AppSettings(apiKey: 'k')
            .copyWith(autoRetryAttempts: 999)
            .autoRetryAttempts,
        maxAutoRetryAttempts,
      );
      expect(
        AppSettings(apiKey: 'k').copyWith(autoRetryDelay: -3).autoRetryDelay,
        minAutoRetryDelay,
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'autoRetryAttempts': 999,
          'autoRetryDelay': -3,
        }).autoRetryAttempts,
        maxAutoRetryAttempts,
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'autoRetryAttempts': 999,
          'autoRetryDelay': -3,
        }).autoRetryDelay,
        minAutoRetryDelay,
      );
    });
  });
}
