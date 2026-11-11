import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'llm_client.dart';

/// Shared wire-protocol transports used by BOTH the plain [LlmClient]
/// (any provider, per-provider engine setting) and the AgentRouter
/// subclass: the Anthropic Messages protocol and the OpenAI Responses
/// API, as pure top-level functions over `package:http`.
///
/// The per-provider engine option (v1.49.4) needs every engine available
/// for EVERY provider — `anthropic` (POST `{base}/messages`), `openai`
/// (POST `{base}/chat/completions`, the base transport itself) and
/// `openaiResponses` (POST `{base}/responses`) — so the request builders
/// and stream consumers live here instead of inside one client class.
///
/// AgentRouter-specific concerns (claude-cli User-Agent, dual auth, WAF
/// translation, protocol caching) stay in `agentrouter_client.dart`; it
/// imports and re-exports the pieces below.

/// Anthropic `anthropic-version` header value sent on every
/// Messages-protocol request.
const String kAnthropicVersion = '2023-06-01';

/// `max_tokens` is REQUIRED by the Anthropic Messages protocol; used when
/// [LlmConfig.maxTokens] is not set.
const int kAgentRouterMaxTokens = 8192;

/// Header set for an Anthropic Messages request: the protocol version,
/// dual auth (x-api-key + Bearer — gateways pick either) and SSE accept.
Map<String, String> anthropicHeaders(String apiKey) => <String, String>{
  'x-api-key': apiKey,
  'Authorization': 'Bearer $apiKey',
  'anthropic-version': kAnthropicVersion,
  'Content-Type': 'application/json',
  'Accept': 'text/event-stream',
};

/// Header set for an OpenAI Responses request (Bearer auth + SSE accept).
Map<String, String> responsesHeaders(String apiKey) => <String, String>{
  'Authorization': 'Bearer $apiKey',
  'Content-Type': 'application/json',
  'Accept': 'text/event-stream',
};

