import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di.dart';
import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../tools/tool_defs.dart';
import 'background_service.dart';
import 'chat_store.dart' show SessionBundle;
import 'device_shell.dart';
import 'image_downscale.dart';
import 'llm_client.dart';
import 'make_plugins.dart';
import 'module_registry.dart';
import 'module_runtime.dart';
import 'skill_registry.dart';
import 'tool_executor.dart';

/// Wire-only user message appended when the model tries to finish while
/// its todo plan still has incomplete items (run-until-done + plan-first).
/// Never persisted as a visible chat message — the next assistant turn
/// simply continues working, like z.ai agent mode.
String planNudgeText(List<TodoItem> todos) {
  final StringBuffer buffer = StringBuffer(
    'Your task plan is not finished yet, so the task is not done. '
    'Incomplete todos:\n',
  );
  for (final TodoItem todo in todos) {
    if (todo.status == TodoStatus.completed) continue;
    // v1.49.0 (wave-2): blocked-aware — the model must see WHICH steps are
    // stalled (and why) so it keeps working on the unblocked ones instead
    // of treating them as plain pending.
    final String status = switch (todo.status) {
      TodoStatus.inProgress => 'in_progress',
      TodoStatus.blocked =>
        'blocked${todo.blockedReason.isEmpty ? '' : ' — ${todo.blockedReason}'}',
      _ => 'pending',
    };
    buffer.writeln('- [$status] ${todo.content}');
  }
  buffer
    ..writeln()
    ..write(
      'Continue working now: use your tools to complete the next todo, '
      'call todo_write to update the plan, and only write the final '
      'summary when every todo is completed.',
    );
  return buffer.toString();
}

/// Stable opening of every [todoSyncReminderText] message — the loop uses
/// it for the belt-and-braces dedup check on the wire tail.
const String todoSyncReminderPrefix =
    'Reminder: you have been doing work without updating your plan.';

/// v1.48.1 — wire-only user message appended after a tool batch that did
/// real work WITHOUT calling todo_write while an incomplete plan exists.
/// Mirrors [planNudgeText]'s mechanics (never persisted as a visible chat
/// message) and rendering, but lists the FULL plan with all statuses so
/// the model can re-send it accurately.
String todoSyncReminderText(List<TodoItem> todos) {
  final StringBuffer buffer = StringBuffer(
    '$todoSyncReminderPrefix '
    'Call todo_write NOW with the FULL updated list before continuing — '
    'mark finished steps completed, set exactly one next step '
    'in_progress, keep completed steps completed. Never batch plan '
    'updates at the end. Current plan:\n',
  );
  for (final TodoItem todo in todos) {
    final String status = switch (todo.status) {
      TodoStatus.inProgress => 'in_progress',
      TodoStatus.blocked =>
        'blocked${todo.blockedReason.isEmpty ? '' : ' — ${todo.blockedReason}'}',
      TodoStatus.completed => 'completed',
      _ => 'pending',
    };
    buffer.writeln('- [$status] ${todo.content}');
  }
  return buffer.toString();
}

/// Immutable UI state of the currently ACTIVE chat session.
class ChatState {
  const ChatState({
    this.sessionId,
    this.title = '',
    this.messages = const <ChatMessage>[],
    this.isRunning = false,
    this.isLoading = false,
    this.error,
    this.todos = const <TodoItem>[],
    this.pendingModule,
    this.activeModules = const <String>[],
    this.activeSkills = const <String>[],
    this.setupRequest,
    this.waitingForSetup = false,
    this.pendingModuleInstall,
    this.pendingConfirmation,
  });

  final String? sessionId;
  final String title;
  final List<ChatMessage> messages;
  final bool isRunning;

  /// True while a stored session is being read from disk after a chat
  /// switch. The screen must show the TARGET chat (empty transcript +
  /// spinner), never the previous chat's messages, todos or running
  /// state — that was the visible cross-chat leak during async loads.
  final bool isLoading;

  final String? error;

  /// Latest plan written via `todo_write` in the running session — drives
  /// the show/hide plan panel next to the thinking indicator.
  final List<TodoItem> todos;

  /// Module (plugins) selected on a FRESH DRAFT that activates with the
  /// first message. Null when no module is staged.
  final String? pendingModule;

  /// Modules currently active for the displayed session (per-chat
  /// private-window scope).
  final List<String> activeModules;

  /// v1.49.0 (wave-2): skills the user pinned to THIS chat through the
  /// composer's skill sheet. Non-empty replaces the global installed-skills
  /// set in the system prompt for this chat only; empty follows the global
  /// default. Isolated per chat like [activeModules] — one chat's selection
  /// never appears in another.
  final List<String> activeSkills;

  /// Module waiting for its per-chat setup form in THIS session — the UI
  /// shows a banner + form; submitting re-runs the module automatically.
  /// Null when no active module is missing required setup input.
  final ModuleSetupRequest? setupRequest;

  /// v1.29.0: true while a sent message WAITS for a module's required
  /// setup input. The agent must not process the queued message until the
  /// form is submitted — the send() gate queues the message (visible,
  /// persisted) and [ChatController.submitModuleSetup] resumes the cycle
  /// right after the form lands.
  final bool waitingForSetup;

  /// Repaired module zip staged by the agent (`module_stage_repair`) and
  /// awaiting the user's Install/Discard decision on the card.
  final ModuleInstallRequest? pendingModuleInstall;

  /// v1.38.0: confirmation prompt raised by `request_confirmation` in the
  /// DISPLAYED session — the dialog blocks that run until the user
  /// approves/denies. Background sessions never raise one (they fail
  /// closed with an actionable error instead).
  final ConfirmationRequest? pendingConfirmation;

  static const Object _unset = Object();

  ChatState copyWith({
    String? sessionId,
    String? title,
    List<ChatMessage>? messages,
    bool? isRunning,
    bool? isLoading,
    Object? error = _unset,
    List<TodoItem>? todos,
    Object? pendingModule = _unset,
    List<String>? activeModules,
    List<String>? activeSkills,
    Object? setupRequest = _unset,
    bool? waitingForSetup,
    Object? pendingModuleInstall = _unset,
    Object? pendingConfirmation = _unset,
  }) => ChatState(
    sessionId: sessionId ?? this.sessionId,
    title: title ?? this.title,
    messages: messages ?? this.messages,
    isRunning: isRunning ?? this.isRunning,
    isLoading: isLoading ?? this.isLoading,
    error: error == _unset ? this.error : error as String?,
    todos: todos ?? this.todos,
    pendingModule: pendingModule == _unset
        ? this.pendingModule
        : pendingModule as String?,
    activeModules: activeModules ?? this.activeModules,
    activeSkills: activeSkills ?? this.activeSkills,
    setupRequest: setupRequest == _unset
        ? this.setupRequest
        : setupRequest as ModuleSetupRequest?,
    waitingForSetup: waitingForSetup ?? this.waitingForSetup,
    pendingModuleInstall: pendingModuleInstall == _unset
        ? this.pendingModuleInstall
        : pendingModuleInstall as ModuleInstallRequest?,
    pendingConfirmation: pendingConfirmation == _unset
        ? this.pendingConfirmation
        : pendingConfirmation as ConfirmationRequest?,
  );
}

/// A module activation that is waiting for the user to fill its per-chat
/// setup form. Rendered as a banner + bottom-sheet form; the submitted
/// values persist into the (chat, module) storage and the module re-runs
/// automatically.
class ModuleSetupRequest {
  const ModuleSetupRequest({
    required this.moduleName,
    required this.moduleTitle,
    required this.setup,
    this.values = const <String, dynamic>{},
  });

  final String moduleName;
  final String moduleTitle;
  final ModuleSetup setup;

  /// Previously submitted values (when editing an existing setup) — or,
  /// when THIS chat has not satisfied the form yet, a convenience
  /// PREFILL merged from the user's latest submitted values for this
  /// module in another chat (current-chat values win per field). Either
  /// way the user confirms with Save & run before anything persists.
  final Map<String, dynamic> values;

  /// Display heading: manifest setup title or "<title> setup".
  String get title =>
      setup.title.isNotEmpty ? setup.title : '$moduleTitle setup';
}

/// A repaired module zip the AGENT staged via `module_stage_repair` and
/// the user has not confirmed yet. Rendered as a confirmation card;
/// nothing is installed until the user taps Install (the trust boundary
/// of the module doctor: the agent can prepare, the user decides).
class ModuleInstallRequest {
  const ModuleInstallRequest({
    required this.zipPath,
    required this.moduleName,
    required this.version,
    required this.title,
    this.permissions = const <String>[],
    this.isNew = false,
  });

  /// Absolute path of the validated zip inside the session sandbox.
  final String zipPath;
  final String moduleName;
  final String version;
  final String title;
  final List<String> permissions;

  /// True when the staged module is a NEW plugin built in this chat
  /// (no module with that name was installed when it was staged) — the
  /// card then shows the builder wording instead of the repair one.
  final bool isNew;
}

/// v1.38.0: an EXPLICIT user-approval prompt raised by the agent through
/// the `request_confirmation` tool — the authorization boundary for
/// money-moving/irreversible actions (Web3 transactions, token
/// approvals, destructive changes). The agent loop BLOCKS until the user
/// answers (or a 10-minute timeout counts as a denial). Login or wallet
/// connection is never treated as permission: every transaction gets its
/// own approval with a complete human-readable summary.
class ConfirmationRequest {
  const ConfirmationRequest({
    required this.id,
    required this.title,
    required this.details,
    this.danger = true,
  });

  /// Tool-call id this request belongs to.
  final String id;
  final String title;
  final List<String> details;
  final bool danger;
}

/// One parked approval prompt: which session raised it and the completer
/// the agent loop is waiting on. Keyed by tool-call id.
class _ConfirmationWaiter {
  _ConfirmationWaiter({required this.sessionId, required this.completer});

  final String sessionId;
  final Completer<bool> completer;
}

/// Internal state of one running (or recently run) session. Sessions run
/// in parallel: each keeps its own message list so switching to another
/// chat never interrupts the loop.
class _SessionRun {
  _SessionRun({
    required this.sessionId,
    required this.title,
    bool running = true,
  }) : isRunning = running;

  final String sessionId;
  String title;
  final List<ChatMessage> messages = <ChatMessage>[];
  bool isRunning = true;

  /// True after the loop finished but while the final persistence /
  /// auto-title / notification work is still in flight. A new send must
  /// NOT reuse this run object during that window (it would race the old
  /// finalizer over `isRunning` and `_runs`).
  bool finalizing = false;

  /// Completed once [_executeRun] has released this run (finished,
  /// failed or was stopped) and the session is out of `_runs`. A send
  /// that arrives while `finalizing` waits here instead of racing the
  /// finalizer over `isRunning` / `_runs`. Replaced (not reused) when a
  /// new run starts on the same object, so a waiter can never be woken by
  /// a different run's release.
  Completer<void> finalized = Completer<void>();

  /// Incremented by every [_executeRun] invocation. The release path of an
  /// older invocation must not clear flags or evict `_runs` when a newer
  /// run already took over this same object.
  int runToken = 0;

  /// Buffer of the assistant turn currently streaming, when one is in
  /// flight. Background runs do NOT materialize it into a [ChatMessage]
  /// on every delta (nobody is rendering them); the buffer is materialized
  /// once when the user switches back to the chat (see [openChat]) and
  /// authoritatively at turn end.
  StringBuffer? streamingBuffer;

  bool stopRequested = false;

  /// True while the session title still came from the automatic
  /// `_titleFor(prompt)` path (fresh session or history fallback): the
  /// first successful answer then triggers the model-generated title.
  /// A user rename flips this off permanently.
  bool autoTitlePending = false;

  /// Set when the user deletes the session mid-run: the final persist is
  /// skipped so the conversation cannot resurrect itself.
  bool deleted = false;

  /// v1.38.0 perf: the chat-list snapshot is refreshed ONCE per run (at
  /// the first persist, so a new session appears in the drawer right
  /// away) and again at run end — NOT on every per-step persist. The old
  /// per-step invalidation made every tool batch re-read + re-decode ALL
  /// chat files from disk (drawer open: C x file reads per step per
  /// concurrent session) for zero visible benefit.
  bool listInvalidatePending = true;

  /// base64 payloads cached per attachment path (avoid re-encoding images
  /// on every wire rebuild).
  final Map<String, String> dataUrlCache = <String, String>{};

  /// Text contents of text-like attachments, read once per run.
  final Map<String, String> textCache = <String, String>{};

  /// Latest plan written via `todo_write` in THIS run. Mirrored into the
  /// [ChatState] on every sync so the UI can show live plan progress.
  List<TodoItem> latestTodos = const <TodoItem>[];

  /// Chat modules (plugins) active for THIS session — a per-chat
  /// private-window scope: activating a module in another chat never
  /// affects this list, and each active module gets its own state
  /// directory under this session's sandbox.
  final List<String> activeModules = <String>[];

  /// Module staged on the draft; activates with the first message.
  String? pendingModule;

  /// Serialization tail for [ChatController._persist] — every save for
  /// this run is queued behind the previous one (ordering guarantee for
  /// the fire-and-forget persist-at-start vs the final save).
  Future<void> persistChain = Future<void>.value();

  /// Skills the user pinned to THIS chat (v1.49.0 wave-2) — per-chat
  /// scope like [activeModules]. Non-empty replaces the global skill set
  /// in the next system prompt built for this session.
  final List<String> activeSkills = <String>[];

  /// Module activation currently blocked behind its per-chat setup form
  /// (null when nothing waits). Mirrored into the UI state on every sync.
  ModuleSetupRequest? setupRequest;

  /// v1.29.0: true while queued user message(s) wait for a module's
  /// required setup input (see [ChatState.waitingForSetup]).
  bool waitingForSetup = false;

  /// Repaired module zip staged by the agent and awaiting the user's
  /// decision (in-memory per run, like [pendingModule]).
  ModuleInstallRequest? pendingInstall;

  /// Absolute path of the app documents directory, resolved once per run so
  /// binary attachment notes can advertise the documents-relative path the
  /// file tools expect (e.g. `uploads/1_project.zip`).
  String? docsPath;
}

/// Drives multi-session agent loops: user prompt -> LLM (streaming) ->
/// tool calls -> tool results -> ... -> final answer, per session, in
/// parallel. Also handles persistence, history and renaming.
class ChatController extends Notifier<ChatState> {
  final Map<String, _SessionRun> _runs = <String, _SessionRun>{};

  /// v1.38.0: pending user-approval waiters keyed by tool-call id —
  /// `_requestConfirmation` parks the agent loop here until the user
  /// answers the dialog (`resolveConfirmation`) or the 10-minute timeout
  /// fires (counts as a denial; nothing irreversible may proceed on
  /// silence). Each waiter records its OWN session so cancelling one
  /// chat's prompt (switch/Stop/delete) can never deny another chat's
  /// pending action.
  final Map<String, _ConfirmationWaiter> _confirmationWaiters =
      <String, _ConfirmationWaiter>{};

  /// The session currently rendered by the UI (null = fresh draft).
  String? _activeSessionId;

  /// v1.38.1 — staged composer attachments per chat (key: session id,
  /// null = fresh draft). [pendingAttachmentsProvider] stays the VIEW of
  /// the displayed chat; this map is the STORE — switching away and back
  /// now PRESERVES each chat's own staged files (v1.38.0 cleared them,
  /// which fixed the leak but lost the user's picks). Files still never
  /// travel between chats.
  final Map<String?, List<ChatAttachment>> _stagedAttachments =
      <String?, List<ChatAttachment>>{};

  /// v1.38.1 — composer draft text per chat (key: session id, null =
  /// fresh draft). Typed text travels with its own chat; one chat's
  /// draft never appears in another.
  final Map<String?, String> _draftTexts = <String?, String>{};

  /// Stashes the currently displayed staged-attachment list into the
  /// store (call BEFORE changing [_activeSessionId]).
  void _stashStagedAttachments() {
    _stagedAttachments[_activeSessionId] = List<ChatAttachment>.unmodifiable(
      ref.read(pendingAttachmentsProvider),
    );
  }

