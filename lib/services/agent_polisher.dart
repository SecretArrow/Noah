import 'agent_composer.dart';
import 'llm_client.dart';

/// One reply-polish request from a chat module (`zagents.agent.polish`).
///
/// Unlike the strict one-sentence [AgentComposeRequest] contract, the
/// polisher turns a template into a natural multi-sentence social reply
/// (Facebook comment/Messenger, X/Twitter mention): it may contain
/// question marks and normal punctuation, and it answers the incoming
/// message in the sender's own language. The module supplies the template
/// (already slot-filled) plus the live message text; the chat's own agent
/// (the LLM configured for this chat) rewrites the template at the moment
/// it is needed.
class AgentPolishRequest {
  const AgentPolishRequest({
    required this.template,
    required this.context,
    this.language = '',
    this.tone = defaultTone,
    this.maxChars = defaultMaxChars,
    this.allowEmoji = false,
    this.avoid = const <String>[],
  });

  /// Char budget applied to the polished reply (X free accounts allow 280).
  static const int defaultMaxChars = 280;
  static const int minMaxChars = 20;
  static const int maxMaxChars = 500;

  /// Default voice when the module does not pick one.
  static const String defaultTone = 'friendly';

  /// The reply template with all placeholders already filled by the
  /// module. Required.
  final String template;

  /// The live incoming message / comment / mention being answered.
  /// Required.
  final String context;

  /// `''` = auto (match the language of [context]); otherwise a language
  /// code such as `id`, `en`, `es`.
  final String language;

  /// `friendly`, `professional` or `casual`.
  final String tone;

  /// Maximum number of characters the polished reply may use (clamped
  /// [minMaxChars]..[maxMaxChars]).
  final int maxChars;

  /// Whether the polished reply may carry a simple emoji (default off —
  /// emoji-free text reads human on every platform).
  final bool allowEmoji;

  /// Recent replies the polished text must not repeat.
  final List<String> avoid;

  int get clampedMaxChars => maxChars.clamp(minMaxChars, maxMaxChars);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'template': template,
    'context': context,
    'language': language,
    'tone': tone,
    'maxChars': clampedMaxChars,
    'allowEmoji': allowEmoji,
    'avoid': avoid,
  };
}

/// Thrown when the polisher could not produce a reply that passes the
/// gate (missing connection settings, provider failure, repeated rule
/// violations). Modules are expected to fall back to the slot-filled
/// template and continue.
class AgentPolishException implements Exception {
  const AgentPolishException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of checking one polished candidate against the polisher rules.
class PolisherVerdict {
  const PolisherVerdict(this.violations);

  final List<String> violations;

  bool get ok => violations.isEmpty;
}

/// The deterministic half of the reply polisher: validation +
/// sanitization. Raw model output is never trusted — everything is
/// pre-cleaned, re-checked, sanitized once and re-validated before the
/// module sees it.
abstract final class ReplyPolishGate {
  /// Markdown / formatting artifacts that look machine-generated on
  /// social platforms: bold, italics/underline, headings, code spans,
  /// list items, table pipes.
  static final RegExp markdown = RegExp(
    r'(\*\*|__|`|^#{1,6}\s|\n\s*[-*]\s|\|)',
    multiLine: true,
  );

  /// An unfilled template slot such as `{name}` that leaked into the
  /// output (the module must fill slots BEFORE calling the polisher).
  static final RegExp placeholder = RegExp(r'\{[a-zA-Z_][a-zA-Z0-9_]*\}');

  /// A link the model may have invented — URLs are only allowed when the
  /// template or the incoming message already contained one.
  static final RegExp url = RegExp(r'(https?://|www\.)', caseSensitive: false);

  /// Assistant-style phrasings that instantly expose the reply as
  /// machine-written.
  static const List<String> assistantPhrases = <String>[
    'as an ai',
    'sebagai ai',
    'sebagai model',
    'i am an ai',
    "i'm an ai",
    'hope this helps',
    'let me know if',
  ];

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Light pre-clean applied to raw model output BEFORE validation:
  /// trim, collapse all whitespace (including newlines — a polished reply
  /// is a single paragraph), strip one layer of wrapping quotes/backticks.
  static String preClean(String text) {
    String t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final String q in const <String>['"', "'", '`']) {
      if (t.length >= 2 && t.startsWith(q) && t.endsWith(q)) {
        t = t.substring(1, t.length - 1).trim();
      }
    }
    return t;
  }

