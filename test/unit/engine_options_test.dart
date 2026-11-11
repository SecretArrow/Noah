// v1.49.4 — per-provider engine options: Anthropic Messages / OpenAI Chat
// Completions / OpenAI Responses / Auto. Covers the shared transports in
// wire_transports.dart, the base-client engine routing, the AgentRouter
// per-model protocol cache + the "use /v1/responses" one-shot fallback
// (the gpt-6.1-sol production failure) and the settings serialization.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agentrouter_client.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/wire_transports.dart';

const String _responsesHintBody =
    '{"error":{"message":"模型 gpt-6.1-sol 不支持 /v1/chat/completions 接口，'
    '请改用 /v1/responses（OpenAI Responses API）。 Model gpt-6.1-sol does not '
    'support /v1/chat/completions, please use /v1/responses instead. '
    '(request id: 202610281452...)","type":"new_api_error"}}';

http.StreamedResponse _jsonResponse(String body, {int status = 200}) =>
    http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

http.StreamedResponse _sseResponse(String body) => http.StreamedResponse(
  Stream<List<int>>.value(utf8.encode(body)),
  200,
  headers: <String, String>{'content-type': 'text/event-stream'},
);

Map<String, String> _lower(Map<String, String> headers) => <String, String>{
  for (final MapEntry<String, String> e in headers.entries)
    e.key.toLowerCase(): e.value,
};

String _responsesSse(String text) =>
    'data: {"type":"response.output_text.delta","delta":"$text"}\n\n'
    'data: {"type":"response.completed","response":{"usage":'
    '{"input_tokens":5,"output_tokens":3}}}\n\n';

