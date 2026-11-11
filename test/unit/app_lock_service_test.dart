import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/app_lock_service.dart';

/// Biometric test double: programmatically available / successful.
class ScriptedBiometric implements BiometricAuth {
  ScriptedBiometric({this.available = true, this.success = true});

  final bool available;
  final bool success;

  @override
  Future<bool> canAuthenticate() async => available;

  @override
  Future<bool> authenticate(String localizedReason) async => success;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late AppLockService lock;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    lock = AppLockService(prefs: prefs, biometric: ScriptedBiometric());
  });

  group('AppLockService PIN (v1.18.0)', () {
    test('set + verify accepts the right PIN and rejects wrong ones', () async {
      expect(lock.hasPin, isFalse);
      expect(await lock.setPin('123456'), isTrue);
      expect(lock.hasPin, isTrue);
      expect(await lock.verifyPin('123456'), isTrue);
      expect(await lock.verifyPin('123457'), isFalse);
      expect(await lock.verifyPin(' 123456 '), isTrue, reason: 'trimmed');
    });

    test('PIN length must be 4-8 digits', () async {
      expect(await lock.setPin('123'), isFalse);
      expect(await lock.setPin('1' * 9), isFalse);
      expect(lock.hasPin, isFalse);
    });

    test('clearPin removes the credential', () async {
      await lock.setPin('2468');
      expect(lock.hasPin, isTrue);
      await lock.clearPin();
      expect(lock.hasPin, isFalse);
      expect(await lock.verifyPin('2468'), isFalse);
    });

    test('same PIN hashes differently for different salts', () async {
      await lock.setPin('1111');
      final String hash1 = prefs.getString('zagents.lock.pin.hash')!;
      final AppLockService other = AppLockService(
        prefs: prefs,
        biometric: ScriptedBiometric(),
      );
      // Overwriting with the same PIN re-salts: hash changes, verify works.
      await other.setPin('1111');
      final String hash2 = prefs.getString('zagents.lock.pin.hash')!;
      expect(hash1, isNot(hash2));
      expect(await other.verifyPin('1111'), isTrue);
    });
  });

  group('biometric', () {
    test('availability follows the platform capability', () async {
      expect(await lock.biometricAvailable(), isTrue);
      final AppLockService noBio = AppLockService(
        prefs: prefs,
        biometric: ScriptedBiometric(available: false),
      );
      expect(await noBio.biometricAvailable(), isFalse);
    });

    test('authenticate returns the platform decision', () async {
      expect(await lock.authenticateBiometric('reason'), isTrue);
      final AppLockService failing = AppLockService(
        prefs: prefs,
        biometric: ScriptedBiometric(success: false),
      );
      expect(await failing.authenticateBiometric('reason'), isFalse);
    });
  });

  test('AppSettings persists appLockEnabled + notifyOnDone', () {
    final AppSettings settings = AppSettings(
      apiKey: 'k',
      appLockEnabled: true,
      notifyOnDone: false,
    );
    final AppSettings restored = AppSettings.fromJson(settings.toJson());
    expect(restored.appLockEnabled, isTrue);
    expect(restored.notifyOnDone, isFalse);

    // Defaults keep the current behavior.
    final AppSettings defaults = AppSettings();
    expect(defaults.appLockEnabled, isFalse);
    expect(defaults.notifyOnDone, isTrue);
  });

  test('appInForegroundProvider defaults to true', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(appInForegroundProvider), isTrue);
  });
}
