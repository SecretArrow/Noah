import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/ip_guard.dart';

import '../../test/support/test_doubles.dart';

/// Drawer assertions must be scoped: chat texts also render in the body
/// behind the drawer (find.text matches those bubbles too).
Finder inDrawer(Finder finder) =>
    find.descendant(of: find.byType(Drawer), matching: finder);

/// Pumps the full app shell with two history chats and a chat-switch IP
/// guard whose probe always reports [ip]. The memo starts pre-seeded for
/// `c-1` with [ip] (so switching into chat One matches) and `198.51.100.9`
/// for `c-2` (so switching into chat Two compares different).
Future<ProviderContainer> pumpApp(
  WidgetTester tester,
  Directory tempDir, {
  required SharedPreferences prefs,
  required String ip,
  bool warnEnabled = true,
}) async {
  final IpGuard guard = IpGuard(prefs: prefs, fetchIp: () async => ip)
    ..recordMemo('c-1', ip)
    ..recordMemo('c-2', '198.51.100.9');

  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ...testOverrides(
          dir: tempDir,
          settings: AppSettings(
            apiKey: 'test-key',
            ipSwitchWarnEnabled: warnEnabled,
          ),
          writeScreenshots: false,
        ),
        // Static history: the real chat store does disk IO that never
        // completes inside the async test zone (drawer would spin forever).
        chatListProvider.overrideWith(
          (Ref ref) async => <ChatSummary>[
            ChatSummary(
              id: 'c-1',
              title: 'Chat One',
              updatedAt: DateTime(2025, 1, 1),
            ),
            ChatSummary(
              id: 'c-2',
              title: 'Chat Two',
              updatedAt: DateTime(2025, 1, 2),
            ),
          ],
        ),
        chatStoreProvider.overrideWithValue(MemoryChatStore()),
        ipGuardProvider.overrideWithValue(guard),
      ],
      child: Builder(
        builder: (BuildContext context) {
          container = ProviderScope.containerOf(context);
          return const NoahApp();
        },
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_ip_guard_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('SAME-IP switch warns; Cancel keeps the drawer open and never '
      'opens the target chat', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final ProviderContainer container = await pumpApp(
      tester,
      tempDir,
      prefs: prefs,
      ip: '203.0.113.50',
    );
    expect(container.read(chatControllerProvider).sessionId, isNull);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(Drawer), findsOneWidget);

    // Switch into Chat One: its memo matches the current IP -> warning.
    // The regrouped drawer (TABS/SPACES/CHANNELS headers + icon rows) is
    // taller, so the history viewport is tighter: align the row inside
    // the list before tapping (no-op when it is already on screen).
    await tester.ensureVisible(inDrawer(find.text('Chat One')));
    await tester.pumpAndSettle();
    await tester.tap(inDrawer(find.text('Chat One')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.byKey(const Key('ip-switch-warn-dialog')), findsOneWidget);
    expect(find.textContaining('203.0.113.50'), findsWidgets);

    await tester.tap(find.byKey(const Key('ip-switch-warn-cancel')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(
      find.byType(Drawer),
      findsOneWidget,
      reason: 'a cancelled switch must keep the drawer open',
    );
    expect(
      container.read(chatControllerProvider).sessionId,
      isNull,
      reason: 'a cancelled switch must not open the target chat',
    );
  });

  testWidgets('SAME-IP switch warns; Continue opens the chat and closes '
      'the drawer', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final ProviderContainer container = await pumpApp(
      tester,
      tempDir,
      prefs: prefs,
      ip: '203.0.113.50',
    );

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Align the history row inside the tighter viewport first (no-op
    // when it is already on screen).
    await tester.ensureVisible(inDrawer(find.text('Chat One')));
    await tester.pumpAndSettle();
    await tester.tap(inDrawer(find.text('Chat One')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byKey(const Key('ip-switch-warn-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ip-switch-warn-continue')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.byType(Drawer), findsNothing);
    expect(container.read(chatControllerProvider).sessionId, 'c-1');
  });

  testWidgets('a DIFFERENT IP switches instantly with no dialog', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final ProviderContainer container = await pumpApp(
      tester,
      tempDir,
      prefs: prefs,
      ip: '203.0.113.50',
    );

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // Second seeded row sits at the bottom of the tighter history
    // viewport — align it before the tap so the switch always lands.
    // Chat Two's memo (198.51.100.9) differs from the current IP: no
    // warning, the switch behaves exactly like the pre-guard flow.
    await tester.ensureVisible(inDrawer(find.text('Chat Two')));
    await tester.pumpAndSettle();
    await tester.tap(inDrawer(find.text('Chat Two')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.byKey(const Key('ip-switch-warn-dialog')), findsNothing);
    expect(find.byType(Drawer), findsNothing);
    expect(container.read(chatControllerProvider).sessionId, 'c-2');
  });

  testWidgets('the guard is inert when the setting is OFF', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final ProviderContainer container = await pumpApp(
      tester,
      tempDir,
      prefs: prefs,
      ip: '203.0.113.50',
      warnEnabled: false,
    );

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    // The memo for c-1 matches, but the guard is disabled: the switch must
    // proceed without any network probe or dialog.
    await tester.ensureVisible(inDrawer(find.text('Chat One')));
    await tester.pumpAndSettle();
    await tester.tap(inDrawer(find.text('Chat One')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.byKey(const Key('ip-switch-warn-dialog')), findsNothing);
    expect(find.byType(Drawer), findsNothing);
    expect(container.read(chatControllerProvider).sessionId, 'c-1');
  });
}
