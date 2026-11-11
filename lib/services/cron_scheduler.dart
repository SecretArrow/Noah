import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di.dart';
import '../models/cron_job.dart';
import 'background_service.dart';
import 'cron_parser.dart';
import 'cron_repository.dart';
import 'llm_client.dart';
import 'scheduled_job_runner.dart' show TelegramConfig;
import 'subagents.dart';
import 'telegram_sender.dart';
import 'tool_executor.dart';

/// Cron scheduler — ported from ZAgents (v1.49.9/v1.50.0) and adapted
/// for Noah' per-chat isolation rule:
///
/// * State, controller and repository are scoped PER CHAT SESSION
///   ([CronJobsController] is a family keyed by session id). A chat's
///   jobs are never visible to — and never fire inside — another chat.
/// * The telegram action uses the job's own bot token + chat id; when
///   either is empty the GLOBAL Noah Telegram configuration (the
///   Fase-F config on the CronJobs screen) is the fallback, per field.
/// * The agent action runs the headless fan-of-subagents inside the
///   OWNING chat's sandbox (executeTool is bound to the owner session).
/// * The chat action targets the OWNING chat by default; a job may
///   override the target via [CronJob.chatSessionId] in the editor.

/// How often the scheduler checks for due jobs. Cron is minute-granular;
/// 15 s keeps the fire delay invisible while costing one cheap datetime
/// comparison per job per tick.
const Duration cronTickInterval = Duration(seconds: 15);

/// Injectable wall clock — overridable in tests so every cron mutation
/// (save/toggle/reschedule) is deterministic against a fixed instant.
final cronClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Structured outcome of one dispatched action: [ok] feeds the history
/// dot + job status, [detail] is the human-readable line shown in the
/// manager and history list.
class CronDispatchResult {
  const CronDispatchResult({required this.ok, required this.detail});

  final bool ok;
  final String detail;
}

/// Executes one job's action. Implementations never throw — every
/// failure becomes [CronDispatchResult.detail], because a cron fire must
/// never crash the scheduler loop.
abstract class CronActionDispatcher {
  Future<CronDispatchResult> dispatch(CronJob job);
}

/// Production dispatcher: Telegram Bot API (per-job credentials with
/// the global config as fallback), the existing local notification
/// platform channel, a headless fan-of-subagents agent run inside the
/// owning chat's sandbox, and the chat action which injects the prompt
/// into a chat session through [runInChat] — by default the OWNING
/// chat (Noah rule), or the job's explicit target.
class DefaultCronDispatcher implements CronActionDispatcher {
  DefaultCronDispatcher({
    required this.llm,
    required this.telegram,
    required this.background,
    required this.executeTool,
    required this.resolveConfig,
    this.telegramFallback,
    this.runInChat,
  });

  final LlmClient llm;
  final TelegramSender telegram;
  final BackgroundRun background;

  /// Tool callback — the shared [ToolExecutor] (see toolExecutorProvider),
  /// so the cron subagent can use the same sandboxed workspace/browser
  /// toolset as in-chat subagents. The dispatcher binds it to the job's
  /// owning session for the agent action.
  final Future<ToolResult> Function(
    String name,
    Map<String, dynamic> args, {
    String? sessionId,
    String? browserContext,
  })
  executeTool;
  final LlmConfig Function() resolveConfig;

  /// Global Telegram configuration fallback (Noah Fase-F config).
  /// Consulted per field when the job's own token/chat id is empty.
  final Future<TelegramConfig> Function()? telegramFallback;

  /// Chat action runner: injects the prompt into the session
  /// ([sessionId] — the effective target) via
  /// ChatController.sendToSession. Returns null when accepted, otherwise
  /// the English refusal reason recorded in the cron history. Nullable
  /// so tests that never exercise the chat action can omit it.
  final Future<String?> Function(String sessionId, String prompt)? runInChat;

  static const int _maxNotifChars = 800;

  /// Effective telegram credentials for [job]: the job's own values win;
  /// empty fields fall back to the global configuration.
  Future<({String token, String chatId})> _credentials(CronJob job) async {
    String token = job.telegramToken.trim();
    String chatId = job.telegramChatId.trim();
    if ((token.isEmpty || chatId.isEmpty) && telegramFallback != null) {
      final TelegramConfig cfg = await telegramFallback!();
      if (token.isEmpty) token = cfg.botToken.trim();
      if (chatId.isEmpty) chatId = cfg.chatId.trim();
    }
    return (token: token, chatId: chatId);
  }

  Future<CronDispatchResult> _sendTelegram(CronJob job, String text) async {
    final ({String token, String chatId}) creds = await _credentials(job);
    final TelegramResult result = await telegram.send(
      botToken: creds.token,
      chatId: creds.chatId,
      text: text,
    );
    return CronDispatchResult(ok: result.ok, detail: result.message);
  }

