import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/ui/screens/settings_screen.dart';

import '../../test/support/test_doubles.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_language_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap({AppSettings? settings}) => ProviderScope(
    overrides: testOverrides(
      dir: tempDir,
      settings: settings ?? AppSettings(apiKey: 'k'),
    ),
    child: const NoahApp(),
  );

  testWidgets('default UI language is English', (WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    // Composer hint (home) and drawer title must be English on first run,
    // regardless of the test device locale.
    expect(find.text('Ask anything…'), findsOneWidget);
    expect(find.text('Tanya apa saja…'), findsNothing);
  });

  testWidgets('switching to Bahasa Indonesia updates home and settings', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    // Open settings via the app bar button.
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(SettingsScreen), findsOneWidget);

    // The language section sits below the fold (and gained an extra switch
    // tile above it in v1.15.0). The settings list is long, so the section
    // header and its radio tiles may not fit the viewport TOGETHER anymore:
    // scroll to the header first, assert it, then scroll to the radios.
    await tester.dragUntilVisible(
      find.text('LANGUAGE'),
      find.byType(ListView),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('LANGUAGE'), findsOneWidget); // section titles uppercase

    await tester.dragUntilVisible(
      find.byKey(const Key('lang-id')),
      find.byType(ListView),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.text('English (default)'), findsOneWidget);

    // Switch to Indonesian via the radio tile.
    await tester.tap(find.byKey(const Key('lang-id')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // The header may have scrolled out of the lazy viewport: bring it back.
    await tester.dragUntilVisible(
      find.text('BAHASA'),
      find.byType(ListView),
      const Offset(0, 250),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Settings screen re-renders in Indonesian immediately.
    expect(find.text('Pengaturan'), findsOneWidget);
    expect(find.text('BAHASA'), findsOneWidget);
    expect(find.text('English (bawaan)'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);

    // The choice is persisted in the settings controller.
    final BuildContext context = tester.element(find.byType(SettingsScreen));
    final ProviderContainer container = ProviderScope.containerOf(context);
    expect(container.read(settingsProvider).languageCode, 'id');

    // Go back home: composer hint is now Indonesian.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.text('Tanya apa saja…'), findsOneWidget);
    expect(find.text('Ask anything…'), findsNothing);
  });

  testWidgets('app bar language menu switches back to English', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        settings: AppSettings(apiKey: 'k', languageCode: 'id'),
      ),
    );
    await tester.pump();

    // Stored preference wins on startup: Indonesian.
    expect(find.text('Tanya apa saja…'), findsOneWidget);

    // Quick switch from the app bar popup menu.
    await tester.tap(find.byKey(const Key('language-menu')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const Key('language-menu-en')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.text('Ask anything…'), findsOneWidget);
    expect(find.text('Tanya apa saja…'), findsNothing);
  });
}