Object? tryDecodeJson(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? asJsonMap(Object? raw) =>
    raw is Map<String, dynamic> ? raw : null;

int? asJsonInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

String truncateForError(String text, [int max = 300]) =>
    text.length <= max ? text : '${text.substring(0, max)}...';

/// Extracts the provider's own error message from an Anthropic-shaped
/// error payload (`{"type":"error","error":{"type":...,"message":...}}`);
/// falls back to the truncated raw body.
String anthropicErrorMessage(String raw) {
  final Object? decoded = tryDecodeJson(raw);
  if (decoded is Map<String, dynamic>) {
    final Object? error = decoded['error'];
    if (error is Map<String, dynamic>) {
      final String message = error['message']?.toString() ?? '';
      if (message.isNotEmpty) return message;
    }
  }
  return truncateForError(raw);
}

/// Extracts the provider's own error message from an OpenAI-shaped error
/// payload (`{"error":{"message":...}}`); falls back to the raw body.
String openAiErrorMessage(String raw) {
  final Object? decoded = tryDecodeJson(raw);
  if (decoded is Map<String, dynamic>) {
    final Object? error = decoded['error'];
    if (error is Map<String, dynamic>) {
      final String message = error['message']?.toString() ?? '';
      if (message.isNotEmpty) return message;
    }
    // Responses-style failure events carry the message at the top level.
    final String top = decoded['message']?.toString() ?? '';
    if (top.isNotEmpty) return top;
  }
  return truncateForError(raw);
}

/// The gateway's "this model speaks the Responses API" rejection
/// (HTTP 400, `new_api_error` family): the model does not serve
/// `/chat/completions` and the body explicitly points at `/v1/responses`.
/// Matches BOTH wordings gateways emit (Chinese and English) — both name
/// the two paths in one sentence. Observed in production:
/// "Model gpt-6.1-sol does not support /v1/chat/completions, please use
/// /v1/responses instead." Pure function — unit-tested directly.
bool needsResponsesApi(String body) {
  final String s = body.toLowerCase();
  return s.contains('/v1/responses') && s.contains('chat/completions');
}

/// Guidance appended when the Responses hint arrives but the provider's
/// engine is pinned to Chat Completions (explicit engine = no silent
/// protocol switch): switching the engine — or Auto — resolves it.
String responsesEngineHint() =>
    'This model only serves the OpenAI Responses API (/v1/responses). '
    "Set the provider's Engine to 'OpenAI Responses' (or Auto) in "
    'Settings → Providers.';

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic Messages transport
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the Anthropic Messages request body from the app's OpenAI-style
/// wire messages. Pure function — unit-tested directly.
///
/// Mapping:
/// * all `system` messages join with '\n\n' into the top-level `system`
///   string (omitted when there are none);
/// * `user` string content becomes a single text block; array content maps
///   text parts to text blocks and `image_url` data URIs to base64 image
///   blocks (non-data URLs degrade to a text placeholder — never a crash);
/// * `assistant` text becomes a text block and each `tool_calls` entry a
///   `tool_use` block with `input` = the decoded arguments JSON;
/// * each `tool` message becomes its own `user` message carrying one
///   `tool_result` block.
Map<String, dynamic> buildAnthropicRequestBody({
  required LlmConfig config,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
}) {
  final List<String> systemParts = <String>[];
  final List<Map<String, dynamic>> anthropicMessages = <Map<String, dynamic>>[];

  for (final Map<String, dynamic> message in messages) {
    final String role = message['role']?.toString() ?? '';
    if (role == 'system') {
      systemParts.add(contentToText(message['content']));
    } else if (role == 'tool') {
      anthropicMessages.add(<String, dynamic>{
        'role': 'user',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'tool_result',
            'tool_use_id': message['tool_call_id']?.toString() ?? '',
            'content': contentToText(message['content']),
          },
        ],
      });
    } else if (role == 'assistant') {
      final List<Map<String, dynamic>> blocks = <Map<String, dynamic>>[];
      final String text = contentToText(message['content']);
      if (text.isNotEmpty) {
        blocks.add(<String, dynamic>{'type': 'text', 'text': text});
      }
      final Object? toolCalls = message['tool_calls'];
      if (toolCalls is List) {
        for (final Object? raw in toolCalls) {
          if (raw is! Map<String, dynamic>) continue;
          final Object? function = raw['function'];
          if (function is! Map<String, dynamic>) continue;
          final String name = function['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final String id = raw['id']?.toString() ?? '';
          blocks.add(<String, dynamic>{
            'type': 'tool_use',
            'id': id.isEmpty ? newCallId() : id,
            'name': name,
            'input': decodeArguments(function['arguments']),
          });
        }
      }
      if (blocks.isNotEmpty) {
        anthropicMessages.add(<String, dynamic>{
          'role': 'assistant',
          'content': blocks,
        });
      }
    } else {
      anthropicMessages.add(<String, dynamic>{
        'role': 'user',
        'content': userContentBlocks(message['content']),
      });
    }
  }

  return <String, dynamic>{
    'model': config.model,
    // Anthropic REQUIRES max_tokens — config override or the default cap.
    'max_tokens': config.maxTokens ?? kAgentRouterMaxTokens,
    'stream': true,
    if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
    'messages': anthropicMessages,
    if (tools != null && tools.isNotEmpty)
      'tools': <Map<String, dynamic>>[
        for (final Map<String, dynamic> tool in tools)
          anthropicToolSchema(tool),
      ],
  };
}

/// Encodes the request body off the UI isolate (large conversations can
/// reach multiple MB — same rationale as the base transport).
Future<String> encodeBodyOffIsolate(Map<String, dynamic> body) =>
    Isolate.run(() => jsonEncode(body));

String contentToText(Object? content) {
  if (content is String) return content;
  if (content is List) {
    // Concatenate the text parts of array-shaped content.
    final StringBuffer buffer = StringBuffer();
    for (final Object? part in content) {
      if (part is Map<String, dynamic>) {
        final Object? text = part['text'];
        if (text != null) buffer.write(text.toString());
      } else if (part is String) {
        buffer.write(part);
      }
    }
    return buffer.toString();
  }
  return content?.toString() ?? '';
}