  @override
  Future<CronDispatchResult> dispatch(CronJob job) async {
    switch (job.action) {
      case CronActionKind.telegram:
        final CronDispatchResult result = await _sendTelegram(
          job,
          job.messageText,
        );
        return CronDispatchResult(
          ok: result.ok,
          detail: result.ok ? 'sent' : result.detail,
        );

      case CronActionKind.notification:
        final bool ok = await background.notifyDone(
          title: job.notifTitle.trim().isEmpty ? job.name : job.notifTitle,
          text: job.notifText,
          sessionId: job.sessionId.isEmpty ? null : job.sessionId,
        );
        return CronDispatchResult(
          ok: ok,
          detail: ok ? 'notification posted' : 'notification channel failed',
        );

      case CronActionKind.chat:
        if (runInChat == null) {
          return const CronDispatchResult(
            ok: false,
            detail: 'chat runner unavailable',
          );
        }
        // Noah rule: the default target is the OWNING chat; an
        // explicit editor target overrides it.
        final String target = job.chatSessionId.trim().isNotEmpty
            ? job.chatSessionId.trim()
            : job.sessionId;
        if (target.isEmpty) {
          return const CronDispatchResult(
            ok: false,
            detail: 'chat target unknown',
          );
        }
        final String? refusal = await runInChat!(target, job.agentPrompt);
        return CronDispatchResult(
          ok: refusal == null,
          detail: refusal ?? 'prompt sent to chat',
        );

      case CronActionKind.agent:
        final SubagentRunner runner = SubagentRunner(
          llm: llm,
          resolveConfig: resolveConfig,
          executeTool:
              (
                String name,
                Map<String, dynamic> args,
                String? sessionId, {
                String? browserContext,
              }) => executeTool(
                name,
                args,
                // The agent action always works inside the OWNING
                // chat's sandbox, whatever the subagent asked for.
                sessionId: job.sessionId.isEmpty ? sessionId : job.sessionId,
                browserContext: browserContext,
              ),
        );
        final List<SubagentOutcome> outcomes = await runner.run(
          <SubagentTaskSpec>[
            SubagentTaskSpec(label: job.name, prompt: job.agentPrompt),
          ],
        );
        final SubagentOutcome outcome = outcomes.first;
        await _deliver(job, outcome.answer);
        return CronDispatchResult(
          ok: outcome.ok,
          detail: outcome.ok
              ? 'agent done: ${_truncate(outcome.answer, 120)}'
              : 'agent failed: ${_truncate(outcome.answer, 120)}',
        );
    }
  }

  /// Delivers an agent answer: always a local notification (falls back
  /// to the job name as title), plus an optional Telegram relay when
  /// telegram credentials resolve (job's own or the global fallback).
  Future<void> _deliver(CronJob job, String answer) async {
    final String title = job.notifTitle.trim().isEmpty
        ? job.name
        : job.notifTitle;
    await background.notifyDone(
      title: title,
      text: _truncate(answer, _maxNotifChars),
      sessionId: job.sessionId.isEmpty ? null : job.sessionId,
    );
    final ({String token, String chatId}) creds = await _credentials(job);
    if (creds.token.isNotEmpty && creds.chatId.isNotEmpty) {
      await telegram.send(
        botToken: creds.token,
        chatId: creds.chatId,
        text: answer,
      );
    }
  }

