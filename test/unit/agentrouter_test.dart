import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agentrouter_client.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/model_catalog.dart';

const LlmConfig _agentConfig = LlmConfig(
  baseUrl: 'https://agentrouter.org/v1',
  apiKey: 'test-key-xyz',
  // Claude-family model: keeps the Anthropic-path tests on their natural
  // first-choice protocol (room-browser per-model routing, v1.49.3).
  model: 'claude-test-model',
);

const LlmConfig _gptConfig = LlmConfig(
  baseUrl: 'https://agentrouter.org/v1',
  apiKey: 'test-key-xyz',
  // Non-Claude family: the OpenAI-compatible path is the natural first
  // choice (room-browser per-model routing, v1.49.3).
  model: 'gpt-6-astra',
);

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

void main() {
  setUp(AgentRouterLlmClient.clearProtocolCache);

  group('hostname validation', () {
    test('accepts the exact domain, subdomains and case noise', () {
      expect(isAgentRouterHost('agentrouter.org'), isTrue);
      expect(isAgentRouterHost('api.agentrouter.org'), isTrue);
      expect(isAgentRouterHost('a.b.agentrouter.org'), isTrue);
      expect(isAgentRouterHost('AgentRouter.ORG'), isTrue);
      expect(isAgentRouterHost('  agentrouter.org  '), isTrue);
    });

    test('rejects typosquats, IPs, underscores, empties and trailing dots', () {
      expect(isAgentRouterHost('evil-agentrouter.org'), isFalse);
      expect(isAgentRouterHost('agentrouter.org.evil.com'), isFalse);
      expect(isAgentRouterHost('agentrouter.community'), isFalse);
      expect(isAgentRouterHost('agentrouter.orgx'), isFalse);
      expect(isAgentRouterHost(''), isFalse);
      expect(isAgentRouterHost('1.2.3.4'), isFalse);
      expect(isAgentRouterHost('agent_router.org'), isFalse);
      expect(isAgentRouterHost('agentrouter.org.'), isFalse);
      expect(isAgentRouterHost('.agentrouter.org'), isFalse);
    });

    test('hostOf extracts the host, null for unusable base URLs', () {
      expect(hostOf('https://agentrouter.org/v1'), 'agentrouter.org');
      expect(hostOf('https://api.agentrouter.org/v1/'), 'api.agentrouter.org');
      expect(
        hostOf('https://agentrouter.org.evil.com/v1'),
        'agentrouter.org.evil.com',
      );
      expect(hostOf(''), isNull);
      expect(hostOf('   '), isNull);
      expect(hostOf('https://'), isNull);
      expect(hostOf('not a url'), isNull);
    });
  });

  group('preset', () {
    test('AgentRouter preset: apex base URL + working default model', () {
      expect(providerPresets['AgentRouter'], 'https://agentrouter.org/v1');
      expect(providerDefaultModels['AgentRouter'], 'gpt-6-astra');
    });

    test('suggestions carry no hardcoded agentrouter model ids', () {
      expect(
        suggestedModels.where(
          (String id) => id.toLowerCase().startsWith('agentrouter'),
        ),
        isEmpty,
      );
    });
  });

  group('Anthropic transport', () {
    test('sends the full AgentRouter header set on /messages', () async {
      final List<http.BaseRequest> requests = <http.BaseRequest>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          requests.add(request);
          return _jsonResponse(
            jsonEncode(<String, dynamic>{
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': 'ok'},
              ],
              'usage': <String, dynamic>{'input_tokens': 3, 'output_tokens': 2},
            }),
          );
        }),
      );

      final AssistantTurn turn = await client.complete(
        config: _agentConfig,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );

      expect(requests, hasLength(1));
      expect(
        requests.single.url.toString(),
        'https://agentrouter.org/v1/messages',
      );
      final Map<String, String> headers = _lower(requests.single.headers);
      expect(headers['x-api-key'], 'test-key-xyz');
      expect(headers['authorization'], 'Bearer test-key-xyz');
      expect(headers['anthropic-version'], '2023-06-01');
      expect(headers['user-agent'], 'claude-cli/1.0.60 (external, cli)');
      expect(headers['content-type'], 'application/json');
      expect(turn.content, 'ok');
      expect(turn.usage!.promptTokens, 3);
      expect(turn.usage!.completionTokens, 2);
    });

    test('auth errors pass through unchanged, no OpenAI fallback', () async {
      final List<String> paths = <String>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          paths.add(request.url.path);
          return _jsonResponse(
            jsonEncode(<String, dynamic>{
              'type': 'error',
              'error': <String, dynamic>{
                'type': 'authentication_error',
                'message': 'invalid x-api-key',
              },
            }),
            status: 401,
          );
        }),
      );

      await expectLater(
        client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(
          isA<LlmException>()
              .having((LlmException e) => e.statusCode, 'statusCode', 401)
              .having(
                (LlmException e) => e.message,
                'message',
                contains('invalid x-api-key'),
              ),
        ),
      );
      // Exactly one request: 401 never triggers the /chat/completions probe.
      expect(paths, <String>['/v1/messages']);
    });

    test('transient HTTP errors (429) never fall back either', () async {
      final List<String> paths = <String>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          paths.add(request.url.path);
          return _jsonResponse('rate limited', status: 429);
        }),
      );

      await expectLater(
        client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(
          isA<LlmException>().having(
            (LlmException e) => e.statusCode,
            'statusCode',
            429,
          ),
        ),
      );
      expect(paths, hasLength(1));
    });

    test(
      '404 on /messages probes then falls back; cache skips re-probe',
      () async {
        final List<String> paths = <String>[];
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/messages')) {
              return _jsonResponse('not found', status: 404);
            }
            return _sseResponse(
              'data: {"choices":[{"delta":{"content":"OpenAI turn"}}]}\n\n'
              'data: [DONE]\n\n',
            );
          }),
        );

        final AssistantTurn turn = await client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );
        expect(turn.content, 'OpenAI turn');
        expect(paths, <String>['/v1/messages', '/v1/chat/completions']);

        // Second call: straight to OpenAI, no repeated probe.
        await client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );
        expect(paths, <String>[
          '/v1/messages',
          '/v1/chat/completions',
          '/v1/chat/completions',
        ]);
      },
    );

    test('405 on /messages falls back the same way', () async {
      AgentRouterLlmClient? client;
      client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          if (request.url.path.endsWith('/messages')) {
            return _jsonResponse('method not allowed', status: 405);
          }
          return _sseResponse(
            'data: {"choices":[{"delta":{"content":"via 405"}}]}\n\n'
            'data: [DONE]\n\n',
          );
        }),
      );

      final AssistantTurn turn = await client.complete(
        config: _agentConfig,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );
      expect(turn.content, 'via 405');
    });

    test(
      'OpenAI-shaped 200 on /messages is consumed without re-sending',
      () async {
        final List<String> paths = <String>[];
        Map<String, dynamic> openAiBody(String content) => <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': content,
              },
            },
          ],
        };
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/messages')) {
              return _jsonResponse(jsonEncode(openAiBody('Hi there')));
            }
            return _jsonResponse(jsonEncode(openAiBody('Second')));
          }),
        );

        final AssistantTurn turn = await client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );
        expect(turn.content, 'Hi there'); // parsed from THAT response only
        expect(paths, hasLength(1)); // no duplicate output, no re-send

        final AssistantTurn second = await client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );
        expect(second.content, 'Second');
        expect(paths, <String>['/v1/messages', '/v1/chat/completions']);
      },
    );

    test('SSE error event surfaces the provider message', () async {
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          return _sseResponse(
            'data: {"type":"error","error":{"type":"overloaded_error",'
            '"message":"Overloaded"}}\n\n',
          );
        }),
      );

      await expectLater(
        client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(
          isA<LlmException>().having(
            (LlmException e) => e.message,
            'message',
            contains('Overloaded'),
          ),
        ),
      );
    });

    test('Anthropic SSE stream: deltas, tool_use accumulation, usage', () async {
      final String sse = <String>[
        'event: message_start',
        'data: {"type":"message_start","message":{"usage":{"input_tokens":42,'
            '"output_tokens":1}}}',
        '',
        'data: {"type":"content_block_start","index":0,'
            '"content_block":{"type":"text","text":""}}',
        '',
        'data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"Hello"}}',
        '',
        'data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":" world"}}',
        '',
        'data: {"type":"content_block_start","index":1,'
            '"content_block":{"type":"tool_use","id":"toolu_1",'
            '"name":"browser_navigate"}}',
        '',
        'data: {"type":"content_block_delta","index":1,'
            '"delta":{"type":"input_json_delta","partial_json":"{\\"url\\":"}}',
        '',
        'data: {"type":"content_block_delta","index":1,'
            '"delta":{"type":"input_json_delta",'
            '"partial_json":"\\"https://example.com\\"}"}}',
        '',
        'data: {"type":"content_block_stop","index":1}',
        '',
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use",'
            '"stop_sequence":null},"usage":{"output_tokens":17}}',
        '',
        'data: not even json',
        '',
        'data: {"type":"message_stop"}',
        '',
      ].join('\r\n');

      final List<http.BaseRequest> requests = <http.BaseRequest>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          requests.add(request);
          return _sseResponse(sse);
        }),
      );

      final List<String> deltas = <String>[];
      final AssistantTurn turn = await client.complete(
        config: _agentConfig,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
        onDelta: deltas.add,
      );

      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/v1/messages');
      final Map<String, dynamic> body = jsonDecode(
        (requests.single as http.Request).body,
      ) as Map<String, dynamic>;
      expect(body['stream'], true);
      expect(body['max_tokens'], kAgentRouterMaxTokens);
      expect(body['model'], 'claude-test-model');

      expect(turn.content, 'Hello world');
      expect(deltas, <String>['Hello', ' world']);
      expect(turn.toolCalls, hasLength(1));
      expect(turn.toolCalls.first.id, 'toolu_1');
      expect(turn.toolCalls.first.name, 'browser_navigate');
      expect(turn.toolCalls.first.args['url'], 'https://example.com');
      expect(turn.usage!.promptTokens, 42);
      expect(turn.usage!.completionTokens, 17);
    });

    test('shouldAbort true from the start aborts before any request', () async {
      var calls = 0;
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          calls++;
          return _jsonResponse('{}');
        }),
      );

      await expectLater(
        client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
          shouldAbort: () => true,
        ),
        throwsA(isA<LlmAbortedException>()),
      );
      expect(calls, 0);
    });
  });

  group('non-agentrouter hosts', () {
    test(
      'straight OpenAI request, no probing, no User-Agent override',
      () async {
        final List<http.BaseRequest> requests = <http.BaseRequest>[];
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            requests.add(request);
            return _sseResponse(
              'data: {"choices":[{"delta":{"content":"Hey"}}]}\n\n'
              'data: [DONE]\n\n',
            );
          }),
        );
        const LlmConfig config = LlmConfig(
          baseUrl: 'https://provider.test/v1',
          apiKey: 'test-key-xyz',
          model: 'm',
        );

        final AssistantTurn turn = await client.complete(
          config: config,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );

        expect(requests, hasLength(1)); // no probe request
        expect(
          requests.single.url.toString(),
          'https://provider.test/v1/chat/completions',
        );
        final Map<String, String> headers = _lower(requests.single.headers);
        expect(headers['authorization'], 'Bearer test-key-xyz');
        expect(headers.containsKey('user-agent'), isFalse);
        expect(turn.content, 'Hey');
      },
    );
  });

  group('request translation', () {
    test('system join, tool_use, tool_result and tools schema', () {
      const LlmConfig config = LlmConfig(
        baseUrl: 'https://agentrouter.org/v1',
        apiKey: 'k',
        model: 'model-x',
      );
      final Map<String, dynamic> body = buildAnthropicRequestBody(
        config: config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': 'You are helpful.'},
          <String, dynamic>{'role': 'system', 'content': 'Be brief.'},
          <String, dynamic>{'role': 'user', 'content': 'Navigate please'},
          <String, dynamic>{
            'role': 'assistant',
            'content': '',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'browser_navigate',
                  'arguments': '{"url":"https://example.com"}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': 'page loaded',
          },
        ],
        tools: const <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': 'browser_navigate',
              'description': 'Open a URL',
              'parameters': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'url': <String, dynamic>{'type': 'string'},
                },
              },
            },
          },
        ],
      );

      expect(body['model'], 'model-x');
      expect(body['max_tokens'], kAgentRouterMaxTokens); // 8192 default
      expect(body['stream'], true);
      expect(body['system'], 'You are helpful.\n\nBe brief.');

      final List<Map<String, dynamic>> messages =
          (body['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(messages, hasLength(3)); // user, assistant(tool_use), tool_result

      expect(messages[0]['role'], 'user');
      final List<Map<String, dynamic>> userBlocks =
          (messages[0]['content'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      expect(userBlocks.single['type'], 'text');
      expect(userBlocks.single['text'], 'Navigate please');

      final List<Map<String, dynamic>> assistantBlocks =
          (messages[1]['content'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      expect(messages[1]['role'], 'assistant');
      final Map<String, dynamic> toolUse = assistantBlocks.single;
      expect(toolUse['type'], 'tool_use');
      expect(toolUse['id'], 'call_1');
      expect(toolUse['name'], 'browser_navigate');
      expect(toolUse['input'], <String, dynamic>{'url': 'https://example.com'});

      expect(messages[2]['role'], 'user'); // tool result rides a user message
      final List<Map<String, dynamic>> resultBlocks =
          (messages[2]['content'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      final Map<String, dynamic> toolResult = resultBlocks.single;
      expect(toolResult['type'], 'tool_result');
      expect(toolResult['tool_use_id'], 'call_1');
      expect(toolResult['content'], 'page loaded');

      final List<Map<String, dynamic>> tools = (body['tools'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(tools, hasLength(1));
      expect(tools.single['name'], 'browser_navigate');
      expect(tools.single['description'], 'Open a URL');
      final Map<String, dynamic> schema =
          tools.single['input_schema'] as Map<String, dynamic>;
      expect(schema['type'], 'object');
      expect(schema['properties'], isA<Map<String, dynamic>>());
    });

    test('max_tokens uses the LlmConfig override when set', () {
      const LlmConfig config = LlmConfig(
        baseUrl: 'https://agentrouter.org/v1',
        apiKey: 'k',
        model: 'm',
        maxTokens: 1234,
      );
      final Map<String, dynamic> body = buildAnthropicRequestBody(
        config: config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );
      expect(body['max_tokens'], 1234);
    });

    test('image_url data URIs become base64 source blocks', () {
      const LlmConfig config = LlmConfig(
        baseUrl: 'https://agentrouter.org/v1',
        apiKey: 'k',
        model: 'm',
      );
      final Map<String, dynamic> body = buildAnthropicRequestBody(
        config: config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'look'},
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{
                  'url': 'data:image/png;base64,QUJDREU=',
                },
              },
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{
                  'url': 'https://example.com/cat.png',
                },
              },
            ],
          },
        ],
      );

      final List<Map<String, dynamic>> blocks =
          ((body['messages'] as List<dynamic>).single
                  as Map<String, dynamic>)['content']
              as List<Map<String, dynamic>>;
      expect(blocks, hasLength(3));
      expect(blocks[0]['type'], 'text');
      expect(blocks[1]['type'], 'image');
      expect(blocks[1]['source'], <String, dynamic>{
        'type': 'base64',
        'media_type': 'image/png',
        'data': 'QUJDREU=',
      });
      // Remote URLs degrade to a text placeholder — never a crash.
      expect(blocks[2]['type'], 'text');
      expect(blocks[2]['text'], 'https://example.com/cat.png');
    });

    test('LlmConfig.maxTokens defaults to null', () {
      const LlmConfig config = LlmConfig(
        baseUrl: 'https://x.test/v1',
        apiKey: 'k',
        model: 'm',
      );
      expect(config.maxTokens, isNull);
    });
  });

  group('model discovery', () {
    test('agentrouter host: dual auth + Anthropic-shaped catalog', () async {
      final List<http.BaseRequest> requests = <http.BaseRequest>[];
      final ModelCatalogClient client = ModelCatalogClient(
        client: MockClient.streaming((request, bodyStream) async {
          requests.add(request);
          return _jsonResponse(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'model',
                  'id': 'claude-sonnet-4',
                  'display_name': 'Claude Sonnet 4',
                },
                <String, dynamic>{
                  'type': 'model',
                  'display_name': 'Display Only',
                },
              ],
            }),
          );
        }),
      );

      final List<RemoteModel> models = await client.fetchModels(
        baseUrl: 'https://agentrouter.org/v1',
        apiKey: 'test-key-xyz',
      );

      expect(models.map((RemoteModel m) => m.id), <String>[
        'claude-sonnet-4',
        'Display Only',
      ]);
      final Map<String, String> headers = _lower(requests.single.headers);
      expect(headers['authorization'], 'Bearer test-key-xyz');
      expect(headers['x-api-key'], 'test-key-xyz');
      expect(headers['anthropic-version'], '2023-06-01');
      expect(headers['user-agent'], 'claude-cli/1.0.60 (external, cli)');
    });

    test(
      'other providers keep the bearer-only behavior byte-for-byte',
      () async {
        final List<http.BaseRequest> requests = <http.BaseRequest>[];
        final ModelCatalogClient client = ModelCatalogClient(
          client: MockClient.streaming((request, bodyStream) async {
            requests.add(request);
            return _jsonResponse(
              jsonEncode(<String, dynamic>{
                'data': <Map<String, dynamic>>[
                  <String, dynamic>{'id': 'zai/glm-5.3'},
                ],
              }),
            );
          }),
        );

        final List<RemoteModel> models = await client.fetchModels(
          baseUrl: 'https://api.inferhub.dev/v1',
          apiKey: 'test-key-xyz',
        );

        expect(models.single.id, 'zai/glm-5.3');
        final Map<String, String> headers = _lower(requests.single.headers);
        expect(headers['authorization'], 'Bearer test-key-xyz');
        expect(headers.containsKey('x-api-key'), isFalse);
        expect(headers.containsKey('anthropic-version'), isFalse);
        expect(headers.containsKey('user-agent'), isFalse);
      },
    );

    test(
      'display_name fallback is strictly opt-in via the Anthropic parser',
      () {
        final ModelCatalogClient client = ModelCatalogClient();
        // OpenAI parsing (default): display_name-only entries are skipped.
        expect(client.parseCatalog('{"data":[{"display_name":"X"}]}'), isEmpty);
        // Anthropic parsing: display_name becomes the id.
        expect(
          ModelCatalogClient.parseAgentRouterCatalog(
            '{"data":[{"display_name":"X"}]}',
          ).single.id,
          'X',
        );
      },
    );
  });

  group('room-browser recipe (v1.49.3)', () {
    test('prefersAnthropic: claude family vs everything else', () {
      expect(prefersAnthropic('claude-sonnet-4'), isTrue);
      expect(prefersAnthropic('  Claude-3-Haiku '), isTrue);
      expect(prefersAnthropic('gpt-6-astra'), isFalse);
      expect(prefersAnthropic('glm-4.6'), isFalse);
      expect(prefersAnthropic(''), isFalse);
    });

    test('normalizeAgentRouterBase appends /v1 only when missing', () {
      expect(
        normalizeAgentRouterBase('https://agentrouter.org'),
        'https://agentrouter.org/v1',
      );
      expect(
        normalizeAgentRouterBase('https://agentrouter.org/'),
        'https://agentrouter.org/v1',
      );
      expect(
        normalizeAgentRouterBase('https://agentrouter.org/v1'),
        'https://agentrouter.org/v1',
      );
      expect(
        normalizeAgentRouterBase('https://agentrouter.org/v1/'),
        'https://agentrouter.org/v1',
      );
      expect(
        normalizeAgentRouterBase('https://api.agentrouter.org/v2'),
        'https://api.agentrouter.org/v2',
      );
    });

    test('gpt models take the OpenAI-compatible path first', () async {
      final List<http.BaseRequest> requests = <http.BaseRequest>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          requests.add(request);
          return _sseResponse(
            'data: {"choices":[{"delta":{"content":"gpt via openai"}}]}\n\n'
            'data: [DONE]\n\n',
          );
        }),
      );

      final AssistantTurn turn = await client.complete(
        config: _gptConfig,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );

      expect(turn.content, 'gpt via openai');
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/v1/chat/completions');
      final Map<String, String> headers = _lower(requests.single.headers);
      // The gateway REQUIRES the claude-cli identity on every wire —
      // OpenAI-compatible path included.
      expect(headers['user-agent'], 'claude-cli/1.0.60 (external, cli)');
      expect(headers['authorization'], 'Bearer test-key-xyz');
    });

    test('gpt 404 on chat/completions falls back once to /messages', () async {
      final List<String> paths = <String>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/chat/completions')) {
            return _jsonResponse('not found', status: 404);
          }
          return _jsonResponse(
            jsonEncode(<String, dynamic>{
              'content': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'text',
                  'text': 'anthropic path saved the turn',
                },
              ],
            }),
          );
        }),
      );

      final AssistantTurn turn = await client.complete(
        config: _gptConfig,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );

      expect(turn.content, 'anthropic path saved the turn');
      expect(paths, <String>['/v1/chat/completions', '/v1/messages']);
    });

    test(
      'anti-loop: both protocols 404 → error after exactly 2 requests',
      () async {
        final List<String> paths = <String>[];
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            paths.add(request.url.path);
            return _jsonResponse('not found', status: 404);
          }),
        );

        await expectLater(
          client.complete(
            config: _gptConfig,
            messages: const <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'hi'},
            ],
          ),
          throwsA(isA<LlmException>()),
        );
        // chat/completions then messages — never flip back a third time.
        expect(paths, hasLength(2));
      },
    );

    test('confirmed protocol cache: later gpt calls skip the guess', () async {
      final List<String> paths = <String>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          paths.add(request.url.path);
          return _sseResponse(
            'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
            'data: [DONE]\n\n',
          );
        }),
      );

      for (var i = 0; i < 2; i++) {
        await client.complete(
          config: _gptConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        );
      }
      expect(paths, <String>['/v1/chat/completions', '/v1/chat/completions']);
    });

    test('WAF challenge page (200 HTML) becomes an actionable error', () async {
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                '<!DOCTYPE html><html><head>'
                '<script>var acw_sc__v2="challenge";</script></head>'
                '<body>Aliyun anti-bot slider</body></html>',
              ),
            ),
            200,
            headers: <String, String>{'content-type': 'text/html'},
          );
        }),
      );

      await expectLater(
        client.complete(
          config: _gptConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(
          isA<LlmException>().having(
            (LlmException e) => e.message,
            'message',
            contains('mobile data'),
          ),
        ),
      );
    });

    test('WAF 403 on the Anthropic path keeps the status code', () async {
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                '<html><body>Aliyun WAF captcha verify</body></html>',
              ),
            ),
            403,
            headers: <String, String>{'content-type': 'text/html'},
          );
        }),
      );

      await expectLater(
        client.complete(
          config: _agentConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(
          isA<LlmException>()
              .having((LlmException e) => e.statusCode, 'statusCode', 403)
              .having(
                (LlmException e) => e.message,
                'message',
                contains('mobile data'),
              ),
        ),
      );
    });

    test('Invalid API Key explains the deployment mismatch', () async {
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          return _jsonResponse('Invalid API Key!', status: 401);
        }),
      );

      await expectLater(
        client.complete(
          config: _gptConfig,
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(
          isA<LlmException>()
              .having((LlmException e) => e.statusCode, 'statusCode', 401)
              .having(
                (LlmException e) => e.message,
                'message',
                contains('separate deployments'),
              ),
        ),
      );
    });

    test('WAF / invalid-key detectors: hits and misses', () {
      expect(looksLikeWafChallenge('<html>acw_tc=1</html>'), isTrue);
      expect(looksLikeWafChallenge('Aliyun WAF challenge'), isTrue);
      expect(looksLikeWafChallenge('please slide the captcha'), isTrue);
      expect(looksLikeWafChallenge('{"error":"overloaded"}'), isFalse);
      expect(looksLikeWafChallenge('rate limited'), isFalse);
      expect(looksLikeInvalidApiKey('Invalid API Key!'), isTrue);
      expect(looksLikeInvalidApiKey('invalid api key'), isTrue);
      expect(looksLikeInvalidApiKey('invalid x-api-key'), isFalse);
      expect(looksLikeInvalidApiKey('{"error":"quota"}'), isFalse);
    });

    test('base URL without /v1 lands on the versioned paths', () async {
      final List<http.BaseRequest> requests = <http.BaseRequest>[];
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          requests.add(request);
          return _sseResponse(
            'data: {"choices":[{"delta":{"content":"v1 normalized"}}]}\n\n'
            'data: [DONE]\n\n',
          );
        }),
      );
      const LlmConfig bare = LlmConfig(
        baseUrl: 'https://agentrouter.org',
        apiKey: 'test-key-xyz',
        model: 'gpt-6-astra',
      );

      final AssistantTurn turn = await client.complete(
        config: bare,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
      );

      expect(turn.content, 'v1 normalized');
      expect(requests.single.url.path, '/v1/chat/completions');
    });
  });

  group('waf cookie jar + anti-block retry (v1.49.6)', () {
    setUp(() {
      AgentRouterLlmClient.clearProtocolCache();
      AgentRouterLlmClient.clearWafCookies();
      AgentRouterLlmClient.wafRetryDelay = Duration.zero;
    });

    const List<Map<String, dynamic>> hi = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': 'hi'},
    ];

    http.StreamedResponse blockedPage({
      required int status,
      String? setCookie,
    }) => http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          '<html><body>Your request has been blocked by '
          'Aliyun WAF</body></html>',
        ),
      ),
      status,
      headers: <String, String>{
        'content-type': 'text/html',
        'set-cookie': ?setCookie,
      },
    );

    test('deny pages ("blocked") are WAF failures; content noise is not', () {
      expect(
        looksLikeWafChallenge(
          '<html><body>Your request has been blocked</body></html>',
        ),
        isTrue,
      );
      expect(looksLikeWafChallenge('request blocked by firewall'), isTrue);
      // "blocked" without page/firewall context stays a pass-through (it
      // would otherwise swallow content-policy messages).
      expect(looksLikeWafChallenge('we blocked your request'), isFalse);
      expect(looksLikeWafChallenge('content policy violation'), isFalse);
    });

    test(
      'challenge responses plant cookies; later requests replay them',
      () async {
        final List<http.BaseRequest> requests = <http.BaseRequest>[];
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            requests.add(request);
            return _sseResponse(
              'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
              'data: [DONE]\n\n',
            );
          }),
        );
        AgentRouterLlmClient.wafCookiesForTesting['agentrouter.org'] =
            <String, String>{'acw_tc': 'seeded-123'};

        final AssistantTurn turn = await client.complete(
          config: _gptConfig,
          messages: hi,
        );

        expect(turn.content, 'ok');
        final Map<String, String> headers = _lower(requests.single.headers);
        expect(headers['cookie'], 'acw_tc=seeded-123');
      },
    );

    test(
      'harvests set-cookie from responses (base-transport observer)',
      () async {
        final AgentRouterLlmClient client = AgentRouterLlmClient(
          client: MockClient.streaming((request, bodyStream) async {
            return http.StreamedResponse(
              Stream<List<int>>.value(
                utf8.encode(
                  'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
                  'data: [DONE]\n\n',
                ),
              ),
              200,
              headers: <String, String>{
                'content-type': 'text/event-stream',
                'set-cookie': 'acw_tc=abc123; Path=/; HttpOnly',
              },
            );
          }),
        );

        await client.complete(config: _gptConfig, messages: hi);

        expect(
          AgentRouterLlmClient
              .wafCookiesForTesting['agentrouter.org']?['acw_tc'],
          'abc123',
        );
      },
    );

    test('anti-block: a blocked first attempt is retried once, replaying '
        'the harvested cookie', () async {
      final List<String> cookies = <String>[];
      var attempts = 0;
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          attempts++;
          cookies.add(_lower(request.headers)['cookie'] ?? '');
          if (attempts == 1) {
            return blockedPage(status: 403, setCookie: 'acw_tc=retry-token-9');
          }
          return _sseResponse(
            'data: {"choices":[{"delta":{"content":"recovered"}}]}\n\n'
            'data: [DONE]\n\n',
          );
        }),
      );

      final AssistantTurn turn = await client.complete(
        config: _gptConfig,
        messages: hi,
      );

      expect(turn.content, 'recovered');
      expect(attempts, 2);
      // First attempt: jar still empty. Retry: replays the challenge
      // cookie harvested from the blocked response.
      expect(cookies.first, isEmpty);
      expect(cookies.last, 'acw_tc=retry-token-9');
    });

    test('anti-block: a block that persists surfaces the actionable '
        'guidance after exactly one retry', () async {
      var attempts = 0;
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          attempts++;
          return blockedPage(status: 403);
        }),
      );

      await expectLater(
        client.complete(config: _gptConfig, messages: hi),
        throwsA(
          isA<LlmException>()
              .having((LlmException e) => e.statusCode, 'statusCode', 403)
              .having(
                (LlmException e) => e.message,
                'message',
                contains('mobile data'),
              ),
        ),
      );
      expect(attempts, 2);
    });

    test('anti-block: mid-stream failures (deltas already shown) never '
        'retry', () async {
      var attempts = 0;
      final AgentRouterLlmClient client = AgentRouterLlmClient(
        client: MockClient.streaming((request, bodyStream) async {
          attempts++;
          return _sseResponse(
            'data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"partial"}}\n\n'
            'data: {"type":"error","error":{"type":"api_error",'
            '"message":"Aliyun WAF captcha verify"}}\n\n',
          );
        }),
      );

      // The caller subscribes to deltas (the agent loop always does) —
      // the partial text already reached the UI, so a retry could
      // duplicate it and must never happen.
      await expectLater(
        client.complete(
          config: _agentConfig,
          messages: hi,
          onDelta: (String _) {},
        ),
        throwsA(
          isA<LlmException>().having(
            (LlmException e) => e.message,
            'message',
            contains('bot-challenging'),
          ),
        ),
      );
      expect(attempts, 1);
    });
  });
}
