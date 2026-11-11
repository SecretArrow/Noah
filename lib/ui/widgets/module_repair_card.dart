import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../services/agent_controller.dart'
    show ChatState, ModuleInstallRequest;
import '../theme.dart';

/// Confirmation card for a module zip the AGENT staged via
/// `module_stage_repair` — a repaired installed module OR a newly built
/// plugin (/make_plugins). The trust boundary of the module doctor:
/// the agent prepares and validates, the USER decides — nothing is
/// installed until "Install" is tapped here.
class ModuleRepairCard extends ConsumerWidget {
  const ModuleRepairCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ModuleInstallRequest? request = ref.watch(
      chatControllerProvider.select((ChatState s) => s.pendingModuleInstall),
    );
    if (request == null) return const SizedBox.shrink();
    final AppStrings strings = stringsOf(context);
    return Material(
      key: const Key('module-repair-card'),
      color: context.zSurfaceAlt,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.build_circle_rounded, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    request.isNew
                        ? strings.moduleBuildCardTitle(
                            request.moduleName,
                            request.version,
                          )
                        : strings.moduleRepairCardTitle(
                            request.moduleName,
                            request.version,
                          ),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              request.isNew
                  ? strings.moduleBuildCardBody(
                      request.permissions.isEmpty
                          ? '(none)'
                          : request.permissions.join(', '),
                    )
                  : strings.moduleRepairCardBody(
                      request.permissions.isEmpty
                          ? '(none)'
                          : request.permissions.join(', '),
                    ),
              style: TextStyle(fontSize: 12.5, color: context.zMuted),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    key: const Key('module-repair-discard'),
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .discardStagedModule(),
                    child: Text(strings.moduleRepairDiscard),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: const Key('module-repair-install'),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .installStagedModule(),
                    label: Text(strings.moduleRepairInstall),
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
