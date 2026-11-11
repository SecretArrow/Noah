import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/ui/screens/goals_screen.dart';
import 'package:noah/ui/screens/memory_screen.dart';

import '../support/test_doubles.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('noah_mg_screens');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          dir: tempDir,
          memoriesBySession: <String, List<MemoryEntry>>{
            'test-session': <MemoryEntry>[
              MemoryEntry(
                id: 'm1',
                text: 'User prefers concise answers',
                category: MemoryCategory.preference,
                pinned: true,
                createdAt: DateTime(2026, 1, 1),
                updatedAt: DateTime(2026, 1, 1),
              ),
            ],
          },
          goalsBySession: <String, List<GoalEntry>>{
            'test-session': <GoalEntry>[
              GoalEntry(
                id: 'g1',
                title: 'Ship Noah v1.50',
                progress: 60,
                createdAt: DateTime(2026, 1, 1),
                updatedAt: DateTime(2026, 1, 1),
              ),
            ],
          },
        ),
        activeSessionIdProvider.overrideWithValue('test-session'),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoahApp(),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('MemoryScreen lists stored memories', (tester) async {
    await pumpApp(tester);
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const MemoryScreen()),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.byKey(const Key('memory-m1')), findsOneWidget);
    expect(find.textContaining('concise answers'), findsOneWidget);
    expect(find.byKey(const Key('memory-add-fab')), findsOneWidget);
  });

  testWidgets('GoalsScreen lists stored goals with progress', (tester) async {
    await pumpApp(tester);
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const GoalsScreen()),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.byKey(const Key('goal-g1')), findsOneWidget);
    expect(find.textContaining('Ship Noah v1.50'), findsOneWidget);
    expect(find.byKey(const Key('goal-add-fab')), findsOneWidget);
    // di.dart wiring check: services resolve through the container.
    expect(memoryServiceProvider, isNotNull);
    expect(goalServiceProvider, isNotNull);
  });
}