List<Map<String, dynamic>> userContentBlocks(Object? content) {
  if (content is List) {
    final List<Map<String, dynamic>> blocks = <Map<String, dynamic>>[];
    for (final Object? part in content) {
      final Map<String, dynamic>? block = userContentBlock(part);
      if (block != null) blocks.add(block);
    }
    if (blocks.isNotEmpty) return blocks;
  }
  // String (or unusable) content: a single text block.
  return <Map<String, dynamic>>[
    <String, dynamic>{'type': 'text', 'text': contentToText(content)},
  ];
}

Map<String, dynamic>? userContentBlock(Object? part) {
  if (part is String) {
    return <String, dynamic>{'type': 'text', 'text': part};
  }
  if (part is! Map<String, dynamic>) return null;
  final String type = part['type']?.toString() ?? '';
  if (type == 'image_url') {
    final Object? imageUrl = part['image_url'];
    final String? url = imageUrl is Map<String, dynamic>
        ? imageUrl['url']?.toString()
        : (imageUrl is String ? imageUrl : null);
    final RegExpMatch? dataUri = url == null
        ? null
        : dataUriPattern.firstMatch(url);
    if (dataUri != null) {
      return <String, dynamic>{
        'type': 'image',
        'source': <String, dynamic>{
          'type': 'base64',
          'media_type': dataUri.group(1)!,
          'data': dataUri.group(2)!,
        },
      };
    }
    // Anthropic accepts no remote image URL here: keep the URL text as a
    // placeholder instead of crashing.
    return <String, dynamic>{'type': 'text', 'text': url ?? ''};
  }
  final Object? text = part['text'];
  if (text != null) {
    return <String, dynamic>{'type': 'text', 'text': text.toString()};
  }
  return null;
}

final RegExp dataUriPattern = RegExp(
  r'^data:([^;,]+);base64,(.+)$',
  dotAll: true,
);

/// OpenAI tool definition
/// (`{type:'function',function:{name,description,parameters}}`) → Anthropic
/// tool schema (`{name,description,input_schema}`).
Map<String, dynamic> anthropicToolSchema(Map<String, dynamic> tool) {
  final Object? function = tool['function'];
  final Map<String, dynamic> fn = function is Map<String, dynamic>
      ? function
      : <String, dynamic>{};
  final Object? parameters = fn['parameters'];
  return <String, dynamic>{
    'name': fn['name']?.toString() ?? '',
    'description': fn['description']?.toString() ?? '',
    // Anthropic requires a JSON schema; an absent one degrades to the
    // empty object schema instead of breaking the request.
    'input_schema': parameters is Map<String, dynamic>
        ? parameters
        : <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
  };
}

Map<String, dynamic> decodeArguments(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    final Object? decoded = tryDecodeJson(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  }
  // Malformed arguments must not break the whole request.
  return <String, dynamic>{};
}

/// Full (non-SSE) Anthropic message:
/// `{content:[{type:'text'|'tool_use',...}],usage,stop_reason}`.
AssistantTurn parseAnthropicMessage(String raw) {
  final Object? decoded = tryDecodeJson(raw);
  if (decoded is! Map<String, dynamic>) {
    throw LlmException('Unknown response format: ${truncateForError(raw)}');
  }
  final StringBuffer text = StringBuffer();
  final List<ToolCallRequest> toolCalls = <ToolCallRequest>[];
  final Object? content = decoded['content'];
  if (content is List) {
    for (final Object? block in content) {
      if (block is! Map<String, dynamic>) continue;
      final String type = block['type']?.toString() ?? '';
      if (type == 'text') {
        text.write(block['text']?.toString() ?? '');
      } else if (type == 'tool_use') {
        final String name = block['name']?.toString() ?? '';
        // A glitched entry (missing name) must not crash the app.
        if (name.isEmpty) continue;
        final String id = block['id']?.toString() ?? '';
        toolCalls.add(
          ToolCallRequest(
            id: id.isEmpty ? newCallId() : id,
            name: name,
            argumentsJson: jsonEncode(
              asJsonMap(block['input']) ?? <String, dynamic>{},
            ),
          ),
        );
      }
    }
  }
  final Map<String, dynamic>? usage = asJsonMap(decoded['usage']);
  final int? input = asJsonInt(usage?['input_tokens']);
  final int? output = asJsonInt(usage?['output_tokens']);
  return AssistantTurn(
    content: text.toString(),
    toolCalls: toolCalls,
    usage: (input != null || output != null)
        ? TokenUsage(promptTokens: input ?? 0, completionTokens: output ?? 0)
        : null,
  );
}

