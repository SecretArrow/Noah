import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';
import '../widgets/app_message.dart';
import '../widgets/paged_list.dart';

/// Reminders of the ACTIVE chat (v1.51.0, per-chat): list, add, edit,
/// complete (repeating reminders roll forward), delete.
class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  String get _sessionId => ref.read(activeSessionIdProvider) ?? '';

  Future<void> _refresh() async {
    ref.invalidate(reminderListProvider(_sessionId));
    if (mounted) setState(() {});
  }

  Future<void> _delete(ReminderEntry entry) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: const Text('Delete reminder?'),
        content: const Text('This reminder will be removed.'),
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
    await ref.read(reminderServiceProvider).remove(_sessionId, entry.id);
    await _refresh();
  }

  Future<void> _edit([ReminderEntry? existing]) async {
    final TextEditingController title = TextEditingController(
      text: existing?.title ?? '',
    );
    final TextEditingController detail = TextEditingController(
      text: existing?.detail ?? '',
    );
    final TextEditingController due = TextEditingController(
      text: (existing?.dueAt ?? DateTime.now().add(const Duration(hours: 1)))
          .toIso8601String()
          .substring(0, 16)
          .replaceAll('T', ' '),
    );
    ReminderRepeat repeat = existing?.repeat ?? ReminderRepeat.none;
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: ctx.zSurface,
          title: Text(existing == null ? 'New reminder' : 'Edit reminder'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  key: const Key('reminder-title-field'),
                  autofocus: true,
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('reminder-detail-field'),
                  controller: detail,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Detail'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('reminder-due-field'),
                  controller: due,
                  decoration: const InputDecoration(
                    labelText: 'Due (YYYY-MM-DD HH:MM)',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ReminderRepeat>(
                  key: const Key('reminder-repeat-field'),
                  initialValue: repeat,
                  decoration: const InputDecoration(labelText: 'Repeat'),
                  items: <DropdownMenuItem<ReminderRepeat>>[
                    for (final ReminderRepeat r in ReminderRepeat.values)
                      DropdownMenuItem<ReminderRepeat>(
                        value: r,
                        child: Text(r.name),
                      ),
                  ],
                  onChanged: (ReminderRepeat? v) =>
                      setLocal(() => repeat = v ?? repeat),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(stringsOf(ctx).cancel),
            ),
            TextButton(
              key: const Key('reminder-save-button'),
              onPressed: () {
                if (title.text.trim().isEmpty) return;
                if (DateTime.tryParse(due.text.trim()) == null) return;
                Navigator.of(dialogContext).pop(true);
              },
              child: Text(stringsOf(ctx).save),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final DateTime dueAt = DateTime.parse(due.text.trim());
    final service = ref.read(reminderServiceProvider);
    if (existing == null) {
      await service.create(
        _sessionId,
        title.text,
        detail: detail.text,
        dueAt: dueAt,
        repeat: repeat,
      );
    } else {
      await service.update(
        _sessionId,
        existing.id,
        title: title.text,
        detail: detail.text,
        dueAt: dueAt,
        repeat: repeat,
      );
    }
    await _refresh();
    if (mounted) showAppMessage(context, 'Reminder saved');
  }

  @override
  Widget build(BuildContext context) {
    final String? sessionId = ref.watch(activeSessionIdProvider);
    if (sessionId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reminders')),
        body: const _NoChatBody(kind: 'reminders'),
      );
    }
    final List<ReminderEntry> entries =
        ref.watch(reminderListProvider(sessionId)).value ??
        const <ReminderEntry>[];
    final DateTime now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('reminder-add-fab'),
        heroTag: 'reminder-add',
        onPressed: _edit,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New reminder'),
      ),
      body: entries.isEmpty
          ? const _EmptyBody(
              icon: Icons.alarm_rounded,
              text:
                  'No reminders yet for THIS chat. Reminders are per '
                  'chat and surface in this chat\'s Briefing when due.',
            )
          : PagedList<ReminderEntry>(
              prefix: 'reminder',
              searchFieldKey: const Key('reminder-search-field'),
              searchHint: 'Search reminders',
              items: entries,
              resetKey: entries.length,
              filter: (ReminderEntry e, String q) =>
                  e.title.toLowerCase().contains(q) ||
                  e.detail.toLowerCase().contains(q),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemBuilder: (BuildContext context, ReminderEntry entry) {
                final bool overdue = entry.isOverdue(now);
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
                      key: Key('reminder-${entry.id}'),
                      leading: Icon(
                        entry.done
                            ? Icons.check_circle_rounded
                            : Icons.alarm_outlined,
                        size: 20,
                        color: overdue ? Colors.redAccent : null,
                      ),
                      title: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        <String>[
                          entry.dueAt
                              .toIso8601String()
                              .substring(0, 16)
                              .replaceAll('T', ' '),
                          if (entry.repeat != ReminderRepeat.none)
                            entry.repeat.name,
                          if (overdue) 'OVERDUE',
                          if (entry.done) 'done',
                        ].join(' · '),
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Menu',
                        onSelected: (String action) async {
                          if (action == 'edit') _edit(entry);
                          if (action == 'delete') _delete(entry);
                          if (action == 'complete') {
                            await ref
                                .read(reminderServiceProvider)
                                .complete(_sessionId, entry.id);
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
                                child: Text('Done / next occurrence'),
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
                      onTap: () => _edit(entry),
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

/// Shared "open a chat first" guidance (per-chat screens).
class _NoChatBody extends StatelessWidget {
  const _NoChatBody({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
            'This data is kept per chat, so data never mixes between '
            'chats. Open a chat to see its $kind.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.zMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 48, color: context.zMuted),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.zMuted),
          ),
        ],
      ),
    );
  }
}
