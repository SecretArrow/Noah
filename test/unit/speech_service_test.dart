import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:noah/services/speech_service.dart';

/// Minimal fake implementing the public `SpeechToText` interface that
/// [SpeechService] uses. Everything is driven synchronously by the tests —
/// no platform channels involved.
class _FakeSpeechToText implements SpeechToText {
  _FakeSpeechToText({this.initResult = true, this.initThrows = false});

  /// Value returned by [initialize] (when [initThrows] is false).
  final bool initResult;

  /// When true, [initialize] throws instead of returning [initResult].
  final bool initThrows;

  @override
  SpeechErrorListener? errorListener;
  @override
  SpeechStatusListener? statusListener;
  SpeechResultListener? resultListener;

  SpeechRecognitionError? lastEmittedError;
  String lastStatusValue = '';
  bool throwingListen = false;
  int initializeCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  final List<String?> listenLocaleIds = <String?>[];
  bool _listening = false;

  /// Test drivers that replay plugin events onto captured listeners.
  void emitResult(SpeechRecognitionResult result) =>
      resultListener?.call(result);

  void emitStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      _listening = true;
    } else if (status == SpeechToText.notListeningStatus ||
        status == SpeechToText.doneStatus) {
      _listening = false;
    }
    lastStatusValue = status;
    statusListener?.call(status);
  }

  void emitError(SpeechRecognitionError error) {
    lastEmittedError = error;
    errorListener?.call(error);
  }

  SpeechRecognitionResult resultOf(String words, bool finalResult) =>
      SpeechRecognitionResult(<SpeechRecognitionWords>[
        SpeechRecognitionWords(words, null, -1),
      ], finalResult ? ResultType.finalResult.value : ResultType.partial.value);

  // ---- SpeechToText interface -------------------------------

  @override
  SpeechPhraseAggregator? unexpectedPhraseAggregator;

  @override
  bool get hasRecognized => false;

  @override
  String get lastRecognizedWords => '';

  @override
  String get lastStatus => lastStatusValue;

  @override
  double get lastSoundLevel => 0;

  @override
  bool get isAvailable => initResult;

  @override
  bool get isListening => _listening;

  @override
  bool get isNotListening => !_listening;

  @override
  SpeechRecognitionError? get lastError => lastEmittedError;

  @override
  bool get hasError => lastEmittedError != null;

  @override
  Future<bool> get hasPermission async => true;

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<SpeechConfigOption>? options,
  }) async {
    initializeCalls++;
    errorListener = onError;
    statusListener = onStatus;
    if (initThrows) {
      throw StateError('init crashed');
    }
    return initResult;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    _listening = false;
  }

  @override
  Future<void> listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    dynamic sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    listenCalls++;
    if (throwingListen) {
      throw ListenFailedException('listen failed');
    }
    resultListener = onResult;
    listenLocaleIds.add(listenOptions?.localeId ?? localeId);
    _listening = true;
  }

  @override
  void changePauseFor(Duration pauseFor) {}

  @override
  Future<List<LocaleName>> locales() async => const <LocaleName>[];

  @override
  Future<LocaleName?> systemLocale() async => null;
}

