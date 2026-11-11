import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/di.dart';
import 'package:noah/services/local_ai/llm_server_controller.dart';

void main() {
  late FakeLlmServerPlatform platform;
  late ProviderContainer container;
  late LlmServerController controller;

  /// Boots a container with the fake platform and a scripted health
  /// endpoint; timing knobs are shortened so the timeout test stays fast.
  void boot({required http.Client healthClient}) {
    platform = FakeLlmServerPlatform();
    container = ProviderContainer(
      overrides: <Override>[
        llmServerPlatformProvider.overrideWithValue(platform),
        llmHttpClientProvider.overrideWithValue(healthClient),
        llmServerProvider.overrideWith(
          () => LlmServerController(
            startTimeout: const Duration(milliseconds: 250),
            healthPollInterval: const Duration(milliseconds: 10),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    controller = container.read(llmServerProvider.notifier);
  }

  http.Client health(int status) => MockClient(
    (http.Request request) async => http.Response('{"status":"ok"}', status),
  );

  group('LlmServerController.start', () {
    test('start → starting → health 200 → running (args forwarded)', () async {
      boot(healthClient: health(200));
      platform.logs.addAll(<String>['llama-server listening', 'model loaded']);

      final Future<bool> started = controller.start(
        modelPath: '/data/local/models/m1.gguf',
        modelName: 'qwen3:0.6b',
        port: 11434,
        contextSize: 4096,
        threads: 4,
      );
      // The state flips to starting synchronously before the first await.
      expect(
        container.read(llmServerProvider).status,
        LlmServerStatus.starting,
      );

      expect(await started, isTrue);
      final LlmServerState state = container.read(llmServerProvider);
      expect(state.status, LlmServerStatus.running);
      expect(state.activeModelName, 'qwen3:0.6b');
      expect(state.activeModelPath, '/data/local/models/m1.gguf');
      expect(state.port, 11434);
      expect(platform.startCalls, hasLength(1));
      expect(platform.startCalls.single['alias'], 'qwen3:0.6b');
      expect(platform.startCalls.single['port'], 11434);
      expect(platform.startCalls.single['contextSize'], 4096);
      expect(platform.startCalls.single['threads'], 4);
      expect(platform.running, isTrue);
    });

    test('health never answering → failed with message and log tail', () async {
      boot(healthClient: health(503));
      platform.logs.add('loading model');

      final bool ok = await controller.start(
        modelPath: '/data/local/models/big.gguf',
        modelName: 'big',
      );

      expect(ok, isFalse);
      final LlmServerState state = container.read(llmServerProvider);
      expect(state.status, LlmServerStatus.failed);
      expect(state.message, contains('timed out'));
      expect(state.logTail, contains('loading model'));
    });

    test('a refused platform start fails immediately', () async {
      boot(healthClient: health(200));
      platform.startResult = false;

      final bool ok = await controller.start(
        modelPath: '/x.gguf',
        modelName: 'x',
      );

      expect(ok, isFalse);
      expect(container.read(llmServerProvider).status, LlmServerStatus.failed);
    });

    test('a second start while running is refused', () async {
      boot(healthClient: health(200));

      expect(
        await controller.start(modelPath: '/a.gguf', modelName: 'a'),
        isTrue,
      );
      expect(
        await controller.start(modelPath: '/b.gguf', modelName: 'b'),
        isFalse,
      );
      expect(container.read(llmServerProvider).activeModelName, 'a');
    });
  });

  group('LlmServerController.refresh', () {
    test('runtimeAvailable false → unavailable', () async {
      boot(healthClient: health(200));
      platform.available = false;

      await controller.refresh();

      expect(
        container.read(llmServerProvider).status,
        LlmServerStatus.unavailable,
      );
    });

    test('running + healthy → running (crash recovery probe)', () async {
      boot(healthClient: health(200));
      platform.running = true;

      await controller.refresh();

      expect(container.read(llmServerProvider).status, LlmServerStatus.running);
    });

    test('a crashed process (exit code) flips running → failed', () async {
      boot(healthClient: health(200));
      platform.running = true;

      // The controller believes the server is running…
      expect(
        await controller.start(modelPath: '/a.gguf', modelName: 'a'),
        isTrue,
      );
      platform.simulateCrash(137);

      await controller.refresh();

      final LlmServerState state = container.read(llmServerProvider);
      expect(state.status, LlmServerStatus.failed);
      expect(state.message, contains('137'));
    });

    test('a stopped process reports stopped', () async {
      boot(healthClient: health(200));
      platform.running = false;
      platform.exitCode = null;

      await controller.refresh();

      expect(container.read(llmServerProvider).status, LlmServerStatus.stopped);
    });
  });

  group('LlmServerController.stop / pollNow', () {
    test('stop → stopping → stopped', () async {
      boot(healthClient: health(200));
      await controller.start(modelPath: '/a.gguf', modelName: 'a');

      final bool stopped = await controller.stop();

      expect(stopped, isTrue);
      expect(container.read(llmServerProvider).status, LlmServerStatus.stopped);
      expect(platform.stopCalls, 1);
      expect(platform.running, isFalse);
    });

    test(
      'pollNow flips a dead server to failed and refreshes the logs',
      () async {
        boot(healthClient: health(200));
        await controller.start(modelPath: '/a.gguf', modelName: 'a');
        platform.logs.add('crash!');
        platform.simulateCrash(3);

        await controller.pollNow();

        final LlmServerState state = container.read(llmServerProvider);
        expect(state.status, LlmServerStatus.failed);
        expect(state.logTail, contains('crash!'));
      },
    );

    test('pollNow is a no-op unless the server is believed running', () async {
      boot(healthClient: health(200));

      await controller.pollNow();

      expect(container.read(llmServerProvider).status, LlmServerStatus.stopped);
    });
  });
}
