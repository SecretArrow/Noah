import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/main.dart';
import 'package:noah/ui/screens/home_shell.dart';

import '../support/test_doubles.dart';

/// v1.49.0 — the activity must never draw under the Android status bar
/// (notification bar, top) nor under the system navigation area (bottom).
///
/// Android 15+ enforces edge-to-edge, so the guarantee is implemented in
/// [insetGuardBuilder] (MaterialApp.builder): the whole navigator is
/// padded by the top/bottom system insets and the consumed insets are
/// reported as zero downstream. These tests pin that contract at both
/// levels:
///   1. the builder in isolation (exact geometry, no double padding);
///   2. the real NoahApp shell + a dialog (user-visible geometry).
/// Sets the fake system-bar insets (in LOGICAL pixels — FakeViewPadding
/// takes physical pixels, so the value is scaled by the device pixel
/// ratio here) and resets them when the test ends.
void fakeInsets(
  WidgetTester tester, {
  required double top,
  required double bottom,
}) {
  final double dpr = tester.view.devicePixelRatio;
  tester.view.padding = FakeViewPadding(top: top * dpr, bottom: bottom * dpr);
  addTearDown(tester.view.resetPadding);
}

void main() {
  group('insetGuardBuilder (isolated)', () {
    const double topInset = 40;
    const double bottomInset = 24;

    testWidgets('content starts below the status bar and stops above the '
        'navigation bar', (WidgetTester tester) async {
      late MediaQueryData seen;
      fakeInsets(tester, top: topInset, bottom: bottomInset);
      await tester.pumpWidget(
        MaterialApp(
          builder: insetGuardBuilder,
          home: Scaffold(
            appBar: AppBar(title: const Text('title')),
            body: Builder(
              builder: (BuildContext context) {
                seen = MediaQuery.of(context);
                return const Center(child: Text('body'));
              },
            ),
          ),
        ),
      );

      final double screenH =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;

      // Top: the AppBar (and therefore every screen) begins BELOW the
      // notification bar — exactly at the inset, not one pixel higher.
      expect(
        tester.getTopLeft(find.byType(AppBar)).dy,
        moreOrLessEquals(topInset),
      );

      // Bottom: the scaffold ends ABOVE the navigation bar area.
      expect(
        tester.getBottomRight(find.byType(Scaffold)).dy,
        moreOrLessEquals(screenH - bottomInset),
      );

      // The consumed insets are reported as zero downstream: existing
      // SafeArea widgets must not add the inset a second time.
      expect(seen.padding.top, 0);
      expect(seen.padding.bottom, 0);
      expect(seen.viewPadding.top, 0);
      expect(seen.viewPadding.bottom, 0);
    });

    testWidgets('no-inset views pass through untouched', (
      WidgetTester tester,
    ) async {
      fakeInsets(tester, top: 0, bottom: 0);
      await tester.pumpWidget(
        MaterialApp(
          builder: insetGuardBuilder,
          home: Scaffold(
            appBar: AppBar(title: const Text('title')),
            body: const Center(child: Text('body')),
          ),
        ),
      );

      expect(tester.getTopLeft(find.byType(AppBar)).dy, 0);
      expect(
        tester.getBottomRight(find.byType(Scaffold)).dy,
        moreOrLessEquals(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        ),
      );
    });
  });

  group('NoahApp real shell under system insets', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('zagents_inset_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> pumpApp(WidgetTester tester) async {
      fakeInsets(tester, top: 40, bottom: 24);
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

    testWidgets('app bar is below the notification bar and the composer is '
        'above the system navigation area', (WidgetTester tester) async {
      await pumpApp(tester);

      final double screenH =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;

      // The main app bar must start at/below the status-bar inset.
      expect(
        tester.getTopLeft(find.byType(AppBar).first).dy,
        greaterThanOrEqualTo(39.5),
      );

      // The composer (bottom-most shell element) must end above the
      // navigation-bar inset: nothing may sit under the system menu.
      final Finder composer = find.byKey(const Key('composer-field'));
      if (composer.evaluate().isNotEmpty) {
        expect(
          tester.getBottomRight(composer).dy,
          lessThanOrEqualTo(screenH - 23.5),
        );
      }
    });

    testWidgets('dialogs (exit confirmation) stay above the navigation bar', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);

      // Open the root-route exit dialog the same way the Android back
      // button does.
      final bool handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(handled, isTrue);
      expect(find.byKey(const Key('exit-confirm-dialog')), findsOneWidget);

      final double screenH =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;

      // The dialog card itself must clear both bars — with the guard the
      // dialog route is laid out inside the padded navigator, so its
      // bottom edge can never enter the nav-bar strip.
      final Finder dialog = find.ancestor(
        of: find.byKey(const Key('exit-confirm-yes')),
        matching: find.byType(AlertDialog),
      );
      expect(dialog, findsOneWidget);
      expect(
        tester.getBottomRight(dialog.first).dy,
        lessThanOrEqualTo(screenH - 23.5),
      );
      expect(tester.getTopLeft(dialog.first).dy, greaterThanOrEqualTo(39.5));
    });
  });
}
