import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:pointycastle/random/fortuna_random.dart';

import '../models/models.dart';
import 'chat_store.dart';
import 'context_repository.dart';
import 'settings_repository.dart';

/// Raised when a .zabak file cannot be decrypted: wrong passphrase or a
/// tampered/corrupted file (the HMAC check fails for both).
class BackupAuthException implements Exception {
  const BackupAuthException();

  @override
  String toString() => 'BackupAuthException';
}

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of a successful restore: what the file actually contained, so the
/// UI can tell the user what changed.
class BackupRestoreResult {
  const BackupRestoreResult({
    required this.sessions,
    required this.settingsApplied,
    required this.contextEntries,
  });

  final int sessions;
  final bool settingsApplied;
  final int contextEntries;
}

/// Encrypted, single-file backup & restore of the whole app state
/// (v1.17.0): settings (provider presets + keys), every chat session and
/// the Context Manager entries.
///
/// File format (`.zabak`, UTF-8 text):
/// ```
/// ZABAK1
/// <base64( salt[16] | iv[16] | AES-256-CBC(payload, PKCS7) | HMAC-SHA256 )>
/// ```
/// The key is derived with PBKDF2-HMAC-SHA256 (150k iterations): the first
/// 32 bytes encrypt, the last 32 authenticate. Encrypt-then-MAC — the HMAC
/// is verified BEFORE any decryption, so a wrong passphrase or a tampered
/// file is rejected without ever exposing plaintext.
class BackupService {
  BackupService({
    required this.store,
    required this.settingsRepository,
    required this.contextRepository,
    required this.resolveBaseDir,
    this.offloadIsolate = true,
  });

  final ChatStore store;
  final SettingsRepository settingsRepository;
  final ContextRepository contextRepository;
  final Future<Directory> Function() resolveBaseDir;

  /// Like [ChatStore.offloadIsolate]: production crypto runs in a
  /// background isolate; widget tests flip this off (FakeAsync zones
  /// cannot service real isolate replies).
  final bool offloadIsolate;

  Future<T> _offload<T>(T Function() work) =>
      offloadIsolate ? Isolate.run(work) : Future<T>.value(work());

  static const String magic = 'ZABAK1';
  static const int _saltBytes = 16;
  static const int _ivBytes = 16;
  static const int _iterations = 150000;
  static const int _keyBytes = 64; // 32 encryption + 32 mac

  /// Gathers everything and writes `<docs>/exports/backup-<stamp>.zabak`.
  /// Returns the written file.
  Future<File> createBackup({
    required String passphrase,
    Uint8List? saltOverride, // tests: deterministic file
  }) async {
    if (passphrase.isEmpty) {
      throw ArgumentError.value(passphrase, 'passphrase', 'must not be empty');
    }
    final AppSettings settings = settingsRepository.load();
    final List<ContextEntry> context = contextRepository.load();

    final List<Map<String, dynamic>> sessions = <Map<String, dynamic>>[];
    for (final ChatSummary summary in await store.listSummaries()) {
      final List<ChatMessage>? messages = await store.load(summary.id);
      if (messages == null) continue; // corrupted: skip silently
      sessions.add(<String, dynamic>{
        'id': summary.id,
        'title': summary.title,
        'updatedAt': summary.updatedAt.toIso8601String(),
        'messages': messages.map((ChatMessage m) => m.toJson()).toList(),
      });
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'app': 'Noah',
      'format': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'settings': settings.toJson(),
      'context': <Map<String, dynamic>>[
        for (final ContextEntry e in context) e.toJson(),
      ],
      'sessions': sessions,
    };

    // ANR hardening (v1.28.0): PBKDF2-HMAC-SHA256 with 150k iterations plus
    // the AES pass take seconds of pure CPU on a phone — running them on
    // the main isolate froze the whole app ("app isn't responding"). The
    // closure works on bytes/strings only, all isolate-sendable.
    // v1.34.0: the whole-app jsonEncode + utf8 encode moved INSIDE the
    // worker isolate too — a multi-megabyte payload used to encode on the
    // UI isolate before the crypto even started.
    final Uint8List body = await _offload(() {
      final Uint8List payloadBytes = utf8.encode(jsonEncode(payload));
      final Uint8List salt = saltOverride ?? _randomBytes(_saltBytes);
      final Uint8List keys = _deriveKeys(passphrase, salt);
      final Uint8List encKey = keys.sublist(0, 32);
      final Uint8List macKey = keys.sublist(32, 64);
      final Uint8List iv = _randomBytes(_ivBytes);
      final Uint8List cipherText = _aesCbc(
        payloadBytes,
        encKey,
        iv,
        encrypt: true,
      );
      final Uint8List mac = _hmac(macKey, <Uint8List>[salt, iv, cipherText]);
      return <Uint8List>[salt, iv, cipherText, mac].fold<BytesBuilder>(
        BytesBuilder(),
        (BytesBuilder b, Uint8List part) {
          b.add(part);
          return b;
        },
      ).takeBytes();
    });

    final Directory base = await resolveBaseDir();
    final Directory exportsDir = Directory(
      '${base.path}${Platform.pathSeparator}exports',
    );
    if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
    final String stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final File file = File(
      '${exportsDir.path}${Platform.pathSeparator}backup-$stamp.zabak',
    );
    await file.writeAsString('$magic\n${base64Encode(body)}\n', flush: true);
    return file;
  }

