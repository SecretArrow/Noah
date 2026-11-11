import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException;
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'wire_transports.dart';

/// Connection settings for an OpenAI-compatible endpoint.
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.maxTokens,
    this.engine = LlmEngine.auto,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  /// Optional hard cap on generated tokens (null = provider default).
  /// The Anthropic-protocol transport (AgentRouter) needs it for the
  /// REQUIRED `max_tokens` request field; OpenAI-compatible providers
  /// ignore it.
  final int? maxTokens;

  /// v1.49.4 — wire protocol used to reach this provider. [LlmEngine.auto]
  /// keeps the historical behavior (Chat Completions, with the AgentRouter
  /// subclass adding its per-model routing + one-shot fallbacks); the
  /// pinned values force one transport for providers whose models speak a
  /// specific protocol (e.g. gpt-6.1-sol only serves the OpenAI Responses
  /// API, native Anthropic deployments only serve Messages).
  final LlmEngine engine;
}

/// A tool call requested by the model (arguments still raw JSON string).
class ToolCallRequest {
  ToolCallRequest({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;

  /// Parsed arguments; falls back to an empty map on malformed JSON.
  Map<String, dynamic> get args {
    try {
      final decoded = jsonDecode(argumentsJson.isEmpty ? '{}' : argumentsJson);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // fall through
    }
    return <String, dynamic>{};
  }
}

/// Thrown when [LlmClient.complete] is aborted through its `shouldAbort`
/// callback (the user pressed Stop). Carries whatever content was already
/// streamed so the caller can keep the partial answer.
class LlmAbortedException implements Exception {
  const LlmAbortedException(this.partialContent);

  final String partialContent;

  @override
  String toString() => 'LlmAbortedException';
}

/// One completed assistant turn: streamed text + any tool calls.
class AssistantTurn {
  AssistantTurn({
    required this.content,
    this.toolCalls = const <ToolCallRequest>[],
    this.usage,
  });

  final String content;
  final List<ToolCallRequest> toolCalls;

  /// Token usage reported by the provider for this turn (null when the
  /// provider does not report it or the stream was cut short).
  final TokenUsage? usage;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

class LlmException implements Exception {
  LlmException(this.message, {this.statusCode});

  final String message;

  /// HTTP status code when the failure came from a provider response —
  /// lets the auto-retry logic (v1.30.0) tell transient server errors
  /// (429/5xx, worth another attempt) from permanent ones (401/400).
  final int? statusCode;

  @override
  String toString() => message;
}

/// True when [error] is worth another automatic attempt (v1.30.0):
/// transport failures (unreachable provider, dropped stream, socket or
/// timeout errors) and transient HTTP responses (408/425/429 and all
/// 5xx). Authentication and bad-request errors are permanent — retrying
/// them would only burn the attempt budget. A user-initiated
/// [LlmAbortedException] (Stop) is never retried.
bool isRetryableLlmError(Object? error) {
  if (error is LlmAbortedException) return false;
  if (error is LlmException) {
    final int? code = error.statusCode;
    if (code != null) return _retryableStatusCode(code);
    final String m = error.message.toLowerCase();
    return m.contains('could not connect') ||
        m.contains('connection lost') ||
        m.contains('failed to read response') ||
        m.contains('timeout');
  }
  return error is SocketException ||
      error is HttpException ||
      error is TimeoutException;
}

bool _retryableStatusCode(int code) =>
    code == 408 || code == 425 || code == 429 || (code >= 500 && code <= 599);

/// Streaming client for OpenAI-compatible chat completion APIs
/// (OpenRouter, Z.AI, OpenAI, DeepSeek, Groq, ...).
class LlmClient {
  LlmClient({
    http.Client? client,
    Map<String, String> Function(Uri url)? extraHeaders,
    this._onResponseHeaders,
  }) : _injectedClient = client,
       _extraRequestHeaders = extraHeaders;

  /// Optional injected transport (tests). When null, every [complete] call
  /// owns a dedicated client — which is what makes per-run force cancel
  /// possible: closing one run's client can never touch another chat's
  /// in-flight stream.
  final http.Client? _injectedClient;

  /// Optional per-URL extra headers merged into every outgoing request of
  /// this client. The base transport ships none; the AgentRouter subclass
  /// injects one so its OpenAI-compatible fallback traffic to agentrouter
  /// hosts carries the required User-Agent. Deliberately a private
  /// constructor-injected callback (not a public member) so that
  /// `implements LlmClient` test doubles are unaffected.
  final Map<String, String> Function(Uri url)? _extraRequestHeaders;

  /// v1.49.6 — optional observer for every response HEAD line of this
  /// client (all engines, error statuses included). The AgentRouter
  /// subclass uses it to harvest Aliyun WAF cookies (`acw_tc` et al.) so
  /// the anti-block retry can replay them. Exceptions from the observer
  /// are swallowed — an analytics-style hook must never break a stream.
  final void Function(Uri url, Map<String, String> headers)? _onResponseHeaders;

  void _notifyResponseHeaders(Uri url, http.BaseResponse response) {
    final void Function(Uri, Map<String, String>)? hook = _onResponseHeaders;
    if (hook == null) return;
    try {
      hook(url, response.headers);
    } catch (_) {
      // Never let the observer mask the actual result.
    }
  }

  /// v1.42.0 — live streaming requests keyed by the caller's [cancelKey]
  /// (the agent loop passes its per-run object). [forceCancel] looks a run
  /// up here and hard-closes its HTTP client, which aborts even a STALLED
  /// stream that emits no deltas (the `shouldAbort` poll only runs between
  /// chunks — a silent connection would otherwise pin the run forever).
  static final Map<Object, http.Client> _liveStreams = <Object, http.Client>{};

  /// v1.42.0 — force-stops the in-flight request(s) registered under
  /// [cancelKey]: the client is closed forcefully so the pending socket
  /// read errors out immediately. Returns true when a live request was
  /// found and killed. Safe to call at any time; no-op when nothing is
  /// registered (run already between requests, finished, or test double).
  static bool forceCancel(Object cancelKey) {
    final http.Client? client = _liveStreams.remove(cancelKey);
    if (client == null) return false;
    try {
      client.close();
    } catch (_) {
      // Best-effort: a broken transport is exactly the state we want.
    }
    return true;
  }

  /// Registers [client] as the live request for [key]. Shared by the base
  /// OpenAI transport AND the Anthropic-protocol AgentRouter transport, so
  /// per-run force-cancel works identically on both protocols.
  static void registerLiveStream(Object key, http.Client client) {
    _liveStreams[key] = client;
  }

  /// Removes [client] from [key]'s registry — only when it is still the
  /// registered one, so a fallback transport registering under the same
  /// key is never clobbered by the probe request's cleanup.
  static void unregisterLiveStream(Object key, http.Client client) {
    if (identical(_liveStreams[key], client)) _liveStreams.remove(key);
  }

  http.Client _clientForCall() => _injectedClient ?? http.Client();

  /// Sends a chat completion request and streams the assistant turn.
  ///
  /// [onDelta] receives incremental content tokens while streaming.
  /// Tool call deltas are accumulated internally and returned with the turn.
  /// [shouldAbort] is polled while streaming; when it returns true the
  /// connection is torn down immediately and [LlmAbortedException] is
  /// thrown with the partial content — Stop must feel instant.
  ///
  /// v1.49.4: [LlmConfig.engine] routes the turn — `anthropic` speaks the
  /// Messages protocol on `{base}/messages`, `openaiResponses` speaks the
  /// OpenAI Responses API on `{base}/responses`, `openai`/`auto` keep the
  /// Chat Completions transport below (auto additionally retries once
  /// through Responses when the provider's own 400 names `/v1/responses`).
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    if (shouldAbort?.call() ?? false) {
      throw const LlmAbortedException('');
    }
    switch (config.engine) {
      case LlmEngine.anthropic:
        return _completeViaAnthropic(
          config,
          messages,
          tools,
          onDelta,
          shouldAbort,
          cancelKey,
        );
      case LlmEngine.openaiResponses:
        return _completeViaResponses(
          config,
          messages,
          tools,
          onDelta,
          shouldAbort,
          cancelKey,
        );
      case LlmEngine.auto:
      case LlmEngine.openai:
        return _completeViaChatCompletions(
          config,
          messages,
          tools,
          onDelta,
          shouldAbort,
          cancelKey,
        );
    }
  }

  /// The historical Chat Completions transport (engine `openai` / `auto`).
  Future<AssistantTurn> _completeViaChatCompletions(
    LlmConfig config,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  ) async {
    final url = Uri.parse(
      '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions',
    );
    final requestBody = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'stream': true,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
      // Ask for token usage on the stream (OpenAI-compatible). Providers
      // that reject the parameter trigger one clean retry without it.
      'stream_options': <String, dynamic>{'include_usage': true},
    };

    // v1.42.0: register the per-call client under [cancelKey] for the
    // whole request lifetime (send + stream consumption) so [forceCancel]
    // can tear it down mid-flight; unregister in the finally below. The
    // client is closed here too when we own it, keeping sockets from
    // leaking while preserving injected test transports.
    final http.Client callClient = _clientForCall();
    final bool ownsClient = _injectedClient == null;
    if (cancelKey != null) registerLiveStream(cancelKey, callClient);
    try {
      return await _sendAndConsume(
        callClient,
        config,
        url,
        requestBody,
        onDelta,
        shouldAbort,
        messages: messages,
        tools: tools,
        cancelKey: cancelKey,
      );
    } finally {
      if (cancelKey != null) unregisterLiveStream(cancelKey, callClient);
      if (ownsClient) {
        try {
          callClient.close();
        } catch (_) {
          // Never let transport cleanup mask the actual result.
        }
      }
    }
  }

  /// Anthropic Messages transport for engine `anthropic`: POSTs the
  /// mapped body to `{base}/messages` with the protocol headers, dual
  /// auth and the shared SSE/JSON consumer.
  Future<AssistantTurn> _completeViaAnthropic(
    LlmConfig config,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  ) async {
    final Uri url = Uri.parse(
      '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/messages',
    );
    final Map<String, dynamic> requestBody = buildAnthropicRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );

    final http.Client callClient = _clientForCall();
    final bool ownsClient = _injectedClient == null;
    if (cancelKey != null) registerLiveStream(cancelKey, callClient);
    try {
      http.StreamedResponse response;
      try {
        final http.Request request = http.Request('POST', url)
          ..headers.addAll(anthropicHeaders(config.apiKey))
          ..headers.addAll(
            _extraRequestHeaders?.call(url) ?? const <String, String>{},
          )
          ..body = await encodeBodyOffIsolate(requestBody);
        response = await callClient.send(request);
      } catch (e) {
        throw LlmException('Could not connect to provider: $e');
      }
      _notifyResponseHeaders(url, response);
      if (response.statusCode != 200) {
        final String raw = await response.stream.bytesToString();
        throw LlmException(
          'HTTP ${response.statusCode}: ${_truncate(raw, 300)}',
          statusCode: response.statusCode,
        );
      }
      return await consumeAnthropicResponse(response, onDelta, shouldAbort);
    } finally {
      if (cancelKey != null) unregisterLiveStream(cancelKey, callClient);
      if (ownsClient) {
        try {
          callClient.close();
        } catch (_) {
          // Never let transport cleanup mask the actual result.
        }
      }
    }
  }

