import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';
import '../widgets/app_message.dart';
import '../widgets/paged_list.dart';

/// Goals (v1.50.0): the user tracks their goals (title, detail, progress,
/// status, optional due date) and the agent sees the active ones in its
/// system prompt. Overdue / due-soon goals are flagged in the list.
class GoalsScreen extends ConsumerStatefulWidget {
  const GoalsScreen({super.key});

  @override
  ConsumerState<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends ConsumerState<GoalsScreen> {
  String get _sessionId => ref.read(activeSessionIdProvider) ?? '';

  Future<void> _refresh() async {
    ref.invalidate(goalListProvider(_sessionId));
    if (mounted) setState(() {});
  }

  Future<void> _delete(GoalEntry goal) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: const Text('Delete goal?'),
        content: const Text('This goal will be removed.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(goalServiceProvider).remove(_sessionId, goal.id);
    await _refresh();
  }

  Future<void> _edit([GoalEntry? existing]) async {
    final TextEditingController title = TextEditingController(
      text: existing?.title ?? '',
    );
    final TextEditingController detail = TextEditingController(
      text: existing?.detail ?? '',
    );
    final TextEditingController due = TextEditingController(
      text: existing?.dueDate == null
          ? ''
          : existing!.dueDate!.toIso8601String().substring(0, 10),
    );
    GoalStatus status = existing?.status ?? GoalStatus.active;
    double progress = (existing?.progress ?? 0).toDouble();
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: ctx.zSurface,
          title: Text(existing == null ? 'New goal' : 'Edit goal'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    key: const Key('goal-title-field'),
                    autofocus: true,
                    controller: title,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('goal-detail-field'),
                    controller: detail,
                    maxLines: 4,
                    minLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Detail',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('goal-due-field'),
                    controller: due,
                    decoration: const InputDecoration(
                      labelText: 'Due date (YYYY-MM-DD, optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<GoalStatus>(
                    key: const Key('goal-status-field'),
                    initialValue: status,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: <DropdownMenuItem<GoalStatus>>[
                      for (final GoalStatus s in GoalStatus.values)
                        DropdownMenuItem<GoalStatus>(
                          value: s,
                          child: Text(s.name),
                        ),
                    ],
                    onChanged: (GoalStatus? v) =>
                        setLocal(() => status = v ?? status),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      const Text('Progress'),
                      Expanded(
                        child: Slider(
                          key: const Key('goal-progress-slider'),
                          value: progress,
                          min: 0,
                          max: 100,
                          divisions: 20,
                          label: '${progress.round()}%',
                          onChanged: (double v) => setLocal(() => progress = v),
                        ),
                      ),
                      Text('${progress.round()}%'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(stringsOf(ctx).cancel),
            ),
            TextButton(
              key: const Key('goal-save-button'),
              onPressed: () {
                if (title.text.trim().isEmpty) return;
                Navigator.of(dialogContext).pop(true);
              },
              child: Text(stringsOf(ctx).save),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final DateTime? dueDate = DateTime.tryParse(due.text.trim());
    final service = ref.read(goalServiceProvider);
    if (existing == null) {
      await service.create(
        _sessionId,
        title.text,
        detail: detail.text,
        dueDate: dueDate,
        progress: progress.round(),
      );
    } else {
      await service.update(
        _sessionId,
        existing.id,
        title: title.text,
        detail: detail.text,
        status: status,
        progress: progress.round(),
        dueDate: dueDate,
        clearDueDate: due.text.trim().isEmpty,
      );
    }
    await _refresh();
    if (mounted) showAppMessage(context, 'Goal saved');
  }

  @override
  Widget build(BuildContext context) {
    final String? sessionId = ref.watch(activeSessionIdProvider);
    if (sessionId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Goals')),
        body: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 48,
                color: context.zMuted,
              ),
              const SizedBox(height: 16),
              const Text(
                'Open a chat first',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Goals are kept per chat: each chat tracks only its own '
                'goals, so data never mixes between chats. Open a chat '
                'to see its goals.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.zMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    final List<GoalEntry> goals =
        ref.watch(goalListProvider(sessionId)).value ?? const <GoalEntry>[];
    final DateTime now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Goals')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('goal-add-fab'),
        heroTag: 'goal-add',
        onPressed: _edit,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New goal'),
      ),
      body: goals.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.flag_rounded, size: 48, color: context.zMuted),
                  const SizedBox(height: 16),
                  Text(
                    'No goals yet for THIS chat. Goals are per chat — the '
                    'agent only sees the goals of this conversation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.zMuted),
                  ),
                ],
              ),
            )
          : PagedList<GoalEntry>(
              prefix: 'goal',
              searchFieldKey: const Key('goal-search-field'),
              searchHint: 'Search goals',
              items: goals,
              resetKey: goals.length,
              filter: (GoalEntry g, String q) =>
                  g.title.toLowerCase().contains(q) ||
                  g.detail.toLowerCase().contains(q),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemBuilder: (BuildContext context, GoalEntry goal) {
                final bool overdue = goal.isOverdue(now);
                final bool dueSoon = goal.isDueSoon(now);
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: context.zSurface,
                    borderRadius: BorderRadius.circular(kCardRadius),
                    border: Border.all(color: context.zBorder),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: ListTile(
                      key: Key('goal-${goal.id}'),
                      leading: Icon(
                        goal.status == GoalStatus.done
                            ? Icons.check_circle_rounded
                            : Icons.flag_outlined,
                        size: 20,
                        color: overdue ? Colors.redAccent : null,
                      ),
                      title: Text(
                        goal.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        <String>[
                          goal.status.name,
                          '${goal.progress}%',
                          if (overdue) 'OVERDUE',
                          if (dueSoon) 'due soon',
                          if (goal.dueDate != null)
                            'due ${goal.dueDate!.toIso8601String().substring(0, 10)}',
                        ].join(' · '),
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Menu',
                        onSelected: (String action) async {
                          if (action == 'edit') _edit(goal);
                          if (action == 'delete') _delete(goal);
                          if (action == 'complete') {
                            await ref
                                .read(goalServiceProvider)
                                .complete(_sessionId, goal.id);
                            await _refresh();
                          }
                        },
                        itemBuilder: (BuildContext menuContext) =>
                            <PopupMenuEntry<String>>[
                              const PopupMenuItem<String>(
                                value: 'edit',
                                child: Text('Edit'),
                              ),
                              const PopupMenuItem<String>(
                                value: 'complete',
                                child: Text('Mark done'),
                              ),
                              const PopupMenuItem<String>(
                                value: 'delete',
                                child: Text(
                                  'Delete',
                                  style: TextStyle(color: Colors.redAccent),
                                ),
                              ),
                            ],
                      ),
                      onTap: () => _edit(goal),
                    ),
                  ),
                );
              },
              emptyBuilder: (BuildContext emptyContext) => Center(
                child: Text(
                  'No results',
                  style: TextStyle(color: emptyContext.zMuted, fontSize: 13),
                ),
              ),
              footer: const <Widget>[SizedBox(height: 84)],
            ),
    );
  }
}
