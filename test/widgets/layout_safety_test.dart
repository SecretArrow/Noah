import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/model_catalog.dart';

import '../support/test_doubles.dart';
import 'model_picker_test.dart' show ScriptedModelCatalog;

/// Layout-safety regression tests: the app must render without layout
/// overflows (RenderFlex exceptions) on small screens and with long model
/// ids — overflow would push app bar content into the status bar area and
/// the composer into the system navigation bar on edge-to-edge devices.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_layout_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap({
    AppSettings? settings,
    List<Override> extra = const <Override>[],
  }) => ProviderScope(
    overrides: <Override>[
      ...testOverrides(
        dir: tempDir,
        settings: settings ?? AppSettings(apiKey: 'k'),
      ),
      ...extra,
    ],
    child: const NoahApp(),
  );

  void useSmallScreen(
    WidgetTester tester, {
    Size size = const Size(1080, 1920),
  }) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'home renders without overflow on a small screen with a long model id',
    (WidgetTester tester) async {
      useSmallScreen(tester); // 360 x 640 logical pixels

      await tester.pumpWidget(
        wrap(
          settings: AppSettings(
            apiKey: 'k',
            model: 'anthropic/claude-sonnet-4.5-20250929-thinking',
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home renders without overflow on a tiny screen', (
    WidgetTester tester,
  ) async {
    useSmallScreen(tester, size: const Size(900, 1600)); // 300 x 533 dp

    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('settings screen renders without overflow on a small screen', (
    WidgetTester tester,
  ) async {
    useSmallScreen(tester); // 360 x 640 logical pixels

    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('model picker sheet survives an open keyboard inset', (
    WidgetTester tester,
  ) async {
    useSmallScreen(tester); // 360 x 640 logical pixels

    await tester.pumpWidget(
      wrap(
        settings: AppSettings(apiKey: 'k', model: 'z-ai/glm-4.6'),
        extra: <Override>[
          modelCatalogProvider.overrideWithValue(
            ScriptedModelCatalog(
              models: <RemoteModel>[
                for (var i = 0; i < 25; i++)
                  RemoteModel(
                    id: 'vendor/model-$i',
                    name: 'vendor/model-$i',
                    supportsTools: true,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('model-chip')));
    await tester.pumpAndSettle();

    // Simulate the keyboard being visible while the search field is used.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    // The sheet must stay within the screen: no layout exception.
    expect(tester.takeException(), isNull);

    // Header ("Pick a model") must still be on screen, i.e. not pushed
    // above the top edge by the keyboard inset.
    final Finder header = find.text('Pick a model');
    expect(header, findsOneWidget);
    final Offset top = tester.getTopLeft(header);
    expect(top.dy, greaterThanOrEqualTo(0));
  });
}
