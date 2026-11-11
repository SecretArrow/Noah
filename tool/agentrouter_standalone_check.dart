// Standalone AgentRouter verification harness (room-browser recipe,
// v1.49.3). Drives the REAL AgentRouterLlmClient and ModelCatalogClient
// against a local mock gateway that impersonates the official deployments
// (apex agentrouter.org style, co.agentrouter.org style) plus the Aliyun
// WAF challenge mode — asserting wire-level behavior (paths, User-Agent,
// dual auth, anthropic-version) and the v1.49.3 routing/error contract.
//
// Run through the flutter test wrapper:
//   flutter test test/unit/agentrouter_standalone_check_test.dart
// (the app client transitively imports Flutter, so a bare `dart run` is
// not possible.)
//
// Opt-in LIVE probes (never asserted — network-dependent): set
// AGENTROUTER_LIVE=1 and AGENTROUTER_KEY=<key> to also probe
// https://agentrouter.org/v1 with GET /models + POST chat gpt-6-astra.
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
// RemoteModel lives in model_catalog.dart — no models.dart import needed.
import 'package:noah/services/agentrouter_client.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/model_catalog.dart';

const String kClaudeCliUa = 'claude-cli/1.0.60 (external, cli)';

const String _wafHtml =
    '<!DOCTYPE html><html><head>'
    '<script>var acw_sc__v2="challenge";</script></head>'
    '<body>Aliyun WAF anti-bot captcha slider — verify</body></html>';

/// One observed request: method, path, headers, body (for wire asserts).
class _Seen {
  _Seen(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;

  String header(String name) =>
      headers[name] ?? headers[name.toLowerCase()] ?? '';
}

/// Routes requests for agentrouter.org hosts to a local mock gateway while
/// the client under test still SEES the real agentrouter.org URLs — this
/// is what exercises [isAgentRouterHost], the User-Agent hook and the
/// protocol routing end-to-end over real HTTP.
class _HostRewriteClient extends http.BaseClient {
  _HostRewriteClient(this._targetBase);

  final Uri _targetBase;
  final IOClient _inner = IOClient();
  final List<_Seen> seen = <_Seen>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.Request copy =
        http.Request(
            request.method,
            request.url.replace(
              scheme: _targetBase.scheme,
              host: _targetBase.host,
              port: _targetBase.port,
            ),
          )
          ..headers.addAll(request.headers)
          ..followRedirects = request.followRedirects;
    if (request is http.Request) copy.bodyBytes = request.bodyBytes;
    seen.add(_Seen(copy.method, copy.url.path, copy.headers, copy.body));
    return _inner.send(copy);
  }

  @override
  void close() {
    _inner.close();
  }
}

/// Mock gateway: programmable per-path responses. Bind happens in
/// [start] — `base` is safe to read only on the returned instance.
class _Gateway {
  _Gateway._();

  late final HttpServer _server;

  /// handler(path) → status (default 200).
  int Function(String path)? statusOf;
  String Function(String path)? contentTypeOf;
  String Function(String path)? bodyOf;
  final List<String> hits = <String>[];

