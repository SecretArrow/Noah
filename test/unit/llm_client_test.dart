import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/llm_client.dart';

const LlmConfig _config = LlmConfig(
  baseUrl: 'https://provider.test/v1',
  apiKey: 'test-key',
  model: 'test-model',
);

void main() {
  test('parses SSE stream: content deltas + tool call accumulation', () async {
    final String sse = <String>[
      'data: {"choices":[{"delta":{"role":"assistant","content":"Hello"}}]}',
      '',
      'data: {"choices":[{"delta":{"content":" world"}}]}',
      '',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"browser_navigate","arguments":""}}]}}]}',
      '',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"url\\":\\"https://example.com\\"}"}}]}}]}',
      '',
      'data: [DONE]',
      '',
    ].join('\n');

    final http.Client mockClient = MockClient.streaming(
      (http.BaseRequest request, http.ByteStream bodyStream) async =>
          http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode(sse)),
            200,
            headers: <String, String>{'content-type': 'text/event-stream'},
          ),
    );
    final LlmClient client = LlmClient(client: mockClient);

    final List<String> deltas = <String>[];
    final AssistantTurn turn = await client.complete(
      config: _config,
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
      onDelta: deltas.add,
    );

    expect(deltas.join(), 'Hello world');
    expect(turn.content, 'Hello world');
    expect(turn.toolCalls, hasLength(1));
    expect(turn.toolCalls.first.name, 'browser_navigate');
    expect(turn.toolCalls.first.id, 'call_1');
    expect(turn.toolCalls.first.args['url'], 'https://example.com');
  });

  test('falls back to plain JSON when provider ignores stream=true', () async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'choices': <Map<String, dynamic>>[
        <String, dynamic>{
          'message': <String, dynamic>{
            'role': 'assistant',
            'content': 'Plain answer',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'tc_9',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'write_file',
                  'arguments': '{"path":"a.txt","content":"hi"}',
                },
              },
            ],
          },
        },
      ],
    };

    final http.Client mockClient = MockClient(
      (http.BaseRequest request) async => http.Response(
        jsonEncode(payload),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );
    final LlmClient client = LlmClient(client: mockClient);

    final AssistantTurn turn = await client.complete(
      config: _config,
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
    );

    expect(turn.content, 'Plain answer');
    expect(turn.toolCalls.single.name, 'write_file');
    expect(turn.toolCalls.single.args['path'], 'a.txt');
  });

  test('throws LlmException on HTTP error', () async {
    final http.Client mockClient = MockClient(
      (http.BaseRequest request) async =>
          http.Response('{"error":"invalid api key"}', 401),
    );
    final LlmClient client = LlmClient(client: mockClient);

    await expectLater(
      client.complete(
        config: _config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      ),
      throwsA(isA<LlmException>()),
    );
  });

  test('ToolCallRequest.args tolerates malformed JSON', () {
    final ToolCallRequest request = ToolCallRequest(
      id: 'x',
      name: 'browser_click',
      argumentsJson: '{not json',
    );
    expect(request.args, isEmpty);
  });

  test(
    'non-streaming tool call without name is skipped, not a crash',
    () async {
      // Some providers occasionally emit a tool_calls entry with a missing
      // function name. The old code called .toString() on null.
      final Map<String, dynamic> payload = <String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'role': 'assistant',
              'content': 'Answer text',
              'tool_calls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'tc_1',
                  'type': 'function',
                  'function': <String, dynamic>{'name': null},
                },
                <String, dynamic>{
                  'id': 'tc_2',
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': 'write_file',
                    'arguments': '{"path":"a.txt"}',
                  },
                },
              ],
            },
          },
        ],
      };

      final http.Client mockClient = MockClient(
        (http.BaseRequest request) async => http.Response(
          jsonEncode(payload),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      );
      final LlmClient client = LlmClient(client: mockClient);

      final AssistantTurn turn = await client.complete(
        config: _config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );

      expect(turn.content, 'Answer text');
      expect(turn.toolCalls, hasLength(1));
      expect(turn.toolCalls.single.name, 'write_file');
    },
  );

  test(
    'stream drop mid-content keeps partial text instead of crashing',
    () async {
      // SSE chunks then the socket dies without [DONE]; the generator
      // guarantees the data chunk is delivered before the error.
      Stream<List<int>> flakyStream() async* {
        yield utf8.encode(
          'data: {"choices":[{"delta":{"content":"Partial"}}]}\n\n',
        );
        throw Exception('connection reset');
      }

      final http.Client mockClient = MockClient.streaming(
        (http.BaseRequest request, http.ByteStream bodyStream) async =>
            http.StreamedResponse(
              flakyStream(),
              200,
              headers: <String, String>{'content-type': 'text/event-stream'},
            ),
      );
      final LlmClient client = LlmClient(client: mockClient);

      final AssistantTurn turn = await client.complete(
        config: _config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );

      expect(turn.content, 'Partial');
      expect(turn.toolCalls, isEmpty);
    },
  );

  test(
    'stream drop mid-tool-call surfaces LlmException, not a crash',
    () async {
      // Tool call arguments partially received: unusable, must throw.
      Stream<List<int>> flakyStream() async* {
        yield utf8.encode(
          'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"browser_navigate","arguments":"{\\"url\\":"}}]}}]}\n\n',
        );
        throw Exception('connection reset');
      }

      final http.Client mockClient = MockClient.streaming(
        (http.BaseRequest request, http.ByteStream bodyStream) async =>
            http.StreamedResponse(
              flakyStream(),
              200,
              headers: <String, String>{'content-type': 'text/event-stream'},
            ),
      );
      final LlmClient client = LlmClient(client: mockClient);

      await expectLater(
        client.complete(
          config: _config,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(isA<LlmException>()),
      );
    },
  );

  group('token usage capture (v1.17.0)', () {
    test('SSE usage event (empty choices) is captured', () async {
      final String sse = <String>[
        'data: {"choices":[{"delta":{"content":"Hi"}}]}',
        '',
        'data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n');
      String? capturedBody;
      final http.Client mockClient = MockClient.streaming((
        http.BaseRequest request,
        http.ByteStream bodyStream,
      ) async {
        capturedBody = await bodyStream.bytesToString();
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(sse)),
          200,
          headers: <String, String>{'content-type': 'text/event-stream'},
        );
      });
      final LlmClient client = LlmClient(client: mockClient);

      final AssistantTurn turn = await client.complete(
        config: _config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );

      expect(turn.content, 'Hi');
      expect(turn.usage, isNotNull);
      expect(turn.usage!.promptTokens, 11);
      expect(turn.usage!.completionTokens, 7);
      expect(turn.usage!.totalTokens, 18);
      // The request asks providers for usage.
      expect(capturedBody!, contains('stream_options'));
      expect(capturedBody!, contains('include_usage'));
    });

    test('non-streaming JSON usage is captured', () async {
      final http.Client mockClient = MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'Plain',
                },
              },
            ],
            'usage': <String, dynamic>{
              'prompt_tokens': 5,
              'completion_tokens': 3,
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final LlmClient client = LlmClient(client: mockClient);

      final AssistantTurn turn = await client.complete(
        config: _config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );
      expect(turn.content, 'Plain');
      expect(turn.usage!.totalTokens, 8);
    });

    test('provider rejecting stream_options gets one clean retry', () async {
      var calls = 0;
      final http.Client mockClient = MockClient((http.Request request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '{"error":{"message":"Unknown parameter: stream_options"}}',
            400,
          );
        }
        expect(request.body, isNot(contains('stream_options')));
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'Retry ok',
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final LlmClient client = LlmClient(client: mockClient);

      final AssistantTurn turn = await client.complete(
        config: _config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );
      expect(calls, 2);
      expect(turn.content, 'Retry ok');
    });
  });
}
