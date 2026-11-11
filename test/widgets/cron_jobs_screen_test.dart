import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/cron_job.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/cron_repository.dart';
import 'package:noah/services/scheduled_job_repository.dart';
import 'package:noah/services/scheduled_job_runner.dart';
import 'package:noah/ui/screens/cron_jobs_screen.dart';

/// Port Fase 1 — the merged CronJobs screen (ZAgents cron manager +
/// Noah global Telegram fallback card) shows ONLY the active chat's
/// jobs (per-chat isolation).
void main() {
  CronJob job(String id, String name, String sessionId) => CronJob(
    id: id,
    name: name,
    sessionId: sessionId,
    expression: '0 9 * * *',
    action: CronActionKind.notification,
    notifTitle: name,
    notifText: 'body',
    createdAtMs: 0,
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    final MemoryCronRepository repo = MemoryCronRepository(<String, CronState>{
      's1': CronState(jobs: <CronJob>[job('a', 'Alpha job', 's1')]),
      's2': CronState(jobs: <CronJob>[job('b', 'Beta job', 's2')]),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          cronRepositoryProvider.overrideWithValue(repo),
          activeSessionIdProvider.overrideWithValue('s1'),
          telegramConfigStoreProvider.overrideWithValue(
            MemoryTelegramConfigStore(const TelegramConfig()),
          ),
          scheduledJobRepositoryProvider.overrideWithValue(
            InMemoryScheduledJobRepository(),
          ),
          chatListProvider.overrideWith(
            (ref) async => <ChatSummary>[
              ChatSummary(
                id: 's1',
                title: 'Owner Chat',
                updatedAt: DateTime(2026, 1, 1),
              ),
              ChatSummary(
                id: 's2',
                title: 'Other Chat',
                updatedAt: DateTime(2026, 1, 1),
              ),
            ],
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: <LocalizationsDelegate<dynamic>>[
            zLocalizationsDelegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: CronJobsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows only the active chats jobs + telegram fallback card', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.text('Alpha job'), findsOneWidget);
    expect(find.text('Beta job'), findsNothing);
    expect(find.byKey(const Key('telegram-card')), findsOneWidget);
    expect(find.byKey(const Key('telegram-token-field')), findsOneWidget);
    expect(find.byKey(const Key('telegram-test-button')), findsOneWidget);
    expect(find.byKey(const Key('cron-add-fab')), findsOneWidget);
    expect(find.byKey(const Key('cron-master-switch')), findsOneWidget);
    expect(find.byKey(const Key('cron-job-card-a')), findsOneWidget);
  });
}