  /// Swaps the provider view to [sessionId]'s own staged list.
  void _restoreStagedAttachments(String? sessionId) {
    ref
        .read(pendingAttachmentsProvider.notifier)
        .state = List<ChatAttachment>.unmodifiable(
      _stagedAttachments[sessionId] ?? const <ChatAttachment>[],
    );
  }

  /// v1.38.1 — composer draft text of the DISPLAYED chat.
  String draftTextFor(String? sessionId) => _draftTexts[sessionId] ?? '';

  void setDraftText(String? sessionId, String text) {
    if (text.isEmpty) {
      _draftTexts.remove(sessionId);
    } else {
      _draftTexts[sessionId] = text;
    }
  }

  /// Monotonic token for async history loads. Every openChat/newChat/send
  /// bumps it; a load whose token no longer matches must NOT commit its
  /// (now stale) snapshot over the newer screen. Without this, a slow
  /// openChat(B) could land after the user already sent a message in B
  /// and overwrite the live transcript with the pre-send file.
  int _chatLoadGeneration = 0;

  /// Sessions whose history is currently being materialized, with the
  /// in-flight future so a second caller SHARES the load instead of
  /// starting a parallel one. Without this a double-tap (or send racing
  /// activateModule) could adopt the same session twice and start two
  /// parallel runs for one chat.
  final Map<String, Future<_SessionRun?>> _materializing =
      <String, Future<_SessionRun?>>{};

  @override
  ChatState build() {
    // v1.38.1 — lifecycle guard: a background chain (module run with
    // awaitRun:false, queued-message resume, an agent loop finishing after
    // teardown/app shutdown) can outlive this provider's container. Once
    // disposed, every ref/state touch in those chains degrades to a no-op
    // instead of throwing "provider container already disposed".
    ref.onDispose(() => _alive = false);
    return const ChatState();
  }

  /// True while the provider container is alive (see [build]).
  bool _alive = true;

  /// Sessions whose agent loop is still active. Finished runs stay in
  /// [_runs] (their messages are still on screen) but must not keep the
  /// drawer's "running" badge spinning forever.
  Set<String> get runningIds => <String>{
    for (final _SessionRun run in _runs.values)
      if (run.isRunning) run.sessionId,
  };

  void _markRunning() {
    if (!_alive) return;
    final Set<String> next = runningIds;
    try {
      final StateController<Set<String>> notifier = ref.read(
        runningSessionsProvider.notifier,
      );
      final Set<String> current = notifier.state;
      // v1.39.0: assign only on a real change. Every assignment notifies
      // the drawer (which rebuilds its whole history list), and the old
      // code assigned a fresh Set on every call — including two identical
      // ones at run end.
      if (next.length == current.length && next.containsAll(current)) return;
      notifier.state = next;
    } catch (_) {
      // Container gone between the flag check and the read — ignore.
    }
  }

  /// Stops the ACTIVE session's loop (other sessions keep running) and
  /// safely terminates any chat-module execution belonging to it.
  void stop() {
    final String? id = _activeSessionId;
    if (id != null) {
      _runs[id]?.stopRequested = true;
      // v1.38.0: an open approval prompt must fail closed on Stop — the
      // agent must not resume a money-moving action after the user
      // interrupted.
      _cancelConfirmationsForSession(id);
      try {
        ref.read(moduleRuntimeProvider).terminateSession(id);
      } catch (_) {
        // Runtime unavailable: the stop itself still proceeds.
      }
    }
  }

  /// v1.42.0 — HARD stop for the ACTIVE session, offered after the user
  /// tapped Stop three times (see the composer's force-stop dialog).
  /// [stop] is cooperative: it is polled between SSE deltas and at loop
  /// checkpoints, so a STALLED connection that emits nothing can keep the
  /// run pinned. [forceStop] additionally tears the run's HTTP transport
  /// down RIGHT NOW via [LlmClient.forceCancel], so even a silent socket
  /// errors out immediately and the normal, well-tested release path
  /// (stopped marker → persist → state release → background release)
  /// takes over. Idempotent: safe to call repeatedly.
  void forceStop() {
    final String? id = _activeSessionId;
    final _SessionRun? run = id != null ? _runs[id] : null;
    if (run == null) return;
    stop();
    LlmClient.forceCancel(run);
  }

  Future<void> send(
    String text, {
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) async {
    final String trimmed = text.trim();
    // A chat still being read from disk has no transcript yet: sending
    // now would fork a fresh run over a session whose history is about to
    // arrive (and duplicate the first message). The composer disables
    // send in this state; this guard makes it safe regardless.
    if (trimmed.isEmpty || state.isRunning || state.isLoading) return;
    final String? targetAtStart = _activeSessionId;
    _SessionRun? run = targetAtStart != null ? _runs[targetAtStart] : null;
    // The previous run finished its loop but is still persisting / titling.
    // Wait for it to release the session instead of starting a second loop
    // over the same object (which used to race `isRunning` and `_runs`).
    if (run != null && run.finalizing) {
      await run.finalized.future;
      if (_activeSessionId != targetAtStart) return;
      run = targetAtStart != null ? _runs[targetAtStart] : null;
    }
    if (run != null && run.isRunning) return; // active session busy
    // A message is being appended to this chat: any history load still in
    // flight for it is now stale and must not commit over the live state.
    _chatLoadGeneration++;

    final settings = ref.read(settingsProvider);
    final AppStrings strings = appStringsFor(settings.languageCode);
    if (settings.apiKey.trim().isEmpty) {
      state = state.copyWith(error: strings.missingApiKey);
      return;
    }
    if (settings.model.trim().isEmpty) {
      state = state.copyWith(error: strings.modelNotSet);
      return;
    }

    // Module staged on the draft (module chip on the empty state) —
    // captured BEFORE the session-state reset below can drop it.
    final String? stagedModule = state.pendingModule;
    // v1.49.0 (wave-2): skills applied on a FRESH DRAFT (no open chat yet)
    // travel into the session created by this first message. An existing
    // chat keeps its own persisted selection instead.
    final List<String> stagedSkills = _activeSessionId == null
        ? state.activeSkills
        : const <String>[];

    // Continue the active session, or create a new one. An OPEN but not
    // currently-running session (opened from history, or one whose run has
    // finished) must be CONTINUED — sending a message must never silently
    // fork a brand-new chat. A fresh chat is only created when there is no
    // open conversation at all (i.e. the user tapped "New chat" / fresh app
    // start with no history).
    if (run == null) {
      final String? openId = _activeSessionId;
      if (openId != null) {
        run = await _adoptSession(openId, trimmed);
        _runs[openId] = run;
        // The user may have switched chats while the history was loading. The
        // message still belongs to `openId`, so the run continues in the
        // BACKGROUND — dropping it would silently lose what the user sent,
        // and stealing focus back would yank them out of the chat they opened.
        if (_activeSessionId == openId) {
          state = ChatState(
            sessionId: openId,
            title: run.title,
            messages: [...run.messages],
            // v1.35.0: the plan restored from disk stays visible while the
            // continuation run takes over (a crash-interrupted task keeps
            // its plan instead of starting from a blank panel).
            todos: [...run.latestTodos],
            activeSkills: [...run.activeSkills],
            isRunning: true,
          );
        }
      } else {
        final String sessionId = newId();
        run = _SessionRun(sessionId: sessionId, title: _titleFor(trimmed));
        run.autoTitlePending = true;
        _runs[sessionId] = run;
        _activeSessionId = sessionId;
        state = ChatState(
          sessionId: sessionId,
          title: run.title,
          messages: run.messages,
          // Skills staged on the draft land in run.activeSkills below; the
          // fresh state mirrors them so the composer chip stays truthful.
          activeSkills: [...stagedSkills],
          isRunning: true,
        );
      }
    } else if (_activeSessionId == run.sessionId) {
      state = state.copyWith(isRunning: true, error: null);
    }

    // A module staged on the draft activates with the FIRST message of the
    // session — inside _executeRun, right after the user message lands, so
    // the transcript reads: user → module output → agent reply.
    run.pendingModule ??= stagedModule;
    if (stagedSkills.isNotEmpty) run.activeSkills.addAll(stagedSkills);
    if (_activeSessionId == run.sessionId) {
      state = state.copyWith(pendingModule: null);
    }

    // v1.29.0 — setup-input gate: when a selected module (staged on the
    // draft, or already active in this chat) still requires its per-chat
    // setup form, the message is QUEUED — appended, persisted, visible —
    // and the agent is NOT started. The queued message is processed right
    // after the form is submitted (submitModuleSetup), so a chat is never
    // worked on without the input the module requires.
    final List<String> gateNames = <String>[
      if (run.pendingModule != null) run.pendingModule!,
      ...run.activeModules,
    ];
    if (gateNames.isNotEmpty) {
      final ModuleSetupRequest? gate = await _findSetupRequest(
        run.sessionId,
        gateNames,
      );
      if (gate != null) {
        run.setupRequest = gate;
        run.waitingForSetup = true;
        run.isRunning = false;
        run.messages.add(ChatMessage.user(trimmed, attachments: attachments));
        _sync(run);
        _markRunning();
        if (_activeSessionId == run.sessionId) {
          state = state.copyWith(
            isRunning: false,
            activeModules: [...run.activeModules],
            error: null,
          );
        }
        unawaited(_persist(run));
        return;
      }
    }

    // v1.38.1: the staged files went out with THIS message — the store
    // must not keep them (the provider view was already cleared by the
    // composer; the store would otherwise resurrect them on chat switch).
    _stagedAttachments.remove(run.sessionId);
    await _executeRun(run, settings, prompt: trimmed, attachments: attachments);
  }

  /// v1.50.0 — cron "run in chat": injects [text] into the session
  /// [targetSessionId] exactly like a typed message. A null/empty target
  /// starts a BRAND-NEW background chat that never steals the screen (the
  /// on-screen draft stays untouched); an existing target continues its
  /// stored history, modules and skills. When the target happens to be
  /// the chat on screen, the transcript live-updates through [_sync];
  /// otherwise the run is fully background and the drawer refreshes when
  /// it finishes (plus the regular done-notification off-screen).
  ///
  /// Returns null when the run was accepted; otherwise a short English
  /// refusal reason for the cron history line. Refusals never throw and
  /// never touch the on-screen chat: a cron fire must not barge into a
  /// live conversation, a deleted session, or a chat parked on a module
  /// setup form (only the user can answer that form).
  Future<String?> sendToSession(String? targetSessionId, String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return 'empty prompt';
    if (!_alive) return 'app shutting down';
    final settings = ref.read(settingsProvider);
    if (settings.apiKey.trim().isEmpty) return 'missing API key';
    if (settings.model.trim().isEmpty) return 'model not set';

    final String? target =
        (targetSessionId == null || targetSessionId.trim().isEmpty)
        ? null
        : targetSessionId.trim();
    _SessionRun? run = target != null ? _runs[target] : null;
    if (run != null && (run.isRunning || run.finalizing)) return 'chat busy';
    if (run == null) {
      if (target == null) {
        // Fresh background chat — deliberately does NOT touch
        // _activeSessionId or the provider state.
        final String sessionId = newId();
        run = _SessionRun(sessionId: sessionId, title: _titleFor(trimmed));
        run.autoTitlePending = true;
        _runs[sessionId] = run;
      } else {
        // An unknown (deleted) session must not silently resurrect: the
        // stored-title probe doubles as an existence check.
        final String storedTitle = await _storedTitle(target);
        if (storedTitle.isEmpty) return 'chat not found';
        run = await _adoptSession(target, trimmed);
        if (run.isRunning || run.finalizing) return 'chat busy';
        _runs[target] = run;
      }
    }
    // Claim the run BEFORE the async setup-gate probe so a user message
    // racing the same session sees `isRunning` and backs off instead of
    // starting a second loop over the same run object.
    run.isRunning = true;
    final List<String> gateNames = <String>[...run.activeModules];
    if (gateNames.isNotEmpty) {
      final ModuleSetupRequest? gate = await _findSetupRequest(
        run.sessionId,
        gateNames,
      );
      if (gate != null) {
        run.isRunning = false;
        return 'chat waiting for module setup';
      }
    }
    if (_activeSessionId == run.sessionId) {
      _chatLoadGeneration++;
      state = state.copyWith(isRunning: true, error: null);
    }
    await _executeRun(run, settings, prompt: trimmed);
    return null;
  }

  /// Clears the module staged on a fresh draft (chip unselected).
  void stageNoModule() {
    if (state.pendingModule == null) return;
    state = state.copyWith(pendingModule: null);
  }

  /// v1.49.0 (wave-2) — the per-chat ACTIVE SKILLS selection from the
  /// composer's skill sheet. Replaces the whole selection; an empty list
  /// means "follow the global default" (the system prompt then advertises
  /// every installed skill again).
  ///
  /// Applies to the ACTIVE chat only:
  /// * fresh draft (no session yet) → stored on the draft state and
  ///   adopted by the session created with the next message;
  /// * open session → mirrored into the session's run + persisted with the
  ///   transcript, so it survives restarts and never leaks to other chats.
  ///
  /// Takes effect on the NEXT system-prompt build (the next agent turn);
  /// a run already streaming keeps its current prompt.
  Future<void> setActiveSkills(List<String> skills) async {
    final List<String> cleaned = <String>[
      for (final String name in skills)
        if (name.trim().isNotEmpty) name.trim(),
    ];
    final String? sessionId = _activeSessionId;
    if (sessionId == null) {
      if (listEquals(state.activeSkills, cleaned)) return;
      state = state.copyWith(activeSkills: cleaned);
      return;
    }
    _SessionRun? run = _runs[sessionId];
    if (run == null) {
      run = await _materializeSession(sessionId);
      if (run == null) {
        // Unreadable history: still keep the user's choice on screen.
        state = state.copyWith(activeSkills: cleaned);
        return;
      }
      _runs[sessionId] = run;
    }
    if (listEquals(run.activeSkills, cleaned)) return;
    run.activeSkills
      ..clear()
      ..addAll(cleaned);
    if (_activeSessionId == sessionId) {
      state = state.copyWith(activeSkills: [...run.activeSkills]);
    }
    // Persisted even without a new message, so the choice survives an app
    // restart (same lifecycle as the per-chat module list).
    await _persist(run);
  }

  /// Activates a chat module for the CURRENT context:
  /// * fresh draft → the module is staged (pendingModule) and activates
  ///   with the first message;
  /// * open session → the module activates immediately: it joins the
  ///   session's private-window scope and its entry point runs with the
  ///   output posted as a module message.
  ///
  /// The UI shows the permission dialog BEFORE calling this; the granted
  /// set is therefore the module's declared manifest permissions.
  Future<void> activateModule(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final String? sessionId = _activeSessionId;
    if (sessionId == null) {
      // Draft: stage for the first message.
      if (state.pendingModule == trimmed) return;
      state = state.copyWith(pendingModule: trimmed);
      return;
    }
    _SessionRun? run = _runs[sessionId];
    if (run == null) {
      run = await _materializeSession(sessionId);
      if (run == null) return;
      _runs[sessionId] = run;
    }
    if (run.isRunning || (_activeSessionId == sessionId && state.isRunning)) {
      state = state.copyWith(
        error: appStringsFor(ref.read(settingsProvider).languageCode)
            .moduleSessionBusy,
      );
      return;
    }
    if (run.activeModules.contains(trimmed)) return;
    await _activateModule(run, trimmed);
  }

  /// Deactivates a chat module for the ACTIVE session: removes it from the
  /// per-chat scope, safely terminates a live execution and records the
  /// change as a module message. Returns false when nothing was active.
  Future<bool> deactivateModule(String name) async {
    final String trimmed = name.trim();
    final String? sessionId = _activeSessionId;
    if (sessionId == null || trimmed.isEmpty) return false;
    _SessionRun? run = _runs[sessionId];
    if (run == null) {
      run = await _materializeSession(sessionId);
      if (run == null) return false;
      _runs[sessionId] = run;
    }
    if (!run.activeModules.contains(trimmed)) return false;
    run.activeModules.remove(trimmed);
    // Safe termination: cancel any live execution; persisted per-chat
    // state (storage.json, state/) is intentionally kept for the day the
    // module is re-activated in this chat.
    try {
      ref.read(moduleRuntimeProvider).terminate(sessionId, trimmed);
    } catch (_) {
      // Runtime unavailable: the deactivation itself still proceeds.
    }
    // A pending setup request for this module dies with the activation.
    // v1.29.0: if THIS module was blocking a queued message, the wait is
    // re-evaluated — another active module may still gate, otherwise the
    // queued message is released to the agent right away.
    bool releaseQueued = false;
    if (run.setupRequest?.moduleName == trimmed) run.setupRequest = null;
    if (run.waitingForSetup && run.setupRequest == null) {
      final ModuleSetupRequest? nextGate = run.activeModules.isEmpty
          ? null
          : await _findSetupRequest(run.sessionId, run.activeModules);
      if (nextGate != null) {
        run.setupRequest = nextGate;
      } else {
        run.waitingForSetup = false;
        releaseQueued = run.messages.any(
          (ChatMessage m) => m.role == Role.user,
        );
      }
    }
    final AppStrings strings = appStringsFor(
      ref.read(settingsProvider).languageCode,
    );
    run.messages.add(
      ChatMessage.assistant(
        strings.moduleDeactivated(trimmed),
        moduleName: trimmed,
      ),
    );
    _sync(run);
    if (_activeSessionId == sessionId) {
      state = state.copyWith(
        activeModules: [...run.activeModules],
        setupRequest: run.setupRequest,
        waitingForSetup: run.waitingForSetup,
      );
    }
    await _persist(run);
    if (releaseQueued) await _resumeQueuedRun(run);
    return true;
  }

  /// Activates [name] on a materialized run: executes the entry point in
  /// the session's isolated sandbox and posts the output as a module
  /// message. Failures degrade into the message body — they never break
  /// the chat. [activationPrompt] is the user message that triggered this
  /// activation (staged-module path); the module reads it as
  /// `zagents.info.prompt` so setup commands work on the first message.
  ///
  /// When the manifest declares a per-chat setup form with required
  /// fields and THIS chat has not filled them yet, the module does NOT
  /// run: a localized "needs setup" message is posted, the form request
  /// is surfaced on the state, and [submitModuleSetup] re-runs the module
  /// once the user submits the form.
  Future<void> _activateModule(
    _SessionRun run,
    String name, {
    String? activationPrompt,
  }) async {
    if (!_alive) return; // v1.38.1: container gone — nothing left to do.
    final AppStrings strings = appStringsFor(
      ref.read(settingsProvider).languageCode,
    );
    final ChatModule? module = await ref.read(moduleRegistryProvider).get(name);
    if (module == null) {
      if (_activeSessionId == run.sessionId) {
        state = state.copyWith(error: strings.moduleNotFound(name));
      }
      return;
    }
    if (!run.activeModules.contains(name)) run.activeModules.add(name);
    run.pendingModule = null;

    // Per-chat setup gate: required form fields must be satisfied before
    // the module's code runs — the user fills the form INSTEAD of seeing
    // a failed first cycle.
    final ModuleSetup? setup = module.manifest.setup;
    if (setup != null && setup.hasRequired) {
      Map<String, dynamic> values = const <String, dynamic>{};
      try {
        values = await ref
            .read(moduleRuntimeProvider)
            .readStoredSetup(run.sessionId, module.name);
      } catch (_) {
        // Unreadable storage simply counts as "not set up yet".
      }
      if (!setup.satisfiedBy(values)) {
        final ModuleSetupRequest request = ModuleSetupRequest(
          moduleName: module.name,
          moduleTitle: module.manifest.title.isEmpty
              ? module.name
              : module.manifest.title,
          setup: setup,
          values: await _setupFormValues(run.sessionId, module, values),
        );
        run.setupRequest = request;
        final ChatMessage moduleMessage = ChatMessage.assistant(
          '${strings.moduleSetupNeededTitle(request.title)}\n'
          '${strings.moduleSetupNeededBody}',
          moduleName: name,
        );
        run.messages.add(moduleMessage);
        _sync(run);
        if (_activeSessionId == run.sessionId) {
          state = state.copyWith(
            activeModules: [...run.activeModules],
            setupRequest: request,
          );
        }
        await _persist(run);
        return;
      }
    }
    run.setupRequest = null;

    final ChatMessage moduleMessage = ChatMessage.assistant(
      '',
      moduleName: name,
    );
    run.messages.add(moduleMessage);
    _sync(run);
    if (_activeSessionId == run.sessionId) {
      state = state.copyWith(
        activeModules: [...run.activeModules],
        setupRequest: null,
      );
    }

    final StringBuffer body = StringBuffer();
    // v1.34.0 jank fix: chatty modules (console/emit lines) used to
    // trigger an unthrottled full-state sync PER LINE. Coalesce with the
    // same 48ms streaming gap; a forced final refresh lands the complete
    // output when the run finishes.
    int lastModuleSync = 0;
    // One scheduled refresh at a time: a chatty module used to enqueue a
    // `Timer.run` PER EMITTED LINE, flooding the event queue even though the
    // refresh itself was throttled.
    bool emitScheduled = false;
    void refresh({bool force = false}) {
      final int index = run.messages.indexOf(moduleMessage);
      if (index == -1) return;
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now - lastModuleSync < _streamSyncGapMs) return;
      lastModuleSync = now;
      run.messages[index] = ChatMessage.assistant(
        body.toString(),
        moduleName: name,
        // v1.38.0: stable id — the module bubble re-renders in place
        // instead of being torn down on every throttled refresh.
        id: moduleMessage.id,
      );
      _sync(run);
    }

    try {
      final ModuleRunResult result = await ref
          .read(moduleRuntimeProvider)
          .run(
            sessionId: run.sessionId,
            module: module,
            granted: module.manifest.permissions,
            activationPrompt: activationPrompt,
            onChatEmit: (String text) {
              // The buffer write is cheap and must stay in order; only the
              // UI sync is deferred. One pending timer covers any burst.
              body.writeln(text);
              if (emitScheduled) return;
              emitScheduled = true;
              // Schedule the UI update OUTSIDE the platform-message turn:
              // updating Riverpod state synchronously inside the handler
              // was observed to swallow the next queued frame.
              Timer.run(() {
                emitScheduled = false;
                refresh();
              });
            },
          );
      if (result.output.trim().isNotEmpty) {
        if (body.isNotEmpty) body.writeln();
        body.write(result.output);
      }
      if (!result.ok) {
        if (body.isNotEmpty) {
          body
            ..writeln()
            ..writeln();
        }
        body.write(
          result.terminated
              ? strings.moduleTerminated
              : strings.moduleRunFailed(result.error ?? ''),
        );
        // Setup-required interception: a module that fails BECAUSE its
        // per-chat input is missing must never dead-end. This covers the
        // stale-zip case (installed module predates the setup form and
        // keeps failing after app updates) and any path where the gate
        // did not fire (values wiped, manifest changed after activation).
        if (moduleRunNeedsSetup(result)) {
          await _handleSetupRequiredFailure(run, name, body, strings);
        }
      }
    } catch (e) {
      if (body.isNotEmpty) {
        body
          ..writeln()
          ..writeln();
      }
      body.write(strings.moduleRunFailed('$e'));
    }
    refresh(force: true);
    await _persist(run);
  }

