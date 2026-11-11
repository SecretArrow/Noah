import 'llm_client.dart';

/// One text-composition request from a chat module. The module supplies
/// the LIVE context it reads from the target platform (chat lines, app
/// metadata, a question card) plus optional rules; the chat's own agent
/// (the LLM configured for this chat) generates the sentence at the moment
/// it is needed — there are no templates and no canned pools.
class AgentComposeRequest {
  const AgentComposeRequest({
    this.task = '',
    required this.context,
    this.instruction = '',
    this.maxWords = defaultMaxWords,
    this.avoid = const <String>[],
    this.trailingPeriod = false,
  });

  /// Upper bound for [maxWords] accepted from a module request.
  static const int defaultMaxWords = 24;
  static const int minMaxWords = 1;
  static const int maxMaxWords = 40;

  /// Short label of what is being composed (e.g. `chat-reply`,
  /// `feedback`, `proposal-title`). Used only to steer the agent.
  final String task;

  /// The live context the sentence must fit into (recent chat lines, the
  /// app under review, the question being answered, ...). Required.
  final String context;

  /// Optional extra instruction from the module.
  final String instruction;

  /// Maximum number of words the sentence may use (clamped 1..40).
  final int maxWords;

  /// Recent texts the generated sentence must not repeat.
  final List<String> avoid;

  /// Whether a single trailing period is allowed (proposal bodies say
  /// yes, chat replies say no).
  final bool trailingPeriod;

  int get clampedMaxWords => maxWords.clamp(minMaxWords, maxMaxWords);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'task': task,
    'context': context,
    'instruction': instruction,
    'maxWords': clampedMaxWords,
    'avoid': avoid,
    'trailingPeriod': trailingPeriod,
  };
}

/// Thrown when the composer could not produce a sentence that passes the
/// gate (missing connection settings, provider failure, repeated rule
/// violations). Modules are expected to skip the text action gracefully.
class AgentComposeException implements Exception {
  const AgentComposeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of checking one composed candidate against the composer rules.
class ComposerVerdict {
  const ComposerVerdict(this.violations);

  final List<String> violations;

  bool get ok => violations.isEmpty;
}

/// The deterministic half of the composer: validation + sanitization.
///
/// The agent is instructed to obey the hard rules, but its output is never
/// trusted blindly — everything is re-checked here, sanitized once, and
/// rejected when it still breaks the contract. This is the "diaturkan"
/// half of the composer contract.
abstract final class ComposerGate {
  /// Characters that must never appear: they either end sentences
  /// prematurely or read as formatting on the target platforms.
  static final RegExp forbidden = RegExp('[!?:;\u2014\u2013]');

  /// Emoji / pictographic ranges that make text look machine-generated.
  static final RegExp emoji = RegExp(
    '[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{2B00}-\u{2BFF}]',
    unicode: true,
  );

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Light pre-clean applied to raw model output BEFORE validation:
  /// trim, strip one layer of wrapping quotes/backticks, collapse
  /// whitespace. Cosmetic only — rule violations are handled by
  /// [validate]/[sanitize].
  static String preClean(String text) {
    String t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final String q in const <String>['"', "'", '`']) {
      if (t.length >= 2 && t.startsWith(q) && t.endsWith(q)) {
        t = t.substring(1, t.length - 1).trim();
      }
    }
    return t;
  }

  /// Word count on whitespace boundaries.
  static int wordCount(String text) =>
      text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

  /// Validates [text] against the composer contract. Returns every
  /// violation found (empty list = acceptable).
  static ComposerVerdict validate(
    String text, {
    required int maxWords,
    required bool trailingPeriod,
    List<String> avoid = const <String>[],
  }) {
    final String t = _normalize(text);
    final List<String> problems = <String>[];
    if (t.isEmpty) {
      problems.add('empty output');
      return ComposerVerdict(problems);
    }
    // Internal sentence punctuation. A trailing period is allowed only
    // when the caller asked for one.
    final String body = trailingPeriod && t.endsWith('.')
        ? t.substring(0, t.length - 1)
        : t;
    if (RegExp(r'[.!?;]').allMatches(body).isNotEmpty) {
      problems.add('sentence punctuation inside the text');
    }
    if (forbidden.hasMatch(t)) problems.add('forbidden character');
    if (emoji.hasMatch(t)) problems.add('emoji');
    if (wordCount(t) > maxWords) problems.add('over $maxWords words');
    final String norm = _normalize(t);
    for (final String seen in avoid) {
      if (_normalize(seen) == norm && norm.isNotEmpty) {
        problems.add('repeats an earlier text');
        break;
      }
    }
    return ComposerVerdict(problems);
  }

