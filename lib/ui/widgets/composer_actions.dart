import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/attachment_service.dart';
import '../../services/skill_registry.dart';
import '../../services/speech_service.dart';
import '../screens/prompt_library_screen.dart';
import '../theme.dart';
import 'skill_selector_sheet.dart';
import 'app_message.dart';

/// Immutable in-flight state of the composer TOOL actions (v1.48.0).
class ComposerActionsState {
  const ComposerActionsState({
    this.picking = false,
    this.listening = false,
    this.speechPartial = '',
  });

  /// An attachment-picker round trip is in flight (attach icon renders a
  /// spinner and ignores further taps until it lands).
  final bool picking;

  /// v1.44.0 — a live dictation session is open: the mic icon renders as
  /// a red stop and the partial transcript is previewed inline.
  final bool listening;

  /// The provisional transcript of the open dictation session.
  final String speechPartial;

  ComposerActionsState copyWith({
    bool? picking,
    bool? listening,
    String? speechPartial,
  }) => ComposerActionsState(
    picking: picking ?? this.picking,
    listening: listening ?? this.listening,
    speechPartial: speechPartial ?? this.speechPartial,
  );
}

/// Shared controller behind the three composer TOOL icons — attach file /
/// prompt library / mic (v1.48.0).
///
/// The icons render in TWO placements: the idle composer toolbar AND —
/// while a run streams — the thinking footer's row, immediately LEFT of
/// the plan show/hide eye (the composer toolbar hides while running, so
/// there is never a duplicate on screen). Both placements must behave
/// identically and share ONE set of in-flight state, so the actions moved
/// out of the composer's widget state into this app-lifetime `Notifier`
/// (same pattern as the ChatController/SettingsController notifiers).
///
/// Text insertions (prompt content, dictation finals) land in the field
/// the composer registered via [bindField] — with caret + focus handling
/// — or, when nothing is bound, in the ACTIVE chat's per-chat draft store.
class ComposerActionsController extends Notifier<ComposerActionsState> {
  /// The composer's text field + focus node, registered on mount so
  /// insertions reach the real input. Identity-checked on unbind so a
  /// stale unbind can never drop a newer binding.
  TextEditingController? _field;
  FocusNode? _focus;

  @override
  ComposerActionsState build() => const ComposerActionsState();

  /// The composer registers its field on mount (and unbinds on dispose).
  void bindField(TextEditingController controller, FocusNode focusNode) {
    _field = controller;
    _focus = focusNode;
  }

  void unbindField(TextEditingController controller) {
    if (identical(_field, controller)) {
      _field = null;
      _focus = null;
    }
  }

  /// Appends the chosen prompt's content to the composer text —
  /// newline-joined with what is already there, caret parked at the end.
  void insertText(String text) => _insert(text, newlineJoined: true);

  /// Appends a FINAL dictation result — space-joined (v1.44.0 rule:
  /// "one two", never "one\ntwo") so spoken sentences stay sentences.
  void insertDictation(String text) => _insert(text, newlineJoined: false);

  void _insert(String text, {required bool newlineJoined}) {
    final TextEditingController? field = _field;
    if (field != null) {
      final String merged = _merge(
        field.text,
        text,
        newlineJoined: newlineJoined,
      );
      field.value = TextEditingValue(
        text: merged,
        selection: TextSelection.collapsed(offset: merged.length),
      );
      return;
    }
    // Defensive fallback (no composer mounted): the words still belong to
    // the ACTIVE chat — append to its per-chat draft store.
    final String? sessionId = ref.read(activeSessionIdProvider);
    final String base = ref
        .read(chatControllerProvider.notifier)
        .draftTextFor(sessionId);
    ref
        .read(chatControllerProvider.notifier)
        .setDraftText(
          sessionId,
          _merge(base, text, newlineJoined: newlineJoined),
        );
  }

  String _merge(String base, String text, {required bool newlineJoined}) {
    if (newlineJoined) {
      return base.isEmpty
          ? text
          : base.endsWith('\n')
          ? '$base$text'
          : '$base\n$text';
    }
    return base.isEmpty ? text : '$base ${text.trimLeft()}';
  }

