import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';
import 'composer_actions.dart';
import 'plan_panel.dart';
import 'todo_plan_card.dart';
import 'tool_call_card.dart';

/// One chat message: user (blue bubble, right, with attachment
/// previews) or assistant (soft gray bubble, left, markdown + tool cards).
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.todos = const <TodoItem>[],
    this.agentWorking = false,
    this.onEdit,
    this.onRegenerate,
  });

  final ChatMessage message;

  /// Latest plan of the running session — powers the show/hide panel next
  /// to the thinking indicator.
  final List<TodoItem> todos;

  /// True when the session's agent loop is active AND this bubble is the
  /// newest message: keeps the thinking indicator (and its plan toggle)
  /// visible while tools execute, not just while text streams.
  final bool agentWorking;

  /// Invoked with the new text when the user saves the edit dialog on a
  /// USER bubble. Null hides the edit button entirely (running session,
  /// empty content or no editable session).
  final ValueChanged<String>? onEdit;

  /// Invoked when the user taps the regenerate button under the LAST
  /// ASSISTANT bubble. Null hides the button entirely.
  final VoidCallback? onRegenerate;

  /// Tool call → card. `todo_write` renders as a plan card when it carries
  /// at least one todo; the parsed list is reused by the card instead of
  /// being parsed a second time inside it.
  Widget _toolCard(ToolCall call) {
    if (call.name == 'todo_write') {
      final List<TodoItem> todos = parseTodoList(call.arguments['todos']);
      if (todos.isNotEmpty) return TodoPlanCard(call: call, todos: todos);
    }
    return ToolCallCard(call: call);
  }

  @override
  Widget build(BuildContext context) {
    if (message.role == Role.user) {
      final bool hasText = message.content.trim().isNotEmpty;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                // v1.38.0: sizeOf subscribes ONLY to size changes — the
                // full MediaQuery.of also fired on keyboard inset
                // animation frames, rebuilding every visible bubble.
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.8,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(kBubbleRadius),
                    topRight: Radius.circular(kBubbleTailRadius),
                    bottomLeft: Radius.circular(kBubbleRadius),
                    bottomRight: Radius.circular(kBubbleRadius),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (message.attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            for (final ChatAttachment att
                                in message.attachments)
                              _AttachmentPreview(attachment: att),
                          ],
                        ),
                      ),
                    if (message.content.trim().isNotEmpty)
                      SelectableText(
                        message.content,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          height: 1.4,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (hasText)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (onEdit != null)
                    _EditButton(initialText: message.content, onEdit: onEdit!),
                  _CopyButton(text: message.content),
                ],
              ),
          ],
        ),
      );
    }

    final bool hasToolCards = message.toolCalls.isNotEmpty;
    final bool showContent = message.content.trim().isNotEmpty;
    // No copy control while the answer is still streaming — it appears
    // together with the final text (and never on text-less tool bubbles).
    final bool canCopy = showContent && !message.isStreaming;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.88,
              ),
              padding: EdgeInsets.fromLTRB(
                hasToolCards ? 10 : 14,
                10,
                hasToolCards ? 10 : 14,
                hasToolCards ? 6 : 10,
              ),
              decoration: BoxDecoration(
                color: context.zSurfaceAlt,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(kBubbleTailRadius),
                  topRight: Radius.circular(kBubbleRadius),
                  bottomLeft: Radius.circular(kBubbleRadius),
                  bottomRight: Radius.circular(kBubbleRadius),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (message.moduleName != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(Icons.extension_rounded, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            message.moduleName!,
                            key: Key('module-badge-${message.moduleName}'),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final ToolCall call in message.toolCalls)
                    _toolCard(call),
                  if (showContent)
                    _MemoMarkdown(
                      // v1.38.0: keyed on the streaming flag — the flip at
                      // finalize swaps the (now selectable) rendering with a
                      // single fresh parse instead of streaming with one.
                      key: ValueKey<bool>(message.isStreaming),
                      data: message.content,
                      streaming: message.isStreaming,
                    ),
                  if (message.isStreaming ||
                      (agentWorking && message.role == Role.assistant))
                    _ThinkingFooter(todos: todos),
                ],
              ),
            ),
          ),
          if (canCopy) _CopyButton(text: message.content),
          if (onRegenerate != null)
            _RegenerateButton(onRegenerate: onRegenerate!),
        ],
      ),
    );
  }
}

