import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';
import '../widgets/paged_list.dart';
import '../widgets/app_message.dart';

/// Prompt Library (v1.15.0): the user stores reusable prompts (title +
/// content) and inserts them into the composer with one tap. Follows the
/// Context Manager screen structure closely: paged list, FAB, edit dialog,
/// delete confirmation.
class PromptLibraryScreen extends ConsumerStatefulWidget {
  const PromptLibraryScreen({super.key});

  @override
  ConsumerState<PromptLibraryScreen> createState() =>
      _PromptLibraryScreenState();
}

class _PromptLibraryScreenState extends ConsumerState<PromptLibraryScreen> {
  Future<void> _persist(List<PromptEntry> entries, bool deleted) async {
    await ref.read(promptRepositoryProvider).save(entries);
    ref.invalidate(promptListProvider);
    if (!mounted) return;
    // v1.49.6: centered message dialog instead of a SnackBar.
    showAppMessage(
      context,
      deleted
          ? stringsOf(context).promptDeleted
          : stringsOf(context).promptSaved,
    );
    if (mounted) setState(() {});
  }

  Future<void> _delete(PromptEntry entry) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(strings.deletePromptTitle),
        content: Text(strings.deletePromptBody),
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
    final List<PromptEntry> entries = await ref
        .read(promptRepositoryProvider)
        .load();
    await _persist(
      entries.where((PromptEntry e) => e.id != entry.id).toList(),
      true,
    );
  }

  Future<void> _edit([PromptEntry? existing]) async {
    final AppStrings strings = stringsOf(context);
    final TextEditingController title = TextEditingController(
      text: existing?.title ?? '',
    );
    final TextEditingController content = TextEditingController(
      text: existing?.content ?? '',
    );
    final (String, String)? result = await showDialog<(String, String)>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(existing == null ? strings.newPrompt : strings.editPrompt),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const Key('prompt-title-field'),
                autofocus: true,
                controller: title,
                decoration: InputDecoration(
                  labelText: strings.promptTitleLabel,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('prompt-content-field'),
                controller: content,
                maxLines: 8,
                minLines: 4,
                decoration: InputDecoration(
                  labelText: strings.promptContentLabel,
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
            key: const Key('prompt-save-button'),
            onPressed: () {
              if (title.text.trim().isEmpty) return;
              Navigator.of(dialogContext)
                  .pop((title.text.trim(), content.text));
            },
            child: Text(strings.save),
          ),
        ],
      ),
    );
    if (result == null) return;
    final List<PromptEntry> entries = await ref
        .read(promptRepositoryProvider)
        .load();
    if (existing == null) {
      await _persist(<PromptEntry>[
        ...entries,
        PromptEntry(
          id: newId(),
          title: result.$1,
          content: result.$2,
          createdAt: DateTime.now(),
        ),
      ], false);
    } else {
      await _persist(<PromptEntry>[
        for (final PromptEntry e in entries)
          if (e.id == existing.id)
            PromptEntry(
              id: e.id,
              title: result.$1,
              content: result.$2,
              createdAt: e.createdAt,
            )
          else
            e,
      ], false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final List<PromptEntry> entries =
        ref.watch(promptListProvider).value ?? const <PromptEntry>[];
    return Scaffold(
      appBar: AppBar(title: Text(strings.promptLibrary)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('prompt-add-fab'),
        heroTag: 'prompt-add',
        onPressed: _edit,
        icon: const Icon(Icons.add_rounded),
        label: Text(strings.newPrompt),
      ),
      body: entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.bookmarks_rounded,
                    size: 48,
                    color: context.zMuted,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    strings.promptLibraryEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.zMuted),
                  ),
                ],
              ),
            )
          : PagedList<PromptEntry>(
              prefix: 'prompt',
              searchFieldKey: const Key('prompt-search-field'),
              searchHint: strings.searchHint,
              items: entries,
              resetKey: entries.length,
              filter: (PromptEntry e, String q) =>
                  e.title.toLowerCase().contains(q) ||
                  e.content.toLowerCase().contains(q),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemBuilder: (BuildContext context, PromptEntry entry) =>
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: context.zSurface,
                      borderRadius: BorderRadius.circular(kCardRadius),
                      border: Border.all(color: context.zBorder),
                    ),
                    child: Material(
                      // Interactive ListTile inside a decorated Container
                      // needs its own Material or the ink splashes (and the
                      // framework assertion) break.
                      type: MaterialType.transparency,
                      child: ListTile(
                        key: Key('prompt-${entry.id}'),
                        title: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          entry.content.isEmpty
                              ? '—'
                              : (entry.content.length > 120
                                    ? '${entry.content.substring(0, 120)}…'
                                    : entry.content),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
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
                        onTap: () => _edit(entry),
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