/// Anthropic SSE consumption: line-buffered, CRLF-tolerant, malformed JSON
/// events are ignored, Stop aborts mid-stream keeping the partial text.
Future<AssistantTurn> consumeAnthropicStream(
  http.ByteStream stream,
  void Function(String delta)? onDelta,
  bool Function()? shouldAbort,
) async {
  final StringBuffer contentBuffer = StringBuffer();
  final Map<int, AnthropicToolBlock> toolBlocks = <int, AnthropicToolBlock>{};
  int? inputTokens;
  int? outputTokens;
  var lineBuffer = '';
  var done = false;
  var aborted = false;

  try {
    await for (final chunk in stream.transform(utf8.decoder)) {
      // Stop must interrupt DURING generation: bail out of the stream at
      // the first chance, cancelling the HTTP subscription with it.
      if (shouldAbort?.call() ?? false) {
        aborted = true;
        break;
      }
      lineBuffer += chunk;
      while (true) {
        final int newlineIndex = lineBuffer.indexOf('\n');
        if (newlineIndex < 0) break;
        // trim() also strips the '\r' of CRLF line endings.
        final String line = lineBuffer.substring(0, newlineIndex).trim();
        lineBuffer = lineBuffer.substring(newlineIndex + 1);

        if (line.isEmpty || line.startsWith(':')) continue;
        // `event:`/`id:` lines carry no payload — the JSON itself has
        // the event `type`.
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') {
          done = true;
          break;
        }

        final Object? decoded = tryDecodeJson(data);
        if (decoded is! Map<String, dynamic>) continue; // malformed JSON
        final String type = decoded['type']?.toString() ?? '';

        if (type == 'error') {
          throw LlmException(anthropicErrorMessage(data));
        }

        if (type == 'message_start') {
          final Map<String, dynamic>? message = asJsonMap(decoded['message']);
          final Map<String, dynamic>? usage = asJsonMap(message?['usage']);
          if (usage != null) {
            inputTokens = asJsonInt(usage['input_tokens']) ?? inputTokens;
            outputTokens = asJsonInt(usage['output_tokens']) ?? outputTokens;
          }
        } else if (type == 'content_block_start') {
          final int index = asJsonInt(decoded['index']) ?? toolBlocks.length;
          final Map<String, dynamic>? block = asJsonMap(
            decoded['content_block'],
          );
          // Tool call id/name arrive ONLY here; arguments come later via
          // input_json_delta accumulation.
          if (block != null && block['type']?.toString() == 'tool_use') {
            toolBlocks[index] = AnthropicToolBlock(
              id: block['id']?.toString(),
              name: block['name']?.toString(),
            );
          }
        } else if (type == 'content_block_delta') {
          final Map<String, dynamic>? delta = asJsonMap(decoded['delta']);
          if (delta == null) continue;
          final String deltaType = delta['type']?.toString() ?? '';
          if (deltaType == 'text_delta') {
            final String text = delta['text']?.toString() ?? '';
            if (text.isNotEmpty) {
              contentBuffer.write(text);
              onDelta?.call(text);
            }
          } else if (deltaType == 'input_json_delta') {
            final int index = asJsonInt(decoded['index']) ?? 0;
            toolBlocks
                .putIfAbsent(index, AnthropicToolBlock.new)
                .arguments
                .write(delta['partial_json']?.toString() ?? '');
          }
        } else if (type == 'message_delta') {
          final Map<String, dynamic>? usage = asJsonMap(decoded['usage']);
          if (usage != null) {
            inputTokens = asJsonInt(usage['input_tokens']) ?? inputTokens;
            outputTokens = asJsonInt(usage['output_tokens']) ?? outputTokens;
          }
          // delta.stop_reason is informational: the turn shape (content
          // + tool calls) already tells the agent loop what happened.
        } else if (type == 'message_stop') {
          done = true;
        }
        // 'content_block_stop' and 'ping' need no handling.
      }
      if (done) break;
    }
  } on LlmException {
    rethrow;
  } catch (e) {
    // A dropped socket mid-stream must not crash the app: keep partial
    // plain-text content, but never return half-received tool calls
    // (their JSON arguments would be truncated and unusable).
    if (toolBlocks.isEmpty && contentBuffer.isNotEmpty) {
      return AssistantTurn(content: contentBuffer.toString());
    }
    throw LlmException('Connection lost while streaming: $e');
  }
  if (aborted) {
    throw LlmAbortedException(contentBuffer.toString());
  }

  final List<int> indexes = toolBlocks.keys.toList()..sort();
  return AssistantTurn(
    content: contentBuffer.toString(),
    usage: (inputTokens != null || outputTokens != null)
        ? TokenUsage(
            promptTokens: inputTokens ?? 0,
            completionTokens: outputTokens ?? 0,
          )
        : null,
    toolCalls: <ToolCallRequest>[
      for (final int index in indexes)
        if (toolBlocks[index]!.hasName) toolBlocks[index]!.toRequest(),
    ],
  );
}

