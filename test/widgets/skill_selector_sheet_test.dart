import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/services/settings_repository.dart';
import 'package:noah/services/skill_registry.dart';
import 'package:noah/ui/screens/skills_screen.dart';
import 'package:noah/ui/theme.dart';
import 'package:noah/ui/widgets/skill_selector_sheet.dart';

/// v1.49.0 per-chat skill selector sheet: selection round-trip contract of
/// [SkillSelectorSheet.show] (Apply / Use global default / Clear /
/// barrier-dismiss), checkbox prefill, wallet badge and the search filter.
/// No registry, no I/O — the sheet takes a plain [SkillOption] list.
void main() {
  const List<SkillOption> options = <SkillOption>[
    SkillOption(name: 'a', title: 'Alpha', description: 'alpha skill'),
    SkillOption(
      name: 'b',
      title: 'Beta',
      description: 'beta skill',
      wallet: true,
    ),
    SkillOption(name: 'c', title: 'Gamma', description: 'gamma skill'),
  ];

  late Future<List<String>?>? pending;

  Future<void> openSheet(
    WidgetTester tester, {
    List<String>? currentSelection,
  }) async {
    pending = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        locale: const Locale('en'),
        supportedLocales: const <Locale>[Locale('en'), Locale('id')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          zLocalizationsDelegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () {
                  pending = SkillSelectorSheet.show(
                    context,
                    options: options,
                    currentSelection: currentSelection,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder item(String name) => find.byKey(Key('skill-sheet-item-$name'));

  testWidgets('prefills the checkboxes from currentSelection and badges the '
      'wallet option', (WidgetTester tester) async {
    await openSheet(tester, currentSelection: <String>['a']);

    final CheckboxListTile tileA = tester.widget<CheckboxListTile>(item('a'));
    final CheckboxListTile tileB = tester.widget<CheckboxListTile>(item('b'));
    final CheckboxListTile tileC = tester.widget<CheckboxListTile>(item('c'));
    expect(tileA.value, isTrue);
    expect(tileB.value, isFalse);
    expect(tileC.value, isFalse);
    // Only the wallet-declared option carries the badge.
    expect(find.byIcon(Icons.account_balance_wallet_rounded), findsOneWidget);
    const AppStrings strings = AppStringsEn();
    expect(find.text(strings.skillSheetTitle), findsOneWidget);
    expect(find.text(strings.skillSheetHint), findsOneWidget);
  });

  testWidgets('tapping another option and applying resolves with the merged '
      'selection', (WidgetTester tester) async {
    await openSheet(tester, currentSelection: <String>['a']);

    await tester.tap(item('c'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('skill-sheet-apply')));
    await tester.pumpAndSettle();

    final List<String>? result = await pending;
    expect(result, <String>['a', 'c']);
  });

  testWidgets('Clear resolves with the empty selection', (
    WidgetTester tester,
  ) async {
    await openSheet(tester, currentSelection: <String>['a']);

    await tester.tap(find.byKey(const Key('skill-sheet-clear')));
    await tester.pumpAndSettle();

    expect(await pending, isEmpty);
  });

  testWidgets('Use global default resolves with null', (
    WidgetTester tester,
  ) async {
    await openSheet(tester, currentSelection: <String>['a']);

    await tester.tap(find.byKey(const Key('skill-sheet-use-global')));
    await tester.pumpAndSettle();

    expect(await pending, isNull);
  });

  testWidgets('the search field filters the visible options', (
    WidgetTester tester,
  ) async {
    await openSheet(tester);

    await tester.enterText(
      find.byKey(const Key('skill-sheet-search-field')),
      'beta',
    );
    await tester.pump();

    expect(item('b'), findsOneWidget);
    expect(item('a'), findsNothing);
    expect(item('c'), findsNothing);
  });

  testWidgets('a query with no match renders the empty hint', (
    WidgetTester tester,
  ) async {
    await openSheet(tester);

    await tester.enterText(
      find.byKey(const Key('skill-sheet-search-field')),
      'zzz',
    );
    await tester.pump();

    expect(item('a'), findsNothing);
    expect(item('b'), findsNothing);
    expect(item('c'), findsNothing);
    expect(find.text(const AppStringsEn().skillsEmptyTitle), findsOneWidget);
  });

  testWidgets('barrier dismissal resolves with the caller\'s current '
      'selection (unchanged)', (WidgetTester tester) async {
    await openSheet(tester, currentSelection: <String>['a']);

    // Tap the scrim ABOVE the sheet — showModalBottomSheet pops null and
    // show() must translate that into "keep the current selection".
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(await pending, <String>['a']);
  });

  testWidgets(
    'manage-skills shortcut pops the sheet and opens the Skills manager',
    (WidgetTester tester) async {
      // The pushed SkillsScreen watches the registry providers — the sheet
      // host gets the same REAL-registry-over-temp-dir overrides the
      // manager screen tests use (no mocks, empty install dir is fine).
      // runAsync: native IO must run OUTSIDE the FakeAsync zone — a bare
      // await here never completes (the future is delivered on the real
      // event loop, which FakeAsync does not pump).
      final Directory docs = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('skill_sheet_manage_test'),
      ))!;
      addTearDown(() async {
        if (await docs.exists()) await docs.delete(recursive: true);
      });
      final SkillRegistry registry = SkillRegistry(
        resolveBaseDir: () async => docs,
        secretBox: InMemorySecretBox(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            skillRegistryProvider.overrideWithValue(registry),
            bundledSkillCatalogProvider.overrideWith(
              (Ref ref) async => <BundledSkillInfo>[],
            ),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            locale: const Locale('en'),
            supportedLocales: const <Locale>[Locale('en'), Locale('id')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              zLocalizationsDelegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => Center(
                  child: TextButton(
                    onPressed: () {
                      pending = SkillSelectorSheet.show(
                        context,
                        options: options,
                        currentSelection: const <String>['a'],
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The shortcut pops the sheet (dismissing it must NOT apply the
      // selection — the pending future resolves with the caller's current
      // selection) and pushes the manager route.
      await tester.tap(find.byKey(const Key('skill-sheet-manage-skills')));

      // The manager loads through native file IO — drain the real event
      // loop (bounded) until no loading spinner remains; pumpAndSettle
      // would hang on the spinner inside the FakeAsync zone.
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

      // Advance the sheet-pop and screen-push transitions to completion
      // (fake-time pumps): the popped route's future — and therefore
      // `pending` — only completes when the pop animation ends.
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(find.byType(SkillsScreen), findsOneWidget);
      expect(screenLoading(), isFalse);
      expect(find.byKey(const Key('skill-sheet-search-field')), findsNothing);
      expect(await pending, <String>['a']);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
