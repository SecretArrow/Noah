import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../di.dart';
import '../../services/module_registry.dart';
import '../../services/module_remote.dart';
import '../../l10n/app_strings.dart';
import '../theme.dart';
import '../widgets/app_message.dart';

/// Modules (plugins) manager: install from ZIP or URL, one-tap
/// install/update from the official samples repository, list installed
/// modules with their permissions, per-module update, remove, open the
/// official SDK documentation, and start a module in a new chat or the
/// current one.
class ModulesScreen extends ConsumerStatefulWidget {
  const ModulesScreen({super.key});

  @override
  ConsumerState<ModulesScreen> createState() => _ModulesScreenState();

  /// Permission consent dialog — every activation funnels through this so
  /// the user always sees what the module may do before it runs.
  static Future<bool> confirmPermissions(
    BuildContext context,
    WidgetRef ref,
    ChatModule module,
  ) async {
    if (module.manifest.permissions.isEmpty) return true;
    final AppStrings strings = stringsOf(context);
    final bool? allowed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          strings.modulePermissionTitle(
            module.manifest.title.isEmpty ? module.name : module.manifest.title,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.modulePermissionBody,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final ModulePermission p in module.manifest.permissions)
                  Chip(
                    label: Text(p.name, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('module-permission-allow'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.moduleAllow),
          ),
        ],
      ),
    );
    return allowed ?? false;
  }

  /// v1.47.0 — sanitizes a user-entered export file name. The rename
  /// dialog hands raw text over; the file system must only ever see a
  /// flat, portable name:
  ///
  /// 1. trim whitespace;
  /// 2. REMOVE every character outside `A-Z a-z 0-9 . _ -` and space —
  ///    no replacement, so `my ../module:name` becomes `my ..modulename`;
  /// 3. collapse space/dot runs at the EDGES so the name never starts or
  ///    ends with a dot or space (hidden-file/traversal lookalikes and
  ///    runs stranded by step 2); internal spaces/dots are kept as typed
  ///    — harmless inside a single flat file name with no separators;
  /// 4. empty, `.` or `..` → [fallback] (the preset name);
  /// 5. cap the base name at 120 characters (edge-collapsed again — the
  ///    `.zip` suffix may extend the final name to 124);
  /// 6. append `.zip` when the name does not already end with it
  ///    (case-insensitive check; the user's casing is kept).
  static String sanitizeExportFileName(String input, String fallback) {
    String name = input.trim().replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '');
    name = name.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    if (name.isEmpty || name == '.' || name == '..') return fallback;
    if (name.length > 120) name = name.substring(0, 120);
    name = name.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    if (name.isEmpty || name == '.' || name == '..') return fallback;
    if (!name.toLowerCase().endsWith('.zip')) name = '$name.zip';
    return name;
  }
}

class _ModulesScreenState extends ConsumerState<ModulesScreen> {
  bool _installing = false;

  /// v1.46.0 — true while a URL/sample download is in flight (the AppBar
  /// URL action disables itself; the FAB stays independent).
  bool _downloading = false;

  /// Shared result reporter: refreshes the list and surfaces the
  /// version-aware install/update message ("Updated name vX → vY" is
  /// shown verbatim — v1.44.0 behavior, now shared by all intakes).
  Future<void> _reportInstall(Future<ModuleInstallResult> future) async {
    final ModuleInstallResult result = await future;
    ref.invalidate(moduleListProvider);
    if (!mounted) return;
    final AppStrings strings = stringsOf(context);
    // v1.49.6: centered message dialog instead of a SnackBar.
    showAppMessage(
      context,
      result.ok
          ? (result.message.startsWith('Updated')
                // v1.44.0: version-aware reinstall — surface
                // "Updated name vX → vY" verbatim.
                ? result.message
                : strings.moduleInstallSuccess(result.module!.name))
          : strings.moduleInstallFailed(result.message),
    );
  }

