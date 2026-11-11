import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'browser_automation.dart';
import 'browser_session_isolation.dart';
import 'device_shell.dart';
import 'file_system_service.dart';
import 'js_runtime.dart';
import 'goal_service.dart';
import 'memory_service.dart';
import 'reminder_service.dart';
import '../models/cron_job.dart';
import 'cron_migration.dart';
import 'cron_tool_service.dart';
import 'scheduled_job_service.dart';
import 'module_registry.dart';
import 'module_runtime.dart';
import 'npm_service.dart';
import 'skill_registry.dart';
import 'subagents.dart';
import 'web_fetcher.dart';

/// Result of executing one tool.
class ToolResult {
  const ToolResult({
    required this.ok,
    required this.llmOutput,
    this.screenshotPath,
    this.displayText,
    this.data,
  });

  final bool ok;

  /// Content sent back to the model as the tool message.
  final String llmOutput;

  /// Optional screenshot path to render in the UI.
  final String? screenshotPath;

  /// Optional short label for the UI.
  final String? displayText;

  /// Optional structured payload for the controller (e.g. the staged
  /// module repair metadata behind `module_stage_repair`).
  final Map<String, dynamic>? data;
}

/// Executes agent tools: embedded browser automation, page JS, file IO
/// scoped to the app documents directory, and the embedded Node.js-style
/// JS runtime with npm package management.
class ToolExecutor {
  ToolExecutor({
    required this.browser,
    required this.resolveBaseDir,
    required this.isAutomationEnabled,
    this.js,
    this.npm,
    this.fs,
    this.fsFor,
    this.fetcher,
    this.modules,
    this.moduleRuntime,
    this.subagents,
    this.skills,
    this.deviceStatus,
    this.bundledSkills,
    this.memory,
    this.goals,
    this.reminders,
    this.cronJobs,
    this.cronStore,
  });

  final BrowserAutomation browser;

  /// Yields the workspace root for the given chat session id — isolated
  /// per session ("private window"). `null` = legacy shared root
  /// (documents dir), used by call sites that predate sessions.
  final Future<Directory> Function(String? sessionId) resolveBaseDir;
  final bool Function() isAutomationEnabled;

  /// Embedded JS runtime + npm manager. Nullable so existing tests and
  /// minimal setups keep working; the node tools degrade gracefully.
  final JsRuntime? js;
  final NpmService? npm;

  /// File workspace (zip/unzip + sandboxed paths). Nullable for legacy
  /// tests; the zip tools degrade gracefully when absent.
  final FileSystemService? fs;

  /// Session-aware workspace factory, preferred over [fs] when set:
  /// archive tools operate on the calling session's own sandbox.
  final FileSystemService? Function(String? sessionId)? fsFor;

  /// Server-side URL fetcher behind the `web_fetch` tool. Nullable for
  /// legacy tests; the tool degrades gracefully when absent.
  final WebFetcher? fetcher;

  /// Installed chat-module registry behind the module doctor tools
  /// (`module_list` / `module_read` / `module_export` /
  /// `module_stage_repair`). Nullable for legacy tests; the tools
  /// degrade gracefully when absent.
  final ModuleRegistry? modules;

  /// Chat-module RUNTIME behind the per-chat setup state reported by
  /// `module_list` (v1.33.0): whether each module's setup form is
  /// already completed for the CURRENT chat. Nullable for legacy tests;
  /// the status degrades to the manifest-declared form only.
  final ModuleRuntime? moduleRuntime;

  /// Fan-of-subagents runner behind `spawn_subagents`. Nullable for
  /// legacy tests; the tool degrades gracefully when absent.
  final SubagentRunner? subagents;

  /// Installed-skills registry behind the `skill_*` tools (v1.38.0).
  /// Nullable for legacy tests; the tools degrade gracefully when absent.
  final SkillRegistry? skills;

  /// Device-state probe behind the `device_status` tool (v1.32.0):
  /// verified airplane state (world-readable, NO root) + root
  /// availability. Nullable for legacy tests; the tool degrades
  /// gracefully when absent. The root probe is expensive (`su -c id -u`),
  /// so its outcome is cached for the process lifetime — root status
  /// never changes while the app runs.
  final DeviceShellService? Function()? deviceStatus;

  /// v1.38.1 — bundled-skill loader behind `skill_install builtin:<name>`:
  /// returns the SKILL.md contents carried in the app binary (di wires
  /// rootBundle; tests inject a plain map). Nullable for legacy tests —
  /// the builtin path then reports "loader unavailable".
  final Future<Map<String, String>> Function()? bundledSkills;

  /// Long-term memory behind the `memory_*` tools (v1.50.0). Nullable
  /// for legacy tests; the tools degrade gracefully when absent.
  final MemoryService? memory;

  /// User goals behind the `goal_*` tools (v1.50.0). Nullable for
  /// legacy tests; the tools degrade gracefully when absent.
  final GoalService? goals;

  /// Reminders behind the `reminder_*` tools (v1.51.0). Nullable for
  /// legacy tests; the tools degrade gracefully when absent.
  final ReminderService? reminders;

  /// Scheduled jobs behind the `cron_*` tools (v1.51.0). Nullable for
  /// legacy tests; the tools degrade gracefully when absent.
  final ScheduledJobService? cronJobs;

  /// Cron-expression job store (port Fase 1): when present, the
  /// `cron_*` tools create/list/toggle/delete REAL cron jobs for the
  /// calling chat. One-shot jobs (no cron equivalent) still fall back
  /// to the legacy [cronJobs] service.
  final CronToolService? cronStore;

  /// Cached root-availability outcome (null = not probed yet).
  bool? _rootAvailable;

  static const Set<String> _browserTools = <String>{
    'browser_navigate',
    'browser_click',
    'browser_type',
    'browser_scroll',
    'browser_screenshot',
    'browser_extract_text',
    'run_js',
  };

  Future<ToolResult> execute(
    String name,
    Map<String, dynamic> args, {
    String? sessionId,
    String? browserContext,
    bool Function()? shouldAbort,
  }) async {
    // v1.37.0 — parallel browser contexts: when the caller pins a named
    // context (a fan-of-subagents worker), browser tools run in THAT
    // context's own engine instead of the chat's default one. File tools
    // stay scoped to the session workspace regardless.
    final BrowserAutomation browserApi =
        (browserContext == null || browserContext.isEmpty)
        ? browser
        : browser.withContext(browserContext);
    try {
      switch (name) {
        case 'todo_write':
          return _todoWrite(args);
        case 'browser_context_create':
          return await _browserContextCreate(args, sessionId);
        case 'browser_context_list':
          return await _browserContextList(sessionId);
        case 'browser_context_close':
          return await _browserContextClose(args, sessionId);
        case 'browser_navigate':
          return await _navigate(args, sessionId, browserApi);
        case 'browser_click':
          return await _click(args, sessionId, browserApi);
        case 'browser_type':
          return await _type(args, sessionId, browserApi);
        case 'browser_scroll':
          return await _scroll(args, sessionId, browserApi);
        case 'browser_screenshot':
          return await _screenshot(sessionId, browserApi);
        case 'browser_extract_text':
          return await _extract(args, sessionId, browserApi);
        case 'run_js':
          return await _runJs(args, sessionId, browserApi);
        case 'read_file':
          return await _readFile(args, sessionId);
        case 'write_file':
          return await _writeFile(args, sessionId);
        case 'unzip_file':
          return await _unzipFile(args, sessionId);
        case 'zip_file':
          return await _zipFile(args, sessionId);
        case 'node_run':
          return await _nodeRun(args, sessionId);
        case 'node_install':
          return await _nodeInstall(args);
        case 'node_remove':
          return await _nodeRemove(args);
        case 'web_fetch':
          return await _webFetch(args);
        case 'git_clone':
          return await _gitClone(args, sessionId);
        case 'git_status':
          return await _gitStatus(args, sessionId);
        case 'git_commit':
          return await _gitCommit(args, sessionId);
        case 'git_push':
          return await _gitPush(args, sessionId);
        case 'git_log':
          return await _gitLog(args, sessionId);
        case 'module_list':
          return await _moduleList(sessionId);
        case 'module_read':
          return await _moduleRead(args);
        case 'module_export':
          return await _moduleExport(args, sessionId);
        case 'module_stage_repair':
          return await _moduleStageRepair(args, sessionId);
        case 'spawn_subagents':
          return await _spawnSubagents(args, sessionId, shouldAbort);
        case 'skill_install':
          return await _skillInstall(args, sessionId);
        case 'skill_list':
          return await _skillList();
        case 'skill_info':
          return await _skillInfo(args);
        case 'skill_config':
          return await _skillConfig(args);
        case 'skill_remove':
          return await _skillRemove(args);
        case 'skill_update':
          return await _skillUpdate(args);
        case 'skill_run':
          return await _skillRun(args, sessionId);
        case 'memory_save':
          return await _memorySave(args, sessionId);
        case 'memory_recall':
          return _memoryRecall(args, sessionId);
        case 'memory_list':
          return _memoryList(args, sessionId);
        case 'memory_forget':
          return await _memoryForget(args, sessionId);
        case 'goal_create':
          return await _goalCreate(args, sessionId);
        case 'goal_list':
          return _goalList(args, sessionId);
        case 'goal_update':
          return await _goalUpdate(args, sessionId);
        case 'goal_complete':
          return await _goalComplete(args, sessionId);
        case 'reminder_create':
          return await _reminderCreate(args, sessionId);
        case 'reminder_list':
          return _reminderList(args, sessionId);
        case 'reminder_complete':
          return await _reminderComplete(args, sessionId);
        case 'cron_create':
          return await _cronCreate(args, sessionId);
        case 'cron_list':
          return _cronList(args, sessionId);
        case 'cron_update':
          return await _cronUpdate(args, sessionId);
        case 'cron_delete':
          return await _cronDelete(args, sessionId);
        case 'skill_save':
          return await _skillSave(args);
        case 'device_status':
          return await _deviceStatus();
        default:
          return ToolResult(ok: false, llmOutput: 'Unknown tool: $name');
      }
    } catch (e) {
      // Never let a tool failure crash the agent loop: degrade to a result
      // the model can read and retry around.
      return ToolResult(ok: false, llmOutput: 'Tool $name failed: $e');
    }
  }

