import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/ui/screens/briefing_screen.dart';
import 'package:noah/ui/screens/cron_jobs_screen.dart';
import 'package:noah/ui/screens/reminders_screen.dart';
import 'package:noah/ui/screens/settings_screen.dart';

import '../support/test_doubles.dart';

/// Fase E/F widget tests (v1.51.0): per-chat screens render only the
/// active chat's data, and — the user's explicit placement request —
/// Settings shows "CronJobs" directly below Appearance, opening the
/// full-screen CronJobsScreen.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('noah_ef_screens');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          dir: tempDir,
          remindersBySession: <String, List<ReminderEntry>>{
            'test-session': <ReminderEntry>[
              ReminderEntry(
                id: 'r1',
                title: 'Water the plants',
                dueAt: DateTime.now().add(const Duration(hours: 3)),
                createdAt: DateTime(2026, 1, 1),
                updatedAt: DateTime(2026, 1, 1),
              ),
            ],
          },
          jobsBySession: <String, List<ScheduledJob>>{
            'test-session': <ScheduledJob>[
              ScheduledJob(
                id: 'j1',
                sessionId: 'test-session',
                title: 'Morning digest',
                message: 'Good morning',
                kind: JobScheduleKind.daily,
                hour: 7,
                minute: 30,
                nextRunAt: DateTime.now().add(const Duration(hours: 5)),
                createdAt: DateTime(2026, 1, 1),
                updatedAt: DateTime(2026, 1, 1),
              ),
              ScheduledJob(
                id: 'j2',
                sessionId: 'test-session',
                title: 'Weekly report',
                message: 'Report time',
                kind: JobScheduleKind.weekly,
                weekday: 5,
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

  Future<void> push(WidgetTester tester, Widget screen) async {
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => screen)));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
  }

  testWidgets('RemindersScreen lists this chat reminders', (tester) async {
    await pumpApp(tester);
    await push(tester, const RemindersScreen());
    expect(find.byKey(const Key('reminder-add-fab')), findsOneWidget);
    expect(find.text('Water the plants'), findsOneWidget);
  });

  testWidgets('CronJobsScreen lists multiple jobs + telegram card', (
    tester,
  ) async {
    await pumpApp(tester);
    await push(tester, const CronJobsScreen());
    expect(find.byKey(const Key('telegram-card')), findsOneWidget);
    expect(find.byKey(const Key('telegram-token-field')), findsOneWidget);
    expect(find.byKey(const Key('telegram-test-button')), findsOneWidget);
    expect(find.text('Morning digest'), findsOneWidget);
    // The merged manager is one long ListView: the second (migrated)
    // job sits below the fold of the default test surface — drag the
    // list up until it is built.
    final Finder list = find.descendant(
      of: find.byType(CronJobsScreen),
      matching: find.byType(ListView),
    );
    for (
      int i = 0;
      i < 12 && find.text('Weekly report').evaluate().isEmpty;
      i++
    ) {
      await tester.drag(list, const Offset(0, -320));
      await tester.pump(const Duration(milliseconds: 350));
    }
    expect(find.text('Weekly report'), findsOneWidget);
    expect(find.byKey(const Key('cron-add-fab')), findsOneWidget);
  });

  testWidgets('BriefingScreen summarizes the active chat', (tester) async {
    await pumpApp(tester);
    await push(tester, const BriefingScreen());
    expect(find.byKey(const Key('briefing-list')), findsOneWidget);
    expect(find.textContaining('Water the plants'), findsOneWidget);
    expect(find.textContaining('Morning digest'), findsOneWidget);
  });

  testWidgets('Settings: CronJobs sits below Appearance and opens the '
      'full CronJobsScreen', (tester) async {
    await pumpApp(tester);
    await push(tester, const SettingsScreen());
    final Finder appearance = find.text('APPEARANCE');
    final Finder cronTile = find.byKey(const Key('cronjobs-tile'));
    expect(appearance, findsOneWidget);
    expect(cronTile, findsOneWidget);
    expect(
      tester.getTopLeft(cronTile).dy,
      greaterThan(tester.getTopLeft(appearance).dy),
      reason: 'CronJobs entry must be BELOW the Appearance section',
    );
    await tester.ensureVisible(cronTile);
    await tester.pump();
    await tester.tap(cronTile);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.byType(CronJobsScreen), findsOneWidget);
    expect(find.byKey(const Key('telegram-card')), findsOneWidget);
  });
}