  /// Deterministic last-resort repair: strip wrapping quotes, drop emoji,
  /// replace forbidden characters, remove internal sentence punctuation
  /// and cut to the word budget. The result is not guaranteed to pass
  /// [validate] (dedupe cannot be repaired) — callers must re-validate.
  static String sanitize(
    String text, {
    required int maxWords,
    required bool trailingPeriod,
  }) {
    String t = text.trim();
    // Strip one layer of wrapping quotes/backticks the model may add.
    for (final String q in const <String>['"', "'", '`']) {
      if (t.length >= 2 && t.startsWith(q) && t.endsWith(q)) {
        t = t.substring(1, t.length - 1).trim();
      }
    }
    t = t.replaceAll(emoji, ' ');
    // Forbidden characters → soft replacements that keep the flow.
    t = t.replaceAllMapped(RegExp('[:;\u2014\u2013]'), (_) => ' -');
    t = t.replaceAllMapped(RegExp('[!?]'), (_) => '');
    // Internal sentence punctuation (periods not at the very end).
    final bool endsWithPeriod = t.endsWith('.');
    String body = endsWithPeriod ? t.substring(0, t.length - 1) : t;
    body = body.replaceAll('.', ' ');
    t = '$body${trailingPeriod && endsWithPeriod ? '.' : ''}';
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceAll(RegExp(r' - -+'), ' - ').trim();
    // Enforce the word budget.
    final List<String> words = t.split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.length > maxWords) {
      t = words.take(maxWords).join(' ');
    }
    return t.trim();
  }

  /// Builds the system prompt for the chat agent. The agent generates the
  /// sentence live; this prompt is the regulated part of the contract.
  static String systemPrompt(AgentComposeRequest request) {
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        'You compose ONE short casual English sentence for a member of an '
        'educational app community. It must sound like a real person typing '
        'on their phone between tasks.',
      )
      ..writeln('Hard rules:')
      ..writeln(
        '- Output ONLY the sentence itself: no quotes, no labels, '
        'no explanations, no markdown, no code, no lists.',
      )
      ..writeln(
        '- Exactly one sentence. Never use the characters '
        '! : ; \u2014 \u2013 ? anywhere in the text.',
      );
    if (request.trailingPeriod) {
      buffer.writeln('- The sentence ends with a single period.');
    } else {
      buffer.writeln('- Do not end the sentence with a period.');
    }
    buffer
      ..writeln(
        '- No emoji. Lowercase is fine. At most '
        '${request.clampedMaxWords} words.',
      )
      ..writeln(
        '- Never sound like an assistant: avoid "as an AI", '
        '"here is", "hope this helps", "let me know if".',
      )
      ..writeln(
        '- Stay factual to the context. Never invent facts, '
        'numbers, names or features that are not supported by it.',
      )
      ..writeln(
        '- Never mention bots, scripts, automation, prompts, AI '
        'or models, not even jokingly.',
      );
    if (request.avoid.isNotEmpty) {
      buffer
        ..writeln(
          'Do not repeat or closely paraphrase any of these earlier '
          'texts:',
        )
        ..writeln(
          request.avoid.take(20).map((t) => '- ${t.trim()}').join('\n'),
        );
    }
    return buffer.toString();
  }

  /// Builds the user message for the chat agent.
  static String userPrompt(AgentComposeRequest request, {String? retryNote}) {
    final StringBuffer buffer = StringBuffer();
    if (request.task.trim().isNotEmpty) {
      buffer.writeln('Task: ${request.task.trim()}');
    }
    buffer
      ..writeln('Live context:')
      ..writeln(request.context.trim())
      ..writeln();
    if (request.instruction.trim().isNotEmpty) {
      buffer.writeln('Extra instruction: ${request.instruction.trim()}');
    }
    if (retryNote != null && retryNote.trim().isNotEmpty) {
      buffer
        ..writeln('Your previous attempt violated the rules: $retryNote')
        ..writeln('Write a different sentence that follows every rule.');
    } else {
      buffer.writeln('Compose the sentence now.');
    }
    return buffer.toString();
  }
}

/// The agent-backed composer: turns an [AgentComposeRequest] into one
/// validated sentence by asking the chat's own LLM (the provider, base
/// URL, API key and model the user already chats with).
///
/// Pipeline: compose → validate → (one corrective retry) → sanitize →
/// re-validate → deliver or throw. The module never sees raw model output
/// that breaks the contract.
class AgentComposer {
  AgentComposer({required this.llm, this.maxAttempts = 2});

  final LlmClient llm;

  /// Total generation attempts per request (initial + one corrective).
  final int maxAttempts;

  Future<String> compose({
    required AgentComposeRequest request,
    required LlmConfig config,
  }) async {
    if (request.context.trim().isEmpty) {
      throw const AgentComposeException(
        'agent.compose requires a non-empty context',
      );
    }
    String? retryNote;
    String? lastText;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final AssistantTurn turn = await llm.complete(
        config: config,
        messages: <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content': ComposerGate.systemPrompt(request),
          },
          <String, dynamic>{
            'role': 'user',
            'content': ComposerGate.userPrompt(request, retryNote: retryNote),
          },
        ],
      );
      final String text = ComposerGate.preClean(turn.content);
      lastText = text;
      final ComposerVerdict verdict = ComposerGate.validate(
        text,
        maxWords: request.clampedMaxWords,
        trailingPeriod: request.trailingPeriod,
        avoid: request.avoid,
      );
      if (verdict.ok) return text;
      retryNote = verdict.violations.join(', ');
    }
    // Both attempts broke the contract — deterministic repair, then a
    // final check. Dedupe violations cannot be repaired; those fail.
    final String repaired = ComposerGate.sanitize(
      lastText ?? '',
      maxWords: request.clampedMaxWords,
      trailingPeriod: request.trailingPeriod,
    );
    final ComposerVerdict finalVerdict = ComposerGate.validate(
      repaired,
      maxWords: request.clampedMaxWords,
      trailingPeriod: request.trailingPeriod,
      avoid: request.avoid,
    );
    if (finalVerdict.ok) return repaired;
    throw AgentComposeException(
      'composer output kept violating the rules '
      '(${finalVerdict.violations.join(', ')})',
    );
  }
}
