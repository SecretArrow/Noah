import '../models/models.dart';
import 'chat_store.dart';

/// Aggregated token statistics for ONE model.
class ModelTokenStats {
  const ModelTokenStats({
    required this.model,
    this.turns = 0,
    this.turnsWithUsage = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  final String model;
  final int turns;

  /// Turns where the provider actually reported usage — the denominator
  /// stays visible so users understand why numbers may be partial.
  final int turnsWithUsage;
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;

  ModelTokenStats plus(TokenUsage usage, {required bool countsAsUsage}) =>
      ModelTokenStats(
        model: model,
        turns: turns + 1,
        turnsWithUsage: turnsWithUsage + (countsAsUsage ? 1 : 0),
        promptTokens: promptTokens + usage.promptTokens,
        completionTokens: completionTokens + usage.completionTokens,
      );
}

/// Whole-app token statistics computed from the persisted chat files.
class TokenStatsResult {
  const TokenStatsResult({
    required this.sessions,
    required this.assistantTurns,
    required this.turnsWithUsage,
    required this.promptTokens,
    required this.completionTokens,
    required this.perModel,
  });

  final int sessions;
  final int assistantTurns;
  final int turnsWithUsage;
  final int promptTokens;
  final int completionTokens;

  /// Sorted by total tokens, descending.
  final List<ModelTokenStats> perModel;

  int get totalTokens => promptTokens + completionTokens;
}

/// Scans every stored chat session and aggregates the token usage the
/// providers reported on assistant turns (v1.17.0). Sessions without any
/// usage data are counted in [TokenStatsResult.sessions] but contribute
/// nothing else — providers that never report usage simply stay invisible.
class TokenStatsService {
  TokenStatsService({required this.store});

  final ChatStore store;

  Future<TokenStatsResult> compute() async {
    final List<ChatSummary> summaries = await store.listSummaries();
    final Map<String, ModelTokenStats> perModel = <String, ModelTokenStats>{};
    var assistantTurns = 0;
    var turnsWithUsage = 0;
    var promptTokens = 0;
    var completionTokens = 0;

    for (final ChatSummary summary in summaries) {
      final List<ChatMessage>? messages = await store.load(summary.id);
      if (messages == null) continue; // Corrupted entry: skip.
      for (final ChatMessage message in messages) {
        if (message.role != Role.assistant || message.isStreaming) continue;
        assistantTurns++;
        final TokenUsage? usage = message.usage;
        if (usage == null) continue;
        turnsWithUsage++;
        promptTokens += usage.promptTokens;
        completionTokens += usage.completionTokens;
        final String model = message.model ?? '(unknown model)';
        perModel[model] = (perModel[model] ?? ModelTokenStats(model: model))
            .plus(usage, countsAsUsage: true);
      }
    }

    final List<ModelTokenStats> models = perModel.values.toList()
      ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));

    return TokenStatsResult(
      sessions: summaries.length,
      assistantTurns: assistantTurns,
      turnsWithUsage: turnsWithUsage,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      perModel: models,
    );
  }
}
