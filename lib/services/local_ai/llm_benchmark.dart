import 'dart:convert';

import 'package:http/http.dart' as http;

/// Tokens-per-second benchmark against a running llama-server —
/// v1.52.0 (Fase 2).
///
/// One streaming chat completion against `<baseUrl>/v1/chat/completions`
/// with a fixed counting prompt; measures time-to-first-token plus the
/// whole-generation wall clock and reports tokens/s. The [http.Client]
/// is injectable (same pattern as `OllamaRegistryClient`) so tests feed
/// a MockClient serving canned SSE.

/// One measurement of a completed benchmark run.
class LlmBenchmarkResult {
  const LlmBenchmarkResult({
    required this.totalTokens,
    required this.promptTokens,
    required this.elapsed,
    required this.firstTokenLatency,
  });

  /// Completion tokens of the answer (server-reported `usage` when the
  /// final chunk carries one, else a whitespace word count of the
  /// accumulated text — see [LlmBenchmark]).
  final int totalTokens;

  /// Prompt tokens of the fixed benchmark prompt (server-reported when
  /// available, else the whitespace word count of the prompt — an
  /// approximation documented on [LlmBenchmark]).
  final int promptTokens;

  /// Wall clock of the whole streamed generation.
  final Duration elapsed;

  /// Time from request send to the first content delta.
  final Duration firstTokenLatency;

  /// Completion tokens per second over [elapsed]. The denominator is
  /// clamped to a minimum of 1 ms — a sub-millisecond mock run must not
  /// divide by zero.
  double get tokensPerSecond {
    final int ms = elapsed.inMilliseconds < 1 ? 1 : elapsed.inMilliseconds;
    return totalTokens * 1000.0 / ms;
  }

  /// Compact English summary (`12.3 tok/s · first token 210ms · 20
  /// tokens`) — for logs and tests; the UI localizes via
  /// `ollamaBenchmarkSummary`.
  String get summary =>
      '${tokensPerSecond.toStringAsFixed(1)} tok/s · '
      'first token ${firstTokenLatency.inMilliseconds}ms · '
      '$totalTokens tokens';
}

/// Clean failure of a benchmark run (unreachable server, bad status,
/// malformed stream, empty output).
class LlmBenchmarkException implements Exception {
  LlmBenchmarkException(this.message);

  final String message;

  @override
  String toString() => 'LlmBenchmarkException: $message';
}