  /// Validates [text] against the polisher contract. Returns every
  /// violation found (empty list = acceptable).
  static PolisherVerdict validate(
    String text, {
    required int maxChars,
    required bool allowEmoji,
    required String template,
    required String context,
    List<String> avoid = const <String>[],
  }) {
    final String t = _normalize(text);
    final List<String> problems = <String>[];
    if (t.isEmpty) {
      problems.add('empty output');
      return PolisherVerdict(problems);
    }
    if (text.length > maxChars) {
      problems.add('over $maxChars characters');
    }
    if (!allowEmoji && ComposerGate.emoji.hasMatch(text)) {
      problems.add('emoji');
    }
    if (markdown.hasMatch(text)) problems.add('markdown formatting');
    if (placeholder.hasMatch(text)) problems.add('unfilled template slot');
    final String known = '$template $context';
    if (url.hasMatch(text) && !url.hasMatch(known)) {
      problems.add('invented link');
    }
    for (final String phrase in assistantPhrases) {
      if (t.contains(phrase)) {
        problems.add('assistant phrasing');
        break;
      }
    }
    final String norm = _normalize(text);
    for (final String seen in avoid) {
      if (_normalize(seen) == norm && norm.isNotEmpty) {
        problems.add('repeats an earlier reply');
        break;
      }
    }
    return PolisherVerdict(problems);
  }

  /// Deterministic last-resort repair: strip wrapping quotes, drop emoji
  /// (unless allowed), remove markdown artifacts and unfilled slots,
  /// drop invented links, collapse whitespace and cut to the char budget
  /// at a word boundary. The result is not guaranteed to pass
  /// [validate] (assistant phrasing and dedupe cannot be repaired) —
  /// callers must re-validate.
  static String sanitize(
    String text, {
    required int maxChars,
    required bool allowEmoji,
  }) {
    String t = text.trim();
    // Strip one layer of wrapping quotes/backticks the model may add.
    for (final String q in const <String>['"', "'", '`']) {
      if (t.length >= 2 && t.startsWith(q) && t.endsWith(q)) {
        t = t.substring(1, t.length - 1).trim();
      }
    }
    if (!allowEmoji) t = t.replaceAll(ComposerGate.emoji, ' ');
    // Markdown artifacts → removed or softened.
    t = t.replaceAll('**', '');
    t = t.replaceAll('__', '');
    t = t.replaceAll('`', '');
    t = t.replaceAllMapped(RegExp(r'(^|\n)\s*#{1,6}\s*'), (_) => ' ');
    t = t.replaceAllMapped(RegExp(r'\n\s*[-*]\s+'), (_) => ' ');
    t = t.replaceAll('|', ' ');
    // Unfilled slots → dropped (better a short reply than a broken one).
    t = t.replaceAll(placeholder, ' ');
    // Invented links → dropped token by token.
    t = t.replaceAllMapped(
      RegExp(r'\b(?:https?://|www\.)\S+', caseSensitive: false),
      (_) => ' ',
    );
    // Collapse and enforce the char budget at a word boundary.
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > maxChars) {
      t = t.substring(0, maxChars);
      final int cut = t.lastIndexOf(' ');
      if (cut > maxChars * 0.5) t = t.substring(0, cut);
      t = t.trim();
      if (t.endsWith(',')) t = t.substring(0, t.length - 1);
    }
    return t.trim();
  }

  /// Builds the system prompt for the chat agent. The agent rewrites the
  /// template live; this prompt is the regulated part of the contract.
  static String systemPrompt(AgentPolishRequest request) {
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        'You polish ONE reply for a social media page (a Facebook comment '
        'or Messenger message, or an X/Twitter mention). The module gives '
        'you a reply template plus the incoming message it answers; you '
        'rewrite the template into the final reply a real person would '
        'send from the page.',
      )
      ..writeln('Hard rules:')
      ..writeln(
        '- Output ONLY the reply text itself: no quotes, no labels, no '
        'explanations, no markdown, no lists, no signature.',
      )
      ..writeln(
        '- Keep every promise and fact from the template. Never invent '
        'prices, dates, names, links or features that neither the '
        'template nor the incoming message support.',
      )
      ..writeln(
        '- Answer what the incoming message actually says — weave in a '
        'natural acknowledgment of it, do not copy it word for word.',
      );
    if (request.language.trim().isEmpty || request.language == 'auto') {
      buffer.writeln(
        '- Reply in the SAME language the incoming message is written '
        'in.',
      );
    } else {
      buffer.writeln(
        '- Reply in this language: ${request.language.trim()} (regardless '
        'of the incoming message language).',
      );
    }
    buffer
      ..writeln(
        '- 1 to 3 short sentences. Natural punctuation is fine (periods, '
        'commas, question marks). No hashtag unless the template has one.',
      )
      ..writeln(
        '- Sound like a warm human typing on a phone — casual contractions '
        'are fine. Never sound like an assistant: avoid "as an AI", '
        '"sebagai AI", "hope this helps", "let me know if".',
      )
      ..writeln(
        '- No emoji, no hashtags, no mentions, no link shorteners unless '
        'the template already contains them.',
      )
      ..writeln(
        '- At most ${request.clampedMaxChars} characters. Never mention '
        'bots, scripts, automation, templates, AI or models — not even '
        'jokingly.',
      );
    if (request.allowEmoji) {
      buffer.writeln('- You may use at most one simple, natural emoji.');
    }
    if (request.avoid.isNotEmpty) {
      buffer
        ..writeln(
          'Do not repeat or closely paraphrase any of these earlier '
          'replies:',
        )
        ..writeln(request.avoid.take(8).map((t) => '- ${t.trim()}').join('\n'));
    }
    return buffer.toString();
  }

  /// Builds the user message for the chat agent.
  static String userPrompt(AgentPolishRequest request, {String? retryNote}) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('Incoming message:')
      ..writeln(request.context.trim())
      ..writeln()
      ..writeln('Template:')
      ..writeln(request.template.trim())
      ..writeln();
    buffer
      ..writeln(
        'Tone: ${request.tone.trim().isEmpty ? AgentPolishRequest.defaultTone : request.tone.trim()}',
      )
      ..writeln('Max characters: ${request.clampedMaxChars}');
    if (retryNote != null && retryNote.trim().isNotEmpty) {
      buffer
        ..writeln('Your previous attempt violated the rules: $retryNote')
        ..writeln('Write a different reply that follows every rule.');
    } else {
      buffer.writeln('Polish the template into the final reply now.');
    }
    return buffer.toString();
  }
}