  static Future<_Gateway> start() async {
    final _Gateway gateway = _Gateway._();
    gateway._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    gateway._server.listen((HttpRequest req) async {
      final String path = req.uri.path;
      gateway.hits.add(path);
      final String body = gateway.bodyOf?.call(path) ?? 'not found';
      // Default 200: cases that only program bodyOf expect a healthy
      // endpoint; failure cases set statusOf explicitly.
      final int status = gateway.statusOf?.call(path) ?? 200;
      final String type =
          gateway.contentTypeOf?.call(path) ?? 'application/json';
      req.response.statusCode = status;
      req.response.headers.set('content-type', type);
      req.response.add(utf8.encode(body));
      await req.response.close();
    });
    return gateway;
  }

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

String _anthropicJson(String text) => jsonEncode(<String, dynamic>{
  'content': <Map<String, dynamic>>[
    <String, dynamic>{'type': 'text', 'text': text},
  ],
  'usage': <String, dynamic>{'input_tokens': 1, 'output_tokens': 1},
});

String _openAiSse(String text) =>
    'data: {"choices":[{"delta":{"content":"$text"}}]}\n\ndata: [DONE]\n\n';

/// SSE bodies MUST travel as text/event-stream — the client's _consume
/// branches on the content-type, exactly like the real gateway does.
String _sseOrJson(String path) {
  if (path.endsWith('/chat/completions')) {
    return 'text/event-stream';
  }
  return 'application/json';
}

const List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[
  <String, dynamic>{'role': 'user', 'content': 'hi'},
];

LlmConfig _cfg(String base, String model) =>
    LlmConfig(baseUrl: base, apiKey: 'test-key-xyz', model: model);

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _expectWafError(Future<AssistantTurn> future) async {
  try {
    await future;
  } on LlmException catch (e) {
    _check(
      e.message.contains('mobile data'),
      'WAF error should tell the user to switch networks, got: ${e.message}',
    );
    return;
  }
  throw StateError('Expected an LlmException for the WAF page.');
}

/// Runs every mock-gateway case; throws [StateError] on the first failure.
/// Invoked from the flutter-test wrapper (and [main] below).
Future<void> runChecks() async {
  // ── 1. gpt model → OpenAI-compatible path first, full UA branding ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.bodyOf = (String p) =>
        p.endsWith('/chat/completions') ? _openAiSse('via openai') : '';
    g.contentTypeOf = _sseOrJson;
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    final AssistantTurn turn = await client.complete(
      config: _cfg('https://agentrouter.org/v1', 'gpt-6-astra'),
      messages: _messages,
    );
    _check(turn.content == 'via openai', 'case1: wrong content');
    _check(httpc.seen.length == 1, 'case1: expected 1 request');
    _check(
      httpc.seen.single.path == '/v1/chat/completions',
      'case1: gpt must hit /v1/chat/completions first, got '
      '${httpc.seen.single.path}',
    );
    _check(
      httpc.seen.single.header('user-agent') == kClaudeCliUa,
      'case1: missing claude-cli User-Agent',
    );
    _check(
      httpc.seen.single.header('authorization') == 'Bearer test-key-xyz',
      'case1: missing Bearer auth',
    );
    await g.close();
  }