void main() {
  setUp(AgentRouterLlmClient.clearProtocolCache);

  group('needsResponsesApi detector', () {
    test('matches the production gateway rejection (both wordings)', () {
      expect(needsResponsesApi(_responsesHintBody), isTrue);
      expect(
        needsResponsesApi(
          'Model gpt-6.1-sol does not support /v1/chat/completions, '
          'please use /v1/responses instead.',
        ),
        isTrue,
      );
    });

    test('rejects unrelated 400s and WAF pages', () {
      expect(needsResponsesApi('Invalid model id'), isFalse);
      expect(needsResponsesApi('acw_sc__v2 captcha page'), isFalse);
      expect(needsResponsesApi(''), isFalse);
      // One path alone is not the hint.
      expect(needsResponsesApi('see /v1/responses docs'), isFalse);
      expect(needsResponsesApi('chat/completions is deprecated'), isFalse);
    });
  });

  group('Responses request builder', () {
    test('maps system/user/assistant/tool messages to input items', () {
      final LlmConfig config = LlmConfig(
        baseUrl: 'https://x.test/v1',
        apiKey: 'k',
        model: 'gpt-6.1-sol',
        maxTokens: 512,
      );
      final Map<String, dynamic> body = buildResponsesRequestBody(
        config: config,
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': 'be brief'},
          <String, dynamic>{'role': 'system', 'content': 'stay safe'},
          <String, dynamic>{'role': 'user', 'content': 'hi'},
          <String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'look:'},
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{
                  'url': 'data:image/png;base64,QUJD',
                },
              },
            ],
          },
          <String, dynamic>{'role': 'assistant', 'content': 'earlier reply'},
          <String, dynamic>{
            'role': 'assistant',
            'content': '',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'calculator',
                  'arguments': '{"expression":"2+2"}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': '4',
          },
        ],
        tools: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': 'calculator',
              'description': 'Evaluate arithmetic',
              'parameters': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
        ],
      );

      expect(body['model'], 'gpt-6.1-sol');
      expect(body['stream'], isTrue);
      expect(body['store'], isFalse);
      expect(body['max_output_tokens'], 512);
      expect(body['instructions'], 'be brief\n\nstay safe');
      // Tools use the FLAT Responses schema, not the nested chat one.
      expect(
        (body['tools'] as List<Map<String, dynamic>>).single,
        <String, dynamic>{
          'type': 'function',
          'name': 'calculator',
          'description': 'Evaluate arithmetic',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
        },
      );

      final List<Map<String, dynamic>> input = (body['input'] as List)
          .cast<Map<String, dynamic>>();
      expect(input, hasLength(5));
      // user string → input_text part
      expect(input[0]['role'], 'user');
      expect((input[0]['content'] as List).single, <String, dynamic>{
        'type': 'input_text',
        'text': 'hi',
      });
      // user array → input_text + input_image (data URI kept intact)
      expect(input[1]['role'], 'user');
      final List<Map<String, dynamic>> parts = (input[1]['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(parts[0]['type'], 'input_text');
      expect(parts[1]['type'], 'input_image');
      expect(parts[1]['image_url'], 'data:image/png;base64,QUJD');
      // assistant text → output_text part
      expect(input[2]['role'], 'assistant');
      expect((input[2]['content'] as List).single, <String, dynamic>{
        'type': 'output_text',
        'text': 'earlier reply',
      });
      // assistant tool_calls → function_call item
      expect(input[3], <String, dynamic>{
        'type': 'function_call',
        'call_id': 'call_1',
        'name': 'calculator',
        'arguments': '{"expression":"2+2"}',
      });
      // tool result → function_call_output
      expect(input[4], <String, dynamic>{
        'type': 'function_call_output',
        'call_id': 'call_1',
        'output': '4',
      });
    });

    test('max_output_tokens omitted when the config cap is unset', () {
      final Map<String, dynamic> body = buildResponsesRequestBody(
        config: const LlmConfig(
          baseUrl: 'https://x.test/v1',
          apiKey: 'k',
          model: 'm',
        ),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );
      expect(body.containsKey('max_output_tokens'), isFalse);
      expect(body.containsKey('instructions'), isFalse);
    });
  });

  group('Responses response parsing', () {
    test('full JSON: message text, function calls and usage', () {
      final AssistantTurn turn = parseResponsesMessage(
        jsonEncode(<String, dynamic>{
          'id': 'resp_1',
          'object': 'response',
          'status': 'completed',
          'output': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'reasoning', 'summary': <Object>[]},
            <String, dynamic>{
              'type': 'message',
              'role': 'assistant',
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'output_text', 'text': 'Hello '},
                <String, dynamic>{'type': 'output_text', 'text': 'world'},
              ],
            },
            <String, dynamic>{
              'type': 'function_call',
              'id': 'fc_1',
              'call_id': 'call_9',
              'name': 'calc',
              'arguments': '{"x":1}',
            },
          ],
          'usage': <String, dynamic>{
            'input_tokens': 7,
            'output_tokens': 2,
            'total_tokens': 9,
          },
        }),
      );
      expect(turn.content, 'Hello world');
      expect(turn.toolCalls, hasLength(1));
      expect(turn.toolCalls.single.id, 'call_9');
      expect(turn.toolCalls.single.name, 'calc');
      expect(turn.toolCalls.single.argumentsJson, '{"x":1}');
      expect(turn.usage!.promptTokens, 7);
      expect(turn.usage!.completionTokens, 2);
    });

    test('error payloads surface the provider message', () {
      expect(
        () => parseResponsesMessage(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'boom'},
          }),
        ),
        throwsA(
          isA<LlmException>().having(
            (LlmException e) => e.message,
            'message',
            'boom',
          ),
        ),
      );
    });

    test('SSE: text deltas, tool accumulation and final usage', () async {
      final http.ByteStream stream = http.ByteStream.fromBytes(
        utf8.encode(
          'data: {"type":"response.output_text.delta","delta":"He"}\n\n'
          'data: {"type":"response.output_text.delta","delta":"y"}\n\n'
          'data: {"type":"response.output_item.added","output_index":0,'
          '"item":{"type":"function_call","id":"fc_1","call_id":"call_1",'
          '"name":"calc","arguments":""}}\n\n'
          'data: {"type":"response.function_call_arguments.delta",'
          '"item_id":"fc_1","delta":"{\\"expression\\":"}\n\n'
          'data: {"type":"response.function_call_arguments.delta",'
          '"item_id":"fc_1","delta":"\\"2+2\\"}"}\n\n'
          'data: {"type":"response.output_item.done","output_index":0,'
          '"item":{"type":"function_call","id":"fc_1","call_id":"call_1",'
          '"name":"calc","arguments":"{\\"expression\\":\\"2+2\\"}"}}\n\n'
          'data: {"type":"response.completed","response":{"usage":'
          '{"input_tokens":9,"output_tokens":4}}}\n\n',
        ),
      );
      final StringBuffer deltas = StringBuffer();
      final AssistantTurn turn = await consumeResponsesStream(
        stream,
        deltas.write,
        null,
      );
      expect(deltas.toString(), 'Hey');
      expect(turn.content, 'Hey');
      expect(turn.toolCalls, hasLength(1));
      expect(turn.toolCalls.single.id, 'call_1');
      expect(turn.toolCalls.single.name, 'calc');
      // output_item.done replaced the accumulated deltas with the
      // authoritative complete arguments.
      expect(turn.toolCalls.single.argumentsJson, '{"expression":"2+2"}');
      expect(turn.usage!.promptTokens, 9);
      expect(turn.usage!.completionTokens, 4);
    });

    test('SSE: response.failed becomes an LlmException', () async {
      final http.ByteStream stream = http.ByteStream.fromBytes(
        utf8.encode(
          'data: {"type":"response.failed","response":{"status":"failed",'
          '"error":{"code":"server_error","message":"kaboom"}}}\n\n',
        ),
      );
      await expectLater(
        consumeResponsesStream(stream, null, null),
        throwsA(
          isA<LlmException>().having(
            (LlmException e) => e.message,
            'message',
            'kaboom',
          ),
        ),
      );
    });
  });

  group('base client engine routing', () {
    test(
      'engine anthropic POSTs {base}/messages with protocol headers',
      () async {
        final List<http.BaseRequest> requests = <http.BaseRequest>[];
        final LlmClient client = LlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            requests.add(request);
            return _jsonResponse(
              jsonEncode(<String, dynamic>{
                'content': <Map<String, dynamic>>[
                  <String, dynamic>{'type': 'text', 'text': 'anthropic turn'},
                ],
                'usage': <String, dynamic>{
                  'input_tokens': 2,
                  'output_tokens': 1,
                },
              }),
            );
          }),
        );
        final AssistantTurn turn = await client.complete(
          config: const LlmConfig(
            baseUrl: 'https://provider.test/v1',
            apiKey: 'key-anthropic',
            model: 'claude-x',
            engine: LlmEngine.anthropic,
          ),
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );
        expect(turn.content, 'anthropic turn');
        expect(
          requests.single.url.toString(),
          'https://provider.test/v1/messages',
        );
        final Map<String, String> headers = _lower(requests.single.headers);
        expect(headers['x-api-key'], 'key-anthropic');
        expect(headers['authorization'], 'Bearer key-anthropic');
        expect(headers['anthropic-version'], '2023-06-01');
      },
    );

    test('engine openaiResponses POSTs {base}/responses with Bearer', () async {
      final List<http.BaseRequest> requests = <http.BaseRequest>[];
      final LlmClient client = LlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          requests.add(request);
          return _sseResponse(_responsesSse('responses turn'));
        }),
      );
      final AssistantTurn turn = await client.complete(
        config: const LlmConfig(
          baseUrl: 'https://provider.test/v1',
          apiKey: 'key-r',
          model: 'gpt-6.1-sol',
          engine: LlmEngine.openaiResponses,
        ),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );
      expect(turn.content, 'responses turn');
      expect(
        requests.single.url.toString(),
        'https://provider.test/v1/responses',
      );
      final Map<String, String> headers = _lower(requests.single.headers);
      expect(headers['authorization'], 'Bearer key-r');
      final Map<String, dynamic> body = jsonDecode(
        (requests.single as http.Request).body,
      ) as Map<String, dynamic>;
      expect(body['model'], 'gpt-6.1-sol');
      expect(body['store'], isFalse);
    });

    test(
      'auto retries ONCE through /responses when the 400 names it',
      () async {
        final List<String> paths = <String>[];
        final LlmClient client = LlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/chat/completions')) {
              return _jsonResponse(_responsesHintBody, status: 400);
            }
            return _sseResponse(_responsesSse('saved by responses'));
          }),
        );
        final AssistantTurn turn = await client.complete(
          config: const LlmConfig(
            baseUrl: 'https://provider.test/v1',
            apiKey: 'k',
            model: 'gpt-6.1-sol',
          ),
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );
        expect(turn.content, 'saved by responses');
        expect(paths, <String>['/v1/chat/completions', '/v1/responses']);
      },
    );

    test('pinned openai keeps the 400 (no silent protocol switch)', () async {
      final List<String> paths = <String>[];
      final LlmClient client = LlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          paths.add(request.url.path);
          return _jsonResponse(_responsesHintBody, status: 400);
        }),
      );
      await expectLater(
        client.complete(
          config: const LlmConfig(
            baseUrl: 'https://provider.test/v1',
            apiKey: 'k',
            model: 'gpt-6.1-sol',
            engine: LlmEngine.openai,
          ),
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(isA<LlmException>()),
      );
      expect(paths, <String>['/v1/chat/completions']);
    });
  });

  group('AgentRouter engine options (v1.49.4)', () {
    test(
      'auto: gpt-6.1-sol 400 hint falls back to /responses, cache follows',
      () async {
        final List<String> paths = <String>[];
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/chat/completions')) {
              return _jsonResponse(_responsesHintBody, status: 400);
            }
            return _sseResponse(_responsesSse('sol via responses'));
          }),
        );
        const LlmConfig config = LlmConfig(
          baseUrl: 'https://agentrouter.org/v1',
          apiKey: 'test-key-xyz',
          model: 'gpt-6.1-sol',
        );
        final AssistantTurn turn = await client.complete(
          config: config,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hi'},
          ],
        );
        expect(turn.content, 'sol via responses');
        expect(paths, <String>['/v1/chat/completions', '/v1/responses']);

        // Second call goes straight to /responses (per-model cache).
        final AssistantTurn second = await client.complete(
          config: config,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hi'},
          ],
        );
        expect(second.content, 'sol via responses');
        expect(paths, <String>[
          '/v1/chat/completions',
          '/v1/responses',
          '/v1/responses',
        ]);
      },
    );

    test('per-model cache: a Chat Completions model never inherits the '
        'Responses protocol of another model', () async {
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          final Map<String, dynamic> body = jsonDecode(
            (request as http.Request).body,
          ) as Map<String, dynamic>;
          if (request.url.path.endsWith('/responses')) {
            return _sseResponse(_responsesSse('via responses'));
          }
          if (body['model'] == 'gpt-6.1-sol') {
            return _jsonResponse(_responsesHintBody, status: 400);
          }
          return _sseResponse(
            'data: {"choices":[{"delta":{"content":"astra via cc"}}]}\n\n'
            'data: [DONE]\n\n',
          );
        }),
      );
      const LlmConfig sol = LlmConfig(
        baseUrl: 'https://agentrouter.org/v1',
        apiKey: 'test-key-xyz',
        model: 'gpt-6.1-sol',
      );
      const LlmConfig astra = LlmConfig(
        baseUrl: 'https://agentrouter.org/v1',
        apiKey: 'test-key-xyz',
        model: 'gpt-6-astra',
      );

      expect(
        (await client.complete(
          config: sol,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hi'},
          ],
        )).content,
        'via responses',
      );
      expect(
        (await client.complete(
          config: astra,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hi'},
          ],
        )).content,
        'astra via cc',
      );
      expect(
        (await client.complete(
          config: astra,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hi'},
          ],
        )).content,
        'astra via cc',
      );
    });

    test('pinned anthropic: never falls back, 404 is a hard error', () async {
      final List<String> paths = <String>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          paths.add(request.url.path);
          return _jsonResponse('not found', status: 404);
        }),
      );
      await expectLater(
        client.complete(
          config: const LlmConfig(
            baseUrl: 'https://agentrouter.org/v1',
            apiKey: 'test-key-xyz',
            model: 'gpt-6.1-sol',
            engine: LlmEngine.anthropic,
          ),
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hi'},
          ],
        ),
        throwsA(
          isA<LlmException>()
              .having((LlmException e) => e.statusCode, 'statusCode', 404)
              .having(
                (LlmException e) => e.message,
                'message',
                contains('/messages unavailable'),
              ),
        ),
      );
      expect(paths, <String>['/v1/messages']);
    });

    test(
      'pinned openai: responses-hint 400 fails with the engine hint',
      () async {
        final List<String> paths = <String>[];
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            paths.add(request.url.path);
            return _jsonResponse(_responsesHintBody, status: 400);
          }),
        );
        await expectLater(
          client.complete(
            config: const LlmConfig(
              baseUrl: 'https://agentrouter.org/v1',
              apiKey: 'test-key-xyz',
              model: 'gpt-6.1-sol',
              engine: LlmEngine.openai,
            ),
            messages: const <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'Hi'},
            ],
          ),
          throwsA(
            isA<LlmException>()
                .having((LlmException e) => e.statusCode, 'statusCode', 400)
                .having(
                  (LlmException e) => e.message,
                  'message',
                  allOf(
                    contains('/v1/responses'),
                    contains("Engine to 'OpenAI Responses'"),
                  ),
                ),
          ),
        );
        expect(paths, <String>['/v1/chat/completions']);
      },
    );

    test(
      'pinned openaiResponses: straight to /responses with dual auth',
      () async {
        final List<http.BaseRequest> requests = <http.BaseRequest>[];
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            requests.add(request);
            return _sseResponse(_responsesSse('pinned turn'));
          }),
        );
        final AssistantTurn turn = await client.complete(
          config: const LlmConfig(
            baseUrl: 'https://agentrouter.org/v1',
            apiKey: 'test-key-xyz',
            model: 'gpt-6.1-sol',
            engine: LlmEngine.openaiResponses,
          ),
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hi'},
          ],
        );
        expect(turn.content, 'pinned turn');
        expect(requests, hasLength(1));
        expect(
          requests.single.url.toString(),
          'https://agentrouter.org/v1/responses',
        );
        final Map<String, String> headers = _lower(requests.single.headers);
        expect(headers['x-api-key'], 'test-key-xyz');
        expect(headers['authorization'], 'Bearer test-key-xyz');
        expect(headers['user-agent'], 'claude-cli/1.0.60 (external, cli)');
        final Map<String, dynamic> body = jsonDecode(
          (requests.single as http.Request).body,
        ) as Map<String, dynamic>;
        expect(body['model'], 'gpt-6.1-sol');
        expect(body['store'], isFalse);
        expect(body['stream'], isTrue);
      },
    );

    test('responses hint survives the Anthropic fallback chain', () async {
      // claude-family model routed to /messages first; the gateway 404s,
      // the OpenAI retry answers with the responses hint, and the chain
      // lands on /responses (bounded: responses never falls back again).
      final List<String> paths = <String>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/messages')) {
            return _jsonResponse('not found', status: 404);
          }
          if (request.url.path.endsWith('/chat/completions')) {
            return _jsonResponse(_responsesHintBody, status: 400);
          }
          return _sseResponse(_responsesSse('chain complete'));
        }),
      );
      final AssistantTurn turn = await client.complete(
        config: const LlmConfig(
          baseUrl: 'https://agentrouter.org/v1',
          apiKey: 'test-key-xyz',
          model: 'claude-test-model',
        ),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'Hi'},
        ],
      );
      expect(turn.content, 'chain complete');
      expect(paths, <String>[
        '/v1/messages',
        '/v1/chat/completions',
        '/v1/responses',
      ]);
    });
  });

  group('engine settings serialization', () {
    test('ProviderPreset engine round-trips through JSON', () {
      for (final LlmEngine engine in LlmEngine.values) {
        final Map<String, dynamic> json = ProviderPreset(
          id: 'p1',
          name: 'P',
          engine: engine,
        ).toJson();
        expect(ProviderPreset.fromJson(json).engine, engine);
      }
    });

    test('legacy/unknown engine names degrade to auto', () {
      expect(
        ProviderPreset.fromJson(const <String, dynamic>{}).engine,
        LlmEngine.auto,
      );
      expect(
        ProviderPreset.fromJson(const <String, dynamic>{
          'engine': 'chat-completions',
        }).engine,
        LlmEngine.auto,
      );
      expect(llmEngineFromName(null), LlmEngine.auto);
      expect(llmEngineFromName('openaiResponses'), LlmEngine.openaiResponses);
    });

    test('AppSettings engine persists and survives the preset migration', () {
      final AppSettings settings = AppSettings().copyWith(
        engine: LlmEngine.anthropic,
      );
      final AppSettings restored = AppSettings.fromJson(settings.toJson());
      expect(restored.engine, LlmEngine.anthropic);
      // Preset migration reconstruction must not reset the field.
      final AppSettings remigrated = restored._remigratedForTest();
      expect(remigrated.engine, LlmEngine.anthropic);
    });
  });
}

extension on AppSettings {
  /// Runs the private preset-migration reconstruction through a fresh
  /// fromJson round-trip (the reconstruction itself is private; fromJson
  /// invokes it, so a second round-trip exercises the same path).
  AppSettings _remigratedForTest() => AppSettings.fromJson(toJson());
}