  /// OpenAI Responses transport for engine `openaiResponses`: POSTs the
  /// mapped body to `{base}/responses` with Bearer auth and the shared
  /// SSE/JSON consumer. Also the one-shot landing spot for the auto
  /// engine when a provider's 400 names `/v1/responses`.
  Future<AssistantTurn> _completeViaResponses(
    LlmConfig config,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  ) async {
    final Uri url = Uri.parse(
      '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/responses',
    );
    final Map<String, dynamic> requestBody = buildResponsesRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );

    final http.Client callClient = _clientForCall();
    final bool ownsClient = _injectedClient == null;
    if (cancelKey != null) registerLiveStream(cancelKey, callClient);
    try {
      http.StreamedResponse response;
      try {
        final http.Request request = http.Request('POST', url)
          ..headers.addAll(responsesHeaders(config.apiKey))
          ..headers.addAll(
            _extraRequestHeaders?.call(url) ?? const <String, String>{},
          )
          ..body = await encodeBodyOffIsolate(requestBody);
        response = await callClient.send(request);
      } catch (e) {
        throw LlmException('Could not connect to provider: $e');
      }
      _notifyResponseHeaders(url, response);
      if (response.statusCode != 200) {
        final String raw = await response.stream.bytesToString();
        throw LlmException(
          'HTTP ${response.statusCode}: ${_truncate(raw, 300)}',
          statusCode: response.statusCode,
        );
      }
      return await consumeResponsesResponse(response, onDelta, shouldAbort);
    } finally {
      if (cancelKey != null) unregisterLiveStream(cancelKey, callClient);
      if (ownsClient) {
        try {
          callClient.close();
        } catch (_) {
          // Never let transport cleanup mask the actual result.
        }
      }
    }
  }

  Future<AssistantTurn> _sendAndConsume(
    http.Client callClient,
    LlmConfig config,
    Uri url,
    Map<String, dynamic> requestBody,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort, {
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    Object? cancelKey,
  }) async {
    final http.StreamedResponse response;
    try {
      response = await callClient.send(
        await _buildRequest(config, url, requestBody),
      );
    } catch (e) {
      throw LlmException('Could not connect to provider: $e');
    }
    _notifyResponseHeaders(url, response);

    if (response.statusCode == 400) {
      // Some providers do not know stream_options: one quiet retry with a
      // plain body keeps the chat working (usage simply stays null).
      final String errorBody = await response.stream.bytesToString();
      if (errorBody.contains('stream_options')) {
        final Map<String, dynamic> retryBody = Map<String, dynamic>.of(
          requestBody,
        )..remove('stream_options');
        try {
          final http.StreamedResponse retry = await callClient.send(
            await _buildRequest(config, url, retryBody),
          );
          _notifyResponseHeaders(url, retry);
          if (retry.statusCode == 200) {
            return await _consume(retry, onDelta, shouldAbort);
          }
        } catch (_) {
          // Fall through to the normal error path below.
        }
      }
      if (config.engine == LlmEngine.auto && needsResponsesApi(errorBody)) {
        // The provider itself names the protocol that serves this model
        // ("does not support /v1/chat/completions, please use
        // /v1/responses instead") — one deterministic retry through the
        // Responses transport (v1.49.4). Pinned OpenAI engines keep the
        // error (with the engine hint from the AgentRouter wrapper).
        return _completeViaResponses(
          config,
          messages,
          tools,
          onDelta,
          shouldAbort,
          cancelKey,
        );
      }
      throw LlmException(
        'HTTP ${response.statusCode}: ${_truncate(errorBody, 300)}',
        statusCode: 400,
      );
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException(
        'HTTP ${response.statusCode}: ${_truncate(body, 300)}',
        statusCode: response.statusCode,
      );
    }

    return _consume(response, onDelta, shouldAbort);
  }

  Future<http.Request> _buildRequest(
    LlmConfig config,
    Uri url,
    Map<String, dynamic> body,
  ) async => http.Request('POST', url)
    ..headers['Authorization'] = 'Bearer ${config.apiKey}'
    ..headers['Content-Type'] = 'application/json'
    ..headers['Accept'] = 'text/event-stream'
    // OpenRouter attribution (ignored by other providers).
    ..headers['HTTP-Referer'] = 'https://github.com/SecretArrow/Noah'
    ..headers['X-Title'] = 'Noah'
    ..headers.addAll(
      _extraRequestHeaders?.call(url) ?? const <String, String>{},
    )
    // v1.38.0: encode OFF the UI isolate — every agent step re-encodes
    // the whole conversation (tool outputs + cached base64 images can
    // reach multiple MB) and a main-thread jsonEncode of that size
    // stalls every frame; ChatStore.save already does this for the same
    // payloads.
    ..body = await Isolate.run(() => jsonEncode(body));

  /// Shared response consumption: non-streaming JSON or SSE stream.
  Future<AssistantTurn> _consume(
    http.StreamedResponse response,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
  ) async {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (!contentType.contains('text/event-stream')) {
      // Some providers ignore `stream: true`; parse a plain JSON response.
      if (shouldAbort?.call() ?? false) {
        throw const LlmAbortedException('');
      }
      final raw = await response.stream.bytesToString();
      return _parseNonStreaming(raw);
    }
    try {
      return await _parseSse(response.stream, onDelta, shouldAbort);
    } on LlmAbortedException {
      rethrow;
    } on LlmException {
      rethrow;
    } catch (e) {
      // Network drop mid-stream: keep whatever was streamed so far when it
      // is usable text, otherwise surface a connection error.
      throw LlmException('Connection lost while streaming: $e');
    }
  }

  AssistantTurn _parseNonStreaming(String raw) {
    try {
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final choices = obj['choices'];
      if (choices is List && choices.isNotEmpty) {
        final message = choices.first['message'];
        if (message is Map<String, dynamic>) {
          return AssistantTurn(
            content: message['content']?.toString() ?? '',
            toolCalls: _parseFullToolCalls(message['tool_calls']),
            usage: TokenUsage.fromJson(obj['usage']),
          );
        }
      }
      throw LlmException('Unknown response format: ${_truncate(raw, 200)}');
    } on LlmException {
      rethrow;
    } catch (e) {
      // Non-JSON bodies (WAF challenge pages, HTML error pages) MUST keep
      // their content in the error: downstream AgentRouter detection
      // (looksLikeWafChallenge / looksLikeInvalidApiKey) and user
      // diagnostics both read this snippet. 600 chars — WAF markers live
      // in the page head/scripts.
      throw LlmException('Failed to read response: ${_truncate(raw, 600)}');
    }
  }

  Future<AssistantTurn> _parseSse(
    http.ByteStream stream,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
  ) async {
    final contentBuffer = StringBuffer();
    final toolAccumulators = <int, _ToolAccumulator>{};
    TokenUsage? usage;
    var lineBuffer = '';
    var done = false;
    var aborted = false;

    try {
      await for (final chunk in stream.transform(utf8.decoder)) {
        // Stop must interrupt DURING generation: bail out of the stream at
        // the first chance, which also cancels the HTTP subscription and
        // tears the connection down.
        if (shouldAbort?.call() ?? false) {
          aborted = true;
          break;
        }
        lineBuffer += chunk;
        while (true) {
          final newlineIndex = lineBuffer.indexOf('\n');
          if (newlineIndex < 0) break;
          final line = lineBuffer.substring(0, newlineIndex).trim();
          lineBuffer = lineBuffer.substring(newlineIndex + 1);

          if (line.isEmpty || line.startsWith(':')) continue;
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data == '[DONE]') {
            done = true;
            break;
          }

          Map<String, dynamic> event;
          try {
            final decoded = jsonDecode(data);
            if (decoded is! Map<String, dynamic>) continue;
            event = decoded;
          } catch (_) {
            continue;
          }

          // The usage event may arrive with an empty choices list (OpenAI
          // compatible include_usage final chunk) — capture it BEFORE the
          // choices guard below.
          final Object? eventUsage = event['usage'];
          if (eventUsage is Map<String, dynamic>) {
            usage = TokenUsage.fromJson(eventUsage) ?? usage;
          }

          final choices = event['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final delta = choices.first['delta'];
          if (delta is! Map<String, dynamic>) continue;

          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            contentBuffer.write(content);
            onDelta?.call(content);
          }

          final toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final raw in toolCalls) {
              if (raw is! Map<String, dynamic>) continue;
              final index = (raw['index'] as int?) ?? toolAccumulators.length;
              final acc = toolAccumulators.putIfAbsent(
                index,
                _ToolAccumulator.new,
              );
              if (raw['id'] is String && (acc.id == null || acc.id!.isEmpty)) {
                acc.id = raw['id'] as String;
              }
              final function = raw['function'];
              if (function is Map<String, dynamic>) {
                final name = function['name'];
                if (name is String &&
                    name.isNotEmpty &&
                    (acc.name == null || acc.name!.isEmpty)) {
                  acc.name = name;
                }
                final arguments = function['arguments'];
                if (arguments is String) acc.arguments.write(arguments);
              }
            }
          }
        }
        if (done) break;
      }
    } on LlmException {
      rethrow;
    } catch (e) {
      // A dropped socket mid-stream must not crash the app: keep partial
      // plain-text content, but never return half-received tool calls
      // (their JSON arguments would be truncated and unusable).
      if (toolAccumulators.isEmpty && contentBuffer.isNotEmpty) {
        return AssistantTurn(content: contentBuffer.toString());
      }
      throw LlmException('Connection lost while streaming: $e');
    }
    if (aborted) {
      throw LlmAbortedException(contentBuffer.toString());
    }

    final ordered = toolAccumulators.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return AssistantTurn(
      content: contentBuffer.toString(),
      usage: usage,
      toolCalls: <ToolCallRequest>[
        for (final entry in ordered)
          if (entry.value.name != null) entry.value.toRequest(),
      ],
    );
  }

  List<ToolCallRequest> _parseFullToolCalls(Object? rawToolCalls) {
    if (rawToolCalls is! List) return const <ToolCallRequest>[];
    final out = <ToolCallRequest>[];
    for (final raw in rawToolCalls) {
      if (raw is! Map<String, dynamic>) continue;
      final function = raw['function'];
      if (function is! Map<String, dynamic>) continue;
      final Object? name = function['name'];
      // A provider glitch (missing name) must not crash the app: the entry
      // is skipped instead of throwing on null.
      if (name == null || name.toString().isEmpty) continue;
      out.add(
        ToolCallRequest(
          id: raw['id']?.toString() ?? newCallId(),
          name: name.toString(),
          argumentsJson: (function['arguments'] ?? '').toString(),
        ),
      );
    }
    return out;
  }

  String _truncate(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}...';
}

int _callCounter = 0;
String newCallId() =>
    'call_${DateTime.now().millisecondsSinceEpoch}_${_callCounter++}';

class _ToolAccumulator {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  ToolCallRequest toRequest() => ToolCallRequest(
    id: (id == null || id!.isEmpty) ? newCallId() : id!,
    name: name!,
    argumentsJson: arguments.toString(),
  );
}
