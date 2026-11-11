import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/cron_job.dart';
import '../../models/models.dart';
import '../../services/cron_migration.dart';
import '../../services/cron_scheduler.dart' show CronDispatchResult;
import '../../services/scheduled_job_runner.dart';
import '../../services/telegram_sender.dart';
import '../theme.dart';
import '../widgets/app_message.dart';
import 'cron_job_editor_screen.dart';

/// Full-screen cron manager (the "activity" opened from the Settings
/// tile directly below Appearance). Noah merged manager (port
/// Fase 1): ONE screen for everything scheduled in the ACTIVE chat —
///
/// * the global Telegram channel config (fallback credentials for jobs
///   without their own token/chat id),
/// * the cron-expression jobs of THIS chat (ported from ZAgents:
///   telegram / notification / agent / chat actions, master switch,
///   run history), and
/// * any remaining LEGACY v1.51.0 jobs of this chat (one-shot and odd
///   intervals that cannot be expressed as cron — they keep firing via
///   the legacy engine; migratable kinds are converted automatically
///   on open and disappear from the legacy section).
///
/// Jobs belong to one chat each: data never mixes between chats.
class CronJobsScreen extends ConsumerStatefulWidget {
  const CronJobsScreen({super.key});

  @override
  ConsumerState<CronJobsScreen> createState() => _CronJobsScreenState();
}

class _CronJobsScreenState extends ConsumerState<CronJobsScreen> {
  final TextEditingController _token = TextEditingController();
  final TextEditingController _chatId = TextEditingController();
  bool _configLoaded = false;
  String _testStatus = '';

  String get _sessionId => ref.read(activeSessionIdProvider) ?? '';

