import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/cron_job.dart';
import '../../models/models.dart' show AppSettings, ChatSummary;
import '../../services/cron_parser.dart';
import '../theme.dart';
import '../widgets/app_message.dart';
import 'ollama_manage_screen.dart';

/// Predefined schedule presets shown in the editor. Values are standard
/// 5-field cron expressions understood by [CronExpression].
const List<(String, String)> kCronSchedulePresets = <(String, String)>[
  ('* * * * *', 'every-minute'),
  ('*/5 * * * *', 'every-5-minutes'),
  ('0 * * * *', 'hourly'),
  ('0 8 * * *', 'daily-8'),
  ('0 9 * * mon-fri', 'weekdays-9'),
  ('0 9 * * sun', 'weekly-sun'),
  ('0 8 1 * *', 'monthly-1'),
];

/// Full-screen editor for one cron job (the "activity" behind the
/// Settings tile). Creates a job with any of the three action kinds —
/// Telegram message, local notification or headless agent task — and
/// validates the cron expression live, showing the next three fire
/// times before saving.
class CronJobEditorScreen extends ConsumerStatefulWidget {
  const CronJobEditorScreen({super.key, required this.job});

  /// The job to edit. Pass a fresh [CronJob] (empty id) to create one.
  final CronJob job;

  @override
  ConsumerState<CronJobEditorScreen> createState() =>
      _CronJobEditorScreenState();
}