  /// Reacts to a module run that failed with a setup-required signal:
  ///
  /// * If the CURRENT manifest (fresh from the registry — the user may
  ///   have reinstalled an updated zip since activation) declares a
  ///   required setup form and this chat has not filled it, the form is
  ///   surfaced right here (banner + sheet) and the localized "needs
  ///   setup" text is appended to the module message.
  /// * Otherwise the run failed with a STALE module zip (installed before
  ///   the setup form existed — it survives app updates on device), so
  ///   the localized legacy guidance names the two concrete solutions:
  ///   install the updated module zip, or run the module's own setup
  ///   command in a fresh chat.
  Future<void> _handleSetupRequiredFailure(
    _SessionRun run,
    String name,
    StringBuffer body,
    AppStrings strings,
  ) async {
    final ChatModule? fresh = await ref.read(moduleRegistryProvider).get(name);
    final ModuleSetup? liveSetup = fresh?.manifest.setup;
    if (liveSetup != null && liveSetup.hasRequired) {
      Map<String, dynamic> values = const <String, dynamic>{};
      try {
        values = await ref
            .read(moduleRuntimeProvider)
            .readStoredSetup(run.sessionId, fresh!.name);
      } catch (_) {
        // Unreadable storage simply counts as "not set up yet".
      }
      if (!liveSetup.satisfiedBy(values)) {
        final ModuleSetupRequest request = ModuleSetupRequest(
          moduleName: fresh!.name,
          moduleTitle: fresh.manifest.title.isEmpty
              ? fresh.name
              : fresh.manifest.title,
          setup: liveSetup,
          values: await _setupFormValues(run.sessionId, fresh, values),
        );
        run.setupRequest = request;
        body
          ..writeln()
          ..writeln()
          ..write('${strings.moduleSetupNeededTitle(request.title)}\n')
          ..write(strings.moduleSetupNeededBody);
        if (_activeSessionId == run.sessionId) {
          state = state.copyWith(setupRequest: request);
        }
        return;
      }
    }
    body
      ..writeln()
      ..writeln()
      ..write(strings.moduleSetupLegacyHint(name));
  }

  /// Submits the per-chat setup form for [moduleName]: validates the
  /// required fields, persists the values into the (chat, module)
  /// storage under the cooperative `zagentsSetup` key, clears the pending
  /// request and RE-RUNS the module for the active chat — "fill the form,
  /// then it runs". Returns false when the values are incomplete or no
  /// matching module is active in the current chat.
  ///
  /// Robust against the finished agent loop: [_executeRun] drops its run
  /// object when the loop ends, so the pending request is re-derived from
  /// the persisted per-chat module scope when needed.
  /// Persists the submitted per-chat setup values and re-runs the gated
  /// module. With [awaitRun] (default) the returned future completes after
  /// the module run (and any queued-message release) finished — the
  /// original contract, used by tests. The SETUP SHEET passes
  /// `awaitRun: false`: the form closes as soon as the values are on
  /// disk and the module run + agent resume continue in the background
  /// (v1.34.0 — submitting used to freeze the sheet for the whole
  /// WebView boot + run).
  Future<bool> submitModuleSetup(
    String moduleName,
    Map<String, dynamic> values, {
    bool awaitRun = true,
  }) async {
    final String trimmed = moduleName.trim();
    final String? sessionId = _activeSessionId;
    if (trimmed.isEmpty || sessionId == null) return false;
    _SessionRun? run = _runs[sessionId];
    if (run == null) {
      run = await _materializeSession(sessionId);
      if (run == null) return false;
      _runs[sessionId] = run;
    }
    ModuleSetupRequest? pending = run.setupRequest;
    if (pending == null || pending.moduleName != trimmed) {
      // The finished loop dropped the run object (or a different module
      // is pending): re-derive the request from the persisted scope.
      if (!run.activeModules.contains(trimmed)) return false;
      pending = await _findSetupRequest(sessionId, <String>[trimmed]);
      if (pending == null || pending.moduleName != trimmed) return false;
      run.setupRequest = pending;
      if (_activeSessionId == sessionId) {
        state = state.copyWith(setupRequest: pending);
      }
    }
    if (!pending.setup.satisfiedBy(values)) return false;
    try {
      await ref
          .read(moduleRuntimeProvider)
          .writeStoredSetup(sessionId, trimmed, values);
    } catch (_) {
      // Persistence failure: keep the request open so the user can retry.
      return false;
    }
    run.setupRequest = null;
    if (_activeSessionId == sessionId) {
      state = state.copyWith(setupRequest: null);
    }
    await _persist(run);
    final bool queued = run.waitingForSetup;
    // v1.34.0: the sheet pops as soon as the values are persisted — the
    // module run + agent resume (WebView boot, module cycle, streaming)
    // continue in the background instead of freezing the form.
    if (!awaitRun) {
      unawaited(_finishSetupSubmission(run, trimmed, queued));
      return true;
    }
    await _finishSetupSubmission(run, trimmed, queued);
    return true;
  }

  /// Shared tail of [submitModuleSetup]: re-run the gated activation —
  /// the gate now passes and the module executes with the freshly
  /// submitted values — and, when a send() was queued behind this form,
  /// release that message to the agent.
  Future<void> _finishSetupSubmission(
    _SessionRun run,
    String trimmed,
    bool queued,
  ) async {
    if (!_alive) return; // v1.38.1: container gone — degrade to a no-op.
    await _activateModule(
      run,
      trimmed,
      activationPrompt: queued ? _lastUserText(run) : null,
    );
    if (!queued) return;
    // v1.29.0: a send() that hit the setup gate waits here. After the
    // form is submitted, the queued user message finally reaches the
    // agent — unless ANOTHER active module still blocks on its own form.
    final ModuleSetupRequest? nextGate = await _findSetupRequest(
      run.sessionId,
      run.activeModules,
    );
    if (nextGate != null) {
      run.setupRequest = nextGate;
      if (_activeSessionId == run.sessionId) {
        state = state.copyWith(setupRequest: nextGate);
      }
      await _persist(run);
      return;
    }
    run.waitingForSetup = false;
    await _persist(run);
    await _resumeQueuedRun(run);
  }

  /// Content of the LAST user message in the run (null when none) — used
  /// as the module activation prompt when a queued message is released.
  String? _lastUserText(_SessionRun run) {
    for (var i = run.messages.length - 1; i >= 0; i--) {
      if (run.messages[i].role == Role.user) return run.messages[i].content;
    }
    return null;
  }

  /// True when [moduleName]'s manifest declares the "/keyword" typed in
  /// [prompt] (v1.31.0 module command passthrough).
  Future<bool> _declaresCommand(String moduleName, String? prompt) async {
    final String? keyword = moduleCommandKeyword(prompt);
    if (keyword == null) return false;
    final ChatModule? module = await ref
        .read(moduleRegistryProvider)
        .get(moduleName);
    return module?.manifest.declaresCommand(keyword) ?? false;
  }

  /// Resolves the target module for a typed "/cmd …" message (v1.31.0):
  /// the FIRST ACTIVE module whose manifest declares the keyword wins;
  /// otherwise — when nothing is staged — the first INSTALLED module
  /// declaring it (typing the command IS the activation intent). Null
  /// when no module claims the keyword: the message flows to the LLM.
  Future<String?> _moduleCommandTarget(_SessionRun run, String prompt) async {
    final String? keyword = moduleCommandKeyword(prompt);
    if (keyword == null) return null;
    final ModuleRegistry registry = ref.read(moduleRegistryProvider);
    for (final String name in run.activeModules) {
      final ChatModule? module = await registry.get(name);
      if (module?.manifest.declaresCommand(keyword) ?? false) return name;
    }
    if (run.pendingModule != null) return null;
    try {
      final List<ChatModule> installed = await registry.listInstalled();
      for (final ChatModule module in installed) {
        if (module.manifest.declaresCommand(keyword)) return module.name;
      }
    } catch (_) {
      // Registry read failure must never break the send path.
    }
    return null;
  }

  /// Resumes the queued agent cycle (v1.29.0) once the blocking setup
  /// form was submitted or the gating module deactivated: replay-only —
  /// the queued user message(s) are already in the transcript, the wire
  /// rebuilds from run.messages and the agent finally answers.
  Future<void> _resumeQueuedRun(_SessionRun run) async {
    if (run.isRunning || !_alive) return; // v1.38.1: alive guard.
    if (_activeSessionId == run.sessionId) {
      state = state.copyWith(
        sessionId: run.sessionId,
        title: run.title,
        messages: [...run.messages],
        isRunning: true,
        error: null,
        waitingForSetup: false,
      );
    }
    await _executeRun(run, ref.read(settingsProvider));
  }

  /// Form values for a [ModuleSetupRequest]: STRICTLY the current chat's
  /// own stored values. The v1.33-v1.41 cross-chat prefill scan was
  /// removed in v1.41.6 — the user explicitly wants per-chat isolation
  /// for the setup form: chat B's form must never show values typed in
  /// chat A. Each chat keeps its own persistence via readStoredSetup and
  /// still needs an explicit Save & run.
  Future<Map<String, dynamic>> _setupFormValues(
    String sessionId,
    ChatModule module,
    Map<String, dynamic> current,
  ) async => current;

