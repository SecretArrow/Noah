import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';

/// Plan card rendered for every `todo_write` tool call (agent-mode
/// style): a header with progress ("2/5 done") + a thin progress bar, then
/// one row per todo with its status icon. The state shown is the one the
/// model wrote in THIS call, so the cards read as a timeline of the plan.
class TodoPlanCard extends StatelessWidget {
  const TodoPlanCard({super.key, required this.call, this.todos});

  final ToolCall call;

  /// Already-parsed plan. [MessageBubble] parses the call arguments once to
  /// decide whether a plan card is warranted; passing the result here
  /// avoids walking up to 50 entries a second time on every rebuild.
  final List<TodoItem>? todos;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final List<TodoItem> items =
        todos ?? parseTodoList(call.arguments['todos']);
    final int total = items.length;
    final int done = items
        .where((TodoItem t) => t.status == TodoStatus.completed)
        .length;
    final ZPalette palette = context.palette;

    return Container(
      key: const Key('todo-plan-card'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.zSurface,
        borderRadius: BorderRadius.circular(kCardRadius),
        border: Border.all(color: context.zBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.checklist_rounded,
                size: 16,
                color: kAccentColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.planTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                strings.planProgress(done, total),
                style: TextStyle(fontSize: 11.5, color: palette.muted),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 3,
                valueColor: const AlwaysStoppedAnimation<Color>(kAccentColor),
                backgroundColor: palette.border,
              ),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                call.name,
                style: TextStyle(fontSize: 11.5, color: palette.muted),
              ),
            )
          else ...<Widget>[
            for (int i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: MergeSemantics(
                  // One TalkBack stop per todo: status + content + reason.
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: _TodoStatusIcon(status: items[i].status),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              items[i].content,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: switch (items[i].status) {
                                  TodoStatus.completed => palette.muted,
                                  TodoStatus.blocked => const Color(0xFFF59E0B),
                                  TodoStatus.inProgress => Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  TodoStatus.pending => palette.muted,
                                },
                                decoration:
                                    items[i].status == TodoStatus.completed
                                    ? TextDecoration.lineThrough
                                    : null,
                                fontWeight:
                                    items[i].status == TodoStatus.inProgress
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (items[i].status == TodoStatus.blocked &&
                          items[i].blockedReason.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 23, top: 2),
                          child: Text(
                            '${strings.todoBlocked}: ${items[i].blockedReason}',
                            key: Key('todo-blocked-reason-$i'),
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.3,
                              color: const Color(0xFFF59E0B),
                            ),
                          ),
                        ),
                      if (items[i].dependsOn.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 23, top: 2),
                          child: Text(
                            '${strings.todoDependsOn} ${items[i].dependsOn.join(', ')}',
                            key: Key('todo-depends-$i'),
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.3,
                              color: palette.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _TodoStatusIcon extends StatelessWidget {
  const _TodoStatusIcon({required this.status});

  final TodoStatus status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case TodoStatus.completed:
        return Icon(
          Icons.check_circle_rounded,
          size: 15,
          color: const Color(0xFF4ADE80),
          semanticLabel: stringsOf(context).todoCompleted,
        );
      case TodoStatus.inProgress:
        // Static glyph on purpose: historical plan cards show the state at
        // the time of the call, so a spinner would be misleading there.
        return Icon(
          Icons.radio_button_checked_rounded,
          size: 15,
          color: kAccentColor,
          semanticLabel: stringsOf(context).todoInProgress,
        );
      case TodoStatus.pending:
        return Icon(
          Icons.radio_button_unchecked_rounded,
          size: 15,
          color: context.palette.muted,
          semanticLabel: stringsOf(context).todoPending,
        );
      case TodoStatus.blocked:
        return Icon(
          Icons.block_rounded,
          size: 15,
          color: const Color(0xFFF59E0B),
          semanticLabel: stringsOf(context).todoBlocked,
        );
    }
  }
}

/// LIVE plan panel shown from the thinking indicator's show/hide toggle.
/// Unlike the historical [TodoPlanCard] this renders the CURRENT plan
/// state — the in-progress step spins so the user can see at any time
/// how far the agent has gotten.
class TodoPlanView extends StatelessWidget {
  const TodoPlanView({
    super.key,
    required this.todos,
    this.live = false,
    this.onClose,
  });