  // ── 2. claude model → Anthropic path first, dual-auth + version ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.bodyOf = (String p) =>
        p.endsWith('/messages') ? _anthropicJson('via anthropic') : '';
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    final AssistantTurn turn = await client.complete(
      config: _cfg('https://agentrouter.org/v1', 'claude-sonnet-4'),
      messages: _messages,
    );
    _check(turn.content == 'via anthropic', 'case2: wrong content');
    _check(httpc.seen.single.path == '/v1/messages', 'case2: wrong path');
    _check(
      httpc.seen.single.header('x-api-key') == 'test-key-xyz',
      'case2: missing x-api-key',
    );
    _check(
      httpc.seen.single.header('authorization') == 'Bearer test-key-xyz',
      'case2: missing Bearer',
    );
    _check(
      httpc.seen.single.header('anthropic-version') == kAnthropicVersion,
      'case2: missing anthropic-version',
    );
    _check(
      httpc.seen.single.header('user-agent') == kClaudeCliUa,
      'case2: missing claude-cli User-Agent',
    );
    _check(
      httpc.seen.single.body.contains('"max_tokens"'),
      'case2: Anthropic body must carry max_tokens',
    );
    await g.close();
  }

  // ── 3. OpenAI 404 → one-shot Anthropic fallback ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.statusOf = (String p) => p.endsWith('/chat/completions') ? 404 : 200;
    g.bodyOf = (String p) =>
        p.endsWith('/messages') ? _anthropicJson('saved') : 'not found';
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    final AssistantTurn turn = await client.complete(
      config: _cfg('https://agentrouter.org/v1', 'gpt-6-astra'),
      messages: _messages,
    );
    _check(turn.content == 'saved', 'case3: fallback turn lost');
    _check(
      g.hits.join(',') == '/v1/chat/completions,/v1/messages',
      'case3: wrong wire order: ${g.hits.join(',')}',
    );
    await g.close();
  }

  // ── 4. Anthropic 404 → one-shot OpenAI fallback ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.statusOf = (String p) => p.endsWith('/messages') ? 404 : 200;
    g.bodyOf = (String p) =>
        p.endsWith('/chat/completions') ? _openAiSse('via openai') : '';
    g.contentTypeOf = _sseOrJson;
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    final AssistantTurn turn = await client.complete(
      config: _cfg('https://agentrouter.org/v1', 'claude-sonnet-4'),
      messages: _messages,
    );
    _check(turn.content == 'via openai', 'case4: fallback turn lost');
    _check(
      g.hits.join(',') == '/v1/messages,/v1/chat/completions',
      'case4: wrong wire order: ${g.hits.join(',')}',
    );
    await g.close();
  }

  // ── 5. anti-loop: both protocols 404 → exactly 2 requests ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.statusOf = (String p) => 404; // both protocols dead
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    Object? error;
    try {
      await client.complete(
        config: _cfg('https://agentrouter.org/v1', 'gpt-6-astra'),
        messages: _messages,
      );
    } on LlmException catch (e) {
      error = e;
    }
    _check(error is LlmException, 'case5: expected LlmException');
    _check(
      g.hits.length == 2,
      'case5: anti-loop violated, hits=${g.hits.join(',')}',
    );
    await g.close();
  }

  // ── 6. WAF 200 HTML on the OpenAI path → actionable error ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.contentTypeOf = (String p) => 'text/html';
    g.bodyOf = (String p) => _wafHtml;
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    await _expectWafError(
      client.complete(
        config: _cfg('https://agentrouter.org/v1', 'gpt-6-astra'),
        messages: _messages,
      ),
    );
    await g.close();
  }

  // ── 7. WAF 403 on the Anthropic path → actionable error + 403 ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.statusOf = (String p) => p.endsWith('/messages') ? 403 : 200;
    g.contentTypeOf = (String p) => 'text/html';
    g.bodyOf = (String p) => _wafHtml;
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    try {
      await client.complete(
        config: _cfg('https://agentrouter.org/v1', 'claude-sonnet-4'),
        messages: _messages,
      );
      throw StateError('case7: expected LlmException');
    } on LlmException catch (e) {
      _check(e.statusCode == 403, 'case7: status must stay 403');
      _check(
        e.message.contains('mobile data'),
        'case7: WAF message must be actionable',
      );
    }
    await g.close();
  }

  // ── 8. "Invalid API Key" → deployment-mismatch message ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.statusOf = (String p) => p.endsWith('/chat/completions') ? 401 : 200;
    g.bodyOf = (String p) => 'Invalid API Key!';
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    try {
      await client.complete(
        config: _cfg('https://agentrouter.org/v1', 'gpt-6-astra'),
        messages: _messages,
      );
      throw StateError('case8: expected LlmException');
    } on LlmException catch (e) {
      _check(e.statusCode == 401, 'case8: status must stay 401');
      _check(
        e.message.contains('separate deployments'),
        'case8: mismatch message missing, got: ${e.message}',
      );
    }
    await g.close();
  }

  // ── 9. confirmed protocol cache: second call skips the guess ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.bodyOf = (String p) =>
        p.endsWith('/chat/completions') ? _openAiSse('ok') : '';
    g.contentTypeOf = _sseOrJson;
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    for (var i = 0; i < 2; i++) {
      await client.complete(
        config: _cfg('https://agentrouter.org/v1', 'gpt-6-astra'),
        messages: _messages,
      );
    }
    _check(
      g.hits.every((String p) => p == '/v1/chat/completions'),
      'case9: cache must keep calls on the confirmed path: '
      '${g.hits.join(',')}',
    );
    await g.close();
  }

  // ── 10. base URL without /v1 normalized onto the versioned paths ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.bodyOf = (String p) =>
        p.endsWith('/chat/completions') ? _openAiSse('v1 ok') : '';
    g.contentTypeOf = _sseOrJson;
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    final AssistantTurn turn = await client.complete(
      config: _cfg('https://agentrouter.org', 'gpt-6-astra'),
      messages: _messages,
    );
    _check(turn.content == 'v1 ok', 'case10: turn lost');
    _check(
      httpc.seen.single.path == '/v1/chat/completions',
      'case10: /v1 not appended: ${httpc.seen.single.path}',
    );
    await g.close();
  }

  // ── 11. non-agentrouter host: passthrough, no UA branding ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.bodyOf = (String p) =>
        p.endsWith('/chat/completions') ? _openAiSse('plain') : '';
    g.contentTypeOf = _sseOrJson;
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final AgentRouterLlmClient client = AgentRouterLlmClient(client: httpc);
    final AssistantTurn turn = await client.complete(
      config: _cfg('https://provider.test/v1', 'm'),
      messages: _messages,
    );
    _check(turn.content == 'plain', 'case11: turn lost');
    _check(httpc.seen.length == 1, 'case11: no probe expected');
    _check(
      httpc.seen.single.header('user-agent') != kClaudeCliUa,
      'case11: claude-cli UA must NOT brand other providers',
    );
    await g.close();
  }

  // ── 12. discovery: dual auth + Anthropic-shaped catalog ──
  {
    AgentRouterLlmClient.clearProtocolCache();
    final _Gateway g = await _Gateway.start();
    g.bodyOf = (String p) => jsonEncode(<String, dynamic>{
      'data': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'model',
          'id': 'gpt-6-astra',
          'display_name': 'GPT 6 Astra',
        },
      ],
    });
    final _HostRewriteClient httpc = _HostRewriteClient(Uri.parse(g.base));
    final ModelCatalogClient catalog = ModelCatalogClient(client: httpc);
    final List<RemoteModel> models = await catalog.fetchModels(
      baseUrl: 'https://agentrouter.org/v1',
      apiKey: 'test-key-xyz',
    );
    _check(models.single.id == 'gpt-6-astra', 'case12: catalog parse');
    _check(httpc.seen.single.path == '/v1/models', 'case12: discovery path');
    _check(
      httpc.seen.single.header('x-api-key') == 'test-key-xyz',
      'case12: discovery must send x-api-key',
    );
    _check(
      httpc.seen.single.header('anthropic-version') == kAnthropicVersion,
      'case12: discovery must send anthropic-version',
    );
    _check(
      httpc.seen.single.header('user-agent') == kClaudeCliUa,
      'case12: discovery must send the claude-cli UA',
    );
    await g.close();
  }

  print('agentrouter standalone check: 12/12 mock cases passed.');
  await _liveProbes();
}