  /// Finds the first active module whose required per-chat setup is not
  /// satisfied yet (null when every active module is ready to run).
  Future<ModuleSetupRequest?> _findSetupRequest(
    String sessionId,
    List<String> moduleNames,
  ) async {
    for (final String name in moduleNames) {
      final ChatModule? module = await ref
          .read(moduleRegistryProvider)
          .get(name);
      final ModuleSetup? setup = module?.manifest.setup;
      if (module == null || setup == null || !setup.hasRequired) continue;
      Map<String, dynamic> values = const <String, dynamic>{};
      try {
        values = await ref
            .read(moduleRuntimeProvider)
            .readStoredSetup(sessionId, module.name);
      } catch (_) {
        // Unreadable storage simply counts as "not set up yet".
      }
      if (setup.satisfiedBy(values)) continue;
      return ModuleSetupRequest(
        moduleName: module.name,
        moduleTitle: module.manifest.title.isEmpty
            ? module.name
            : module.manifest.title,
        setup: setup,
        values: await _setupFormValues(sessionId, module, values),
      );
    }
    return null;
  }

  /// Installs the staged repaired module (user tapped Install on the
  /// confirmation card). The zip goes through the FULL [installFromZip]
  /// pipeline again (zip-slip, size caps, atomic replace) — staging only
  /// ever validated it. Posts a module message with the outcome, clears
  /// the card and refreshes the module lists. Returns true on success.
  Future<bool> installStagedModule() async {
    // The chat that staged the card owns the outcome: capture it BEFORE
    // the install await, otherwise a switch during the (potentially slow)
    // unzip would post the result into whichever chat is on screen.
    final String? sessionId = _activeSessionId;
    final ModuleInstallRequest? pending = _pendingInstallForActiveSession();
    if (pending == null) return false;
    final AppStrings strings = appStringsFor(
      ref.read(settingsProvider).languageCode,
    );
    _clearPendingInstall();
    final ModuleInstallResult result = await ref
        .read(moduleRegistryProvider)
        .installFromZip(pending.zipPath);
    ref.invalidate(moduleListProvider);
    final _SessionRun? run = sessionId == null ? null : _runs[sessionId];
    final String installedText = result.ok
        ? (pending.isNew
              ? strings.moduleBuildInstalled(pending.moduleName)
              : strings.moduleRepairInstalled(pending.moduleName))
        : strings.moduleRepairInstallFailed(result.message);
    if (run != null) {
      run.messages.add(
        ChatMessage.assistant(
          installedText,
          moduleName: result.ok ? pending.moduleName : null,
        ),
      );
      _sync(run);
      await _persist(run);
    } else if (sessionId != null && _activeSessionId == sessionId) {
      state = state.copyWith(
        messages: [
          ...state.messages,
          ChatMessage.assistant(
            installedText,
            moduleName: result.ok ? pending.moduleName : null,
          ),
        ],
      );
    }
    return result.ok;
  }

  /// Discards the staged repair card (user tapped Discard). The zip file
  /// stays in the chat workspace — the agent may iterate on it.
  void discardStagedModule() {
    _clearPendingInstall();
  }

  /// Test hook: stages a repair card without running the agent loop.
  @visibleForTesting
  void debugStageRepairForTest(ModuleInstallRequest request) {
    state = state.copyWith(pendingModuleInstall: request);
  }

  ModuleInstallRequest? _pendingInstallForActiveSession() {
    final String? sessionId = _activeSessionId;
    if (sessionId == null) return state.pendingModuleInstall;
    return _runs[sessionId]?.pendingInstall ?? state.pendingModuleInstall;
  }

  void _clearPendingInstall() {
    final String? sessionId = _activeSessionId;
    final _SessionRun? run = sessionId == null ? null : _runs[sessionId];
    if (run != null) run.pendingInstall = null;
    state = state.copyWith(pendingModuleInstall: null);
  }

  /// Rewrites a previously sent user message and REGENERATES everything
  /// after it: the message content is replaced (attachments kept) and
  /// every later message is dropped, then the agent loop replays the
  /// truncated history. Works on live sessions and on sessions freshly
  /// opened from history. Returns false when the request is invalid
  /// (unknown session, still running, no user message at that index).
  Future<bool> editUserMessage(
    String sessionId,
    int messageIndex,
    String newText,
  ) async {
    final String trimmed = newText.trim();
    if (trimmed.isEmpty) return false;
    _SessionRun? run = _runs[sessionId];
    if (run == null) {
      if (_activeSessionId != sessionId) return false;
      run = await _materializeSession(sessionId);
      if (run == null) return false;
      _runs[sessionId] = run;
    }
    if (run.isRunning || (_activeSessionId == sessionId && state.isRunning)) {
      return false;
    }
    // v1.29.0: a queued message waits for its module's setup input —
    // editing/regenerating must not start the agent without that input.
    if (run.waitingForSetup) return false;
    if (messageIndex < 0 || messageIndex >= run.messages.length) {
      return false;
    }
    final ChatMessage target = run.messages[messageIndex];
    if (target.role != Role.user) return false;
    if (!_passesConnectionChecks()) return false;

    // Replace the content, keep the attachments, drop everything after.
    run.messages[messageIndex] = ChatMessage(
      id: target.id,
      role: Role.user,
      content: trimmed,
      createdAt: target.createdAt,
      attachments: target.attachments,
    );
    if (messageIndex < run.messages.length - 1) {
      run.messages.removeRange(messageIndex + 1, run.messages.length);
    }
    run.latestTodos = const <TodoItem>[];
    _showRunningTranscript(run);
    await _executeRun(run, ref.read(settingsProvider));
    return true;
  }

  /// Regenerates the answer to the LAST user message: trailing assistant
  /// messages are dropped (the user message is kept) and the agent loop
  /// replays the history from there. Returns false when the request is
  /// invalid (unknown session, still running, no user message).
  Future<bool> regenerate(String sessionId) async {
    _SessionRun? run = _runs[sessionId];
    if (run == null) {
      if (_activeSessionId != sessionId) return false;
      run = await _materializeSession(sessionId);
      if (run == null) return false;
      _runs[sessionId] = run;
    }
    if (run.isRunning || (_activeSessionId == sessionId && state.isRunning)) {
      return false;
    }
    // v1.29.0: a queued message waits for its module's setup input —
    // regenerating must not start the agent without that input.
    if (run.waitingForSetup) return false;
    int lastUser = -1;
    for (var i = run.messages.length - 1; i >= 0; i--) {
      if (run.messages[i].role == Role.user) {
        lastUser = i;
        break;
      }
    }
    if (lastUser < 0) return false;
    if (!_passesConnectionChecks()) return false;

    if (lastUser < run.messages.length - 1) {
      run.messages.removeRange(lastUser + 1, run.messages.length);
    }
    run.latestTodos = const <TodoItem>[];
    _showRunningTranscript(run);
    await _executeRun(run, ref.read(settingsProvider));
    return true;
  }

  /// API key/model validation shared by send/edit/regenerate. Surfaces a
  /// localized error on the chat state when something is missing.
  bool _passesConnectionChecks() {
    final settings = ref.read(settingsProvider);
    final AppStrings strings = appStringsFor(settings.languageCode);
    if (settings.apiKey.trim().isEmpty) {
      state = state.copyWith(error: strings.missingApiKey);
      return false;
    }
    if (settings.model.trim().isEmpty) {
      state = state.copyWith(error: strings.modelNotSet);
      return false;
    }
    return true;
  }

  /// Puts an (edited) transcript on screen and flips the session into the
  /// running state — the same visual contract a normal send has.
  void _showRunningTranscript(_SessionRun run) {
    if (_activeSessionId != run.sessionId) return;
    state = state.copyWith(
      sessionId: run.sessionId,
      title: run.title,
      messages: [...run.messages],
      isRunning: true,
      error: null,
      // Edit/regenerate truncate the transcript and drop the old plan: the
      // panel must show the plan of THIS attempt, not the abandoned one.
      todos: run.latestTodos,
      setupRequest: run.setupRequest,
      waitingForSetup: run.waitingForSetup,
    );
  }

