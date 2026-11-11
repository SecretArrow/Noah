import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../models/models.dart';
import '../../services/agent_controller.dart' show ChatController, ChatState;
import 'empty_state.dart';
import 'message_bubble.dart';
import 'plan_panel.dart';

/// Message list (bottom-anchored via reverse ListView) or empty state.
///
/// v1.39.0 perf: this widget still watches the whole [ChatState] (the
/// transcript itself is the payload), but every row is memoized through
/// [_MessageRow], which returns the IDENTICAL [MessageBubble] instance
/// while its inputs are unchanged. `Element.updateChild` short-circuits on
/// an identical child widget, so a streaming sync (~20/s) now rebuilds
/// only the tail bubble instead of every visible bubble plus its markdown,
/// tool cards and copy buttons.
class ChatBody extends ConsumerWidget {
  const ChatBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ChatState state = ref.watch(chatControllerProvider);
    // v1.48.1: the user must SEE plan progress — the FIRST todo_write of a
    // run (todos empty → non-empty while the run is active) auto-reveals
    // the pinned Plan panel. Idle transitions (e.g. opening a saved chat
    // from disk, isRunning false) never yank it open, and a later
    // todo_write in the same run never re-opens it after the user closed
    // it — only the empty→non-empty transition counts. ChatBody only
    // exists for the on-screen chat, so background sessions can't fire it.
    ref.listen<ChatState>(chatControllerProvider, (
      ChatState? prev,
      ChatState next,
    ) {
      final bool planJustAppeared =
          (prev == null || prev.todos.isEmpty) &&
          next.todos.isNotEmpty &&
          next.isRunning &&
          !ref.read(planPanelOpenProvider);
      if (planJustAppeared) {
        ref.read(planPanelOpenProvider.notifier).state = true;
      }
    });
    if (state.isLoading && state.messages.isEmpty) {
      // Opening a stored chat: show a spinner instead of the previous
      // chat's transcript (which used to linger for the whole disk read).
      return const Center(
        key: Key('chat-loading'),
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (state.messages.isEmpty) {
      return const EmptyState();
    }

    // Edit/regenerate visibility (v1.15.0): the edit button shows on every
    // non-empty USER bubble while the session is idle; the regenerate
    // button only under the LAST assistant bubble when a preceding user
    // message exists. Both hide while the agent is running.
    final String? sessionId = state.sessionId;
    final bool idle = !state.isRunning && sessionId != null;
    final int lastAssistantIndex = state.messages.lastIndexWhere(
      (ChatMessage m) => m.role == Role.assistant,
    );
    // Computed ONCE per build instead of a take().any() scan per row.
    final bool hasUserBeforeLastAssistant =
        lastAssistantIndex > 0 &&
        state.messages
            .take(lastAssistantIndex)
            .any((ChatMessage m) => m.role == Role.user);
    final ChatController controller = ref.read(chatControllerProvider.notifier);
    final int count = state.messages.length;

    // v1.38.0: the live Plan panel is PINNED above the list and driven by
    // the global planPanelOpenProvider — it never closes on streaming
    // updates, step transitions, run end or chat switching (see PlanPanel).
    return Column(
      children: <Widget>[
        const PlanPanel(),
        Expanded(
          child: ListView.builder(
            key: const Key('message-list'),
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: count,
            itemBuilder: (BuildContext context, int index) {
              // The list is reversed: translate back to the transcript
              // index the controller uses for editUserMessage. Indexed
              // directly — no reversed copy allocation per sync.
              final int messageIndex = count - 1 - index;
              final ChatMessage message = state.messages[messageIndex];
              final bool isTail = index == 0;
              return _MessageRow(
                key: ValueKey<String>(message.id),
                message: message,
                messageIndex: messageIndex,
                sessionId: sessionId,
                controller: controller,
                idle: idle,
                canEdit:
                    idle &&
                    message.role == Role.user &&
                    message.content.trim().isNotEmpty,
                canRegenerate:
                    idle &&
                    hasUserBeforeLastAssistant &&
                    messageIndex == lastAssistantIndex,
                // The thinking footer (and its plan toggle) only exists on
                // the tail bubble — passing the live plan to every row
                // would rebuild the whole visible history on each
                // todo_write.
                agentWorking: state.isRunning && isTail,
                todos: isTail ? state.todos : const <TodoItem>[],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Memoizing wrapper around [MessageBubble].
///
/// It builds its child once and returns the SAME widget instance on
/// subsequent builds unless one of its inputs actually changed, which
/// lets Flutter skip the entire bubble subtree. Callbacks are created
/// here (not passed in) so their identity never defeats the comparison.
class _MessageRow extends StatefulWidget {
  const _MessageRow({
    super.key,
    required this.message,
    required this.messageIndex,
    required this.sessionId,
    required this.controller,
    required this.idle,
    required this.canEdit,
    required this.canRegenerate,
    required this.agentWorking,
    required this.todos,
  });

  final ChatMessage message;
  final int messageIndex;
  final String? sessionId;
  final ChatController controller;
  final bool idle;
  final bool canEdit;
  final bool canRegenerate;
  final bool agentWorking;
  final List<TodoItem> todos;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  Widget? _built;

  @override
  void didUpdateWidget(covariant _MessageRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.message, widget.message) ||
        oldWidget.messageIndex != widget.messageIndex ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.controller != widget.controller ||
        oldWidget.idle != widget.idle ||
        oldWidget.canEdit != widget.canEdit ||
        oldWidget.canRegenerate != widget.canRegenerate ||
        oldWidget.agentWorking != widget.agentWorking ||
        !identical(oldWidget.todos, widget.todos)) {
      _built = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _built ??= _build(context);
  }

  Widget _build(BuildContext context) {
    final String? sessionId = widget.sessionId;
    final bool canEdit = widget.canEdit && sessionId != null;
    final bool canRegenerate = widget.canRegenerate && sessionId != null;
    return MessageBubble(
      message: widget.message,
      todos: widget.todos,
      agentWorking: widget.agentWorking,
      onEdit: canEdit
          ? (String newText) => widget.controller.editUserMessage(
              sessionId,
              widget.messageIndex,
              newText,
            )
          : null,
      onRegenerate: canRegenerate
          ? () => widget.controller.regenerate(sessionId)
          : null,
    );
  }
}