  /// `spawn_subagents` (v1.28.0): runs 1..N independent subagent loops in
  /// parallel and returns their labeled answers together. The runner is
  /// optional (legacy tests); the calling session's id scopes every nested
  /// tool call to the same per-chat sandbox.
  Future<ToolResult> _spawnSubagents(
    Map<String, dynamic> args,
    String? sessionId,
    bool Function()? shouldAbort,
  ) async {
    final SubagentRunner? runner = subagents;
    if (runner == null) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'spawn_subagents is unavailable in this build (no runner '
            'configured).',
      );
    }
    final (List<SubagentTaskSpec> tasks, String? error) = runner.parseTasks(
      args['tasks'],
    );
    if (error != null) {
      return ToolResult(ok: false, llmOutput: 'spawn_subagents: $error');
    }
    if (shouldAbort?.call() ?? false) {
      return const ToolResult(ok: false, llmOutput: 'spawn_subagents aborted');
    }
    final List<SubagentOutcome> outcomes = await runner.run(
      tasks,
      sessionId: sessionId,
      shouldAbort: shouldAbort,
    );
    return ToolResult(
      ok: true,
      llmOutput: runner.formatOutcomes(outcomes),
      displayText: 'subagents ×${outcomes.length}',
    );
  }

  /// `device_status` (v1.32.0): the verified device facts the agent needs
  /// to ground airplane-mode workflows — the REAL airplane state (world
  /// readable, no root) and whether `su` is available (rooted phone).
  /// Grounding matters: the agent can now CHECK a user's "yes, airplane
  /// is on/off" claim instead of trusting it blindly.
  Future<ToolResult> _deviceStatus() async {
    final DeviceShellService? Function()? resolve = deviceStatus;
    final DeviceShellService? shell = resolve?.call();
    if (shell == null) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'device_status is unavailable in this build (no shell bridge).',
      );
    }
    final bool? airplane = await shell.readAirplaneMode();
    if (_rootAvailable == null) {
      // One-shot probe with a short budget: `su -c id -u` prints 0 on a
      // rooted phone; anything else (missing su, user denial, timeout)
      // counts as "no root". Cached — root never changes at runtime.
      final DeviceShellResult probe = await shell.run(
        command: 'id -u',
        root: true,
        timeoutMs: 5000,
      );
      _rootAvailable =
          probe.succeeded &&
          probe.stdout.trim().split(RegExp(r'\s+')).last == '0';
    }
    final String airplaneText = airplane == null
        ? 'unknown (this platform cannot report it)'
        : airplane
        ? 'ON'
        : 'OFF';
    return ToolResult(
      ok: true,
      llmOutput:
          'Device status:\n'
          '- airplane_mode: $airplaneText\n'
          '- root_available: ${_rootAvailable!}\n'
          'Note: with airplane_mode ON the device has no internet — chat '
          'requests to the AI provider will fail until the user turns it '
          'back off (auto-retry then resumes the task automatically).',
      displayText:
          'airplane: ${airplane == null ? "?" : (airplane ? "ON" : "OFF")}, root: ${_rootAvailable!}',
    );
  }

  // -- Long-term memory & goals (v1.50.0) --------------------------------

  MemoryCategory _memoryCategory(Object? raw) =>
      memoryCategoryFromName(raw?.toString());

  Future<ToolResult> _memorySave(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final MemoryService? svc = memory;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'memory_save is unavailable in this build.',
      );
    }
    final MemoryEntry? entry = await svc.add(
      sessionId ?? '',
      args['text']?.toString() ?? '',
      category: _memoryCategory(args['category']),
      pinned: args['pinned'] == true,
    );
    if (entry == null) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'memory_save failed: empty text, duplicate, or the 500-entry '
            'memory limit was reached.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput:
          'Saved memory ${entry.id} [${entry.category.name}]: '
          '${entry.text}',
      displayText: 'memory saved',
    );
  }

  ToolResult _memoryRecall(Map<String, dynamic> args, String? sessionId) {
    final MemoryService? svc = memory;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'memory_recall is unavailable in this build.',
      );
    }
    final String query = args['query']?.toString() ?? '';
    final List<MemoryEntry> hits = svc.search(
      sessionId ?? '',
      query,
      limit: 10,
    );
    if (hits.isEmpty) {
      return const ToolResult(ok: true, llmOutput: 'No memories found.');
    }
    return ToolResult(
      ok: true,
      llmOutput: <String>[
        for (final MemoryEntry e in hits)
          '- ${e.id} [${e.category.name}]${e.pinned ? ' (pinned)' : ''} '
              '${e.text}',
      ].join('\n'),
      displayText: 'memories ×${hits.length}',
    );
  }

  ToolResult _memoryList(Map<String, dynamic> args, String? sessionId) {
    final MemoryService? svc = memory;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'memory_list is unavailable in this build.',
      );
    }
    List<MemoryEntry> entries = svc.search(sessionId ?? '', '', limit: 50);
    final Object? cat = args['category'];
    if (cat != null && cat.toString().isNotEmpty) {
      final MemoryCategory wanted = _memoryCategory(cat);
      entries = entries.where((MemoryEntry e) => e.category == wanted).toList();
    }
    if (entries.isEmpty) {
      return const ToolResult(ok: true, llmOutput: 'No memories stored.');
    }
    return ToolResult(
      ok: true,
      llmOutput: <String>[
        for (final MemoryEntry e in entries)
          '- ${e.id} [${e.category.name}]${e.pinned ? ' (pinned)' : ''} '
              '${e.text}',
      ].join('\n'),
      displayText: 'memories ×${entries.length}',
    );
  }

  Future<ToolResult> _memoryForget(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final MemoryService? svc = memory;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'memory_forget is unavailable in this build.',
      );
    }
    final String id = args['id']?.toString() ?? '';
    final bool removed = id.isNotEmpty && await svc.forget(sessionId ?? '', id);
    return ToolResult(
      ok: removed,
      llmOutput: removed
          ? 'Forgot memory $id.'
          : 'memory_forget failed: no memory with id $id.',
    );
  }

  // -- Reminders (v1.51.0, per-chat) ------------------------------------

  ReminderRepeat _reminderRepeat(Object? raw) =>
      switch (raw?.toString().toLowerCase()) {
        'daily' => ReminderRepeat.daily,
        'weekly' => ReminderRepeat.weekly,
        _ => ReminderRepeat.none,
      };

  Future<ToolResult> _reminderCreate(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final ReminderService? svc = reminders;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'reminder_create is unavailable in this build.',
      );
    }
    final DateTime? dueAt = DateTime.tryParse(args['dueAt']?.toString() ?? '');
    if (dueAt == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'reminder_create failed: dueAt must be ISO-8601.',
      );
    }
    final ReminderEntry? entry = await svc.create(
      sessionId ?? '',
      args['title']?.toString() ?? '',
      detail: args['detail']?.toString() ?? '',
      dueAt: dueAt,
      repeat: _reminderRepeat(args['repeat']),
    );
    if (entry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'reminder_create failed: empty title.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput:
          'Reminder saved for this chat: ${entry.id} "${entry.title}" '
          'due ${entry.dueAt.toIso8601String()} (repeat ${entry.repeat.name}).',
    );
  }

  ToolResult _reminderList(Map<String, dynamic> args, String? sessionId) {
    final ReminderService? svc = reminders;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'reminder_list is unavailable in this build.',
      );
    }
    final List<ReminderEntry> entries = svc.list(sessionId ?? '');
    if (entries.isEmpty) {
      return const ToolResult(
        ok: true,
        llmOutput: 'No reminders in this chat.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput: entries
          .map(
            (ReminderEntry e) =>
                '- ${e.id} · ${e.dueAt.toIso8601String()} · '
                '${e.repeat.name}${e.done ? ' · done' : ''} · ${e.title}',
          )
          .join('\n'),
    );
  }

  Future<ToolResult> _reminderComplete(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final ReminderService? svc = reminders;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'reminder_complete is unavailable in this build.',
      );
    }
    final ReminderEntry? entry = await svc.complete(
      sessionId ?? '',
      args['id']?.toString() ?? '',
    );
    if (entry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'reminder_complete failed: unknown reminder id.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput: entry.done
          ? 'Reminder done: ${entry.id}.'
          : 'Reminder rolled to next occurrence: ${entry.dueAt.toIso8601String()}.',
    );
  }

  // -- CronJobs (per-chat, multi-job; cron expressions since the
  // ZAgents port) ------------------------------------------------------

  JobScheduleKind _jobKind(Object? raw) =>
      switch (raw?.toString().toLowerCase()) {
        'daily' => JobScheduleKind.daily,
        'weekly' => JobScheduleKind.weekly,
        'interval' => JobScheduleKind.interval,
        _ => JobScheduleKind.once,
      };

  JobAction _jobAction(Object? raw) => switch (raw?.toString().toLowerCase()) {
    'telegram' => JobAction.telegram,
    'both' => JobAction.both,
    _ => JobAction.notify,
  };

  CronActionKind _cronAction(Object? raw) =>
      switch (raw?.toString().toLowerCase()) {
        'telegram' => CronActionKind.telegram,
        'agent' => CronActionKind.agent,
        'chat' => CronActionKind.chat,
        _ => CronActionKind.notification,
      };

  /// Builds the cron expression for a create call: an explicit valid
  /// `expression` wins; otherwise the legacy kind fields are converted
  /// (daily/weekly/interval). Returns null for one-shot jobs, which
  /// stay on the legacy service.
  String? _cronExpressionFor(Map<String, dynamic> args) {
    final String explicit = args['expression']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final ScheduledJob probe = ScheduledJob(
      id: 'probe',
      sessionId: 'probe',
      title: 'probe',
      kind: _jobKind(args['kind']),
      hour: (args['hour'] as num?)?.toInt() ?? 9,
      minute: (args['minute'] as num?)?.toInt() ?? 0,
      weekday: (args['weekday'] as num?)?.toInt() ?? 1,
      intervalMinutes: (args['intervalMinutes'] as num?)?.toInt() ?? 60,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    return CronLegacyMigration.expressionFor(probe);
  }

  Future<ToolResult> _cronCreate(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final String sid = sessionId ?? '';
    final CronToolService? store = cronStore;
    final String? expression = _cronExpressionFor(args);
    if (store != null && expression != null) {
      final String title = args['title']?.toString().trim() ?? '';
      final String message = args['message']?.toString() ?? '';
      final String prompt =
          args['prompt']?.toString() ?? args['agentPrompt']?.toString() ?? '';
      if (title.isEmpty) {
        return const ToolResult(
          ok: false,
          llmOutput: 'cron_create failed: empty title.',
        );
      }
      final String actionRaw = args['action']?.toString().toLowerCase() ?? '';
      final List<CronActionKind> kinds = actionRaw == 'both'
          ? const <CronActionKind>[
              CronActionKind.telegram,
              CronActionKind.notification,
            ]
          : <CronActionKind>[_cronAction(args['action'])];
      CronJob? last;
      for (final CronActionKind kind in kinds) {
        last = await store.add(
          sid,
          CronJob(
            id: newId(),
            sessionId: sid,
            name: title,
            expression: expression,
            action: kind,
            telegramToken: args['telegramToken']?.toString() ?? '',
            telegramChatId: args['telegramChatId']?.toString() ?? '',
            messageText: message,
            notifTitle: title,
            notifText: message,
            agentPrompt: prompt.isNotEmpty ? prompt : message,
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      if (last == null) {
        return const ToolResult(
          ok: false,
          llmOutput: 'cron_create failed: no active chat session.',
        );
      }
      return ToolResult(
        ok: true,
        llmOutput:
            'Cron job created for this chat: ${last.id} "$title" '
            '($expression, ${kinds.map((k) => k.name).join('+')}) next run '
            '${last.nextRunAtMs == null ? '—' : DateTime.fromMillisecondsSinceEpoch(last.nextRunAtMs!).toIso8601String()}.',
      );
    }
    // Legacy fallback: one-shot jobs (no cron equivalent) and builds
    // without the cron store keep the v1.51.0 behavior.
    final ScheduledJobService? svc = cronJobs;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'cron_create is unavailable in this build.',
      );
    }
    final ScheduledJob? job = await svc.create(
      sid,
      title: args['title']?.toString() ?? '',
      message: args['message']?.toString() ?? '',
      kind: _jobKind(args['kind']),
      action: _jobAction(args['action']),
      runAt: DateTime.tryParse(args['runAt']?.toString() ?? ''),
      hour: (args['hour'] as num?)?.toInt() ?? 9,
      minute: (args['minute'] as num?)?.toInt() ?? 0,
      weekday: (args['weekday'] as num?)?.toInt() ?? 1,
      intervalMinutes: (args['intervalMinutes'] as num?)?.toInt() ?? 60,
    );
    if (job == null) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'cron_create failed: empty title/message or the 100-job '
            'per-chat limit was reached.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput:
          'Job created for this chat: ${job.id} "${job.title}" '
          '(${job.kind.name}, ${job.action.name}) next run '
          '${job.nextRunAt?.toIso8601String() ?? '—'}.',
    );
  }

  ToolResult _cronList(Map<String, dynamic> args, String? sessionId) {
    final String sid = sessionId ?? '';
    final List<String> lines = <String>[];
    final CronToolService? store = cronStore;
    if (store != null) {
      for (final CronJob j in store.list(sid)) {
        lines.add(
          '- ${j.id} · cron "${j.expression}" · ${j.action.name} · '
          '${j.enabled ? 'enabled' : 'disabled'} · next '
          '${j.nextRunAtMs == null ? '—' : DateTime.fromMillisecondsSinceEpoch(j.nextRunAtMs!).toIso8601String()} · ${j.name}',
        );
      }
    }
    final ScheduledJobService? svc = cronJobs;
    if (svc != null) {
      for (final ScheduledJob j in svc.list(sid)) {
        lines.add(
          '- ${j.id} · ${j.kind.name} (legacy) · ${j.action.name} · '
          '${j.enabled ? 'enabled' : 'disabled'} · next '
          '${j.nextRunAt?.toIso8601String() ?? '—'} · ${j.title}',
        );
      }
    }
    if (store == null && svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'cron_list is unavailable in this build.',
      );
    }
    if (lines.isEmpty) {
      return const ToolResult(ok: true, llmOutput: 'No jobs in this chat.');
    }
    return ToolResult(ok: true, llmOutput: lines.join('\n'));
  }

  Future<ToolResult> _cronUpdate(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final String sid = sessionId ?? '';
    final String id = args['id']?.toString() ?? '';
    final bool enabled = args['enabled'] == true;
    final CronToolService? store = cronStore;
    if (store != null && await store.setEnabled(sid, id, enabled)) {
      return ToolResult(
        ok: true,
        llmOutput: 'Job $id is now ${enabled ? 'enabled' : 'disabled'}.',
      );
    }
    final ScheduledJobService? svc = cronJobs;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'cron_update is unavailable in this build.',
      );
    }
    final ScheduledJob? job = await svc.update(sid, id, enabled: enabled);
    if (job == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'cron_update failed: unknown job id.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput:
          'Job ${job.id} is now ${job.enabled ? 'enabled' : 'disabled'}.',
    );
  }

  Future<ToolResult> _cronDelete(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final String sid = sessionId ?? '';
    final String id = args['id']?.toString() ?? '';
    final CronToolService? store = cronStore;
    if (store != null && await store.remove(sid, id)) {
      return const ToolResult(ok: true, llmOutput: 'Job deleted.');
    }
    final ScheduledJobService? svc = cronJobs;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'cron_delete is unavailable in this build.',
      );
    }
    final bool removed = await svc.remove(sid, id);
    return ToolResult(
      ok: removed,
      llmOutput: removed
          ? 'Job deleted.'
          : 'cron_delete failed: unknown job id.',
    );
  }

  // -- skill_save (v1.51.0) ----------------------------------------------

  Future<ToolResult> _skillSave(Map<String, dynamic> args) async {
    final SkillRegistry? registry = skills;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'skill_save is unavailable in this build.',
      );
    }
    try {
      final report = await registry.saveSkillFromChat(
        name: args['name']?.toString() ?? '',
        description: args['description']?.toString() ?? '',
        instructions: args['instructions']?.toString() ?? '',
      );
      return ToolResult(
        ok: true,
        llmOutput:
            'Skill saved: ${report.skill.name} '
            '(${report.skill.source}). It is now available in the '
            'Skills screen.',
      );
    } catch (e) {
      return ToolResult(ok: false, llmOutput: 'skill_save failed: $e');
    }
  }

  Future<ToolResult> _goalCreate(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final GoalService? svc = goals;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'goal_create is unavailable in this build.',
      );
    }
    final GoalEntry? goal = await svc.create(
      sessionId ?? '',
      args['title']?.toString() ?? '',
      detail: args['detail']?.toString() ?? '',
      dueDate: DateTime.tryParse(args['due_date']?.toString() ?? ''),
      progress: GoalEntry.clampProgress(args['progress']),
    );
    if (goal == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'goal_create failed: title is required.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput:
          'Created goal ${goal.id}: ${goal.title} '
          '(${goal.progress}%)',
      displayText: 'goal created',
    );
  }

  ToolResult _goalList(Map<String, dynamic> args, String? sessionId) {
    final GoalService? svc = goals;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'goal_list is unavailable in this build.',
      );
    }
    List<GoalEntry> entries = svc.list(sessionId ?? '');
    if (args['all'] != true) {
      final String statusName =
          args['status']?.toString() ?? GoalStatus.active.name;
      entries = entries
          .where((GoalEntry g) => g.status.name == statusName)
          .toList();
    }
    if (entries.isEmpty) {
      return const ToolResult(ok: true, llmOutput: 'No goals found.');
    }
    final DateTime now = DateTime.now();
    return ToolResult(
      ok: true,
      llmOutput: <String>[
        for (final GoalEntry g in entries)
          '- ${g.id} [${g.status.name}] ${g.title} (${g.progress}%)'
              '${g.isOverdue(now) ? ' OVERDUE' : ''}'
              '${g.dueDate == null ? '' : ' due ${g.dueDate!.toIso8601String().substring(0, 10)}'}',
      ].join('\n'),
      displayText: 'goals ×${entries.length}',
    );
  }

  Future<ToolResult> _goalUpdate(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final GoalService? svc = goals;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'goal_update is unavailable in this build.',
      );
    }
    final String id = args['id']?.toString() ?? '';
    if (id.isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput: 'goal_update failed: id is required.',
      );
    }
    GoalStatus? status;
    final Object? rawStatus = args['status'];
    if (rawStatus != null) {
      status = goalStatusFromName(rawStatus.toString());
    }
    final Object? rawProgress = args['progress'];
    final GoalEntry? goal = await svc.update(
      sessionId ?? '',
      id,
      title: args['title']?.toString(),
      detail: args['detail']?.toString(),
      status: status,
      progress: rawProgress == null
          ? null
          : GoalEntry.clampProgress(rawProgress),
      dueDate: DateTime.tryParse(args['due_date']?.toString() ?? ''),
    );
    if (goal == null) {
      return ToolResult(
        ok: false,
        llmOutput: 'goal_update failed: no goal with id $id.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput:
          'Updated goal ${goal.id}: ${goal.title} '
          '[${goal.status.name}] (${goal.progress}%)',
      displayText: 'goal updated',
    );
  }

  Future<ToolResult> _goalComplete(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final GoalService? svc = goals;
    if (svc == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'goal_complete is unavailable in this build.',
      );
    }
    final String id = args['id']?.toString() ?? '';
    final GoalEntry? goal = id.isEmpty
        ? null
        : await svc.complete(sessionId ?? '', id);
    if (goal == null) {
      return ToolResult(
        ok: false,
        llmOutput: 'goal_complete failed: no goal with id $id.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput: 'Completed goal ${goal.id}: ${goal.title}',
      displayText: 'goal done',
    );
  }

  ToolResult? _automationGuard(String name) {
    if (_browserTools.contains(name) && !isAutomationEnabled()) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Browser automation is disabled in Settings.',
      );
    }
    return null;
  }

  Future<ToolResult> _navigate(
    Map<String, dynamic> args,
    String? sessionId,
    BrowserAutomation browserApi,
  ) async {
    final guard = _automationGuard('browser_navigate');
    if (guard != null) return guard;
    final url = args['url']?.toString() ?? '';
    // v1.49.0 (wave-2): the model may target a NAMED context created with
    // browser_context_create. Named contexts are a manager-level feature of
    // the multi-context engine only — single-engine automations answer with
    // an honest unsupported error instead of crashing.
    final String contextName = args['context']?.toString().trim() ?? '';
    if (contextName.isNotEmpty) {
      final ContextualBrowserAutomation? manager = _contextManager;
      if (manager == null) {
        return const ToolResult(
          ok: false,
          llmOutput:
              'browser_navigate: named browser contexts are not supported '
              'by this browser engine. Browse in the default context '
              'instead.',
        );
      }
      try {
        final info = await manager.navigate(
          url,
          sessionId: sessionId,
          contextName: contextName,
        );
        return ToolResult(
          ok: info.error == null,
          llmOutput: jsonEncode(info.toJson()),
          displayText: info.title.isEmpty ? info.url : info.title,
        );
      } on ArgumentError catch (e) {
        return ToolResult(
          ok: false,
          llmOutput:
              'browser_navigate: cannot open "$contextName" — '
              '${_errorText(e)} (see browser_context_list).',
        );
      }
    }
    final info = await browserApi.navigate(url, sessionId: sessionId);
    return ToolResult(
      ok: info.error == null,
      llmOutput: jsonEncode(info.toJson()),
      displayText: info.title.isEmpty ? info.url : info.title,
    );
  }

  // -- Named browser contexts (v1.49.0 wave-2) ------------------------------

  /// The manager-level contextual automation behind the named-context
  /// tools, or null when this build's automation is single-engine (the
  /// tools then answer with an honest "unsupported" instead of crashing).
  ///
  /// Named contexts live on the MANAGER ([ContextualBrowserAutomation]),
  /// not on [BrowserAutomation] views (withContext subagent pins), and
  /// every call needs the owning chat's [sessionId].
  ContextualBrowserAutomation? get _contextManager =>
      browser is ContextualBrowserAutomation
      ? browser as ContextualBrowserAutomation
      : null;

  ToolResult _contextsUnsupported(String tool) => ToolResult(
    ok: false,
    llmOutput:
        '$tool: named browser contexts are not supported by this build\'s '
        'browser engine (single-engine automation).',
  );

  /// Human-readable text of the registry/validation errors the contextual
  /// automation throws by contract (ArgumentError / StateError /
  /// UnsupportedError).
  String _errorText(Object error) {
    if (error is ArgumentError) {
      return error.message?.toString() ?? 'invalid argument';
    }
    if (error is StateError) return error.message;
    if (error is UnsupportedError) return error.message ?? 'unsupported';
    return error.toString();
  }

  /// `browser_context_create`: a named, isolated browser context for THIS
  /// chat (own cookies/storage/logins). Errors surface honestly: invalid
  /// or reserved name and missing sessionId are ArgumentError; a duplicate
  /// name is StateError; single-engine builds report "unsupported".
  Future<ToolResult> _browserContextCreate(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final ContextualBrowserAutomation? manager = _contextManager;
    if (manager == null) return _contextsUnsupported('browser_context_create');
    final String name = args['name']?.toString().trim() ?? '';
    final bool persistent = args['persistent'] == true;
    try {
      final Map<String, dynamic> info = await manager.createContext(
        name,
        persistent: persistent,
        sessionId: sessionId,
      );
      return ToolResult(
        ok: true,
        llmOutput:
            'Browser context "${info['name']}" created '
            '(persistent: ${info['persistent']}). Open pages in it with '
            'browser_navigate and context="${info['name']}".\n'
            '${jsonEncode(info)}',
        displayText: 'context +${info['name']}',
      );
    } on ArgumentError catch (e) {
      return ToolResult(
        ok: false,
        llmOutput:
            'browser_context_create: ${_errorText(e)}. Names must be 1-32 '
            'chars: lowercase letters, digits, hyphen or underscore, '
            'starting with a letter or digit.',
        displayText: 'context rejected',
      );
    } on StateError catch (e) {
      return ToolResult(
        ok: false,
        llmOutput:
            'browser_context_create: ${_errorText(e)}. Use '
            'browser_context_list to see the existing names.',
        displayText: 'context exists',
      );
    }
  }

  /// `browser_context_list`: the chat's default context plus every named
  /// context (oldest first), so the model can pick names before creating
  /// duplicates.
  Future<ToolResult> _browserContextList(String? sessionId) async {
    final ContextualBrowserAutomation? manager = _contextManager;
    if (manager == null) return _contextsUnsupported('browser_context_list');
    if (sessionId == null || sessionId.isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'browser_context_list needs the owning chat session '
            '(no sessionId is bound to this call).',
      );
    }
    try {
      final List<Map<String, dynamic>> named = await manager.listContexts(
        sessionId,
      );
      final StringBuffer out = StringBuffer()
        ..writeln(
          'Browser contexts of THIS chat (the default context is always '
          'present and cannot be closed):',
        )
        ..writeln(
          '- default [persistent] — this chat\'s main isolated context',
        );
      if (named.isEmpty) {
        out.writeln(
          '- (no named contexts yet — create one with '
          'browser_context_create)',
        );
      }
      for (final Map<String, dynamic> info in named) {
        out.writeln(
          '- ${info['name']} [${info['persistent'] == true ? 'persistent' : 'ephemeral'}]'
          ' lastUrl: ${info['lastUrl']}'
          ' origins: ${info['originCount']}'
          ' lastUsed: ${info['lastUsedAt']}',
        );
      }
      return ToolResult(
        ok: true,
        llmOutput: out.toString().trim(),
        displayText: '${named.length + 1} context(s)',
      );
    } on Error catch (e) {
      return ToolResult(
        ok: false,
        llmOutput: 'browser_context_list failed: ${_errorText(e)}',
      );
    }
  }

  /// `browser_context_close`: full teardown of one named context (state
  /// file deleted, engine disposed, cookies leave the shared jar). The
  /// default context can never be closed (reserved name → ArgumentError).
  Future<ToolResult> _browserContextClose(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final ContextualBrowserAutomation? manager = _contextManager;
    if (manager == null) return _contextsUnsupported('browser_context_close');
    final String name = args['name']?.toString().trim() ?? '';
    try {
      await manager.closeContext(name, sessionId: sessionId);
      return ToolResult(
        ok: true,
        llmOutput:
            'Browser context "$name" closed: its isolated state (cookies, '
            'storage, logins) was deleted and its engine was released.',
        displayText: 'context -$name',
      );
    } on ArgumentError catch (e) {
      return ToolResult(
        ok: false,
        llmOutput: 'browser_context_close: ${_errorText(e)}',
        displayText: 'context rejected',
      );
    } on StateError catch (e) {
      return ToolResult(
        ok: false,
        llmOutput:
            'browser_context_close: ${_errorText(e)} — see '
            'browser_context_list for the existing names.',
        displayText: 'no such context',
      );
    }
  }

  Future<ToolResult> _click(
    Map<String, dynamic> args,
    String? sessionId,
    BrowserAutomation browserApi,
  ) async {
    final guard = _automationGuard('browser_click');
    if (guard != null) return guard;
    final result = await browserApi.click(
      selector: args['selector']?.toString(),
      text: args['text']?.toString(),
      sessionId: sessionId,
    );
    final ok = result['ok'] == true;
    return ToolResult(
      ok: ok,
      llmOutput: jsonEncode(result),
      displayText: result['clicked']?.toString(),
    );
  }

  Future<ToolResult> _type(
    Map<String, dynamic> args,
    String? sessionId,
    BrowserAutomation browserApi,
  ) async {
    final guard = _automationGuard('browser_type');
    if (guard != null) return guard;
    final result = await browserApi.type(
      args['text']?.toString() ?? '',
      selector: args['selector']?.toString(),
      clear: args['clear'] is bool ? args['clear'] as bool : true,
      sessionId: sessionId,
    );
    return ToolResult(ok: result['ok'] == true, llmOutput: jsonEncode(result));
  }

  Future<ToolResult> _scroll(
    Map<String, dynamic> args,
    String? sessionId,
    BrowserAutomation browserApi,
  ) async {
    final guard = _automationGuard('browser_scroll');
    if (guard != null) return guard;
    final result = await browserApi.scroll(
      direction: args['direction']?.toString() ?? 'down',
      amount: args['amount'] is int ? args['amount'] as int : 800,
      sessionId: sessionId,
    );
    return ToolResult(ok: result['ok'] == true, llmOutput: jsonEncode(result));
  }

  Future<ToolResult> _screenshot(
    String? sessionId,
    BrowserAutomation browserApi,
  ) async {
    final guard = _automationGuard('browser_screenshot');
    if (guard != null) return guard;
    final base = await resolveBaseDir(sessionId);
    final shotsDir = '${base.path}${Platform.pathSeparator}browser_shots';
    final path = await browserApi.screenshot(
      saveDir: shotsDir,
      sessionId: sessionId,
    );
    if (path == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Screenshot could not be captured.',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput: 'Screenshot saved at $path',
      screenshotPath: path,
      displayText: 'screenshot',
    );
  }

  Future<ToolResult> _extract(
    Map<String, dynamic> args,
    String? sessionId,
    BrowserAutomation browserApi,
  ) async {
    final guard = _automationGuard('browser_extract_text');
    if (guard != null) return guard;
    final maxLength = args['maxLength'] is int
        ? args['maxLength'] as int
        : 8000;
    final text = await browserApi.extractText(
      maxLength: maxLength,
      sessionId: sessionId,
    );
    return ToolResult(
      ok: true,
      llmOutput: text.isEmpty ? '(empty page)' : text,
    );
  }

  Future<ToolResult> _runJs(
    Map<String, dynamic> args,
    String? sessionId,
    BrowserAutomation browserApi,
  ) async {
    final guard = _automationGuard('run_js');
    if (guard != null) return guard;
    final code = args['code']?.toString() ?? '';
    if (code.trim().isEmpty) {
      return const ToolResult(ok: false, llmOutput: 'Parameter code is empty.');
    }
    final result = await browserApi.runJs(code, sessionId: sessionId);
    return ToolResult(ok: true, llmOutput: result);
  }

  Future<Directory> _safeBaseDir(String? sessionId) async =>
      resolveBaseDir(sessionId);

  /// Resolves [requested] under [base], rejecting path traversal.
  File? _resolveFile(Directory base, String requested) {
    if (requested.trim().isEmpty) return null;
    try {
      final resolved = base.uri.resolve(requested).toFilePath();
      final normalizedBase = base.path.endsWith(Platform.pathSeparator)
          ? base.path
          : '${base.path}${Platform.pathSeparator}';
      if (!resolved.startsWith(normalizedBase)) return null;
      return File(resolved);
    } catch (_) {
      return null;
    }
  }

  Future<ToolResult> _readFile(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final base = await _safeBaseDir(sessionId);
    final file = _resolveFile(base, args['path']?.toString() ?? '');
    if (file == null) {
      return const ToolResult(ok: false, llmOutput: 'Invalid path.');
    }
    if (!await file.exists()) {
      return ToolResult(ok: false, llmOutput: 'File not found: ${file.path}');
    }
    String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      // Binary or non-UTF8 file: report instead of crashing.
      return ToolResult(
        ok: false,
        llmOutput: 'File could not be read as text: $e',
      );
    }
    final truncated = content.length > 20000
        ? '${content.substring(0, 20000)}\n... [truncated]'
        : content;
    return ToolResult(
      ok: true,
      llmOutput: truncated,
      displayText: file.path.split(Platform.pathSeparator).last,
    );
  }

  Future<ToolResult> _writeFile(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final base = await _safeBaseDir(sessionId);
    final file = _resolveFile(base, args['path']?.toString() ?? '');
    if (file == null) {
      return const ToolResult(ok: false, llmOutput: 'Invalid path.');
    }
    final content = args['content']?.toString() ?? '';
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    } catch (e) {
      return ToolResult(ok: false, llmOutput: 'Could not write file: $e');
    }
    return ToolResult(
      ok: true,
      llmOutput: 'Wrote ${content.length} characters to ${file.path}',
      displayText: file.path.split(Platform.pathSeparator).last,
    );
  }

  // -- Archive tools (zip / unzip) ---------------------------------------

  /// Lists up to [_unzipListCap] files under [dir] (relative paths, '/'
  /// separators) so the model learns what an archive contained.
  static const int _unzipListCap = 100;

  Future<List<String>> _listFiles(Directory dir, String relativeRoot) async {
    final List<String> out = <String>[];
    if (!dir.existsSync()) return out;
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (FileSystemEntity.typeSync(entity.path) != FileSystemEntityType.file) {
        continue;
      }
      final String rel = entity.path
          .substring(relativeRoot.length)
          .replaceAll(Platform.pathSeparator, '/');
      out.add(rel.startsWith('/') ? rel.substring(1) : rel);
      if (out.length >= _unzipListCap) break;
    }
    return out;
  }

  Future<ToolResult> _unzipFile(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final FileSystemService? service = fsFor != null ? fsFor!(sessionId) : fs;
    if (service == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Archive tools are not available in this build.',
      );
    }
    final String path = args['path']?.toString() ?? '';
    if (path.trim().isEmpty) {
      return const ToolResult(ok: false, llmOutput: 'Parameter path is empty.');
    }
    final String password = args['password']?.toString() ?? '';
    final String? effectivePassword = password.trim().isEmpty ? null : password;
    final String dest;
    try {
      dest = await service.unzip(path, password: effectivePassword);
    } on ZipPasswordRequiredException {
      return ToolResult(
        ok: false,
        llmOutput:
            'The archive $path is password-protected. Ask the user for the '
            'password, then call unzip_file again passing it in the '
            '"password" argument.',
        displayText: 'unzip $path — password required',
      );
    } on ZipWrongPasswordException {
      return ToolResult(
        ok: false,
        llmOutput:
            'The password for $path is wrong. Ask the user to confirm the '
            'password, then call unzip_file again with the corrected '
            '"password" argument.',
        displayText: 'unzip $path — wrong password',
      );
    }
    final String? destDirPath = await service.resolve(dest);
    final List<String> files = destDirPath == null
        ? const <String>[]
        : await _listFiles(Directory(destDirPath), destDirPath);
    final StringBuffer output = StringBuffer()
      ..write('Extracted to $dest')
      ..writeln(
        files.isEmpty
            ? ' (no files inside the archive).'
            : ' — ${files.length} file(s):',
      );
    for (final String file in files) {
      output.writeln('- $dest/$file');
    }
    return ToolResult(
      ok: true,
      llmOutput: output.toString().trim(),
      displayText: 'unzip $path',
    );
  }

  Future<ToolResult> _zipFile(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final FileSystemService? service = fsFor != null ? fsFor!(sessionId) : fs;
    if (service == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Archive tools are not available in this build.',
      );
    }
    final String path = args['path']?.toString() ?? '';
    if (path.trim().isEmpty) {
      return const ToolResult(ok: false, llmOutput: 'Parameter path is empty.');
    }
    final String zipPath = await service.zip(path);
    return ToolResult(
      ok: true,
      llmOutput: 'Created archive $zipPath',
      displayText: 'zip $path',
    );
  }

  // -- Task plan (todos) --------------------------------------------------

  /// The planning tool is stateless on purpose: the model re-sends the
  /// FULL list every time, so the latest `todo_write` call in the history
  /// always describes the current plan. The executor only validates and
  /// reports progress back to the model; UI and history read the same
  /// arguments from the persisted tool call.
  ToolResult _todoWrite(Map<String, dynamic> args) {
    final List<TodoItem> todos = parseTodoList(args['todos']);
    if (todos.isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'todo_write requires a non-empty "todos" array of objects with '
            '"content" (string) and "status" (pending | in_progress | '
            'completed). Send the complete updated list.',
      );
    }
    final int completed = todos
        .where((TodoItem t) => t.status == TodoStatus.completed)
        .length;
    final int inProgress = todos
        .where((TodoItem t) => t.status == TodoStatus.inProgress)
        .length;
    // v1.49.0 (wave-2): the blocked contract is accepted end-to-end here —
    // parseTodoList already kept blocked + blocked_reason (≤200 chars) +
    // depends_on (≤10 ids, stored as-is even when an id is unknown), so the
    // progress report tells the model how much of the plan is stalled and
    // nudges it to keep unblocked steps moving.
    final int blocked = todos
        .where((TodoItem t) => t.status == TodoStatus.blocked)
        .length;
    return ToolResult(
      ok: true,
      llmOutput: jsonEncode(<String, dynamic>{
        'ok': true,
        'total': todos.length,
        'completed': completed,
        'in_progress': inProgress,
        'pending': todos.length - completed - inProgress - blocked,
        'blocked': blocked,
      }),
      displayText: 'plan $completed/${todos.length}',
    );
  }

  // -- Embedded Node.js-style runtime ------------------------------------

  Future<ToolResult> _nodeRun(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final JsRuntime? runtime = js;
    if (runtime == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'The embedded JS runtime is not available in this build.',
      );
    }
    final code = args['code']?.toString() ?? '';
    if (code.trim().isEmpty) {
      return const ToolResult(ok: false, llmOutput: 'Parameter code is empty.');
    }
    // node_run works inside the session workspace, but packages stay in
    // the GLOBAL npm library (documents/node_modules) — installs are
    // shared across sessions, scripts are not.
    final Directory base = await _safeBaseDir(sessionId);
    final Directory global = await _safeBaseDir(null);
    final String modulesRoot =
        '${global.path}${Platform.pathSeparator}node_modules';
    final result = await runtime.run(
      code,
      moduleRoots: <String>[modulesRoot],
      workingDir: base.path,
    );
    final String output = result.output;
    if (!result.ok) {
      return ToolResult(
        ok: false,
        llmOutput: output.isEmpty
            ? 'Script error: ${result.error}'
            : '$output\nScript error: ${result.error}',
        displayText: 'node error',
      );
    }
    final List<String> parts = <String>[
      if (output.isNotEmpty) output,
      if (result.result != null && result.result != 'undefined')
        '=> ${result.result}',
    ];
    return ToolResult(
      ok: true,
      llmOutput: parts.isEmpty
          ? 'Script finished with no output.'
          : parts.join('\n'),
      displayText: 'node',
    );
  }

  Future<ToolResult> _nodeInstall(Map<String, dynamic> args) async {
    final NpmService? service = npm;
    if (service == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'npm management is not available in this build.',
      );
    }
    final String pkg = args['package']?.toString() ?? '';
    final String? version = args['version']?.toString();
    final result = await service.install(pkg, version: version);
    return ToolResult(
      ok: result.ok,
      llmOutput: result.ok
          ? '${result.message}. It can now be required from node_run.'
          : result.message,
      displayText: result.ok ? 'installed $pkg' : 'install failed',
    );
  }

  Future<ToolResult> _nodeRemove(Map<String, dynamic> args) async {
    final NpmService? service = npm;
    if (service == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'npm management is not available in this build.',
      );
    }
    final String pkg = args['package']?.toString() ?? '';
    if (pkg.trim().isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Parameter package is empty.',
      );
    }
    if (!NpmService.isValidPackageName(pkg)) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'Invalid package name. Only plain npm names or @scope/name are '
            'accepted.',
      );
    }
    final bool removed;
    try {
      removed = await service.remove(pkg);
    } catch (e) {
      return ToolResult(ok: false, llmOutput: 'Remove failed: $e');
    }
    return ToolResult(
      ok: removed,
      llmOutput: removed
          ? 'Removed $pkg from the embedded runtime.'
          : '$pkg is not installed.',
      displayText: removed ? 'removed $pkg' : 'not installed',
    );
  }

  // -- Skills (v1.38.0): real install/config/run of external skills -------

  String? _classifySkillSource(String source) {
    final String t = source.trim();
    if (t.toLowerCase().startsWith('builtin:')) return 'builtin';
    if (t.startsWith('http://') || t.startsWith('https://')) return 'url';
    final String lower = t.toLowerCase();
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz')) {
      return 'file';
    }
    return 'github';
  }

  /// v1.38.1 — case-insensitive lookup of a bundled skill by asset name.
  String? _lookupBundledSkill(Map<String, String> bundled, String name) {
    for (final MapEntry<String, String> e in bundled.entries) {
      if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
    }
    return null;
  }

  Future<ToolResult> _skillInstall(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final SkillRegistry? registry = skills;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Skills are not available in this build.',
      );
    }
    final String source = args['source']?.toString().trim() ?? '';
    if (source.isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Parameter source is empty.',
      );
    }
    final SkillInstallReport report;
    try {
      switch (_classifySkillSource(source)) {
        case 'builtin':
          // v1.38.1 — app-bundled skill (assets/skills/*): a REAL install
          // from the binary, no network. The loader is injected (di.dart
          // wires rootBundle; tests inject a plain map).
          final Map<String, String>? bundled = await bundledSkills?.call();
          final String bundledName = source.trim().substring(8).trim();
          final String? skillMd = bundled == null
              ? null
              : _lookupBundledSkill(bundled, bundledName);
          if (skillMd == null) {
            return ToolResult(
              ok: false,
              llmOutput:
                  'No bundled skill named "$bundledName". Bundled skills: '
                  '${bundled == null ? '(loader unavailable)' : bundled.keys.join(', ')}.',
              displayText: 'install failed',
            );
          }
          report = await registry.installBundled(
            bundledName: bundledName,
            skillMd: skillMd,
          );
        case 'url':
          report = await registry.install(source);
        case 'file':
          final Directory base = await _safeBaseDir(sessionId);
          final String? abs = _resolveExistingFile(base, source);
          if (abs == null) {
            return ToolResult(
              ok: false,
              llmOutput:
                  'Archive "$source" not found in this chat workspace '
                  '(download it first, e.g. with a node_run fetch, then retry).',
            );
          }
          report = await registry.installFromFile(abs);
        default:
          report = await registry.install(source);
      }
    } on SkillRegistryException catch (e) {
      return ToolResult(
        ok: false,
        llmOutput: 'skill_install failed: ${e.message}',
        displayText: 'install failed',
      );
    } catch (e) {
      return ToolResult(
        ok: false,
        llmOutput: 'skill_install failed: $e',
        displayText: 'install failed',
      );
    }
    final InstalledSkill skill = report.skill;
    final StringBuffer out = StringBuffer()
      ..writeln('Installed skill "${skill.name}" v${skill.version}.')
      ..writeln('Source: ${skill.source}')
      ..writeln('Description: ${skill.description}')
      ..writeln(
        'Permissions declared by the skill: '
        '${skill.permissions.isEmpty ? '(none declared)' : skill.permissions.join(', ')}',
      )
      ..writeln(
        'Config: ${registry.describeConfig(skill, await registry.readConfig(skill))}',
      );
    for (final String note in report.notes) {
      out.writeln('- $note');
    }
    out.writeln();
    out.writeln(
      'Security note: this skill runs with network and file '
      'access inside the embedded sandbox. Verify its source before '
      'executing money-moving workflows, and use request_confirmation '
      'before any irreversible action it performs.',
    );
    return ToolResult(
      ok: true,
      llmOutput: out.toString(),
      displayText: 'installed ${skill.name}',
    );
  }

  Future<ToolResult> _skillList() async {
    final SkillRegistry? registry = skills;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Skills are not available in this build.',
      );
    }
    await registry.ensureCacheLoaded();
    final List<InstalledSkill> list = registry.listSync();
    if (list.isEmpty) {
      return const ToolResult(
        ok: true,
        llmOutput: 'No skills installed yet. Install one with skill_install.',
        displayText: 'no skills',
      );
    }
    final StringBuffer out = StringBuffer();
    for (final InstalledSkill skill in list) {
      final SkillStatus status = await registry.statusOf(skill);
      out.writeln(
        '${skill.name} v${skill.version} [${status.name}] '
        '- ${skill.description}',
      );
      final Set<String> missing = await registry.missingConfigValues(skill);
      if (missing.isNotEmpty) {
        out.writeln('  missing required config: ${missing.join(', ')}');
      }
    }
    return ToolResult(
      ok: true,
      llmOutput: out.toString().trim(),
      displayText: '${list.length} skill(s)',
    );
  }

  Future<ToolResult> _skillInfo(Map<String, dynamic> args) async {
    final SkillRegistry? registry = skills;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Skills are not available in this build.',
      );
    }
    final InstalledSkill? skill = await registry.get(
      args['name']?.toString() ?? '',
    );
    if (skill == null) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Skill "${args['name']}" is not installed. '
            'Use skill_list to see installed skills.',
      );
    }
    final List<String> files = skill.listFiles();
    // Optional `path`: read ONE file of the skill (references/*.md, a
    // helper script, …). Multi-file skills are unusable without this —
    // their SKILL.md tells the agent to read the reference docs first.
    final String requested = args['path']?.toString().trim() ?? '';
    if (requested.isNotEmpty) {
      final String? body = skill.readFile(requested);
      if (body == null) {
        return ToolResult(
          ok: false,
          llmOutput:
              'File "$requested" not found in skill "${skill.name}". '
              'Available files: '
              '${files.isEmpty ? '(none)' : files.join(', ')}',
        );
      }
      const int maxChars = 120000;
      final String text = body.length > maxChars
          ? '${body.substring(0, maxChars)}\n… (truncated)'
          : body;
      return ToolResult(
        ok: true,
        llmOutput: '--- ${skill.name}/$requested ---\n$text',
        displayText: '${skill.name}/$requested',
      );
    }
    final Map<String, String> config = await registry.readConfig(skill);
    final StringBuffer out = StringBuffer()
      ..writeln(
        '=== ${skill.name} v${skill.version} '
        '[${(await registry.statusOf(skill)).name}] ===',
      )
      ..writeln('Source: ${skill.source}')
      ..writeln('Config: ${registry.describeConfig(skill, config)}');
    if (skill.requiresBins.isNotEmpty) {
      out.writeln(
        'UNSUPPORTED HERE: requires native executable(s) '
        '${skill.requiresBins.join(', ')} — this runtime cannot start '
        'external processes.',
      );
    }
    if (skill.wallet) {
      out.writeln(
        'WALLET SKILL: every skill_run on this skill is a value-moving '
        'action — the app asks the user for explicit approval before each '
        'run. Read-only steps use the browser/web tools, not skill_run.',
      );
    }
    if (files.isNotEmpty) {
      out.writeln('Files (read with skill_info path="…"): ${files.join(', ')}');
    }
    out
      ..writeln('--- SKILL.md ---')
      ..write(skill.readInstructions());
    return ToolResult(
      ok: true,
      llmOutput: out.toString(),
      displayText: skill.name,
    );
  }

  Future<ToolResult> _skillConfig(Map<String, dynamic> args) async {
    final SkillRegistry? registry = skills;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Skills are not available in this build.',
      );
    }
    final InstalledSkill? skill = await registry.get(
      args['name']?.toString() ?? '',
    );
    if (skill == null) {
      return ToolResult(
        ok: false,
        llmOutput: 'Skill "${args['name']}" is not installed.',
      );
    }
    final Object? rawValues = args['values'];
    if (rawValues is! Map || rawValues.isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'Parameter values must be a non-empty object of '
            'string config entries.',
      );
    }
    // v1.41.0: keys are validated against the skill's declared config
    // fields — a typo used to be stored SILENTLY and the skill stayed
    // "needs config" with no hint why. A null value unsets a stored key.
    final Set<String> declared = skill.configFields
        .map((SkillConfigField f) => f.name)
        .where((String n) => n.isNotEmpty)
        .toSet();
    final Map<String, String?> values = <String, String?>{};
    final List<String> unknown = <String>[];
    for (final MapEntry<Object?, Object?> e in rawValues.entries) {
      final String key = e.key.toString();
      if (declared.isNotEmpty && !declared.contains(key)) {
        unknown.add(key);
        continue;
      }
      values[key] = e.value?.toString();
    }
    if (unknown.isNotEmpty) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Unknown config key(s) for "${skill.name}": '
            '${unknown.join(', ')}. Declared fields: '
            '${declared.isEmpty ? "(none — this skill takes no config)" : declared.join(", ")}.',
      );
    }
    if (values.isEmpty) {
      return ToolResult(
        ok: false,
        llmOutput:
            'No valid config keys were provided. Declared fields for '
            '"${skill.name}": ${declared.join(', ')}.',
      );
    }
    // Secrets never travel back: the result lists KEYS only.
    await registry.writeConfig(skill, values);
    final Map<String, String> stored = await registry.readConfig(skill);
    final Set<String> missing = registry
        .missingRequiredConfig(skill)
        .where((String f) => !stored.containsKey(f) || stored[f]!.isEmpty)
        .toSet();
    final String unsetNote = values.values.any((String? v) => v == null)
        ? ' Null values removed the matching stored keys.'
        : '';
    return ToolResult(
      ok: true,
      llmOutput:
          'Config saved for "${skill.name}" '
          '(keys: ${values.keys.join(', ')}; values are stored locally '
          'and never displayed).$unsetNote\n'
          '${missing.isEmpty ? 'All required config is set — the skill is ready.' : 'Still missing required config: ${missing.join(', ')}'}',
      displayText: 'config saved',
    );
  }

  Future<ToolResult> _skillRemove(Map<String, dynamic> args) async {
    final SkillRegistry? registry = skills;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Skills are not available in this build.',
      );
    }
    final String name = args['name']?.toString() ?? '';
    try {
      await registry.remove(name);
      return ToolResult(
        ok: true,
        llmOutput: 'Skill "$name" removed (files and stored config deleted).',
        displayText: 'removed $name',
      );
    } on SkillRegistryException catch (e) {
      return ToolResult(ok: false, llmOutput: e.message);
    }
  }

  /// v1.41.0 `skill_update`: re-downloads the skill's declared source and
  /// installs it when the remote version differs. Reports honestly when
  /// nothing changed or when the source kind cannot be updated.
  Future<ToolResult> _skillUpdate(Map<String, dynamic> args) async {
    final SkillRegistry? registry = skills;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Skills are not available in this build.',
      );
    }
    final String name = args['name']?.toString() ?? '';
    try {
      final SkillUpdateReport outcome = await registry.update(name);
      if (outcome.upToDate) {
        return ToolResult(
          ok: true,
          llmOutput:
              'Skill "$name" is already up to date '
              '(v${outcome.skill.version}).',
          displayText: '$name up to date',
        );
      }
      final InstalledSkill skill = outcome.skill;
      final StringBuffer out = StringBuffer()
        ..writeln(
          'Updated skill "$name": v${outcome.previousVersion} → '
          'v${skill.version}.',
        )
        ..writeln('Source: ${skill.source}')
        ..writeln(
          'Config: ${registry.describeConfig(skill, await registry.readConfig(skill))}',
        );
      for (final String note in outcome.report?.notes ?? const <String>[]) {
        out.writeln('- $note');
      }
      return ToolResult(
        ok: true,
        llmOutput: out.toString(),
        displayText: 'updated $name',
      );
    } on SkillRegistryException catch (e) {
      return ToolResult(
        ok: false,
        llmOutput: 'skill_update failed: ${e.message}',
        displayText: 'update failed',
      );
    } catch (e) {
      return ToolResult(
        ok: false,
        llmOutput: 'skill_update failed: $e',
        displayText: 'update failed',
      );
    }
  }

  Future<ToolResult> _skillRun(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final SkillRegistry? registry = skills;
    final JsRuntime? runtime = js;
    if (registry == null || runtime == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Skills or the JS runtime are not available in this build.',
      );
    }
    final InstalledSkill? skill = await registry.get(
      args['name']?.toString() ?? '',
    );
    if (skill == null) {
      return ToolResult(
        ok: false,
        llmOutput: 'Skill "${args['name']}" is not installed.',
      );
    }
    // v1.49.0 (wave-2): a skill the user disabled in the Skills manager
    // must refuse to run — honestly, with the way out. setEnabled
    // refreshes the registry cache, so this reads the current switch.
    if (!skill.enabled) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Skill "${skill.name}" is currently DISABLED in the Skills '
            'manager (Settings → Skills). Ask the user to enable it there, '
            'then retry — do not pretend it ran.',
        displayText: 'skill disabled',
      );
    }
    final String script = args['script']?.toString().trim() ?? '';
    if (script.isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Parameter script is empty.',
      );
    }
    // v1.41.0: segment-based traversal check. The old substring test
    // (script.contains('..')) also rejected legitimate names containing
    // consecutive dots (e.g. scripts/v1..2.js); only whole path segments
    // are dangerous.
    final String normalizedScript = script.replaceAll('\\', '/');
    if (normalizedScript.startsWith('/') ||
        normalizedScript.contains(':') ||
        normalizedScript
            .split('/')
            .any((String seg) => seg == '..' || seg == '.')) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Script path must be relative to the skill folder.',
      );
    }
    if (!script.toLowerCase().endsWith('.js')) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Only JavaScript (.js) skill scripts can run in the '
            'embedded runtime. Native binaries, shells and other runtimes '
            'are unsupported — report this limitation honestly.',
      );
    }
    // v1.39.0: a skill that declares a native executable cannot run here.
    // Saying so up front (and refusing) is the honest behaviour — the
    // agent used to "run" the JS and report a success that never happened.
    if (skill.requiresBins.isNotEmpty) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Skill "${skill.name}" requires the native executable(s) '
            '${skill.requiresBins.join(', ')}. This runtime has no shell and '
            'cannot start external processes, so the skill\'s commands '
            'cannot be executed on this device. Do not claim it worked. Tell '
            'the user this limitation; you may still read its instructions '
            'with skill_info and help with tasks that only need HTTP.',
      );
    }
    final File scriptFile = File(
      '${skill.dirPath}${Platform.pathSeparator}'
      '${script.replaceAll('/', Platform.pathSeparator)}',
    );
    if (!scriptFile.existsSync()) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Script "$script" not found in skill "${skill.name}". '
            'Check skill_info for the available scripts.',
      );
    }
    // Required config must be complete before a run (skills gate on their
    // credentials, mirroring the module setup gate).
    //
    // v1.49.0 (wave-2): the run path needs the REAL secret values — the
    // masked '••••' placeholders used to be injected into process.env and
    // the skill saw a useless mask. The reveal is scoped to this local:
    // the values flow ONLY into the script's process.env preamble and are
    // never logged, echoed into the tool result or persisted anywhere.
    final Map<String, String> config = await registry.readConfig(
      skill,
      revealSecrets: true,
    );
    final Set<String> missing = registry
        .missingRequiredConfig(skill)
        .where((String f) => !config.containsKey(f) || config[f]!.isEmpty)
        .toSet();
    if (missing.isNotEmpty) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Skill "${skill.name}" is missing required config: '
            '${missing.join(', ')}. Collect the values from the user and '
            'store them with skill_config.',
      );
    }
    final Object? rawTimeout = args['timeout_seconds'];
    int timeoutSeconds = 90;
    String? timeoutNote;
    if (rawTimeout is int && rawTimeout >= 10) {
      if (rawTimeout > 300) {
        timeoutSeconds = 300;
        // v1.41.0: the coercion used to be silent — the model had no way
        // to know its requested timeout was not honored.
        timeoutNote =
            'Note: requested timeout ${rawTimeout}s was capped to 300s.';
      } else {
        timeoutSeconds = rawTimeout;
      }
    } else if (rawTimeout != null) {
      timeoutNote =
          'Note: requested timeout ($rawTimeout) is invalid — using the '
          'default 90s (min 10, max 300).';
    }
    final Directory workspace = await _safeBaseDir(sessionId);
    final Directory global = await _safeBaseDir(null);
    final String npmRoot =
        '${global.path}${Platform.pathSeparator}node_modules';

    // Config values reach the script ONLY as process.env entries — the
    // conversation never sees them.
    final Map<String, String> env = <String, String>{
      ...config,
      'ZAGENTS_SKILL_NAME': skill.name,
      'ZAGENTS_SKILL_DIR': skill.dirPath,
      'ZAGENTS_WORKSPACE': workspace.path,
    };
    final Object? rawArgs = args['args'];
    final String preamble =
        'globalThis.__zSkillArgs = ${jsonEncode(rawArgs is Map ? rawArgs : <String, dynamic>{})};\n'
        'window.process = window.process || {};\n'
        'window.process.env = ${jsonEncode(env)};\n'
        'globalThis.process = window.process;\n';

    final String source = await scriptFile.readAsString();
    final JsRunResult result = await runtime.run(
      '$preamble\n$source',
      moduleRoots: <String>[skill.dirPath, if (npmRoot.isNotEmpty) npmRoot],
      workingDir: workspace.path,
      timeout: Duration(seconds: timeoutSeconds),
    );
    final String output = result.output;
    if (!result.ok) {
      return ToolResult(
        ok: false,
        llmOutput: output.isEmpty
            ? 'Skill script error: ${result.error}'
            : '$output\nSkill script error: ${result.error}',
        displayText: 'skill error',
      );
    }
    final List<String> parts = <String>[
      if (output.isNotEmpty) output,
      if (result.result != null && result.result != 'undefined')
        '=> ${result.result}',
      // v1.41.0: surface timeout coercion so the model never believes an
      // un-honored timeout was applied.
      ?timeoutNote,
    ];
    return ToolResult(
      ok: true,
      llmOutput: parts.isEmpty
          ? 'Skill script finished with no output.'
          : parts.join('\n'),
      displayText: skill.name,
    );
  }

  /// Resolves a file inside the session workspace, rejecting traversal.
  String? _resolveExistingFile(Directory base, String requested) {
    final String rel = requested.trim();
    if (rel.isEmpty || rel.startsWith('/') || rel.contains('..')) return null;
    final String candidate =
        '${base.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}';
    final File file = File(candidate);
    return file.existsSync() ? candidate : null;
  }

  // -- Server-side web fetch ----------------------------------------------

  Future<ToolResult> _webFetch(Map<String, dynamic> args) async {
    final WebFetcher? service = fetcher;
    if (service == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'web_fetch is not available in this build.',
      );
    }
    final String url = args['url']?.toString() ?? '';
    if (url.trim().isEmpty) {
      return const ToolResult(ok: false, llmOutput: 'Parameter url is empty.');
    }
    final int maxLength =
        (args['maxLength'] as int?) ?? WebFetcher.defaultMaxLength;
    final WebFetchResult result = await service.fetch(
      url,
      maxLength: maxLength,
    );
    return ToolResult(
      ok: result.ok,
      llmOutput: result.output,
      displayText: result.ok
          ? 'fetched ${Uri.tryParse(url.trim())?.host ?? url.trim()}'
          : 'fetch failed',
    );
  }

  // -- Git tools (isomorphic-git through the embedded JS runtime) ---------

  /// Cached outcome of the isomorphic-git availability check (null until the
  /// first git tool call). npm packages are GLOBAL, so one app-lifetime
  /// check is enough.
  bool? _isoGitAvailable;

  /// Makes sure `isomorphic-git` is installed in the global npm library —
  /// the git tools are thin JS wrappers around it. Installs on first use.
  Future<bool> _ensureIsoGit() async {
    final NpmService? service = npm;
    if (service == null) return false;
    final bool? cached = _isoGitAvailable;
    if (cached != null) return cached;
    try {
      final List<InstalledModule> installed = await service.listInstalled();
      if (installed.any((InstalledModule m) => m.name == 'isomorphic-git')) {
        return _isoGitAvailable = true;
      }
    } catch (_) {
      // Listing failed: fall through and try an install.
    }
    try {
      final result = await service.install('isomorphic-git');
      return _isoGitAvailable = result.ok;
    } catch (_) {
      return _isoGitAvailable = false;
    }
  }

  /// Resolves [requested] as a directory under [base], rejecting path
  /// traversal (git repos must stay inside the session workspace).
  Directory? _resolveDir(Directory base, String requested) {
    final String rel = requested.trim().isEmpty ? '.' : requested.trim();
    try {
      final String resolved = base.uri.resolve(rel).toFilePath();
      final String normalizedBase = base.path.endsWith(Platform.pathSeparator)
          ? base.path
          : '${base.path}${Platform.pathSeparator}';
      if (!resolved.startsWith(normalizedBase)) return null;
      return Directory(resolved);
    } catch (_) {
      return null;
    }
  }

  /// Shared runner for all git tools: guarantees the runtime + package are
  /// available, then executes the generated script with the session
  /// workspace as workingDir and the GLOBAL npm library for modules.
  Future<ToolResult> _gitRun(
    String op,
    Map<String, dynamic> payload,
    String? sessionId,
  ) async {
    final JsRuntime? runtime = js;
    if (runtime == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'The embedded JS runtime is not available in this build.',
      );
    }
    if (!await _ensureIsoGit()) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'Could not make isomorphic-git available (npm unavailable or '
            'offline). Git tools need it — try again once connected.',
      );
    }
    final Directory base = await _safeBaseDir(sessionId);
    final Directory global = await _safeBaseDir(null);
    final result = await runtime.run(
      _gitScript(op, payload),
      moduleRoots: <String>[
        '${global.path}${Platform.pathSeparator}node_modules',
      ],
      workingDir: base.path,
    );
    final String output = result.output;
    if (!result.ok) {
      return ToolResult(
        ok: false,
        llmOutput: output.isEmpty
            ? 'git $op failed: ${result.error}'
            : '$output\ngit $op failed: ${result.error}',
        displayText: 'git $op failed',
      );
    }
    return ToolResult(
      ok: true,
      llmOutput: output.isEmpty
          ? (result.result == 'undefined' || result.result == null
                ? 'git $op finished (no output).'
                : '=> ${result.result}')
          : output,
      displayText: 'git $op',
    );
  }

  /// Builds the JavaScript source for one git operation. [payload] carries
  /// pre-validated, Dart-resolved values (absolute `dir`, sanitized url…).
  /// Network clients prefer the browser build of isomorphic-git (fetch is
  /// available in the embedded runtime) and fall back to the node build.
  String _gitScript(String op, Map<String, dynamic> payload) {
    final String args = jsonEncode(payload);
    final String prelude =
        '''
const ARGS = $args;
const git = require('isomorphic-git');
const fs = require('fs');
let http = null;
function gitHttp() {
  if (http) return http;
  try { http = require('isomorphic-git/http/web'); } catch (e) {}
  if (!http) { try { http = require('isomorphic-git/http/node'); } catch (e) {} }
  return http;
}
''';
    switch (op) {
      case 'clone':
        return '''
$prelude
await git.clone({
  fs, http: gitHttp(), dir: ARGS.dir, url: ARGS.url,
  singleBranch: true, depth: ARGS.depth || 1,
  onAuth: () => ({ username: 'x-access-token', password: ARGS.token || '' }),
});
let files = [];
try { files = fs.readdirSync(ARGS.dir).filter((f) => f !== '.git'); } catch (e) {}
console.log('Cloned ' + (files.length) + ' top-level entries into ' + ARGS.dir);
return files.slice(0, 50).join('\\n');
''';
      case 'status':
        return '''
$prelude
const branch = (await git.currentBranch({ fs, dir: ARGS.dir })) || '(detached HEAD)';
const rows = await git.statusMatrix({ fs, dir: ARGS.dir });
const changed = [];
for (const row of rows) {
  const file = row[0], head = row[1], workdir = row[2];
  if (head === 1 && workdir === 1) continue;
  if (head === 0 && workdir === 2) changed.push('+ ' + file);
  else if (workdir === 0) changed.push('- ' + file);
  else changed.push('~ ' + file);
}
console.log('branch: ' + branch);
console.log(changed.length === 0 ? 'working tree clean' : changed.slice(0, 100).join('\\n'));
return 'branch ' + branch + ', ' + changed.length + ' change(s)';
''';
      case 'commit':
        return '''
$prelude
await git.add({ fs, dir: ARGS.dir, filepath: '.' });
const sha = await git.commit({
  fs, dir: ARGS.dir, message: ARGS.message,
  author: { name: ARGS.authorName, email: ARGS.authorEmail },
});
console.log('Staged all changes.');
return 'Committed ' + sha;
''';
      case 'push':
        return '''
$prelude
let ref = ARGS.branch;
if (!ref) { ref = await git.currentBranch({ fs, dir: ARGS.dir }); }
if (!ref) throw new Error('No branch to push (detached HEAD?).');
await git.push({
  fs, http: gitHttp(), dir: ARGS.dir,
  remote: ARGS.remote || 'origin', ref,
  onAuth: () => ({ username: 'x-access-token', password: ARGS.token || '' }),
});
console.log('Pushed ' + ref + ' to ' + (ARGS.remote || 'origin'));
return 'pushed ' + ref;
''';
      default: // log
        return '''
$prelude
const commits = await git.log({ fs, dir: ARGS.dir, depth: ARGS.limit || 10 });
if (commits.length === 0) { console.log('No commits yet.'); return 'empty history'; }
for (const c of commits) {
  const when = new Date(c.commit.author.timestamp * 1000).toISOString().slice(0, 10);
  console.log(c.oid.slice(0, 7) + ' ' + when + ' ' + c.commit.author.name + ': ' + String(c.commit.message).split('\\n')[0]);
}
return commits.length + ' commit(s)';
''';
    }
  }

  Future<ToolResult> _gitClone(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final String url = args['url']?.toString().trim() ?? '';
    if (url.isEmpty) {
      return const ToolResult(ok: false, llmOutput: 'Parameter url is empty.');
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return const ToolResult(
        ok: false,
        llmOutput: 'git_clone needs an http(s) repository URL.',
      );
    }
    final Directory base = await _safeBaseDir(sessionId);
    final String requested = args['destination']?.toString() ?? '';
    String dest = requested.trim();
    if (dest.isEmpty) {
      final String last = uri.pathSegments.lastWhere(
        (String s) => s.isNotEmpty,
        orElse: () => 'repo',
      );
      dest = last.endsWith('.git') ? last.substring(0, last.length - 4) : last;
      dest = dest.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    }
    final Directory? target = _resolveDir(base, dest);
    if (target == null) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'Invalid destination (must stay inside this chat workspace).',
      );
    }
    if (target.existsSync() && target.listSync().isNotEmpty) {
      return ToolResult(
        ok: false,
        llmOutput: 'Destination already exists and is not empty: $dest',
      );
    }
    return _gitRun('clone', <String, dynamic>{
      'dir': target.path,
      'url': url,
      'token': args['token']?.toString() ?? '',
      'depth': (args['depth'] as int?) ?? 1,
    }, sessionId);
  }

  Future<ToolResult> _gitRepo(
    Map<String, dynamic> args,
    String? sessionId,
    String op,
    Map<String, dynamic> Function(String dir) payloadFor,
  ) async {
    final Directory base = await _safeBaseDir(sessionId);
    final Directory? repo = _resolveDir(
      base,
      args['repoPath']?.toString() ?? '.',
    );
    if (repo == null || !repo.existsSync()) {
      return ToolResult(
        ok: false,
        llmOutput:
            'Repository folder not found inside this chat workspace '
            '(use git_clone first).',
      );
    }
    return _gitRun(op, payloadFor(repo.path), sessionId);
  }

  Future<ToolResult> _gitStatus(Map<String, dynamic> args, String? sessionId) =>
      _gitRepo(
        args,
        sessionId,
        'status',
        (String dir) => <String, dynamic>{'dir': dir},
      );

  Future<ToolResult> _gitCommit(Map<String, dynamic> args, String? sessionId) {
    final String message = args['message']?.toString().trim() ?? '';
    if (message.isEmpty) {
      return Future.value(
        const ToolResult(ok: false, llmOutput: 'Parameter message is empty.'),
      );
    }
    final String authorName = args['authorName']?.toString().trim() ?? '';
    final String authorEmail = args['authorEmail']?.toString().trim() ?? '';
    if (authorName.isEmpty || authorEmail.isEmpty) {
      return Future.value(
        const ToolResult(
          ok: false,
          llmOutput:
              'git_commit needs authorName and authorEmail '
              '(ask the user for their identity).',
        ),
      );
    }
    return _gitRepo(
      args,
      sessionId,
      'commit',
      (String dir) => <String, dynamic>{
        'dir': dir,
        'message': message,
        'authorName': authorName,
        'authorEmail': authorEmail,
      },
    );
  }

  Future<ToolResult> _gitPush(Map<String, dynamic> args, String? sessionId) =>
      _gitRepo(
        args,
        sessionId,
        'push',
        (String dir) => <String, dynamic>{
          'dir': dir,
          'token': args['token']?.toString() ?? '',
          'branch': args['branch']?.toString() ?? '',
          'remote': args['remote']?.toString() ?? '',
        },
      );

  Future<ToolResult> _gitLog(Map<String, dynamic> args, String? sessionId) =>
      _gitRepo(
        args,
        sessionId,
        'log',
        (String dir) => <String, dynamic>{
          'dir': dir,
          'limit': (args['limit'] as int?) ?? 10,
        },
      );

  // -- Module doctor (v1.26.0): read-only inspection + export + a
  // user-confirmed repair install path. The agent can NEVER install or
  // overwrite a module silently: `module_stage_repair` only validates a
  // zip and surfaces a confirmation card the user must tap. -------------

  Future<ToolResult> _moduleList(String? sessionId) async {
    final ModuleRegistry? registry = modules;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Module management is not available in this build.',
      );
    }
    await registry.ensureCacheLoaded();
    final List<ChatModule> installed = await registry.listInstalled();
    if (installed.isEmpty) {
      return const ToolResult(ok: true, llmOutput: 'No modules installed.');
    }
    final StringBuffer out = StringBuffer();
    for (final ChatModule module in installed) {
      final ModuleManifest m = module.manifest;
      out.write(
        '${m.name} v${m.version} — ${m.title.isEmpty ? m.name : m.title} — '
        'permissions: ${m.permissions.isEmpty ? '(none)' : m.permissions.map((p) => p.name).join(',')} '
        '— setup form: ${m.setup != null && m.setup!.hasRequired ? 'yes' : 'no'} '
        '— entry: ${m.entry}',
      );
      // v1.33.0: report whether the per-chat setup form is ALREADY
      // completed for the calling chat — the model can finally see that
      // credentials are on file instead of asking the user for them.
      // Secret (password) fields are always masked by the shared helper.
      if (m.setup != null && m.setup!.hasRequired) {
        Map<String, dynamic> stored = const <String, dynamic>{};
        if (moduleRuntime != null && sessionId != null) {
          try {
            stored = await moduleRuntime!.readStoredSetup(sessionId, m.name);
          } catch (_) {
            // Unreadable storage counts as "not set up yet".
          }
        }
        out.write(
          m.setup!.satisfiedBy(stored)
              ? ' — setup for this chat: COMPLETED '
                    '(${describeModuleSetupValues(m.setup!, stored)}) — the '
                    'module gets these values automatically; never ask the '
                    'user to retype them'
              : ' — setup for this chat: NOT completed — the app\'s form '
                    'collects it on activation; do not ask the user to type '
                    'the values in chat',
        );
      }
      out.writeln();
    }
    return ToolResult(ok: true, llmOutput: out.toString().trim());
  }

  Future<ToolResult> _moduleRead(Map<String, dynamic> args) async {
    final ModuleRegistry? registry = modules;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Module management is not available in this build.',
      );
    }
    final String name = args['name']?.toString() ?? '';
    if (name.trim().isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Missing module name. Call module_list first.',
      );
    }
    final String rel = args['path']?.toString() ?? '';
    final ModuleFileRead read = await registry.readModuleFile(name, rel);
    if (!read.ok) {
      return ToolResult(ok: false, llmOutput: read.message);
    }
    if (read.content != null) {
      return ToolResult(
        ok: true,
        llmOutput: read.content!,
        displayText: rel.isEmpty ? 'module listing' : rel,
      );
    }
    return ToolResult(
      ok: true,
      llmOutput: 'Module files:\n${read.listing.join('\n')}',
      displayText: 'module listing',
    );
  }

  Future<ToolResult> _moduleExport(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final ModuleRegistry? registry = modules;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Module management is not available in this build.',
      );
    }
    final String name = args['name']?.toString() ?? '';
    if (name.trim().isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Missing module name. Call module_list first.',
      );
    }
    // The zip lands inside THIS chat's sandbox (exports/), so the user
    // finds it in the File Manager / can share it — never outside.
    final Directory base = await resolveBaseDir(sessionId);
    final ChatModule? module = await registry.get(name);
    if (module == null) {
      return ToolResult(ok: false, llmOutput: 'Module not installed: $name');
    }
    final String fileName = ModuleRegistry.presetZipFileName(
      module.name,
      module.manifest.version,
    );
    final String target =
        '${base.path}${Platform.pathSeparator}exports'
        '${Platform.pathSeparator}$fileName';
    final ModuleExportResult result = await registry.exportToZip(name, target);
    return ToolResult(
      ok: result.ok,
      llmOutput: result.ok
          ? '${result.message}. Archive: exports/$fileName — the user can '
                'share or reinstall it from the File Manager.'
          : result.message,
      displayText: result.ok ? 'exported $fileName' : 'export failed',
    );
  }

  Future<ToolResult> _moduleStageRepair(
    Map<String, dynamic> args,
    String? sessionId,
  ) async {
    final ModuleRegistry? registry = modules;
    if (registry == null) {
      return const ToolResult(
        ok: false,
        llmOutput: 'Module management is not available in this build.',
      );
    }
    final String path = args['path']?.toString() ?? '';
    if (path.trim().isEmpty) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'Missing zip path. Build the repaired module folder in this '
            'workspace (module.json + entry at the folder root), zip it '
            'with zip_file, then pass that zip path here.',
      );
    }
    final Directory base = await resolveBaseDir(sessionId);
    final String? resolved = _resolveFile(base, path)?.path;
    if (resolved == null) {
      return const ToolResult(
        ok: false,
        llmOutput:
            'Invalid path: the zip must live inside THIS chat workspace '
            '(no traversal).',
      );
    }
    if (!File(resolved).existsSync()) {
      return ToolResult(ok: false, llmOutput: 'ZIP not found: $path');
    }
    final ModuleInstallResult validation = await registry.validateZip(resolved);
    if (!validation.ok || validation.module == null) {
      return ToolResult(
        ok: false,
        llmOutput:
            'The zip is not a valid module — fix it and retry: '
            '${validation.message}',
      );
    }
    final ModuleManifest m = validation.module!.manifest;
    return ToolResult(
      ok: true,
      llmOutput:
          'Valid module zip: ${m.name} v${m.version} '
          '(permissions: ${m.permissions.isEmpty ? '(none)' : m.permissions.map((p) => p.name).join(',')}). '
          'A confirmation card is shown to the user — the module is NOT '
          'installed until the user taps Install. Tell the user what you '
          'fixed and why they should (or should not) install it.',
      displayText: 'repair ready: ${m.name} v${m.version}',
      data: <String, dynamic>{
        'zipPath': resolved,
        'name': m.name,
        'version': m.version,
        'title': m.title.isEmpty ? m.name : m.title,
        'permissions': m.permissions.map((p) => p.name).toList(),
      },
    );
  }
}
