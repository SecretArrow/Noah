import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';

import 'di.dart';
import 'l10n/app_strings.dart';
import 'models/models.dart';
import 'services/context_repository.dart';
import 'services/cron_migration.dart';
import 'services/cron_repository.dart';
import 'services/cron_scheduler.dart';
import 'services/local_ai/local_model_store.dart';
import 'services/goal_repository.dart';
import 'services/memory_repository.dart';
import 'services/prompt_repository.dart';
import 'services/background_service.dart';
import 'services/chat_store.dart';
import 'services/reminder_repository.dart';
import 'services/scheduled_job_repository.dart';
import 'services/scheduled_job_runner.dart';
import 'services/scheduled_job_service.dart';
import 'services/telegram_sender.dart';

import 'services/settings_repository.dart';
import 'ui/lock_gate.dart';
import 'ui/screens/home_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android 15+ (targetSdk 35/36) enforces edge-to-edge: declare it
  // explicitly, then [insetGuardBuilder] (below, wired as MaterialApp
  // builder) keeps all content strictly between the system bars.
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Per-theme icon brightness (dark/light) is declared in the AppBarTheme
    // of buildDarkTheme/buildLightTheme and applied by every Scaffold.
  } catch (_) {
    // System UI channels are unavailable in some test environments.
  }
  final PrefsSettingsRepository settingsRepo =
      await PrefsSettingsRepository.create();
  final PrefsContextRepository contextRepo =
      await PrefsContextRepository.create();
  final PrefsMemoryRepository memoryRepo = await PrefsMemoryRepository.create();
  final PrefsGoalRepository goalRepo = await PrefsGoalRepository.create();
  final PrefsReminderRepository reminderRepo =
      await PrefsReminderRepository.create();
  final PrefsScheduledJobRepository jobRepo =
      await PrefsScheduledJobRepository.create();
  final PrefsCronRepository cronRepo = await PrefsCronRepository.create();
  // Local AI store (installed models + llama-server config).
  final PrefsLocalModelRepository localModelRepo =
      await PrefsLocalModelRepository.create();
  final FilePromptRepository promptRepo = FilePromptRepository(
    resolveBaseDir: getApplicationDocumentsDirectory,
  );
  final SharedPreferences appLockPrefs = await SharedPreferences.getInstance();
  // Per-chat "last seen public IP" memo storage of the chat-switch guard
  // (v1.48.0) — same async-at-boot pattern as the app-lock prefs.
  final SharedPreferences ipMemoPrefs = await SharedPreferences.getInstance();
  // A container handle is needed to boot the cron scheduler once the
  // widget tree is running (main() is the ONLY place the scheduler is
  // started, so widget tests never inherit a pending periodic timer).
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      settingsRepositoryProvider.overrideWithValue(settingsRepo),
      contextRepositoryProvider.overrideWithValue(contextRepo),
      promptRepositoryProvider.overrideWithValue(promptRepo),
      memoryRepositoryProvider.overrideWithValue(memoryRepo),
      goalRepositoryProvider.overrideWithValue(goalRepo),
      reminderRepositoryProvider.overrideWithValue(reminderRepo),
      scheduledJobRepositoryProvider.overrideWithValue(jobRepo),
      cronRepositoryProvider.overrideWithValue(cronRepo),
      localModelRepositoryProvider.overrideWithValue(localModelRepo),
      telegramConfigStoreProvider.overrideWithValue(
        PrefsTelegramConfigStore(
          secrets: const FlutterSecretBox(),
          prefs: appLockPrefs,
        ),
      ),
      appLockPrefsProvider.overrideWithValue(appLockPrefs),
      ipMemoPrefsProvider.overrideWithValue(ipMemoPrefs),
    ],
  );
  runApp(
    UncontrolledProviderScope(container: container, child: const NoahApp()),
  );
  // Cron scheduler (ZAgents port, Fase 1): seed the known sessions with
  // every stored chat, migrate legacy jobs per chat, then start the
  // 15 s tick. Jobs only ever fire inside their owning chat's scope.
  unawaited(() async {
    try {
      final ChatStore seedStore = ChatStore(
        resolveBaseDir: getApplicationDocumentsDirectory,
      );
      final CronLegacyMigration migration = CronLegacyMigration(
        cronRepo: cronRepo,
        legacyRepo: jobRepo,
      );
      for (final ChatSummary summary in await seedStore.listSummaries()) {
        container.read(cronKnownSessionsProvider).add(summary.id);
        await migration.migrate(summary.id);
      }
    } catch (_) {
      // Seeding/migration is best-effort; the screen re-runs migration
      // for the active chat on open.
    }
    await container.read(cronSchedulerProvider).start();
  }());
  // CronJobs engine (v1.51.0): best-effort — a minute timer while the
  // process lives plus this start-up catch-up pass. Started OUTSIDE
  // the widget tree on purpose (no pending-timer hazards in tests,
  // which never call main()).
  final ChatStore bootStore = ChatStore(
    resolveBaseDir: getApplicationDocumentsDirectory,
  );
  final ScheduledJobRunner runner = ScheduledJobRunner(
    jobs: ScheduledJobService(jobRepo),
    notifications: BackgroundRunService(),
    telegram: TelegramSender(),
    configStore: PrefsTelegramConfigStore(
      secrets: const FlutterSecretBox(),
      prefs: appLockPrefs,
    ),
    listSessionIds: () async => <String>[
      for (final ChatSummary s in await bootStore.listSummaries()) s.id,
    ],
  );
  runner.start();
  unawaited(runner.checkAll());
}

