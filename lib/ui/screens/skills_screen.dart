import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart' show listPageSize;
import '../../services/skill_registry.dart';
import '../theme.dart';
import '../widgets/paged_list.dart';
import '../widgets/app_message.dart';

/// Installed-skills snapshot (reactive across the manager like
/// [moduleListProvider] is for modules). Disabled skills ARE listed —
/// the flag is rendered on the tile, not filtered away.
final skillsListProvider = FutureProvider<List<InstalledSkill>>((ref) async {
  final SkillRegistry registry = ref.watch(skillRegistryProvider);
  await registry.ensureCacheLoaded();
  return registry.listSync();
});

/// Skills bundled with the app binary (assets/skills/*) — the manager
/// shows an install tile for each one that is not installed yet.
final bundledSkillCatalogProvider = FutureProvider<List<BundledSkillInfo>>(
  (ref) => ref.watch(skillRegistryProvider).bundledCatalog(),
);

/// Skills manager (v1.49.0): install from URL / ZIP, one-tap install of
/// the skills bundled with the binary, per-skill enable switch, config
/// form (secret fields are masked and stored encrypted), instructions
/// inspector, update and remove.
///
/// Visual conventions follow [ModulesScreen]: card tiles on the shared
/// background, install actions in the AppBar, confirm dialogs before
/// destructive actions.
class SkillsScreen extends ConsumerStatefulWidget {
  const SkillsScreen({super.key});

  @override
  ConsumerState<SkillsScreen> createState() => _SkillsScreenState();

  /// Localized chip label for a lifecycle status. ready/needsConfig/broken
  /// have no dedicated l10n keys, so the closest existing app-wide strings
  /// are reused (see the task worklog for the mapping table).
  static String statusLabel(AppStrings strings, SkillStatus status) {
    switch (status) {
      case SkillStatus.ready:
        return strings.skillEnabled;
      case SkillStatus.needsConfig:
        return strings.skillConfigRequired;
      case SkillStatus.broken:
        return strings.operationFailed;
      case SkillStatus.disabled:
        return strings.skillDisabled;
    }
  }

  /// Chip accent color for a lifecycle status (theme colors only).
  static Color statusColor(BuildContext context, SkillStatus status) {
    switch (status) {
      case SkillStatus.ready:
        return Theme.of(context).colorScheme.primary;
      case SkillStatus.needsConfig:
        return Theme.of(context).colorScheme.tertiary;
      case SkillStatus.broken:
        return Theme.of(context).colorScheme.error;
      case SkillStatus.disabled:
        return context.zMuted;
    }
  }
}

class _SkillsScreenState extends ConsumerState<SkillsScreen> {
  String _query = '';

  /// True while an install/update/remove is in flight — the AppBar
  /// intakes disable themselves (ModulesScreen pattern).
  bool _busy = false;

  /// v1.49.6: centered message dialog instead of a SnackBar.
  void _showFailure() {
    if (!mounted) return;
    showAppMessage(context, stringsOf(context).operationFailed);
  }

  Future<void> _refresh() async => ref.invalidate(skillsListProvider);

