import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/context_repository.dart';
import 'package:noah/ui/screens/context_screen.dart';

import '../../test/support/test_doubles.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_context_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('context manager lists seeded entries and toggles usage', (
    tester,
  ) async {
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(dir: tempDir),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoahApp(),
      ),
    );
    await tester.pump();

    // Push the ContextScreen directly (Navigator lives below MaterialApp).
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const ContextScreen()),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    // Default entries are seeded (disabled).
    expect(find.byKey(const Key('context-list-page-0')), findsOneWidget);
    final ContextRepository repo = container.read(contextRepositoryProvider);
    final List<ContextEntry> seeded = repo.load();
    expect(seeded, isNotEmpty);

    // Enable the first entry via its switch.
    await tester.tap(find.byKey(Key('context-switch-${seeded.first.id}')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(
      repo
          .load()
          .firstWhere((ContextEntry e) => e.id == seeded.first.id)
          .enabled,
      isTrue,
    );
  });

  testWidgets('context search filters entries by name and content', (
    tester,
  ) async {
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(dir: tempDir),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoahApp(),
      ),
    );
    await tester.pump();
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const ContextScreen()),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    final ContextRepository repo = container.read(contextRepositoryProvider);
    final List<ContextEntry> seeded = repo.load();
    expect(seeded.length, greaterThanOrEqualTo(2));

    // Filter by name: only the matching entry stays visible.
    await tester.enterText(
      find.byKey(const Key('context-search-field')),
      seeded.first.name,
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.byKey(Key('context-${seeded.first.id}')), findsOneWidget);
    expect(find.byKey(Key('context-${seeded.last.id}')), findsNothing);

    // No match shows the localized empty state.
    await tester.enterText(
      find.byKey(const Key('context-search-field')),
      'zzz-no-match',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.text('No results'), findsOneWidget);
  });

  testWidgets('adding a context entry through the dialog persists it', (
    tester,
  ) async {
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(dir: tempDir),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoahApp(),
      ),
    );
    await tester.pump();
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const ContextScreen()),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    await tester.tap(find.byKey(const Key('context-add-fab')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.enterText(
      find.byKey(const Key('context-name-field')),
      'Always answer in Markdown',
    );
    await tester.enterText(
      find.byKey(const Key('context-content-field')),
      'Format every answer with Markdown.',
    );
    await tester.tap(find.byKey(const Key('context-save-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    final ContextRepository repo = container.read(contextRepositoryProvider);
    final List<ContextEntry> entries = repo.load();
    expect(
      entries.any((ContextEntry e) => e.name == 'Always answer in Markdown'),
      isTrue,
    );
    // New entries start enabled.
    expect(
      entries
          .firstWhere((ContextEntry e) => e.name == 'Always answer in Markdown')
          .enabled,
      isTrue,
    );
  });
}