/// Consumes a 200 Anthropic response: SSE stream or full JSON body,
/// decided by the response's content-type exactly like the gateways do.
Future<AssistantTurn> consumeAnthropicResponse(
  http.StreamedResponse response,
  void Function(String delta)? onDelta,
  bool Function()? shouldAbort,
) async {
  final String contentType = (response.headers['content-type'] ?? '')
      .toLowerCase();
  if (contentType.contains('text/event-stream')) {
    try {
      return await consumeAnthropicStream(
        response.stream,
        onDelta,
        shouldAbort,
      );
    } on LlmAbortedException {
      rethrow;
    } on LlmException {
      rethrow;
    } catch (e) {
      throw LlmException('Connection lost while streaming: $e');
    }
  }
  if (shouldAbort?.call() ?? false) {
    throw const LlmAbortedException('');
  }
  final String raw = await response.stream.bytesToString();
  return parseAnthropicMessage(raw);
}

/// Accumulator for one Anthropic `tool_use` content block: id/name arrive
/// in `content_block_start`, the arguments JSON accumulates from
/// `input_json_delta` chunks.
class AnthropicToolBlock {
  AnthropicToolBlock({this.id, this.name});

  final String? id;
  final String? name;
  final StringBuffer arguments = StringBuffer();

  bool get hasName => name != null && name!.isNotEmpty;

