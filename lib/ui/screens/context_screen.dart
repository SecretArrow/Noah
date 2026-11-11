import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';
import '../widgets/paged_list.dart';

/// Context Manager: the user creates, edits, enables/disables and deletes
/// reusable prompt blocks. Enabled entries are injected into every request
/// (see ChatController._systemWire).
class ContextScreen extends ConsumerStatefulWidget {
  const ContextScreen({super.key});

  @override
  ConsumerState<ContextScreen> createState() => _ContextScreenState();
}

class _ContextScreenState extends ConsumerState<ContextScreen> {
  Future<void> _persist(List<ContextEntry> entries) async {
    await ref.read(contextRepositoryProvider).save(entries);
    ref.invalidate(contextListProvider);
    if (mounted) setState(() {});
  }

  Future<void> _toggle(ContextEntry entry, bool enabled) async {
    final List<ContextEntry> entries = ref
        .read(contextRepositoryProvider)
        .load();
    await _persist(<ContextEntry>[
      for (final ContextEntry e in entries)
        if (e.id == entry.id) e.copyWith(enabled: enabled) else e,
    ]);
  }

  Future<void> _delete(ContextEntry entry) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(strings.deleteContextTitle),
        content: Text(strings.deleteContextBody),
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
    final List<ContextEntry> entries = ref
        .read(contextRepositoryProvider)
        .load();
    await _persist(
      entries.where((ContextEntry e) => e.id != entry.id).toList(),
    );
  }

  Future<void> _edit([ContextEntry? existing]) async {
    final AppStrings strings = stringsOf(context);
    final TextEditingController name = TextEditingController(
      text: existing?.name ?? '',
    );
    final TextEditingController content = TextEditingController(
      text: existing?.content ?? '',
    );
    final (String, String)? result = await showDialog<(String, String)>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(
          existing == null ? strings.addContext : strings.editContext,
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const Key('context-name-field'),
                autofocus: true,
                controller: name,
                decoration: InputDecoration(
                  labelText: strings.contextNameLabel,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('context-content-field'),
                controller: content,
                maxLines: 8,
                minLines: 4,
                decoration: InputDecoration(
                  labelText: strings.contextContentLabel,
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('context-save-button'),
            onPressed: () {
              if (name.text.trim().isEmpty) return;
              Navigator.of(dialogContext).pop((name.text.trim(), content.text));
            },
            child: Text(strings.save),
          ),
        ],
      ),
    );
    if (result == null) return;
    final List<ContextEntry> entries = ref
        .read(contextRepositoryProvider)
        .load();
    if (existing == null) {
      await _persist(<ContextEntry>[
        ...entries,
        ContextEntry(
          id: newId(),
          name: result.$1,
          content: result.$2,
          enabled: true,
        ),
      ]);
    } else {
      await _persist(<ContextEntry>[
        for (final ContextEntry e in entries)
          if (e.id == existing.id)
            e.copyWith(name: result.$1, content: result.$2)
          else
            e,
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final List<ContextEntry> entries =
        ref.watch(contextListProvider).value ??
        ref.read(contextRepositoryProvider).load();
    final int activeCount = entries.where((ContextEntry e) => e.enabled).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.contextManagerTitle),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                strings.contextActiveCount(activeCount),
                style: TextStyle(fontSize: 12, color: context.zMuted),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('context-add-fab'),
        heroTag: 'context-add',
        onPressed: _edit,
        icon: const Icon(Icons.add_rounded),
        label: Text(strings.addContext),
      ),
      body: entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.format_quote_rounded,
                    size: 48,
                    color: context.zMuted,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    strings.contextEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.zMuted),
                  ),
                ],
              ),
            )
          : PagedList<ContextEntry>(
              prefix: 'context',
              searchFieldKey: const Key('context-search-field'),
              searchHint: strings.searchContextHint,
              items: entries,
              resetKey: entries.length,
              filter: (ContextEntry e, String q) =>
                  e.name.toLowerCase().contains(q) ||
                  e.content.toLowerCase().contains(q),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
              header: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    strings.contextManagerHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.zMuted,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              itemBuilder: (BuildContext context, ContextEntry entry) =>
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: context.zSurface,
                      borderRadius: BorderRadius.circular(kCardRadius),
                      border: Border.all(color: context.zBorder),
                    ),
                    child: ListTile(
                      key: Key('context-${entry.id}'),
                      title: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        entry.content.isEmpty
                            ? '—'
                            : (entry.content.length > 80
                                  ? '${entry.content.substring(0, 80)}…'
                                  : entry.content),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          MergeSemantics(
                            // The switch is announced with its meaning:
                            // "Use this context, switch, on/off".
                            child: Semantics(
                              label: strings.contextEnabledLabel,
                              child: Switch(
                                key: Key('context-switch-${entry.id}'),
                                value: entry.enabled,
                                onChanged: (bool value) =>
                                    _toggle(entry, value),
                              ),
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: strings.menu,
                            onSelected: (String action) {
                              if (action == 'edit') _edit(entry);
                              if (action == 'delete') _delete(entry);
                            },
                            itemBuilder: (BuildContext menuContext) =>
                                <PopupMenuEntry<String>>[
                                  PopupMenuItem<String>(
                                    value: 'edit',
                                    child: Text(strings.edit),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text(
                                      strings.delete,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  ),
                                ],
                          ),
                        ],
                      ),
                    ),
                  ),
              emptyBuilder: (BuildContext emptyContext) => Center(
                child: Text(
                  strings.noResults,
                  style: TextStyle(color: emptyContext.zMuted, fontSize: 13),
                ),
              ),
              // Keeps the pager clear of the floating action button.
              footer: const <Widget>[SizedBox(height: 84)],
            ),
    );
  }
}