/// Small edit control under a USER bubble: opens a multiline dialog
/// pre-filled with the sent text; saving triggers editUserMessage, which
/// truncates everything after the message and regenerates the answer.
class _EditButton extends StatelessWidget {
  const _EditButton({required this.initialText, required this.onEdit});

  /// The message's current text — pre-fills the edit dialog.
  final String initialText;

  final ValueChanged<String> onEdit;

  Future<void> _openDialog(BuildContext context) async {
    final String? newText = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _EditMessageDialog(initialText: initialText),
    );
    if (newText != null && newText.trim().isNotEmpty) {
      onEdit(newText);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return IconButton(
      key: const Key('edit-message-button'),
      tooltip: strings.editMessageAction,
      onPressed: () => _openDialog(context),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      icon: Icon(Icons.edit_rounded, size: 15, color: context.zMuted),
    );
  }
}

/// The edit form itself. It OWNS its [TextEditingController] so the
/// controller lives exactly as long as the dialog route: disposing it right
/// after `showDialog` returns is too early — the route is still animating
/// out and rebuilds its [TextField] during that transition, which throws
/// "A TextEditingController was used after being disposed".
class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initialText});

  final String initialText;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return AlertDialog(
      backgroundColor: context.zSurface,
      title: Text(strings.editDialogTitle),
      content: TextField(
        key: const Key('edit-message-field'),
        controller: _controller,
        autofocus: true,
        maxLines: 5,
        minLines: 2,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('edit-message-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(strings.save),
        ),
      ],
    );
  }
}

/// Regenerate control under the LAST assistant bubble: one tap drops the
/// answer and replays the conversation from the preceding user message.
class _RegenerateButton extends StatelessWidget {
  const _RegenerateButton({required this.onRegenerate});

  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return IconButton(
      key: const Key('regenerate-button'),
      tooltip: strings.regenerate,
      onPressed: onRegenerate,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      icon: Icon(Icons.refresh_rounded, size: 16, color: context.zMuted),
    );
  }
}

/// Small copy control rendered under every message bubble (sent and
/// received): one tap puts the raw text on the clipboard and the icon
/// flips to a check mark for a moment as confirmation.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  /// Text placed on the clipboard (verbatim, unformatted).
  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _resetTimer;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return IconButton(
      key: const Key('copy-message-button'),
      tooltip: _copied ? strings.copied : strings.copyMessage,
      onPressed: _copy,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: Icon(
          _copied ? Icons.check_rounded : Icons.copy_rounded,
          key: ValueKey<bool>(_copied),
          size: 15,
          color: _copied ? const Color(0xFF4CC38A) : context.zMuted,
        ),
      ),
    );
  }
}

/// Footer row under a working assistant message: spinner + "thinking…"
/// on the left; on the right — the three composer TOOL icons (attach /
/// prompt library / mic, v1.48.0: they live HERE while a run streams —
/// the composer toolbar hides so there is exactly one copy on screen) and
/// — as soon as the agent has written a plan — a right-aligned show/hide
/// toggle for the PINNED live Plan panel (v1.38.0: the toggle flips the
/// global [planPanelOpenProvider]; the panel itself renders above the
/// message list, so it survives streaming rebuilds, step transitions,
/// run end and chat switching).
class _ThinkingFooter extends ConsumerStatefulWidget {
  const _ThinkingFooter({required this.todos});

  final List<TodoItem> todos;

  @override
  ConsumerState<_ThinkingFooter> createState() => _ThinkingFooterState();
}