  /// Install from a user-supplied URL / GitHub source. The dialog is the
  /// consent surface: the field is labelled with the expected input.
  Future<void> _installFromUrl() async {
    if (_busy) return;
    final AppStrings strings = stringsOf(context);
    final TextEditingController urlController = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('skills-url-dialog'),
        title: Text(strings.skillsUrlTitle),
        content: TextField(
          key: const Key('skills-url-field'),
          controller: urlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: strings.skillsUrlLabel),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('skills-url-confirm'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(urlController.text.trim()),
            child: Text(strings.skillsInstallUrl),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(skillRegistryProvider).install(url);
      await _refresh();
    } catch (_) {
      _showFailure();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Install from a picked archive — the same file-picking path
  /// [ModulesScreen] uses, handed to the registry's real install pipeline.
  Future<void> _installFromZip() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final XTypeGroup zipGroup = XTypeGroup(
        label: stringsOf(context).skillsInstallZip,
        extensions: const <String>['zip', 'gz', 'tgz'],
      );
      final XFile? picked = await openFile(
        acceptedTypeGroups: <XTypeGroup>[zipGroup],
      );
      if (picked == null) return;
      await ref.read(skillRegistryProvider).installFromFile(picked.path);
      await _refresh();
    } catch (_) {
      _showFailure();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One-tap install of a bundled (builtin:) skill — real on-disk install
  /// from the app asset, no network.
  Future<void> _installBundled(BundledSkillInfo info) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(skillRegistryProvider)
          .installBundledAsset(info.bundledName);
      await _refresh();
      ref.invalidate(bundledSkillCatalogProvider);
    } catch (_) {
      _showFailure();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Update from the skill's stored remote source (hidden for bundled and
  /// local-file installs — the registry refuses them honestly anyway).
  Future<void> _update(InstalledSkill skill) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(skillRegistryProvider).update(skill.name);
      await _refresh();
    } catch (_) {
      _showFailure();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(InstalledSkill skill) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('skill-remove-confirm'),
        title: Text(strings.skillRemoveTitle),
        content: Text(strings.skillRemoveBody),
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
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(skillRegistryProvider).remove(skill.name);
      await _refresh();
      ref.invalidate(bundledSkillCatalogProvider);
    } catch (_) {
      _showFailure();
    }
  }

  Future<void> _setEnabled(InstalledSkill skill, bool value) async {
    await ref.read(skillRegistryProvider).setEnabled(skill.name, value);
    await _refresh();
  }

