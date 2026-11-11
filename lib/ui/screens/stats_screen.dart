import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../services/token_stats.dart';
import '../theme.dart';

/// Token usage statistics (v1.17.0): whole-app totals plus a per-model
/// breakdown, computed from the stored chat sessions. Providers that do
/// not report usage leave gaps — the screen says so instead of faking
/// numbers.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  Future<TokenStatsResult>? _stats;

  @override
  void initState() {
    super.initState();
    _stats = TokenStatsService(store: ref.read(chatStoreProvider)).compute();
  }

  void _reload() {
    setState(() {
      _stats = TokenStatsService(store: ref.read(chatStoreProvider)).compute();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.tokenStatsTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('stats-reload'),
            icon: const Icon(Icons.refresh_rounded, size: 22),
            // Was strings.menu — wrong meaning for a refresh action.
            tooltip: stringsOf(context).refresh,
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<TokenStatsResult>(
        future: _stats,
        builder:
            (BuildContext context, AsyncSnapshot<TokenStatsResult> snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: stringsOf(context).loading,
                  ),
                );
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    strings.operationFailed,
                    style: TextStyle(color: context.zMuted),
                  ),
                );
              }
              final TokenStatsResult stats = snapshot.data!;
              if (stats.turnsWithUsage == 0) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      strings.statsNoData,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.zMuted, fontSize: 13),
                    ),
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _StatCard(
                          label: strings.statsPromptTokens,
                          value: _format(stats.promptTokens),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatCard(
                          label: strings.statsCompletionTokens,
                          value: _format(stats.completionTokens),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _StatCard(
                          label: strings.statsTotalTokens,
                          value: _format(stats.totalTokens),
                          emphasized: true,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatCard(
                          label: strings.statsTurns,
                          value:
                              '${stats.turnsWithUsage}/${stats.assistantTurns}',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _StatCard(
                    label: strings.statsSessions,
                    value: '${stats.sessions}',
                  ),
                  const SizedBox(height: 18),
                  Text(
                    strings.statsPerModel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final ModelTokenStats model in stats.perModel)
                    Container(
                      key: Key('stats-model-${model.model}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: context.zSurface,
                        borderRadius: BorderRadius.circular(kCardRadius),
                        border: Border.all(color: context.zBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            model.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            strings.statsModelLine(
                              _format(model.promptTokens),
                              _format(model.completionTokens),
                              _format(model.totalTokens),
                              model.turns,
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.zMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    strings.statsUsageHint,
                    style: TextStyle(color: context.zMuted, fontSize: 11),
                  ),
                ],
              );
            },
      ),
    );
  }

  static String _format(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}k';
    }
    return '$value';
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.emphasized});

  final String label;
  final String value;
  final bool? emphasized;

  @override
  Widget build(BuildContext context) {
    // One TalkBack stop per card: "label, value" instead of two
    // separate text nodes.
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: context.zSurface,
          borderRadius: BorderRadius.circular(kCardRadius),
          border: Border.all(
            color: emphasized == true ? context.zBorder : context.zBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: TextStyle(fontSize: 11, color: context.zMuted)),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: emphasized == true ? kAccentColor : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
