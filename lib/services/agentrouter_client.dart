import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'llm_client.dart';
import 'wire_transports.dart';

export 'wire_transports.dart'
    show
        kAnthropicVersion,
        kAgentRouterMaxTokens,
        buildAnthropicRequestBody,
        parseAnthropicMessage,
        anthropicErrorMessage,
        truncateForError,
        needsResponsesApi,
        responsesEngineHint;

/// AgentRouter (https://agentrouter.org) transport.
///
/// The gateway serves THREE wire protocols on the version-segmented base
/// (`…/v1/messages` Anthropic Messages, `…/v1/chat/completions` OpenAI
/// Chat Completions and `…/v1/responses` OpenAI Responses). Which one
/// speaks FIRST is decided per model family — the room-browser-proven
/// recipe: Claude models speak Anthropic Messages natively, GPT and every
/// other family speaks OpenAI-compatible ([prefersAnthropic]). A 404/405
/// on the first-choice path still falls back ONCE to the Anthropic
/// protocol for single-protocol deployments, a 400 whose body names
/// `/v1/responses` ("model does not support /v1/chat/completions") falls
/// back ONCE to the Responses protocol, and the confirmed protocol is
/// cached per (normalized base URL, MODEL — not family, so a Responses-
/// only model never poisons a Chat Completions model on the same base)
/// so later calls skip the guess entirely.
///
/// A provider preset can also PIN the wire protocol explicitly
/// ([LlmEngine.anthropic] / [LlmEngine.openai] /
/// [LlmEngine.openaiResponses]): pinned engines never fall back silently
/// — a wrong pin surfaces the provider error plus the engine hint.
///
/// [AgentRouterLlmClient] also carries the claude-cli User-Agent the
/// gateway REQUIRES on every request (missing it yields 401
/// unauthorized_client_error / WAF challenges), sends dual auth headers
/// (x-api-key + Bearer) on the Anthropic path, and translates three gateway
/// failure modes into actionable messages: Aliyun WAF bot-challenge pages
/// ("switch to mobile data"), the "Invalid API Key" deployment mismatch
/// (apex vs co. consoles have separate key databases) and the
/// Responses-only model mismatch ("set the Engine to OpenAI Responses").
///
/// Everything outside agentrouter.org (and its subdomains) goes through
/// `super.complete()` unchanged — zero behavior change for OpenRouter,
/// Z.AI, OpenAI, DeepSeek, Groq and custom providers.

/// Exact User-Agent every AgentRouter request must carry — the Anthropic
/// transport AND the OpenAI-compatible fallback alike.
const String kAgentRouterUserAgent = 'claude-cli/1.0.60 (external, cli)';

const String _agentRouterDomain = 'agentrouter.org';

/// Returns the host of [baseUrl], or null when it cannot be parsed (or is
/// empty). Pure function — unit-tested directly.
String? hostOf(String baseUrl) {
  final Uri? uri = Uri.tryParse(baseUrl.trim());
  if (uri == null) return null;
  final String host = uri.host.trim();
  return host.isEmpty ? null : host;
}

/// Strict anti-typosquatting hostname check: ONLY `agentrouter.org` and
/// any-depth `*.agentrouter.org` subdomains qualify. Rejects look-alikes
/// (`evil-agentrouter.org`, `agentrouter.org.evil.com`,
/// `agentrouter.community`, `agentrouter.orgx`), hosts with underscores,
/// IP literals, empty hosts, case noise and trailing dots. Pure function.
bool isAgentRouterHost(String host) {
  final String h = host.trim().toLowerCase();
  if (h.isEmpty || h.contains('_')) return false;
  // An empty label rejects '' and hosts with a trailing/leading/doubled
  // dot ('agentrouter.org.', '.agentrouter.org', 'a..b').
  for (final String label in h.split('.')) {
    if (label.isEmpty) return false;
  }
  return h == _agentRouterDomain || h.endsWith('.$_agentRouterDomain');
}