  /// Config form. Prefill rule: non-secret fields get their stored value;
  /// secret fields NEVER get a value back — empty means "keep the stored
  /// secret", the mask only appears as a placeholder hint.
  Future<void> _configure(InstalledSkill skill) async {
    if (skill.configFields.isEmpty) return;
    final AppStrings strings = stringsOf(context);
    final SkillRegistry registry = ref.read(skillRegistryProvider);
    final Map<String, String> stored = await registry.readConfig(skill);
    if (!mounted) return;
    final Map<String, TextEditingController> controllers =
        <String, TextEditingController>{
          for (final SkillConfigField f in skill.configFields)
            f.name: TextEditingController(
              text: f.secret ? '' : (stored[f.name] ?? ''),
            ),
        };
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext sheetContext, void Function(VoidCallback) _) =>
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  14,
                  16,
                  16 + MediaQuery.of(sheetContext).viewInsets.bottom,
                ),
                child: Column(
                  key: const Key('skill-config-sheet'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      strings.skillConfigure,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    for (final SkillConfigField f in skill.configFields)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    f.label.isEmpty ? f.name : f.label,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: context.zMuted,
                                    ),
                                  ),
                                ),
                                if (f.required)
                                  Text(
                                    strings.skillConfigRequired,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Theme.of(sheetContext)
                                          .colorScheme
                                          .tertiary,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            TextField(
                              key: Key('skill-config-field-${f.name}'),
                              controller: controllers[f.name],
                              obscureText: f.secret,
                              autocorrect: false,
                              enableSuggestions: false,
                              keyboardType: f.secret
                                  ? TextInputType.visiblePassword
                                  : TextInputType.text,
                              decoration: InputDecoration(
                                // Mask-as-placeholder only: the mask is
                                // never written back on save.
                                hintText: f.secret && stored.containsKey(f.name)
                                    ? SkillRegistry.secretMask
                                    : null,
                                helperText: f.secret
                                    ? strings.skillConfigSecret
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        key: const Key('skill-config-save'),
                        onPressed: () async {
                          final Map<String, String?> values =
                              <String, String?>{};
                          for (final SkillConfigField f in skill.configFields) {
                            final String text =
                                controllers[f.name]?.text.trim() ?? '';
                            if (f.secret) {
                              // Untouched secret field → keep the stored
                              // value (never write the mask back).
                              if (text.isNotEmpty) values[f.name] = text;
                            } else {
                              values[f.name] = text.isEmpty ? null : text;
                            }
                          }
                          if (values.isNotEmpty) {
                            await registry.writeConfig(skill, values);
                          }
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                          await _refresh();
                        },
                        child: Text(strings.skillConfigSave),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ),
    );
    for (final TextEditingController c in controllers.values) {
      c.dispose();
    }
  }

  /// Instructions inspector: the SKILL.md manual (selectable) plus the
  /// file list the registry exposes.
  void _inspect(InstalledSkill skill) {
    final AppStrings strings = stringsOf(context);
    final List<String> files = skill.listFiles();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: SizedBox(
          key: const Key('skill-inspect-sheet'),
          height: MediaQuery.of(sheetContext).size.height * 0.75,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  strings.skillInstructions,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      skill.readInstructions(),
                      key: const Key('skill-instructions'),
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                ),
                if (files.isNotEmpty) ...<Widget>[
                  const Divider(height: 16),
                  Text(
                    strings.skillFiles,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: context.zMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (int i = 0; i < files.length && i < 20; i++)
                    Text(
                      files[i],
                      key: Key('skill-file-$i'),
                      style: TextStyle(fontSize: 11, color: context.zMuted),
                    ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _matchesQuery(String q, List<String> texts) => texts
      .where((String t) => t.toLowerCase().contains(q))
      .toList()
      .isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final AsyncValue<List<InstalledSkill>> installed = ref.watch(
      skillsListProvider,
    );
    final AsyncValue<List<BundledSkillInfo>> bundled = ref.watch(
      bundledSkillCatalogProvider,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.skillsTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('skills-install-url'),
            tooltip: strings.skillsInstallUrl,
            icon: const Icon(Icons.cloud_download_rounded),
            onPressed: _busy ? null : _installFromUrl,
          ),
          IconButton(
            key: const Key('skills-install-zip'),
            tooltip: strings.skillsInstallZip,
            icon: const Icon(Icons.upload_file_rounded),
            onPressed: _busy ? null : _installFromZip,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              strings.skillsSubtitle,
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: const Key('skills-search-field'),
              onChanged: (String value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: strings.skillsSearchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: installed.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (Object e, StackTrace s) => Center(
                child: Text(
                  strings.operationFailed,
                  style: TextStyle(color: context.zMuted),
                ),
              ),
              data: (List<InstalledSkill> items) {
                final String q = _query.trim().toLowerCase();
                final List<InstalledSkill> filtered = q.isEmpty
                    ? items
                    : items
                          .where(
                            (InstalledSkill s) => _matchesQuery(q, <String>[
                              s.name,
                              s.title,
                              s.description,
                            ]),
                          )
                          .toList();
                final List<BundledSkillInfo> pendingBundled =
                    (bundled.value ?? const <BundledSkillInfo>[])
                        .where(
                          (BundledSkillInfo b) => items.every(
                            (InstalledSkill s) => s.name != b.name,
                          ),
                        )
                        .where(
                          (BundledSkillInfo b) =>
                              q.isEmpty ||
                              _matchesQuery(q, <String>[
                                b.bundledName,
                                b.name,
                                b.title,
                                b.description,
                              ]),
                        )
                        .toList();
                return PagedList<InstalledSkill>(
                  items: filtered,
                  showSearch: false,
                  pageSize: listPageSize,
                  prefix: 'skills',
                  resetKey: _query,
                  header: <Widget>[
                    for (final BundledSkillInfo b in pendingBundled)
                      _BundledTile(
                        info: b,
                        onInstall: () => _installBundled(b),
                      ),
                  ],
                  itemBuilder: (BuildContext context, InstalledSkill skill) =>
                      _SkillTile(
                        skill: skill,
                        onConfigure: () => _configure(skill),
                        onInspect: () => _inspect(skill),
                        onUpdate: () => _update(skill),
                        onRemove: () => _remove(skill),
                        onToggle: (bool value) => _setEnabled(skill, value),
                      ),
                  emptyBuilder: (BuildContext context) => const _EmptySkills(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state: no installed skills match (nothing installed at all, or
/// the search came up empty).
class _EmptySkills extends StatelessWidget {
  const _EmptySkills();

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.extension_rounded, size: 40, color: context.zMuted),
          const SizedBox(height: 8),
          Text(
            strings.skillsEmptyTitle,
            key: const Key('skills-empty-title'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              strings.skillsEmptyBody,
              key: const Key('skills-empty-body'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Install tile for a skill bundled with the app binary (not yet
/// installed — the front-matter name decides the installed identity).
class _BundledTile extends StatelessWidget {
  const _BundledTile({required this.info, required this.onInstall});

  final BundledSkillInfo info;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Card(
      key: Key('skill-bundled-${info.bundledName}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    info.title.isEmpty ? info.name : info.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (info.wallet)
                  const Icon(Icons.account_balance_wallet_rounded, size: 16),
              ],
            ),
            if (info.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  info.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.zMuted),
                ),
              ),
            Row(
              children: <Widget>[
                Text(
                  'v${info.version}',
                  style: TextStyle(fontSize: 11, color: context.zMuted),
                ),
                const Spacer(),
                FilledButton.tonal(
                  key: Key('skill-bundled-install-${info.bundledName}'),
                  onPressed: onInstall,
                  child: Text(strings.skillBundledInstall),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One installed skill: title, version, lifecycle status chip, wallet
/// badge, enable switch and the per-skill actions.
class _SkillTile extends StatelessWidget {
  const _SkillTile({
    required this.skill,
    required this.onConfigure,
    required this.onInspect,
    required this.onUpdate,
    required this.onRemove,
    required this.onToggle,
  });

  final InstalledSkill skill;
  final VoidCallback onConfigure;
  final VoidCallback onInspect;
  final VoidCallback onUpdate;
  final VoidCallback onRemove;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    // Bundled (builtin:) and local-file installs cannot be re-downloaded —
    // the registry refuses them honestly, so the action is hidden.
    final bool canUpdate =
        !SkillRegistry.isBuiltinSource(skill.source) &&
        !skill.source.startsWith('file:');
    return Card(
      key: Key('skill-tile-${skill.name}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    skill.title.isEmpty ? skill.name : skill.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                _StatusChip(skill: skill),
              ],
            ),
            if (skill.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  skill.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.zMuted),
                ),
              ),
            Row(
              children: <Widget>[
                if (skill.wallet)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.account_balance_wallet_rounded, size: 16),
                  ),
                Text(
                  'v${skill.version}',
                  style: TextStyle(fontSize: 11, color: context.zMuted),
                ),
                const Spacer(),
                Text(
                  skill.enabled ? strings.skillEnabled : strings.skillDisabled,
                  style: TextStyle(fontSize: 11, color: context.zMuted),
                ),
                Switch(
                  key: Key('skill-enabled-${skill.name}'),
                  value: skill.enabled,
                  onChanged: onToggle,
                ),
              ],
            ),
            Row(
              children: <Widget>[
                if (skill.configFields.isNotEmpty)
                  TextButton(
                    key: Key('skill-configure-${skill.name}'),
                    onPressed: onConfigure,
                    child: Text(strings.skillConfigure),
                  ),
                TextButton(
                  key: Key('skill-inspect-${skill.name}'),
                  onPressed: onInspect,
                  child: Text(strings.skillInspect),
                ),
                if (canUpdate)
                  TextButton(
                    key: Key('skill-update-${skill.name}'),
                    onPressed: onUpdate,
                    child: Text(strings.skillUpdate),
                  ),
                const Spacer(),
                TextButton(
                  key: Key('skill-remove-${skill.name}'),
                  onPressed: onRemove,
                  child: Text(
                    strings.skillRemove,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Lifecycle status chip. Shows [AppStrings.skillStatusChecking] while the
/// status check (config-file IO) is in flight.
class _StatusChip extends ConsumerWidget {
  const _StatusChip({required this.skill});

  final InstalledSkill skill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SkillRegistry registry = ref.read(skillRegistryProvider);
    return FutureBuilder<SkillStatus>(
      future: registry.statusOf(skill),
      builder: (BuildContext context, AsyncSnapshot<SkillStatus> snap) {
        final AppStrings strings = stringsOf(context);
        final SkillStatus status = snap.data ?? SkillStatus.disabled;
        final String label = snap.hasData
            ? SkillsScreen.statusLabel(strings, status)
            : strings.skillStatusChecking;
        final Color color = snap.hasData
            ? SkillsScreen.statusColor(context, status)
            : context.zMuted;
        return Container(
          key: Key('skill-status-${skill.name}'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        );
      },
    );
  }
}
