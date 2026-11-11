import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../services/device_export.dart';
import '../../services/file_system_service.dart';
import '../theme.dart';
import '../widgets/paged_list.dart';
import '../widgets/app_message.dart';

/// In-app file manager over the app documents directory: browse, preview,
/// share, rename, delete, copy/cut/paste, zip and unzip.
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  String _current = '';
  List<FsEntry> _entries = const <FsEntry>[];
  bool _loading = true;
  ({String path, bool cut})? _clipboard;
  bool _exporting = false;

  /// File workspace of the ACTIVE chat session — every session browses
  /// only its own sandbox (like a browser private window).
  FileSystemService get _fs =>
      ref.read(sessionSandboxProvider).fsFor(ref.read(activeSessionIdProvider));

  /// Bumped on every successful listing so the paged list returns to its
  /// first page when the folder content changes.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final List<FsEntry> entries = await _fs.list(_current);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _generation++;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _appMessage(stringsOf(context).operationFailed);
    }
  }

  /// v1.49.6: centered message dialog instead of a SnackBar — a dialog
  /// never pushes the file list or the preview sheet around.
  void _appMessage(String message) {
    showAppMessage(context, message);
  }

  void _snack(String text) {
    _appMessage(text);
  }

  Future<void> _guard(Future<void> Function() op, String? success) async {
    try {
      await op();
      if (!mounted) return;
      if (success != null) _snack(success);
      await _refresh();
    } catch (_) {
      if (mounted) _appMessage(stringsOf(context).operationFailed);
    }
  }

  IconData _iconFor(FsEntry entry) {
    if (entry.isDirectory) return Icons.folder_rounded;
    return switch (entry.extension) {
      'zip' => Icons.folder_zip_rounded,
      'png' || 'jpg' || 'jpeg' || 'webp' || 'gif' => Icons.image_rounded,
      'json' ||
      'js' ||
      'ts' ||
      'dart' ||
      'py' ||
      'html' ||
      'css' => Icons.code_rounded,
      'md' || 'txt' || 'log' => Icons.description_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }

  String _sizeLabel(FsEntry entry) {
    if (entry.isDirectory) return '—';
    final int kb = entry.sizeBytes ~/ 1024;
    if (kb < 1) return '${entry.sizeBytes} B';
    if (kb < 1024) return '$kb KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _openEntry(FsEntry entry) async {
    final AppStrings strings = stringsOf(context);
    if (entry.isDirectory) {
      setState(() => _current = entry.relativePath);
      await _refresh();
      return;
    }
    if (<String>[
      'png',
      'jpg',
      'jpeg',
      'webp',
      'gif',
    ].contains(entry.extension)) {
      final String? abs = await _fs.resolve(entry.relativePath);
      if (abs == null || !mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          title: Text(entry.name),
          content: Image.file(
            File(abs),
            fit: BoxFit.contain,
            // TalkBack announces the image by its file name.
            semanticLabel: entry.name,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(strings.confirm),
            ),
          ],
        ),
      );
      return;
    }
    if (<String>[
      'txt',
      'md',
      'json',
      'csv',
      'log',
      'js',
      'ts',
      'dart',
      'html',
      'css',
      'py',
      'xml',
      'yaml',
      'yml',
      'sh',
      'toml',
    ].contains(entry.extension)) {
      try {
        final String text = await _fs.readText(entry.relativePath);
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            backgroundColor: Theme.of(context).colorScheme.surface,
            title: Text(entry.name),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(strings.confirm),
              ),
            ],
          ),
        );
      } catch (_) {
        if (mounted) _appMessage(stringsOf(context).noPreview);
      }
      return;
    }
    _snack(stringsOf(context).noPreview);
  }

  Future<void> _share(FsEntry entry) async {
    final String? abs = await _fs.resolve(entry.relativePath);
    if (abs == null) return;
    try {
      await SharePlus.instance.share(ShareParams(files: <XFile>[XFile(abs)]));
    } catch (_) {
      if (mounted) _appMessage(stringsOf(context).operationFailed);
    }
  }

  Future<void> _rename(FsEntry entry) async {
    final AppStrings strings = stringsOf(context);
    final TextEditingController controller = TextEditingController(
      text: entry.name,
    );
    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(strings.rename),
        content: TextField(
          autofocus: true,
          controller: controller,
          decoration: InputDecoration(labelText: strings.nameHint),
          onSubmitted: (String value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty || newName == entry.name) {
      return;
    }
    await _guard(
      () async => _fs.rename(entry.relativePath, newName.trim()),
      null,
    );
  }

  Future<void> _delete(FsEntry entry) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(strings.deleteEntryTitle),
        content: Text(strings.deleteEntryBody),
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
    await _guard(() => _fs.delete(entry.relativePath), null);
  }

  Future<void> _newFolder() async {
    final AppStrings strings = stringsOf(context);
    final TextEditingController controller = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(strings.newFolderTitle),
        content: TextField(
          autofocus: true,
          controller: controller,
          key: const Key('new-folder-field'),
          decoration: InputDecoration(labelText: strings.nameHint),
          onSubmitted: (String value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.add),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final String rel = _current.isEmpty
        ? name.trim()
        : '$_current/${name.trim()}';
    await _guard(() => _fs.mkdir(rel), null);
  }

  void _copyEntry(FsEntry entry) {
    setState(() => _clipboard = (path: entry.relativePath, cut: false));
    _snack(stringsOf(context).clipboardCopied);
  }

  void _cutEntry(FsEntry entry) {
    setState(() => _clipboard = (path: entry.relativePath, cut: true));
    _snack(stringsOf(context).clipboardCut);
  }

  Future<void> _paste() async {
    final ({String path, bool cut}) clip = _clipboard!;
    final String path = clip.path;
    final bool cut = clip.cut;
    final String name = path.split('/').last;
    final String dest = _current.isEmpty ? name : '$_current/$name';
    if (dest == path) {
      // Pasting into the same folder: make a "copy" suffix for copies.
      if (cut) return;
      final int dot = name.lastIndexOf('.') > 0
          ? name.lastIndexOf('.')
          : name.length;
      final String destCopy =
          '${path.substring(0, path.lastIndexOf('/') + 1)}'
          '${name.substring(0, dot)}_copy${name.substring(dot)}';
      await _guard(() => _fs.copy(path, destCopy), stringsOf(context).pastedOk);
      return;
    }
    await _guard(() async {
      if (cut) {
        await _fs.move(path, dest);
      } else {
        await _fs.copy(path, dest);
      }
    }, stringsOf(context).pastedOk);
    if (mounted) setState(() => _clipboard = null);
  }

  Future<void> _compress(FsEntry entry) async {
    await _guard(
      () => _fs.zip(entry.relativePath),
      stringsOf(context).zipCreatedOk,
    );
  }

  Future<void> _extract(FsEntry entry) async {
    final FileSystemService service = _fs;
    try {
      await _runExtract(service, entry, null);
    } on ZipPasswordRequiredException {
      // Encrypted archive: ask for the password and retry once.
      if (!mounted) return;
      final String? password = await _askPassword(entry.name);
      if (password == null || password.isEmpty) return;
      try {
        await _runExtract(service, entry, password);
      } on ZipWrongPasswordException {
        if (mounted) _snack(stringsOf(context).wrongPassword);
      }
    }
  }

  /// Runs one extraction attempt. Password problems are rethrown so the
  /// caller can drive the password dialog; every other failure keeps the
  /// generic operation-failed snackbar.
  Future<void> _runExtract(
    FileSystemService service,
    FsEntry entry,
    String? password,
  ) async {
    try {
      await service.unzip(entry.relativePath, password: password);
      if (!mounted) return;
      _snack(stringsOf(context).unzippedOk);
      await _refresh();
    } on ZipWrongPasswordException {
      rethrow;
    } on ZipPasswordRequiredException {
      rethrow;
    } catch (_) {
      if (mounted) _appMessage(stringsOf(context).operationFailed);
    }
  }

  /// Dialog asking for an encrypted archive's password.
  Future<String?> _askPassword(String name) {
    final AppStrings strings = stringsOf(context);
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('unzip-password-dialog'),
        title: Text(strings.unzipPasswordTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(strings.unzipPasswordBody(name)),
            const SizedBox(height: 12),
            TextField(
              key: const Key('unzip-password-field'),
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: strings.passwordFieldHint),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('unzip-password-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('unzip-password-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.unzipPasswordConfirm),
          ),
        ],
      ),
    );
  }

  /// Copies the ACTIVE chat's whole workspace folder to the device file
  /// manager (v1.29.0): MediaStore `Download/Noah/<chat>/` on Android
  /// 10+, zip + share sheet on older versions.
  Future<void> _exportChatFolder() async {
    final AppStrings strings = stringsOf(context);
    final String? sessionId = ref.read(activeSessionIdProvider);
    if (sessionId == null || _exporting) return;
    setState(() => _exporting = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        content: MergeSemantics(
          // One TalkBack stop: spinner + export status text.
          child: Row(
            children: <Widget>[
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(width: 20),
              Expanded(child: Text(strings.filesExporting)),
            ],
          ),
        ),
      ),
    );
    try {
      final Directory root = await ref
          .read(sessionSandboxProvider)
          .rootFor(sessionId);
      final String title = ref.read(chatControllerProvider).title;
      final DeviceExportResult result = await ref
          .read(deviceExportServiceProvider)
          .exportChatFolder(
            folderName: deviceFolderName(
              title.trim().isEmpty ? 'chat' : title.trim(),
              sessionId,
            ),
            root: root,
          );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // progress dialog
      switch (result) {
        case MediaStoreExport(:final fileCount):
          _snack(strings.filesExportDone(fileCount));
        case SharedZipExport(:final zipPath, :final fileCount):
          _snack(strings.filesExportZipReady(fileCount));
          try {
            await SharePlus.instance.share(
              ShareParams(files: <XFile>[XFile(zipPath)]),
            );
          } catch (_) {
            // The zip stays in exports/ — user can share it from Files.
          }
      }
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // progress dialog
      _appMessage(stringsOf(context).operationFailed);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final ZPalette palette = context.palette;
    // v1.29.0: without an ACTIVE chat there is no per-chat workspace to
    // browse — showing the legacy shared root here mixed every chat's
    // files into one confusing view. Ask the user to open a chat instead.
    final String? activeSession = ref.watch(activeSessionIdProvider);
    if (activeSession == null) {
      return Scaffold(
        appBar: AppBar(title: Text(strings.filesTitle)),
        body: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 48,
                color: palette.muted,
              ),
              const SizedBox(height: 16),
              Text(
                strings.filesNoChatTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                strings.filesNoChatBody,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _current.isEmpty ? strings.filesTitle : _current.split('/').last,
        ),
        actions: <Widget>[
          IconButton(
            key: const Key('files-export-folder'),
            tooltip: strings.filesExportFolder,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt_rounded),
            onPressed: _exportChatFolder,
          ),
          IconButton(
            key: const Key('files-new-folder'),
            tooltip: strings.newFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _newFolder,
          ),
          IconButton(
            key: const Key('files-paste'),
            tooltip: strings.paste,
            icon: Badge(
              isLabelVisible: _clipboard != null,
              child: const Icon(Icons.paste_rounded),
            ),
            onPressed: _clipboard == null ? null : _paste,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: stringsOf(context).loading,
              ),
            )
          : _entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.folder_open_rounded,
                    size: 48,
                    color: palette.muted,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    strings.filesEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.muted),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.filesHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: PagedList<FsEntry>(
                prefix: 'files',
                searchFieldKey: const Key('files-search-field'),
                searchHint: strings.searchFilesHint,
                items: _entries,
                resetKey: '$_current|$_generation',
                filter: (FsEntry e, String q) =>
                    e.name.toLowerCase().contains(q),
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemBuilder: (BuildContext context, FsEntry entry) {
                  return ListTile(
                    key: Key('file-${entry.name}'),
                    leading: Icon(_iconFor(entry), color: context.zMuted),
                    title: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${_sizeLabel(entry)} · '
                      '${entry.modified.day}/${entry.modified.month}/${entry.modified.year}',
                      style: TextStyle(fontSize: 11, color: context.zMuted),
                    ),
                    trailing: PopupMenuButton<String>(
                      key: Key('file-menu-${entry.name}'),
                      tooltip: strings.menu,
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: context.zMuted,
                      ),
                      onSelected: (String action) {
                        switch (action) {
                          case 'open':
                            _openEntry(entry);
                          case 'share':
                            _share(entry);
                          case 'copy':
                            _copyEntry(entry);
                          case 'cut':
                            _cutEntry(entry);
                          case 'rename':
                            _rename(entry);
                          case 'zip':
                            _compress(entry);
                          case 'unzip':
                            _extract(entry);
                          case 'delete':
                            _delete(entry);
                        }
                      },
                      itemBuilder: (BuildContext menuContext) =>
                          <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(
                              value: 'open',
                              child: Text(
                                entry.isDirectory
                                    ? strings.open
                                    : strings.filePreviewTitle,
                              ),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem<String>(
                              value: 'share',
                              child: Text(strings.share),
                            ),
                            PopupMenuItem<String>(
                              value: 'copy',
                              child: Text(strings.copy),
                            ),
                            PopupMenuItem<String>(
                              value: 'cut',
                              child: Text(strings.cut),
                            ),
                            PopupMenuItem<String>(
                              value: 'rename',
                              child: Text(strings.rename),
                            ),
                            if (!entry.isDirectory)
                              const PopupMenuItem<String>(
                                value: 'zip',
                                child: Text('ZIP'),
                              ),
                            if (entry.extension == 'zip')
                              PopupMenuItem<String>(
                                value: 'unzip',
                                child: Text(strings.extractHere),
                              ),
                            const PopupMenuDivider(),
                            PopupMenuItem<String>(
                              value: 'delete',
                              child: Text(
                                strings.delete,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          ],
                    ),
                    onTap: () => _openEntry(entry),
                    onLongPress: () => _copyEntry(entry),
                  );
                },
                emptyBuilder: (BuildContext emptyContext) => Center(
                  child: Text(
                    strings.noResults,
                    style: TextStyle(color: emptyContext.zMuted, fontSize: 13),
                  ),
                ),
                // Subfolders show the "up" FAB — keep the pager clear of it.
                footer: _current.isEmpty
                    ? const <Widget>[]
                    : const <Widget>[SizedBox(height: 84)],
              ),
            ),
      floatingActionButton: _current.isEmpty
          ? null
          : FloatingActionButton(
              heroTag: 'files-up',
              // l10n: no 'parent folder' string exists yet.
              tooltip: stringsOf(context).parentFolder,
              onPressed: () async {
                final int slash = _current.lastIndexOf('/');
                setState(() {
                  _current = slash <= 0 ? '' : _current.substring(0, slash);
                });
                await _refresh();
              },
              child: const Icon(Icons.arrow_upward_rounded),
            ),
    );
  }
}