  ToolCallRequest toRequest() => ToolCallRequest(
    id: (id == null || id!.isEmpty) ? newCallId() : id!,
    name: name!,
    argumentsJson: arguments.toString(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// OpenAI Responses transport (/responses)
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the OpenAI Responses API request body from the app's
/// OpenAI-style wire messages. Pure function — unit-tested directly.
///
/// Mapping (wire chat messages → Responses `input` items):
/// * all `system` messages join with '\n\n' into the top-level
///   `instructions` field;
/// * `user` string/array content → `input_text` parts, `image_url` data
///   URIs → `input_image` parts;
/// * `assistant` text → an assistant message with `output_text` parts;
/// * `assistant.tool_calls` → one `function_call` item per call;
/// * `tool` messages → `function_call_output` items keyed by `call_id`;
/// * tools → the flat Responses function schema
///   (`{type:'function',name,description,parameters}` — NOT nested).
///
/// `store:false` keeps the gateway from persisting the turn server-side
/// (OpenAI defaults to retention that org-verified accounts only allow).
Map<String, dynamic> buildResponsesRequestBody({
  required LlmConfig config,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
}) {
  final List<String> systemParts = <String>[];
  final List<Map<String, dynamic>> input = <Map<String, dynamic>>[];

  for (final Map<String, dynamic> message in messages) {
    final String role = message['role']?.toString() ?? '';
    if (role == 'system') {
      systemParts.add(contentToText(message['content']));
    } else if (role == 'tool') {
      input.add(<String, dynamic>{
        'type': 'function_call_output',
        'call_id': message['tool_call_id']?.toString() ?? '',
        'output': contentToText(message['content']),
      });
    } else if (role == 'assistant') {
      final String text = contentToText(message['content']);
      if (text.isNotEmpty) {
        input.add(<String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'output_text', 'text': text},
          ],
        });
      }
      final Object? toolCalls = message['tool_calls'];
      if (toolCalls is List) {
        for (final Object? raw in toolCalls) {
          if (raw is! Map<String, dynamic>) continue;
          final Object? function = raw['function'];
          if (function is! Map<String, dynamic>) continue;
          final String name = function['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final String id = raw['id']?.toString() ?? '';
          input.add(<String, dynamic>{
            'type': 'function_call',
            'call_id': id.isEmpty ? newCallId() : id,
            'name': name,
            'arguments': (function['arguments'] ?? '{}').toString(),
          });
        }
      }
    } else {
      input.add(<String, dynamic>{
        'role': 'user',
        'content': responsesUserContent(message['content']),
      });
    }
  }

  return <String, dynamic>{
    'model': config.model,
    'input': input,
    'stream': true,
    'store': false,
    if (systemParts.isNotEmpty) 'instructions': systemParts.join('\n\n'),
    if (config.maxTokens != null) 'max_output_tokens': config.maxTokens,
    if (tools != null && tools.isNotEmpty)
      'tools': <Map<String, dynamic>>[
        for (final Map<String, dynamic> tool in tools)
          responsesToolSchema(tool),
      ],
  };
}

List<Map<String, dynamic>> responsesUserContent(Object? content) {
  if (content is List) {
    final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];
    for (final Object? part in content) {
      if (part is String) {
        parts.add(<String, dynamic>{'type': 'input_text', 'text': part});
        continue;
      }
      if (part is! Map<String, dynamic>) continue;
      final String type = part['type']?.toString() ?? '';
      if (type == 'image_url') {
        final Object? imageUrl = part['image_url'];
        final String? url = imageUrl is Map<String, dynamic>
            ? imageUrl['url']?.toString()
            : (imageUrl is String ? imageUrl : null);
        final RegExpMatch? dataUri = url == null
            ? null
            : dataUriPattern.firstMatch(url);
        if (dataUri != null) {
          // Responses takes the data URI directly.
          parts.add(<String, dynamic>{'type': 'input_image', 'image_url': url});
          continue;
        }
        parts.add(<String, dynamic>{'type': 'input_text', 'text': url ?? ''});
        continue;
      }
      final Object? text = part['text'];
      if (text != null) {
        parts.add(<String, dynamic>{
          'type': 'input_text',
          'text': text.toString(),
        });
      }
    }
    if (parts.isNotEmpty) return parts;
  }
  return <Map<String, dynamic>>[
    <String, dynamic>{'type': 'input_text', 'text': contentToText(content)},
  ];
}

/// OpenAI tool definition
/// (`{type:'function',function:{name,description,parameters}}`) → the
/// FLAT Responses function schema.
Map<String, dynamic> responsesToolSchema(Map<String, dynamic> tool) {
  final Object? function = tool['function'];
  final Map<String, dynamic> fn = function is Map<String, dynamic>
      ? function
      : <String, dynamic>{};
  final Object? parameters = fn['parameters'];
  return <String, dynamic>{
    'type': 'function',
    'name': fn['name']?.toString() ?? '',
    'description': fn['description']?.toString() ?? '',
    'parameters': parameters is Map<String, dynamic>
        ? parameters
        : <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
  };
}