class _ThinkingFooterState extends ConsumerState<_ThinkingFooter> {
  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final bool hasPlan = widget.todos.isNotEmpty;
    final bool open = ref.watch(planPanelOpenProvider);
    // v1.41.6 — the live plan is rendered INLINE again, directly ABOVE the
    // thinking row (like v1.36 and below), instead of only in the pinned
    // top panel. The open/close state stays GLOBAL (planPanelOpenProvider)
    // — the v1.36 bug was the footer's LOCAL _expanded flag dying on step
    // transitions, not inline rendering itself — so step transitions, run
    // end and chat switches can no longer close it behind the user's back.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (open && hasPlan)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TodoPlanView(
              key: const Key('live-todo-panel'),
              todos: widget.todos,
              live: true,
              onClose: () =>
                  ref.read(planPanelOpenProvider.notifier).state = false,
            ),
          ),
        Row(
          children: <Widget>[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              strings.thinking,
              style: TextStyle(color: context.zMuted, fontSize: 12),
            ),
            const Spacer(),
            // v1.48.0 — the attach / prompt library / mic icons sit ON the
            // thinking row ("lurus dengan thinking"), immediately LEFT of
            // the plan eye. Compact density so the group matches the eye's
            // 16 px icon sizing; taps drive the shared composer actions.
            const ComposerToolIcons(compact: true),
            if (hasPlan)
              IconButton(
                key: const Key('todo-toggle-button'),
                tooltip: open
                    ? strings.hidePlanTooltip
                    : strings.showPlanTooltip,
                icon: Icon(
                  open
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16,
                  color: context.zMuted,
                ),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: const EdgeInsets.all(6),
                onPressed: () => togglePlanPanel(ref),
              ),
          ],
        ),
      ],
    );
  }
}

/// v1.38.0: markdown body with a STABLE style sheet.
///
/// The style sheet used to be constructed inline on every build, so
/// flutter_markdown's update check (`data != old || styleSheet != old`)
/// ALWAYS saw a new object and re-parsed the markdown of EVERY visible
/// bubble on every provider emission — ~20x/second while streaming, for
/// the growing answer AND every history bubble on screen (parse runs on
/// the UI isolate; selectable additionally built SelectableText blocks).
/// The sheet is now built once per theme change and reused, so only
/// bubbles whose text actually changed re-parse.
class _MemoMarkdown extends StatefulWidget {
  const _MemoMarkdown({super.key, required this.data, required this.streaming});

  final String data;
  final bool streaming;

  @override
  State<_MemoMarkdown> createState() => _MemoMarkdownState();
}

class _MemoMarkdownState extends State<_MemoMarkdown> {
  MarkdownStyleSheet? _sheet;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheet = MarkdownStyleSheet(
      p: TextStyle(
        fontSize: 15,
        height: 1.5,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      h1: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      h2: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      h3: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      codeblockDecoration: BoxDecoration(
        color: context.zBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.zBorder),
      ),
      code: TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFFB8C4FF)
            : const Color(0xFF3D51B4),
      ),
      listBullet: TextStyle(
        fontSize: 15,
        height: 1.5,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      // Selection affordance only on FINAL text: building selectable text
      // blocks on every streaming sync is one of the heaviest frame costs,
      // and the text can still be copied through the copy button.
      selectable: !widget.streaming,
      data: widget.data,
      styleSheet: _sheet,
    );
  }
}

/// Inline preview of a sent attachment inside the user bubble: a small
/// image thumbnail or a file chip.
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.attachment});

  final ChatAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.kind == AttachmentKind.image) {
      final File file = File(attachment.path);
      // v1.38.0: cacheWidth caps the decode resolution — a full-res photo
      // (4000x3000) used to be decoded for a 120dp thumbnail on every
      // visible scroll pass (jank + memory spikes). Decode at the box's
      // physical resolution instead.
      final int cacheWidth = (120 * MediaQuery.devicePixelRatioOf(context))
          .round();
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        // v1.39.0: no `existsSync()` pre-check — that was a blocking
        // syscall on the UI thread for every image of every visible bubble
        // on every rebuild. `errorBuilder` already renders the placeholder
        // when the file is gone.
        child: Image.file(
          file,
          width: 120,
          height: 120,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          // TalkBack announces the attachment by its file name instead of
          // focusing an unlabeled image node.
          semanticLabel: attachment.name,
          errorBuilder: (_, _, _) => Container(
            width: 120,
            height: 120,
            color: Colors.white24,
            alignment: Alignment.center,
            child: const Icon(
              Icons.broken_image_rounded,
              color: Colors.white70,
            ),
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.insert_drive_file_rounded,
            size: 14,
            color: Colors.white,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
