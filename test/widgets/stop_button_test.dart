import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// LLM double whose first complete() call PARKS on [gate] — the run stays
/// `isRunning` (Stop button up) while the test taps, and proceeds (aborting
/// cleanly when Stop was requested) once the gate opens. This is exactly
/// the "process refuses to die quickly" window the force-stop escalation
/// is designed for.
class _GatedLlmClient implements LlmClient {
  _GatedLlmClient(this.gate);

  final Completer<void> gate;

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    if (shouldAbort?.call() ?? false) throw const LlmAbortedException('');
    await gate.future;
    if (shouldAbort?.call() ?? false) throw const LlmAbortedException('');
    return AssistantTurn(content: 'done after gate');
  }
}

/// Variant whose Nth complete() call parks on the Nth gate — lets one test
/// drive TWO consecutive runs against the same app scope.
class _QueueGatedLlmClient implements LlmClient {
  _QueueGatedLlmClient(this.gates);

  final List<Completer<void>> gates;
  int _calls = 0;

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    if (shouldAbort?.call() ?? false) throw const LlmAbortedException('');
    final int index = _calls < gates.length ? _calls : gates.length - 1;
    _calls++;
    await gates[index].future;
    if (shouldAbort?.call() ?? false) throw const LlmAbortedException('');
    return AssistantTurn(content: 'done after gate');
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_stop_widget');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Pumps the real app with a run parked on [gate] and returns the
  /// provider container for state assertions.
  Future<ProviderContainer> pumpParkedRun(
    WidgetTester tester,
    Completer<void> gate,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(
            llm: _GatedLlmClient(gate),
            dir: tempDir,
            settings: AppSettings(apiKey: 'test-key'),
            writeScreenshots: false,
          ),
          chatListProvider.overrideWith((Ref ref) async => <ChatSummary>[]),
        ],
        child: Builder(
          builder: (BuildContext context) {
            container = ProviderScope.containerOf(context);
            return const NoahApp();
          },
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byKey(const Key('composer-field')), 'go');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump();

    // The gated turn keeps the run alive: the red Stop control is up.
    expect(find.byKey(const Key('stop-button')), findsOneWidget);
    expect(container.read(chatControllerProvider).isRunning, isTrue);
    return container;
  }

  testWidgets(
    'stop escalation: taps 1-2 stop gracefully, 3rd tap OFFERS force stop, '
    'cancel keeps the graceful stop',
    (WidgetTester tester) async {
      final Completer<void> gate = Completer<void>();
      final ProviderContainer container = await pumpParkedRun(tester, gate);

      // Tap 1: plain stop — no dialog yet.
      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      expect(find.byKey(const Key('force-stop-dialog')), findsNothing);

      // Tap 2: asks again and shows the escalation hint.
      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      expect(find.byKey(const Key('stop-hint-snack')), findsOneWidget);
      expect(find.byKey(const Key('force-stop-dialog')), findsNothing);
      // Let the snack fully expire (timer + entrance/exit animations) so it
      // cannot intercept the next tap.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(const Duration(milliseconds: 600));

      // Tap 3: the force-stop OFFER appears.
      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('force-stop-dialog')), findsOneWidget);

      // Cancel: no force stop happened, dialog is gone.
      await tester.tap(find.byKey(const Key('force-stop-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('force-stop-dialog')), findsNothing);

      // The run still ends through the (already armed) graceful stop.
      gate.complete();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      final ChatState state = container.read(chatControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.messages.last.content, contains('_(stopped)_'));
      expect(find.byKey(const Key('force-stop-done-snack')), findsNothing);
      expect(find.byKey(const Key('send-button')), findsOneWidget);
    },
  );

  testWidgets(
    'stop escalation: confirming the 3rd-tap offer force-stops the run',
    (WidgetTester tester) async {
      final Completer<void> gate = Completer<void>();
      final ProviderContainer container = await pumpParkedRun(tester, gate);

      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      // Expire the hint snack completely (timer + animations).
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('force-stop-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('force-stop-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Explicit confirmation feedback.
      expect(find.byKey(const Key('force-stop-done-snack')), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(const Duration(milliseconds: 600));

      // Force stop ends the pinned run and releases the composer.
      gate.complete();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      final ChatState state = container.read(chatControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.messages.last.content, contains('_(stopped)_'));
      expect(find.byKey(const Key('send-button')), findsOneWidget);
    },
  );

  testWidgets(
    'the tap counter resets with the run: a stale count never fires the '
    'offer in the next run',
    (WidgetTester tester) async {
      final Completer<void> gate1 = Completer<void>();
      final Completer<void> gate2 = Completer<void>();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...testOverrides(
              llm: _QueueGatedLlmClient(<Completer<void>>[gate1, gate2]),
              dir: tempDir,
              settings: AppSettings(apiKey: 'test-key'),
              writeScreenshots: false,
            ),
            chatListProvider.overrideWith((Ref ref) async => <ChatSummary>[]),
            // Run #2 CONTINUES the existing session (adopted from the store);
            // the in-memory store makes that load instant and deterministic.
            chatStoreProvider.overrideWithValue(MemoryChatStore()),
          ],
          child: Builder(
            builder: (BuildContext context) {
              container = ProviderScope.containerOf(context);
              return const NoahApp();
            },
          ),
        ),
      );
      await tester.pump();

      // Run #1: two escalation taps (counter reaches 2), then end the run.
      await tester.enterText(find.byKey(const Key('composer-field')), 'go');
      await tester.tap(find.byKey(const Key('send-button')));
      await tester.pump();
      expect(find.byKey(const Key('stop-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      expect(find.byKey(const Key('stop-hint-snack')), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));

      gate1.complete();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(find.byKey(const Key('send-button')), findsOneWidget);

      // Run #2 on the same chat: with a stale counter the FIRST tap would
      // already be tap #3 and open the offer dialog. The counter must have
      // reset with the run instead. Started via the controller (no tap) so
      // leftover overlay animations cannot interfere with hit-testing.
      unawaited(container.read(chatControllerProvider.notifier).send('go 2'));
      for (
        var i = 0;
        i < 30 && find.byKey(const Key('stop-button')).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('stop-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      expect(find.byKey(const Key('force-stop-dialog')), findsNothing);
      expect(container.read(chatControllerProvider).isRunning, isTrue);

      await tester.tap(find.byKey(const Key('stop-button')));
      await tester.pump();
      expect(find.byKey(const Key('force-stop-dialog')), findsNothing);

      gate2.complete();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(find.byKey(const Key('send-button')), findsOneWidget);
    },
  );
}