/// Normalized base URL used as the protocol-probe cache key (and for
/// building `{base}/messages` / `{base}/chat/completions` /
/// `{base}/responses` URLs).
String normalizeBaseUrl(String baseUrl) =>
    baseUrl.replaceAll(RegExp(r'/+$'), '');

/// AgentRouter's official paths live under the version segment
/// (`…/v1/chat/completions`, `…/v1/messages`, `…/v1/responses`). Base URLs
/// without any version segment get `/v1` appended; URLs that already
/// carry one pass through untouched. Pure function — unit-tested directly.
String normalizeAgentRouterBase(String baseUrl) {
  final String trimmed = normalizeBaseUrl(baseUrl.trim());
  final Uri? uri = Uri.tryParse(trimmed);
  final bool hasVersionSegment = <String>[
    for (final String s in uri?.pathSegments ?? const <String>[])
      if (s.trim().isNotEmpty) s,
  ].any((String s) => RegExp(r'^v\d+$').hasMatch(s.toLowerCase()));
  return hasVersionSegment ? trimmed : '$trimmed/v1';
}

/// Room-browser-proven per-model routing: the gateway serves all three
/// wire protocols, and the model family has a natural first choice —
/// Claude models speak Anthropic Messages natively, GPT and every other
/// family speaks OpenAI-compatible. A wrong first guess costs one dead
/// request (or a WAF page on guarded deployments), so the family decides.
/// Pure function — unit-tested directly.
bool prefersAnthropic(String model) =>
    model.trim().toLowerCase().startsWith('claude');

/// Detects Aliyun WAF bot-challenge pages (slider captcha / JS challenge)
/// served instead of API responses to datacenter IPs. Runs on response
/// bodies and on error messages that embed a body snippet — the markers
/// (`acw_tc`, `acw_sc__v2`, captcha scripts) live in the first bytes of
/// the page. Pure function — unit-tested directly.
bool looksLikeWafChallenge(String body) {
  final String s = body.toLowerCase();
  if (s.contains('acw_tc') ||
      s.contains('acw_sc') ||
      s.contains('aliyunwaf') ||
      s.contains('aliyun waf') ||
      s.contains('anti-bot') ||
      s.contains('captcha') ||
      (s.contains('aliyun') && (s.contains('waf') || s.contains('slider')))) {
    return true;
  }
  // v1.49.6: outright DENY pages. Aliyun WAF serves an HTML block page
  // ("... has been blocked ...") — or a JSON error naming the firewall —
  // instead of a JS challenge when the client is outright rejected. The
  // word "blocked" alone is too generic (content-policy messages also use
  // it), so require page/context corroboration: an HTML document or an
  // explicit firewall/protection mention.
  if (!s.contains('blocked')) return false;
  final bool htmlPage = s.contains('<html') || s.contains('<!doctype');
  final bool firewallWord =
      s.contains('waf') ||
      s.contains('firewall') ||
      s.contains('aliyun') ||
      s.contains('protection');
  return htmlPage || firewallWord;
}

/// First bytes of [agentRouterWafMessage] — the retry detector matches
/// the TRANSLATED message too (the challenge markers are gone once the
/// failure has been rewritten into actionable guidance).
const String _wafGuidancePrefix =
    'AgentRouter is bot-challenging this connection';

/// Actionable guidance for [looksLikeWafChallenge]: the fix is a network
/// switch (phone networks pass, datacenter IPs are challenged), never a
/// key or URL change.
String agentRouterWafMessage() =>
    '$_wafGuidancePrefix (Aliyun WAF). The '
    'gateway blocks datacenter IPs but normally allows phone networks — '
    'switch to mobile data (or another WiFi) and retry. No API key or '
    'URL change is needed.';

/// True when [error] is an Aliyun WAF challenge/block failure — the ONE
/// failure mode worth a transparent in-flight retry (v1.49.6): the
/// challenge response plants WAF cookies which the retry replays, and
/// that is frequently what converts a challenged request into a pass.
bool isAgentRouterWafBlock(LlmException error) =>
    looksLikeWafChallenge(error.message) ||
    error.message.startsWith(_wafGuidancePrefix);

