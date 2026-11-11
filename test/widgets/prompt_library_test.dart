import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/ui/screens/prompt_library_screen.dart';

import '../../test/support/test_doubles.dart';

/// Widget tests for the v1.15.0 Prompt Library: create/delete flows and
/// the composer's insert sheet.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_prompt_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ThemeData themeForTests() => ThemeData(useMaterial3: true);

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 15),
  );

  testWidgets('create flow: dialog saves a prompt into the repository', (
    WidgetTester tester,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
          writeScreenshots: false,
        ),
        child: Builder(
          builder: (BuildContext context) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              theme: themeForTests(),
              locale: const Locale('en'),
              supportedLocales: const <Locale>[Locale('en'), Locale('id')],
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                zLocalizationsDelegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const PromptLibraryScreen(),
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No prompts yet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('prompt-add-fab')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('prompt-title-field')),
      'My prompt',
    );
    await tester.enterText(
      find.byKey(const Key('prompt-content-field')),
      'Do the thing carefully',
    );
    await tester.tap(find.byKey(const Key('prompt-save-button')));
    await settle(tester);

    expect(find.text('My prompt'), findsOneWidget);
    expect(find.text('Prompt saved.'), findsOneWidget);
    final List<PromptEntry> stored = await container
        .read(promptRepositoryProvider)
        .load();
    expect(stored, hasLength(1));
    expect(stored.single.title, 'My prompt');
    expect(stored.single.content, 'Do the thing carefully');
  });

  testWidgets('delete flow: confirm dialog removes the prompt', (
    WidgetTester tester,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
          writeScreenshots: false,
          prompts: <PromptEntry>[
            PromptEntry(
              id: 'p1',
              title: 'Doomed prompt',
              content: 'bye',
              createdAt: DateTime(2025, 1, 1),
            ),
          ],
        ),
        child: Builder(
          builder: (BuildContext context) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              theme: themeForTests(),
              locale: const Locale('en'),
              supportedLocales: const <Locale>[Locale('en'), Locale('id')],
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                zLocalizationsDelegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const PromptLibraryScreen(),
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Doomed prompt'), findsOneWidget);

    // Open the tile menu → Delete → confirm.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await settle(tester);
    await tester.tap(find.text('Delete').last);
    await settle(tester);
    await tester.tap(find.text('Delete').last);
    await settle(tester);

    expect(find.text('Doomed prompt'), findsNothing);
    expect(find.text('Prompt deleted.'), findsOneWidget);
    expect(await container.read(promptRepositoryProvider).load(), isEmpty);
  });

  testWidgets('composer insert sheet puts the prompt into the input field', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(
            dir: tempDir,
            settings: AppSettings(apiKey: 'k', autoTitle: false),
            writeScreenshots: false,
            prompts: <PromptEntry>[
              PromptEntry(
                id: 'p1',
                title: 'Insert me',
                content: 'PROMPT CONTENT MARKER',
                createdAt: DateTime(2025, 1, 1),
              ),
            ],
          ),
          chatListProvider.overrideWith((Ref ref) async => <ChatSummary>[]),
        ],
        child: const NoahApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('prompt-insert-button')));
    await settle(tester);
    expect(find.byKey(const Key('prompt-sheet-list')), findsOneWidget);

    await tester.tap(find.byKey(const Key('prompt-sheet-item-p1')));
    await settle(tester);

    // The sheet closed and the composer field now carries the prompt.
    expect(find.text('PROMPT CONTENT MARKER'), findsOneWidget);
    expect(find.byKey(const Key('prompt-sheet-list')), findsNothing);
  });

  testWidgets('empty sheet offers a shortcut into the library', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(
            dir: tempDir,
            settings: AppSettings(apiKey: 'k', autoTitle: false),
            writeScreenshots: false,
          ),
          chatListProvider.overrideWith((Ref ref) async => <ChatSummary>[]),
        ],
        child: const NoahApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('prompt-insert-button')));
    await settle(tester);
    expect(find.text('No prompts yet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('prompt-sheet-open-library')));
    await settle(tester);
    // Landed on the library screen (its own empty state).
    expect(find.byKey(const Key('prompt-add-fab')), findsOneWidget);
  });
}
