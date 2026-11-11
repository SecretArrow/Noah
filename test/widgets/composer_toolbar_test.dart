import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/ui/widgets/composer.dart';

import '../support/test_doubles.dart';

/// v1.48.0 — the composer TOOL icons (attach / prompt library / mic) live
/// in a toolbar row ABOVE the text field ONLY while no run is active, and
/// the plan show/hide eye is GONE from the composer: while a run streams
/// the toolbar row disappears entirely and the SAME three icons render on
/// the thinking footer's row, immediately LEFT of the footer's eye (see
/// todo_plan_card_test.dart for the footer-side geometry).
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('composer_toolbar_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(dir: tempDir, writeScreenshots: false),
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            zLocalizationsDelegate,
          ],
          supportedLocales: const <Locale>[Locale('en'), Locale('id')],
          home: const Scaffold(body: Composer()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Scopes a finder to the COMPOSER subtree — during a run the thinking
  /// footer (rendered by the message list, not here) owns the icons, so
  /// toolbar assertions must be scoped.
  Finder inComposer(Key key) =>
      find.descendant(of: find.byType(Composer), matching: find.byKey(key));

  testWidgets('tool icons render in the toolbar above the text field', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    expect(find.byKey(const Key('attach-button')), findsOneWidget);
    expect(find.byKey(const Key('prompt-insert-button')), findsOneWidget);
    expect(find.byKey(const Key('mic-button')), findsOneWidget);
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
    expect(find.byKey(const Key('send-button')), findsOneWidget);

    // Toolbar is a SEPARATE row from the text field: the attach button's
    // center sits ABOVE the field's top edge (v1.45 and below had them
    // in one Row, i.e. vertically overlapping).
    final Rect attach = tester.getRect(find.byKey(const Key('attach-button')));
    final Rect field = tester.getRect(find.byKey(const Key('composer-field')));
    expect(attach.bottom, lessThanOrEqualTo(field.top + 1));
  });

  testWidgets('v1.48.0: the plan show/hide eye is DELETED from the composer — '
      'zero matches, even with a plan in the chat', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    expect(find.byKey(const Key('composer-plan-toggle')), findsNothing);
  });

  testWidgets(
    'while a run streams the toolbar row is HIDDEN — the three icons move '
    'to the thinking footer (exactly one copy on screen), field + stop '
    'stay, and no duplicate eye appears',
    (WidgetTester tester) async {
      final Completer<void> gate = Completer<void>();
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

      // The composer toolbar row is GONE: none of the three tool keys
      // inside the composer subtree…
      expect(inComposer(const Key('attach-button')), findsNothing);
      expect(inComposer(const Key('prompt-insert-button')), findsNothing);
      expect(inComposer(const Key('mic-button')), findsNothing);
      // …and the duplicate plan eye is gone from the whole app.
      expect(find.byKey(const Key('composer-plan-toggle')), findsNothing);

      // The input row stays untouched.
      expect(find.byKey(const Key('composer-field')), findsOneWidget);

      // The icons DID move (not vanish): the streaming assistant bubble's
      // thinking footer now renders the attach icon — exactly ONCE. The
      // streaming bubble is created by the run loop, so wait for it.
      for (
        var i = 0;
        i < 20 && find.text('thinking…').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('thinking…'), findsOneWidget);
      expect(find.byKey(const Key('attach-button')), findsOneWidget);
      expect(find.byKey(const Key('prompt-insert-button')), findsOneWidget);
      expect(find.byKey(const Key('mic-button')), findsOneWidget);

      // Run ends: the toolbar comes back and the footer (with its icon
      // copy) unmounts.
      gate.complete();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(container.read(chatControllerProvider).isRunning, isFalse);
      expect(find.byKey(const Key('send-button')), findsOneWidget);
      expect(inComposer(const Key('attach-button')), findsOneWidget);
      expect(find.text('thinking…'), findsNothing);
    },
  );
}

/// LLM double whose complete() PARKS on [gate] — the run stays
/// `isRunning` (Stop button up, toolbar hidden) while the test asserts,
/// and proceeds once the gate opens. Same pattern as stop_button_test.
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
