import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/model_catalog.dart';

void main() {
  group('ModelCatalogClient.parseCatalog', () {
    final ModelCatalogClient client = ModelCatalogClient();

    test('parses OpenRouter-style payload with pricing and tools', () {
      const String body = '''
{
  "data": [
    {
      "id": "z-ai/glm-4.6",
      "name": "Z.AI: GLM 4.6",
      "context_length": 200000,
      "supported_parameters": ["tools", "temperature", "top_p"],
      "pricing": {"prompt": "0.000001", "completion": "0.000002"}
    },
    {
      "id": "meta-llama/llama-3.3-70b-instruct:free",
      "name": "Llama 3.3 70B (free)",
      "context_length": 131072,
      "supported_parameters": ["temperature"],
      "pricing": {"prompt": "0", "completion": "0"}
    }
  ]
}
''';
      final List<RemoteModel> models = client.parseCatalog(body);
      expect(models, hasLength(2));

      expect(models[0].id, 'z-ai/glm-4.6');
      expect(models[0].name, 'Z.AI: GLM 4.6');
      expect(models[0].vendor, 'z-ai');
      expect(models[0].contextLength, 200000);
      expect(models[0].supportsTools, isTrue);
      expect(models[0].isFree, isFalse);

      expect(models[1].vendor, 'meta-llama');
      expect(models[1].supportsTools, isFalse);
      expect(models[1].isFree, isTrue);
    });

    test('parses plain OpenAI payload (id only)', () {
      const String body =
          '{"object":"list","data":[{"object":"model","id":"gpt-4o"},{"object":"model","id":"gpt-4.1"}]}';
      final List<RemoteModel> models = client.parseCatalog(body);
      expect(models, hasLength(2));
      expect(models[0].id, 'gpt-4o');
      expect(models[0].name, 'gpt-4o'); // name falls back to id
      expect(models[0].vendor, ''); // flat id, no vendor prefix
      expect(models[0].contextLength, isNull);
      expect(models[0].supportsTools, isFalse);
      expect(models[0].isFree, isFalse);
    });

    test('parses alternative shapes: root list and models key', () {
      final List<RemoteModel> rootList = client.parseCatalog(
        '[{"id":"m-1"},{"id":"m-2"}]',
      );
      expect(rootList.map((RemoteModel m) => m.id), <String>['m-1', 'm-2']);

      final List<RemoteModel> modelsKey = client.parseCatalog(
        '{"models":[{"id":"m-3"},{"id":"m-4"}]}',
      );
      expect(modelsKey.map((RemoteModel m) => m.id), <String>['m-3', 'm-4']);
    });

    test('tolerates numeric pricing and string context length', () {
      const String body = '''
{"data": [
  {"id": "model-a", "context_length": "128000",
   "pricing": {"prompt": 0, "completion": 0.0},
   "capabilities": {"tools": true}},
  {"id": "model-b", "context_length": 8192,
   "pricing": {"prompt": 1, "completion": 2}}
]}
''';
      final List<RemoteModel> models = client.parseCatalog(body);
      expect(models[0].contextLength, 128000);
      expect(models[0].isFree, isTrue);
      expect(models[0].supportsTools, isTrue);
      expect(models[1].isFree, isFalse);
      expect(models[1].supportsTools, isFalse);
    });

    test('skips entries without any id alias', () {
      // `name` is accepted as an id alias (some gateways ship it alone),
      // but fully anonymous entries and non-map items are skipped.
      const String body =
          '{"data":[{"id":"keep-me"},{"name":"name-only"},{"other":1},{},null]}';
      final List<RemoteModel> models = client.parseCatalog(body);
      expect(models, hasLength(2));
      expect(models[0].id, 'keep-me');
      expect(models[1].id, 'name-only');
      expect(models[1].name, 'name-only');
    });

    test('throws on malformed JSON and unexpected shapes', () {
      expect(
        () => client.parseCatalog('not-json'),
        throwsA(isA<ModelCatalogException>()),
      );
      expect(
        () => client.parseCatalog('{"foo": 1}'),
        throwsA(isA<ModelCatalogException>()),
      );
    });
  });

  group('ModelCatalogClient.fetchModels', () {
    test('sends bearer auth and parses a 200 response', () async {
      Uri? capturedUrl;
      Map<String, String>? capturedHeaders;
      final ModelCatalogClient client = ModelCatalogClient(
        client: MockClient.streaming((request, bodyStream) async {
          capturedUrl = request.url;
          capturedHeaders = Map<String, String>.from(request.headers);
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"data":[{"id":"zai/glm-5.3"}]}')),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final List<RemoteModel> models = await client.fetchModels(
        baseUrl: 'https://api.inferhub.dev/v1/',
        apiKey: 'sk-airo-test',
      );

      expect(capturedUrl.toString(), 'https://api.inferhub.dev/v1/models');
      expect(capturedHeaders?['Authorization'], 'Bearer sk-airo-test');
      expect(models.single.id, 'zai/glm-5.3');
    });

    test('omits the auth header when no API key is set', () async {
      Map<String, String>? capturedHeaders;
      final ModelCatalogClient client = ModelCatalogClient(
        client: MockClient.streaming((request, bodyStream) async {
          capturedHeaders = Map<String, String>.from(request.headers);
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"data":[{"id":"open-router-model"}]}')),
            200,
          );
        }),
      );

      await client.fetchModels(
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: '',
      );
      expect(capturedHeaders?.containsKey('Authorization'), isFalse);
    });

    test('maps 401 to an unauthorized exception', () async {
      final ModelCatalogClient client = ModelCatalogClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode('{"error":{"message":"missing authorization"}}'),
            ),
            401,
          );
        }),
      );

      await expectLater(
        client.fetchModels(
          baseUrl: 'https://api.inferhub.dev/v1',
          apiKey: 'wrong',
        ),
        throwsA(
          isA<ModelCatalogException>()
              .having(
                (ModelCatalogException e) => e.statusCode,
                'statusCode',
                401,
              )
              .having(
                (ModelCatalogException e) => e.message,
                'message',
                contains('API key'),
              ),
        ),
      );
    });

    test('maps other HTTP errors and network failures', () async {
      final ModelCatalogClient failing = ModelCatalogClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(Stream.value(utf8.encode('boom')), 500);
        }),
      );
      await expectLater(
        failing.fetchModels(baseUrl: 'https://x.dev/v1', apiKey: 'k'),
        throwsA(
          isA<ModelCatalogException>().having(
            (ModelCatalogException e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );

      final ModelCatalogClient offline = ModelCatalogClient(
        client: MockClient.streaming(
          (request, bodyStream) async => throw Exception('offline'),
        ),
      );
      await expectLater(
        offline.fetchModels(baseUrl: 'https://x.dev/v1', apiKey: 'k'),
        throwsA(isA<ModelCatalogException>()),
      );
    });
  });
}
