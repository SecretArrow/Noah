import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/ui/widgets/message_bubble.dart';

import '../support/test_doubles.dart';
import 'modules_screen_test.dart' show ScriptedModuleRegistry;

ChatModule _module(
  String name, {
  List<ModulePermission> permissions = const <ModulePermission>[
    ModulePermission.storage,
  ],
}) => ChatModule(
  manifest: ModuleManifest(
    name: name,
    version: '1.0.0',
    title: name,
    description: '$name description',
    entry: 'main.js',
    permissions: permissions.toSet(),
  ),
  path: '/tmp/modules/$name',
  installedAt: DateTime(2026, 1, 1),
);

void main() {
  late Directory tempDir;
  late ScriptedModuleRegistry registry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_plugins_test');
    registry = ScriptedModuleRegistry();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget host({LlmClient? llm}) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: llm ?? ScriptedLlmClient(<AssistantTurn>[]),
          dir: tempDir,
          settings: AppSettings(apiKey: 'test-key', autoTitle: false),
          writeScreenshots: false,
        ),
        moduleRegistryProvider.overrideWithValue(registry),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: const NoahApp(),
    );
  }

  testWidgets('/plugins opens the interactive module menu listing installed '
      'modules', (WidgetTester tester) async {
    registry.seed(_module('weather'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('composer-field')), '/plugins');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();

    expect(find.text('Modules for this chat'), findsOneWidget);
    expect(find.byKey(const Key('plugin-sheet-item-weather')), findsOneWidget);
    expect(find.text('weather description'), findsOneWidget);
  });

  testWidgets('/plugins with no modules shows the empty hint and a shortcut '
      'to the manager', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('composer-field')), '/plugins');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No modules installed yet. Install one from the Modules screen.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('plugin-sheet-open-modules')), findsOneWidget);
  });

  testWidgets('tapping a module in the menu asks for consent then stages it '
      'on the fresh draft', (WidgetTester tester) async {
    registry.seed(_module('weather'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('composer-field')), '/plugins');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plugin-sheet-item-weather')));
    await tester.pumpAndSettle();

    // Consent dialog appears with the declared permission.
    expect(find.text('Allow \u201cweather\u201d to:'), findsOneWidget);
    await tester.tap(find.byKey(const Key('module-permission-allow')));
    await tester.pumpAndSettle();

    // Draft: the module is staged, not yet executed.
    final BuildContext context = tester.state(find.byType(Navigator)).context;
    final ProviderContainer container = ProviderScope.containerOf(context);
    expect(container.read(chatControllerProvider).pendingModule, 'weather');
    expect(container.read(chatControllerProvider).activeModules, isEmpty);
  });

  testWidgets('/plugins name activates a known module name and unknown names '
      'surface a localized error', (WidgetTester tester) async {
    registry.seed(_module('weather'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // Unknown module: snackbar, no staging.
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      '/plugins ghost',
    );
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();
    expect(find.text('Module not installed: ghost'), findsOneWidget);

    // Let the snackbar's dismissal timer fire so it stops covering the
    // composer's send button at the bottom of the screen.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Known module: consent + staged on the draft.
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      '/plugins weather',
    );
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('module-permission-allow')));
    await tester.pumpAndSettle();

    final BuildContext context = tester.state(find.byType(Navigator)).context;
    expect(
      ProviderScope.containerOf(context)
          .read(chatControllerProvider)
          .pendingModule,
      'weather',
    );
  });

  testWidgets('empty state renders module chips; tapping stages the module', (
    WidgetTester tester,
  ) async {
    registry.seed(_module('weather'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('empty-module-picker')), findsOneWidget);
    expect(find.text('Start with a module'), findsOneWidget);
    expect(find.byKey(const Key('empty-module-weather')), findsOneWidget);

    // The picker sits below the suggestion chips — scroll it into view
    // before tapping.
    await tester.ensureVisible(find.byKey(const Key('empty-module-weather')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('empty-module-weather')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('module-permission-allow')));
    await tester.pumpAndSettle();

    final BuildContext context = tester.state(find.byType(Navigator)).context;
    expect(
      ProviderScope.containerOf(context)
          .read(chatControllerProvider)
          .pendingModule,
      'weather',
    );
  });

  testWidgets('the /plugins sheet uninstalls a module after confirmation', (
    WidgetTester tester,
  ) async {
    registry.seed(_module('weather'));
    registry.seed(_module('clock'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('composer-field')), '/plugins');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plugin-sheet-item-weather')), findsOneWidget);

    // Trash button on the weather tile opens the confirmation dialog.
    await tester.tap(find.byKey(const Key('plugin-sheet-remove-weather')));
    await tester.pumpAndSettle();
    expect(find.text('Remove module?'), findsOneWidget);

    // Confirm → the registry removes it, the list refreshes, snackbar.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(registry.removed, <String>['weather']);
    expect(find.text('Module removed: weather'), findsOneWidget);
    expect(find.byKey(const Key('plugin-sheet-item-weather')), findsNothing);
    // The untouched module stays listed.
    expect(find.byKey(const Key('plugin-sheet-item-clock')), findsOneWidget);
  });

  testWidgets('cancelling the uninstall dialog keeps the module installed', (
    WidgetTester tester,
  ) async {
    registry.seed(_module('weather'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('composer-field')), '/plugins');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plugin-sheet-remove-weather')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(registry.removed, isEmpty);
    expect(find.byKey(const Key('plugin-sheet-item-weather')), findsOneWidget);
  });

  testWidgets('module messages render with a module badge', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          zLocalizationsDelegate,
        ],
        supportedLocales: const <Locale>[Locale('en'), Locale('id')],
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              message: ChatMessage.assistant(
                'Weather: sunny',
                moduleName: 'weather',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('module-badge-weather')), findsOneWidget);
    expect(find.text('weather'), findsOneWidget);
    expect(find.text('Weather: sunny'), findsOneWidget);
  });
}