/// The gateway's own rejection string ("Invalid API Key!"). agentrouter.org
/// and co.agentrouter.org run SEPARATE key databases, so a valid-looking
/// key from the wrong console is rejected exactly like a dead one.
bool looksLikeInvalidApiKey(String body) =>
    body.toLowerCase().contains('invalid api key');

/// Actionable guidance for [looksLikeInvalidApiKey].
String agentRouterInvalidKeyMessage() =>
    'AgentRouter rejected this API key ("Invalid API Key"). agentrouter.org '
    'and co.agentrouter.org are separate deployments with separate key '
    'databases — generate the key on the same host you are calling and '
    'check that it is still active.';

/// Confirmed wire protocol per (normalized base URL, model).
enum _WireProtocol { anthropic, openAi, openAiResponses }

/// Streaming client for AgentRouter: per-model protocol routing with
/// one-shot fallbacks and the pinned per-provider engine override. See
/// the library doc comment.
class AgentRouterLlmClient extends LlmClient {
  // `client` must be forwarded to the super constructor AND mirrored into
  // `_injected` below — one parameter, two destinations, so it cannot be a
  // plain super parameter.
  // ignore: use_super_parameters
  AgentRouterLlmClient({http.Client? client})
    : _injected = client,
      super(
        client: client,
        extraHeaders: _headersForUrl,
        // v1.49.6: harvest WAF cookies from EVERY response the base
        // transport sees (the OpenAI-compatible path included) so the
        // anti-block retry can replay them.
        onResponseHeaders: _harvestWafCookies,
      );

  /// Mirrors the base class's private injected-transport field so the
  /// Anthropic/Responses paths reuse the same test double the OpenAI path
  /// gets.
  final http.Client? _injected;

  /// Confirmed wire protocol per `base|model` key: an entry means the
  /// gateway answered a REAL turn through that protocol — later calls for
  /// the same MODEL skip the first-choice guessing entirely. Keyed per
  /// model (not per family) since v1.49.4: a Responses-only model
  /// (gpt-6.1-sol) and a Chat Completions model (gpt-6-astra) share the
  /// family prefix but not the protocol.
  static final Map<String, _WireProtocol> _confirmedProtocol =
      <String, _WireProtocol>{};

  static String _protocolCacheKey(String base, String model) =>
      '$base|${model.trim()}';

  /// Test hook: clears the confirmed-protocol cache.
  static void clearProtocolCache() => _confirmedProtocol.clear();

  /// v1.49.6 — Aliyun WAF cookie jar, keyed by host. Challenge responses
  /// plant `acw_tc` / `acw_sc__v2` cookies; replaying them on the next
  /// request is what frequently converts a challenged/blocked connection
  /// into a pass. Harvested from every AgentRouter response (headers
  /// observer on the base transport, explicit calls on the wrapper-owned
  /// transports); attached to every outgoing AgentRouter request.
  static final Map<String, Map<String, String>> _wafCookies =
      <String, Map<String, String>>{};

  static final RegExp _wafCookiePattern = RegExp(
    r'(acw_tc|acw_sc__v[23]|cdn_sec_tc|aliyungf[_ ]tc)=([^;,\s]+)',
    caseSensitive: false,
  );

  /// Harvests WAF cookies from a response's headers (the raw `set-cookie`
  /// value — dart:io merges duplicates with commas, which the regex
  /// handles). Non-agentrouter hosts are ignored; failures never throw.
  static void _harvestWafCookies(Uri url, Map<String, String> headers) {
    if (!isAgentRouterHost(url.host)) return;
    final String? setCookie = headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return;
    try {
      final Map<String, String> jar = _wafCookies.putIfAbsent(
        url.host,
        () => <String, String>{},
      );
      for (final RegExpMatch match in _wafCookiePattern.allMatches(setCookie)) {
        final String name = match.group(1)!.toLowerCase().replaceAll(' ', '_');
        jar[name] = match.group(2)!;
      }
    } catch (_) {
      // Cookie bookkeeping must never break the stream.
    }
  }