  /// Paperclip: opens the system file picker and stages the picked file
  /// into the ACTIVE chat's pending attachments. Images take the
  /// optimization pipeline; everything else is copied byte-for-byte into
  /// the chat's uploads folder.
  Future<void> pickFile(BuildContext context) async {
    if (state.picking) return;
    state = state.copyWith(picking: true);
    // The picker is a system dialog: the user can switch chats while it is
    // open. Files belong to the chat they were picked FROM, so the session is
    // captured before the await and the result is discarded if the user moved
    // on — otherwise chat A's file silently appeared in chat B's composer.
    final String? sessionId = ref.read(activeSessionIdProvider);
    try {
      final XFile? picked = await openFile();
      if (picked == null) return;
      if (ref.read(activeSessionIdProvider) != sessionId) return;
      // v1.44.0: images take the optimization pipeline — validated by
      // content magic, downscaled to a 1600 px long edge, re-encoded —
      // and are stored under `attachments/` in the SAME per-chat sandbox.
      // Non-image files keep the byte-for-byte uploads copy below.
      if (AttachmentService.looksLikeImage(picked.name)) {
        final AttachmentResult result = await ref
            .read(attachmentServiceProvider)
            .optimizeAndStore(sessionId: sessionId, picked: picked);
        if (ref.read(activeSessionIdProvider) != sessionId) return;
        if (!result.ok) {
          if (context.mounted) _showAttachmentError(context, result);
          return;
        }
        final List<String> refParts = result.relativePath!.split(
          Platform.pathSeparator,
        );
        final ChatAttachment attachment = ChatAttachment(
          name: refParts.last,
          path: result.absolutePath!,
          sizeBytes: result.bytes!.length,
          kind: AttachmentKind.image,
        );
        ref.read(pendingAttachmentsProvider.notifier).state = <ChatAttachment>[
          ...ref.read(pendingAttachmentsProvider),
          attachment,
        ];
        return;
      }
      // Uploads live in the ACTIVE session's own workspace — files never
      // mix between chats (private-window isolation).
      final Directory root = await ref
          .read(sessionSandboxProvider)
          .rootFor(sessionId);
      final Directory uploads = Directory(
        '${root.path}${Platform.pathSeparator}uploads',
      );
      if (!uploads.existsSync()) uploads.createSync(recursive: true);
      final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String safeName = picked.name.replaceAll('/', '_');
      final File dest = File(
        '${uploads.path}${Platform.pathSeparator}${stamp}_$safeName',
      );
      await File(picked.path).copy(dest.path);
      if (ref.read(activeSessionIdProvider) != sessionId) {
        // The user switched while the copy ran: don't leave an orphan file
        // (and don't stage it into the wrong chat).
        try {
          if (dest.existsSync()) dest.deleteSync();
        } catch (_) {}
        return;
      }
      final ChatAttachment attachment = ChatAttachment(
        name: safeName,
        path: dest.path,
        sizeBytes: await dest.length(),
        kind: attachmentKindFor(safeName),
      );
      ref.read(pendingAttachmentsProvider.notifier).state = <ChatAttachment>[
        ...ref.read(pendingAttachmentsProvider),
        attachment,
      ];
    } catch (_) {
      if (context.mounted) {
        // v1.49.6: centered message dialog instead of a SnackBar.
        showAppMessage(context, stringsOf(context).operationFailed);
      }
    } finally {
      state = state.copyWith(picking: false);
    }
  }