/// v1.49.0 — keeps EVERY screen, dialog, bottom sheet, drawer and
/// snackbar strictly between the Android status bar (notification bar,
/// top) and the navigation bar (system back-home area, bottom).
///
/// Android 15+ (targetSdk 35/36) enforces edge-to-edge: the window always
/// extends under both system bars and there is no manifest opt-out.
/// Padding each screen by hand is fragile — any new route without
/// SafeArea regresses (list bottoms and dialog buttons slid under the
/// bars exactly this way). Instead the WHOLE Navigator is padded once
/// here and the consumed insets are reported as zero to the tree below:
///   * app content can never reach the notification bar or the system
///     navigation area, on any route, including dialogs/sheets/drawers
///     and snackbars;
///   * existing SafeArea widgets see zero extra padding (no double
///     spacing) — they keep working unchanged;
///   * the keyboard stays untouched: MediaQuery.padding collapses when
///     the keyboard overlaps the nav bar (padding = viewPadding −
///     viewInsets), so no phantom gap appears while typing;
///   * the strip behind the transparent system bars is painted with the
///     scaffold background color, so the bars blend with the app in both
///     themes.
Widget insetGuardBuilder(BuildContext context, Widget? child) {
  final MediaQueryData mq = MediaQuery.of(context);
  final double top = mq.padding.top;
  final double bottom = mq.padding.bottom;
  if (top <= 0 && bottom <= 0) {
    return child ?? const SizedBox.shrink();
  }
  return ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: MediaQuery(
        data: mq
            .removePadding(removeTop: true, removeBottom: true)
            .removeViewPadding(removeTop: true, removeBottom: true),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}

class NoahApp extends ConsumerWidget {
  const NoahApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild the tree only when the language or theme preference changes;
    // other settings (API key, model, …) are read further down the tree.
    final String languageCode = ref.watch(
      settingsProvider.select((s) => s.languageCode),
    );
    final ThemeModeSetting themeSetting = ref.watch(
      settingsProvider.select((s) => s.themeMode),
    );
    final ThemeMode themeMode = switch (themeSetting) {
      ThemeModeSetting.light => ThemeMode.light,
      ThemeModeSetting.dark => ThemeMode.dark,
      ThemeModeSetting.system => ThemeMode.system,
    };
    return MaterialApp(
      title: 'Noah',
      debugShowCheckedModeBanner: false,
      builder: insetGuardBuilder,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      // Explicit locale (never the device locale): English is the default
      // until the user picks Bahasa Indonesia in Settings.
      locale: Locale(languageCode),
      supportedLocales: const <Locale>[Locale('en'), Locale('id')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        zLocalizationsDelegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const LockGate(child: HomeShell()),
    );
  }
}