/// The agent-backed reply polisher: turns an [AgentPolishRequest] into one
/// validated, natural reply by asking the chat's own LLM (the provider,
/// base URL, API key and model the user already chats with).
///
/// Pipeline: polish → validate → (one corrective retry) → sanitize →
/// re-validate → deliver or throw. The module never sees raw model output
/// that breaks the contract.
class AgentPolisher {
  AgentPolisher({required this.llm, this.maxAttempts = 2});

  final LlmClient llm;

  /// Total generation attempts per request (initial + one corrective).
  final int maxAttempts;

  Future<String> polish({
    required AgentPolishRequest request,
    required LlmConfig config,
  }) async {
    if (request.template.trim().isEmpty) {
      throw const AgentPolishException(
        'agent.polish requires a non-empty template',
      );
    }
    if (request.context.trim().isEmpty) {
      throw const AgentPolishException(
        'agent.polish requires a non-empty context',
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
            'content': ReplyPolishGate.systemPrompt(request),
          },
          <String, dynamic>{
            'role': 'user',
            'content': ReplyPolishGate.userPrompt(
              request,
              retryNote: retryNote,
            ),
          },
        ],
      );
      final String text = ReplyPolishGate.preClean(turn.content);
      lastText = text;
      final PolisherVerdict verdict = ReplyPolishGate.validate(
        text,
        maxChars: request.clampedMaxChars,
        allowEmoji: request.allowEmoji,
        template: request.template,
        context: request.context,
        avoid: request.avoid,
      );
      if (verdict.ok) return text;
      retryNote = verdict.violations.join(', ');
    }
    // Both attempts broke the contract — deterministic repair, then a
    // final check. Assistant phrasing and dedupe violations cannot be
    // repaired; those fail so the module can fall back to its template.
    final String repaired = ReplyPolishGate.sanitize(
      lastText ?? '',
      maxChars: request.clampedMaxChars,
      allowEmoji: request.allowEmoji,
    );
    final PolisherVerdict finalVerdict = ReplyPolishGate.validate(
      repaired,
      maxChars: request.clampedMaxChars,
      allowEmoji: request.allowEmoji,
      template: request.template,
      context: request.context,
      avoid: request.avoid,
    );
    if (finalVerdict.ok) return repaired;
    throw AgentPolishException(
      'polisher output kept violating the rules '
      '(${finalVerdict.violations.join(', ')})',
    );
  }
}
