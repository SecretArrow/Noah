import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:noah/main.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/llm_client.dart';

import '../../test/support/test_doubles.dart';

/// Widget tests for the v1.15.0 message actions: the edit button on user
/// bubbles, the regenerate button under the LAST assistant bubble, and
/// their round trips through the controller.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_actions_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap({LlmClient? llm, AppSettings? settings}) => ProviderScope(
    overrides: [
      ...testOverrides(
        llm: llm,
        dir: tempDir,
        settings: settings ?? AppSettings(apiKey: 'test-key', autoTitle: false),
        writeScreenshots: false,
      ),
      // v1.41.0: this file performs MULTIPLE sends on one session. The
      // run-release path awaits the final persist, and real dart:io IO
      // never completes inside the FakeAsync widget-test zone — the second
      // send then waits forever on the first run's `finalized` future and
      // is silently swallowed (transcript stays at [q1, answer one]).
      // The in-memory store keeps every store future synchronous, so the
      // release completes and multi-send flows behave like on a device.
      chatStoreProvider.overrideWithValue(InMemoryChatStore()),
    ],
    child: const NoahApp(),
  );

  Future<void> pumpSendAndSettle(
    WidgetTester tester,
    ScriptedLlmClient llm,
    String message,
  ) async {
    await tester.enterText(find.byKey(const Key('composer-field')), message);
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump(); // user bubble appears
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
  }

  testWidgets('buttons appear after the run and disappear while running', (
    WidgetTester tester,
  ) async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'first answer'),
    ]);
    await tester.pumpWidget(wrap(llm: llm));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('composer-field')), 'halo');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump(); // user bubble + running state

    // Hidden while the agent loop is active.
    expect(find.byKey(const Key('edit-message-button')), findsNothing);
    expect(find.byKey(const Key('regenerate-button')), findsNothing);

    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Edit next to the copy button under the user bubble, regenerate under
    // the (single) assistant answer.
    expect(find.byKey(const Key('edit-message-button')), findsOneWidget);
    expect(find.byKey(const Key('copy-message-button')), findsNWidgets(2));
    expect(find.byKey(const Key('regenerate-button')), findsOneWidget);
  });

  testWidgets('edit dialog round trip truncates history and re-answers', (
    WidgetTester tester,
  ) async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'first answer'),
      AssistantTurn(content: 'second answer'),
    ]);
    await tester.pumpWidget(wrap(llm: llm));
    await tester.pump();
    await pumpSendAndSettle(tester, llm, 'first question');

    await tester.tap(find.byKey(const Key('edit-message-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // The dialog is pre-filled with the current text.
    expect(find.byKey(const Key('edit-message-field')), findsOneWidget);
    final EditableText field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('edit-message-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.controller.text, 'first question');

    await tester.enterText(
      find.byKey(const Key('edit-message-field')),
      'edited question',
    );
    await tester.tap(find.byKey(const Key('edit-message-save')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // The edited bubble + the regenerated answer replace the old transcript.
    expect(find.text('edited question'), findsOneWidget);
    expect(find.textContaining('second answer'), findsOneWidget);
    expect(find.textContaining('first question'), findsNothing);
    expect(find.textContaining('first answer'), findsNothing);
    // Exactly two LLM calls: the original send + the edit replay.
    expect(llm.calls, hasLength(2));
  });

  testWidgets('regenerate button replays the last user message', (
    WidgetTester tester,
  ) async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'first answer'),
      AssistantTurn(content: 'REGENERATED MARKER'),
    ]);
    await tester.pumpWidget(wrap(llm: llm));
    await tester.pump();
    await pumpSendAndSettle(tester, llm, 'the question');

    // Confirm-less: one tap regenerates immediately.
    await tester.tap(find.byKey(const Key('regenerate-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.textContaining('REGENERATED MARKER'), findsOneWidget);
    expect(find.textContaining('first answer'), findsNothing);
    expect(find.text('the question'), findsOneWidget);
    expect(llm.calls, hasLength(2));
  });

  testWidgets('regenerate shows only under the LAST assistant message', (
    WidgetTester tester,
  ) async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'answer one'),
      AssistantTurn(content: 'answer two'),
    ]);
    await tester.pumpWidget(wrap(llm: llm));
    await tester.pump();
    await pumpSendAndSettle(tester, llm, 'q1');
    await pumpSendAndSettle(tester, llm, 'q2');

    // Two assistant answers on screen, but exactly one regenerate control.
    expect(find.textContaining('answer one'), findsOneWidget);
    expect(find.textContaining('answer two'), findsOneWidget);
    expect(find.byKey(const Key('regenerate-button')), findsOneWidget);
  });
}
