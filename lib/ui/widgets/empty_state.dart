import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../services/module_registry.dart';
import '../../l10n/app_strings.dart';
import '../screens/modules_screen.dart';
import '../theme.dart';

/// Empty state with the brand circle avatar + suggestion chips and the
/// module picker for starting a new chat with a module.
class EmptyState extends ConsumerWidget {
  const EmptyState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Big gradient circle avatar with the white "N" glyph — the
            // friendly face of the empty chat screen.
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                gradient: kBrandGradient,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Text(
                'N',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Noah',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              strings.emptySubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.zMuted, height: 1.5),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (final String suggestion in strings.suggestions)
                  ActionChip(
                    label: Text(
                      suggestion,
                      style: const TextStyle(fontSize: 12),
                    ),
                    backgroundColor: context.zSurface,
                    side: BorderSide(color: context.zBorder),
                    shape: const StadiumBorder(),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      ref
                          .read(chatControllerProvider.notifier)
                          .send(suggestion);
                    },
                  ),
              ],
            ),
            const _ModulePicker(),
          ],
        ),
      ),
    );
  }
}

/// "Start with a module" — chips for every installed module on the fresh
/// draft screen. Tapping stages the module (with permission consent); the
/// first message activates it for the new chat. Tapping the selected chip
/// unstages it.
class _ModulePicker extends ConsumerWidget {
  const _ModulePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final AsyncValue<List<ChatModule>> modules = ref.watch(moduleListProvider);
    final String? pending = ref.watch(
      chatControllerProvider.select((s) => s.pendingModule),
    );
    return modules.maybeWhen(
      data: (List<ChatModule> items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 20),
            Text(
              strings.startWithModule,
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
            const SizedBox(height: 8),
            Wrap(
              key: const Key('empty-module-picker'),
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (final ChatModule module in items)
                  FilterChip(
                    key: Key('empty-module-${module.name}'),
                    label: Text(
                      module.manifest.title.isEmpty
                          ? module.name
                          : module.manifest.title,
                      style: const TextStyle(fontSize: 12),
                    ),
                    avatar: Icon(
                      pending == module.name
                          ? Icons.check_circle_rounded
                          : Icons.extension_rounded,
                      size: 14,
                    ),
                    selected: pending == module.name,
                    backgroundColor: context.zSurfaceAlt,
                    side: BorderSide(color: context.zBorder),
                    onSelected: (bool selected) async {
                      if (!selected) {
                        // Unstage: activateModule on a draft is idempotent
                        // per name, so unstaging needs the null path —
                        // easiest is re-staging nothing via a fresh state.
                        ref
                            .read(chatControllerProvider.notifier)
                            .stageNoModule();
                        return;
                      }
                      if (!await ModulesScreen.confirmPermissions(
                        context,
                        ref,
                        module,
                      )) {
                        return;
                      }
                      ref
                          .read(chatControllerProvider.notifier)
                          .activateModule(module.name);
                    },
                  ),
              ],
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}
