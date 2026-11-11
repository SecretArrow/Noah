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

/// v1.49.0 Skills manager screen — LEAN widget coverage against the REAL
/// SkillRegistry over a temp documents dir:
///
///  * title/subtitle + empty state, bundled install tiles (deterministic
///    catalog override), installed tile keys (Update hidden for builtin);
///  * the enable switch persisting enabled=false through the real registry;
///  * search filtering, the config sheet saving a plain value, the remove
///    confirm dialog, the URL install dialog (dialog-only — never a
///    network install) and the inspect sheet;
///  * one-tap bundled install through the REAL app asset (rootBundle —
///    no network, no file picker).
///
/// Zone note: widget tests run inside FakeAsync, where NATIVE file IO
/// (the registry's flushed writes) never completes on its own. Seeding
/// goes through [WidgetTester.runAsync]; every tap that persists something
/// is drained by [flushWrites] before assertions read the real registry.
void main() {
  late Directory docs;
  late InMemorySecretBox box;
  late SkillRegistry registry;

  const String demoMd =
      '---\nname: demo-skill\ntitle: Demo Skill\ndescription: demo skill\n'
      'version: 1.0.0\nconfig:\n'
      '  - name: API_KEY\n    secret: true\n    required: true\n'
      '  - name: REGION\n    required: false\n'
      '---\n\n# Demo\nDemo instructions body.\n';

  const String helperMd =
      '---\nname: helper-skill\ntitle: Helper Skill\n'
      'description: helper skill\nversion: 2.0.0\n'
      '---\n\n# Helper\nHelper body.\n';

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('skills_screen_test');
    box = InMemorySecretBox();
    registry = SkillRegistry(resolveBaseDir: () async => docs, secretBox: box);
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  /// Real on-disk install (no network) — outside the FakeAsync zone.
  Future<void> seed(WidgetTester tester, String bundledName, String skillMd) =>
      tester.runAsync(() async {
        await registry.installBundled(
          bundledName: bundledName,
          skillMd: skillMd,
        );
      });

  /// Yields to the REAL event loop (native file writes complete there) and
  /// pumps the fake zone afterwards, until [done] holds. Bounded so a
  /// broken write path can never hang the suite.
  Future<void> flushWrites(WidgetTester tester, bool Function() done) async {
    int guard = 0;
    while (!done() && guard++ < 50) {
      await tester.runAsync<void>(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  File configFile(String skillName) => File(
    '${docs.path}${Platform.pathSeparator}skills'
    '${Platform.pathSeparator}$skillName'
    '${Platform.pathSeparator}.zconfig.json',
  );

  BundledSkillInfo bundled(String name) => BundledSkillInfo(
    bundledName: name,
    name: name,
    title: 'Bundled $name',
    description: 'bundled skill tile',
    version: '1.0.0',
    wallet: false,
  );

  Widget host({List<BundledSkillInfo> catalog = const <BundledSkillInfo>[]}) =>
      ProviderScope(
        overrides: <Override>[
          // The REAL registry against the temp dir — every screen action
          // (toggle/configure/remove) persists through it, so assertions
          // read the exact instance production code writes to.
          skillRegistryProvider.overrideWithValue(registry),
          // Deterministic bundled catalog (the real one parses assets via
          // rootBundle; the fixed list keeps tiles stable per test).
          bundledSkillCatalogProvider.overrideWith((Ref ref) async => catalog),
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
          home: const SkillsScreen(),
        ),
      );

  testWidgets('renders the title, subtitle and the empty state when nothing '
      'is installed', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    const AppStrings strings = AppStringsEn();
    expect(find.text(strings.skillsTitle), findsOneWidget);
    expect(find.text(strings.skillsSubtitle), findsOneWidget);
    expect(find.byKey(const Key('skills-empty-title')), findsOneWidget);
    expect(find.byKey(const Key('skills-empty-body')), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('shows install tiles for bundled skills that are not installed '
      'yet', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(catalog: <BundledSkillInfo>[bundled('web3-wallet-basics')]),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('skill-bundled-web3-wallet-basics')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('skill-bundled-install-web3-wallet-basics')),
      findsOneWidget,
    );
  });

  testWidgets('renders installed tiles with status chip, switch and actions '
      '(Update hidden for a bundled source)', (WidgetTester tester) async {
    await seed(tester, 'demo-skill', demoMd);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('skill-tile-demo-skill')), findsOneWidget);
    expect(find.byKey(const Key('skill-status-demo-skill')), findsOneWidget);
    expect(find.byKey(const Key('skill-enabled-demo-skill')), findsOneWidget);
    expect(find.byKey(const Key('skill-configure-demo-skill')), findsOneWidget);
    expect(find.byKey(const Key('skill-inspect-demo-skill')), findsOneWidget);
    expect(find.byKey(const Key('skill-remove-demo-skill')), findsOneWidget);
    // builtin: installs cannot be re-downloaded — the Update action is
    // hidden (the registry refuses it honestly anyway).
    expect(find.byKey(const Key('skill-update-demo-skill')), findsNothing);
  });

  testWidgets('tapping the enable switch persists enabled=false through the '
      'real registry', (WidgetTester tester) async {
    await seed(tester, 'demo-skill', demoMd);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final Switch before = tester.widget<Switch>(
      find.byKey(const Key('skill-enabled-demo-skill')),
    );
    expect(before.value, isTrue);

    await tester.tap(find.byKey(const Key('skill-enabled-demo-skill')));
    await flushWrites(
      tester,
      () => registry.listSync().single.enabled == false,
    );

    final InstalledSkill? fresh = await registry.get('demo-skill');
    expect(fresh, isNotNull);
    expect(fresh!.enabled, isFalse, reason: 'the flag must hit registry.json');
    final Switch after = tester.widget<Switch>(
      find.byKey(const Key('skill-enabled-demo-skill')),
    );
    expect(after.value, isFalse);
  });

  testWidgets('the search field filters the installed tiles', (
    WidgetTester tester,
  ) async {
    await seed(tester, 'demo-skill', demoMd);
    await seed(tester, 'helper-skill', helperMd);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('skill-tile-demo-skill')), findsOneWidget);
    expect(find.byKey(const Key('skill-tile-helper-skill')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('skills-search-field')),
      'helper',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('skill-tile-helper-skill')), findsOneWidget);
    expect(find.byKey(const Key('skill-tile-demo-skill')), findsNothing);
  });

  testWidgets('configure sheet: saving persists a non-secret value through '
      'the real registry (an untouched secret stays unset)', (
    WidgetTester tester,
  ) async {
    await seed(tester, 'demo-skill', demoMd);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('skill-configure-demo-skill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skill-config-field-API_KEY')), findsOneWidget);
    expect(find.byKey(const Key('skill-config-field-REGION')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('skill-config-field-REGION')),
      'ap-southeast-1',
    );
    await tester.tap(find.byKey(const Key('skill-config-save')));
    final File cfg = configFile('demo-skill');
    await flushWrites(
      tester,
      () =>
          cfg.existsSync() && cfg.readAsStringSync().contains('ap-southeast-1'),
    );

    final InstalledSkill skill = (await registry.get('demo-skill'))!;
    final Map<String, String> stored = await registry.readConfig(
      skill,
      revealSecrets: true,
    );
    expect(stored['REGION'], 'ap-southeast-1');
    expect(stored.containsKey('API_KEY'), isFalse);
  });

  testWidgets('remove flow: the confirm dialog shows the localized strings '
      'and Delete uninstalls the skill', (WidgetTester tester) async {
    await seed(tester, 'demo-skill', demoMd);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('skill-remove-demo-skill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skill-remove-confirm')), findsOneWidget);
    const AppStrings strings = AppStringsEn();
    expect(find.text(strings.skillRemoveTitle), findsOneWidget);
    expect(find.text(strings.skillRemoveBody), findsOneWidget);

    await tester.tap(find.text(strings.delete));
    await flushWrites(tester, () => registry.listSync().isEmpty);

    expect(find.byKey(const Key('skill-tile-demo-skill')), findsNothing);
    expect(await registry.list(), isEmpty);
    expect(
      Directory(
        '${docs.path}${Platform.pathSeparator}skills'
        '${Platform.pathSeparator}demo-skill',
      ).existsSync(),
      isFalse,
    );
  });

  testWidgets('URL install opens the consent dialog only — no network in '
      'the test zone', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('skills-install-url')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skills-url-dialog')), findsOneWidget);
    expect(find.byKey(const Key('skills-url-field')), findsOneWidget);

    // Leave the screen idle again (nothing was installed).
    await tester.tap(find.text(const AppStringsEn().cancel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skills-url-dialog')), findsNothing);
    expect(await registry.list(), isEmpty);
  });

  testWidgets('inspect sheet shows the SKILL.md instructions and the skill '
      'file list', (WidgetTester tester) async {
    await seed(tester, 'demo-skill', demoMd);
    // One extra shipped file so the list section renders a row. Sync IO —
    // safe inside the fake zone.
    final Directory extra = Directory(
      '${docs.path}${Platform.pathSeparator}skills'
      '${Platform.pathSeparator}demo-skill'
      '${Platform.pathSeparator}references',
    )..createSync(recursive: true);
    File('${extra.path}${Platform.pathSeparator}guide.md')
        .writeAsStringSync('Guide');
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('skill-inspect-demo-skill')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('skill-inspect-sheet')), findsOneWidget);
    expect(find.byKey(const Key('skill-instructions')), findsOneWidget);
    expect(find.textContaining('Demo instructions body.'), findsOneWidget);
    expect(find.byKey(const Key('skill-file-0')), findsOneWidget);
  });

  testWidgets('one-tap bundled install runs the REAL asset install (no '
      'network) and turns the tile into an installed skill', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(catalog: <BundledSkillInfo>[bundled('web3-wallet-basics')]),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('skill-bundled-install-web3-wallet-basics')),
    );
    await flushWrites(tester, () => registry.listSync().isNotEmpty);

    final InstalledSkill? installed = await registry.get('web3-wallet-basics');
    expect(installed, isNotNull);
    expect(installed!.wallet, isTrue);
    expect(installed.source, 'builtin:web3-wallet-basics');
    expect(
      find.byKey(const Key('skill-tile-web3-wallet-basics')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('skill-bundled-install-web3-wallet-basics')),
      findsNothing,
      reason: 'the bundled tile disappears once the skill is installed',
    );
  });
}
