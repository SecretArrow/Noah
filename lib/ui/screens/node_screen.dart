import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../services/npm_service.dart';
import '../theme.dart';
import '../widgets/paged_list.dart';
import '../widgets/app_message.dart';

/// Node.js runtime manager: lists installed npm packages, installs new
/// ones (auto add) and removes them (auto remove) for the embedded JS
/// runtime the agent uses via node_run / node_install / node_remove.
class NodeScreen extends ConsumerStatefulWidget {
  const NodeScreen({super.key});

  @override
  ConsumerState<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends ConsumerState<NodeScreen> {
  List<InstalledModule> _modules = const <InstalledModule>[];
  bool _loading = true;
  bool _installing = false;

  /// Bumped on every refresh so the paged list returns to page 1 when the
  /// installed packages change.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final List<InstalledModule> modules = await ref
          .read(npmServiceProvider)
          .listInstalled();
      if (!mounted) return;
      setState(() {
        _modules = modules;
        _loading = false;
        _generation++;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// v1.49.6: centered message dialog instead of a SnackBar — the Node
  /// runtime screen no longer jumps when feedback arrives.
  void _snack(String text) {
    showAppMessage(context, text);
  }

  Future<void> _install() async {
    final AppStrings strings = stringsOf(context);
    final TextEditingController name = TextEditingController();
    final TextEditingController version = TextEditingController();
    final (String, String)? result = await showDialog<(String, String)>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(strings.nodeAddButton),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              key: const Key('node-package-field'),
              autofocus: true,
              controller: name,
              decoration: InputDecoration(labelText: strings.nodeAddHint),
              onSubmitted: (_) =>
                  Navigator.of(dialogContext)
                      .pop((name.text.trim(), version.text.trim())),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: version,
              decoration: InputDecoration(labelText: strings.nodeVersionHint),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('node-install-button'),
            onPressed: () =>
                Navigator.of(dialogContext)
                    .pop((name.text.trim(), version.text.trim())),
            child: Text(strings.nodeAddButton),
          ),
        ],
      ),
    );
    if (result == null || result.$1.isEmpty) return;
    setState(() => _installing = true);
    _snack(strings.nodeInstalling);
    try {
      final npm = await Future<NpmService>.value(ref.read(npmServiceProvider));
      final res = await npm.install(
        result.$1,
        version: result.$2.isEmpty ? null : result.$2,
      );
      if (!mounted) return;
      _snack(res.message);
    } catch (e) {
      if (mounted) _snack('Install failed: $e');
    } finally {
      if (mounted) setState(() => _installing = false);
      await _refresh();
    }
  }

  Future<void> _remove(InstalledModule module) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(strings.nodeRemoveTitle),
        content: Text('${module.name}: ${strings.nodeRemoveBody}'),
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
    try {
      await ref.read(npmServiceProvider).remove(module.name);
    } catch (_) {
      if (mounted) _snack(strings.operationFailed);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.nodeManagerTitle)),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: stringsOf(context).loading,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Card(
                    color: context.zSurface,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kCardRadius),
                      side: BorderSide(color: context.zBorder),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: <Widget>[
                          const Icon(
                            Icons.javascript_rounded,
                            color: kAccentColor,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              strings.nodeDescription,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.zMuted,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Text(
                    strings.nodeInstalledCount(_modules.length),
                    style: TextStyle(fontSize: 12, color: context.zMuted),
                  ),
                ),
                Expanded(
                  child: _modules.isEmpty
                      ? Center(
                          child: Text(
                            strings.nodeEmpty,
                            style: TextStyle(color: context.zMuted),
                          ),
                        )
                      : PagedList<InstalledModule>(
                          prefix: 'node',
                          searchFieldKey: const Key('node-search-field'),
                          searchHint: strings.searchLibsHint,
                          items: _modules,
                          resetKey: _generation,
                          filter: (InstalledModule m, String q) =>
                              m.name.toLowerCase().contains(q) ||
                              m.version.toLowerCase().contains(q),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemBuilder:
                              (BuildContext context, InstalledModule module) =>
                                  ListTile(
                                    key: Key('node-module-${module.name}'),
                                    leading: const Icon(
                                      Icons.inventory_2_rounded,
                                      color: kAccentColor,
                                      size: 20,
                                    ),
                                    title: Text(
                                      module.name,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    subtitle: Text(
                                      module.version,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: context.zMuted,
                                      ),
                                    ),
                                    trailing: IconButton(
                                      key: Key('node-remove-${module.name}'),
                                      tooltip: strings.delete,
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                        color: Colors.redAccent,
                                      ),
                                      onPressed: () => _remove(module),
                                    ),
                                  ),
                          emptyBuilder: (BuildContext emptyContext) => Center(
                            child: Text(
                              strings.noResults,
                              style: TextStyle(
                                color: emptyContext.zMuted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          // Keeps the pager clear of the floating action
                          // button.
                          footer: const <Widget>[SizedBox(height: 84)],
                        ),
                ),
                if (_installing)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      semanticsLabel: strings.nodeInstalling,
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('node-add-fab'),
        heroTag: 'node-add',
        onPressed: _installing ? null : _install,
        icon: const Icon(Icons.add_rounded),
        label: Text(strings.nodeAddButton),
      ),
    );
  }
}