  final List<TodoItem> todos;
  final bool live;

  /// v1.38.0: when set, the header shows a close (X) button — used by the
  /// pinned live Plan panel so the user can close it directly, no matter
  /// whether the thinking footer (and its toggle) is currently mounted.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final int total = todos.length;
    final int done = todos
        .where((TodoItem t) => t.status == TodoStatus.completed)
        .length;
    final ZPalette palette = context.palette;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.zSurface,
        borderRadius: BorderRadius.circular(kCardRadius),
        border: Border.all(color: context.zBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.checklist_rounded,
                size: 16,
                color: kAccentColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.planTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                // v1.48.1: keyed so tests (and the live-progress invariant)
                // can target the counter of the LIVE plan view only — the
                // historical [TodoPlanCard] keeps its unlabeled counter.
                strings.planProgress(done, total),
                key: const Key('plan-progress-label'),
                style: TextStyle(fontSize: 11.5, color: palette.muted),
              ),
              if (onClose != null)
                IconButton(
                  key: const Key('plan-panel-close'),
                  tooltip: strings.hidePlanTooltip,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: palette.muted,
                  ),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: const EdgeInsets.all(5),
                  onPressed: onClose,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 3,
                valueColor: const AlwaysStoppedAnimation<Color>(kAccentColor),
                backgroundColor: palette.border,
              ),
            ),
          ),
          for (int i = 0; i < todos.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: MergeSemantics(
                // One TalkBack stop per todo: status + content + reason.
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: _LiveTodoStatusIcon(
                            status: todos[i].status,
                            live: live,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            todos[i].content,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              color: switch (todos[i].status) {
                                TodoStatus.completed => palette.muted,
                                TodoStatus.blocked => const Color(0xFFF59E0B),
                                TodoStatus.inProgress => Theme.of(
                                  context,
                                ).colorScheme.onSurface,
                                TodoStatus.pending => palette.muted,
                              },
                              decoration:
                                  todos[i].status == TodoStatus.completed
                                  ? TextDecoration.lineThrough
                                  : null,
                              fontWeight:
                                  todos[i].status == TodoStatus.inProgress
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (todos[i].status == TodoStatus.blocked &&
                        todos[i].blockedReason.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 23, top: 2),
                        child: Text(
                          '${strings.todoBlocked}: ${todos[i].blockedReason}',
                          key: Key('todo-blocked-reason-$i'),
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.3,
                            color: const Color(0xFFF59E0B),
                          ),
                        ),
                      ),
                    if (todos[i].dependsOn.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 23, top: 2),
                        child: Text(
                          '${strings.todoDependsOn} ${todos[i].dependsOn.join(', ')}',
                          key: Key('todo-depends-$i'),
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.3,
                            color: palette.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Status icon for the live plan panel: identical to [_TodoStatusIcon]
/// except that the in-progress step renders as a small spinner while the
/// run is active.
class _LiveTodoStatusIcon extends StatelessWidget {
  const _LiveTodoStatusIcon({required this.status, required this.live});

  final TodoStatus status;
  final bool live;

  @override
  Widget build(BuildContext context) {
    if (live && status == TodoStatus.inProgress) {
      return SizedBox(
        width: 14,
        height: 14,
        child: Padding(
          padding: const EdgeInsets.all(1),
          // l10n: no todo-status strings exist yet.
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: stringsOf(context).todoInProgress,
          ),
        ),
      );
    }
    return _TodoStatusIcon(status: status);
  }
}
