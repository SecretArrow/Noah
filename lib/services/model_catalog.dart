import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'agentrouter_client.dart';

/// One model entry from a provider's `GET /models` catalog.
class RemoteModel {
  const RemoteModel({
    required this.id,
    required this.name,
    this.contextLength,
    this.supportsTools = false,
    this.isFree = false,
  });

  final String id;

  /// Human-readable name; falls back to [id] when the provider does not
  /// supply one.
  final String name;

  /// Context window in tokens, when advertised.
  final int? contextLength;

  /// Whether the provider advertises tool/function-calling support.
  final bool supportsTools;

  /// Whether both prompt and completion pricing are zero.
  final bool isFree;

  /// Vendor prefix before the first `/` (e.g. `z-ai` in `z-ai/glm-4.6`),
  /// or an empty string for flat ids.
  String get vendor => id.contains('/') ? id.substring(0, id.indexOf('/')) : '';
}

/// Raised when the model catalog cannot be fetched or parsed.
class ModelCatalogException implements Exception {
  ModelCatalogException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Fetches the model catalog from any OpenAI-compatible provider
/// (`GET {baseUrl}/models`): OpenRouter, InferHub, Z.AI, OpenAI, DeepSeek,
/// Groq, ...
///
/// Parsing is deliberately defensive: providers ship different enrichment
/// fields on top of the plain OpenAI shape, and unknown shapes must degrade
/// to a simple list of ids instead of crashing the picker.
class ModelCatalogClient {
  ModelCatalogClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<RemoteModel>> fetchModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    final Uri url = Uri.parse(
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models',
    );
    final http.Request request = http.Request('GET', url)
      ..headers['Accept'] = 'application/json';
    // OpenRouter lists models publicly; InferHub and most others require the
    // key. Only send the header when we actually have one.
    if (apiKey.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    }
    // AgentRouter accepts BOTH auth headers and expects its Anthropic-flavor
    // branding on every request (discovery hits the same gateway as chat).
    final String? host = hostOf(baseUrl);
    final bool agentRouter = host != null && isAgentRouterHost(host);
    if (agentRouter) {
      if (apiKey.trim().isNotEmpty) {
        request.headers['x-api-key'] = apiKey.trim();
      }
      request.headers['anthropic-version'] = kAnthropicVersion;
      request.headers['User-Agent'] = kAgentRouterUserAgent;
    }

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_timeout);
    } on TimeoutException {
      throw ModelCatalogException('Request timed out.');
    } catch (e) {
      throw ModelCatalogException('Network error: $e');
    }

    final String body = await response.stream.bytesToString();
    if (response.statusCode == 401 || response.statusCode == 403) {
      if (agentRouter) {
        // The gateway answers auth failures with its own strings; WAF
        // challenges and key/deployment mismatches deserve actionable
        // messages instead of a bare "Unauthorized".
        if (looksLikeWafChallenge(body)) {
          throw ModelCatalogException(
            agentRouterWafMessage(),
            statusCode: response.statusCode,
          );
        }
        if (looksLikeInvalidApiKey(body)) {
          throw ModelCatalogException(
            agentRouterInvalidKeyMessage(),
            statusCode: response.statusCode,
          );
        }
      }
      throw ModelCatalogException(
        'Unauthorized — check the API key for this provider.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      if (agentRouter && looksLikeWafChallenge(body)) {
        throw ModelCatalogException(
          agentRouterWafMessage(),
          statusCode: response.statusCode,
        );
      }
      throw ModelCatalogException(
        'HTTP ${response.statusCode}: ${_truncate(body)}',
        statusCode: response.statusCode,
      );
    }

    if (agentRouter) {
      // A 200 with an Aliyun WAF page (datacenter IP) parses as garbage —
      // surface the actionable message instead of a cryptic format error.
      if (looksLikeWafChallenge(body)) {
        throw ModelCatalogException(agentRouterWafMessage());
      }
      try {
        return parseAgentRouterCatalog(body);
      } on FormatException catch (e) {
        throw ModelCatalogException(
          'Unknown response format: ${_truncate(body)} ($e)',
        );
      }
    }
    return parseCatalog(body);
  }

  /// Parses a catalog payload. Kept public for tests. Signature must stay
  /// `parseCatalog(String)` — subclasses in existing tests override it.
  List<RemoteModel> parseCatalog(String body) =>
      _parseCatalogBody(body, agentRouter: false);

  /// Anthropic-flavor parsing (AgentRouter): also accepts model entries of
  /// the shape `{id, display_name}` — `id` is used, falling back to
  /// `display_name`. The default [parseCatalog] stays byte-for-byte.
  /// Deliberately STATIC: `implements ModelCatalogClient` test doubles
  /// must not be forced to implement it.
  static List<RemoteModel> parseAgentRouterCatalog(String body) =>
      _parseCatalogBody(body, agentRouter: true);

  static List<RemoteModel> _parseCatalogBody(
    String body, {
    required bool agentRouter,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      throw ModelCatalogException('Malformed JSON: $e');
    }

    List<dynamic>? items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map<String, dynamic>) {
      // `data` (OpenAI), `models` (some gateways), `result` (rare).
      items =
          (decoded['data'] ?? decoded['models'] ?? decoded['result'])
              as List<dynamic>?;
    }
    if (items == null) {
      throw ModelCatalogException('Unexpected catalog format.');
    }

    final List<RemoteModel> models = <RemoteModel>[];
    for (final Object? raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      final RemoteModel? model = _parseModel(raw, agentRouter: agentRouter);
      if (model != null) models.add(model);
    }
    return models;
  }

  static RemoteModel? _parseModel(
    Map<String, dynamic> json, {
    required bool agentRouter,
  }) {
    // `id` is the OpenAI standard; tolerate `model`/`name` aliases. The
    // Anthropic-style catalog (AgentRouter) also allows `display_name`.
    final Object? rawId = agentRouter
        ? (json['id'] ?? json['display_name'] ?? json['model'] ?? json['name'])
        : (json['id'] ?? json['model'] ?? json['name']);
    final String id = rawId?.toString() ?? '';
    if (id.trim().isEmpty) return null;

    final Object? rawName = agentRouter
        ? (json['name'] ?? json['display_name'])
        : json['name'];
    final String name = (rawName is String && rawName.trim().isNotEmpty)
        ? rawName.trim()
        : id;

    return RemoteModel(
      id: id,
      name: name,
      contextLength: _asInt(json['context_length'] ?? json['context_size']),
      supportsTools: _detectTools(json),
      isFree: _detectFree(json['pricing']),
    );
  }

  /// Tool support signals across providers:
  /// * OpenRouter: `supported_parameters` contains `tools`.
  /// * Generic: `capabilities.tools == true`, `tools == true`,
  ///   `function_calling == true`.
  static bool _detectTools(Map<String, dynamic> json) {
    final Object? params = json['supported_parameters'];
    if (params is List) {
      return params.any((Object? p) => p?.toString() == 'tools');
    }
    final Object? capabilities = json['capabilities'];
    if (capabilities is Map<String, dynamic>) {
      return capabilities['tools'] == true;
    }
    return json['tools'] == true || json['function_calling'] == true;
  }

  /// Free when both prompt and completion price are zero
  /// (OpenRouter ships prices as strings, others may use numbers).
  static bool _detectFree(Object? pricing) {
    if (pricing is! Map<String, dynamic>) return false;
    final double? prompt = _asDouble(pricing['prompt']);
    final double? completion = _asDouble(pricing['completion']);
    if (prompt == null || completion == null) return false;
    return prompt <= 0 && completion <= 0;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  String _truncate(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}...';

  static const Duration _timeout = Duration(seconds: 20);
}