  /// Bottom sheet listing the Prompt Library entries; tapping one inserts
  /// it into the composer. Includes a shortcut into the library screen.
  Future<void> openPromptSheet(BuildContext context) async {
    final AppStrings strings = stringsOf(context);
    final BuildContext hostContext = context;
    ref.invalidate(promptListProvider);
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => Consumer(
        builder: (BuildContext context, WidgetRef sheetRef, _) {
          final AsyncValue<List<PromptEntry>> prompts = sheetRef.watch(
            promptListProvider,
          );
          return SafeArea(
            child: prompts.when(
              loading: () => const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              error: (Object e, StackTrace s) => SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    strings.operationFailed,
                    style: TextStyle(color: context.zMuted),
                  ),
                ),
              ),
              data: (List<PromptEntry> items) => Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            strings.promptLibrary,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('prompt-sheet-manage'),
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            Navigator.of(hostContext).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PromptLibraryScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.bookmarks_rounded, size: 16),
                          label: Text(strings.edit),
                        ),
                      ],
                    ),
                  ),
                  if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      child: Column(
                        children: <Widget>[
                          Text(
                            strings.promptLibraryEmpty,
                            style: TextStyle(color: context.zMuted),
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            key: const Key('prompt-sheet-open-library'),
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                              Navigator.of(hostContext).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const PromptLibraryScreen(),
                                ),
                              );
                            },
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: Text(strings.newPrompt),
                          ),
                        ],
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        key: const Key('prompt-sheet-list'),
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (BuildContext context, int index) {
                          final PromptEntry entry = items[index];
                          return ListTile(
                            key: Key('prompt-sheet-item-${entry.id}'),
                            dense: true,
                            leading: const Icon(Icons.notes_rounded, size: 18),
                            title: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: entry.content.isEmpty
                                ? null
                                : Text(
                                    entry.content,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              insertText(entry.content);
                              _focus?.requestFocus();
                            },
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// v1.44.0 — mic control: first tap probes availability (lazy init +
  /// runtime RECORD_AUDIO prompt), starts dictation in the app language,
  /// and the next tap stops it. Final recognition results are appended to
  /// the composer text (per-chat draft, so they survive a chat switch);
  /// partials only feed the inline preview row.
  Future<void> toggleMic(BuildContext context) async {
    if (state.listening) {
      await ref.read(speechServiceProvider).stop();
      return;
    }
    final AppStrings strings = stringsOf(context);
    final SpeechService speech = ref.read(speechServiceProvider);
    final SpeechAvailability availability = await speech.ensureReady();
    if (!context.mounted) return;
    if (availability == SpeechAvailability.unavailable) {
      _snack(context, strings.speechUnavailable);
      return;
    }
    if (availability == SpeechAvailability.notAuthorized) {
      _snack(context, strings.speechPermissionDenied);
      return;
    }
    state = state.copyWith(listening: true, speechPartial: '');
    await speech.start(
      localeCode: ref.read(settingsProvider).languageCode,
      onResult: (String text, bool finalResult) {
        if (!finalResult) {
          state = state.copyWith(speechPartial: text);
          return;
        }
        final String trimmed = text.trim();
        if (trimmed.isNotEmpty) insertDictation(trimmed);
        state = state.copyWith(speechPartial: '');
      },
      onEnd: () {
        state = state.copyWith(listening: false, speechPartial: '');
      },
    );
  }

  /// v1.49.0 (wave-2) — the per-chat ACTIVE SKILLS selector: offers the
  /// enabled+ready skills from the registry (wallet skills carry the
  /// badge) and applies the result to the ACTIVE chat through
  /// [ChatController.setActiveSkills]. The sheet's null sentinel ("use
  /// global default") and the explicit empty list both clear the chat's
  /// pinned set — an empty pinned set IS the global default.
  Future<void> openSkillSheet(BuildContext context) async {
    final SkillRegistry registry = ref.read(skillRegistryProvider);
    await registry.ensureCacheLoaded();
    final List<SkillOption> options = <SkillOption>[];
    for (final InstalledSkill skill in registry.listSync()) {
      if (!skill.enabled) continue;
      if (await registry.statusOf(skill) != SkillStatus.ready) continue;
      options.add(
        SkillOption(
          name: skill.name,
          title: skill.title.isEmpty ? skill.name : skill.title,
          description: skill.description,
          wallet: skill.wallet,
        ),
      );
    }
    final List<String> current = ref.read(chatControllerProvider).activeSkills;
    if (!context.mounted) return;
    final List<String>? result = await SkillSelectorSheet.show(
      context,
      options: options,
      currentSelection: current,
    );
    // Barrier dismiss resolves with the caller's selection — nothing to
    // save in that case (the sheet contract guarantees it).
    if (result != null && listEquals(result, current)) return;
    await ref
        .read(chatControllerProvider.notifier)
        .setActiveSkills(result ?? const <String>[]);
  }

  /// Localized snackbar for the image-attachment failure kinds.
  void _showAttachmentError(BuildContext context, AttachmentResult result) {
    final AppStrings strings = stringsOf(context);
    switch (result.errorType) {
      case AttachmentErrorType.tooLarge:
        _snack(context, strings.imageTooLarge);
      case AttachmentErrorType.notAnImage:
        _snack(context, strings.imageNotAnImage);
      case AttachmentErrorType.cancelled:
        break;
      case AttachmentErrorType.saveFailed:
      case null:
        _snack(context, strings.operationFailed);
    }
  }

  void _snack(BuildContext context, String message) {
    if (context.mounted) {
      // v1.49.6: centered message dialog instead of a SnackBar.
      showAppMessage(context, message);
    }
  }
}

/// App-lifetime state + controller of the composer tool actions.
final composerActionsProvider =
    NotifierProvider<ComposerActionsController, ComposerActionsState>(
      ComposerActionsController.new,
    );

/// The four composer TOOL icons — skills / attach file / prompt library /
/// mic — with their stable test keys ('composer-skills', 'attach-button',
/// 'prompt-insert-button', 'mic-button') and the v1.46.0 visual states
/// (picking spinner, red listening stop). The skills multi-select sits
/// EXACTLY LEFT of the attach icon (v1.49.0 user requirement).
///
/// Rendered by the idle composer toolbar AND (compact) by the thinking
/// footer's row during a run — same behaviour everywhere, driven by the
/// shared [composerActionsProvider], so the two placements can never drift.
class ComposerToolIcons extends ConsumerWidget {
  const ComposerToolIcons({super.key, this.compact = false});

  /// Footer mode: dense tap targets + 16 px icons sized to match the plan
  /// show/hide eye sitting to the right of the group.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final ComposerActionsState actions = ref.watch(composerActionsProvider);
    final ComposerActionsController controller = ref.read(
      composerActionsProvider.notifier,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // v1.49.0 (wave-2): per-chat skill multi-select — placed EXACTLY
        // LEFT of the upload/attach icon (user requirement).
        IconButton(
          key: const Key('composer-skills'),
          tooltip: strings.composerSkillsTooltip,
          onPressed: () => controller.openSkillSheet(context),
          visualDensity: compact ? VisualDensity.compact : null,
          constraints: compact
              ? const BoxConstraints(minWidth: 32, minHeight: 32)
              : null,
          padding: compact ? const EdgeInsets.all(6) : null,
          icon: Icon(
            Icons.auto_awesome_rounded,
            size: compact ? 16 : null,
            color: context.zMuted,
          ),
        ),
        IconButton(
          key: const Key('attach-button'),
          tooltip: strings.attachFile,
          onPressed: actions.picking
              ? null
              : () => controller.pickFile(context),
          visualDensity: compact ? VisualDensity.compact : null,
          constraints: compact
              ? const BoxConstraints(minWidth: 32, minHeight: 32)
              : null,
          padding: compact ? const EdgeInsets.all(6) : null,
          icon: actions.picking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  Icons.attach_file_rounded,
                  size: compact ? 16 : null,
                  color: context.zMuted,
                ),
        ),
        IconButton(
          key: const Key('prompt-insert-button'),
          tooltip: strings.insertPrompt,
          onPressed: () => controller.openPromptSheet(context),
          visualDensity: compact ? VisualDensity.compact : null,
          constraints: compact
              ? const BoxConstraints(minWidth: 32, minHeight: 32)
              : null,
          padding: compact ? const EdgeInsets.all(6) : null,
          icon: Icon(
            Icons.notes_rounded,
            size: compact ? 16 : null,
            color: context.zMuted,
          ),
        ),
        IconButton(
          key: const Key('mic-button'),
          tooltip: actions.listening
              ? strings.speechStop
              : strings.speechListen,
          onPressed: () => controller.toggleMic(context),
          visualDensity: compact ? VisualDensity.compact : null,
          constraints: compact
              ? const BoxConstraints(minWidth: 32, minHeight: 32)
              : null,
          padding: compact ? const EdgeInsets.all(6) : null,
          icon: Icon(
            actions.listening ? Icons.stop_rounded : Icons.mic_none_rounded,
            size: compact ? 16 : null,
            color: actions.listening ? const Color(0xFFE5484D) : context.zMuted,
          ),
        ),
      ],
    );
  }
}