class _CronJobEditorScreenState extends ConsumerState<CronJobEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _expression;
  late final TextEditingController _telegramToken;
  late final TextEditingController _telegramChatId;
  late final TextEditingController _message;
  late final TextEditingController _notifTitle;
  late final TextEditingController _notifText;
  late final TextEditingController _agentPrompt;

  late CronActionKind _action;

  /// Chat action target: '' = the OWNING chat (Noah default),
  /// otherwise the picked session id from [chatListProvider].
  String _chatTarget = '';

  /// Null while the expression parses; carries the error text otherwise.
  CronFormatException? _expressionError;

  bool get _isNew => widget.job.id.isEmpty;

  AppStrings get _strings => stringsOf(context);

  @override
  void initState() {
    super.initState();
    final CronJob job = widget.job;
    _name = TextEditingController(text: job.name);
    _expression = TextEditingController(text: job.expression);
    _telegramToken = TextEditingController(text: job.telegramToken);
    _telegramChatId = TextEditingController(text: job.telegramChatId);
    _message = TextEditingController(text: job.messageText);
    _notifTitle = TextEditingController(text: job.notifTitle);
    _notifText = TextEditingController(text: job.notifText);
    _agentPrompt = TextEditingController(text: job.agentPrompt);
    _action = job.action;
    _chatTarget = job.chatSessionId;
    _revalidate();
  }

  @override
  void dispose() {
    _name.dispose();
    _expression.dispose();
    _telegramToken.dispose();
    _telegramChatId.dispose();
    _message.dispose();
    _notifTitle.dispose();
    _notifText.dispose();
    _agentPrompt.dispose();
    super.dispose();
  }

  void _revalidate() {
    try {
      CronExpression.parse(_expression.text);
      _expressionError = null;
    } on CronFormatException catch (error) {
      _expressionError = error;
    }
  }

  /// The next up-to-3 fire times for the live preview, empty when the
  /// expression is invalid.
  List<DateTime> _upcoming() {
    if (_expressionError != null) return const <DateTime>[];
    final CronExpression parsed = CronExpression.parse(_expression.text);
    final List<DateTime> out = <DateTime>[];
    DateTime? next = parsed.nextAfter(DateTime.now());
    while (next != null && out.length < 3) {
      out.add(next);
      next = parsed.nextAfter(next);
    }
    return out;
  }

  String? _validate() {
    if (_name.text.trim().isEmpty) return _strings.cronNameRequired;
    if (_expressionError != null) return _strings.cronExpressionInvalid;
    switch (_action) {
      case CronActionKind.telegram:
        // Noah: per-job token/chat id are OPTIONAL — when empty the
        // global Telegram configuration (CronJobs screen) is used.
        if (_message.text.trim().isEmpty) {
          return _strings.cronMessageRequired;
        }
      case CronActionKind.notification:
        if (_notifText.text.trim().isEmpty) {
          return _strings.cronNotifTextRequired;
        }
      case CronActionKind.agent:
        if (_agentPrompt.text.trim().isEmpty) {
          return _strings.cronAgentPromptRequired;
        }
      case CronActionKind.chat:
        if (_agentPrompt.text.trim().isEmpty) {
          return _strings.cronChatPromptRequired;
        }
    }
    return null;
  }

  Future<void> _save() async {
    final String? problem = _validate();
    if (problem != null) {
      _snack(problem);
      return;
    }
    final CronJob saved = widget.job.copyWith(
      name: _name.text.trim(),
      expression: _expression.text.trim(),
      action: _action,
      telegramToken: _telegramToken.text.trim(),
      telegramChatId: _telegramChatId.text.trim(),
      messageText: _message.text,
      notifTitle: _notifTitle.text.trim(),
      notifText: _notifText.text,
      agentPrompt: _agentPrompt.text.trim(),
      chatSessionId: _chatTarget.trim(),
    );
    final String owner = saved.sessionId.isNotEmpty
        ? saved.sessionId
        : (ref.read(activeSessionIdProvider) ?? '');
    await ref.read(cronJobsProvider(owner).notifier).saveJob(saved);
    if (!mounted) return;
    // Close the editor FIRST, then surface the confirmation — the
    // feedback dialog lives on the ROOT navigator, so a pop() after
    // showing it would dismiss the DIALOG instead of this screen
    // (same ordering fix as PresetEditorScreen v1.49.6).
    final NavigatorState nav = Navigator.of(context);
    nav.pop();
    showAppMessage(nav.context, _strings.cronSaved);
  }

  void _snack(String message) {
    if (!mounted) return;
    showAppMessage(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = _strings;
    final ZPalette palette = context.palette;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? strings.cronNewTitle : strings.cronEditTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('cron-editor-save-appbar'),
            tooltip: strings.save,
            icon: const Icon(Icons.check_rounded),
            onPressed: _save,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            TextField(
              key: const Key('cron-editor-name-field'),
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: strings.cronFieldName,
                hintText: 'Daily report',
              ),
            ),
            const SizedBox(height: 16),

            // -- Schedule ------------------------------------------------
            Text(
              strings.cronFieldSchedule,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              key: const Key('cron-schedule-presets'),
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (String expr, String tag) in kCronSchedulePresets)
                  ActionChip(
                    key: Key('cron-preset-$tag'),
                    label: Text(_presetLabel(expr)),
                    onPressed: () {
                      _expression.text = expr;
                      setState(_revalidate);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('cron-editor-expression-field'),
              controller: _expression,
              onChanged: (_) => setState(_revalidate),
              keyboardType: TextInputType.text,
              decoration: InputDecoration(
                labelText: strings.cronFieldExpression,
                hintText: '30 8 * * *',
                helperText: strings.cronExpressionHint,
                errorText: _expressionError == null
                    ? null
                    : strings.cronExpressionInvalid,
              ),
            ),
            if (_expressionError == null && _upcoming().isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              _NextRunsPreview(upcoming: _upcoming()),
            ],
            const SizedBox(height: 16),

            // -- Action --------------------------------------------------
            // v1.50.0: four action kinds now — a SegmentedButton with four
            // icon+label segments overflows on 360dp phones, so the kinds
            // render as ChoiceChips in a Wrap (same visual language as the
            // schedule presets above).
            Text(
              strings.cronFieldAction,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              key: const Key('cron-editor-action-segmented'),
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (CronActionKind kind, IconData icon)
                    in const <(CronActionKind, IconData)>[
                      (
                        CronActionKind.notification,
                        Icons.notifications_none_rounded,
                      ),
                      (CronActionKind.telegram, Icons.send_outlined),
                      (CronActionKind.agent, Icons.smart_toy_outlined),
                      (CronActionKind.chat, Icons.forum_rounded),
                    ])
                  ChoiceChip(
                    key: Key('cron-action-chip-${kind.name}'),
                    avatar: Icon(
                      icon,
                      size: 16,
                      color: _action == kind ? null : palette.muted,
                    ),
                    label: Text(switch (kind) {
                      CronActionKind.notification =>
                        strings.cronActionNotification,
                      CronActionKind.telegram => strings.cronActionTelegram,
                      CronActionKind.agent => strings.cronActionAgent,
                      CronActionKind.chat => strings.cronActionChat,
                    }),
                    selected: _action == kind,
                    onSelected: (bool selected) {
                      if (selected) setState(() => _action = kind);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Local AI shortcut: when the ACTIVE provider is the built-in
            // `Local AI` preset, agent/chat jobs run against the
            // on-device llama-server. The tile (model name + jump into
            // Ollama Manage) appears only for those actions and ONLY for
            // Local AI users — zero visual delta for everyone else.
            if (_action == CronActionKind.agent ||
                _action == CronActionKind.chat)
              ..._localAiShortcut(strings, palette),
            ...switch (_action) {
              CronActionKind.notification => <Widget>[
                TextField(
                  key: const Key('cron-editor-notif-title-field'),
                  controller: _notifTitle,
                  decoration: InputDecoration(
                    labelText: strings.cronFieldNotifTitle,
                    hintText: 'Noah',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cron-editor-notif-text-field'),
                  controller: _notifText,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: strings.cronFieldNotifText,
                  ),
                ),
              ],
              CronActionKind.telegram => <Widget>[
                TextField(
                  key: const Key('cron-editor-telegram-token-field'),
                  controller: _telegramToken,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: strings.cronFieldTelegramToken,
                    hintText: '123456:ABC-DEF…',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cron-editor-telegram-chat-field'),
                  controller: _telegramChatId,
                  decoration: InputDecoration(
                    labelText: strings.cronFieldTelegramChat,
                    hintText: '123456789',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cron-editor-message-field'),
                  controller: _message,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: strings.cronFieldMessage,
                  ),
                ),
              ],
              CronActionKind.chat => <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: palette.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        strings.cronActionChatHint,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: palette.muted,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _ChatTargetDropdown(
                  value: _chatTarget,
                  onChanged: (String? value) =>
                      setState(() => _chatTarget = value ?? ''),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cron-editor-chat-prompt-field'),
                  controller: _agentPrompt,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: strings.cronFieldChatPrompt,
                  ),
                ),
              ],
              CronActionKind.agent => <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: palette.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        strings.cronActionAgentHint,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: palette.muted,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cron-editor-agent-prompt-field'),
                  controller: _agentPrompt,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: strings.cronFieldAgentPrompt,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cron-editor-agent-telegram-token-field'),
                  controller: _telegramToken,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: '${strings.cronFieldTelegramToken} (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cron-editor-agent-telegram-chat-field'),
                  controller: _telegramChatId,
                  decoration: InputDecoration(
                    labelText: '${strings.cronFieldTelegramChat} (optional)',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  strings.cronAgentRelayHint,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.muted,
                    height: 1.35,
                  ),
                ),
              ],
            },
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('cron-editor-save-button'),
              onPressed: _save,
              icon: const Icon(Icons.check_rounded),
              label: Text(strings.save),
            ),
          ],
        ),
      ),
    );
  }

  /// Local AI shortcut tile for agent/chat actions (see the insertion
  /// point in [build]). Returns nothing unless the ACTIVE provider is
  /// the built-in `Local AI` preset.
  List<Widget> _localAiShortcut(AppStrings strings, ZPalette palette) {
    final AppSettings settings = ref.watch(settingsProvider);
    if (settings.providerName != 'Local AI') return const <Widget>[];
    final String model = settings.model.trim();
    return <Widget>[
      const SizedBox(height: 12),
      Container(
        key: const Key('cron-local-ai-tile'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 2),
        decoration: BoxDecoration(
          color: palette.muted.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.muted.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.memory_rounded, size: 14, color: palette.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    model.isEmpty
                        ? strings.cronLocalAiNoModel
                        : strings.cronLocalAiHint(model),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: palette.muted,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('cron-local-ai-hint'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          const OllamaManageScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.dns_outlined, size: 16),
                label: Text(strings.cronOpenOllamaManage),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// Human label for a preset expression (falls back to the expression
  /// itself when it matches no preset).
  String _presetLabel(String expr) {
    final AppStrings strings = stringsOf(context);
    for (final (String preset, String tag) in kCronSchedulePresets) {
      if (preset != expr) continue;
      return switch (tag) {
        'every-minute' => strings.cronScheduleEveryMinute,
        'every-5-minutes' => strings.cronScheduleEvery5Minutes,
        'hourly' => strings.cronScheduleHourly,
        'daily-8' => strings.cronScheduleDaily8,
        'weekdays-9' => strings.cronScheduleWeekdays9,
        'weekly-sun' => strings.cronScheduleWeekly,
        'monthly-1' => strings.cronScheduleMonthly,
        _ => preset,
      };
    }
    return expr;
  }
}

/// Target-chat selector of the chat action (v1.50.0). Lists the stored
/// conversations (newest first) plus the "new chat per fire" option;
/// a persisted id that no longer resolves still shows as an entry so the
/// user sees the stale selection instead of a silent reset.
class _ChatTargetDropdown extends ConsumerWidget {
  const _ChatTargetDropdown({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final List<ChatSummary> sessions =
        ref.watch(chatListProvider).valueOrNull ?? const <ChatSummary>[];
    final bool knownTarget =
        value.isEmpty || sessions.any((ChatSummary s) => s.id == value);
    return DropdownButtonFormField<String>(
      key: const Key('cron-editor-chat-target-dropdown'),
      initialValue: value.isEmpty || knownTarget ? value : _staleSentinel,
      decoration: InputDecoration(labelText: strings.cronFieldChatTarget),
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(
          value: '',
          child: Text(strings.cronChatOwnerDefault),
        ),
        if (!knownTarget)
          DropdownMenuItem<String>(
            value: _staleSentinel,
            child: Text(
              strings.cronChatTargetMissing,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        for (final ChatSummary session in sessions)
          DropdownMenuItem<String>(
            value: session.id,
            child: Text(session.title, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (String? selected) =>
          onChanged(selected == _staleSentinel ? null : selected),
    );
  }

  /// Internal sentinel for a persisted-but-unresolvable target: shown so
  /// the stale id stays visible; selecting anything else drops it.
  static const String _staleSentinel = '__stale__';
}

/// Live preview of the next fire times under the expression field.
class _NextRunsPreview extends StatelessWidget {
  const _NextRunsPreview({required this.upcoming});

  final List<DateTime> upcoming;

  static String _fmt(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final ZPalette palette = context.palette;
    return Column(
      key: const Key('cron-next-runs-preview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          strings.cronNextRuns,
          style: TextStyle(fontSize: 11.5, color: palette.muted),
        ),
        const SizedBox(height: 2),
        for (final DateTime t in upcoming)
          Text(
            '• ${_fmt(t)}',
            style: TextStyle(
              fontSize: 11.5,
              color: palette.muted,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}
