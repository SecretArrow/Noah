import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/ui/screens/preset_editor_screen.dart';
import 'package:noah/models/user_agent.dart';
import 'package:noah/ui/screens/providers_screen.dart';
import 'package:noah/ui/screens/skills_screen.dart';
import 'package:noah/services/background_service.dart';
import 'package:noah/ui/screens/about_screen.dart';
import 'package:noah/ui/screens/help_screen.dart';
import 'package:noah/ui/screens/settings_screen.dart';

import '../../test/support/test_doubles.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_settings_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// v1.49.6: feedback arrives as a centered modal dialog — acknowledge it
  /// via the OK button so the dialog barrier cannot swallow the next tap.
  Future<void> dismissAppMessage(WidgetTester tester) async {
    final Finder ok = find.byKey(const Key('app-message-ok'));
    if (ok.evaluate().isNotEmpty) {
      await tester.tap(ok);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
    }
  }

  Future<ProviderContainer> openSettings(WidgetTester tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[...testOverrides(dir: tempDir)],
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
    return container;
  }

  /// v1.49.0: the Skills manager is reachable from Settings, exactly like
  /// the Modules manager — tapping the tile pushes [SkillsScreen]. The
  /// manager loads its list through native file IO, which only completes
  /// outside the FakeAsync zone, so the route wait is a bounded runAsync
  /// drain (a broken install dir can never hang the suite).
  testWidgets('skills manager tile opens the Skills manager screen', (
    WidgetTester tester,
  ) async {
    await openSettings(tester);

    // The Skills section sits below the fold in the settings ListView —
    // drag until the tile is built and visible before tapping.
    await tester.scrollUntilVisible(
      find.byKey(const Key('skills-manager-tile')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const Key('skills-manager-tile')));

    // The manager loads its list through native file IO, whose completion
    // is only delivered outside the FakeAsync zone — drain the real event
    // loop (bounded) until no loading spinner remains, then assert. A
    // plain pumpAndSettle would hang forever on the spinner.
    await tester.pump();
    int guard = 0;
    bool screenLoading() => find
        .descendant(
          of: find.byType(SkillsScreen),
          matching: find.byType(CircularProgressIndicator),
        )
        .evaluate()
        .isNotEmpty;
    while (screenLoading() && guard++ < 100) {
      await tester.runAsync<void>(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    // Advance the push transition to completion (fake-time pumps) so the
    // route is fully settled before the assertions.
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(find.byType(SkillsScreen), findsOneWidget);
    expect(screenLoading(), isFalse);
  });

  Future<void> openProviders(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('providers-tile')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(ProvidersScreen), findsOneWidget);
  }

  testWidgets('settings shows a compact provider tile (no cramped fields)', (
    WidgetTester tester,
  ) async {
    await openSettings(tester);

    expect(find.byKey(const Key('providers-tile')), findsOneWidget);
    // The old inline connection fields are gone — CRUD moved to the
    // full-screen providers manager.
    expect(find.byKey(const Key('base-url-field')), findsNothing);
    expect(find.byKey(const Key('api-key-field')), findsNothing);
    expect(find.byKey(const Key('model-field')), findsNothing);
  });

  testWidgets('agent controls keep working (switches + max steps)', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);

    // The agent section sits below the fold: scroll before asserting.
    await tester.dragUntilVisible(
      find.byKey(const Key('agent-mode-switch')),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('agent-mode-switch')), findsOneWidget);
    expect(find.byKey(const Key('automation-switch')), findsOneWidget);

    // Reveal the bottom of the agent card first so slider + field are built.
    await tester.dragUntilVisible(
      find.byKey(const Key('max-steps-field')),
      find.byType(ListView),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // "Run until done" is ON by default: the max-steps cap is bypassed and
    // the slider/input are disabled (dimmed).
    expect(container.read(settingsProvider).runUntilDone, isTrue);
    final Slider disabledSlider = tester.widget<Slider>(
      find.byKey(const Key('max-steps-slider')),
    );
    expect(disabledSlider.onChanged, isNull);
    final TextField disabledField = tester.widget<TextField>(
      find.byKey(const Key('max-steps-field')),
    );
    expect(disabledField.enabled, isFalse);

    // Toggling the switch OFF re-enables the max-steps controls.
    await tester.dragUntilVisible(
      find.byKey(const Key('run-until-done-switch')),
      find.byType(ListView),
      const Offset(0, 120),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const Key('run-until-done-switch')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).runUntilDone, isFalse);

    await tester.dragUntilVisible(
      find.byKey(const Key('max-steps-field')),
      find.byType(ListView),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    final Slider enabledSlider = tester.widget<Slider>(
      find.byKey(const Key('max-steps-slider')),
    );
    expect(enabledSlider.onChanged, isNotNull);

    await tester.enterText(find.byKey(const Key('max-steps-field')), '55');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).maxSteps, 55);

    // Out-of-range input is clamped into the allowed bounds.
    await tester.enterText(find.byKey(const Key('max-steps-field')), '5000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).maxSteps, 100);

    // The choice persists in settings (memory repo keeps the last write).
    expect(container.read(settingsProvider).runUntilDone, isFalse);
  });

  testWidgets('plan-first switch defaults on and persists the toggle', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);

    await tester.dragUntilVisible(
      find.byKey(const Key('plan-first-switch')),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(container.read(settingsProvider).planFirst, isTrue);
    expect(find.byKey(const Key('plan-first-switch')), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-first-switch')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).planFirst, isFalse);
  });

  testWidgets('device commands switch defaults OFF and persists (v1.31.0)', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);

    await tester.dragUntilVisible(
      find.byKey(const Key('device-commands-switch')),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Root shell commands are opt-in: the switch ships off.
    expect(container.read(settingsProvider).deviceCommandsEnabled, isFalse);
    expect(find.byKey(const Key('device-commands-switch')), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-commands-switch')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).deviceCommandsEnabled, isTrue);
  });

  testWidgets('ip-switch warn defaults OFF and persists (v1.48.0)', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);

    await tester.dragUntilVisible(
      find.byKey(const Key('ip-switch-warn-switch')),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Privacy-sensitive network probe: the switch ships off.
    expect(container.read(settingsProvider).ipSwitchWarnEnabled, isFalse);
    expect(find.byKey(const Key('ip-switch-warn-switch')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ip-switch-warn-switch')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).ipSwitchWarnEnabled, isTrue);
  });

  testWidgets('theme picker switches light/dark/system and persists', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);

    // Dark is the default (v1.3.0 look preserved).
    expect(container.read(settingsProvider).themeMode, ThemeModeSetting.dark);

    // Switch to light (segments are identified by their icons —
    // ButtonSegment does not expose a key parameter).
    await tester.tap(find.byIcon(Icons.light_mode_outlined));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).themeMode, ThemeModeSetting.light);
    // Switch to system.
    await tester.tap(find.byIcon(Icons.settings_suggest_outlined));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).themeMode, ThemeModeSetting.system);
  });

  testWidgets('providers screen lists presets; activating a preset copies '
      'its stored values into the connection', (WidgetTester tester) async {
    final ProviderContainer container = await openSettings(tester);
    await openProviders(tester);

    // Built-in presets render as cards.
    expect(find.byKey(const Key('provider-OpenRouter')), findsOneWidget);
    expect(find.byKey(const Key('provider-InferHub')), findsOneWidget);

    // Activating a provider copies its stored values into the connection.
    await tester.tap(find.byKey(const Key('use-provider-Z.AI')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).providerName, 'Z.AI');
    expect(
      container.read(settingsProvider).baseUrl,
      'https://api.z.ai/api/paas/v4',
    );
  });

  testWidgets('long-pressing a provider card asks for confirmation before '
      'activating it', (WidgetTester tester) async {
    final ProviderContainer container = await openSettings(tester);
    await openProviders(tester);

    // Default active provider is OpenRouter.
    expect(container.read(settingsProvider).providerName, 'OpenRouter');

    // Long-press opens the confirmation dialog (the editor must NOT open).
    await tester.longPress(find.byKey(const Key('provider-InferHub')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('provider-activate-dialog')), findsOneWidget);
    expect(container.read(settingsProvider).providerName, 'OpenRouter');

    // Cancel keeps the current connection.
    await tester.tap(find.byKey(const Key('cancel-activate-provider')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).providerName, 'OpenRouter');

    // Long-press again and confirm: the connection switches.
    await tester.longPress(find.byKey(const Key('provider-InferHub')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const Key('confirm-activate-provider')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).providerName, 'InferHub');
    expect(
      container.read(settingsProvider).baseUrl,
      'https://api.inferhub.dev/v1',
    );
  });

  testWidgets('long-pressing the already-active provider does nothing', (
    WidgetTester tester,
  ) async {
    await openSettings(tester);
    await openProviders(tester);

    await tester.longPress(find.byKey(const Key('provider-OpenRouter')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('provider-activate-dialog')), findsNothing);
  });

  testWidgets('editing an existing provider: API key is saved per provider '
      'via the explicit save button', (WidgetTester tester) async {
    final ProviderContainer container = await openSettings(tester);
    await openProviders(tester);

    // Open the full-screen editor for InferHub.
    await tester.tap(find.byKey(const Key('provider-InferHub')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(PresetEditorScreen), findsOneWidget);
    expect(find.byKey(const Key('editor-name-field')), findsOneWidget);
    expect(find.byKey(const Key('editor-api-key-field')), findsOneWidget);

    // The editor must NOT be a modal dialog: it fills the screen.
    final Finder editorFinder = find.byType(PresetEditorScreen);
    final Size size = tester.getSize(editorFinder);
    expect(size.height, greaterThan(400));

    await tester.enterText(
      find.byKey(const Key('editor-api-key-field')),
      'sk-airo-test-123',
    );
    // Explicit per-provider key save (no keyboard-done action needed).
    await tester.tap(find.byKey(const Key('editor-save-api-key-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    final AppSettings settings = container.read(settingsProvider);
    final ProviderPreset inferhub = settings.presets.firstWhere(
      (ProviderPreset p) => p.name == 'InferHub',
    );
    expect(inferhub.apiKey, 'sk-airo-test-123');
    // Not activated — the connection must not change.
    expect(settings.providerName, 'OpenRouter');
    expect(settings.apiKey, isNot('sk-airo-test-123'));

    // Editor stays open after a key-only save.
    expect(find.byType(PresetEditorScreen), findsOneWidget);
  });

  testWidgets('new provider is created through the full-screen editor', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);
    await openProviders(tester);

    await tester.tap(find.byKey(const Key('add-provider-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(PresetEditorScreen), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('editor-name-field')),
      'My Provider',
    );
    await tester.enterText(
      find.byKey(const Key('editor-base-url-field')),
      'https://api.example.com/v1',
    );
    await tester.enterText(
      find.byKey(const Key('editor-api-key-field')),
      'sk-mine',
    );
    // AppBar save action is always visible (no scrolling required).
    await tester.tap(find.byKey(const Key('editor-save-appbar')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Back on the providers screen with the preset persisted.
    expect(find.byType(ProvidersScreen), findsOneWidget);
    final AppSettings settings = container.read(settingsProvider);
    expect(
      settings.presets.any((ProviderPreset p) => p.name == 'My Provider'),
      isTrue,
    );
    // A new preset is not auto-activated.
    expect(settings.providerName, 'OpenRouter');

    // The new card is appended at the end of the list — page 2 with the
    // 5-per-page pager. The built-in search brings it into view (and
    // doubles as an integration test of the universal search).
    await tester.enterText(
      find.byKey(const Key('providers-search-field')),
      'My Provider',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('provider-My Provider')), findsOneWidget);
  });

  testWidgets('saving the active provider keeps the connection in sync', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);
    await openProviders(tester);

    // Activate Z.AI first.
    await tester.tap(find.byKey(const Key('use-provider-Z.AI')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    // v1.49.6: activation feedback is a centered modal dialog — acknowledge
    // it before the next tap (the barrier would swallow it otherwise).
    await dismissAppMessage(tester);

    // Edit the active provider's key through the editor.
    await tester.tap(find.byKey(const Key('provider-Z.AI')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.enterText(
      find.byKey(const Key('editor-api-key-field')),
      'sk-zai-live',
    );
    await tester.tap(find.byKey(const Key('editor-save-api-key-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    // Acknowledge the key-saved dialog before the next tap.
    await dismissAppMessage(tester);
    // Active connection picked up the new key immediately.
    expect(container.read(settingsProvider).apiKey, 'sk-zai-live');

    // Now save the whole form with a new model value (AppBar save).
    await tester.enterText(
      find.byKey(const Key('editor-model-field')),
      'glm-4.6',
    );
    await tester.tap(find.byKey(const Key('editor-save-appbar')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(PresetEditorScreen), findsNothing);
    expect(container.read(settingsProvider).model, 'glm-4.6');
    expect(container.read(settingsProvider).apiKey, 'sk-zai-live');
  });

  testWidgets('validation: empty name and duplicate names are rejected', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);
    await openProviders(tester);

    await tester.tap(find.byKey(const Key('add-provider-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Save without a name -> validation error, editor stays open
    // (AppBar save = same full-save path, always hittable).
    await tester.enterText(
      find.byKey(const Key('editor-base-url-field')),
      'https://api.example.com/v1',
    );
    await tester.tap(find.byKey(const Key('editor-save-appbar')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(PresetEditorScreen), findsOneWidget);
    expect(find.text('Name is required.'), findsOneWidget);

    // Duplicate built-in name -> duplicate error.
    await tester.enterText(find.byKey(const Key('editor-name-field')), 'Groq');
    await tester.tap(find.byKey(const Key('editor-save-appbar')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(PresetEditorScreen), findsOneWidget);
    expect(
      find.text('A provider with this name already exists.'),
      findsOneWidget,
    );
    // Built-in presets: 9 through v1.49.8 (Nvidia NIM) + Local AI
    // (Local AI port) = 10.
    expect(container.read(settingsProvider).presets.length, 10);
  });

  testWidgets('a provider can be deleted from the editor', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);
    await openProviders(tester);

    // Create a disposable provider first.
    await tester.tap(find.byKey(const Key('add-provider-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.enterText(
      find.byKey(const Key('editor-name-field')),
      'Throwaway',
    );
    await tester.enterText(
      find.byKey(const Key('editor-base-url-field')),
      'https://throw.example.com/v1',
    );
    await tester.tap(find.byKey(const Key('editor-save-appbar')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    // v1.49.6: the saved confirmation is a centered modal dialog —
    // acknowledge it so the barrier cannot eat the provider tap below.
    await dismissAppMessage(tester);
    // The new card sits at the bottom of the list (page 2 with the
    // 5-per-page pager) — use the search to reach it.
    await tester.enterText(
      find.byKey(const Key('providers-search-field')),
      'Throwaway',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('provider-Throwaway')), findsOneWidget);

    // Open it and delete it (scroll the danger zone into view first).
    await tester.tap(find.byKey(const Key('provider-Throwaway')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.dragUntilVisible(
      find.byKey(const Key('editor-delete-button')),
      find.byType(ListView),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const Key('editor-delete-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    // Confirm dialog.
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // The search query 'Throwaway' is still active: after deletion the
    // filtered list is empty, so clear the search first.
    await tester.enterText(find.byKey(const Key('providers-search-field')), '');
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.byKey(const Key('provider-Throwaway')), findsNothing);
    expect(
      container
          .read(settingsProvider)
          .presets
          .any((ProviderPreset p) => p.name == 'Throwaway'),
      isFalse,
    );
  });

  testWidgets('providers search filters by name and resets to page one', (
    WidgetTester tester,
  ) async {
    await openSettings(tester);
    await openProviders(tester);

    expect(find.byKey(const Key('provider-OpenRouter')), findsOneWidget);
    expect(find.byKey(const Key('provider-InferHub')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('providers-search-field')),
      'inferhub',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('provider-InferHub')), findsOneWidget);
    expect(find.byKey(const Key('provider-OpenRouter')), findsNothing);
    expect(find.byKey(const Key('provider-Z.AI')), findsNothing);

    // Clearing the query restores the full list.
    await tester.enterText(find.byKey(const Key('providers-search-field')), '');
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('provider-OpenRouter')), findsOneWidget);
  });

  testWidgets('user-agent mode dropdown persists the selection', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);

    // The section sits below the agent card: reveal it first.
    await tester.dragUntilVisible(
      find.byKey(const Key('ua-mode-dropdown')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('ua-mode-dropdown')), findsOneWidget);
    expect(
      container.read(settingsProvider).uaMode,
      UaMode.auto,
      reason: 'Auto is the default mode',
    );

    // Open the dropdown and pick PC/Desktop.
    await tester.tap(find.byKey(const Key('ua-mode-dropdown')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.text('PC/Desktop').last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).uaMode, UaMode.desktop);

    // Rotating moves the desktop pick forward and persists it.
    final int before = container.read(settingsProvider).uaDesktopId;
    await tester.tap(find.byKey(const Key('ua-rotate-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).uaDesktopId, isNot(before));
    // The preview label updates with the new pick.
    expect(find.byKey(const Key('ua-current-preview')), findsOneWidget);
  });

  testWidgets('ask-random-ua switch defaults on and persists the toggle', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSettings(tester);

    // The UA section sits below the fold: reveal it first.
    await tester.dragUntilVisible(
      find.byKey(const Key('ask-random-ua-switch')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    final SwitchListTile tile = tester.widget<SwitchListTile>(
      find.byKey(const Key('ask-random-ua-switch')),
    );
    expect(
      tile.value,
      isTrue,
      reason: 'the new-chat random UA prompt is enabled by default',
    );

    await tester.tap(find.byKey(const Key('ask-random-ua-switch')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(container.read(settingsProvider).askRandomUa, isFalse);
  });

  group('background reliability tile (v1.28.0)', () {
    testWidgets('shows the current battery-optimization state', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      // The tile sits below the fold: reveal it first (same pattern as
      // the tapping test below).
      await tester.dragUntilVisible(
        find.byKey(const Key('battery-reliability-tile')),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.pump();

      // Default double: not exempted yet.
      expect(find.byKey(const Key('battery-reliability-tile')), findsOneWidget);
      expect(find.textContaining('Optimized (may pause runs)'), findsOneWidget);
    });

    testWidgets('tapping the tile requests the exemption and refreshes', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = await openSettings(tester);
      final RecordingBackgroundRun background = container.read(
        backgroundRunServiceProvider,
      ) as RecordingBackgroundRun;

      // The tile sits below the fold in the Agent section: reveal it first.
      await tester.dragUntilVisible(
        find.byKey(const Key('battery-reliability-tile')),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );

      await tester.tap(find.byKey(const Key('battery-reliability-tile')));
      // The tile re-queries after a short settle delay.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );

      expect(background.batteryRequests, 1);
      expect(find.textContaining('Exempted'), findsOneWidget);
    });

    testWidgets('help tile sits above about tile and opens both screens', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      // Both tiles live near the list bottom and the settings ListView
      // builds lazily: reveal the section FIRST, then assert.
      final Finder helpTile = find.byKey(const Key('help-tile'));
      final Finder aboutTile = find.byKey(const Key('about-tile'));
      await tester.dragUntilVisible(
        aboutTile,
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(helpTile, findsOneWidget);
      expect(aboutTile, findsOneWidget);
      final double helpY2 = tester.getTopLeft(helpTile).dy;
      final double aboutY2 = tester.getTopLeft(aboutTile).dy;
      expect(helpY2, lessThan(aboutY2), reason: 'Help must sit above About');

      // Tapping About opens the dedicated About screen.
      await tester.tap(aboutTile);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(find.byType(AboutScreen), findsOneWidget);
      expect(find.byKey(const Key('about-version')), findsOneWidget);

      // Back to settings, then Help opens the dedicated guide screen.
      await tester.pageBack();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      await tester.dragUntilVisible(
        helpTile,
        find.byType(ListView),
        const Offset(0, 200),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      await tester.tap(helpTile);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(find.byType(HelpScreen), findsOneWidget);
      expect(find.byKey(const Key('help-topic-0')), findsOneWidget);
    });
  });
}