  static String _fmt(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _loadConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) => _migrateLegacy());
  }

  @override
  void dispose() {
    _token.dispose();
    _chatId.dispose();
    super.dispose();
  }

  /// One-shot legacy → cron migration for the active chat (idempotent;
  /// recorded in the cron store itself).
  Future<void> _migrateLegacy() async {
    final String sid = _sessionId;
    if (sid.isEmpty) return;
    try {
      final int migrated = await CronLegacyMigration(
        cronRepo: ref.read(cronRepositoryProvider),
        legacyRepo: ref.read(scheduledJobRepositoryProvider),
      ).migrate(sid);
      if (!mounted) return;
      if (migrated > 0) {
        ref.invalidate(cronJobsProvider(sid));
        ref.invalidate(scheduledJobListProvider(sid));
      }
    } catch (_) {
      // Migration is best-effort: legacy jobs stay visible below.
    }
  }

  Future<void> _loadConfig() async {
    try {
      final TelegramConfig config = await ref
          .read(telegramConfigStoreProvider)
          .load();
      if (!mounted) return;
      _token.text = config.botToken;
      _chatId.text = config.chatId;
    } catch (_) {
      // Config storage unavailable (tests): fields stay empty.
    }
    if (mounted) setState(() => _configLoaded = true);
  }

  Future<void> _saveConfig() async {
    await ref
        .read(telegramConfigStoreProvider)
        .save(
          TelegramConfig(
            botToken: _token.text.trim(),
            chatId: _chatId.text.trim(),
          ),
        );
    if (mounted) showAppMessage(context, 'Telegram settings saved');
  }

  Future<void> _sendTest() async {
    setState(() => _testStatus = 'Sending…');
    final TelegramResult result = await TelegramSender().send(
      botToken: _token.text,
      chatId: _chatId.text,
      text: 'Noah CronJobs test message — your Telegram channel works.',
    );
    if (!mounted) return;
    setState(
      () => _testStatus = result.ok
          ? 'Test message sent ✓'
          : 'Failed: ${result.message}',
    );
  }

  void _openEditor(CronJob job) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CronJobEditorScreen(job: job)),
    );
  }

  Future<void> _confirmDelete(CronJob job) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('cron-delete-dialog'),
        title: Text(strings.cronDeleteTitle),
        content: Text(strings.cronDeleteBody(job.name)),
        actions: <Widget>[
          TextButton(
            key: const Key('cron-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('cron-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(cronJobsProvider(_sessionId).notifier).removeJob(job.id);
    }
  }

  Future<void> _runNow(CronJob job) async {
    final AppStrings strings = stringsOf(context);
    final CronDispatchResult result = await ref
        .read(cronSchedulerProvider)
        .runNow(job);
    if (!mounted) return;
    showAppMessage(context, '${strings.cronRunNowTooltip}: ${result.detail}');
  }

  Future<void> _deleteLegacy(ScheduledJob job) async {
    await ref.read(scheduledJobServiceProvider).remove(_sessionId, job.id);
    ref.invalidate(scheduledJobListProvider(_sessionId));
    if (mounted) setState(() {});
  }

  String _legacySummary(ScheduledJob j) {
    final String time =
        '${j.hour.toString().padLeft(2, '0')}:${j.minute.toString().padLeft(2, '0')}';
    return switch (j.kind) {
      JobScheduleKind.once =>
        'once · ${j.runAt?.toIso8601String().substring(0, 16).replaceAll('T', ' ') ?? '—'}',
      JobScheduleKind.daily => 'daily · $time',
      JobScheduleKind.weekly => 'weekly · day ${j.weekday} · $time',
      JobScheduleKind.interval => 'every ${j.intervalMinutes} min',
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? sessionId = ref.watch(activeSessionIdProvider);
    if (sessionId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('CronJobs')),
        body: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 48,
                color: context.zMuted,
              ),
              const SizedBox(height: 16),
              const Text(
                'Open a chat first',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'CronJobs belong to one chat each, so data never mixes '
                'between chats. Open a chat to manage its jobs.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.zMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    final AppStrings strings = stringsOf(context);
    final ZPalette palette = context.palette;
    final CronState state = ref.watch(cronJobsProvider(sessionId));
    final List<ScheduledJob> legacyJobs =
        ref.watch(scheduledJobListProvider(sessionId)).value ??
        const <ScheduledJob>[];
    final Map<String, String> chatTitles = <String, String>{
      for (final ChatSummary session
          in (ref.watch(chatListProvider).valueOrNull ?? const <ChatSummary>[]))
        session.id: session.title,
    };
    return Scaffold(
      appBar: AppBar(title: Text(strings.cronJobsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('cron-add-fab'),
        heroTag: 'cron-add-job-fab',
        tooltip: strings.cronAddJobTooltip,
        icon: const Icon(Icons.add_rounded),
        label: Text(strings.cronAddJobTooltip),
        onPressed: () => _openEditor(
          CronJob(
            id: newId(),
            sessionId: sessionId,
            name: '',
            expression: '',
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: <Widget>[
            // -- Telegram channel (global fallback) ----------------------
            Container(
              key: const Key('telegram-card'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.zSurface,
                borderRadius: BorderRadius.circular(kCardRadius),
                border: Border.all(color: context.zBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Row(
                    children: <Widget>[
                      Icon(Icons.send_rounded, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Telegram (fallback for jobs without their own)',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('telegram-token-field'),
                    controller: _token,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Bot token (stored encrypted)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('telegram-chat-id-field'),
                    controller: _chatId,
                    decoration: const InputDecoration(labelText: 'Chat ID'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      FilledButton(
                        key: const Key('telegram-save-button'),
                        onPressed: _configLoaded ? _saveConfig : null,
                        child: const Text('Save'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        key: const Key('telegram-test-button'),
                        onPressed: _sendTest,
                        child: const Text('Send test'),
                      ),
                    ],
                  ),
                  if (_testStatus.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(_testStatus, style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Master switch -------------------------------------------
            Card(
              child: SwitchListTile(
                key: const Key('cron-master-switch'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(strings.cronMasterTitle),
                subtitle: Text(
                  strings.cronMasterSubtitle,
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
                value: state.enabled,
                onChanged: (bool value) => ref
                    .read(cronJobsProvider(sessionId).notifier)
                    .setEnabled(value),
              ),
            ),
            Text(
              strings.cronRunsWhileAppOpen,
              style: TextStyle(
                fontSize: 11.5,
                color: palette.muted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),

            // -- Cron jobs -------------------------------------------------
            if (state.jobs.isEmpty)
              Card(
                key: const Key('cron-empty-card'),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: <Widget>[
                      Icon(
                        Icons.schedule_rounded,
                        size: 32,
                        color: palette.muted,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        strings.cronJobsEmptyTitle,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        strings.cronJobsEmptyBody,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: palette.muted,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else ...<Widget>[
              for (final CronJob job in state.jobs)
                _JobCard(
                  key: Key('cron-job-card-${job.id}'),
                  job: job,
                  fmt: _fmt,
                  chatTargetLabel: job.action == CronActionKind.chat
                      ? (chatTitles[job.chatSessionId.isEmpty
                                ? job.sessionId
                                : job.chatSessionId] ??
                            strings.cronChatTargetMissing)
                      : null,
                  onEdit: () => _openEditor(job),
                  onDelete: () => _confirmDelete(job),
                  onToggle: (bool value) => ref
                      .read(cronJobsProvider(sessionId).notifier)
                      .toggleJob(job.id, value),
                  onRunNow: () => _runNow(job),
                ),
            ],

            // -- Legacy jobs (not cron-expressible) ------------------------
            if (legacyJobs.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              const Text(
                'Legacy jobs',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'One-shot and non-divisor interval jobs from the previous '
                'scheduler. They cannot be expressed as cron, so they stay '
                'here and keep firing via the legacy engine until their '
                'single run.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: palette.muted,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              for (final ScheduledJob job in legacyJobs)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    key: Key('legacy-job-${job.id}'),
                    title: Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      <String>[
                        _legacySummary(job),
                        job.action.name,
                        if (job.lastStatus.isNotEmpty)
                          'last: ${job.lastStatus}',
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      key: Key('legacy-job-delete-${job.id}'),
                      tooltip: strings.delete,
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => _deleteLegacy(job),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 16),

            // -- History ---------------------------------------------------
            Text(
              strings.cronHistoryTitle,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (state.history.isEmpty)
              Text(
                strings.cronHistoryEmpty,
                style: TextStyle(fontSize: 12, color: palette.muted),
              )
            else ...<Widget>[
              for (final CronRunEntry entry in state.history)
                Padding(
                  key: Key('cron-history-row-${entry.jobId}-${entry.atMs}'),
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        entry.ok
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        size: 16,
                        color: entry.ok
                            ? const Color(0xFF2E9E5B)
                            : const Color(0xFFD0453E),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_fmt(DateTime.fromMillisecondsSinceEpoch(entry.atMs))} · '
                          '${entry.jobName} · ${entry.detail}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: palette.muted,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One job card: name + action icon, schedule, next/last run lines, the
/// enabled switch and the Run-now / delete actions.
class _JobCard extends StatelessWidget {
  const _JobCard({
    super.key,
    required this.job,
    required this.fmt,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
    required this.onRunNow,
    this.chatTargetLabel,
  });

  final CronJob job;
  final String Function(DateTime) fmt;

  /// Chat action only: human label of the target conversation (the
  /// owning chat by default in Noah). Null for other action kinds.
  final String? chatTargetLabel;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRunNow;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final ZPalette palette = context.palette;
    final IconData actionIcon = switch (job.action) {
      CronActionKind.notification => Icons.notifications_none_rounded,
      CronActionKind.telegram => Icons.send_outlined,
      CronActionKind.agent => Icons.smart_toy_outlined,
      CronActionKind.chat => Icons.forum_rounded,
    };
    final String? nextLine = job.nextRunAtMs == null
        ? null
        : '${strings.cronNextRunLabel}: ${fmt(DateTime.fromMillisecondsSinceEpoch(job.nextRunAtMs!))}';
    final String? lastLine = job.lastRunAtMs == null
        ? null
        : '${strings.cronLastRunLabel}: ${fmt(DateTime.fromMillisecondsSinceEpoch(job.lastRunAtMs!))}${job.lastResult.isEmpty ? '' : ' · ${job.lastResult}'}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(actionIcon, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      job.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!job.enabled)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        strings.cronDisabledBadge,
                        style: TextStyle(fontSize: 10.5, color: palette.muted),
                      ),
                    ),
                  Switch(
                    key: Key('cron-job-switch-${job.id}'),
                    value: job.enabled,
                    onChanged: onToggle,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                job.expression,
                style: TextStyle(
                  fontSize: 12,
                  color: palette.muted,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              if (chatTargetLabel != null)
                Text(
                  '→ $chatTargetLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.muted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              if (nextLine != null)
                Text(
                  nextLine,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.muted,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              if (lastLine != null)
                Text(
                  lastLine,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: job.lastResultOk
                        ? palette.muted
                        : const Color(0xFFD0453E),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    key: Key('cron-job-run-now-${job.id}'),
                    tooltip: strings.cronRunNowTooltip,
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: onRunNow,
                  ),
                  IconButton(
                    key: Key('cron-job-delete-${job.id}'),
                    tooltip: strings.delete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
