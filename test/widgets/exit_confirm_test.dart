import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/main.dart';
import 'package:noah/ui/screens/home_shell.dart';

import '../support/test_doubles.dart';

/// v1.28.0: Android back on the root screen must ask for confirmation
/// (Yes / No) before the app leaves, so a running agent task is never
/// lost to a stray back press.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_exit_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[...testOverrides(dir: tempDir)],
        child: const NoahApp(),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(HomeShell), findsOneWidget);
  }

  testWidgets('back on the shell opens the exit confirmation dialog', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    // Root-route pop attempt (canPop: false) must trigger the dialog.
    final bool handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(handled, isTrue);
    expect(find.byKey(const Key('exit-confirm-dialog')), findsOneWidget);
    expect(find.byKey(const Key('exit-confirm-yes')), findsOneWidget);
    expect(find.byKey(const Key('exit-confirm-no')), findsOneWidget);
  });

  testWidgets('answering No keeps the app open', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const Key('exit-confirm-no')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.byKey(const Key('exit-confirm-dialog')), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('answering Yes dismisses the shell (SystemNavigator)', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const Key('exit-confirm-yes')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // SystemNavigator.pop() hits the platform channel, which is a no-op
    // in the test environment — the dialog itself must be gone, and the
    // shell stays (real devices close the activity).
    expect(find.byKey(const Key('exit-confirm-dialog')), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
  });
}
