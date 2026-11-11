import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';
import '../widgets/app_message.dart';
import '../widgets/paged_list.dart';

/// Long-term Memory (v1.50.0): the user reviews, searches, adds, edits,
/// pins and deletes the memories the agent recalls across chats.
/// Follows the Prompt Library / Context Manager screen structure.
class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  String get _sessionId => ref.read(activeSessionIdProvider) ?? '';

  Future<void> _refresh() async {
    ref.invalidate(memoryListProvider(_sessionId));
    if (mounted) setState(() {});
  }

  Future<void> _delete(MemoryEntry entry) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: const Text('Delete memory?'),
        content: const Text('This memory will no longer be recalled.'),
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
    await ref.read(memoryServiceProvider).forget(_sessionId, entry.id);
    await _refresh();
  }

  Future<void> _edit([MemoryEntry? existing]) async {
    final TextEditingController text = TextEditingController(
      text: existing?.text ?? '',
    );
    MemoryCategory category = existing?.category ?? MemoryCategory.fact;
    bool pinned = existing?.pinned ?? false;
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: ctx.zSurface,
          title: Text(existing == null ? 'New memory' : 'Edit memory'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  key: const Key('memory-text-field'),
                  autofocus: true,
                  controller: text,
                  maxLines: 5,
                  minLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Memory',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<MemoryCategory>(
                  key: const Key('memory-category-field'),
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: <DropdownMenuItem<MemoryCategory>>[
                    for (final MemoryCategory c in MemoryCategory.values)
                      DropdownMenuItem<MemoryCategory>(
                        value: c,
                        child: Text(c.name),
                      ),
                  ],
                  onChanged: (MemoryCategory? v) =>
                      setLocal(() => category = v ?? category),
                ),
                SwitchListTile(
                  key: const Key('memory-pinned-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pinned'),
                  value: pinned,
                  onChanged: (bool v) => setLocal(() => pinned = v),
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
              key: const Key('memory-save-button'),
              onPressed: () {
                if (text.text.trim().isEmpty) return;
                Navigator.of(dialogContext).pop(true);
              },
              child: Text(stringsOf(ctx).save),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final service = ref.read(memoryServiceProvider);
    if (existing == null) {
      await service.add(
        _sessionId,
        text.text,
        category: category,
        pinned: pinned,
      );
    } else {
      await service.update(
        _sessionId,
        existing.id,
        text: text.text,
        category: category,
        pinned: pinned,
      );
    }
    await _refresh();
    if (mounted) showAppMessage(context, 'Memory saved');
  }

  @override
  Widget build(BuildContext context) {
    final String? sessionId = ref.watch(activeSessionIdProvider);
    if (sessionId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Memory')),
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
                'Memory is kept per chat: each chat remembers only its '
                'own facts, so data never mixes between chats. Open a '
                'chat to see its memory.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.zMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    final List<MemoryEntry> entries =
        ref.watch(memoryListProvider(sessionId)).value ?? const <MemoryEntry>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('memory-add-fab'),
        heroTag: 'memory-add',
        onPressed: _edit,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New memory'),
      ),
      body: entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.psychology_rounded,
                    size: 48,
                    color: context.zMuted,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No memories yet for THIS chat. Memories are per chat — '
                    'they are only recalled inside this conversation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.zMuted),
                  ),
                ],
              ),
            )
          : PagedList<MemoryEntry>(
              prefix: 'memory',
              searchFieldKey: const Key('memory-search-field'),
              searchHint: 'Search memories',
              items: entries,
              resetKey: entries.length,
              filter: (MemoryEntry e, String q) =>
                  e.text.toLowerCase().contains(q) ||
                  e.category.name.contains(q),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              header: const <Widget>[
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'This memory belongs to THIS chat only.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              itemBuilder: (BuildContext context, MemoryEntry entry) =>
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: context.zSurface,
                      borderRadius: BorderRadius.circular(kCardRadius),
                      border: Border.all(color: context.zBorder),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        key: Key('memory-${entry.id}'),
                        leading: Icon(
                          entry.pinned
                              ? Icons.push_pin_rounded
                              : Icons.psychology_outlined,
                          size: 20,
                        ),
                        title: Text(
                          entry.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(entry.category.name),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Menu',
                          onSelected: (String action) {
                            if (action == 'edit') _edit(entry);
                            if (action == 'delete') _delete(entry);
                            if (action == 'pin') {
                              ref
                                  .read(memoryServiceProvider)
                                  .update(
                                    _sessionId,
                                    entry.id,
                                    pinned: !entry.pinned,
                                  )
                                  .then((_) => _refresh());
                            }
                          },
                          itemBuilder: (BuildContext menuContext) =>
                              <PopupMenuEntry<String>>[
                                const PopupMenuItem<String>(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'pin',
                                  child: Text('Pin / unpin'),
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
                  ),
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
