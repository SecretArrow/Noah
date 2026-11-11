import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Abstraction over the platform biometric prompt — overridable in tests
/// and swappable if the plugin changes.
abstract class BiometricAuth {
  Future<bool> canAuthenticate();

  Future<bool> authenticate(String localizedReason);
}

/// local_auth-backed implementation used in production.
class LocalAuthBiometric implements BiometricAuth {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> canAuthenticate() async {
    try {
      final bool supported = await _auth.isDeviceSupported();
      final bool canCheck = await _auth.canCheckBiometrics;
      return supported && canCheck;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String localizedReason) async {
    try {
      return await _auth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

/// App lock (v1.18.0): a 4-8 digit PIN (salted SHA-256) as the fallback
/// credential plus an optional biometric shortcut.
///
/// The PIN hash lives in SharedPreferences under dedicated keys —
/// deliberately NOT inside [AppSettings] — so the hash never travels in
/// chat/session exports or .zabak backups.
class AppLockService {
  AppLockService({required this.prefs, BiometricAuth? biometric})
    : biometric = biometric ?? LocalAuthBiometric();

  static const String _saltKey = 'zagents.lock.pin.salt';
  static const String _hashKey = 'zagents.lock.pin.hash';

  final SharedPreferences prefs;
  final BiometricAuth biometric;

  bool get hasPin => (prefs.getString(_hashKey) ?? '').isNotEmpty;

  /// Stores a new PIN (4-8 digits). Returns false when the pin is invalid.
  Future<bool> setPin(String pin) async {
    final String trimmed = pin.trim();
    if (trimmed.length < 4 || trimmed.length > 8) return false;
    final String salt =
        DateTime.now().microsecondsSinceEpoch.toRadixString(16) +
        trimmed.length.toRadixString(16) +
        (prefs.getString(_saltKey) ?? '');
    final String saltHex = md5.convert(utf8.encode(salt)).toString();
    await prefs.setString(_saltKey, saltHex);
    await prefs.setString(_hashKey, _hash(saltHex, trimmed));
    return true;
  }

  Future<bool> verifyPin(String pin) async {
    final String? salt = prefs.getString(_saltKey);
    final String? hash = prefs.getString(_hashKey);
    if (salt == null || hash == null) return false;
    return _constantEquals(_hash(salt, pin.trim()), hash);
  }

  Future<void> clearPin() async {
    await prefs.remove(_saltKey);
    await prefs.remove(_hashKey);
  }

  Future<bool> biometricAvailable() => biometric.canAuthenticate();

  Future<bool> authenticateBiometric(String reason) =>
      biometric.authenticate(reason);

  static String _hash(String saltHex, String pin) =>
      sha256.convert(utf8.encode('$saltHex:$pin')).toString();

  static bool _constantEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