  /// Shared run scaffolding for send / edit / regenerate: background hold,
  /// the agent loop itself, final state + persistence, auto-title.
  /// [prompt] null = replay-only (edit/regenerate); a non-null prompt is
  /// appended as a new user message first.
  Future<void> _executeRun(
    _SessionRun run,
    AppSettings settings, {
    String? prompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) async {
    // v1.38.1: a run scheduled right before teardown/app shutdown stops
    // here instead of throwing on the first ref read.
    if (!_alive) {
      run.isRunning = false;
      return;
    }
    run.isRunning = true;
    run.finalizing = false;
    // A fresh release signal per invocation: a waiter parked on the previous
    // run must never be woken by this one (and vice versa).
    if (run.finalized.isCompleted) run.finalized = Completer<void>();
    final int token = ++run.runToken;
    _markRunning();
    _RunResult? result;
    // v1.39.0: the release of a run (flag reset, `_runs` eviction, running
    // badge, waiter wake-up) lives in a `finally`, so an exception ANYWHERE
    // in the loop can no longer leave the session marked running forever
    // with its map entry behind — the failure used to freeze the chat.
    try {
      result = await _runSession(run, settings, prompt, attachments);
    } catch (e) {
      // Never let a throw escape as an unhandled error, and never leave the
      // composer showing Stop for a loop that no longer exists.
      result = _RunResult(error: '$e');
    } finally {
      // Token-checked: a newer run for the same chat (started while this one
      // was finalizing) must never be reset or evicted by its predecessor.
      if (run.runToken == token) {
        run.isRunning = false;
        run.finalizing = false;
        if (!run.finalized.isCompleted) run.finalized.complete();
        if (identical(_runs[run.sessionId], run)) {
          _runs.remove(run.sessionId);
        }
        _lastStreamSync.remove(run.sessionId);
        _markRunning();
        if (_activeSessionId == run.sessionId && state.isRunning) {
          state = state.copyWith(isRunning: false, error: result?.error);
        }
      }
    }
    final _RunResult outcome = result;
    if (run.runToken == token) {
      // Auto-title and the completion notification are slow, best-effort
      // extras. They run AFTER the session is released so the next message in
      // this chat never stalls on a title LLM call.
      if (outcome.error == null && !run.stopRequested) {
        await _maybeAutoTitle(run, settings);
      }
      await _maybeNotifyDone(run, settings, outcome.error);
    }
    ref.invalidate(chatListProvider);
  }

  /// The body of one run: setup → agent loop → auto-retry → final persist.
  /// Always called through [_executeRun], which owns the lifecycle flags and
  /// the post-run extras (auto-title, notification).
  Future<_RunResult> _runSession(
    _SessionRun run,
    AppSettings settings,
    String? prompt,
    List<ChatAttachment> attachments,
  ) async {
    // Preload attachment contents (text bodies + image data URLs) and the
    // documents root (for relative path hints on binary attachments).
    run.docsPath ??= (await ref.read(documentsDirProvider)()).path;
    await _prepareAttachments(run, attachments);

    _RunResult result = await _runLoop(run, settings, prompt, attachments);

    // v1.30.0 auto-retry at RUN level: when the run died from a retryable
    // failure (network error, weak connection, dropped stream, transient
    // provider 429/5xx) or ended mid-way with an unfinished todo plan, the
    // task is RESUMED from the persisted transcript instead of staying
    // stalled. Each resume adds a visible note to the chat and waits
    // (delay x attempt) before picking the work back up. Stop always wins:
    // nothing resumes after the user pressed Stop.
    final int maxResumes = settings.autoRetryEnabled
        ? settings.autoRetryAttempts
        : 0;
    final AppStrings strings = appStringsFor(settings.languageCode);
    for (
      int attempt = 1;
      !run.stopRequested && attempt <= maxResumes;
      attempt++
    ) {
      final bool retryableFailure =
          result.error != null && isRetryableLlmError(result.cause);
      final bool planStalled =
          result.error == null && _planInterrupted(run, settings);
      if (!retryableFailure && !planStalled) break;
      // v1.32.0 — airplane-aware hold at run level: a retryable network
      // failure while airplane mode is ON is the expected manual-airplane
      // window. Hold (with a visible note) WITHOUT consuming a resume
      // until the radio comes back; Stop still wins. An unanswerable
      // probe keeps the plain v1.30.0 accounting.
      if (retryableFailure && await _airplaneModeOn()) {
        _finalizeDanglingStream(run);
        run.messages.add(
          ChatMessage.assistant(strings.autoRetryAirplaneResumeNote),
        );
        _sync(run);
        await _persist(run);
        if (!await _airplaneWait(run)) {
          // Stop pressed while holding: a user-stopped run must not
          // present the transport error as if something went wrong.
          result = const _RunResult();
          break;
        }
      }
      _finalizeDanglingStream(run);
      run.messages.add(
        ChatMessage.assistant(
          retryableFailure
              ? strings.autoRetryResumeNote(attempt, maxResumes)
              : strings.autoRetryPlanNote(attempt, maxResumes),
        ),
      );
      _sync(run);
      await _persist(run);
      if (!await _retryWait(run, settings.autoRetryDelay * attempt)) {
        // Stop wins: a user-stopped run must not present the transport
        // error as if something had gone wrong.
        if (result.error != null) {
          result = const _RunResult();
        }
        break;
      }
      result = await _runLoop(run, settings, null, const <ChatAttachment>[]);
    }

    // A failed turn can leave a streaming placeholder behind; mark it
    // finished so the transcript never shows an eternal thinking bubble.
    _finalizeDanglingStream(run);

    run.isRunning = false;
    // The loop is over but persistence is still in flight: a send arriving
    // now must wait for the release rather than start a second loop over
    // this same run object. Auto-title runs after the release (see
    // [_executeRun]) so it never stalls the next message.
    run.finalizing = true;
    _markRunning();
    if (!run.deleted) {
      if (_activeSessionId == run.sessionId) {
        state = state.copyWith(
          messages: [...run.messages],
          isRunning: false,
          error: result.error,
        );
      }
      await _persist(run);
    }
    return result;
  }

  /// Posts a local "task finished" notification when a run completes while
  /// the app is in the background (v1.18.0). Skipped when the user turned
  /// notifications off, when the app is on screen, or when the user/Stop
  /// ended the run — those already have their own feedback.
  Future<void> _maybeNotifyDone(
    _SessionRun run,
    AppSettings settings,
    String? error,
  ) async {
    try {
      if (!settings.notifyOnDone || run.stopRequested) return;
      if (ref.read(appInForegroundProvider)) return;
      final AppStrings strings = appStringsFor(settings.languageCode);
      await ref
          .read(backgroundRunServiceProvider)
          .notifyDone(
            title: strings.notifDoneTitle,
            text: strings.notifDoneBody(run.title, error),
            sessionId: run.deleted ? null : run.sessionId,
          );
    } catch (_) {
      // A failed notification must never disturb the finished run.
    }
  }

  static String _titleFor(String text) =>
      text.length > 48 ? '${text.substring(0, 48)}…' : text;

  /// Loads an existing (persisted) session into a runnable state so the
  /// next message CONTINUES it instead of forking a new chat. Falls back
  /// to an empty transcript when the stored file is unreadable — the
  /// conversation keeps its id and title either way.
  Future<_SessionRun> _adoptSession(String sessionId, String prompt) async {
    final _SessionRun run =
        await _materializeSession(sessionId) ??
        _SessionRun(sessionId: sessionId, title: '');
    // Only a session that still has no title (fresh, or its stored title is
    // empty) is titled from the prompt — exactly the automatic-title path, so
    // the model may rename it later. `run.title` comes from the SESSION's own
    // stored file, never from whatever chat happens to be on screen.
    if (run.title.trim().isEmpty) {
      run.title = _titleFor(prompt);
      run.autoTitlePending = true;
    }
    return run;
  }

  /// Builds a [_SessionRun] from the STORED history of [sessionId] so
  /// edit/regenerate work on freshly opened sessions too (and _adoptSession
  /// can share the logic). Returns null when the run could not be built —
  /// storage failures degrade to an empty transcript, never an exception.
  ///
  /// Concurrent callers for the same session share ONE load: two runs over
  /// the same chat would each own a separate message list and the second
  /// persist would silently drop the first one's messages.
  Future<_SessionRun?> _materializeSession(String sessionId) {
    final Future<_SessionRun?>? inFlight = _materializing[sessionId];
    if (inFlight != null) return inFlight;
    final Future<_SessionRun?> load = _materializeSessionNow(sessionId);
    _materializing[sessionId] = load;
    return load.whenComplete(() => _materializing.remove(sessionId));
  }

  /// Stored title of [sessionId], or '' when the file is missing/unreadable.
  Future<String> _storedTitle(String sessionId) async {
    try {
      return await ref.read(chatStoreProvider).loadTitle(sessionId);
    } catch (_) {
      return '';
    }
  }

  Future<_SessionRun?> _materializeSessionNow(String sessionId) async {
    // Materialized history is NOT running — edit/regenerate check this
    // flag before reshaping the transcript.
    // The title comes from THIS session: `state.title` is only used when it
    // is the chat on screen, otherwise the stored title is read. Taking the
    // on-screen title used to give a background session another chat's name
    // (and then persist it over the real one).
    final String title = _activeSessionId == sessionId && state.title.isNotEmpty
        ? state.title
        : await _storedTitle(sessionId);
    final _SessionRun run = _SessionRun(
      sessionId: sessionId,
      title: title,
      running: false,
    );
    try {
      // v1.38.1: ONE read/decode for the whole stored state (messages,
      // modules, wait flag, plan) instead of four.
      final SessionBundle? bundle = await ref
          .read(chatStoreProvider)
          .loadBundle(sessionId);
      if (bundle != null) {
        run.activeModules.addAll(bundle.modules);
        run.activeSkills.addAll(bundle.skills);
        if (bundle.messages.isNotEmpty) {
          run.messages.addAll(bundle.messages);
          // Re-read attachment payloads so replayed attachments reach the
          // model again (images need their data URLs, text files their
          // bodies). Missing files are skipped by [_prepareAttachments].
          final List<ChatAttachment> atts = <ChatAttachment>[
            for (final ChatMessage m in bundle.messages) ...m.attachments,
          ];
          await _prepareAttachments(run, atts);
        }
        // v1.35.0 crash recovery: the persisted plan feeds run.latestTodos
        // so continuing a crash-interrupted session keeps the plan panel
        // alive — and the plan-first nudge / resume logic can pick the
        // task back up. edit/regenerate still clear it explicitly (a
        // rewritten transcript invalidates the old plan).
        run.latestTodos = bundle.todos;
      }
    } catch (_) {
      // Storage failure: continue with whatever is on screen (possibly
      // empty) rather than blocking the user's request.
    }
    return run;
  }

  /// Reads picked files into the run's caches so wire building never
  /// touches the filesystem again. Failures degrade to a note in text.
  Future<void> _prepareAttachments(
    _SessionRun run,
    List<ChatAttachment> attachments,
  ) async {
    for (final ChatAttachment att in attachments) {
      if (att.path.isEmpty ||
          run.dataUrlCache.containsKey(att.path) ||
          run.textCache.containsKey(att.path)) {
        continue;
      }
      try {
        final File file = File(att.path);
        if (!await file.exists()) continue;
        switch (att.kind) {
          case AttachmentKind.image:
            final List<int> bytes = await file.readAsBytes();
            // Vision hardening (v1.16.0): cap the long edge and re-encode
            // so a full-resolution photo never becomes megabytes of base64
            // in the wire. Mime follows the OUTPUT format (a downscaled
            // JPEG may no longer match the original file extension).
            final DownscaledImage prepared = await downscaleForUpload(bytes);
            run.dataUrlCache[att.path] =
                'data:${prepared.mime};base64,${base64Encode(prepared.bytes)}';
          case AttachmentKind.text:
            final String content = await file.readAsString();
            run.textCache[att.path] = content.length > 20000
                ? '${content.substring(0, 20000)}\n…[truncated]'
                : content;
          case AttachmentKind.other:
            // Binary: only the metadata travels in the prompt.
            break;
        }
      } catch (_) {
        // Unreadable attachment: skip silently, message text still sends.
      }
    }
  }

  /// Composes the effective user text: prompt + text-attachment blocks.
  /// A `/make_plugins` command is expanded into the builder specification
  /// for the WIRE only — the transcript keeps the raw command. The
  /// expansion is deterministic, so history replay reproduces it exactly.
  String _composeUserText(
    String prompt,
    List<ChatAttachment> attachments,
    _SessionRun run,
  ) {
    final StringBuffer buffer = StringBuffer(expandMakePluginsPrompt(prompt));
    for (final ChatAttachment att in attachments) {
      switch (att.kind) {
        case AttachmentKind.text:
          final String? content = run.textCache[att.path];
          if (content != null) {
            buffer
              ..writeln()
              ..writeln()
              ..writeln('[Attached file: ${att.name}]');
            buffer
              ..writeln('```')
              ..writeln(content)
              ..write('```');
          }
        case AttachmentKind.image:
          // Images travel as separate content parts, not inline text.
          break;
        case AttachmentKind.other:
          // Binary: metadata + the documents-relative path so the agent can
          // act on the file (unzip_file, node_run, zip_file ...).
          final String relative = _relativeToDocs(att.path, run);
          final bool isZip = att.name.toLowerCase().endsWith('.zip');
          buffer
            ..writeln()
            ..writeln(
              '[Attached file: ${att.name} (${att.sizeBytes} bytes, binary — '
              'no preview available)]',
            );
          if (relative.isNotEmpty) {
            buffer.writeln(
              isZip
                  ? 'The archive is saved at "$relative". Use unzip_file '
                        'with this path to extract it, then read_file or '
                        'node_run (require relative paths like '
                        '"./$relative/...") to work with the files inside.'
                  : 'The file is saved at "$relative". It can be processed '
                        'with node_run or re-archived with zip_file.',
            );
          }
      }
    }
    return buffer.toString();
  }

  /// Documents-relative form of [absolutePath] (forward slashes), or ''
  /// when the path is unknown/outside the documents root.
  String _relativeToDocs(String absolutePath, _SessionRun run) {
    final String? docsPath = run.docsPath;
    if (docsPath == null || docsPath.isEmpty) return '';
    String normalized = absolutePath.replaceAll('\\', '/');
    String root = docsPath.replaceAll('\\', '/');
    if (!root.endsWith('/')) root = '$root/';
    if (!normalized.startsWith(root)) return '';
    return normalized.substring(root.length);
  }

  Future<_RunResult> _runLoop(
    _SessionRun run,
    AppSettings settings,
    String? prompt,
    List<ChatAttachment> attachments,
  ) async {
    final AppStrings strings = appStringsFor(settings.languageCode);
    // A null prompt means REPLAY: edit/regenerate already reshaped the
    // transcript, so no new user message is appended — the wire rebuilds
    // from run.messages below and truncation "just works".
    if (prompt != null) {
      run.messages.add(ChatMessage.user(prompt, attachments: attachments));
      _sync(run);
      // Persist the session the moment the first user message lands
      // (v1.28.0): previously a session only appeared in the drawer list
      // after its whole run finished, so a new chat started while another
      // session was running was invisible (and could be lost to a crash).
      // Persisting now makes it show up immediately with its running
      // badge. Fire-and-forget: the run must never BLOCK on disk I/O
      // here (real-device save latency would stall the loop's start;
      // ordering is guaranteed by the per-run persist chain).
      unawaited(_persist(run));
    }

    // Staged module (new chat with a module) activates AFTER the user
    // message so its entry output lands between the prompt and the reply.
    // The prompt itself is forwarded so the module can implement setup
    // commands on the first message (e.g. credentials, options).
    final String? stagedModule = run.pendingModule;
    if (stagedModule != null) {
      run.pendingModule = null;
      await _activateModule(run, stagedModule, activationPrompt: prompt);
      if (run.setupRequest != null) {
        // v1.29.0: the gate fired during activation (values wiped since
        // the send() check, manifest changed mid-flight) — the queued
        // user message must not be answered without the module's input.
        // Stop BEFORE the first LLM call; submitModuleSetup resumes the
        // cycle once the form is in.
        run.waitingForSetup = true;
        if (_activeSessionId == run.sessionId) {
          state = state.copyWith(waitingForSetup: true);
        }
        await _persist(run);
        return const _RunResult();
      }
      // v1.31.0 — a staged module that DECLARES the typed "/cmd" keyword
      // already ran with the raw message as zagents.info.prompt: the
      // command is consumed, the LLM stays out of a pure command chat.
      if (await _declaresCommand(stagedModule, prompt)) {
        run.autoTitlePending = false;
        return const _RunResult();
      }
    }

    // v1.31.0 — module command passthrough: a message like "/airplane on"
    // whose keyword is declared by an ACTIVE module's manifest routes to
    // that module (its entry point re-runs with the raw message as
    // zagents.info.prompt) instead of reaching the LLM. When no module
    // claims the keyword there, an INSTALLED module declaring it is
    // auto-activated first — typing the command IS the activation intent.
    if (prompt != null) {
      final String? commandTarget = await _moduleCommandTarget(run, prompt);
      if (commandTarget != null) {
        // The title of a command-only chat is the command itself — no
        // point burning an LLM call to retitle "/airplane on".
        run.autoTitlePending = false;
        await _activateModule(run, commandTarget, activationPrompt: prompt);
        if (run.setupRequest != null) {
          // The activated module wants its per-chat setup first: surface
          // the form; submitModuleSetup re-runs the module with the
          // queued command text as its activation prompt.
          run.waitingForSetup = true;
          if (_activeSessionId == run.sessionId) {
            state = state.copyWith(waitingForSetup: true);
          }
          await _persist(run);
        }
        return const _RunResult();
      }
    }

    final wire = <Map<String, dynamic>>[
      await _systemWire(settings, run),
      // Full replay: previous turns (assistant + tool results + user msgs,
      // attachments included) followed by the freshly added user message.
      ..._buildWire(run, run.messages),
    ];

    final config = LlmConfig(
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      model: settings.model,
      engine: settings.engine,
    );
    final tools = settings.agentMode
        ? buildAgentTools(planFirst: settings.planFirst)
        : null;

    final BackgroundRun background = ref.read(backgroundRunServiceProvider);
    final bool holdStarted = settings.runInBackground;
    if (holdStarted) {
      await background.start(
        title: strings.notifTitle,
        text: strings.notifProcessing,
      );
      // v1.42.0: one notification PER ACTIVE CHAT, on top of the aggregate
      // service notification — title + live step + tap-to-open-THIS-chat
      // (the tap extra rides the existing pending-session deep link).
      await background.startSession(
        sessionId: run.sessionId,
        title: run.title.isEmpty ? strings.notifTitle : run.title,
        text: strings.notifProcessing,
      );
    }

    try {
      // "Run until done" removes the max-steps cap: the loop only ends
      // when the model stops requesting tools or the user presses Stop.
      // [unboundedStepLimit] remains as a runaway guard.
      final int stepLimit = settings.runUntilDone
          ? unboundedStepLimit
          : settings.maxSteps;

      // Latest plan state written via todo_write in THIS run (tracked on
      // the run itself so the UI can mirror it). A plan from an earlier
      // turn stays in the replayed history; a new user command is expected
      // to re-plan, so the nudge only tracks the current run.
      int planNudges = 0;

      // v1.48.1 plan-sync: consecutive tool batches that did work without
      // any todo_write, and how many wire-only reminders this run already
      // spent (capped by [maxPlanNudges] like the end-of-turn nudge).
      int stepsSinceTodoWrite = 0;
      int todoReminders = 0;

      for (var step = 0; step < stepLimit; step++) {
        // Stop pressed before this turn even starts — leave immediately.
        if (run.stopRequested) break;

        // 1. Stream one assistant turn.
        final buffer = StringBuffer();
        run.streamingBuffer = buffer;
        run.messages.add(ChatMessage.assistant('', isStreaming: true));
        _sync(run);

        final AssistantTurn turn;
        try {
          turn = await _completeWithRetry(
            run,
            settings,
            config: config,
            wire: wire,
            tools: tools,
            buffer: buffer,
          );
        } on LlmAbortedException {
          // Keep the partial answer on screen; the finalize step below
          // marks it as stopped. No wire entry is added, so the next
          // message continues from a clean history.
          break;
        } finally {
          run.streamingBuffer = null;
        }
        if (run.stopRequested) break;

        final toolCalls = <ToolCall>[
          for (final tc in turn.toolCalls)
            ToolCall(id: tc.id, name: tc.name, arguments: tc.args),
        ];
        run.messages[run.messages.length - 1] = _preserveLastId(
          run,
          ChatMessage.assistant(
            turn.content,
            toolCalls: toolCalls,
            model: settings.model,
            usage: turn.usage,
          ),
        );
        _sync(run);

        if (toolCalls.isEmpty) {
          // The model produced a final answer. An incomplete todo plan
          // means the task is NOT done: nudge the model to keep working
          // (z.ai agent mode behavior) instead of accepting a premature
          // summary. v1.48.1: the nudge no longer requires plan-first —
          // a model that planned on its own (planFirst off) must still
          // finish its plan when run-until-done is on.
          if (settings.agentMode &&
              (settings.runUntilDone || settings.planFirst) &&
              !run.stopRequested &&
              hasIncompleteTodos(run.latestTodos) &&
              planNudges < maxPlanNudges) {
            planNudges++;
            wire.add(<String, dynamic>{
              'role': 'user',
              'content': planNudgeText(run.latestTodos),
            });
            continue;
          }
          break; // Final answer reached.
        }

        // 2. Execute each requested tool and feed results back.
        wire.add(<String, dynamic>{
          'role': 'assistant',
          if (turn.content.isNotEmpty) 'content': turn.content,
          'tool_calls': <Map<String, dynamic>>[
            for (final tc in turn.toolCalls)
              <String, dynamic>{
                'id': tc.id,
                'type': 'function',
                'function': <String, dynamic>{
                  'name': tc.name,
                  'arguments': tc.argumentsJson,
                },
              },
          ],
        });

        final executor = ref.read(toolExecutorProvider);
        // v1.48.1 plan-sync: did THIS batch sync the plan? Decided per call
        // below and consumed at the batch tail.
        bool batchIncludedTodoWrite = false;
        for (final call in toolCalls) {
          if (run.stopRequested) break;
          call.status = ToolStatus.running;
          _sync(run);
          // Live progress in the foreground-service notification.
          await background.updateStatus(strings.notifStep(step + 1, call.name));
          // v1.42.0: the per-chat notification mirrors the same step.
          await background.updateSessionStatus(
            sessionId: run.sessionId,
            text: strings.notifStep(step + 1, call.name),
          );

          // One place that hands a call to the executor, so every approval
          // branch below runs the tool the same way (and Stop still reaches
          // LONG-RUNNING tools through `shouldAbort`).
          Future<ToolResult> runTool() async {
            // v1.41.0: Stop can land WHILE an approval dialog is open —
            // between the user's "approve" and this line. The action must
            // then NOT run: a stopped chat that still sends a transaction
            // is the worst possible race. `shouldAbort` only covers tools
            // that are already running.
            if (run.stopRequested) {
              return ToolResult(
                ok: false,
                llmOutput:
                    'Stopped by the user before this action ran — it was '
                    'NOT performed.',
                displayText: 'stopped',
              );
            }
            return executor.execute(
              call.name,
              call.arguments,
              sessionId: run.sessionId,
              shouldAbort: () => run.stopRequested,
            );
          }

          final ToolResult result;
          if (call.name == 'request_confirmation') {
            // v1.38.0: the loop BLOCKS here until the user approves or
            // denies in the confirmation dialog (or a 10-minute timeout
            // counts as a denial). Never delegated to the executor — the
            // user decision is the authorization boundary for
            // money-moving actions.
            result = await _requestConfirmation(run, call);
          } else if (call.name == 'skill_install') {
            // v1.40.0: installing a skill downloads THIRD-PARTY CODE that
            // then runs with network/file access on this device. The agent
            // must never do that silently: the user approves the source
            // first (the install itself is not otherwise reversible from
            // the chat).
            final bool approved = await _askApproval(
              run,
              id: 'install:${call.id}',
              title: strings.skillInstallConfirmTitle,
              details: <String>[
                strings.skillInstallConfirmSource(
                  call.arguments['source']?.toString() ?? '',
                ),
                strings.skillInstallConfirmBody,
              ],
            );
            result = approved
                ? await runTool()
                : ToolResult(
                    ok: false,
                    llmOutput: strings.skillInstallDeclined,
                    displayText: 'install declined',
                  );
          } else if (call.name == 'skill_run' &&
              await _isWalletSkill(call.arguments['name']?.toString())) {
            // v1.41.0: a `wallet: true` skill moves value on-chain. A
            // `request_confirmation` call earlier in the turn is only
            // advisory — the model can skip it — so the enforced gate
            // lives HERE: every run of a value-moving skill needs its own
            // explicit approval, and a denial is reported as a failed
            // call (never a silent success).
            final String skillName = call.arguments['name']?.toString() ?? '';
            final bool approved = await _askApproval(
              run,
              id: 'wallet:${call.id}',
              title: strings.skillWalletConfirmTitle,
              details: <String>[
                strings.skillWalletConfirmAction(
                  skillName,
                  call.arguments['script']?.toString() ?? '',
                ),
                strings.skillWalletConfirmBody,
              ],
            );
            result = approved
                ? await runTool()
                : ToolResult(
                    ok: false,
                    llmOutput: strings.skillWalletDeclined,
                    displayText: 'wallet action denied',
                  );
          } else {
            result = await runTool();
          }
          call.status = result.ok ? ToolStatus.success : ToolStatus.error;
          call.resultText = result.llmOutput;
          call.screenshotPath = result.screenshotPath;
          if (call.name == 'todo_write') {
            batchIncludedTodoWrite = true;
            // v1.48.1: only a SUCCESSFUL, non-empty todo_write may move the
            // plan. A failed/empty call (malformed JSON args degrade to {},
            // an empty array is rejected by the executor) must never wipe
            // the live plan — UI, nudge loop and disk all read latestTodos.
            final List<TodoItem> parsedTodos = parseTodoList(
              call.arguments['todos'],
            );
            if (result.ok && parsedTodos.isNotEmpty) {
              run.latestTodos = parsedTodos;
            }
          }
          // Module doctor / builder: a validated module zip becomes a
          // pending install card. The tool only validated; the USER
          // decides. isNew distinguishes a freshly built plugin (no
          // module with that name installed) from a repair.
          if (call.name == 'module_stage_repair' &&
              result.ok &&
              result.data != null) {
            final String stagedName = result.data!['name']?.toString() ?? '';
            bool isNew = false;
            try {
              final ModuleRegistry registry = ref.read(moduleRegistryProvider);
              await registry.ensureCacheLoaded();
              isNew = registry.getSync(stagedName) == null;
            } catch (_) {
              // Registry hiccup: keep the (repair) default wording.
            }
            run.pendingInstall = ModuleInstallRequest(
              zipPath: result.data!['zipPath']?.toString() ?? '',
              moduleName: stagedName,
              version: result.data!['version']?.toString() ?? '',
              title:
                  result.data!['title']?.toString() ??
                  result.data!['name']?.toString() ??
                  '',
              permissions: <String>[
                ...((result.data!['permissions'] as List<dynamic>?) ??
                        const <dynamic>[])
                    .map((Object? p) => p.toString()),
              ],
              isNew: isNew,
            );
            if (_activeSessionId == run.sessionId) {
              state = state.copyWith(pendingModuleInstall: run.pendingInstall);
            }
          }
          _sync(run);

          wire.add(<String, dynamic>{
            'role': 'tool',
            'tool_call_id': call.id,
            'content': result.llmOutput,
          });
        }
        // v1.35.0 crash recovery: persist after every step's tool batch —
        // previously the transcript was only written at run START, so a
        // mid-run crash (OOM kill, ANR, dead battery) wiped everything
        // after the opening user message, plan cards included. The save is
        // fire-and-forget: the per-run persist chain guarantees ordering
        // and the loop never blocks on disk I/O.
        //
        // v1.48.1 plan-sync: a batch that did real work WITHOUT a
        // todo_write lengthens the drift streak; any todo_write resets it.
        // After two unsynced batches, remind the model ON THE WIRE ONLY
        // (same mechanics as planNudgeText — never a visible message) to
        // write the full updated plan, so the user's plan panel stays
        // current after every completed step.
        if (batchIncludedTodoWrite) {
          stepsSinceTodoWrite = 0;
        } else {
          stepsSinceTodoWrite++;
        }
        if (stepsSinceTodoWrite >= 2 &&
            todoReminders < maxPlanNudges &&
            settings.agentMode &&
            hasIncompleteTodos(run.latestTodos) &&
            !run.stopRequested) {
          final String reminder = todoSyncReminderText(run.latestTodos);
          // Belt-and-braces dedup: never stack the reminder on itself.
          final bool wireEndsWithReminder =
              wire.isNotEmpty &&
              wire.last['role'] == 'user' &&
              wire.last['content'] is String &&
              (wire.last['content'] as String).startsWith(
                todoSyncReminderPrefix,
              );
          if (!wireEndsWithReminder) {
            wire.add(<String, dynamic>{'role': 'user', 'content': reminder});
            todoReminders++;
          }
          stepsSinceTodoWrite = 0;
        }
        unawaited(_persist(run));
        if (run.stopRequested) break;
      }

      if (run.stopRequested && run.messages.isNotEmpty) {
        final ChatMessage last = run.messages.last;
        if (last.role == Role.assistant && last.isStreaming) {
          final String marker = appStringsFor(settings.languageCode)
              .stoppedMarkdown;
          run.messages[run.messages.length - 1] = _preserveLastId(
            run,
            ChatMessage.assistant(
              last.content.trim().isEmpty
                  ? marker
                  : '${last.content}\n\n$marker',
            ),
          );
          _sync(run);
        }
      } else if (!run.stopRequested &&
          run.messages.isNotEmpty &&
          run.messages.last.role == Role.assistant &&
          run.messages.last.toolCalls.isNotEmpty) {
        // The step cap was exhausted while the model still wanted to call
        // tools — explain the pause instead of stopping silently.
        run.messages.add(
          ChatMessage.assistant(
            strings.maxStepsReachedMarkdown(
              settings.runUntilDone ? unboundedStepLimit : settings.maxSteps,
            ),
          ),
        );
        _sync(run);
      }
      return const _RunResult();
    } catch (e) {
      return _RunResult(error: e.toString(), cause: e);
    } finally {
      // Always release the background hold — success, error, or stop.
      // Refcounted: parallel sessions keep the service alive until all end.
      if (holdStarted) {
        // v1.42.0: drop THIS chat's notification first, then the hold (the
        // service itself only stops when the LAST session releases).
        await background.stopSession(run.sessionId);
        await background.stop();
      }
    }
  }

  /// Streams one assistant turn with v1.30.0 auto-retry: a retryable
  /// failure (unreachable provider, weak network, dropped stream, HTTP
  /// 429/5xx) is re-attempted up to [AppSettings.autoRetryAttempts] times,
  /// waiting [AppSettings.autoRetryDelay] x attempt seconds between tries.
  /// While waiting, the streaming placeholder shows the reconnect note;
  /// as soon as the next attempt emits, live content takes over again.
  /// A user Stop aborts instantly ([LlmAbortedException]) — never retried.
  ///
  /// v1.32.0 airplane-aware hold: a retryable failure while airplane mode
  /// is ON is EXPECTED (the user turned the radio off on purpose). The
  /// loop then HOLDS — showing the airplane note — without consuming an
  /// attempt, until airplane mode is OFF again (connection restored), the
  /// cap elapses, or the user presses Stop. This is what makes the
  /// manual airplane workflow actually "auto-continue": the user's queued
  /// reply is delivered the moment the radio comes back.
  Future<AssistantTurn> _completeWithRetry(
    _SessionRun run,
    AppSettings settings, {
    required LlmConfig config,
    required List<Map<String, dynamic>> wire,
    required List<Map<String, dynamic>>? tools,
    required StringBuffer buffer,
  }) async {
    final AppStrings strings = appStringsFor(settings.languageCode);
    final int maxAttempts = settings.autoRetryEnabled
        ? settings.autoRetryAttempts
        : 1;
    int attempt = 0;
    bool noteShown = false;
    String partial = '';
    while (true) {
      try {
        return await ref
            .read(llmClientProvider)
            .complete(
              config: config,
              messages: wire,
              tools: tools,
              onDelta: (delta) {
                buffer.write(delta);
                // v1.39.0: a BACKGROUND session renders nothing, so skip
                // the O(n) buffer→string→ChatMessage materialization and
                // the state emission entirely. openChat materializes the
                // buffer once if the user comes back mid-turn; the turn
                // consumer writes the authoritative message at the end.
                if (_activeSessionId != run.sessionId) return;
                // v1.34.0 jank fix: the O(n) transcript copy (buffer →
                // ChatMessage) used to run on EVERY delta — hundreds of
                // copies per answer on fast providers. Gate it behind the
                // same 48ms streaming gap as the state emission; the turn
                // consumer writes the authoritative message from the final
                // turn anyway. When the user presses Stop, every remaining
                // delta DOES update again so the abort keeps full text.
                final int now = DateTime.now().millisecondsSinceEpoch;
                final int last = _lastStreamSync[run.sessionId] ?? 0;
                if (now - last < _streamSyncGapMs && !run.stopRequested) {
                  return;
                }
                _lastStreamSync[run.sessionId] = now;
                run.messages[run.messages.length - 1] = _preserveLastId(
                  run,
                  ChatMessage.assistant(buffer.toString(), isStreaming: true),
                );
                _sync(run);
              },
              // Stop must interrupt DURING the stream, not after it.
              shouldAbort: () => run.stopRequested,
              // v1.42.0: lets forceStop() hard-close THIS run's transport
              // (stalled-connection kill) without touching other chats.
              cancelKey: run,
            );
      } on LlmAbortedException {
        rethrow;
      } catch (e) {
        // v1.32.0 — airplane-aware hold BEFORE the attempt accounting:
        // only when the failure is retryable, the device can actually
        // report the airplane state, and it IS on. Stop aborts; the cap
        // falls through to normal accounting so a stuck radio can never
        // pin a run forever.
        if (settings.autoRetryEnabled &&
            isRetryableLlmError(e) &&
            !run.stopRequested &&
            await _airplaneModeOn()) {
          run.messages[run.messages.length - 1] = _preserveLastId(
            run,
            ChatMessage.assistant(
              strings.autoRetryAirplaneNote,
              isStreaming: true,
            ),
          );
          _sync(run);
          if (!await _airplaneWait(run)) {
            // Stop pressed while holding: restore what the failed
            // attempt had streamed, then abort through the normal path.
            run.messages[run.messages.length - 1] = _preserveLastId(
              run,
              ChatMessage.assistant(partial, isStreaming: true),
            );
            _sync(run);
            throw const LlmAbortedException('');
          }
          continue;
        }
        attempt++;
        final bool exhausted =
            !isRetryableLlmError(e) ||
            attempt >= maxAttempts ||
            run.stopRequested;
        if (exhausted) {
          // A Stop pressed while the attempt was failing must surface the
          // normal stop flow — never a transport error.
          if (run.stopRequested) throw const LlmAbortedException('');
          // Give up: put back the last content the user actually saw if
          // the final attempt died before producing anything (the note
          // would otherwise be the only thing left on screen).
          if (noteShown && buffer.isEmpty) {
            run.messages[run.messages.length - 1] = _preserveLastId(
              run,
              ChatMessage.assistant(partial, isStreaming: true),
            );
            _sync(run);
          }
          rethrow;
        }
        partial = buffer.toString();
        buffer.clear();
        noteShown = true;
        run.messages[run.messages.length - 1] = _preserveLastId(
          run,
          ChatMessage.assistant(
            strings.autoRetryStreamNote(attempt, maxAttempts),
            isStreaming: true,
          ),
        );
        _sync(run);
        if (!await _retryWait(run, settings.autoRetryDelay * attempt)) {
          // Stop pressed while waiting: restore what the failed attempt
          // had streamed, then abort through the normal stop path.
          run.messages[run.messages.length - 1] = _preserveLastId(
            run,
            ChatMessage.assistant(partial, isStreaming: true),
          );
          _sync(run);
          throw const LlmAbortedException('');
        }
      }
    }
  }

  /// Test hook (v1.32.0): poll cadence of the airplane-aware wait. Tests
  /// set [Duration.zero] to run a single probe pass without real delays.
  static Duration airplanePollInterval = const Duration(seconds: 2);

  /// Test hook (v1.32.0): hard cap of the airplane-aware wait — a radio
  /// stuck ON must not pin a run forever; past the cap the normal retry
  /// accounting takes over (visible attempts, visible notes).
  static Duration airplaneWaitCap = const Duration(minutes: 10);

  /// v1.32.0 — true when the device reports airplane mode ON. Unknown
  /// (null) counts as OFF: the airplane-aware hold only applies where
  /// the state can actually be verified, so tests and non-Android
  /// platforms keep the plain v1.30.0 behavior.
  Future<bool> _airplaneModeOn() async {
    try {
      final bool? on = await ref
          .read(deviceShellServiceProvider)
          .readAirplaneMode();
      return on == true;
    } catch (_) {
      return false;
    }
  }

  /// v1.32.0 — airplane-aware hold: polls the airplane state every
  /// [airplanePollInterval] until it turns OFF (connection restored),
  /// the cap elapses, or the user presses Stop. Returns false ONLY on
  /// Stop — a cap timeout falls through to the caller, which proceeds
  /// with normal retry accounting. An unanswerable probe (null) ends
  /// the hold immediately: no verifiable airplane state, no hold.
  Future<bool> _airplaneWait(_SessionRun run) async {
    if (airplanePollInterval == Duration.zero) {
      // Test cadence: one probe pass, no real delay — always proceed
      // (unless Stop). The surrounding retry loop drives the sequence;
      // tests flip the fake probe between attempts as needed.
      return !run.stopRequested;
    }
    final DeviceShellService shell = ref.read(deviceShellServiceProvider);
    int waitedMs = 0;
    final int capMs = airplaneWaitCap.inMilliseconds;
    while (waitedMs < capMs) {
      if (run.stopRequested) return false;
      bool? on;
      try {
        on = await shell.readAirplaneMode();
      } catch (_) {
        on = null;
      }
      if (on != true) return true; // OFF or unknown → stop holding
      await Future<void>.delayed(airplanePollInterval);
      waitedMs += airplanePollInterval.inMilliseconds;
    }
    return true; // cap reached → normal accounting takes over
  }

  /// Abortable backoff wait for auto-retry (v1.30.0): polls the Stop flag
  /// so a stop request always lands quickly even during a long wait.
  /// Returns false when the user pressed Stop — the caller must abort.
  Future<bool> _retryWait(_SessionRun run, int seconds) async {
    if (seconds <= 0) return !run.stopRequested;
    const int sliceMs = 200;
    int waitedMs = 0;
    final int totalMs = seconds * 1000;
    while (waitedMs < totalMs) {
      if (run.stopRequested) return false;
      await Future<void>.delayed(const Duration(milliseconds: sliceMs));
      waitedMs += sliceMs;
    }
    return !run.stopRequested;
  }

  /// Finalizes a dangling streaming placeholder left behind by a failed
  /// LLM turn (v1.30.0): without this the transcript would keep an eternal
  /// "thinking" bubble. The content (partial answer or retry note) is
  /// kept as-is, only the streaming flag is cleared.
  void _finalizeDanglingStream(_SessionRun run) {
    if (run.messages.isEmpty) return;
    final ChatMessage last = run.messages.last;
    if (last.role == Role.assistant && last.isStreaming) {
      run.messages[run.messages.length - 1] = _preserveLastId(
        run,
        ChatMessage.assistant(last.content),
      );
      _sync(run);
    }
  }

  /// v1.30.0: true when the loop ended NORMALLY (no error, no Stop) but
  /// the todo plan is still unfinished — the step cap was exhausted or the
  /// model wrapped up early. With auto-retry on, the task is picked back
  /// up instead of staying stalled mid-plan.
  bool _planInterrupted(_SessionRun run, AppSettings settings) {
    if (!settings.agentMode || !settings.planFirst) return false;
    if (!hasIncompleteTodos(run.latestTodos)) return false;
    if (run.messages.isEmpty) return false;
    final ChatMessage last = run.messages.last;
    return last.role == Role.assistant &&
        !last.isStreaming &&
        last.toolCalls.isEmpty &&
        last.content.trim().isNotEmpty;
  }

  /// System message: agent prompt (agent mode) + plan-first addendum +
  /// active-module context + enabled Context Manager entries merged into
  /// ONE system message (some providers reject several).
  ///
  /// v1.33.0: async so each active module's PER-CHAT setup state can be
  /// read and reported to the model. Before this, the prompt only said a
  /// setup form EXISTS — the model had no way to know the user had
  /// already filled it, so it kept asking for credentials in chat even
  /// though the module received them on every run.
  Future<Map<String, dynamic>> _systemWire(
    AppSettings settings,
    _SessionRun run,
  ) async {
    final StringBuffer content = StringBuffer();
    if (settings.agentMode) {
      content.write(agentSystemPrompt);
      if (settings.planFirst) content.write(planFirstSystemPrompt);
    }
    // v1.38.0: installed skills — global scope, injected so the agent
    // discovers its extended capabilities WITHOUT the user repeating the
    // install in every chat. Sync-cache read: no I/O on the wire path.
    //
    // v1.49.0 (wave-2): when THIS chat has pinned skills (composer skill
    // sheet), the per-chat selection REPLACES the global default set —
    // only the pinned, still-installed, still-enabled skills are
    // advertised here. An empty selection keeps today's behavior.
    try {
      final SkillRegistry skillRegistry = ref.read(skillRegistryProvider);
      await skillRegistry.ensureCacheLoaded();
      final List<InstalledSkill> installed = skillRegistry.listSync();
      final bool perChat = run.activeSkills.isNotEmpty;
      final List<InstalledSkill> advertised = perChat
          ? installed
                .where(
                  (InstalledSkill s) =>
                      run.activeSkills.contains(s.name) && s.enabled,
                )
                .toList(growable: false)
          : installed;
      if (advertised.isNotEmpty) {
        content
          ..writeln()
          ..writeln()
          ..writeln(
            perChat
                ? '# Installed skills (pinned to THIS chat — the user selected them for this conversation only)'
                : '# Installed skills (available in every chat)',
          );
        for (final InstalledSkill skill in advertised) {
          final Map<String, String> config = await skillRegistry.readConfig(
            skill,
          );
          final Set<String> missing = skillRegistry
              .missingRequiredConfig(skill)
              .where(
                (String f) =>
                    !config.containsKey(f) || (config[f] ?? '').isEmpty,
              )
              .toSet();
          content
            ..writeln(
              '- ${skill.name} v${skill.version}: '
              '${skill.description.isEmpty ? skill.title : skill.description}',
            )
            ..writeln(
              '  status: '
              '${missing.isEmpty ? 'ready' : 'needs config: ${missing.join(', ')}'}'
              ' — read the manual with skill_info("${skill.name}") before '
              'first use, run scripts with skill_run; configure with '
              'skill_config (values stay on-device); refresh from its '
              'source with skill_update when the user asks for the latest '
              'version.',
            );
          if (skill.requiresBins.isNotEmpty) {
            content.writeln(
              '  UNSUPPORTED HERE: requires native executable(s) '
              '${skill.requiresBins.join(', ')} — the embedded runtime '
              'cannot start external processes. Say so instead of '
              'pretending it works.',
            );
          }
        }
        content.write(
          'Use skills when the user\'s task matches one. Follow each '
          'skill\'s SKILL.md exactly, and remember the security rules: '
          'no seed phrases/private keys in chat, explicit '
          'request_confirmation approval before any irreversible or '
          'money-moving action.',
        );
      }
    } catch (_) {
      // Registry hiccup must never break the wire build.
    }

    // Chat modules active in THIS session (per-chat scope): the model
    // should treat their run output as conversation data.
    if (run.activeModules.isNotEmpty) {
      final ModuleRegistry registry = ref.read(moduleRegistryProvider);
      for (final String name in run.activeModules) {
        try {
          final ChatModule? module = registry.getSync(name);
          if (module == null) continue;
          content
            ..writeln()
            ..writeln()
            ..writeln(
              '# Active module: ${module.name} v${module.manifest.version}',
            )
            ..write(
              module.manifest.description.trim().isEmpty
                  ? 'This module runs in THIS chat\'s isolated sandbox. '
                        'Its entry point already executed; treat its module '
                        'message output as data the user may ask about.'
                  : module.manifest.description.trim(),
            );
          if (module.manifest.setup != null) {
            final ModuleSetup setup = module.manifest.setup!;
            final List<String> labels = <String>[
              for (final ModuleSetupField f in setup.fields) f.label,
            ];
            Map<String, dynamic> stored = const <String, dynamic>{};
            try {
              stored = await ref
                  .read(moduleRuntimeProvider)
                  .readStoredSetup(run.sessionId, module.name);
            } catch (_) {
              // Unreadable storage counts as "not set up yet".
            }
            if (setup.satisfiedBy(stored)) {
              content
                ..writeln()
                ..write(
                  'Setup for THIS chat: COMPLETED — the user already '
                  'submitted the app\'s setup form for this module '
                  '(${describeModuleSetupValues(setup, stored)}). The '
                  'module receives these values automatically on every '
                  'run (zagents.info.setup); secret fields are masked '
                  'here on purpose. NEVER ask the user to type or repeat '
                  'these values in chat — they are already on file and '
                  'the module uses them by itself.',
                );
            } else {
              content
                ..writeln()
                ..write(
                  'Setup for THIS chat: NOT completed (${labels.join(', ')} '
                  'are still missing) — the app shows the module\'s setup '
                  'form automatically before the module runs. Do NOT ask '
                  'the user to type these values in chat; the form '
                  'collects them and the run resumes on its own.',
                );
            }
          }
        } catch (_) {
          // Registry hiccup: skip the context block.
        }
      }
    }
    try {
      final List<ContextEntry> entries = ref
          .read(contextRepositoryProvider)
          .load()
          .where((ContextEntry e) => e.enabled && e.content.trim().isNotEmpty)
          .toList();
      for (final ContextEntry entry in entries) {
        if (content.isNotEmpty) content.writeln();
        content
          ..writeln()
          ..writeln('# Context: ${entry.name}')
          ..write(entry.content.trim());
      }
    } catch (_) {
      // Context store failure must never block a chat request.
    }
    // v1.50.0 — long-term memory + active goals (agent-mode).
    // Injected ONLY when non-empty, so empty stores keep the legacy
    // prompt byte-for-byte and legacy tests/behavior are untouched.
    try {
      String lastUser = '';
      for (final ChatMessage m in run.messages.reversed) {
        if (m.role == Role.user && m.content.trim().isNotEmpty) {
          lastUser = m.content;
          break;
        }
      }
      final String memorySummary = ref
          .read(memoryServiceProvider)
          .promptSummary(run.sessionId, lastUser);
      if (memorySummary.isNotEmpty) {
        if (content.isNotEmpty) content.writeln();
        content
          ..writeln()
          ..writeln(
            '# Long-term memory (saved across chats — treat as user facts)',
          )
          ..write(memorySummary);
      }
    } catch (_) {
      // Memory store failure must never block a chat request.
    }
    try {
      final String goalSummary = ref
          .read(goalServiceProvider)
          .promptSummary(run.sessionId);
      if (goalSummary.isNotEmpty) {
        if (content.isNotEmpty) content.writeln();
        content
          ..writeln()
          ..writeln('# Active goals (the user is working toward these)')
          ..write(goalSummary);
      }
    } catch (_) {
      // Goal store failure must never block a chat request.
    }
    return <String, dynamic>{'role': 'system', 'content': content.toString()};
  }

  /// User message in wire format; with image attachments the content
  /// becomes an OpenAI multimodal parts array.
  Map<String, dynamic> _userWireMessage(_SessionRun run, ChatMessage message) {
    final String text = _composeUserText(
      message.content,
      message.attachments,
      run,
    );
    final List<String> dataUrls = <String>[
      for (final ChatAttachment att in message.attachments)
        if (att.kind == AttachmentKind.image &&
            run.dataUrlCache[att.path] != null)
          run.dataUrlCache[att.path]!,
    ];
    if (dataUrls.isEmpty) {
      return <String, dynamic>{'role': 'user', 'content': text};
    }
    return <String, dynamic>{
      'role': 'user',
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
        for (final String url in dataUrls)
          <String, dynamic>{
            'type': 'image_url',
            'image_url': <String, dynamic>{'url': url},
          },
      ],
    };
  }