  /// The harvested cookies for [url]'s host as a `Cookie` header value,
  /// or null when the jar is empty for that host.
  static String? _wafCookieHeader(Uri url) {
    final Map<String, String>? jar = _wafCookies[url.host];
    if (jar == null || jar.isEmpty) return null;
    return jar.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
  }

  /// Test hook: clears the WAF cookie jar.
  static void clearWafCookies() => _wafCookies.clear();

  /// Test hook: read-only view of the jar (inspect in tests).
  static Map<String, Map<String, String>> get wafCookiesForTesting =>
      _wafCookies;

  /// Test hook: the anti-block retry delay (unit tests set [Duration.zero]
  /// to keep them fast).
  static Duration wafRetryDelay = const Duration(milliseconds: 700);

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    // Validated on EVERY call — special treatment only when the host of
    // the resolved base URL strictly passes [isAgentRouterHost].
    final String? host = hostOf(config.baseUrl);
    if (host == null || !isAgentRouterHost(host)) {
      return super.complete(
        config: config,
        messages: messages,
        tools: tools,
        onDelta: onDelta,
        shouldAbort: shouldAbort,
        cancelKey: cancelKey,
      );
    }
    // v1.49.6 anti-block: watch the delta stream so a MID-STREAM failure
    // (deltas already surfaced to the chat) is never retried — only
    // failures that happened before ANY output are.
    bool streamed = false;
    final void Function(String delta)? watched = onDelta == null
        ? null
        : (String delta) {
            streamed = true;
            onDelta(delta);
          };
    try {
      return await _completeAgentRouter(
        config: config,
        messages: messages,
        tools: tools,
        onDelta: watched,
        shouldAbort: shouldAbort,
        cancelKey: cancelKey,
      );
    } on LlmException catch (e) {
      // One transparent retry for WAF challenge/block pages: the first
      // attempt planted the challenge cookies in the jar, so attempt 2
      // goes out WITH them — the classic Aliyun acw_tc pass-through.
      // Everything else (auth errors, 400s, aborts, mid-stream failures)
      // surfaces immediately.
      if (!isAgentRouterWafBlock(e) ||
          streamed ||
          (shouldAbort?.call() ?? false)) {
        rethrow;
      }
      await Future<void>.delayed(wafRetryDelay);
      return _completeAgentRouter(
        config: config,
        messages: messages,
        tools: tools,
        onDelta: watched,
        shouldAbort: shouldAbort,
        cancelKey: cancelKey,
      );
    }
  }

  /// The v1.49.4 protocol dispatch (normalization + engine switch +
  /// confirmed-protocol cache + family first choice) — extracted verbatim
  /// so [complete] can wrap it with the anti-block retry.
  Future<AssistantTurn> _completeAgentRouter({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    final String base = normalizeAgentRouterBase(config.baseUrl);
    // All official paths are served under the version segment; hand the
    // normalized base to every transport.
    final LlmConfig normalized = LlmConfig(
      baseUrl: base,
      apiKey: config.apiKey,
      model: config.model,
      maxTokens: config.maxTokens,
      engine: config.engine,
    );
    final String cacheKey = _protocolCacheKey(base, config.model);

    // Pinned engine: exactly one transport, never a silent fallback.
    switch (config.engine) {
      case LlmEngine.anthropic:
        return _completeAnthropic(
          config: normalized,
          base: base,
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          shouldAbort: shouldAbort,
          cancelKey: cancelKey,
          allowFallback: false,
          cacheKey: cacheKey,
        );
      case LlmEngine.openai:
        return _completeOpenAi(
          config: normalized,
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          shouldAbort: shouldAbort,
          cancelKey: cancelKey,
          allowFallback: false,
          responsesHint: false,
          cacheKey: cacheKey,
        );
      case LlmEngine.openaiResponses:
        return _completeResponses(
          config: normalized,
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          shouldAbort: shouldAbort,
          cancelKey: cancelKey,
          cacheKey: cacheKey,
        );
      case LlmEngine.auto:
        break;
    }

    // Auto: confirmed protocol short-circuits the guess; otherwise the
    // model family picks the first choice.
    final _WireProtocol? confirmed = _confirmedProtocol[cacheKey];
    switch (confirmed) {
      case _WireProtocol.openAi:
        return _completeOpenAi(
          config: normalized,
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          shouldAbort: shouldAbort,
          cancelKey: cancelKey,
          allowFallback: false,
          responsesHint: true,
          cacheKey: cacheKey,
        );
      case _WireProtocol.anthropic:
        return _completeAnthropic(
          config: normalized,
          base: base,
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          shouldAbort: shouldAbort,
          cancelKey: cancelKey,
          allowFallback: false,
          cacheKey: cacheKey,
        );
      case _WireProtocol.openAiResponses:
        return _completeResponses(
          config: normalized,
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          shouldAbort: shouldAbort,
          cancelKey: cancelKey,
          cacheKey: cacheKey,
        );
      case null:
        break;
    }
    return prefersAnthropic(config.model)
        ? _completeAnthropic(
            config: normalized,
            base: base,
            messages: messages,
            tools: tools,
            onDelta: onDelta,
            shouldAbort: shouldAbort,
            cancelKey: cancelKey,
            allowFallback: true,
            cacheKey: cacheKey,
          )
        : _completeOpenAi(
            config: normalized,
            messages: messages,
            tools: tools,
            onDelta: onDelta,
            shouldAbort: shouldAbort,
            cancelKey: cancelKey,
            allowFallback: true,
            responsesHint: true,
            cacheKey: cacheKey,
          );
  }

  /// Brands every agentrouter-host request of the OpenAI-compatible
  /// fallback path with the required User-Agent AND replays harvested WAF
  /// cookies (v1.49.6). Plain LlmClient instances and other hosts get no
  /// extra headers, keeping the base behavior untouched.
  static Map<String, String> _headersForUrl(Uri url) {
    if (!isAgentRouterHost(url.host)) {
      return const <String, String>{};
    }
    return <String, String>{
      'User-Agent': kAgentRouterUserAgent,
      // v1.49.6: carrying the challenge cookie (`acw_tc` et al.) is what
      // turns a challenged connection into a pass on the retry.
      if (_wafCookieHeader(url) != null) 'Cookie': _wafCookieHeader(url)!,
    };
  }

  /// Translates the two gateway failure modes embedded in error messages
  /// into actionable guidance; passes everything else through.
  LlmException _translate(LlmException e) {
    if (looksLikeWafChallenge(e.message)) {
      return LlmException(agentRouterWafMessage(), statusCode: e.statusCode);
    }
    if (looksLikeInvalidApiKey(e.message)) {
      return LlmException(
        agentRouterInvalidKeyMessage(),
        statusCode: e.statusCode,
      );
    }
    return e;
  }

  /// The OpenAI-compatible path IS the base transport — same request
  /// building, SSE parsing, retry semantics — with the AgentRouter
  /// User-Agent merged in via the constructor-injected header hook. A
  /// successful turn confirms the protocol for this (base, model) pair;
  /// 404/405 falls back once to the Anthropic path when allowed; a 400
  /// whose body names `/v1/responses` falls back once to the Responses
  /// path (auto mode) or fails with the engine hint (pinned OpenAI);
  /// WAF pages and key/deployment mismatches become actionable errors.
  Future<AssistantTurn> _completeOpenAi({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
    required bool allowFallback,
    required bool responsesHint,
    required String cacheKey,
  }) async {
    try {
      // Pinned to `openai` for THIS call: the base transport must stay on
      // Chat Completions — its auto-engine responses-hint retry would
      // otherwise answer the 400 through the PLAIN Responses transport
      // (no claude-cli User-Agent, no WAF translation) and cache the
      // wrong protocol. Cross-protocol fallbacks belong to this wrapper.
      final LlmConfig pinned = LlmConfig(
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        model: config.model,
        maxTokens: config.maxTokens,
        engine: LlmEngine.openai,
      );
      final AssistantTurn turn = await super.complete(
        config: pinned,
        messages: messages,
        tools: tools,
        onDelta: onDelta,
        shouldAbort: shouldAbort,
        cancelKey: cancelKey,
      );
      _confirmedProtocol[cacheKey] = _WireProtocol.openAi;
      return turn;
    } on LlmException catch (e) {
      // Non-200 errors embed the body snippet; parse failures embed it
      // too (the base transport includes the raw body since v1.49.3) —
      // which is exactly what makes WAF/invalid-key detection possible
      // on this path.
      if (looksLikeWafChallenge(e.message)) {
        throw LlmException(agentRouterWafMessage(), statusCode: e.statusCode);
      }
      if (looksLikeInvalidApiKey(e.message)) {
        throw LlmException(
          agentRouterInvalidKeyMessage(),
          statusCode: e.statusCode,
        );
      }
      if (e.statusCode == 400 && needsResponsesApi(e.message)) {
        if (responsesHint) {
          // Auto mode: the gateway itself says which protocol serves this
          // model — one deterministic extra hop (Responses never falls
          // back further, so the chain always terminates).
          return _completeResponses(
            config: config,
            messages: messages,
            tools: tools,
            onDelta: onDelta,
            shouldAbort: shouldAbort,
            cancelKey: cancelKey,
            cacheKey: cacheKey,
          );
        }
        throw LlmException(
          '${e.message} ${responsesEngineHint()}',
          statusCode: e.statusCode,
        );
      }
      if (allowFallback && (e.statusCode == 404 || e.statusCode == 405)) {
        return _completeAnthropic(
          config: config,
          base: normalizeBaseUrl(config.baseUrl),
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          shouldAbort: shouldAbort,
          cancelKey: cancelKey,
          allowFallback: false,
          cacheKey: cacheKey,
        );
      }
      rethrow;
    }
  }

  Future<AssistantTurn> _completeAnthropic({
    required LlmConfig config,
    required String base,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
    required bool allowFallback,
    required String cacheKey,
  }) async {
    if (shouldAbort?.call() ?? false) {
      throw const LlmAbortedException('');
    }
    final Uri url = Uri.parse('$base/messages');
    final Map<String, dynamic> body = buildAnthropicRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );

    final http.Client callClient = _injected ?? http.Client();
    final bool ownsClient = _injected == null;
    // Same per-run registry as the base transport: force-stop hard-closes
    // this request exactly like an OpenAI-compatible one.
    if (cancelKey != null) LlmClient.registerLiveStream(cancelKey, callClient);
    try {
      final http.StreamedResponse response;
      try {
        response = await callClient.send(
          await _buildAnthropicRequest(config, url, body),
        );
      } catch (e) {
        // Transport errors must NOT silently fall back: re-sending the
        // same turn over a second protocol after a real network failure
        // risks duplicate outputs. Surface it like the base client does.
        throw LlmException('Could not connect to provider: $e');
      }
      // v1.49.6: WAF cookies from ANY response (challenge pages included)
      // feed the jar so the anti-block retry — and every later request —
      // replays them.
      _harvestWafCookies(url, response.headers);

      if (response.statusCode == 404 || response.statusCode == 405) {
        // No /messages endpoint on this base: OpenAI-compatible gateway.
        if (allowFallback) {
          // await — the finally below must run AFTER the fallback turn is
          // fully consumed, not when its Future is merely returned.
          return await _completeOpenAi(
            config: config,
            messages: messages,
            tools: tools,
            onDelta: onDelta,
            shouldAbort: shouldAbort,
            cancelKey: cancelKey,
            allowFallback: false,
            responsesHint: true,
            cacheKey: cacheKey,
          );
        }
        // The confirmed route suddenly 404s — surface a hard error. The
        // two-way fallback is strictly one-shot: never flip back and
        // forth (guard anti-loop).
        throw LlmException(
          'HTTP ${response.statusCode}: /messages unavailable on $base',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        final String raw = await response.stream.bytesToString();
        // Auth/API errors keep the provider's own message — these NEVER
        // trigger a protocol fallback (only 404/405 above may).
        throw agentRouterHttpError(raw, response.statusCode);
      }

      final String contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      if (!contentType.contains('text/event-stream')) {
        final String raw = await response.stream.bytesToString();
        if (looksLikeWafChallenge(raw)) {
          throw LlmException(agentRouterWafMessage());
        }
        if (looksLikeInvalidApiKey(raw)) {
          throw LlmException(agentRouterInvalidKeyMessage());
        }
        final Object? decoded = tryDecodeJson(raw);
        if (decoded is Map<String, dynamic> && decoded['choices'] is List) {
          // OpenAI-shaped answer on the Anthropic endpoint: consume THIS
          // response (no re-send — no duplicate output) and remember the
          // protocol for the following calls.
          _confirmedProtocol[cacheKey] = _WireProtocol.openAi;
          return _parseOpenAiMessage(raw);
        }
        _confirmedProtocol[cacheKey] = _WireProtocol.anthropic;
        return parseAnthropicMessage(raw);
      }

      _confirmedProtocol[cacheKey] = _WireProtocol.anthropic;
      try {
        return await consumeAnthropicStream(
          response.stream,
          onDelta,
          shouldAbort,
        );
      } on LlmException catch (e) {
        throw _translate(e);
      }
    } finally {
      if (cancelKey != null) {
        LlmClient.unregisterLiveStream(cancelKey, callClient);
      }
      if (ownsClient) {
        try {
          callClient.close();
        } catch (_) {
          // Never let transport cleanup mask the actual result.
        }
      }
    }
  }

  /// The Responses-protocol path (`POST {base}/responses`, OpenAI
  /// Responses API as relayed by new-api gateways). Never falls back:
  /// reached through a pinned engine, a confirmed-protocol cache hit or
  /// the one-shot Responses hint — so a dead endpoint surfaces as a hard
  /// error instead of a protocol ping-pong.
  Future<AssistantTurn> _completeResponses({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
    required String cacheKey,
  }) async {
    if (shouldAbort?.call() ?? false) {
      throw const LlmAbortedException('');
    }
    final String base = normalizeBaseUrl(config.baseUrl);
    final Uri url = Uri.parse('$base/responses');
    final Map<String, dynamic> body = buildResponsesRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );

    final http.Client callClient = _injected ?? http.Client();
    final bool ownsClient = _injected == null;
    if (cancelKey != null) LlmClient.registerLiveStream(cancelKey, callClient);
    try {
      final http.StreamedResponse response;
      try {
        response = await callClient.send(
          await _buildResponsesRequest(config, url, body),
        );
      } catch (e) {
        throw LlmException('Could not connect to provider: $e');
      }
      // v1.49.6: harvest WAF cookies — same as the Anthropic path.
      _harvestWafCookies(url, response.headers);

      if (response.statusCode == 404 || response.statusCode == 405) {
        throw LlmException(
          'HTTP ${response.statusCode}: /responses unavailable on $base',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode != 200) {
        final String raw = await response.stream.bytesToString();
        throw agentRouterHttpError(raw, response.statusCode);
      }

      final String contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      if (!contentType.contains('text/event-stream')) {
        final String raw = await response.stream.bytesToString();
        if (looksLikeWafChallenge(raw)) {
          throw LlmException(agentRouterWafMessage());
        }
        if (looksLikeInvalidApiKey(raw)) {
          throw LlmException(agentRouterInvalidKeyMessage());
        }
        _confirmedProtocol[cacheKey] = _WireProtocol.openAiResponses;
        return parseResponsesMessage(raw);
      }

      _confirmedProtocol[cacheKey] = _WireProtocol.openAiResponses;
      try {
        return await consumeResponsesStream(
          response.stream,
          onDelta,
          shouldAbort,
        );
      } on LlmException catch (e) {
        throw _translate(e);
      }
    } finally {
      if (cancelKey != null) {
        LlmClient.unregisterLiveStream(cancelKey, callClient);
      }
      if (ownsClient) {
        try {
          callClient.close();
        } catch (_) {
          // Never let transport cleanup mask the actual result.
        }
      }
    }
  }

  Future<http.Request> _buildAnthropicRequest(
    LlmConfig config,
    Uri url,
    Map<String, dynamic> body,
  ) async {
    final http.Request request = http.Request('POST', url)
      ..headers['x-api-key'] = config.apiKey
      ..headers['Authorization'] = 'Bearer ${config.apiKey}'
      ..headers['anthropic-version'] = kAnthropicVersion
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..headers['User-Agent'] = kAgentRouterUserAgent;
    // v1.49.6: replay harvested WAF cookies when the jar has any.
    final String? cookie = _wafCookieHeader(url);
    if (cookie != null) request.headers['Cookie'] = cookie;
    // Encoded OFF the UI isolate — same rationale as the base transport.
    request.body = await encodeBodyOffIsolate(body);
    return request;
  }

  Future<http.Request> _buildResponsesRequest(
    LlmConfig config,
    Uri url,
    Map<String, dynamic> body,
  ) async {
    final http.Request request = http.Request('POST', url)
      // Dual-auth parity with the Anthropic path: the gateway accepts
      // either credential header on every version-segmented endpoint.
      ..headers['x-api-key'] = config.apiKey
      ..headers['Authorization'] = 'Bearer ${config.apiKey}'
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..headers['User-Agent'] = kAgentRouterUserAgent;
    final String? cookie = _wafCookieHeader(url);
    if (cookie != null) request.headers['Cookie'] = cookie;
    request.body = await encodeBodyOffIsolate(body);
    return request;
  }

  /// OpenAI-shaped JSON that arrived on the Anthropic endpoint — parsed
  /// exactly like the base transport's non-streaming parser would.
  AssistantTurn _parseOpenAiMessage(String raw) {
    final Object? decoded = tryDecodeJson(raw);
    if (decoded is! Map<String, dynamic>) {
      throw LlmException('Unknown response format: ${truncateForError(raw)}');
    }
    final Object? choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final Object? first = choices.first;
      if (first is Map<String, dynamic>) {
        final Object? message = first['message'];
        if (message is Map<String, dynamic>) {
          return AssistantTurn(
            content: message['content']?.toString() ?? '',
            toolCalls: _parseFullOpenAiToolCalls(message['tool_calls']),
            usage: TokenUsage.fromJson(decoded['usage']),
          );
        }
      }
    }
    throw LlmException('Unknown response format: ${truncateForError(raw)}');
  }

  List<ToolCallRequest> _parseFullOpenAiToolCalls(Object? rawToolCalls) {
    if (rawToolCalls is! List) return const <ToolCallRequest>[];
    final List<ToolCallRequest> out = <ToolCallRequest>[];
    for (final Object? raw in rawToolCalls) {
      if (raw is! Map<String, dynamic>) continue;
      final Object? function = raw['function'];
      if (function is! Map<String, dynamic>) continue;
      final Object? name = function['name'];
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
}

/// Non-200 on an AgentRouter path: WAF challenges and key/deployment
/// mismatches become actionable errors; everything else keeps the
/// provider's own error text (Anthropic-shaped payloads are unwrapped).
LlmException agentRouterHttpError(String raw, int statusCode) {
  if (looksLikeWafChallenge(raw)) {
    return LlmException(agentRouterWafMessage(), statusCode: statusCode);
  }
  if (looksLikeInvalidApiKey(raw)) {
    return LlmException(agentRouterInvalidKeyMessage(), statusCode: statusCode);
  }
  return LlmException(
    'HTTP $statusCode: ${anthropicErrorMessage(raw)}',
    statusCode: statusCode,
  );
}