  /// Verifies + decrypts a .zabak file and REPLACES the current app state
  /// with it (chats are cleared, settings and contexts overwritten).
  Future<BackupRestoreResult> restore(
    String filePath, {
    required String passphrase,
  }) async {
    if (passphrase.isEmpty) {
      throw ArgumentError.value(passphrase, 'passphrase', 'must not be empty');
    }
    final List<String> lines = await File(filePath).readAsLines();
    if (lines.isEmpty || lines.first.trim() != magic) {
      throw const BackupFormatException('Not a Noah backup file');
    }
    final Uint8List body = _decodeBody(lines.length > 1 ? lines[1] : '');
    if (body.length < _saltBytes + _ivBytes + 32) {
      throw const BackupFormatException('Backup file is truncated');
    }
    final Uint8List salt = body.sublist(0, _saltBytes);
    final Uint8List iv = body.sublist(_saltBytes, _saltBytes + _ivBytes);
    final Uint8List mac = body.sublist(body.length - 32);
    final Uint8List cipherText = body.sublist(
      _saltBytes + _ivBytes,
      body.length - 32,
    );

    // Verify + decrypt OFF the main isolate (PBKDF2 again) — the plaintext
    // never leaves the closure, only the decoded JSON map travels back.
    final Object? decoded;
    try {
      decoded = await _offload(() {
        final Uint8List keys = _deriveKeys(passphrase, salt);
        final Uint8List macKey = keys.sublist(32, 64);
        final Uint8List expected = _hmac(macKey, <Uint8List>[
          salt,
          iv,
          cipherText,
        ]);
        if (!_constantTimeEquals(expected, mac)) {
          return const _RestoreCryptoResult.auth();
        }
        final Uint8List encKey = keys.sublist(0, 32);
        final Uint8List plain = _aesCbc(cipherText, encKey, iv, encrypt: false);
        try {
          return _RestoreCryptoResult.payload(jsonDecode(utf8.decode(plain)));
        } catch (_) {
          return const _RestoreCryptoResult.format();
        }
      });
    } catch (_) {
      throw const BackupFormatException('Backup payload is corrupted');
    }
    if (decoded is! _RestoreCryptoResult) {
      throw const BackupFormatException('Backup payload is corrupted');
    }
    if (decoded.authFailed) throw const BackupAuthException();
    if (decoded.formatFailed || decoded.payload is! Map<String, dynamic>) {
      throw const BackupFormatException('Backup payload is corrupted');
    }
    final Map<String, dynamic> payloadMap = decoded.payload!;
    if (payloadMap['app'] != 'Noah' && payloadMap['app'] != 'ZAgents') {
      throw const BackupFormatException('Not a Noah backup file');
    }

    // Replace settings.
    var settingsApplied = false;
    final Object? rawSettings = payloadMap['settings'];
    if (rawSettings is Map<String, dynamic>) {
      await settingsRepository.save(AppSettings.fromJson(rawSettings));
      settingsApplied = true;
    }

    // Replace context entries.
    var contextCount = 0;
    final Object? rawContext = payloadMap['context'];
    if (rawContext is List) {
      final List<ContextEntry> entries = <ContextEntry>[
        for (final Object? item in rawContext)
          if (item is Map<String, dynamic>) ContextEntry.fromJson(item),
      ];
      await contextRepository.save(entries);
      contextCount = entries.length;
    }

    // Replace chats: drop everything that exists, then save every session
    // from the backup with its ORIGINAL id.
    for (final ChatSummary existing in await store.listSummaries()) {
      await store.delete(existing.id);
    }
    var sessionCount = 0;
    final Object? rawSessions = payloadMap['sessions'];
    if (rawSessions is List) {
      for (final Object? rawSession in rawSessions) {
        if (rawSession is! Map<String, dynamic>) continue;
        final String id = rawSession['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final Object? rawMessages = rawSession['messages'];
        if (rawMessages is! List) continue;
        final List<ChatMessage> messages = <ChatMessage>[
          for (final Object? m in rawMessages)
            if (m is Map<String, dynamic>) ChatMessage.fromJson(m),
        ];
        await store.save(
          id: id,
          title: rawSession['title']?.toString() ?? 'Restored',
          messages: messages,
        );
        sessionCount++;
      }
    }

    return BackupRestoreResult(
      sessions: sessionCount,
      settingsApplied: settingsApplied,
      contextEntries: contextCount,
    );
  }

  // -- crypto helpers -----------------------------------------------------

  static Uint8List _randomBytes(int length) {
    final FortunaRandom random = FortunaRandom()
      ..seed(
        pc.KeyParameter(
          Uint8List.fromList(
            List<int>.generate(32, (_) => Random.secure().nextInt(256)),
          ),
        ),
      );
    return random.nextBytes(length);
  }

  static Uint8List _deriveKeys(String passphrase, Uint8List salt) {
    final PBKDF2KeyDerivator derivator = PBKDF2KeyDerivator(
      HMac(SHA256Digest(), 64),
    );
    derivator.init(Pbkdf2Parameters(salt, _iterations, _keyBytes));
    return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  static Uint8List _aesCbc(
    List<int> input,
    Uint8List key,
    Uint8List iv, {
    required bool encrypt,
  }) {
    final pc.PaddedBlockCipher cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      encrypt,
      pc.PaddedBlockCipherParameters(
        pc.ParametersWithIV(pc.KeyParameter(key), iv),
        null,
      ),
    );
    return cipher.process(Uint8List.fromList(input));
  }

  static Uint8List _hmac(Uint8List key, List<Uint8List> parts) {
    final HMac mac = HMac(SHA256Digest(), 32)..init(pc.KeyParameter(key));
    for (final Uint8List part in parts) {
      mac.update(part, 0, part.length);
    }
    final Uint8List out = Uint8List(32);
    mac.doFinal(out, 0);
    return out;
  }

  static Uint8List _decodeBody(String base64Body) {
    try {
      return base64Decode(base64Body.trim());
    } catch (_) {
      throw const BackupFormatException('Backup body is not valid base64');
    }
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Result envelope crossing the restore isolate boundary: the crypto
/// verdict plus the decoded payload map (null unless the file decrypted
/// cleanly). A tagged object instead of a bare dynamic keeps the
/// type-switch on the main side explicit.
class _RestoreCryptoResult {
  const _RestoreCryptoResult._(
    this.authFailed,
    this.formatFailed,
    this.payload,
  );

  const _RestoreCryptoResult.auth() : this._(true, false, null);
  const _RestoreCryptoResult.format() : this._(false, true, null);
  const _RestoreCryptoResult.payload(Map<String, dynamic> map)
    : this._(false, false, map);

  final bool authFailed;
  final bool formatFailed;
  final Map<String, dynamic>? payload;
}
