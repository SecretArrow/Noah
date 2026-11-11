import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../screens/skills_screen.dart';
import '../theme.dart';

/// One selectable skill entry for [SkillSelectorSheet] — a lightweight
/// view model so the sheet needs no registry and no I/O (the caller
/// decides what is offerable, e.g. excluding disabled skills).
class SkillOption {
  const SkillOption({
    required this.name,
    required this.title,
    required this.description,
    this.wallet = false,
  });

  /// Installed-skill identity (registry name).
  final String name;
  final String title;
  final String description;

  /// True for value-moving (wallet) skills — surfaced with a badge icon so
  /// the user sees which attachments can move assets.
  final bool wallet;
}

/// Per-chat skill selector (v1.49.0): a multi-select bottom sheet over
/// the installed skills. Resolution contract of [show]:
/// * Apply → the newly selected name list;
/// * "Use global default" → `null` (follow the global default);
/// * "Clear selection" → the empty list (no skills for this chat);
/// * dismissed (barrier tap / back) → the CALLER'S `currentSelection`,
///   so awaiting it never changes the chat's selection by accident —
///   `null` is reserved for the explicit reset-to-global action.
class SkillSelectorSheet {
  const SkillSelectorSheet._();

  static Future<List<String>?> show(
    BuildContext context, {
    required List<SkillOption> options,
    List<String>? currentSelection,
  }) async {
    final Object? result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _SheetBody(
        options: options,
        initialSelection: currentSelection ?? const <String>[],
      ),
    );
    if (result == null) {
      // Barrier/back dismissal: resolve with the caller's current
      // selection so "nothing changed" is a value, not a guess.
      return currentSelection;
    }
    if (identical(result, _useGlobalDefault)) return null;
    return result as List<String>;
  }
}

/// Result popped by the "Use global default" action. A sentinel (not a
/// bare `null`) is needed because the route machinery pops `null` on a
/// barrier/back dismissal — the two cases must stay distinguishable.
const Object _useGlobalDefault = Object();

class _SheetBody extends StatefulWidget {
  const _SheetBody({required this.options, required this.initialSelection});

  final List<SkillOption> options;
  final List<String> initialSelection;

  @override
  State<_SheetBody> createState() => _SheetBodyState();
}

class _SheetBodyState extends State<_SheetBody> {
  late final Set<String> _selected = Set<String>.of(widget.initialSelection);
  String _query = '';

  List<SkillOption> get _filtered {
    final String q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return widget.options
        .where(
          (SkillOption o) =>
              o.name.toLowerCase().contains(q) ||
              o.title.toLowerCase().contains(q) ||
              o.description.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final List<SkillOption> visible = _filtered;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    strings.skillSheetTitle,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                // v1.49.0: shortcut to the Skills manager (Settings → Skills)
                // — install/enable/configure without leaving the chat.
                TextButton.icon(
                  key: const Key('skill-sheet-manage-skills'),
                  onPressed: () {
                    // Capture the navigator BEFORE pop(): the sheet's own
                    // context is deactivated once the sheet route pops, but
                    // the NavigatorState survives and still points at the
                    // root navigator that hosts the chat screen.
                    final NavigatorState nav = Navigator.of(context);
                    nav.pop();
                    nav.push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SkillsScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: Text(strings.skillsManage),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              strings.skillSheetHint,
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('skill-sheet-search-field'),
              onChanged: (String value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: strings.skillsSearchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          strings.skillsEmptyTitle,
                          style: TextStyle(color: context.zMuted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: visible.length,
                      itemBuilder: (BuildContext context, int index) {
                        final SkillOption option = visible[index];
                        return CheckboxListTile(
                          key: Key('skill-sheet-item-${option.name}'),
                          value: _selected.contains(option.name),
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            option.title.isEmpty ? option.name : option.title,
                          ),
                          subtitle: option.description.isEmpty
                              ? null
                              : Text(
                                  option.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.zMuted,
                                  ),
                                ),
                          secondary: option.wallet
                              ? const Icon(
                                  Icons.account_balance_wallet_rounded,
                                  size: 18,
                                )
                              : null,
                          onChanged: (bool? checked) => setState(() {
                            if (checked == true) {
                              _selected.add(option.name);
                            } else {
                              _selected.remove(option.name);
                            }
                          }),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextButton(
                    key: const Key('skill-sheet-use-global'),
                    onPressed: () =>
                        Navigator.of(context).pop(_useGlobalDefault),
                    child: Text(strings.skillSheetUseGlobal),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    key: const Key('skill-sheet-clear'),
                    onPressed: () => Navigator.of(context).pop(<String>[]),
                    child: Text(strings.skillSheetClear),
                  ),
                ),
                Expanded(
                  child: FilledButton(
                    key: const Key('skill-sheet-apply'),
                    onPressed: () =>
                        Navigator.of(context).pop(_selected.toList()),
                    child: Text(strings.skillSheetApply),
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
