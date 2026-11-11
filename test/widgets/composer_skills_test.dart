import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/services/settings_repository.dart';
import 'package:noah/services/skill_registry.dart';
import 'package:noah/ui/widgets/composer.dart';

import '../support/test_doubles.dart';

/// v1.49.0 (wave-2) — the composer skill multi-select icon:
///
///  * the `composer-skills` icon exists and sits EXACTLY LEFT of the
///    upload/attach icon (user requirement);
///  * tapping it opens the SkillSelectorSheet offering the enabled+ready
///    skills (a skill missing required config is NOT offered);
///  * Apply persists the selection into the CURRENT chat's state via
///    ChatController.setActiveSkills.
///
/// Zone note (same as skills_screen_test.dart): the REAL registry is
/// seeded through [WidgetTester.runAsync] because flushed file IO never
/// completes inside the FakeAsync test zone. After seeding, the tap-path
/// only performs microtask work (in-memory secret box + loaded cache), so
/// plain pumping suffices.
void main() {
  late Directory docs;
  late InMemorySecretBox box;
  late SkillRegistry registry;

  const String demoMd =
      '---\nname: demo-skill\ntitle: Demo Skill\ndescription: demo skill\n'
      'version: 1.0.0\nconfig:\n'
      '  - name: API_KEY\n    secret: true\n    required: true\n'
      '---\n\n# Demo\nDemo instructions body.\n';

  const String helperMd =
      '---\nname: helper-skill\ntitle: Helper Skill\n'
      'description: helper skill\nversion: 2.0.0\n'
      '---\n\n# Helper\nHelper body.\n';

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('composer_skills_test');
    box = InMemorySecretBox();
    registry = SkillRegistry(resolveBaseDir: () async => docs, secretBox: box);
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  Future<void> seedBoth(WidgetTester tester) => tester.runAsync(() async {
    await registry.installBundled(bundledName: 'demo-skill', skillMd: demoMd);
    await registry.installBundled(
      bundledName: 'helper-skill',
      skillMd: helperMd,
    );
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    late final ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(dir: docs, writeScreenshots: false),
          skillRegistryProvider.overrideWithValue(registry),
        ],
        child: Builder(
          builder: (BuildContext context) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                zLocalizationsDelegate,
              ],
              supportedLocales: const <Locale>[Locale('en'), Locale('id')],
              home: const Scaffold(body: Composer()),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the skills icon exists and sits EXACTLY LEFT of the upload '
      'icon', (WidgetTester tester) async {
    await seedBoth(tester);
    await pump(tester);

    final Finder skills = find.byKey(const Key('composer-skills'));
    final Finder attach = find.byKey(const Key('attach-button'));
    expect(skills, findsOneWidget);
    expect(attach, findsOneWidget);

    final Rect skillsRect = tester.getRect(skills);
    final Rect attachRect = tester.getRect(attach);
    expect(
      skillsRect.left,
      lessThan(attachRect.left),
      reason: 'the multi-select must sit LEFT of the upload icon',
    );
    expect(
      skillsRect.right,
      lessThanOrEqualTo(attachRect.left + 1),
      reason: 'adjacent — no other control between skills and upload',
    );
    // Same toolbar row.
    expect(skillsRect.top, attachRect.top);
    // Localized tooltip (accessibility).
    expect(
      find.byTooltip(const AppStringsEn().composerSkillsTooltip),
      findsOneWidget,
    );
  });

  testWidgets('tap opens the selector sheet with the ENABLED+READY skills '
      'and Apply persists into the chat state', (WidgetTester tester) async {
    await seedBoth(tester);
    final ProviderContainer container = await pump(tester);

    // Fresh scope = fresh draft: nothing pinned yet.
    expect(container.read(chatControllerProvider).activeSkills, isEmpty);

    await tester.tap(find.byKey(const Key('composer-skills')));
    await tester.pumpAndSettle();

    // The sheet is up. demo-skill is missing its required API_KEY config
    // → NOT offerable; helper-skill is ready → offered.
    expect(find.byKey(const Key('skill-sheet-search-field')), findsOneWidget);
    expect(
      find.byKey(const Key('skill-sheet-item-helper-skill')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('skill-sheet-item-demo-skill')),
      findsNothing,
      reason: 'only enabled+ready skills are offered',
    );

    // Select helper-skill and Apply.
    await tester.tap(find.byKey(const Key('skill-sheet-item-helper-skill')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('skill-sheet-apply')));
    await tester.pumpAndSettle();

    expect(container.read(chatControllerProvider).activeSkills, <String>[
      'helper-skill',
    ], reason: 'Apply must persist the selection into the chat state');
    // The sheet is gone.
    expect(find.byKey(const Key('skill-sheet-apply')), findsNothing);

    // Re-opening pre-fills the saved selection (per-chat memory).
    await tester.tap(find.byKey(const Key('composer-skills')));
    await tester.pumpAndSettle();
    final CheckboxListTile tile = tester.widget<CheckboxListTile>(
      find.byKey(const Key('skill-sheet-item-helper-skill')),
    );
    expect(
      tile.value,
      isTrue,
      reason: 'the saved selection pre-fills the checkboxes',
    );
    await tester.pumpAndSettle();
  });
}