  /// v1.46.0: the ZIP pick shared by the FAB (fresh install) and the
  /// per-module update sheet (reinstall = atomic replace = update).
  Future<void> _pickAndInstallZip() async {
    if (_installing) return;
    setState(() => _installing = true);
    try {
      const XTypeGroup zipGroup = XTypeGroup(
        label: 'ZIP module',
        extensions: <String>['zip'],
      );
      final XFile? picked = await openFile(
        acceptedTypeGroups: <XTypeGroup>[zipGroup],
      );
      if (picked == null) return;
      await _reportInstall(
        ref.read(moduleRegistryProvider).installFromZip(picked.path),
      );
    } catch (e) {
      if (mounted) {
        showAppMessage(context, stringsOf(context).moduleInstallFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  /// v1.46.0 — install/update a module from a user-supplied HTTPS URL.
  /// The dialog doubles as the consent surface: it names the source and
  /// the same-scrutiny promise BEFORE any byte is fetched. Official
  /// sample names prefill the field with the repository ZIP URL, so a
  /// manual update is two taps even without the catalog badge.
  Future<void> _installFromUrl({String? presetUrl}) async {
    if (_downloading) return;
    final AppStrings strings = stringsOf(context);
    final TextEditingController urlController = TextEditingController(
      text: presetUrl ?? '',
    );
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('module-url-dialog'),
        title: Text(strings.moduleUrlDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.moduleUrlDialogBody,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('module-url-field'),
              controller: urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: strings.moduleUrlDialogHint,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('module-url-download'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(urlController.text.trim()),
            child: Text(strings.moduleDownload),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    setState(() => _downloading = true);
    // v1.49.6: centered message dialog instead of a SnackBar.
    showAppMessage(
      context,
      strings.moduleDownloading,
      key: const Key('module-downloading-snack'),
    );
    try {
      await _reportInstall(ref.read(moduleRemoteProvider).installFromUrl(url));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// v1.46.0 — per-module update sheet: the same two intake paths as a
  /// fresh install, offered for an INSTALLED module. The bottom sheet
  /// keeps the module card as the single surface for its whole lifecycle
  /// (start / export / update / remove).
  Future<void> _updateModule(ChatModule module) async {
    final AppStrings strings = stringsOf(context);
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.moduleUpdateTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.moduleUpdateBody(module.name),
                  style: TextStyle(fontSize: 12, color: context.zMuted),
                ),
              ),
            ),
            ListTile(
              key: const Key('module-update-from-zip'),
              leading: const Icon(Icons.upload_file_rounded),
              title: Text(strings.moduleUpdateFromZip),
              onTap: () => Navigator.of(sheetContext).pop('zip'),
            ),
            ListTile(
              key: const Key('module-update-from-url'),
              leading: const Icon(Icons.cloud_download_rounded),
              title: Text(strings.moduleUpdateFromUrl),
              onTap: () => Navigator.of(sheetContext).pop('url'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'zip') {
      await _pickAndInstallZip();
    } else if (choice == 'url') {
      final bool knownSample = _kOfficialSamples.any(
        (_OfficialSample s) => s.name == module.name,
      );
      await _installFromUrl(
        presetUrl: knownSample
            ? ref.read(moduleRemoteProvider).sampleZipUrl(module.name)
            : null,
      );
    }
  }

  Future<void> _remove(ChatModule module) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(strings.moduleRemoveTitle),
        content: Text(strings.moduleRemoveBody(module.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(moduleRegistryProvider).remove(module.name);
    ref.invalidate(moduleListProvider);
  }

  Future<void> _startInNewChat(ChatModule module) async {
    if (!await ModulesScreen.confirmPermissions(context, ref, module)) return;
    if (!mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    await ref.read(chatControllerProvider.notifier).newChat();
    await ref.read(chatControllerProvider.notifier).activateModule(module.name);
    if (navigator.canPop()) navigator.pop();
  }

  /// v1.47.0 — two-step export. Step 1: a rename dialog runs BEFORE any
  /// byte is written — the field is pre-filled with the preset file name
  /// ([ModuleRegistry.presetZipFileName]) and fully selected on focus, so
  /// the user can rename the archive or accept it as-is. Step 2: the
  /// entered name is sanitized ([sanitizeExportFileName]) and the fresh,
  /// installable ZIP (module root = zip root, no account/session/chat
  /// data) is written into `<docs>/modules-export/` and handed to the
  /// share sheet. The archive re-installs via the normal path.
  Future<void> _export(ChatModule module) async {
    final AppStrings strings = stringsOf(context);
    final String preset = ModuleRegistry.presetZipFileName(
      module.name,
      module.manifest.version,
    );
    final TextEditingController nameController = TextEditingController(
      text: preset,
    );
    // Select the whole prefill when the field gains focus — typing then
    // replaces the preset cleanly instead of inserting mid-name.
    final FocusNode nameFocus = FocusNode();
    nameFocus.addListener(() {
      if (nameFocus.hasFocus) {
        nameController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: nameController.text.length,
        );
      }
    });
    // Captured by the dialog builder; the preset is always exportable.
    bool canExport = preset.trim().isNotEmpty;
    try {
      final String? chosen = await showDialog<String>(
        context: context,
        builder: (BuildContext dialogContext) => StatefulBuilder(
          builder:
              (
                BuildContext builderContext,
                void Function(VoidCallback) setDialogState,
              ) => AlertDialog(
                key: const Key('module-export-dialog'),
                title: Text(strings.moduleExportTitle),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      strings.moduleExportHint,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const Key('module-export-name-field'),
                      controller: nameController,
                      focusNode: nameFocus,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (String text) => setDialogState(
                        () => canExport = text.trim().isNotEmpty,
                      ),
                    ),
                  ],
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(strings.cancel),
                  ),
                  FilledButton(
                    key: const Key('module-export-confirm'),
                    onPressed: canExport
                        ? () =>
                              Navigator.of(dialogContext)
                                  .pop(nameController.text)
                        : null,
                    child: Text(strings.moduleExportAction),
                  ),
                ],
              ),
        ),
      );
      if (chosen == null) return; // cancelled / dismissed
      final String fileName = ModulesScreen.sanitizeExportFileName(
        chosen,
        preset,
      );
      if (!mounted) return;
      final Directory base = await ref.read(documentsDirProvider)();
      final String target =
          '${base.path}${Platform.pathSeparator}modules-export'
          '${Platform.pathSeparator}$fileName';
      final ModuleExportResult result = await ref
          .read(moduleRegistryProvider)
          .exportToZip(module.name, target);
      if (!result.ok || result.zipPath == null) {
        if (!mounted) return;
        showAppMessage(context, strings.operationFailed);
        return;
      }
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(result.zipPath!)]),
      );
    } catch (e) {
      if (!mounted) return;
      showAppMessage(context, strings.operationFailed);
    } finally {
      nameController.dispose();
      nameFocus.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final AsyncValue<List<ChatModule>> modules = ref.watch(moduleListProvider);
    final String? activeModule = ref.watch(
      chatControllerProvider.select(
        (s) => s.activeModules.isNotEmpty ? s.activeModules.first : null,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.modulesTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('modules-install-url'),
            tooltip: strings.moduleInstallFromUrl,
            icon: const Icon(Icons.cloud_download_rounded),
            onPressed: _downloading ? null : _installFromUrl,
          ),
          IconButton(
            key: const Key('modules-sdk-docs'),
            tooltip: strings.moduleSdkDocs,
            icon: const Icon(Icons.menu_book_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SdkDocsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('modules-install'),
        onPressed: _installing ? null : _pickAndInstallZip,
        icon: _installing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.upload_file_rounded),
        label: Text(strings.modulesInstall),
      ),
      body: modules.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (Object e, StackTrace s) => Center(
          child: Text(
            strings.operationFailed,
            style: TextStyle(color: context.zMuted),
          ),
        ),
        data: (List<ChatModule> items) => items.isEmpty
            ? _EmptyModules(onInstall: _pickAndInstallZip)
            : ListView.builder(
                key: const Key('modules-list'),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                // +1: the official sample-module catalog footer (v1.44.0).
                itemCount: items.length + 1,
                itemBuilder: (BuildContext context, int index) {
                  if (index == items.length) return const _OfficialCatalog();
                  final ChatModule module = items[index];
                  final bool isActive = activeModule == module.name;
                  return Card(
                    key: Key('module-tile-${module.name}'),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Icon(Icons.extension_rounded, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  module.manifest.title.isEmpty
                                      ? module.name
                                      : module.manifest.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isActive)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Chip(
                                    key: Key('module-active-${module.name}'),
                                    label: Text(
                                      strings.moduleActiveBadge,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              Text(
                                'v${module.manifest.version}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.zMuted,
                                ),
                              ),
                            ],
                          ),
                          if (module.manifest.description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                module.manifest.description,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.zMuted,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (module.manifest.permissions.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: <Widget>[
                                  for (final ModulePermission p
                                      in module.manifest.permissions)
                                    Chip(
                                      label: Text(
                                        p.name,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 6),
                          Row(
                            children: <Widget>[
                              TextButton.icon(
                                key: Key('module-new-chat-${module.name}'),
                                onPressed: () => _startInNewChat(module),
                                icon: const Icon(
                                  Icons.add_comment_rounded,
                                  size: 16,
                                ),
                                label: Text(strings.moduleStartNewChat),
                              ),
                              const Spacer(),
                              IconButton(
                                key: Key('module-update-${module.name}'),
                                tooltip: strings.moduleUpdateTooltip,
                                icon: Icon(
                                  Icons.cloud_sync_rounded,
                                  color: context.zMuted,
                                ),
                                onPressed: () => _updateModule(module),
                              ),
                              IconButton(
                                key: Key('module-export-${module.name}'),
                                tooltip: strings.moduleExportTooltip,
                                icon: Icon(
                                  Icons.ios_share_rounded,
                                  color: context.zMuted,
                                ),
                                onPressed: () => _export(module),
                              ),
                              IconButton(
                                key: Key('module-remove-${module.name}'),
                                tooltip: strings.delete,
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: context.zMuted,
                                ),
                                onPressed: () => _remove(module),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _EmptyModules extends ConsumerWidget {
  const _EmptyModules({required this.onInstall});

  final Future<void> Function() onInstall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.extension_rounded, size: 48, color: context.zMuted),
            const SizedBox(height: 12),
            Text(strings.modulesEmpty, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              strings.modulesEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.zMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// In-app viewer for the official Module SDK documentation (canonical
/// sources live in `docs/modules/` of the repository; shipped as app
/// assets, English and Bahasa Indonesia).
class SdkDocsScreen extends ConsumerWidget {
  const SdkDocsScreen({super.key});

  /// Canonical documentation sources in the repository (declared as app
  /// assets in pubspec.yaml) — also asserted by module_sdk_assets_test.
  static const String docAssetEn = 'docs/modules/sdk-reference-en.md';
  static const String docAssetId = 'docs/modules/sdk-reference-id.md';

  Future<String> _loadDoc(String languageCode) async {
    final String asset = languageCode.trim().toLowerCase().startsWith('id')
        ? docAssetId
        : docAssetEn;
    try {
      return await rootBundle.loadString(asset);
    } catch (_) {
      // Asset missing in a stripped build: fall back to the other locale.
      return rootBundle.loadString(docAssetEn);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final String languageCode = ref.watch(
      settingsProvider.select((s) => s.languageCode),
    );
    return Scaffold(
      appBar: AppBar(title: Text(strings.moduleSdkDocs)),
      body: FutureBuilder<String>(
        future: _loadDoc(languageCode),
        builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final String doc = snapshot.data ?? '';
          if (doc.isEmpty) {
            return Center(
              child: Text(
                strings.operationFailed,
                style: TextStyle(color: context.zMuted),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: doc,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                code: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A bundled catalog entry: one official sample module from the repo's
/// `samples/` folder, with its slash command (or the /plugins activation
/// path) and a one-line description.
class _OfficialSample {
  const _OfficialSample(this.name, this.command, this.description);
  final String name;
  final String command;
  final String description;
}

/// Static catalog of every module shipped in `samples/` (kept in sync with
/// the repo README). The app cannot reach into GitHub at runtime, so the
/// catalog documents WHAT to install from the samples zips — the install
/// itself stays a local, user-driven ZIP pick (no remote code execution).
const List<_OfficialSample> _kOfficialSamples = <_OfficialSample>[
  _OfficialSample(
    'counter',
    '/plugins counter',
    'Per-chat counter — storage isolation demo.',
  ),
  _OfficialSample(
    'network-fetcher',
    '/plugins network-fetcher',
    'Allowlisted HTTP fetch (api.github.com only).',
  ),
  _OfficialSample(
    'file-notes',
    '/plugins file-notes',
    'Sandboxed notes inside the per-chat state dir.',
  ),
  _OfficialSample(
    'chat-streamer',
    '/plugins chat-streamer',
    'Progressive output via zagents.chat.emit.',
  ),
  _OfficialSample(
    'onhomeroom-daily',
    '/plugins onhomeroom-daily',
    'Daily bot for app.onhomeroom.com (agent.compose).',
  ),
  _OfficialSample(
    'airplane-mode',
    '/airplane',
    'Airplane IP-rotation cycle (root / manual).',
  ),
  _OfficialSample(
    'evm-wallet',
    '/wallet',
    'Generate-only EVM wallet with signed transfers.',
  ),
  _OfficialSample(
    'web-browser',
    '/web',
    'Text-mode browser: reader extraction + search.',
  ),
  _OfficialSample(
    'rss-reader',
    '/rss',
    'Per-chat RSS 2.0 / Atom subscriptions.',
  ),
  _OfficialSample('qr-tools', '/qr', 'Scannable QR codes, zero permissions.'),
  _OfficialSample(
    'facebook-page',
    '/fb',
    'Fanspage assistant: auto-reply comments + Messenger (templates + AI polish).',
  ),
  _OfficialSample(
    'twitter-x',
    '/tw',
    'X/Twitter assistant: auto-reply mentions (OAuth 1.0a + AI polish).',
  ),
  _OfficialSample(
    'totp-auth',
    '/otp',
    'RFC 6238 authenticator — secrets never leave the device.',
  ),
  _OfficialSample(
    'csv-data',
    '/csv',
    'RFC 4180 CSV studio: stats, filter, chart.',
  ),
  _OfficialSample(
    'converters',
    '/cur + /unit',
    'Live currency rates + offline unit engine.',
  ),
];

/// v1.44.0 — the "Official sample modules" card at the bottom of the
/// Modules screen. v1.46.0: the card is now ACTIONABLE — every sample row
/// carries a one-tap Install/Update action that downloads the sample ZIP
/// straight from the official repository (`samples/<name>.zip` on the
/// `main` branch) through [ModuleRemote] and funnels it through the
/// normal registry intake (zip-slip, caps, atomic staging). A tiny
/// `module.json` probe per row powers the Update badge WITHOUT
/// downloading the whole archive; a failed probe degrades to a plain
/// Install attempt, never to a hard error.
class _OfficialCatalog extends ConsumerStatefulWidget {
  const _OfficialCatalog();

  @override
  ConsumerState<_OfficialCatalog> createState() => _OfficialCatalogState();
}

class _OfficialCatalogState extends ConsumerState<_OfficialCatalog> {
  /// Sample name -> remote version. Absent = probe still running or not
  /// attempted; null = probe failed (offline) — treated as "unknown",
  /// which still leaves a plain Install attempt available.
  final Map<String, String?> _remote = <String, String?>{};

  final Set<String> _probing = <String>{};

  /// The one sample whose download is currently in flight (its row shows
  /// a spinner; all other actions stay enabled — downloads are small).
  String? _busyName;

  @override
  void initState() {
    super.initState();
    // Probes are tiny (< 1 KB each) — fire them in parallel, settle each
    // row independently so one slow fetch never blocks the others.
    for (final _OfficialSample sample in _kOfficialSamples) {
      _probe(sample.name);
    }
  }

  Future<void> _probe(String name) async {
    if (_remote.containsKey(name) || _probing.contains(name)) return;
    _probing.add(name);
    if (mounted) setState(() {});
    final String? version = await ref
        .read(moduleRemoteProvider)
        .sampleRemoteVersion(name);
    if (!mounted) return;
    setState(() {
      _probing.remove(name);
      _remote[name] = version;
    });
  }

  /// One-tap install/update for an official sample: downloads the repo
  /// ZIP and installs through the shared registry intake. Success keeps
  /// the row in sync immediately (the freshly installed version IS the
  /// remote version just delivered) and refreshes the global module
  /// list for the installed-cards section above.
  Future<void> _installSample(String name) async {
    if (_busyName != null) return;
    setState(() => _busyName = name);
    ModuleInstallResult result;
    try {
      result = await ref.read(moduleRemoteProvider).installSample(name);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyName = null);
      showAppMessage(context, stringsOf(context).moduleInstallFailed('$e'));
      return;
    }
    ref.invalidate(moduleListProvider);
    if (!mounted) return;
    final AppStrings strings = stringsOf(context);
    // v1.49.6: centered message dialog instead of a SnackBar.
    showAppMessage(
      context,
      result.ok
          ? (result.message.startsWith('Updated')
                ? result.message
                : strings.moduleInstallSuccess(result.module!.name))
          : strings.moduleInstallFailed(result.message),
    );
    setState(() {
      _busyName = null;
      if (result.ok && result.module != null) {
        _remote[name] = result.module!.manifest.version;
      }
    });
  }

  /// The trailing action for one sample row, resolved from the probe
  /// state and the installed registry:
  ///   probing        -> spinner
  ///   downloading    -> spinner
  ///   not installed  -> Install
  ///   remote newer   -> Update (accent)
  ///   otherwise      -> Installed (quiet)
  Widget _rowAction(_OfficialSample sample, ChatModule? installed) {
    final AppStrings strings = stringsOf(context);
    final String name = sample.name;
    if (_busyName == name) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_probing.contains(name) && !_remote.containsKey(name)) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: context.zMuted),
      );
    }
    if (installed == null) {
      return TextButton(
        key: Key('sample-install-$name'),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
        ),
        onPressed: () => _installSample(name),
        child: Text(
          strings.moduleSampleInstall,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      );
    }
    final String? remote = _remote[name];
    if (remote != null &&
        ModuleRegistry.compareVersions(remote, installed.manifest.version) >
            0) {
      return TextButton(
        key: Key('sample-update-$name'),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
        ),
        onPressed: () => _installSample(name),
        child: Text(
          strings.moduleSampleUpdate,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF4CC38A),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        strings.moduleSampleInstalled,
        style: TextStyle(fontSize: 11, color: context.zMuted),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final AsyncValue<List<ChatModule>> modules = ref.watch(moduleListProvider);
    final Map<String, ChatModule> installed = <String, ChatModule>{
      for (final ChatModule m in modules.value ?? const <ChatModule>[])
        m.name: m,
    };
    return Card(
      key: const Key('official-modules-catalog'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.category_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.officialModulesTitle,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              strings.officialModulesSubtitle,
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
            const SizedBox(height: 2),
            Text(
              strings.moduleSampleRepoHint,
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: context.zMuted,
              ),
            ),
            const SizedBox(height: 8),
            for (final _OfficialSample sample in _kOfficialSamples)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      flex: 3,
                      child: Text(
                        sample.name,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        sample.command,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.zMuted,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 6,
                      child: Text(
                        sample.description,
                        style: TextStyle(fontSize: 11, color: context.zMuted),
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 78,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _rowAction(sample, installed[sample.name]),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
