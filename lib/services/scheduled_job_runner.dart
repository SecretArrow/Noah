import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'background_service.dart';
import 'scheduled_job_service.dart';
import 'settings_repository.dart' show SecretBox;
import 'telegram_sender.dart';

/// Telegram configuration (v1.51.0): bot token in the encrypted
/// [SecretBox] (same pattern as provider API keys), chat id in plain
/// prefs (an identifier, not a credential).
class TelegramConfig {
  const TelegramConfig({this.botToken = '', this.chatId = ''});

  final String botToken;
  final String chatId;

  bool get isConfigured =>
      botToken.trim().isNotEmpty && chatId.trim().isNotEmpty;
}

/// Loads/saves the Telegram configuration. Implemented in di.dart wiring
/// over SecretBox + SharedPreferences; tests use a fake.
abstract class TelegramConfigStore {
  Future<TelegramConfig> load();
  Future<void> save(TelegramConfig config);
}

/// Best-effort scheduled-job engine (v1.51.0, Fase F).
///
/// Execution model (honest limits — see README/docs): jobs are checked
/// (a) when the app starts, (b) when it returns to the foreground, and
/// (c) on a periodic timer while the app process is alive. Android may
/// kill the process; there is NO AlarmManager/WorkManager precision
/// guarantee in this version — missed jobs are caught up at next launch.
///
/// Firing NEVER throws: every due job of the chat is processed in
/// order, one job's failure is recorded as its own lastStatus and does
/// not stop the others. Actions:
/// * notify/both → the EXISTING done-notification plumbing
///   ([BackgroundRun.notifyDone]); tapping the notification reopens the
///   owning chat through the existing pending-session routing;
/// * telegram/both → Telegram Bot API sendMessage; an unconfigured or
///   failing Telegram send is recorded as an error status but the
///   notification (for `both`) still goes out.
class ScheduledJobRunner {
  ScheduledJobRunner({
    required this.jobs,
    required this.notifications,
    required this.telegram,
    required this.configStore,
    required this.listSessionIds,
  });

  final ScheduledJobService jobs;
  final BackgroundRun notifications;
  final TelegramSender telegram;
  final TelegramConfigStore configStore;

  /// All chat session ids that may own jobs (from the chat store).
  final Future<List<String>> Function() listSessionIds;

  Timer? _timer;
  bool _ticking = false;

  /// Starts the while-alive periodic check (idempotent).
  void start() {
    _timer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(checkAll()),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Catch-up + due check across EVERY chat (jobs stay per-chat: each
  /// job only ever fires inside its own session's scope).
  Future<void> checkAll({DateTime? now}) async {
    if (_ticking) return;
    _ticking = true;
    try {
      final List<String> sessionIds = await listSessionIds();
      for (final String sessionId in sessionIds) {
        await checkChat(sessionId, now: now);
      }
    } catch (_) {
      // The engine is best-effort: a broken store must never crash the app.
    } finally {
      _ticking = false;
    }
  }

  Future<void> checkChat(String sessionId, {DateTime? now}) async {
    final DateTime at = now ?? DateTime.now();
    final List<ScheduledJob> due = jobs.dueJobs(sessionId, at);
    for (final ScheduledJob job in due) {
      await fire(job, firedAt: at);
    }
  }

  /// Fires ONE job: performs its action(s), then records the outcome via
  /// [ScheduledJobService.markFired]. Returns the status string.
  Future<String> fire(ScheduledJob job, {DateTime? firedAt}) async {
    final DateTime at = firedAt ?? DateTime.now();
    final List<String> problems = <String>[];
    final String text = job.message.trim().isEmpty
        ? job.title
        : '${job.title}\n${job.message.trim()}';
    if (job.action == JobAction.notify || job.action == JobAction.both) {
      try {
        await notifications.notifyDone(
          title: job.title,
          text: job.message.trim().isEmpty ? job.title : job.message.trim(),
          sessionId: job.sessionId,
        );
      } catch (_) {
        problems.add('notification failed');
      }
    }
    if (job.action == JobAction.telegram || job.action == JobAction.both) {
      try {
        final TelegramConfig config = await configStore.load();
        if (!config.isConfigured) {
          problems.add('telegram not configured');
        } else {
          final TelegramResult result = await telegram.send(
            botToken: config.botToken,
            chatId: config.chatId,
            text: text,
          );
          if (!result.ok) problems.add(result.message);
        }
      } catch (e) {
        problems.add('telegram error: $e');
      }
    }
    final String status = problems.isEmpty
        ? 'ok'
        : 'error: ${problems.join('; ')}';
    try {
      await jobs.markFired(job.sessionId, job.id, firedAt: at, status: status);
    } catch (_) {
      // Recording is best-effort too.
    }
    return status;
  }
}

/// Production [TelegramConfigStore]: token in the encrypted [SecretBox]
/// (key `noah.telegram.botToken`), chat id in SharedPreferences.
class PrefsTelegramConfigStore implements TelegramConfigStore {
  PrefsTelegramConfigStore({required this.secrets, required this.prefs});

  final SecretBox secrets;
  final SharedPreferences prefs;

  static const String tokenKey = 'noah.telegram.botToken';
  static const String chatIdKey = 'noah.telegram.chatId';

  @override
  Future<TelegramConfig> load() async {
    String token = '';
    try {
      token = await secrets.read(tokenKey) ?? '';
    } catch (_) {
      // Secret storage unavailable: treat as unconfigured.
    }
    return TelegramConfig(
      botToken: token,
      chatId: prefs.getString(chatIdKey) ?? '',
    );
  }

  @override
  Future<void> save(TelegramConfig config) async {
    try {
      if (config.botToken.trim().isEmpty) {
        await secrets.delete(tokenKey);
      } else {
        await secrets.write(tokenKey, config.botToken.trim());
      }
    } catch (_) {
      // Best-effort: chat id below still persists.
    }
    await prefs.setString(chatIdKey, config.chatId.trim());
  }
}

/// In-memory [TelegramConfigStore] for tests.
class MemoryTelegramConfigStore implements TelegramConfigStore {
  MemoryTelegramConfigStore([this._config = const TelegramConfig()]);

  TelegramConfig _config;

  @override
  Future<TelegramConfig> load() async => _config;

  @override
  Future<void> save(TelegramConfig config) async {
    _config = config;
  }
}
