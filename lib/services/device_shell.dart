import 'package:flutter/services.dart';

/// Outcome of one device shell execution (v1.31.0 — module `device`
/// capability). All fields are always populated defensively: a missing
/// native side, a `su` refusal or a timeout degrade into a result value
/// instead of an exception, so a module can branch on the outcome and
/// the chat never breaks.
class DeviceShellResult {
  const DeviceShellResult({
    this.exitCode = -1,
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
    this.error,
  });

  /// Process exit code (-1 when the process could not start or was
  /// killed after the timeout).
  final int exitCode;
  final String stdout;
  final String stderr;

  /// True when the process was destroyed because it exceeded the
  /// requested time budget.
  final bool timedOut;

  /// Bridge-level failure (channel missing, spawn failure, `su` binary
  /// absent …). Null when the process itself ran.
  final String? error;

  bool get ran => error == null && !timedOut;
  bool get succeeded => ran && exitCode == 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'exitCode': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'timedOut': timedOut,
    if (error != null) 'error': error,
  };

  static DeviceShellResult fromJson(Map<Object?, Object?> json) =>
      DeviceShellResult(
        exitCode: (json['exitCode'] as num?)?.toInt() ?? -1,
        stdout: json['stdout']?.toString() ?? '',
        stderr: json['stderr']?.toString() ?? '',
        timedOut: json['timedOut'] == true,
        error: json['error']?.toString(),
      );
}

/// Signature of the native seam — injectable in tests so unit tests never
/// need a real platform channel.
typedef DeviceShellInvoker = Future<Object?> Function(
  String method,
  Map<String, Object?> arguments,
);

/// Dart side of the `zagents/device` MethodChannel: executes one shell
/// command on the device, optionally through `su` (rooted phones).
///
/// Security model — this service is only reachable from module runs that
/// (a) declare the `device` permission, (b) were approved by the user at
/// activation, and (c) pass the Settings → Modules master switch that the
/// bridge checks on every call. The channel itself adds the last line of
/// defense: nothing else in the app invokes it.
class DeviceShellService {
  DeviceShellService({DeviceShellInvoker? invoker})
    : _invoker = invoker ?? _defaultInvoker;

  static const MethodChannel _channel = MethodChannel('zagents/device');

  final DeviceShellInvoker _invoker;

  static Future<Object?> _defaultInvoker(
    String method,
    Map<String, Object?> arguments,
  ) => _channel.invokeMethod(method, arguments);

  /// Runs [command] (POSIX `sh -c` semantics), as root when [root] is set
  /// (`su -c`). [timeoutMs] is clamped by the native side too; both sides
  /// agree on the same 1s–120s window with a 30s default.
  Future<DeviceShellResult> run({
    required String command,
    bool root = false,
    int timeoutMs = 30000,
  }) async {
    final Map<String, Object?> args = <String, Object?>{
      'command': command,
      'root': root,
      'timeoutMs': timeoutMs,
    };
    try {
      final Object? raw = await _invoker('exec', args);
      if (raw is Map) {
        return DeviceShellResult.fromJson(raw.cast<Object?, Object?>());
      }
      return const DeviceShellResult(error: 'Malformed shell bridge response');
    } on PlatformException catch (e) {
      return DeviceShellResult(error: e.message ?? e.code);
    } on MissingPluginException {
      return const DeviceShellResult(
        error: 'Shell bridge is unavailable on this platform',
      );
    } catch (e) {
      return DeviceShellResult(error: '$e');
    }
  }

  /// Reads the airplane-mode state WITHOUT root (v1.32.0) — the native
  /// side answers from the world-readable `Settings.Global
  /// .AIRPLANE_MODE_ON` setting. Returns null when the platform cannot
  /// answer (tests, iOS, missing native side) so callers can degrade to
  /// "unknown" instead of asserting a state they never saw.
  Future<bool?> readAirplaneMode() async {
    try {
      final Object? raw = await _invoker(
        'getAirplaneMode',
        const <String, Object?>{},
      );
      return raw is bool ? raw : null;
    } on Exception {
      return null;
    } catch (_) {
      return null;
    }
  }
}
