import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../models/models.dart';
import '../../services/briefing_service.dart';
import '../theme.dart';

/// Briefing (v1.51.0): the personal-agent greeting for the ACTIVE chat —
/// its active goals, due reminders, next scheduled job and pinned
/// memories, aggregated by [BriefingService]. Read-only by design.
class BriefingScreen extends ConsumerWidget {
  const BriefingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? sessionId = ref.watch(activeSessionIdProvider);
    if (sessionId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Briefing')),
        body: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 48,
                color: context.zMuted,
              ),
              const SizedBox(height: 16),
              const Text(
                'Open a chat first',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'The briefing summarizes ONE chat at a time, so data '
                'never mixes between chats.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.zMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    final BriefingData data = ref
        .read(briefingServiceProvider)
        .build(sessionId);
    return Scaffold(
      appBar: AppBar(title: const Text('Briefing')),
      body: ListView(
        key: const Key('briefing-list'),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'Here is where this chat stands:',
            style: TextStyle(color: context.zMuted),
          ),
          const SizedBox(height: 16),
          if (data.isEmpty)
            const Text(
              'Nothing to brief yet — no active goals, due reminders, '
              'scheduled jobs or pinned memories in this chat.',
            ),
          if (data.goals.isNotEmpty) ...<Widget>[
            const _SectionTitle('Active goals'),
            for (final GoalEntry g in data.goals)
              ListTile(
                key: Key('briefing-goal-${g.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.flag_rounded, size: 20),
                title: Text(g.title),
                subtitle: Text('${g.progress}% complete'),
              ),
          ],
          if (data.dueReminders.isNotEmpty) ...<Widget>[
            const _SectionTitle('Reminders due'),
            for (final ReminderEntry r in data.dueReminders)
              ListTile(
                key: Key('briefing-reminder-${r.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.alarm_rounded, size: 20),
                title: Text(r.title),
                subtitle: Text(
                  r.dueAt
                      .toIso8601String()
                      .substring(0, 16)
                      .replaceAll('T', ' '),
                ),
              ),
          ],
          if (data.nextJob != null) ...<Widget>[
            const _SectionTitle('Next scheduled job'),
            ListTile(
              key: const Key('briefing-next-job'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_rounded, size: 20),
              title: Text(data.nextJob!.title),
              subtitle: Text(
                data.nextJob!.nextRunAt == null
                    ? data.nextJob!.kind.name
                    : 'fires ${data.nextJob!.nextRunAt!.toIso8601String().substring(0, 16).replaceAll('T', ' ')} · ${data.nextJob!.action.name}',
              ),
            ),
          ],
          if (data.nextCronJob != null) ...<Widget>[
            const _SectionTitle('Next cron job'),
            ListTile(
              key: const Key('briefing-next-cron'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_rounded, size: 20),
              title: Text(data.nextCronJob!.name),
              subtitle: Text(
                'fires ${DateTime.fromMillisecondsSinceEpoch(data.nextCronJob!.nextRunAtMs!).toIso8601String().substring(0, 16).replaceAll('T', ' ')} · ${data.nextCronJob!.expression} · ${data.nextCronJob!.action.name}',
              ),
            ),
          ],
          if (data.pinnedMemories.isNotEmpty) ...<Widget>[
            const _SectionTitle('Pinned memories'),
            for (final MemoryEntry m in data.pinnedMemories)
              ListTile(
                key: Key('briefing-memory-${m.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.push_pin_rounded, size: 20),
                title: Text(m.text),
                subtitle: Text(m.category.name),
              ),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
