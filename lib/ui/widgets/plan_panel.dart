import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../models/models.dart';
import '../../services/agent_controller.dart' show ChatState;
import 'todo_plan_card.dart';

/// v1.38.0: PINNED live Plan panel rendered by [ChatBody] above the
/// message list.
///
/// Why pinned instead of inline under the thinking footer: the footer is
/// a per-message decoration that unmounts on every agent step transition
/// (the "working" marker moves to the newest bubble), at run end, and on
/// chat switches — each unmount silently closed the panel the user had
/// opened, and streamed updates re-created it collapsed. The pinned panel
/// instead:
///   * opens/closes ONLY through the user's own toggle (footer icon,
///     panel close button) — state lives in [planPanelOpenProvider];
///   * updates in REAL time — it watches the active session's todos,
///     so every `todo_write` during the run re-renders it immediately;
///   * stays open across chat switches — the active chat's plan is
///     always what it shows, so a background session's progress never
///     leaks into another chat's panel.
/// When the displayed session has no plan the panel renders nothing
/// (the open state is kept, so switching back restores it).
///
/// v1.41.6: WHILE the agent is running the plan renders INLINE again —
/// directly above the thinking row inside the tail bubble (the v1.36
/// placement, user request) — so this pinned host steps aside during a
/// run to avoid a double render. The open flag is untouched by the
/// switch: the moment the run ends (footer unmounts) the pinned panel
/// reappears on its own, and chat switches never close it.
class PlanPanel extends ConsumerWidget {
  const PlanPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool open = ref.watch(planPanelOpenProvider);
    final bool running = ref.watch(
      chatControllerProvider.select((ChatState s) => s.isRunning),
    );
    final List<TodoItem> todos = ref.watch(
      chatControllerProvider.select((ChatState s) => s.todos),
    );
    // While the agent runs the thinking footer owns the inline render
    // (above the thinking row); when idle this pinned panel is the host.
    final bool visible = open && todos.isNotEmpty && !running;
    return AnimatedSize(
      key: const Key('plan-panel-host'),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: visible
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TodoPlanView(
                key: const Key('live-todo-panel'),
                todos: todos,
                live: true,
                onClose: () =>
                    ref.read(planPanelOpenProvider.notifier).state = false,
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

/// Convenience toggle for the footer's show/hide icon — flips the global
/// open state without rebuilding anything else.
void togglePlanPanel(WidgetRef ref) {
  final StateController<bool> controller = ref.read(
    planPanelOpenProvider.notifier,
  );
  controller.state = !controller.state;
}
