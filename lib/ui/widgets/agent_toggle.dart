import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../theme.dart';

/// Pill toggle for agent mode in the app bar.
class AgentModeToggle extends ConsumerWidget {
  const AgentModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool agentMode = ref.watch(
      settingsProvider.select((s) => s.agentMode),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        key: const Key('agent-toggle'),
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          final current = ref.read(settingsProvider);
          ref
              .read(settingsProvider.notifier)
              .update(current.copyWith(agentMode: !current.agentMode));
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            gradient: agentMode ? kBrandGradient : null,
            color: agentMode ? null : context.zSurfaceAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: agentMode ? Colors.transparent : context.zBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.bolt_rounded,
                size: 15,
                color: agentMode ? Colors.white : context.zMuted,
              ),
              const SizedBox(width: 4),
              Text(
                'Agent',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: agentMode ? Colors.white : context.zMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
