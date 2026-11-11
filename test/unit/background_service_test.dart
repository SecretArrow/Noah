import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/background_service.dart';

/// Tests for the Dart side of the background-run hold (foreground service
/// bridge). The native side is exercised by the e2e suite on the Android
/// emulator; here we verify the channel contract and — critically — that
/// every failure path degrades to a no-op instead of crashing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('zagents/background');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start/update/stop round-trip through the method channel', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return true;
        });

    final BackgroundRunService service = BackgroundRunService();
    expect(service.isActive, isFalse);

    await service.start(title: 'Noah agent is running', text: 'Processing…');
    expect(service.isActive, isTrue);
    expect(calls.single.method, 'start');
    expect(calls.single.arguments['title'], 'Noah agent is running');
    expect(calls.single.arguments['text'], 'Processing…');

    await service.updateStatus('Step 1 · browser_navigate');
    expect(calls, hasLength(2));
    expect(calls.last.method, 'update');
    expect(calls.last.arguments['text'], 'Step 1 · browser_navigate');

    await service.stop();
    expect(service.isActive, isFalse);
    expect(calls, hasLength(3));
    expect(calls.last.method, 'stop');
  });

  test('updateStatus is skipped while inactive (no channel traffic)', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return true;
        });

    final BackgroundRunService service = BackgroundRunService();
    await service.updateStatus('Step 1 · browser_click');
    expect(calls, isEmpty); // never started → nothing sent
  });

  test('missing platform implementation never throws', () async {
    // No mock handler registered → invokeMethod throws
    // MissingPluginException, which must be swallowed.
    final BackgroundRunService service = BackgroundRunService();

    await service.start(title: 't', text: 'x');
    expect(service.isActive, isFalse);
    expect(service.lastOperationSucceeded, isFalse);

    // Still safe afterwards: update is skipped, stop is a no-op.
    await service.updateStatus('Step 1 · read_file');
    await service.stop();
    expect(service.isActive, isFalse);
  });

  test('platform returning null / throwing keeps the Dart side safe', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'start') return null; // ambiguous platform answer
          if (call.method == 'update') throw PlatformException(code: 'boom');
          return true;
        });

    final BackgroundRunService service = BackgroundRunService();
    await service.start(title: 't', text: 'x');
    expect(service.isActive, isFalse); // null is treated as failure
    expect(service.lastOperationSucceeded, isFalse);

    await service.updateStatus('Step 1 · scroll'); // must not throw
    await service.stop(); // inactive → no channel call, must not throw
  });

  test(
    'per-chat notification round-trip with one-time permission ask',
    () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return true;
          });

      final BackgroundRunService service = BackgroundRunService();

      // First per-chat start asks for POST_NOTIFICATIONS exactly once, then
      // posts the session notification.
      await service.startSession(
        sessionId: 's1',
        title: 'Chat A',
        text: 'Processing…',
      );
      expect(calls, hasLength(2));
      expect(calls.first.method, 'requestNotificationPermission');
      expect(calls.last.method, 'startSession');
      expect(calls.last.arguments['sessionId'], 's1');
      expect(calls.last.arguments['title'], 'Chat A');
      expect(calls.last.arguments['text'], 'Processing…');
      expect(service.activeSessionIds, <String>{'s1'});

      // Live step update targets the right session.
      await service.updateSessionStatus(sessionId: 's1', text: 'Step 1 · tool');
      expect(calls, hasLength(3));
      expect(calls.last.method, 'updateSession');
      expect(calls.last.arguments['sessionId'], 's1');

      // A second session starts WITHOUT another permission round-trip.
      await service.startSession(sessionId: 's2', title: 'Chat B', text: 'x');
      expect(calls, hasLength(4));
      expect(calls.last.method, 'startSession');
      expect(service.activeSessionIds, <String>{'s1', 's2'});

      // Releasing s2 removes only s2.
      await service.stopSession('s2');
      expect(calls.last.method, 'stopSession');
      expect(calls.last.arguments['sessionId'], 's2');
      expect(service.activeSessionIds, <String>{'s1'});

      // Updates for a released session are dropped (no channel traffic).
      await service.updateSessionStatus(sessionId: 's2', text: 'ghost');
      expect(calls, hasLength(5));

      // Releasing s1 clears the set.
      await service.stopSession('s1');
      expect(service.activeSessionIds, isEmpty);
    },
  );

  test('per-chat calls before/without any session are safe no-ops', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return true;
        });

    final BackgroundRunService service = BackgroundRunService();
    await service.updateSessionStatus(sessionId: 'ghost', text: 'x');
    await service.stopSession('ghost');
    expect(calls, isEmpty);
    expect(service.activeSessionIds, isEmpty);
  });

  test(
    'missing platform implementation never throws for per-chat calls',
    () async {
      // No mock handler registered → MissingPluginException, swallowed.
      final BackgroundRunService service = BackgroundRunService();
      await service.startSession(sessionId: 's1', title: 't', text: 'x');
      await service.updateSessionStatus(sessionId: 's1', text: 'Step 1 · x');
      await service.stopSession('s1');
      expect(service.activeSessionIds, isEmpty);
    },
  );
}