void main() {
  group('resolvedSpeechLocale', () {
    test('maps supported app language codes to full locales', () {
      expect(resolvedSpeechLocale('en'), 'en_US');
      expect(resolvedSpeechLocale('id'), 'id_ID');
      expect(resolvedSpeechLocale('es'), 'es_ES');
    });

    test('falls back to en_US for unknown or empty codes', () {
      expect(resolvedSpeechLocale('fr'), 'en_US');
      expect(resolvedSpeechLocale('pt_BR'), 'en_US');
      expect(resolvedSpeechLocale(''), 'en_US');
      expect(resolvedSpeechLocale('  '), 'en_US');
    });

    test('is case-insensitive and tolerates region suffixes', () {
      expect(resolvedSpeechLocale('EN'), 'en_US');
      expect(resolvedSpeechLocale('id-ID'), 'id_ID');
      expect(resolvedSpeechLocale(' ES '), 'es_ES');
    });
  });

  group('ensureReady', () {
    test(
      'returns ready when initialize succeeds, once and idempotent',
      () async {
        final _FakeSpeechToText fake = _FakeSpeechToText();
        final SpeechService service = SpeechService(stt: fake);

        expect(await service.ensureReady(), SpeechAvailability.ready);
        expect(await service.ensureReady(), SpeechAvailability.ready);
        expect(fake.initializeCalls, 1);
      },
    );

    test('reports unavailable when the device has no STT engine', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText(initResult: false);
      final SpeechService service = SpeechService(stt: fake);

      expect(await service.ensureReady(), SpeechAvailability.unavailable);
    });

    test('reports notAuthorized when permission is denied', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText(initResult: false);
      fake.lastEmittedError = SpeechRecognitionError('error_permission', true);
      final SpeechService service = SpeechService(stt: fake);

      expect(await service.ensureReady(), SpeechAvailability.notAuthorized);
    });

    test(
      'maps an initialize crash to unavailable instead of throwing',
      () async {
        final _FakeSpeechToText fake = _FakeSpeechToText(initThrows: true);
        final SpeechService service = SpeechService(stt: fake);

        expect(await service.ensureReady(), SpeechAvailability.unavailable);
      },
    );
  });

  group('start / result callbacks', () {
    test('forwards partials verbatim and final results replace', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      final List<(String, bool)> events = <(String, bool)>[];
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) =>
            events.add((text, finalResult)),
      );

      fake.emitResult(fake.resultOf('hal', false));
      fake.emitResult(fake.resultOf('halo', false));
      fake.emitResult(fake.resultOf('halo dunia', true));

      expect(events, <(String, bool)>[
        ('hal', false),
        ('halo', false),
        ('halo dunia', true),
      ]);
    });

    test('partials never bake into the accumulated final text', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      String lastFinalText = '';
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {
          if (finalResult) lastFinalText = text;
        },
      );

      fake.emitResult(fake.resultOf('temp', false));
      fake.emitResult(fake.resultOf('halo dunia', true));

      expect(lastFinalText, 'halo dunia');
      expect(lastFinalText, isNot('temp halo dunia'));
    });

    test('two consecutive finals replace instead of doubling', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      final List<String> finals = <String>[];
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {
          if (finalResult) finals.add(text);
        },
      );

      fake.emitResult(fake.resultOf('satu', true));
      fake.emitResult(fake.resultOf('satu dua', true));

      // The last final wins; the duplicate/cumulative re-delivery must not
      // be appended ("satu satu dua" would be the append bug).
      expect(finals, <String>['satu', 'satu dua']);
      expect(finals.last, 'satu dua');
      expect(finals.last, isNot('satu satu dua'));
    });

    test('partials arriving after a final do not corrupt it', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      String lastFinalText = '';
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {
          if (finalResult) lastFinalText = text;
        },
      );

      fake.emitResult(fake.resultOf('satu', true));
      fake.emitResult(fake.resultOf('satu du', false));
      expect(lastFinalText, 'satu');

      fake.emitResult(fake.resultOf('satu dua', true));
      expect(lastFinalText, 'satu dua');
      expect(lastFinalText, isNot('satu satu dua'));
    });

    test('start resolves the app locale through the plugin options', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      await service.start(
        localeCode: 'id',
        onResult: (String text, bool finalResult) {},
      );

      expect(fake.listenCalls, 1);
      expect(fake.listenLocaleIds.single, 'id_ID');
    });

    test('start while listening stops the previous session first', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      int firstEnd = 0;
      int secondEnd = 0;
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {},
        onEnd: () => firstEnd++,
      );
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {},
        onEnd: () => secondEnd++,
      );

      expect(firstEnd, 1);
      expect(secondEnd, 0);
      expect(service.isListening, isTrue);
      expect(fake.stopCalls, 1);
    });

    test('start when unavailable ends immediately with onEnd', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText(initResult: false);
      final SpeechService service = SpeechService(stt: fake);
      int endCount = 0;
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {},
        onEnd: () => endCount++,
      );

      expect(endCount, 1);
      expect(service.isListening, isFalse);
      expect(fake.listenCalls, 0);
    });

    test('a listen failure ends the session instead of throwing', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      fake.throwingListen = true;
      final SpeechService service = SpeechService(stt: fake);
      int endCount = 0;
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {},
        onEnd: () => endCount++,
      );

      expect(service.isListening, isFalse);
      expect(endCount, 1);
    });
  });

  group('isListening lifecycle', () {
    test('true after start, false after stop, onEnd exactly once', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      int endCount = 0;
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {},
        onEnd: () => endCount++,
      );
      expect(service.isListening, isTrue);

      await service.stop();
      expect(service.isListening, isFalse);
      expect(endCount, 1);
      expect(fake.stopCalls, 1);

      // stop() when already stopped is a no-op — no extra onEnd.
      await service.stop();
      expect(endCount, 1);
    });

    test('stop() before any start is a harmless no-op', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);

      await service.stop();

      expect(service.isListening, isFalse);
      expect(fake.stopCalls, 0);
    });

    test('onEnd fires once on the done status', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      int endCount = 0;
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {},
        onEnd: () => endCount++,
      );

      fake.emitStatus(SpeechToText.doneStatus);
      expect(service.isListening, isFalse);
      expect(endCount, 1);

      // The plugin may re-deliver done — the end stays at exactly one.
      fake.emitStatus(SpeechToText.doneStatus);
      expect(endCount, 1);
    });

    test('onEnd fires exactly once when an error ends the session', () async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final SpeechService service = SpeechService(stt: fake);
      int endCount = 0;
      await service.start(
        localeCode: 'en',
        onResult: (String text, bool finalResult) {},
        onEnd: () => endCount++,
      );

      fake.emitError(SpeechRecognitionError('error_network_timeout', true));
      expect(service.isListening, isFalse);
      expect(endCount, 1);

      // cancelOnError also produces a done status afterwards — still once.
      fake.emitStatus(SpeechToText.doneStatus);
      expect(endCount, 1);
    });

    test(
      'a permission error downgrades availability to notAuthorized',
      () async {
        final _FakeSpeechToText fake = _FakeSpeechToText();
        final SpeechService service = SpeechService(stt: fake);
        await service.start(
          localeCode: 'en',
          onResult: (String text, bool finalResult) {},
          onEnd: () {},
        );

        fake.emitError(SpeechRecognitionError('error_permission', true));

        expect(await service.ensureReady(), SpeechAvailability.notAuthorized);
      },
    );
  });
}
