import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../screens/briefing_screen.dart';
import '../screens/files_screen.dart';
import '../screens/goals_screen.dart';
import '../screens/memory_screen.dart';
import '../screens/prompt_library_screen.dart';
import '../screens/search_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/stats_screen.dart';
import '../theme.dart';
import 'paged_list.dart';
import 'app_message.dart';

/// Navigation drawer: brand header, then three grouped sections —
/// TABS (new chat + the chat history list, long-press to rename,
/// running badge for parallel sessions), SPACES (feature tools) and
/// CHANNELS (session data channels) — with settings pinned at the
/// bottom.
class ChatDrawer extends ConsumerWidget {
  const ChatDrawer({super.key});

  /// v1.49.6: centered message dialog — a SnackBar would push the whole
  /// drawer/chat layout up, which users found disruptive.
  void _snack(BuildContext context, String message) {
    showAppMessage(context, message);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String id,
  ) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(strings.deleteChatTitle),
        content: Text(strings.deleteChatBody),
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
    if (confirmed == true) {
      await ref.read(chatControllerProvider.notifier).deleteChat(id);
    }
  }

  Future<void> _renameChat(
    BuildContext context,
    WidgetRef ref,
    ChatSummary item,
  ) async {
    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _RenameChatDialog(initialName: item.title),
    );
    if (newName == null || newName.trim().isEmpty) return;
    await ref
        .read(chatControllerProvider.notifier)
        .renameChat(item.id, newName);
  }

  /// Exports the ACTIVE session as Markdown (v1.17.0). Guards the empty
  /// state so a fresh draft never produces a pointless file.
  Future<void> _exportActiveMarkdown(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final AppStrings strings = stringsOf(context);
    final String? sessionId = ref.read(chatControllerProvider).sessionId;
    if (sessionId == null ||
        ref.read(chatControllerProvider).messages.isEmpty) {
      _snack(context, strings.exportChatMarkdownEmpty);
      return;
    }
    try {
      final File? file = await ref
          .read(sessionExporterProvider)
          .exportMarkdown(sessionId);
      if (!context.mounted) return;
      if (file == null) {
        _snack(context, strings.exportChatMarkdownEmpty);
        return;
      }
      _snack(context, strings.exportChatMarkdownDone(file.path));
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, strings.operationFailed);
    }
  }

  /// Exports the ACTIVE session as a self-contained HTML file
  /// (v1.51.0) — long-press on the export-chat button.
  Future<void> _exportActiveHtml(BuildContext context, WidgetRef ref) async {
    final AppStrings strings = stringsOf(context);
    final String? sessionId = ref.read(chatControllerProvider).sessionId;
    if (sessionId == null ||
        ref.read(chatControllerProvider).messages.isEmpty) {
      _snack(context, strings.exportChatMarkdownEmpty);
      return;
    }
    try {
      final File? file = await ref
          .read(sessionExporterProvider)
          .exportHtml(sessionId);
      if (!context.mounted) return;
      if (file == null) {
        _snack(context, strings.exportChatMarkdownEmpty);
        return;
      }
      _snack(context, 'HTML export saved: ${file.path}');
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, strings.operationFailed);
    }
  }

  Future<void> _exportSessions(BuildContext context, WidgetRef ref) async {
    final AppStrings strings = stringsOf(context);
    try {
      final dynamic file = await ref.read(sessionExporterProvider).exportAll();
      if (!context.mounted) return;
      _snack(context, strings.exportDone(file.path));
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, strings.operationFailed);
    }
  }

  Future<void> _importSessions(BuildContext context, WidgetRef ref) async {
    final AppStrings strings = stringsOf(context);
    try {
      final XFile? picked = await openFile();
      if (picked == null) return;
      final int count = await ref
          .read(sessionExporterProvider)
          .importFrom(picked.path);
      ref.invalidate(chatListProvider);
      if (!context.mounted) return;
      _snack(context, strings.importDone(count));
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, strings.importFailed);
    }
  }

  /// New chat flow. When "offer random User-Agent" is enabled (default),
  /// a dialog asks whether the embedded browser should switch to a
  /// different, randomly picked User-Agent before the fresh conversation
  /// starts. Declining (or a disabled prompt) keeps the current identity.
  Future<void> _onNewChat(BuildContext context, WidgetRef ref) async {
    final AppSettings settings = ref.read(settingsProvider);
    if (settings.askRandomUa) {
      final AppStrings strings = stringsOf(context);
      final bool? randomize = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          backgroundColor: context.zSurface,
          title: Text(strings.randomUaDialogTitle),
          content: Text(strings.randomUaDialogBody),
          actions: <Widget>[
            TextButton(
              key: const Key('random-ua-decline'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.randomUaDecline),
            ),
            FilledButton(
              key: const Key('random-ua-accept'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.randomUaAccept),
            ),
          ],
        ),
      );
      if (randomize == true) {
        await ref.read(userAgentManagerProvider).rotateRandom(settings.uaMode);
      }
    }
    ref.read(chatControllerProvider.notifier).newChat();
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final AsyncValue<List<ChatSummary>> history = ref.watch(chatListProvider);
    final Set<String> running = ref.watch(runningSessionsProvider);
    // The chat that is currently open — its history row gets the
    // selected-pill highlight.
    final String? activeSessionId = ref.watch(
      chatControllerProvider.select((s) => s.sessionId),
    );
    return Drawer(
      backgroundColor: context.zSurface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: kBrandGradient,
                borderRadius: BorderRadius.circular(kCardRadius),
              ),
              child: Row(
                children: <Widget>[
                  // Decorative logo — the adjacent 'Noah' text carries
                  // the meaning, so drop the empty 'N' node from the
                  // semantics tree.
                  const ExcludeSemantics(child: BrandMark(size: 36)),
                  const SizedBox(width: 12),
                  // Expanded so narrow drawers can never overflow the row.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Text(
                          'Noah',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          strings.agentTagline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Briefing (v1.51.0): per-chat personal-agent summary.
                  IconButton(
                    key: const Key('drawer-briefing'),
                    tooltip: 'Briefing',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const BriefingScreen(),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.dashboard_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  // Global chat search (v1.15.0).
                  IconButton(
                    key: const Key('drawer-search'),
                    tooltip: strings.searchChats,
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SearchScreen(),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.search_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
            // -- TABS: new chat + chat history --------------------------------
            const _DrawerGroupHeader('TABS'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                key: const Key('new-chat'),
                onPressed: () => _onNewChat(context, ref),
                icon: const Icon(Icons.add_rounded),
                label: Text(strings.newChat),
              ),
            ),
            Expanded(
              child: history.when(
                loading: () => Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: stringsOf(context).loading,
                  ),
                ),
                error: (Object error, StackTrace stack) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    strings.historyLoadFailed,
                    style: TextStyle(color: context.zMuted, fontSize: 13),
                  ),
                ),
                data: (List<ChatSummary> items) {
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        strings.noChats,
                        style: TextStyle(color: context.zMuted, fontSize: 13),
                      ),
                    );
                  }
                  return PagedList<ChatSummary>(
                    prefix: 'history',
                    searchFieldKey: const Key('history-search-field'),
                    searchHint: strings.searchSessionsHint,
                    items: items,
                    resetKey: items.length,
                    filter: (ChatSummary c, String q) =>
                        c.title.toLowerCase().contains(q),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemBuilder: (BuildContext context, ChatSummary item) {
                      final bool isRunning = running.contains(item.id);
                      final bool active = item.id == activeSessionId;
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(kPillRadius),
                        ),
                        selected: active,
                        selectedTileColor: Theme.of(context)
                            .colorScheme
                            .secondaryContainer,
                        leading: Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 18,
                          color: context.zMuted,
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: MergeSemantics(
                          // One TalkBack stop for date + running state.
                          child: Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  '${item.updatedAt.day}/${item.updatedAt.month}/${item.updatedAt.year}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.zMuted,
                                  ),
                                ),
                              ),
                              if (isRunning) ...<Widget>[
                                const SizedBox(width: 8),
                                SizedBox(
                                  key: const Key('running-badge'),
                                  width: 10,
                                  height: 10,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    // Reuses the localized "agent running"
                                    // notification title as the badge label.
                                    semanticsLabel: strings.notifTitle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: strings.delete,
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: context.zMuted,
                          ),
                          onPressed: () =>
                              _confirmDelete(context, ref, item.id),
                        ),
                        onTap: () async {
                          // v1.48.0: the chat-switch IP guard may interrupt
                          // with a confirmation dialog when the current
                          // public IP equals the last one recorded for the
                          // TARGET chat. Cancelling aborts the switch and
                          // keeps the drawer open with NO navigation.
                          final bool allowed = await ref
                              .read(ipGuardProvider)
                              .confirmChatSwitch(context, ref, item.id);
                          if (!allowed || !context.mounted) return;
                          Navigator.of(context).pop();
                          ref
                              .read(chatControllerProvider.notifier)
                              .openChat(item);
                        },
                        onLongPress: () => _renameChat(context, ref, item),
                      );
                    },
                    emptyBuilder: (BuildContext emptyContext) => Center(
                      child: Text(
                        strings.noResults,
                        style: TextStyle(
                          color: emptyContext.zMuted,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // -- SPACES: feature tools ----------------------------------------
            const _DrawerGroupHeader('SPACES'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ListTile(
                key: const Key('drawer-files'),
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.folder_open_rounded, size: 20),
                title: Text(strings.filesTitle),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FilesScreen(),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ListTile(
                key: const Key('drawer-prompts'),
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.bookmarks_rounded, size: 20),
                title: Text(strings.promptLibrary),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PromptLibraryScreen(),
                    ),
                  );
                },
              ),
            ),
            // Memory / goals / token stats: icon-only feature tools
            // (tooltips only, no text labels — same actions as before).
            _DrawerIconGroup(
              children: <Widget>[
                IconButton(
                  key: const Key('drawer-memory'),
                  tooltip: 'Memory',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.psychology_rounded, size: 20),
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const MemoryScreen(),
                      ),
                    );
                  },
                ),
                IconButton(
                  key: const Key('drawer-goals'),
                  tooltip: 'Goals',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.flag_rounded, size: 20),
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const GoalsScreen(),
                      ),
                    );
                  },
                ),
                IconButton(
                  key: const Key('drawer-token-stats'),
                  tooltip: strings.tokenStatsMenuItem,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.bar_chart_rounded, size: 20),
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const StatsScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
            // -- CHANNELS: session data channels ------------------------------
            const _DrawerGroupHeader('CHANNELS'),
            _DrawerIconGroup(
              children: <Widget>[
                IconButton(
                  key: const Key('drawer-import-sessions'),
                  tooltip: strings.importSessionsIconTip,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.file_upload_outlined, size: 20),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await _importSessions(context, ref);
                  },
                ),
                IconButton(
                  key: const Key('drawer-export-sessions'),
                  tooltip: strings.exportSessionsIconTip,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.file_download_outlined, size: 20),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await _exportSessions(context, ref);
                  },
                ),
                IconButton(
                  key: const Key('drawer-export-chat'),
                  tooltip: strings.exportChatMarkdown,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.article_outlined, size: 20),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await _exportActiveMarkdown(context, ref);
                  },
                  onLongPress: () async {
                    Navigator.of(context).pop();
                    await _exportActiveHtml(context, ref);
                  },
                ),
              ],
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(strings.settings),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Rename form. It owns its [TextEditingController] for exactly as long as
/// the dialog route exists: disposing the controller right after
/// `showDialog` returns is too early, because the route keeps rebuilding its
/// [TextField] while it animates out ("A TextEditingController was used
/// after being disposed").
class _RenameChatDialog extends StatefulWidget {
  const _RenameChatDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<_RenameChatDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
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
      title: Text(strings.renameChatTitle),
      content: TextField(
        autofocus: true,
        controller: _controller,
        decoration: InputDecoration(labelText: strings.nameHint),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(strings.save),
        ),
      ],
    );
  }
}

/// Small gray uppercase group label used by the drawer sections
/// (TABS / SPACES / CHANNELS).
class _DrawerGroupHeader extends StatelessWidget {
  const _DrawerGroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 1.2,
          color: context.zMuted,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Rounded group container for the drawer's icon-only action rows.
class _DrawerIconGroup extends StatelessWidget {
  const _DrawerIconGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: context.zSurfaceAlt,
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: children,
      ),
    );
  }
}