/// Full (non-streaming) Responses payload:
/// `{output:[{type:'message',content:[{type:'output_text',text}]},
///   {type:'function_call',call_id,name,arguments}],usage,...}`.
AssistantTurn parseResponsesMessage(String raw) {
  final Object? decoded = tryDecodeJson(raw);
  if (decoded is! Map<String, dynamic>) {
    throw LlmException('Unknown response format: ${truncateForError(raw)}');
  }
  final Object? error = decoded['error'];
  if (error is Map<String, dynamic>) {
    final String message = error['message']?.toString() ?? '';
    if (message.isNotEmpty) throw LlmException(message);
  }
  final Object? output = decoded['output'];
  if (output is! List) {
    throw LlmException('Unknown response format: ${truncateForError(raw)}');
  }
  final StringBuffer text = StringBuffer();
  final List<ToolCallRequest> toolCalls = <ToolCallRequest>[];
  for (final Object? item in output) {
    if (item is! Map<String, dynamic>) continue;
    final String type = item['type']?.toString() ?? '';
    if (type == 'message') {
      final Object? content = item['content'];
      if (content is List) {
        for (final Object? part in content) {
          if (part is! Map<String, dynamic>) continue;
          if (part['type']?.toString() == 'output_text') {
            text.write(part['text']?.toString() ?? '');
          }
        }
      }
    } else if (type == 'function_call') {
      final String name = item['name']?.toString() ?? '';
      if (name.isEmpty) continue; // glitched entry — never crash
      final String callId = item['call_id']?.toString() ?? '';
      final String id = item['id']?.toString() ?? '';
      toolCalls.add(
        ToolCallRequest(
          id: callId.isNotEmpty ? callId : (id.isNotEmpty ? id : newCallId()),
          name: name,
          argumentsJson: (item['arguments'] ?? '{}').toString(),
        ),
      );
    }
  }
  return AssistantTurn(
    content: text.toString(),
    toolCalls: toolCalls,
    usage: _responsesUsage(decoded['usage']),
  );
}

TokenUsage? _responsesUsage(Object? raw) {
  final Map<String, dynamic>? usage = asJsonMap(raw);
  if (usage == null) return null;
  final int? input = asJsonInt(usage['input_tokens']);
  final int? output = asJsonInt(usage['output_tokens']);
  if (input == null && output == null) return null;
  return TokenUsage(promptTokens: input ?? 0, completionTokens: output ?? 0);
}