  static String _truncate(String text, int max) {
    final String flat = text.replaceAll('\n', ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}

/// Pure decision core (unit-tested without timers or IO): which jobs are
/// due at [now], and how a job's bookkeeping looks after a run.
class CronSchedulerCore {
  const CronSchedulerCore();

  /// Jobs that must fire at [now]: enabled (job AND master switch), with
  /// a computed next run that is due. A job whose [CronJob.nextRunAtMs]
  /// is null (invalid expression, never scheduled) never fires.
  List<CronJob> dueJobs(CronState state, DateTime now) {
    if (!state.enabled) return const <CronJob>[];
    final int nowMs = now.millisecondsSinceEpoch;
    return <CronJob>[
      for (final CronJob job in state.jobs)
        if (job.enabled && job.nextRunAtMs != null && job.nextRunAtMs! <= nowMs)
          job,
    ];
  }

  /// Bookkeeping after one execution attempt: stamps the last run, stores
  /// the outcome detail and advances nextRunAt (recomputed from [now] so
  /// a slow or missed period can never cascade-fire).
  CronJob afterRun(
    CronJob job,
    DateTime now,
    bool ok,
    String detail,
    CronExpression parsed,
  ) {
    final DateTime? next = parsed.nextAfter(now);
    return job.copyWith(
      lastRunAtMs: now.millisecondsSinceEpoch,
      lastResultOk: ok,
      lastResult: detail,
      nextRunAtMs: next?.millisecondsSinceEpoch,
    );
  }

  /// Boot recovery: jobs whose nextRunAt passed while the app was CLOSED
  /// are re-anchored to the next future occurrence WITHOUT firing (no
  /// catch-up spam after a long absence). Jobs still in the future are
  /// left untouched. Returns null when nothing changed (no save needed).
  CronState? rescheduleMissed(CronState state, DateTime now) {
    bool changed = false;
    final List<CronJob> jobs = <CronJob>[];
    for (final CronJob job in state.jobs) {
      final int? nextMs = job.nextRunAtMs;
      if (!job.enabled ||
          nextMs == null ||
          nextMs > now.millisecondsSinceEpoch) {
        jobs.add(job);
        continue;
      }
      changed = true;
      try {
        final DateTime? next = CronExpression.parse(job.expression)
            .nextAfter(now);
        jobs.add(job.copyWith(nextRunAtMs: next?.millisecondsSinceEpoch));
      } on CronFormatException {
        jobs.add(job.copyWith(nextRunAtMs: null));
      }
    }
    if (!changed) return null;
    return state.copyWith(jobs: jobs);
  }
}

/// Riverpod controller mirroring ONE chat's persisted [CronState]
/// (family keyed by session id) and exposing the CRUD + bookkeeping
/// mutations used by the manager screen and the scheduler service.
class CronJobsController extends FamilyNotifier<CronState, String> {
  @override
  CronState build(String sessionId) {
    _sessionId = sessionId;
    // Register this chat with the scheduler so its jobs get ticked even
    // when the chat is not on screen.
    ref.read(cronKnownSessionsProvider).add(sessionId);
    return ref.watch(cronRepositoryProvider).load(sessionId);
  }

  late String _sessionId;

  CronRepository get _repo => ref.read(cronRepositoryProvider);

  DateTime get _now => ref.read(cronClockProvider)();

  Future<void> _persist(CronState next) async {
    state = next;
    try {
      await _repo.save(_sessionId, next);
    } catch (_) {
      // Degraded persistence: in-session state stays applied (same
      // trade-off as SettingsController.update).
    }
  }

  /// Adds or replaces [job]; nextRunAt is recomputed from the expression
  /// (the editor validates, but a bad expression must still never crash —
  /// it simply never fires with nextRunAt = null). The job's owner is
  /// forced to this controller's session.
  Future<void> saveJob(CronJob job) async {
    int? nextMs;
    try {
      nextMs = CronExpression.parse(job.expression)
          .nextAfter(_now)
          ?.millisecondsSinceEpoch;
    } on CronFormatException {
      nextMs = null;
    }
    final CronJob stamped = job.copyWith(
      sessionId: _sessionId,
      nextRunAtMs: nextMs,
    );
    final List<CronJob> jobs = <CronJob>[
      for (final CronJob existing in state.jobs)
        if (existing.id == stamped.id) stamped else existing,
    ];
    if (!jobs.any((j) => j.id == stamped.id)) jobs.add(stamped);
    await _persist(state.copyWith(jobs: jobs));
  }

  Future<void> removeJob(String id) async {
    await _persist(
      state.copyWith(
        jobs: <CronJob>[
          for (final CronJob j in state.jobs)
            if (j.id != id) j,
        ],
        history: <CronRunEntry>[
          for (final CronRunEntry h in state.history)
            if (h.jobId != id) h,
        ],
      ),
    );
  }

  /// Master switch: pauses/resumes ALL jobs of THIS chat without
  /// deleting them.
  Future<void> setEnabled(bool enabled) async =>
      _persist(state.copyWith(enabled: enabled));

  /// Per-job enable toggle; re-anchors nextRun when re-enabled.
  Future<void> toggleJob(String id, bool enabled) async {
    CronJob? target;
    for (final CronJob j in state.jobs) {
      if (j.id == id) {
        target = j;
        break;
      }
    }
    if (target == null) return;
    int? nextMs = target.nextRunAtMs;
    if (enabled) {
      try {
        nextMs = CronExpression.parse(target.expression)
            .nextAfter(_now)
            ?.millisecondsSinceEpoch;
      } on CronFormatException {
        nextMs = null;
      }
    }
    await _persist(
      state.copyWith(
        jobs: <CronJob>[
          for (final CronJob j in state.jobs)
            if (j.id == id)
              j.copyWith(enabled: enabled, nextRunAtMs: nextMs)
            else
              j,
        ],
      ),
    );
  }

  /// Scheduler hook: applies the post-run bookkeeping and prepends a
  /// history entry (capped by the repository on save).
  Future<void> recordRun(
    CronJob updated,
    DateTime now,
    bool ok,
    String detail,
  ) async {
    await _persist(
      state.copyWith(
        jobs: <CronJob>[
          for (final CronJob j in state.jobs)
            if (j.id == updated.id) updated else j,
        ],
        history: <CronRunEntry>[
          CronRunEntry(
            jobId: updated.id,
            jobName: updated.name,
            atMs: now.millisecondsSinceEpoch,
            ok: ok,
            detail: detail,
          ),
          ...state.history,
        ],
      ),
    );
  }

  /// Boot recovery (see [CronSchedulerCore.rescheduleMissed]).
  Future<void> rescheduleMissed() async {
    final CronState? next = const CronSchedulerCore().rescheduleMissed(
      state,
      _now,
    );
    if (next != null) await _persist(next);
  }
}

/// Session ids the scheduler knows about. Controllers register their
/// session on build; main() seeds the set with every stored chat at
/// boot. The scheduler ticks exactly these sessions — a chat's jobs can
/// only ever fire inside its own scope.
final cronKnownSessionsProvider = Provider<Set<String>>((ref) => <String>{});

/// Timer-driven service tying the per-session repositories, controllers
/// and dispatcher together. Started once from main() (production boot) —
/// deliberately NOT from a widget's initState, so widget tests never
/// inherit a pending periodic timer.
class CronSchedulerService {
  CronSchedulerService({
    required this.controllerFor,
    required this.stateFor,
    required this.sessionIds,
    required this.dispatcher,
    this._core = const CronSchedulerCore(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CronJobsController Function(String sessionId) controllerFor;

  /// Reads the LIVE cron state of one chat through its provider.
  final CronState Function(String sessionId) stateFor;

  /// The sessions to tick (boot-seeded + controller-registered).
  final Iterable<String> Function() sessionIds;
  final CronActionDispatcher dispatcher;
  final CronSchedulerCore _core;
  final DateTime Function() _now;

  Timer? _timer;

  /// Whether the periodic tick is currently running (test/debug).
  bool get isRunning => _timer != null;

  /// Boots the scheduler: applies missed-run recovery per session, then
  /// starts the periodic tick. Safe to call twice (second is a no-op).
  Future<void> start() async {
    if (_timer != null) return;
    for (final String sid in sessionIds().toList()) {
      await controllerFor(sid).rescheduleMissed();
    }
    _timer = Timer.periodic(cronTickInterval, (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One scheduler pass over EVERY known session: fire every due job,
  /// record the outcome. Before each fire the job is re-checked so a
  /// save/toggle/disable during an earlier dispatch of the same pass
  /// cannot fire a job that was just removed or paused.
  Future<void> tick() async {
    final DateTime now = _now();
    for (final String sid in sessionIds().toList()) {
      final List<CronJob> due = _core.dueJobs(stateFor(sid), now);
      for (final CronJob job in due) {
        final CronState fresh = stateFor(sid);
        CronJob? current;
        for (final CronJob j in fresh.jobs) {
          if (j.id == job.id) {
            current = j;
            break;
          }
        }
        if (current == null ||
            !current.enabled ||
            !fresh.enabled ||
            current.nextRunAtMs == null ||
            current.nextRunAtMs! > now.millisecondsSinceEpoch) {
          continue;
        }
        await _fire(current, now);
      }
    }
  }

  /// Fires one job immediately regardless of schedule ("Run now" in the
  /// manager). Bookkeeping/history is recorded exactly like a scheduled
  /// fire.
  Future<CronDispatchResult> runNow(CronJob job) => _fire(job, _now());

  Future<CronDispatchResult> _fire(CronJob job, DateTime now) async {
    CronDispatchResult result;
    try {
      result = await dispatcher.dispatch(job);
    } catch (error) {
      // The dispatcher contract says "never throw", but a programming
      // error must still degrade to a recorded failure, not a crash.
      result = CronDispatchResult(
        ok: false,
        detail: 'dispatcher error: $error',
      );
    }
    CronJob stamped = job.copyWith(
      lastRunAtMs: now.millisecondsSinceEpoch,
      lastResultOk: result.ok,
      lastResult: result.detail,
    );
    if (job.id.isNotEmpty) {
      // Advance the schedule only for real (persisted) jobs — "run now"
      // probes keep their pending next occurrence.
      try {
        final DateTime? next = CronExpression.parse(job.expression)
            .nextAfter(now);
        stamped = stamped.copyWith(nextRunAtMs: next?.millisecondsSinceEpoch);
      } on CronFormatException {
        stamped = stamped.copyWith(nextRunAtMs: null);
      }
    }
    await controllerFor(job.sessionId)
        .recordRun(stamped, now, result.ok, result.detail);
    return result;
  }
}
