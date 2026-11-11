import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../services/module_registry.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../screens/modules_screen.dart';
import 'composer_actions.dart';
import '../theme.dart';
import 'app_message.dart';

/// Bottom composer: attachment chips, pill-shaped input, send / stop
/// button. The paperclip copies the picked file into the app's
/// uploads folder and stages it for the next message.
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key});

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// v1.42.0 — consecutive Stop taps while the SAME run is still active.
  /// 1 tap = graceful stop; tap 2 asks again + hints; tap 3 opens the
  /// force-stop offer dialog. Reset whenever the running flag flips (run
  /// ended, or a new run started), so counts never leak across runs.
  int _stopTaps = 0;

  /// v1.38.1 — the chat this text field is currently bound to (null =
  /// fresh draft). Typed text is stored per chat in the controller, so
  /// switching chats swaps the draft and one chat's text never appears
  /// in another.
  String? _boundSession;

  /// v1.48.0 — the shared tool-action controller, captured in initState
  /// while `ref` is still usable, so dispose can unbind the field WITHOUT
  /// touching `ref` (riverpod forbids ref reads after unmount).
  ComposerActionsController? _actions;

  @override
  void initState() {
    super.initState();
    // v1.48.0 — the shared tool-action controller writes prompt inserts
    // and dictation finals straight into this field (caret + focus
    // handled there); this widget is the single owner of the controller.
    _actions = ref.read(composerActionsProvider.notifier);
    _actions!.bindField(_controller, _focusNode);
    _boundSession = ref.read(chatControllerProvider).sessionId;
    _controller.text = ref
        .read(chatControllerProvider.notifier)
        .draftTextFor(_boundSession);
    _controller.addListener(() {
      ref
          .read(chatControllerProvider.notifier)
          .setDraftText(_boundSession, _controller.text);
    });
  }

  /// Re-binds the field to another chat: the old text is already saved by
  /// the listener; load the target chat's own draft (never another's).
  void _rebind(String? session) {
    if (_boundSession == session) return;
    _boundSession = session;
    final String draft = ref
        .read(chatControllerProvider.notifier)
        .draftTextFor(session);
    if (_controller.text == draft) return;
    _controller.text = draft;
    _controller.selection = TextSelection.collapsed(offset: draft.length);
  }

  @override
  void dispose() {
    // Unbind BEFORE the field dies, so a late insertion degrades to the
    // per-chat draft store instead of touching a disposed controller.
    // Uses the initState-captured controller — `ref` is NOT usable here.
    _actions?.unbindField(_controller);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final String text = _controller.text.trim();
    final List<ChatAttachment> attachments = ref.read(
      pendingAttachmentsProvider,
    );
    if (text.isEmpty && attachments.isEmpty) return;
    // Slash commands are consumed LOCALLY — they never reach the LLM.
    if (text == '/plugins') {
      _controller.clear();
      FocusScope.of(context).unfocus();
      _openModuleSheet();
      return;
    }
    if (text.startsWith('/plugins ')) {
      final String moduleName = text.substring('/plugins '.length).trim();
      _controller.clear();
      FocusScope.of(context).unfocus();
      _activateNamedModule(moduleName);
      return;
    }
    _controller.clear();
    ref.read(pendingAttachmentsProvider.notifier).state =
        const <ChatAttachment>[];
    FocusScope.of(context).unfocus();
    ref
        .read(chatControllerProvider.notifier)
        .send(text, attachments: attachments);
  }

  /// `/plugins name`: resolves the module, asks for permission consent
  /// (when the manifest declares capabilities) and activates it for the
  /// current chat. Unknown names surface a localized snackbar.
  Future<void> _activateNamedModule(String name) async {
    if (name.isEmpty) {
      _openModuleSheet();
      return;
    }
    final AppStrings strings = stringsOf(context);
    final ChatModule? module = await ref.read(moduleRegistryProvider).get(name);
    if (!mounted) return;
    if (module == null) {
      showAppMessage(context, strings.moduleNotFound(name));
      return;
    }
    if (!await ModulesScreen.confirmPermissions(context, ref, module)) {
      return;
    }
    if (!mounted) return;
    await ref.read(chatControllerProvider.notifier).activateModule(module.name);
  }

  /// Interactive module menu for `/plugins`: every installed module with
  /// its active state; tapping activates (with consent) in the current
  /// chat, the trailing trash button removes (uninstalls) the module
  /// after confirmation, and a footer shortcut opens the Modules manager.
  Future<void> _openModuleSheet() async {
    final AppStrings strings = stringsOf(context);
    ref.invalidate(moduleListProvider);
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => Consumer(
        builder: (BuildContext context, WidgetRef sheetRef, _) {
          final AsyncValue<List<ChatModule>> modules = sheetRef.watch(
            moduleListProvider,
          );
          final List<String> active = sheetRef.watch(
            chatControllerProvider.select((s) => s.activeModules),
          );
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          strings.pluginMenuTitle,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('plugin-sheet-manage'),
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          Navigator.of(this.context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ModulesScreen(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.extension_rounded, size: 16),
                        label: Text(strings.modulesManage),
                      ),
                    ],
                  ),
                ),
                modules.when(
                  loading: () => const SizedBox(
                    height: 120,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
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
                  data: (List<ChatModule> items) => items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                          child: Column(
                            children: <Widget>[
                              Text(
                                strings.pluginMenuEmpty,
                                style: TextStyle(color: context.zMuted),
                              ),
                              const SizedBox(height: 8),
                              TextButton.icon(
                                key: const Key('plugin-sheet-open-modules'),
                                onPressed: () {
                                  Navigator.of(sheetContext).pop();
                                  Navigator.of(this.context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const ModulesScreen(),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.add_rounded, size: 16),
                                label: Text(strings.modulesInstall),
                              ),
                            ],
                          ),
                        )
                      : Flexible(
                          child: ListView.builder(
                            key: const Key('plugin-sheet-list'),
                            shrinkWrap: true,
                            itemCount: items.length,
                            itemBuilder: (BuildContext context, int index) {
                              final ChatModule module = items[index];
                              final bool isActive = active.contains(
                                module.name,
                              );
                              return ListTile(
                                key: Key('plugin-sheet-item-${module.name}'),
                                dense: true,
                                leading: Icon(
                                  isActive
                                      ? Icons.check_circle_rounded
                                      : Icons.extension_rounded,
                                  size: 20,
                                  color: isActive ? null : context.zMuted,
                                ),
                                title: Text(
                                  module.manifest.title.isEmpty
                                      ? module.name
                                      : module.manifest.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: module.manifest.description.isEmpty
                                    ? null
                                    : Text(
                                        module.manifest.description,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text(
                                      'v${module.manifest.version}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: context.zMuted,
                                      ),
                                    ),
                                    IconButton(
                                      key: Key(
                                        'plugin-sheet-remove-${module.name}',
                                      ),
                                      tooltip: strings.delete,
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                        color: context.zMuted,
                                      ),
                                      onPressed: () =>
                                          _removeModule(sheetRef, module),
                                    ),
                                  ],
                                ),
                                onTap: () async {
                                  final NavigatorState sheetNav = Navigator.of(
                                    sheetContext,
                                  );
                                  if (isActive) {
                                    await sheetRef
                                        .read(chatControllerProvider.notifier)
                                        .deactivateModule(module.name);
                                    sheetNav.pop();
                                    return;
                                  }
                                  if (!await ModulesScreen.confirmPermissions(
                                    this.context,
                                    sheetRef,
                                    module,
                                  )) {
                                    return;
                                  }
                                  await sheetRef
                                      .read(chatControllerProvider.notifier)
                                      .activateModule(module.name);
                                  sheetNav.pop();
                                },
                              );
                            },
                          ),
                        ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Uninstalls a module straight from the `/plugins` sheet: confirm →
  /// deactivate in the current chat (when active) → delete from the
  /// registry → refresh the list. The sheet stays open so the user can
  /// continue managing modules.
  Future<void> _removeModule(WidgetRef sheetRef, ChatModule module) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(strings.moduleRemoveTitle),
        content: Text(strings.moduleRemoveBody(module.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final bool removed = await sheetRef
        .read(moduleRegistryProvider)
        .remove(module.name);
    if (!removed) return;
    if (sheetRef
        .read(chatControllerProvider)
        .activeModules
        .contains(module.name)) {
      await sheetRef
          .read(chatControllerProvider.notifier)
          .deactivateModule(module.name);
    }
    sheetRef.invalidate(moduleListProvider);
    if (!mounted) return;
    // v1.49.6: centered message dialog instead of a SnackBar — the composer
    // must not jump while the keyboard is open.
    showAppMessage(context, strings.moduleRemoved(module.name));
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final bool isRunning = ref.watch(
      chatControllerProvider.select((s) => s.isRunning),
    );
    // v1.42.0: the tap counter is only meaningful within one run — any
    // running-state change (run ended or a new run began) starts fresh.
    ref.listen<bool>(chatControllerProvider.select((s) => s.isRunning), (
      bool? previous,
      bool next,
    ) {
      if (previous != next && _stopTaps != 0) _stopTaps = 0;
    });
    // v1.38.1: swap the draft text when the displayed chat changes.
    ref.listen<String?>(
      chatControllerProvider.select((s) => s.sessionId),
      (String? previous, String? current) => _rebind(current),
    );
    // v1.44.0: dictation belongs to the chat it was started in — a chat
    // switch ends the speech session instead of letting the final words
    // land in another chat's draft. The dictation STATE lives in the
    // shared [composerActionsProvider] (v1.48.0), so the guard reads it.
    ref.listen<String?>(chatControllerProvider.select((s) => s.sessionId), (
      String? previous,
      String? current,
    ) {
      if (previous != current && ref.read(composerActionsProvider).listening) {
        ref.read(speechServiceProvider).stop();
      }
    });
    // A chat whose history is still being read has no runnable transcript
    // yet — sending now would fork a duplicate session (see ChatController
    // .send), so the send control is disabled until the load lands.
    final bool isLoading = ref.watch(
      chatControllerProvider.select((s) => s.isLoading),
    );
    final List<ChatAttachment> pending = ref.watch(pendingAttachmentsProvider);
    // v1.48.0 — the composer tool actions (attach / prompt library / mic)
    // moved into the shared [composerActionsProvider]; while a run
    // streams the toolbar row disappears entirely and the SAME three
    // icons render on the thinking footer's row, immediately LEFT of the
    // plan show/hide eye. The composer-side plan eye is DELETED — the
    // thinking footer's eye is the only show/hide control.
    final ComposerActionsState actions = ref.watch(composerActionsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // v1.44.0: live dictation preview — the partial transcript while
          // the mic is open, so the user sees the phone is listening.
          if (actions.listening)
            Padding(
              key: const Key('speech-listening-row'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 16,
                    color: context.zMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      actions.speechPartial.isEmpty
                          ? stringsOf(context).speechListening
                          : actions.speechPartial,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: context.zMuted),
                    ),
                  ),
                ],
              ),
            ),
          if (pending.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                key: const Key('pending-attachments'),
                scrollDirection: Axis.horizontal,
                shrinkWrap: true,
                children: <Widget>[
                  for (final ChatAttachment att in pending)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        avatar: Icon(
                          att.kind == AttachmentKind.image
                              ? Icons.image_rounded
                              : Icons.insert_drive_file_rounded,
                          size: 16,
                          color: context.zMuted,
                        ),
                        label: Text(
                          att.name,
                          style: const TextStyle(fontSize: 11),
                        ),
                        backgroundColor: context.zSurfaceAlt,
                        side: BorderSide(color: context.zBorder),
                        onDeleted: () {
                          ref
                              .read(pendingAttachmentsProvider.notifier)
                              .state = ref
                              .read(pendingAttachmentsProvider)
                              .where((ChatAttachment a) => a.path != att.path)
                              .toList();
                        },
                      ),
                    ),
                ],
              ),
            ),
          // v1.48.0 — idle TOOLBAR: the three tool icons stay reachable
          // while no run is active (no plan eye anymore). WHILE RUNNING
          // the row is removed from the tree: the icons render on the
          // thinking footer instead — exactly one copy on screen.
          if (!isRunning) Row(children: <Widget>[const ComposerToolIcons()]),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('composer-field'),
                  controller: _controller,
                  focusNode: _focusNode,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  // Pill composer on a surface fill; light mode adds the
                  // subtle hairline border, dark mode stays borderless.
                  decoration: InputDecoration(
                    hintText: strings.askAnything,
                    filled: true,
                    fillColor: context.zSurface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(kComposerRadius),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(kComposerRadius),
                      borderSide:
                          Theme.of(context).brightness == Brightness.light
                          ? BorderSide(color: context.zBorder)
                          : BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(kComposerRadius),
                      borderSide: const BorderSide(color: kAccentColor),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  gradient: isRunning || isLoading ? null : kBrandGradient,
                  // v1.30.0: the Stop button is clearly red — it must read
                  // as an interrupt control, not a disabled send button.
                  color: isRunning
                      ? const Color(0xFFE5484D)
                      : (isLoading ? context.zSurfaceAlt : null),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  key: Key(isRunning ? 'stop-button' : 'send-button'),
                  onPressed: isLoading
                      ? null
                      : (isRunning ? _handleStopPressed : _submit),
                  icon: isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          isRunning
                              ? Icons.stop_rounded
                              : Icons.arrow_upward_rounded,
                          color: Colors.white,
                        ),
                  tooltip: isRunning ? strings.stop : strings.send,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// v1.42.0 — 1 tap stops the process (graceful); the 2nd tap asks again
  /// and hints; after the 3rd tap the force-stop offer is shown. Every tap
  /// (re)arms the cooperative stop, so the loop keeps exiting as early as
  /// it can while the user escalates.
  void _handleStopPressed() {
    _stopTaps++;
    ref.read(chatControllerProvider.notifier).stop();
    if (_stopTaps >= 3) {
      _stopTaps = 0;
      _showForceStopDialog();
    } else if (_stopTaps == 2) {
      showAppMessage(
        context,
        stringsOf(context).stopHintForce,
        key: const Key('stop-hint-snack'),
        duration: const Duration(seconds: 3),
      );
    }
  }

  /// Third-tap offer: force-stops ONLY after an explicit confirmation —
  /// a mis-tap must never kill a healthy run.
  Future<void> _showForceStopDialog() async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('force-stop-dialog'),
        title: Text(strings.forceStopTitle),
        content: Text(strings.forceStopBody),
        actions: <Widget>[
          TextButton(
            key: const Key('force-stop-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.forceStopCancel),
          ),
          FilledButton(
            key: const Key('force-stop-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE5484D),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.forceStopConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    ref.read(chatControllerProvider.notifier).forceStop();
    showAppMessage(
      context,
      stringsOf(context).forceStopDone,
      key: const Key('force-stop-done-snack'),
      duration: const Duration(seconds: 3),
    );
  }
}
