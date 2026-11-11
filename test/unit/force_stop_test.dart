import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// A transport whose [send] hangs forever until [close] is called — the
/// "stalled connection" scenario: no deltas arrive, so the cooperative
/// `shouldAbort` poll never fires. Only a force-cancel can break it.
class _StubbornClient extends http.BaseClient {
  final Completer<void> release = Completer<void>();
  bool sendCalled = false;
  bool closeCalled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCalled = true;
    await release.future;
    throw http.ClientException('Client is already closed');
  }

  @override
  void close() {
    closeCalled = true;
    if (!release.isCompleted) release.complete();
  }
}

const LlmConfig _config = LlmConfig(
  baseUrl: 'https://provider.test',
  apiKey: 'k',
  model: 'm',
);

/// Waits (bounded) until [predicate] holds, pumping real async time.
Future<bool> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 400 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return predicate();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LlmClient.forceCancel (v1.42.0)', () {
    test('kills a stalled in-flight stream and unregisters it', () async {
      final _StubbornClient stubborn = _StubbornClient();
      final LlmClient client = LlmClient(client: stubborn);
      final Object key = Object();

      final Future<AssistantTurn> future = client.complete(
        config: _config,
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
        cancelKey: key,
      );

      expect(
        await _waitFor(() => stubborn.sendCalled),
        isTrue,
        reason: 'the request never reached the transport',
      );

      expect(LlmClient.forceCancel(key), isTrue);
      expect(stubborn.closeCalled, isTrue);
      await expectLater(future, throwsA(isA<LlmException>()));
      // The registry entry was consumed: a second cancel is a no-op.
      expect(LlmClient.forceCancel(key), isFalse);
    });

    test('is a safe no-op for unknown keys', () {
      expect(LlmClient.forceCancel('never-registered'), isFalse);
      expect(LlmClient.forceCancel(Object()), isFalse);
    });
  });

  group('ChatController.forceStop (v1.42.0)', () {
    test(
      'ends a run that a graceful stop cannot reach (stalled stream)',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'zagents_force_stop',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });

        final _StubbornClient stubborn = _StubbornClient();
        final ProviderContainer container = ProviderContainer(
          overrides: testOverrides(
            llm: LlmClient(client: stubborn),
            dir: tempDir,
            settings: AppSettings(apiKey: 'k', autoTitle: false),
          ),
        );
        addTearDown(container.dispose);

        final Future<void> sending = container
            .read(chatControllerProvider.notifier)
            .send('go');

        // The run is now pinned inside the hanging send: isRunning shows
        // it, and the transcript already has the user message + streaming
        // placeholder (both land before the transport call).
        expect(
          await _waitFor(() {
            final ChatState current = container.read(chatControllerProvider);
            return current.isRunning && current.messages.length >= 2;
          }),
          isTrue,
        );
        expect(container.read(chatControllerProvider).messages, isNotEmpty);

        // Force stop must tear the transport down immediately…
        container.read(chatControllerProvider.notifier).forceStop();
        expect(stubborn.closeCalled, isTrue);

        // …and the standard release path takes over: run released, composer
        // usable again, transcript marked stopped.
        await sending;
        final ChatState state = container.read(chatControllerProvider);
        expect(state.isRunning, isFalse);
        expect(state.isLoading, isFalse);
        expect(state.messages, isNotEmpty);
        expect(state.messages.last.role, Role.assistant);
        expect(state.messages.last.content, contains('_(stopped)_'));

        // The session is free for a NEW run (no zombie run state): a second
        // force stop is an idempotent no-op.
        container.read(chatControllerProvider.notifier).forceStop();
        expect(container.read(chatControllerProvider).isRunning, isFalse);
      },
    );
  });
}
