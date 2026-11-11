import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Abstraction over persistent settings storage.
///
/// Secret-handling contract (v1.44.0 hardening): [AppSettings.apiKey] is a
/// credential and must never be persisted as plaintext JSON. Implementations
/// keep it in a [SecretBox] (secure storage) and persist every non-secret
/// field exactly as before. [load] stays synchronous — it may serve the key
/// from an in-process mirror that is refreshed by
/// [PrefsSettingsRepository.create], [PrefsSettingsRepository.save] and the
/// one-shot legacy migration.
abstract class SettingsRepository {
  AppSettings load();
  Future<void> save(AppSettings settings);
}

/// Thin async key/value interface for secret values (API keys).
///
/// Pure Dart on purpose: unit tests inject [InMemorySecretBox] instead of the
/// FlutterSecureStorage-backed implementation, so no platform channel is
/// needed. Implementations may throw (platform/Keystore/Keychain failures) —
/// callers must treat any exception as "secret storage unavailable", never as
/// a fatal error. Callers pass fully-namespaced keys, e.g.
/// `zagents.settings.apiKey`.
abstract class SecretBox {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production [SecretBox] backed by flutter_secure_storage (Android
/// Keystore-encrypted prefs / iOS Keychain / equivalents).
class FlutterSecretBox implements SecretBox {
  const FlutterSecretBox({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory [SecretBox] for unit and widget tests.
class InMemorySecretBox implements SecretBox {
  InMemorySecretBox([Map<String, String>? initial])
    : _values = initial != null ? Map<String, String>.of(initial) : {};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// SharedPreferences-backed repository used in production.
///
/// Secret handling: the active [AppSettings.apiKey] lives in the [SecretBox]
/// under [apiKeySecretKey] and is REMOVED from the settings JSON stored in
/// SharedPreferences (both on save and during a one-shot legacy migration on
/// load). Non-secret fields — including the per-preset keys inside
/// [AppSettings.presets] — are still stored in the JSON exactly as before;
/// moving preset keys is deliberately out of scope for this hardening step
/// (the active key is the one transported into every LLM request header).
///
/// Crash safety (v1.47.1 re-ordering): the non-secret settings JSON is
/// persisted FIRST and is never gated behind the Keystore — the previous
/// order awaited the secure copy before writing prefs, so a process death
/// or a slow/hung Keystore in that window silently discarded the user's
/// change (e.g. the "check updates on start" toggle resetting to ON after
/// reopening the app). With the new order a crash at ANY point leaves
/// either the previous intact JSON or a new JSON whose apiKey is either
/// already secured (and stripped, or scheduled to be stripped idempotently
/// by the next load's migration) or covered by the legacy-migration retry.
/// The plaintext apiKey in prefs is a transient fallback: [save] removes it
/// only after both the prefs write and the secure copy are confirmed, by
/// reusing [_stripApiKeyFromPrefs] (re-reads the disk JSON, strips only a
/// byte-identical value, idempotent).
///
/// Failure behaviour (trade-off): if secure storage is unavailable,
/// [load]/[save] never throw. Reads fall back to the legacy plaintext copy in
/// prefs (old behaviour), and saves keep the key inside the prefs JSON as a
/// last-resort fallback instead of losing it — degrading to the pre-hardening
/// plaintext behaviour until secure storage recovers. Every secure-storage
/// degradation is recorded in [lastSecretStorageError] with a human-readable
/// message, and a failed prefs write is recorded in [lastSettingsWriteError].
/// One caveat: if deleting an emptied key fails, a subsequent cold start may
/// read the stale key back from secure storage; the user can simply clear it
/// again.
class PrefsSettingsRepository implements SettingsRepository {
  PrefsSettingsRepository(this._prefs, {SecretBox? secretBox})
    : _secrets = secretBox ?? const FlutterSecretBox() {
    // Best-effort warm-up of the synchronous key mirror; production code
    // goes through [create], which awaits it before the first [load].
    unawaited(_refreshApiKeyCache());
  }

  final SharedPreferences _prefs;
  final SecretBox _secrets;

  static const String _key = 'zagents.settings.v1';

  /// Namespaced secure-storage key holding the active provider API key.
  static const String apiKeySecretKey = 'zagents.settings.apiKey';

  /// Synchronous mirror of the [SecretBox] value, kept in step by [create],
  /// [save] and the legacy migration, so the synchronous [load] can serve the
  /// key without awaiting platform channels. Empty string = "no key known".
  String _apiKeyCache = '';

  /// Bumped by every code path that authoritatively sets [_apiKeyCache]
  /// ([save], the legacy migration). The fire-and-forget constructor warm-up
  /// captures the generation before awaiting the box and only applies its
  /// result when nothing changed in between — without this guard a slow
  /// warm-up could clobber a key a concurrent [save] just installed.
  int _cacheGeneration = 0;

  /// Description of the most recent secure-storage failure, or null. Lets
  /// callers/tests surface degradation ("clear message") without this file
  /// depending on UI/print facilities.
  String? lastSecretStorageError;

  /// Description of the most recent failed prefs write of the settings JSON,
  /// or null. Cleared at the start of every [save] (so after it returns, a
  /// null value means that save persisted the JSON successfully) and set
  /// with a human-readable message when [SharedPreferences.setString]
  /// throws (e.g. disk full). Lets callers/tests surface degradation without
  /// this file depending on UI/print facilities.
  String? lastSettingsWriteError;

  static Future<PrefsSettingsRepository> create({SecretBox? secretBox}) async {
    final prefs = await SharedPreferences.getInstance();
    final PrefsSettingsRepository repository = PrefsSettingsRepository(
      prefs,
      secretBox: secretBox,
    );
    await repository._refreshApiKeyCache();
    return repository;
  }

  @override
  AppSettings load() {
    final String? raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return AppSettings();
    final Map<String, dynamic>? decoded = _decode(raw);
    if (decoded == null) {
      // Corrupted settings: fall back to defaults.
      return AppSettings();
    }
    final AppSettings settings = AppSettings.fromJson(decoded);
    final String legacyKey = decoded['apiKey'] as String? ?? '';
    // Secure storage wins over a stale plaintext copy; the legacy plaintext
    // is only adopted when the secure mirror holds nothing yet.
    final String knownKey = _apiKeyCache.isNotEmpty ? _apiKeyCache : legacyKey;
    if (legacyKey.isNotEmpty) {
      // Pre-hardening install (or a degraded save): plaintext key still in
      // prefs. Migration is fire-and-forget; it writes the key to the
      // SecretBox FIRST and only then strips the plaintext, so a crash in
      // the middle never loses the key (see [_migrateLegacyApiKey]).
      unawaited(_migrateLegacyApiKey(legacyKey));
    }
    if (knownKey.isEmpty) return settings;
    return settings.copyWith(apiKey: knownKey);
  }

  @override
  Future<void> save(AppSettings settings) async {
    final String apiKey = settings.apiKey;
    _apiKeyCache = apiKey;
    _cacheGeneration++;
    // v1.47.1 fix: persist the settings JSON FIRST. The old order awaited
    // the (Keystore-backed) SecretBox before the prefs write, so process
    // death or a slow/hung Keystore in that window silently lost the change
    // — and a throwing prefs write could not be reported either. Non-secret
    // settings must never be gated behind secure storage.
    final Map<String, dynamic> json = settings.toJson();
    lastSettingsWriteError = null;
    bool prefsOk = true;
    try {
      await _prefs.setString(_key, jsonEncode(json));
    } catch (error) {
      prefsOk = false;
      lastSettingsWriteError = 'Settings write failed for $_key: $error';
    }
    bool secured = false;
    try {
      if (apiKey.isEmpty) {
        await _secrets.delete(apiKeySecretKey);
      } else {
        await _secrets.write(apiKeySecretKey, apiKey);
      }
      secured = true;
    } catch (error) {
      _recordSecretFailure('write', error);
    }
    if (prefsOk && secured) {
      // Both copies confirmed: drop the transient plaintext fallback from
      // prefs. [_stripApiKeyFromPrefs] re-reads the disk JSON and only
      // strips a value byte-identical to the confirmed key, so it is
      // idempotent and can never wipe a concurrent newer save. When the
      // prefs write failed, everything is left as-is for the next
      // save/migration instead.
      await _stripApiKeyFromPrefs(apiKey);
    }
  }

  /// One-shot legacy migration: moves a plaintext apiKey out of the prefs
  /// JSON into the [SecretBox]. Idempotent and crash-safe — safe ordering is
  /// (1) read what the box already holds, (2) write the legacy key only when
  /// the box is empty (an existing value is either the same key from a
  /// crashed earlier attempt or a NEWER save; either way it wins), (3) strip
  /// the plaintext from prefs only after a secure copy is confirmed. A crash
  /// between the steps always leaves at least one intact copy and the next
  /// [load] retries the remaining step.
  Future<void> _migrateLegacyApiKey(String legacyKey) async {
    String? secured;
    try {
      secured = await _secrets.read(apiKeySecretKey);
    } catch (error) {
      _recordSecretFailure('read', error);
    }
    if (secured == null || secured.isEmpty) {
      try {
        await _secrets.write(apiKeySecretKey, legacyKey);
        _apiKeyCache = legacyKey;
        _cacheGeneration++;
      } catch (error) {
        // Secure storage unavailable: keep the plaintext legacy copy in
        // prefs so the key is not lost; the next load() retries.
        _recordSecretFailure('write', error);
        return;
      }
    } else {
      _apiKeyCache = secured;
      _cacheGeneration++;
    }
    await _stripApiKeyFromPrefs(legacyKey);
  }

  /// Rewrites the prefs JSON without `apiKey` — but only when the JSON still
  /// holds exactly [confirmedKey] (the value already safe in the SecretBox).
  /// If a concurrent save replaced it with a newer key that is not yet in the
  /// SecretBox, that one is left untouched for the next migration attempt.
  Future<void> _stripApiKeyFromPrefs(String confirmedKey) async {
    try {
      final String? raw = _prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final Map<String, dynamic>? decoded = _decode(raw);
      if (decoded == null) return;
      if (decoded['apiKey'] != confirmedKey) return;
      decoded.remove('apiKey');
      await _prefs.setString(_key, jsonEncode(decoded));
    } catch (_) {
      // Best-effort: the plaintext copy stays and the next load() retries.
    }
  }

  /// Refreshes the synchronous mirror from the [SecretBox]. Failures are
  /// recorded but leave the current mirror untouched. The result is applied
  /// only when no authoritative writer ([save] / migration) ran while the
  /// box read was in flight — see [_cacheGeneration].
  Future<void> _refreshApiKeyCache() async {
    final int generationAtStart = _cacheGeneration;
    try {
      final String? value = await _secrets.read(apiKeySecretKey);
      if (_cacheGeneration != generationAtStart) return;
      _apiKeyCache = value ?? '';
    } catch (error) {
      _recordSecretFailure('read', error);
    }
  }

  void _recordSecretFailure(String operation, Object error) {
    lastSecretStorageError =
        'Secure storage $operation failed for '
        '$apiKeySecretKey: $error';
  }

  Map<String, dynamic>? _decode(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Corrupted settings: fall back to defaults.
    }
    return null;
  }
}

/// In-memory repository for unit and widget tests.
class MemorySettingsRepository implements SettingsRepository {
  MemorySettingsRepository([AppSettings? initial])
    : _settings = initial ?? AppSettings();

  AppSettings _settings;

  @override
  AppSettings load() => _settings;

  @override
  Future<void> save(AppSettings settings) async => _settings = settings;
}