/// Responses SSE consumption. Key events (OpenAI Responses API, relayed
/// by new-api gateways):
/// * `response.output_text.delta` — assistant text tokens;
/// * `response.output_item.added` / `response.function_call_arguments.delta`
///   / `response.output_item.done` — tool calls accumulate per `item_id`;
/// * `response.completed` / `response.incomplete` — final usage;
/// * `response.failed` / `error` — provider errors.
Future<AssistantTurn> consumeResponsesStream(
  http.ByteStream stream,
  void Function(String delta)? onDelta,
  bool Function()? shouldAbort,
) async {
  final StringBuffer contentBuffer = StringBuffer();
  final Map<String, ResponsesToolAccumulator> tools =
      <String, ResponsesToolAccumulator>{};
  TokenUsage? usage;
  var lineBuffer = '';
  var done = false;
  var aborted = false;

  try {
    await for (final chunk in stream.transform(utf8.decoder)) {
      if (shouldAbort?.call() ?? false) {
        aborted = true;
        break;
      }
      lineBuffer += chunk;
      while (true) {
        final int newlineIndex = lineBuffer.indexOf('\n');
        if (newlineIndex < 0) break;
        final String line = lineBuffer.substring(0, newlineIndex).trim();
        lineBuffer = lineBuffer.substring(newlineIndex + 1);

        if (line.isEmpty || line.startsWith(':')) continue;
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') {
          done = true;
          break;
        }

        final Object? decoded = tryDecodeJson(data);
        if (decoded is! Map<String, dynamic>) continue; // malformed JSON
        final String type = decoded['type']?.toString() ?? '';

        if (type == 'error') {
          throw LlmException(openAiErrorMessage(data));
        }
        if (type == 'response.failed') {
          final Map<String, dynamic>? response = asJsonMap(decoded['response']);
          final Map<String, dynamic>? error = asJsonMap(response?['error']);
          throw LlmException(
            error?['message']?.toString() ??
                response?['status']?.toString() ??
                'Responses request failed',
          );
        }

        if (type == 'response.output_text.delta') {
          final String delta = decoded['delta']?.toString() ?? '';
          if (delta.isNotEmpty) {
            contentBuffer.write(delta);
            onDelta?.call(delta);
          }
        } else if (type == 'response.output_item.added') {
          final Map<String, dynamic>? item = asJsonMap(decoded['item']);
          if (item != null && item['type']?.toString() == 'function_call') {
            final String itemId = item['id']?.toString() ?? '';
            final String key = itemId.isNotEmpty
                ? itemId
                : 'index-${tools.length}';
            final ResponsesToolAccumulator acc = tools.putIfAbsent(
              key,
              ResponsesToolAccumulator.new,
            );
            acc.callId = item['call_id']?.toString() ?? acc.callId;
            acc.name = item['name']?.toString() ?? acc.name;
          }
        } else if (type == 'response.function_call_arguments.delta') {
          final String itemId = decoded['item_id']?.toString() ?? '';
          final ResponsesToolAccumulator acc = tools.putIfAbsent(
            itemId.isNotEmpty ? itemId : 'index-${tools.length}',
            ResponsesToolAccumulator.new,
          );
          acc.arguments.write(decoded['delta']?.toString() ?? '');
        } else if (type == 'response.output_item.done') {
          final Map<String, dynamic>? item = asJsonMap(decoded['item']);
          if (item != null && item['type']?.toString() == 'function_call') {
            final String itemId = item['id']?.toString() ?? '';
            final ResponsesToolAccumulator acc = tools.putIfAbsent(
              itemId.isNotEmpty ? itemId : 'index-${tools.length}',
              ResponsesToolAccumulator.new,
            );
            acc.callId = item['call_id']?.toString() ?? acc.callId;
            acc.name = item['name']?.toString() ?? acc.name;
            // The done event carries the COMPLETE arguments — replace any
            // accumulated deltas with the authoritative body.
            final Object? args = item['arguments'];
            if (args != null && args.toString().isNotEmpty) {
              acc.arguments
                ..clear()
                ..write(args.toString());
            }
          }
        } else if (type == 'response.completed' ||
            type == 'response.incomplete') {
          final Map<String, dynamic>? response = asJsonMap(decoded['response']);
          usage = _responsesUsage(response?['usage']) ?? usage;
          done = true;
        }
        // Everything else (response.created, response.in_progress,
        // reasoning summaries, *part.added/done, output_text.done) needs
        // no handling.
      }
      if (done) break;
    }
  } on LlmException {
    rethrow;
  } catch (e) {
    if (tools.isEmpty && contentBuffer.isNotEmpty) {
      return AssistantTurn(content: contentBuffer.toString());
    }
    throw LlmException('Connection lost while streaming: $e');
  }
  if (aborted) {
    throw LlmAbortedException(contentBuffer.toString());
  }

  return AssistantTurn(
    content: contentBuffer.toString(),
    usage: usage,
    toolCalls: <ToolCallRequest>[
      for (final ResponsesToolAccumulator acc in tools.values)
        if (acc.hasName) acc.toRequest(),
    ],
  );
}

/// Consumes a 200 Responses-API response: SSE stream or full JSON body.
Future<AssistantTurn> consumeResponsesResponse(
  http.StreamedResponse response,
  void Function(String delta)? onDelta,
  bool Function()? shouldAbort,
) async {
  final String contentType = (response.headers['content-type'] ?? '')
      .toLowerCase();
  if (contentType.contains('text/event-stream')) {
    try {
      return await consumeResponsesStream(
        response.stream,
        onDelta,
        shouldAbort,
      );
    } on LlmAbortedException {
      rethrow;
    } on LlmException {
      rethrow;
    } catch (e) {
      throw LlmException('Connection lost while streaming: $e');
    }
  }
  if (shouldAbort?.call() ?? false) {
    throw const LlmAbortedException('');
  }
  final String raw = await response.stream.bytesToString();
  return parseResponsesMessage(raw);
}

/// Accumulator for one Responses `function_call` item, keyed by `item_id`:
/// name/call_id arrive in `output_item.added`, arguments stream through
/// `function_call_arguments.delta`, and `output_item.done` carries the
/// complete authoritative arguments.
class ResponsesToolAccumulator {
  String? callId;
  String? name;
  final StringBuffer arguments = StringBuffer();

  bool get hasName => name != null && name!.isNotEmpty;

  ToolCallRequest toRequest() => ToolCallRequest(
    id: (callId == null || callId!.isEmpty) ? newCallId() : callId!,
    name: name!,
    argumentsJson: arguments.toString(),
  );
}
