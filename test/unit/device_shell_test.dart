import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/device_shell.dart';

void main() {
  group('DeviceShellService.readAirplaneMode (v1.32.0)', () {
    test('passes a bool answer through', () async {
      final DeviceShellService service = DeviceShellService(
        invoker: (String method, Map<String, Object?> args) async {
          expect(method, 'getAirplaneMode');
          return true;
        },
      );
      expect(await service.readAirplaneMode(), isTrue);
    });

    test('false passes through as a real state, not unknown', () async {
      final DeviceShellService service = DeviceShellService(
        invoker: (String method, Map<String, Object?> args) async => false,
      );
      expect(await service.readAirplaneMode(), isFalse);
    });

    test('a malformed answer degrades to null (unknown)', () async {
      final DeviceShellService service = DeviceShellService(
        invoker: (String method, Map<String, Object?> args) async => 'yes',
      );
      expect(await service.readAirplaneMode(), isNull);
    });

    test('a missing platform handler degrades to null (unknown)', () async {
      final DeviceShellService service = DeviceShellService(
        invoker: (String method, Map<String, Object?> args) async =>
            throw MissingPluginException('no native side'),
      );
      expect(await service.readAirplaneMode(), isNull);
    });

    test('a platform exception degrades to null (unknown)', () async {
      final DeviceShellService service = DeviceShellService(
        invoker: (String method, Map<String, Object?> args) async =>
            throw PlatformException(code: 'boom'),
      );
      expect(await service.readAirplaneMode(), isNull);
    });

    test('any other failure degrades to null (unknown)', () async {
      final DeviceShellService service = DeviceShellService(
        invoker: (String method, Map<String, Object?> args) async =>
            throw StateError('unexpected'),
      );
      expect(await service.readAirplaneMode(), isNull);
    });
  });
}
