import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/ui/widgets/module_repair_card.dart';

import '../support/test_doubles.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
    zLocalizationsDelegate,
  ],
  supportedLocales: const <Locale>[Locale('en'), Locale('id')],
  home: child,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repair_card_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<ProviderContainer> container() async {
    final ProviderContainer c = ProviderContainer(
      overrides: testOverrides(
        llm: ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
        dir: tempDir,
        settings: AppSettings(apiKey: 'k', autoTitle: false),
      ),
    );
    addTearDown(c.dispose);
    return c;
  }

  ModuleInstallRequest request() => const ModuleInstallRequest(
    zipPath: '/tmp/repaired.zip',
    moduleName: 'fixme',
    version: '1.0.1',
    title: 'Fixme',
    permissions: <String>['storage'],
  );

  testWidgets('hidden when nothing is staged', (WidgetTester tester) async {
    final ProviderContainer c = await container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: _app(const Scaffold(body: ModuleRepairCard())),
      ),
    );
    expect(find.byKey(const Key('module-repair-card')), findsNothing);
  });

  testWidgets('shows title, body and buttons; install runs the pipeline', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = await container();
    // Prime the state with a staged request.
    c.read(chatControllerProvider.notifier);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: _app(const Scaffold(body: ModuleRepairCard())),
      ),
    );
    c.read(chatControllerProvider.notifier).debugStageRepairForTest(request());
    await tester.pump();

    expect(find.byKey(const Key('module-repair-card')), findsOneWidget);
    final AppStrings strings = appStringsFor('en');
    expect(
      find.text(strings.moduleRepairCardTitle('fixme', '1.0.1')),
      findsOneWidget,
    );
    expect(find.text(strings.moduleRepairCardBody('storage')), findsOneWidget);
    expect(find.byKey(const Key('module-repair-install')), findsOneWidget);
    expect(find.byKey(const Key('module-repair-discard')), findsOneWidget);

    // Discard clears the card (no registry touched — the zip path does
    // not even exist here).
    await tester.tap(find.byKey(const Key('module-repair-discard')));
    await tester.pump();
    expect(find.byKey(const Key('module-repair-card')), findsNothing);
  });

  testWidgets('a NEW plugin (/make_plugins build) shows the builder wording', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = await container();
    c.read(chatControllerProvider.notifier);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: _app(const Scaffold(body: ModuleRepairCard())),
      ),
    );
    c
        .read(chatControllerProvider.notifier)
        .debugStageRepairForTest(
          const ModuleInstallRequest(
            zipPath: '/tmp/built.zip',
            moduleName: 'quoter',
            version: '1.0.0',
            title: 'Quoter',
            permissions: <String>['storage', 'network'],
            isNew: true,
          ),
        );
    await tester.pump();

    final AppStrings strings = appStringsFor('en');
    expect(
      find.text(strings.moduleBuildCardTitle('quoter', '1.0.0')),
      findsOneWidget,
    );
    expect(
      find.text(strings.moduleBuildCardBody('storage, network')),
      findsOneWidget,
    );
    // The repair wording is NOT shown for a fresh build.
    expect(
      find.text(strings.moduleRepairCardTitle('quoter', '1.0.0')),
      findsNothing,
    );
    expect(find.byKey(const Key('module-repair-install')), findsOneWidget);
  });
}