/// Opt-in live probes (AGENTROUTER_LIVE=1 + AGENTROUTER_KEY). NEVER
/// asserts success — the apex gateway WAF-challenges datacenter IPs; the
/// probe only REPORTS what the gateway answered so a human can read it.
Future<void> _liveProbes() async {
  if (Platform.environment['AGENTROUTER_LIVE'] != '1') return;
  final String? key = Platform.environment['AGENTROUTER_KEY'];
  print('--- live probes (opt-in) ---');
  if (key == null || key.trim().isEmpty) {
    print('AGENTROUTER_KEY not set; skipping live probes.');
    return;
  }
  final IOClient client = IOClient();
  try {
    final http.Response models = await client.get(
      Uri.parse('https://agentrouter.org/v1/models'),
      headers: <String, String>{
        'Authorization': 'Bearer $key',
        'x-api-key': key,
        'anthropic-version': kAnthropicVersion,
        'User-Agent': kAgentRouterUserAgent,
      },
    );
    print(
      'GET /v1/models → ${models.statusCode}: '
      '${truncateForError(models.body, 160)}',
    );
  } catch (e) {
    print('GET /v1/models → network error: $e');
  }
  try {
    final http.Response chat = await client.post(
      Uri.parse('https://agentrouter.org/v1/chat/completions'),
      headers: <String, String>{
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
        'User-Agent': kAgentRouterUserAgent,
      },
      body: jsonEncode(<String, dynamic>{
        'model': 'gpt-6-astra',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'ping'},
        ],
      }),
    );
    print(
      'POST /v1/chat/completions (gpt-6-astra) → ${chat.statusCode}: '
      '${truncateForError(chat.body, 160)}',
    );
  } catch (e) {
    print('POST /v1/chat/completions → network error: $e');
  } finally {
    client.close();
  }
}

void main() {
  runChecks()
      .then((_) {
        print('standalone check finished OK.');
      })
      .catchError((Object e) {
        print('standalone check FAILED: $e');
        exitCode = 1;
      });
}
