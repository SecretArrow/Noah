import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/local_ai/ollama_registry_client.dart';

const String _modelDigest =
    'c0c7bd67b0c14b9a3e9e5a4a5a7c8b9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b';

const String _bigDigest =
    'bb00bd67b0c14b9a3e9e5a4a5a7c8b9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b';

/// Builds a registry-manifest-shaped payload.
Map<String, Object?> _manifest(List<Map<String, Object?>> layers) =>
    <String, Object?>{
      'schemaVersion': 2,
      'mediaType': 'application/vnd.docker.distribution.manifest.v2+json',
      'config': <String, Object?>{
        'mediaType': 'application/vnd.docker.container.image.v1+json',
        'digest':
            'sha256:fffff67b0c14b9a3e9e5a4a5a7c8b9d0e1f2a3b4c5d6e7'
            'f8a9b0c1d2e3f4a5b',
        'size': 187,
      },
      'layers': layers,
    };

Map<String, Object?> _layer(
  String digest,
  int size, {
  String mediaType = 'application/vnd.ollama.image.model',
}) => <String, Object?>{
  'mediaType': mediaType,
  'digest': 'sha256:$digest',
  'size': size,
};

void main() {
  group('OllamaRegistryClient.resolve', () {
    test(
      'library ref: config + one blob layer → blob url, sha and size',
      () async {
        final List<http.Request> requests = <http.Request>[];
        final OllamaRegistryClient client = OllamaRegistryClient(
          client: MockClient((http.Request request) async {
            requests.add(request);
            return http.Response(
              jsonEncode(
                _manifest(<Map<String, Object?>>[
                  _layer(_modelDigest, 548407808),
                ]),
              ),
              200,
            );
          }),
        );

        final RegistryBlob blob = await client.resolve('qwen3:0.6b');

        expect(
          requests.single.url.toString(),
          'https://registry.ollama.ai/v2/library/qwen3/manifests/0.6b',
        );
        expect(
          requests.single.headers['Accept'],
          contains('application/vnd.docker.distribution.manifest.v2+json'),
        );
        expect(
          blob.blobUrl,
          'https://registry.ollama.ai/v2/library/qwen3/blobs/'
          'sha256:$_modelDigest',
        );
        expect(blob.sha256, _modelDigest);
        expect(blob.sizeBytes, 548407808);
      },
    );

    test('multi-layer manifest picks the largest non-config layer', () async {
      final OllamaRegistryClient client = OllamaRegistryClient(
        client: MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(
              _manifest(<Map<String, Object?>>[
                _layer(
                  'aaaa1d67b0c14b9a3e9e5a4a5a7c8b9d0e1f2a3b4c5d6e7f8a9b0c1d2'
                  'e3f4a5b',
                  517,
                  mediaType: 'application/vnd.ollama.image.params',
                ),
                _layer(
                  'cccc3d67b0c14b9a3e9e5a4a5a7c8b9d0e1f2a3b4c5d6e7f8a9b0c1d2'
                  'e3f4a5b',
                  1870,
                  mediaType: 'application/vnd.oci.image.config.v1+json',
                ),
                _layer(_bigDigest, 943718400),
              ]),
            ),
            200,
          );
        }),
      );

      final RegistryBlob blob = await client.resolve('bonsai-2:2b');

      expect(blob.sha256, _bigDigest);
      expect(blob.sizeBytes, 943718400);
      expect(
        blob.blobUrl,
        'https://registry.ollama.ai/v2/library/bonsai-2/blobs/'
        'sha256:$_bigDigest',
      );
    });

    test('hf.co refs keep the repo path verbatim and use the tag', () async {
      final List<Uri> seen = <Uri>[];
      final OllamaRegistryClient client = OllamaRegistryClient(
        client: MockClient((http.Request request) async {
          seen.add(request.url);
          return http.Response(
            jsonEncode(
              _manifest(<Map<String, Object?>>[_layer(_modelDigest, 10)]),
            ),
            200,
          );
        }),
      );

      await client.resolve('hf.co/user/repo:my-tag');

      expect(
        seen.single.toString(),
        'https://registry.ollama.ai/v2/hf.co/user/repo/manifests/my-tag',
      );
    });

    test('a ref without a tag defaults to latest', () async {
      final List<Uri> seen = <Uri>[];
      final OllamaRegistryClient client = OllamaRegistryClient(
        client: MockClient((http.Request request) async {
          seen.add(request.url);
          return http.Response(
            jsonEncode(
              _manifest(<Map<String, Object?>>[_layer(_modelDigest, 10)]),
            ),
            200,
          );
        }),
      );

      await client.resolve('qwen3');

      expect(
        seen.single.toString(),
        'https://registry.ollama.ai/v2/library/qwen3/manifests/latest',
      );
    });

    test('HTTP 404 raises OllamaRegistryException', () async {
      final OllamaRegistryClient client = OllamaRegistryClient(
        client: MockClient(
          (http.Request request) async => http.Response('not found', 404),
        ),
      );

      await expectLater(
        client.resolve('nope:latest'),
        throwsA(
          isA<OllamaRegistryException>().having(
            (OllamaRegistryException e) => e.message,
            'message',
            contains('not found'),
          ),
        ),
      );
    });

    test('other HTTP statuses raise OllamaRegistryException', () async {
      final OllamaRegistryClient client = OllamaRegistryClient(
        client: MockClient(
          (http.Request request) async => http.Response('boom', 500),
        ),
      );

      await expectLater(
        client.resolve('qwen3:0.6b'),
        throwsA(isA<OllamaRegistryException>()),
      );
    });

    test('network errors surface as OllamaRegistryException', () async {
      final OllamaRegistryClient client = OllamaRegistryClient(
        client: MockClient((http.Request request) async {
          throw Exception('socket closed');
        }),
      );

      await expectLater(
        client.resolve('qwen3:0.6b'),
        throwsA(isA<OllamaRegistryException>()),
      );
    });

    test('malformed payloads raise OllamaRegistryException', () async {
      final OllamaRegistryClient brokenJson = OllamaRegistryClient(
        client: MockClient(
          (http.Request request) async => http.Response('{not json', 200),
        ),
      );
      await expectLater(
        brokenJson.resolve('qwen3:0.6b'),
        throwsA(isA<OllamaRegistryException>()),
      );

      final OllamaRegistryClient noLayers = OllamaRegistryClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<String, Object?>{'layers': <Object>[]}),
            200,
          ),
        ),
      );
      await expectLater(
        noLayers.resolve('qwen3:0.6b'),
        throwsA(isA<OllamaRegistryException>()),
      );
    });

    test('an empty reference is rejected without a request', () async {
      int calls = 0;
      final OllamaRegistryClient client = OllamaRegistryClient(
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        client.resolve('  '),
        throwsA(isA<OllamaRegistryException>()),
      );
      expect(calls, 0);
    });
  });
}
