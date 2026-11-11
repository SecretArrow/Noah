import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/ui/screens/settings_screen.dart';

import '../../test/support/test_doubles.dart';

/// LLM double that never answers — keeps the run alive so the UI shows
/// the Stop button.
class _NeverLlmClient implements LlmClient {
  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) => Completer<AssistantTurn>().future;
}

/// The exact red used by the Stop button (v1.30.0).
const Color kStopRed = Color(0xFFE5484D);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_v130_ui_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap({LlmClient? llm}) => ProviderScope(
    overrides: testOverrides(
      llm: llm,
      dir: tempDir,
      settings: AppSettings(apiKey: 'test-key'),
      writeScreenshots: false,
    ),
    child: const NoahApp(),
  );

  testWidgets('the Stop button is red while the agent is running', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(llm: _NeverLlmClient()));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('composer-field')), 'hi');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final Finder button = find.byKey(const Key('stop-button'));
    expect(button, findsOneWidget);

    final Finder containerFinder = find.ancestor(
      of: button,
      matching: find.byType(Container),
    );
    expect(containerFinder, findsAtLeastNWidgets(1));
    final Container box = tester.widget<Container>(containerFinder.first);
    final BoxDecoration decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, kStopRed);
  });

  testWidgets('auto retry settings: switch + two sliders, toggle persists', (
    WidgetTester tester,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(dir: tempDir, writeScreenshots: false),
        child: Builder(
          builder: (BuildContext context) {
            container = ProviderScope.containerOf(context);
            return const NoahApp();
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(SettingsScreen), findsOneWidget);

    // The auto-retry card sits below the fold: reveal it by scrolling.
    await tester.dragUntilVisible(
      find.byKey(const Key('auto-retry-switch')),
      find.byType(ListView),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.byKey(const Key('auto-retry-switch')), findsOneWidget);
    expect(find.byKey(const Key('auto-retry-attempts-slider')), findsOneWidget);
    expect(find.byKey(const Key('auto-retry-delay-slider')), findsOneWidget);

    // Defaults: on, 3 attempts, 5 s delay.
    expect(container.read(settingsProvider).autoRetryEnabled, isTrue);
    expect(container.read(settingsProvider).autoRetryAttempts, 3);
    expect(container.read(settingsProvider).autoRetryDelay, 5);

    // Toggling the switch off persists immediately and disables the
    // sliders.
    await tester.tap(find.byKey(const Key('auto-retry-switch')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).autoRetryEnabled, isFalse);
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('auto-retry-attempts-slider')))
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('auto-retry-delay-slider')))
          .onChanged,
      isNull,
    );
  });
}
