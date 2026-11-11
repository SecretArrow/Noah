import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/local_ai/llm_benchmark.dart';

/// Canned SSE: three content deltas, a final usage chunk (llama-server
/// sends `usage` in the last chunk by default) and the [DONE] marker.
const String _sseWithUsage =
    ''
    'data: {"choices":[{"delta":{"content":"one two "}}]}\n'
    'data: {"choices":[{"delta":{"content":"three four "}}]}\n'
    'data: {"choices":[{"delta":{"content":"five"}}]}\n'
    'data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":11,"completion_tokens":20}}\n'
    'data: [DONE]\n';

/// Same answer but WITHOUT a usage chunk — the word-count fallback path.
const String _sseNoUsage =
    ''
    'data: {"choices":[{"delta":{"content":"one two three four five"}}]}\n'
    'data: {"choices":[{"delta":{"content":" six seven eight nine ten"}}]}\n'
    'data: [DONE]\n';

http.Client _sseClient(
  String body, {
  int status = 200,
  List<http.Request>? requests,
}) => MockClient((http.Request request) async {
  requests?.add(request);
  return http.Response(body, status);
});

void main() {
  group('LlmBenchmarkResult', () {
    test('tokensPerSecond clamps a sub-millisecond elapsed to 1 ms', () {
      const LlmBenchmarkResult result = LlmBenchmarkResult(
        totalTokens: 20,
        promptTokens: 11,
        elapsed: Duration.zero,
        firstTokenLatency: Duration.zero,
      );
      expect(result.tokensPerSecond, 20000.0);
    });

    test('summary carries tok/s, first-token latency and token count', () {
      const LlmBenchmarkResult result = LlmBenchmarkResult(
        totalTokens: 20,
        promptTokens: 11,
        elapsed: Duration(milliseconds: 2000),
        firstTokenLatency: Duration(milliseconds: 210),
      );
      expect(result.tokensPerSecond, 10.0);
      expect(result.summary, contains('10.0 tok/s'));
      expect(result.summary, contains('first token 210ms'));
      expect(result.summary, contains('20 tokens'));
    });
  });

  group('LlmBenchmark.run', () {
    test('happy path: usage chunk wins, timings measured', () async {
      final List<http.Request> requests = <http.Request>[];
      final LlmBenchmark benchmark = LlmBenchmark(
        client: _sseClient(_sseWithUsage, requests: requests),
      );

      final LlmBenchmarkResult result = await benchmark.run(
        baseUrl: 'http://127.0.0.1:11434/',
        model: 'qwen3:0.6b',
      );

      // Request shape: OpenAI-compatible streaming chat completion.
      final http.Request sent = requests.single;
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'http://127.0.0.1:11434/v1/chat/completions');
      final Map<String, dynamic> body =
          jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['model'], 'qwen3:0.6b');
      expect(body['stream'], isTrue);
      expect(body['max_tokens'], 96);
      expect(
        (body['messages'] as List<dynamic>).single['content'],
        LlmBenchmark.kPrompt,
      );

      // Token counts: server-reported usage, both completion and prompt.
      expect(result.totalTokens, 20);
      expect(result.promptTokens, 11);
      expect(result.elapsed.inMilliseconds, greaterThanOrEqualTo(0));
      expect(result.firstTokenLatency.inMilliseconds, greaterThanOrEqualTo(0));
      expect(result.tokensPerSecond, greaterThan(0));
    });

    test('no usage chunk → whitespace word-count fallback', () async {
      final LlmBenchmark benchmark = LlmBenchmark(
        client: _sseClient(_sseNoUsage),
      );

      final LlmBenchmarkResult result = await benchmark.run(
        baseUrl: 'http://127.0.0.1:11434',
        model: 'm',
      );

      // "one two … ten" → 10 words == 10 approximate tokens; the prompt
      // word count (10) approximates the prompt tokens.
      expect(result.totalTokens, 10);
      expect(result.promptTokens, 10);
    });

    test('HTTP 500 → LlmBenchmarkException with a clean message', () async {
      final LlmBenchmark benchmark = LlmBenchmark(
        client: _sseClient('boom', status: 500),
      );

      await expectLater(
        benchmark.run(baseUrl: 'http://127.0.0.1:11434', model: 'm'),
        throwsA(
          isA<LlmBenchmarkException>().having(
            (LlmBenchmarkException e) => e.message,
            'message',
            'HTTP 500',
          ),
        ),
      );
    });

    test('network failure → LlmBenchmarkException', () async {
      final LlmBenchmark benchmark = LlmBenchmark(
        client: MockClient((http.Request request) async {
          throw Exception('socket closed');
        }),
      );

      await expectLater(
        benchmark.run(baseUrl: 'http://127.0.0.1:11434', model: 'm'),
        throwsA(isA<LlmBenchmarkException>()),
      );
    });

    test('a stream with no content → “produced no output”', () async {
      const String empty = 'data: {"choices":[{"delta":{}}]}\ndata: [DONE]\n';
      final LlmBenchmark benchmark = LlmBenchmark(client: _sseClient(empty));

      await expectLater(
        benchmark.run(baseUrl: 'http://127.0.0.1:11434', model: 'm'),
        throwsA(
          isA<LlmBenchmarkException>().having(
            (LlmBenchmarkException e) => e.message,
            'message',
            contains('no output'),
          ),
        ),
      );
    });

    test('malformed SSE payload → LlmBenchmarkException', () async {
      const String broken =
          'data: {not json at all}\ndata: {"choices":[{"delta":{"content":"x"}}]}\n';
      final LlmBenchmark benchmark = LlmBenchmark(client: _sseClient(broken));

      await expectLater(
        benchmark.run(baseUrl: 'http://127.0.0.1:11434', model: 'm'),
        throwsA(
          isA<LlmBenchmarkException>().having(
            (LlmBenchmarkException e) => e.message,
            'message',
            contains('malformed SSE'),
          ),
        ),
      );
    });

    test('non-JSON body → LlmBenchmarkException', () async {
      final LlmBenchmark benchmark = LlmBenchmark(
        client: _sseClient('<html>not sse</html>'),
      );

      await expectLater(
        benchmark.run(baseUrl: 'http://127.0.0.1:11434', model: 'm'),
        throwsA(isA<LlmBenchmarkException>()),
      );
    });
  });
}