  /// Rebuilds the LLM wire for a CONTINUING session (history replay).
  List<Map<String, dynamic>> _buildWire(
    _SessionRun run,
    List<ChatMessage> messages,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final message in messages) {
      switch (message.role) {
        case Role.user:
          out.add(_userWireMessage(run, message));
        case Role.assistant:
          if (message.isStreaming) continue;
          if (message.toolCalls.isNotEmpty) {
            out.add(<String, dynamic>{
              'role': 'assistant',
              if (message.content.isNotEmpty) 'content': message.content,
              'tool_calls': <Map<String, dynamic>>[
                for (final call in message.toolCalls)
                  <String, dynamic>{
                    'id': call.id,
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': call.name,
                      // Secrets (skill_config values) never travel back to
                      // the provider — see ToolCall.safeArguments.
                      'arguments': jsonEncode(call.safeArguments),
                    },
                  },
              ],
            });
            for (final call in message.toolCalls) {
              out.add(<String, dynamic>{
                'role': 'tool',
                'tool_call_id': call.id,
                'content': call.resultText ?? '(no result)',
              });
            }
          } else if (message.content.isNotEmpty) {
            out.add(<String, dynamic>{
              'role': 'assistant',
              'content': message.content,
            });
          }
        default:
          break;
      }
    }
    return out;
  }

  /// Writes the run's view into the UI state — but only when the run's
  /// session is the one currently displayed (parallel sessions otherwise
  /// clobber each other's screen).
  void _sync(_SessionRun run) {
    if (!_alive || _activeSessionId != run.sessionId) return;
    // Live state beats anything still being read from disk: a slow
    // openChat for this same chat must not land afterwards and overwrite
    // the transcript with the pre-run file contents.
    _chatLoadGeneration++;
    state = state.copyWith(
      messages: [...run.messages],
      title: run.title,
      sessionId: run.sessionId,
      isLoading: false,
      todos: run.latestTodos,
      setupRequest: run.setupRequest,
      waitingForSetup: run.waitingForSetup,
    );
  }

  /// v1.38.0: rebuilds the last message of [run] while PRESERVING its id.
  /// Streaming deltas, finalize, stop markers and retry notes replace the
  /// trailing assistant message in place; minting a fresh id each time
  /// changed the UI's per-bubble ValueKey, so Flutter tore down and
  /// re-inflated the whole bubble subtree on every throttled sync
  /// (~20x/second) — markdown re-parse storms, frame drops and the live
  /// Plan panel losing its open state mid-answer.
  ChatMessage _preserveLastId(_SessionRun run, ChatMessage updated) {
    return ChatMessage.assistant(
      updated.content,
      toolCalls: updated.toolCalls,
      isStreaming: updated.isStreaming,
      model: updated.model,
      usage: updated.usage,
      moduleName: updated.moduleName,
      id: run.messages.last.id,
    );
  }

  // -- request_confirmation (v1.38.0) -------------------------------------

  /// True when [name] names an installed skill whose SKILL.md declares
  /// `wallet: true` — i.e. running it can move value on-chain.
  ///
  /// Fails CLOSED: if the registry cannot answer, the skill may be a
  /// wallet skill, so the caller must ask for approval anyway. An
  /// uninstalled name returns false — the executor reports it as missing.
  Future<bool> _isWalletSkill(String? name) async {
    final String skillName = name?.trim() ?? '';
    if (skillName.isEmpty) return false;
    try {
      final SkillRegistry registry = ref.read(skillRegistryProvider);
      final InstalledSkill? skill = await registry.get(skillName);
      return skill?.wallet ?? false;
    } catch (_) {
      return true;
    }
  }

  /// Hard cap on waiting for the user's approval decision.
  static const Duration confirmationTimeout = Duration(minutes: 10);

  /// Blocks the agent loop until the user answers the approval dialog.
  /// Fails closed: a run that is not on screen cannot ask (background
  /// runs must never silently wait or auto-approve), and silence times
  /// out into a denial.
  Future<ToolResult> _requestConfirmation(
    _SessionRun run,
    ToolCall call,
  ) async {
    final AppStrings strings = appStringsFor(
      ref.read(settingsProvider).languageCode,
    );
    if (_activeSessionId != run.sessionId) {
      return ToolResult(ok: false, llmOutput: strings.confirmUnavailable);
    }
    // `details` is model-authored: accept a list OR a bare string (a strict
    // `as List` cast used to throw on `"details": "send 1 BNB"`).
    final Object? rawDetails = call.arguments['details'];
    final List<String> details = <String>[];
    switch (rawDetails) {
      case final List<Object?> list:
        for (final Object? item in list) {
          if (item != null && item.toString().trim().isNotEmpty) {
            details.add(item.toString());
          }
        }
        break;
      case final String text:
        if (text.trim().isNotEmpty) details.add(text);
        break;
      case null:
        break;
      default:
        final String text = rawDetails.toString().trim();
        if (text.isNotEmpty) details.add(text);
        break;
    }
    final bool approved = await _askApproval(
      run,
      id: call.id,
      title: call.arguments['title']?.toString() ?? 'Confirmation',
      details: details,
      danger: call.arguments['danger'] != false,
    );
    return ToolResult(
      // A denial (or a timeout) is a FAILED tool call, not a successful one:
      // reporting ok here made the transcript show a green check next to an
      // action the user refused.
      ok: approved,
      llmOutput: approved ? strings.confirmApproved : strings.confirmDenied,
      displayText: approved ? 'approved' : 'denied',
    );
  }

  /// Parks an approval prompt on the chat and waits for the user's decision.
  /// Fails closed: a run that is not on screen cannot ask (background runs
  /// must never silently wait or auto-approve), and silence times out into a
  /// denial.
  Future<bool> _askApproval(
    _SessionRun run, {
    required String id,
    required String title,
    required List<String> details,
    bool danger = true,
  }) async {
    if (_activeSessionId != run.sessionId) return false;
    final Completer<bool> waiter = Completer<bool>();
    _confirmationWaiters[id] = _ConfirmationWaiter(
      sessionId: run.sessionId,
      completer: waiter,
    );
    state = state.copyWith(
      pendingConfirmation: ConfirmationRequest(
        id: id,
        title: title,
        details: details,
        danger: danger,
      ),
    );
    late final bool approved;
    try {
      approved = await waiter.future.timeout(
        confirmationTimeout,
        onTimeout: () => false,
      );
    } finally {
      _confirmationWaiters.remove(id);
      if (_activeSessionId == run.sessionId) {
        state = state.copyWith(pendingConfirmation: null);
      }
    }
    return approved;
  }

  /// The user tapped Approve (true) or Deny (false) on the dialog for
  /// [id]. Unknown/stale ids are ignored (the run may have been stopped).
  void resolveConfirmation(String id, bool approved) {
    final _ConfirmationWaiter? waiter = _confirmationWaiters[id];
    if (waiter == null || waiter.completer.isCompleted) return;
    waiter.completer.complete(approved);
  }

  /// Any open confirmation prompts must fail closed when the user stops
  /// the run, deletes the chat or switches away mid-prompt.
  ///
  /// v1.39.0: scoped to ONE session. The map is shared by every parallel
  /// run, and the previous implementation completed every waiter in it —
  /// so stopping chat A silently denied a prompt that belonged to chat B.
  void _cancelConfirmationsForSession(String sessionId) {
    final List<String> owned = <String>[
      for (final MapEntry<String, _ConfirmationWaiter> entry
          in _confirmationWaiters.entries)
        if (entry.value.sessionId == sessionId) entry.key,
    ];
    for (final String id in owned) {
      final _ConfirmationWaiter? waiter = _confirmationWaiters.remove(id);
      if (waiter != null && !waiter.completer.isCompleted) {
        waiter.completer.complete(false);
      }
    }
    if (sessionId == _activeSessionId && state.pendingConfirmation != null) {
      state = state.copyWith(pendingConfirmation: null);
    }
  }

  /// Minimum gap between two streaming UI updates (ms). Every streamed
  /// delta used to copy the whole transcript and emit a new state, so a
  /// fast provider + long conversation rebuilt the chat body dozens of
  /// times per second — visible jank and a contributor to Android ANRs.
  /// Coalescing is synchronous (no timers): dropped intermediates are
  /// always flushed by the authoritative syncs at turn end / finalize.
  /// v1.34.0: the same gap now also gates the per-delta ChatMessage copy
  /// itself (the O(n) part), not just the state emission.
  static const int _streamSyncGapMs = 48;
  final Map<String, int> _lastStreamSync = <String, int>{};

  /// Persists [run], serialized through the run's own persist chain so
  /// concurrent calls (persist-at-start vs mid-run vs final) can never
  /// write out of order. Deleted sessions are skipped — and an in-flight
  /// save that races a delete is rolled back — so a chat can never
  /// resurrect from its own run.
  Future<void> _persist(_SessionRun run) {
    if (run.deleted) return Future<void>.value();
    final Future<void> previous = run.persistChain;
    final Future<void> next = previous.then((_) => _saveNow(run));
    run.persistChain = next;
    return next;
  }

  Future<void> _saveNow(_SessionRun run) async {
    if (run.deleted) return;
    final persisted = run.messages
        .where((m) => !(m.isStreaming && m.content.isEmpty))
        .toList();
    try {
      await ref
          .read(chatStoreProvider)
          .save(
            id: run.sessionId,
            title: run.title,
            messages: persisted,
            modules: run.activeModules,
            skills: run.activeSkills,
            waitingForSetup: run.waitingForSetup,
            // v1.35.0 crash recovery: the plan travels with the transcript.
            todos: run.latestTodos,
          );
      if (run.deleted) {
        // The session was deleted while this save was in flight — undo it
        // so a deleted chat can never resurrect from its own run (the
        // persist-at-start write can land after deleteChat's own remove).
        await ref.read(chatStoreProvider).delete(run.sessionId);
        return;
      }
      if (run.listInvalidatePending) {
        run.listInvalidatePending = false;
        ref.invalidate(chatListProvider);
      }
    } catch (_) {
      // Persistence is best-effort.
    }
  }

  /// Model-generated conversation title (v1.15.0). Runs ONCE per session,
  /// after the first successful answer, when the title still came from the
  /// automatic prompt-prefix path and the user has not renamed the chat.
  /// Every failure keeps the old title and never surfaces an error.
  Future<void> _maybeAutoTitle(_SessionRun run, AppSettings settings) async {
    try {
      if (!settings.autoTitle || !run.autoTitlePending) return;
      ChatMessage? firstUser;
      ChatMessage? firstAssistant;
      for (final ChatMessage m in run.messages) {
        if (m.role == Role.user &&
            firstUser == null &&
            m.content.trim().isNotEmpty) {
          firstUser = m;
        }
        if (m.role == Role.assistant &&
            firstAssistant == null &&
            m.content.trim().isNotEmpty &&
            !m.isStreaming) {
          firstAssistant = m;
        }
        if (firstUser != null && firstAssistant != null) break;
      }
      if (firstUser == null || firstAssistant == null) return;

      final AssistantTurn turn = await ref
          .read(llmClientProvider)
          .complete(
            config: LlmConfig(
              baseUrl: settings.baseUrl,
              apiKey: settings.apiKey,
              model: settings.model,
              engine: settings.engine,
            ),
            tools: null,
            messages: <Map<String, dynamic>>[
              <String, dynamic>{
                'role': 'system',
                'content':
                    'You write short conversation titles. Reply with '
                    'ONLY the title: max 6 words, no quotes, no punctuation '
                    'at the end, same language as the conversation.',
              },
              <String, dynamic>{
                'role': 'user',
                'content':
                    '${_capForTitle(firstUser.content, 500)}\n\n'
                    'Assistant reply:\n'
                    '${_capForTitle(firstAssistant.content, 500)}',
              },
            ],
          );

      final String title = _sanitizeTitle(turn.content);
      if (title.isEmpty || title == run.title) return;
      run.title = title;
      run.autoTitlePending = false;
      if (_activeSessionId == run.sessionId) {
        state = state.copyWith(title: title);
      }
      try {
        await ref.read(chatStoreProvider).rename(run.sessionId, title);
        ref.invalidate(chatListProvider);
      } catch (_) {
        // The UI already shows the new title; storage stays best-effort.
      }
    } catch (_) {
      // Title generation is a pure nicety: any failure (API, parsing,
      // storage) keeps the existing title silently.
    }
  }

  /// Cleans a model-proposed title: trims, strips wrapping quotes, joins
  /// newlines and caps the length. Returns '' when nothing usable remains.
  static String _sanitizeTitle(String raw) {
    String title = raw.trim();
    if (title.length >= 2) {
      const List<String> quotes = <String>['"', "'", '“', '”', '«', '»'];
      for (final String q in quotes) {
        if (title.startsWith(q) && title.endsWith(q)) {
          title = title.substring(1, title.length - 1).trim();
          break;
        }
      }
    }
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.length > 80) title = title.substring(0, 80);
    return title.trim();
  }

  static String _capForTitle(String text, int max) {
    final String trimmed = text.trim();
    return trimmed.length > max ? trimmed.substring(0, max) : trimmed;
  }

  /// Starts a fresh draft. Any in-flight session keeps running in the
  /// background and can be reopened from history. v1.38.1: the draft slot
  /// gets back its own staged files — staged files belong to the chat the
  /// user staged them in, not to whichever chat happens to be open.
  Future<void> newChat() async {
    if (_activeSessionId != null) {
      _cancelConfirmationsForSession(_activeSessionId!);
    }
    _stashStagedAttachments();
    // Invalidate any in-flight openChat: a draft must never be replaced by
    // a chat the user already navigated away from.
    _chatLoadGeneration++;
    _activeSessionId = null;
    _restoreStagedAttachments(null);
    state = const ChatState();
  }

  /// App-start behavior (chat.z.ai style): reopen the most recent
  /// conversation so the first message CONTINUES it. A brand-new chat is
  /// only started after the user explicitly taps "New chat" in the drawer.
  /// Never yanks the screen away when the user is already interacting.
  Future<void> restoreLastChat() async {
    if (_activeSessionId != null ||
        state.messages.isNotEmpty ||
        state.isRunning) {
      return;
    }
    // A draft the user explicitly started (New chat, staged module, staged
    // attachment) must never be replaced by the last chat just because the
    // history list finished loading a moment later.
    final int generation = _chatLoadGeneration;
    bool draftTouched() =>
        _activeSessionId != null ||
        state.messages.isNotEmpty ||
        state.isRunning ||
        state.pendingModule != null ||
        ref.read(pendingAttachmentsProvider).isNotEmpty;
    try {
      final List<ChatSummary> items = await _historyOnce();
      if (items.isEmpty) return;
      if (generation != _chatLoadGeneration || draftTouched()) return;
      await openChat(items.first);
    } catch (_) {
      // History unavailable: stay on the fresh draft.
    }
  }

  /// The history list, resolved even when the provider is INVALIDATED while
  /// this call is waiting (v1.40.0). `ref.read(chatListProvider.future)`
  /// returns a future owned by the provider instance of that moment: any
  /// `ref.invalidate(chatListProvider)` (every finished run does one) while
  /// it is still pending disposes that instance and the old future NEVER
  /// completes — `restoreLastChat` then hung forever, which is exactly what
  /// happens when the user sends a message while app-start history is still
  /// loading.
  ///
  /// v1.40.1: read the STORE directly. The list is only used to pick the
  /// most recent conversation — the drawer keeps watching chatListProvider
  /// for the reactive UI, but this cold-start path has no invalidation race
  /// against a plain store read. (A manual provider listener is also not an
  /// option here: `Ref.listenManual` does not exist on
  /// `NotifierProviderRef` in flutter_riverpod 2.6.)
  Future<List<ChatSummary>> _historyOnce() =>
      ref.read(chatStoreProvider).listSummaries();

  Future<void> openChat(ChatSummary summary) async {
    final String? previousId = _activeSessionId;
    if (previousId != null && previousId != summary.id) {
      _cancelConfirmationsForSession(previousId);
    }
    // v1.38.1: stash the displayed chat's staged list before switching...
    _stashStagedAttachments();
    // v1.39.0: invalidate every load still in flight for a previous chat.
    // The old code only compared `_activeSessionId`, which a fast
    // A → B → A switch defeats: A's first (slow) load would commit after
    // the user already came back, overwriting the newer state.
    final int generation = ++_chatLoadGeneration;
    _activeSessionId = summary.id;
    // ...and restore THIS chat's own staged list (preserve, not clear —
    // files still never travel between chats).
    _restoreStagedAttachments(summary.id);
    final _SessionRun? run = _runs[summary.id];
    if (run != null) {
      // A background run mid-stream did not materialize its deltas (nobody
      // was rendering it). Flush the buffer ONCE so the reopened chat shows
      // the answer produced so far instead of an empty bubble.
      final StringBuffer? streaming = run.streamingBuffer;
      if (streaming != null && run.messages.isNotEmpty) {
        run.messages[run.messages.length - 1] = _preserveLastId(
          run,
          ChatMessage.assistant(streaming.toString(), isStreaming: true),
        );
      }
      // Live session (still running or just finished): adopt its state.
      state = ChatState(
        sessionId: run.sessionId,
        title: run.title,
        messages: [...run.messages],
        // A stopping run is still running until its loop actually exits —
        // showing send here would silently swallow the next message.
        isRunning: run.isRunning,
        // v1.35.0: switching away and back no longer blanks the plan
        // panel for a finished run (no further _sync would restore it).
        todos: [...run.latestTodos],
        activeModules: [...run.activeModules],
        activeSkills: [...run.activeSkills],
        setupRequest: run.setupRequest,
        waitingForSetup: run.waitingForSetup,
        // A module build/repair awaiting the user's install decision belongs
        // to the run, not to the screen: reopening the chat mid-run must not
        // hide the install card until the next sync.
        pendingModuleInstall: run.pendingInstall,
      );
      return;
    }
    // v1.39.0: show the TARGET chat immediately — an empty transcript
    // behind a spinner — instead of leaving the previous chat's messages,
    // plan and running state on screen for the whole disk read. This was
    // the visible cross-chat leak: opening a chat showed another chat's
    // content until the load finished.
    state = ChatState(
      sessionId: summary.id,
      title: summary.title,
      isLoading: true,
    );
    try {
      // v1.38.1: ONE file read/decode for messages + modules + wait flag
      // + plan (was four separate decodes of the same megabyte-scale file).
      final SessionBundle? bundle = await ref
          .read(chatStoreProvider)
          .loadBundle(summary.id);
      // The user may have switched again while loading — only commit when
      // this load is still the current one. The generation token also
      // catches a fast A → B → A switch, where `_activeSessionId` alone
      // would let A's first (slow) load overwrite the newer state.
      if (!_isCurrentLoad(generation, summary.id)) return;
      final List<ChatMessage> messages =
          bundle?.messages ?? const <ChatMessage>[];
      final List<String> modules = bundle?.modules ?? const <String>[];
      final List<String> skills = bundle?.skills ?? const <String>[];
      if (!_isCurrentLoad(generation, summary.id)) return;
      // A module left unconfigured in this chat resurfaces its per-chat
      // setup form right on reopen — before any failed re-run can happen.
      final ModuleSetupRequest? setupRequest = await _findSetupRequest(
        summary.id,
        modules,
      );
      if (!_isCurrentLoad(generation, summary.id)) return;
      // v1.29.0: the persisted wait flag tells whether a QUEUED user
      // message is blocked behind that form (the agent must not run).
      final bool waitingForSetup = bundle?.waitingForSetup ?? false;
      if (!_isCurrentLoad(generation, summary.id)) return;
      state = ChatState(
        sessionId: summary.id,
        title: summary.title,
        messages: messages,
        // v1.35.0 crash recovery: the latest plan comes back from disk so
        // reopening a chat after a crash still shows what the agent was
        // doing (and continuing the task picks the plan back up).
        todos: bundle?.todos ?? const <TodoItem>[],
        activeModules: modules,
        activeSkills: skills,
        setupRequest: setupRequest,
        waitingForSetup: waitingForSetup,
      );
    } catch (_) {
      // A corrupted history entry must never crash the app: open an empty
      // session and tell the user what happened.
      if (!_isCurrentLoad(generation, summary.id)) return;
      state = ChatState(
        sessionId: summary.id,
        error: appStringsFor(ref.read(settingsProvider).languageCode)
            .chatOpenError,
      );
    }
  }

  /// True when the chat load started with [generation] is still the one
  /// the screen is waiting for.
  bool _isCurrentLoad(int generation, String sessionId) =>
      generation == _chatLoadGeneration && _activeSessionId == sessionId;

  Future<void> renameChat(String id, String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final _SessionRun? run = _runs[id];
    if (run != null) {
      run.title = _titleFor(trimmed);
      // A manual rename is authoritative: no automatic retitle afterwards.
      run.autoTitlePending = false;
      if (_activeSessionId == id) {
        state = state.copyWith(title: run.title);
      }
    }
    try {
      await ref.read(chatStoreProvider).rename(id, _titleFor(trimmed));
      ref.invalidate(chatListProvider);
    } catch (_) {
      state = state.copyWith(
        error: appStringsFor(ref.read(settingsProvider).languageCode)
            .chatRenameError,
      );
    }
  }

  Future<void> deleteChat(String id) async {
    _cancelConfirmationsForSession(id);
    // v1.38.1: the deleted chat's staged files and draft text die with it.
    _stagedAttachments.remove(id);
    _draftTexts.remove(id);
    // If this session is running, stop it and drop its results; a live
    // module execution for the session is terminated safely too.
    _runs[id]?.stopRequested = true;
    _runs[id]?.deleted = true;
    try {
      ref.read(moduleRuntimeProvider).terminateSession(id);
    } catch (_) {
      // Runtime unavailable: deletion proceeds regardless.
    }
    try {
      await ref.read(chatStoreProvider).delete(id);
    } catch (_) {
      state = state.copyWith(
        error: appStringsFor(ref.read(settingsProvider).languageCode)
            .chatDeleteError,
      );
      return;
    }
    // v1.29.0: the chat's private workspace folder (uploads, module
    // state, agent files) is deleted WITH the chat — data of a removed
    // conversation must not linger and mix into the sessions directory.
    try {
      await ref.read(sessionSandboxProvider).deleteSession(id);
    } catch (_) {
      // Sandbox cleanup is best-effort: the transcript is already gone.
    }
    if (_activeSessionId == id) {
      _activeSessionId = null;
      // The composer's staged files belonged to the deleted chat: their
      // uploads folder is gone, so leaving the chips would send dangling
      // paths with the next message.
      ref.read(pendingAttachmentsProvider.notifier).state =
          const <ChatAttachment>[];
      // Invalidate any history load still in flight for the deleted chat.
      _chatLoadGeneration++;
      state = const ChatState();
    }
    ref.invalidate(chatListProvider);
    _markRunning();
  }
}

class _RunResult {
  const _RunResult({this.error, this.cause});
  final String? error;

  /// Original thrown object behind [error] (v1.30.0) — lets the auto-retry
  /// logic classify the failure (retryable transport error vs permanent
  /// bad request) without parsing the message string.
  final Object? cause;
}

/// Settings controller: holds AppSettings and persists on every update.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsRepositoryProvider).load();

  Future<void> update(AppSettings next) async {
    state = next;
    try {
      await ref.read(settingsRepositoryProvider).save(next);
    } catch (e) {
      // v1.47.1: a failed persistence (e.g. disk full) must not escape —
      // callers fire-and-forget this future, so an unhandled error would
      // only surface as a zone issue while the UI already shows the new
      // value. In-session state stays applied; the repository surfaces
      // degradation via lastSettingsWriteError/lastSecretStorageError.
      debugPrint('settings save failed: $e');
    }
  }
}