/// Streaming tokens/s benchmark — v1.52.0 (Fase 2).
///
/// Token counting strategy (documented approximation):
/// * preferred: `usage.completion_tokens` / `usage.prompt_tokens` from
///   the final chunk — llama-server sends `usage` in the last chunk by
///   default, so this is the accurate path;
/// * fallback: whitespace-split word count of the accumulated answer
///   text. The fixed prompt asks for "the numbers from one to twenty,
///   separated by spaces", so the answer is single-space-separated
///   numbers and its word count equals the token count for every
///   well-behaved model.
class LlmBenchmark {
  LlmBenchmark({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The fixed benchmark prompt (10 words): stable, tiny, and its
  /// expected answer is whitespace-separated numbers.
  static const String kPrompt =
      'Say the numbers from one to twenty, separated by spaces.';

  /// Whitespace word count used for the token approximations.
  static int wordCount(String text) {
    final List<String> words = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .toList(growable: false);
    return words.length;
  }

  Future<LlmBenchmarkResult> run({
    required String baseUrl,
    required String model,
    int maxTokens = 96,
  }) async {
    String base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final Uri uri = Uri.parse('$base/v1/chat/completions');
    final Stopwatch watch = Stopwatch()..start();

    final http.Request request = http.Request('POST', uri)
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(<String, dynamic>{
        'model': model,
        'stream': true,
        'max_tokens': maxTokens,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': kPrompt},
        ],
      });

    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (error) {
      throw LlmBenchmarkException('cannot reach the server: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmBenchmarkException('HTTP ${response.statusCode}');
    }

    final StringBuffer text = StringBuffer();
    bool sawFirstToken = false;
    Duration firstTokenLatency = Duration.zero;
    int usageCompletionTokens = -1;
    int usagePromptTokens = -1;
    String buffer = '';

    /// Handles one `data: …` SSE line (comments/blank lines ignored).
    void handleLine(String raw) {
      final String line = raw.trim();
      if (line.isEmpty || !line.startsWith('data:')) return;
      final String payload = line.substring(5).trim();
      if (payload == '[DONE]') return; // stream-end marker
      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException catch (error) {
        throw LlmBenchmarkException('malformed SSE payload: $error');
      }
      if (decoded is! Map<String, dynamic>) {
        throw LlmBenchmarkException('malformed SSE payload');
      }
      final Object? usage = decoded['usage'];
      if (usage is Map<String, dynamic>) {
        final int? completion = (usage['completion_tokens'] as num?)?.toInt();
        final int? prompt = (usage['prompt_tokens'] as num?)?.toInt();
        if (completion != null && completion >= 0) {
          usageCompletionTokens = completion;
        }
        if (prompt != null && prompt >= 0) {
          usagePromptTokens = prompt;
        }
      }
      final Object? choices = decoded['choices'];
      if (choices is List<dynamic> && choices.isNotEmpty) {
        final Object? head = choices.first;
        if (head is Map<String, dynamic>) {
          final Object? delta = head['delta'];
          if (delta is Map<String, dynamic>) {
            final Object? content = delta['content'];
            if (content is String && content.isNotEmpty) {
              if (!sawFirstToken) {
                sawFirstToken = true;
                firstTokenLatency = watch.elapsed;
              }
              text.write(content);
            }
          }
        }
      }
    }

    try {
      await for (final List<int> chunk in response.stream) {
        // allowMalformed: a chunk boundary may split a multi-byte char.
        buffer = '$buffer${utf8.decode(chunk, allowMalformed: true)}';
        int nl = buffer.indexOf('\n');
        while (nl >= 0) {
          final String line = buffer.substring(0, nl);
          buffer = buffer.substring(nl + 1);
          handleLine(line);
          nl = buffer.indexOf('\n');
        }
      }
      if (buffer.trim().isNotEmpty) handleLine(buffer); // trailing line
    } on LlmBenchmarkException {
      rethrow;
    } catch (error) {
      throw LlmBenchmarkException('broken SSE stream: $error');
    }

    final Duration elapsed = watch.elapsed;
    final String answer = text.toString();
    final int totalTokens = usageCompletionTokens >= 0
        ? usageCompletionTokens
        : wordCount(answer);
    if (totalTokens <= 0) {
      throw LlmBenchmarkException('the model produced no output');
    }
    return LlmBenchmarkResult(
      totalTokens: totalTokens,
      promptTokens: usagePromptTokens >= 0
          ? usagePromptTokens
          : wordCount(kPrompt),
      elapsed: elapsed,
      firstTokenLatency: sawFirstToken ? firstTokenLatency : elapsed,
    );
  }
}

// -- UI state of the last benchmark run -----------------------------------

/// Phase of the last benchmark run (Ollama Manage → Server tab).
enum BenchmarkRunStatus { idle, running, done, failed }

/// Last-run snapshot kept OUTSIDE [LlmServerState] (the §2 controller
/// state is a frozen v1.51.0 contract — benchmark progress is screen
/// state, surfaced through `benchmarkRunProvider` in di.dart).
class BenchmarkRunState {
  const BenchmarkRunState({
    this.status = BenchmarkRunStatus.idle,
    this.result,
    this.message = '',
  });

  final BenchmarkRunStatus status;

  /// Set when [status] is [BenchmarkRunStatus.done].
  final LlmBenchmarkResult? result;

  /// Clean failure text when [status] is [BenchmarkRunStatus.failed].
  final String message;
}
