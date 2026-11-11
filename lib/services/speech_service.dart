import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Shape-compatible stand-in for Flutter's `VoidCallback` so this file has
/// no direct dependency on the Flutter framework.
typedef VoidCallbackLike = void Function();

/// Lifecycle state of the underlying speech recognition engine.
///
/// * [unavailable] — the device has no usable speech recognition service
///   (for example an Android device without a recognizer / Google app) or
///   initialization failed for a non-permission reason. The UI should hide
///   the dictation button.
/// * [notAuthorized] — microphone / speech permission was denied. The UI
///   should hide the button (or route the user to system settings).
/// * [ready] — initialization succeeded; [SpeechService.start] may be used.
enum SpeechAvailability { unavailable, notAuthorized, ready }

/// Language-code → full-locale mapping used by [resolvedSpeechLocale].
///
/// 'es' is already mapped even though the app ships 'en' and 'id' first
/// (see `lib/l10n/app_strings.dart`); Spanish support is planned.
const Map<String, String> _speechLocaleByLanguage = <String, String>{
  'en': 'en_US',
  'id': 'id_ID',
  'es': 'es_ES',
};

/// Maps an app language code ('en', 'id', 'es') to the full locale id
/// expected by `package:speech_to_text` (`en_US`, `id_ID`, `es_ES`).
///
/// Matching is case-insensitive and tolerant of region suffixes, so both
/// 'id' and 'id-ID' resolve to 'id_ID'. Unknown or empty codes fall back
/// to 'en_US' (the app's default language) so recognition always receives
/// a usable locale.
String resolvedSpeechLocale(String code) {
  final String language = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  return _speechLocaleByLanguage[language] ?? 'en_US';
}

/// Voice dictation service for the chat composer.
///
/// Thin wrapper around `package:speech_to_text` (the [SpeechToText]
/// instance is injected in the constructor so tests can supply a fake)
/// with a small, documented contract:
///
/// ### Initialization — [ensureReady]
/// * `initialize()` (which also triggers the permission prompt) runs at
///   most ONCE per [SpeechService] instance. The resulting
///   [SpeechAvailability] is cached and concurrent callers share the same
///   in-flight future, making the call idempotent. Errors never propagate
///   to the caller.
/// * A failed/throwing initialization maps to
///   [SpeechAvailability.unavailable] unless the plugin reported a
///   permission error (`error_permission`,
///   `error_insufficient_permissions`), which maps to
///   [SpeechAvailability.notAuthorized].
///
/// ### Recognition — [start]
/// Result callback contract (the `onResult` argument of [start]):
/// * **Final results** (`finalResult == true`) are the only results that
///   contribute to the accumulated text; each final REPLACES the previous
///   accumulated text instead of being appended. This matches platforms
///   that re-deliver cumulative finals and guarantees that repeated or
///   duplicate finals never double the text: two consecutive finals always
///   yield the text of the LAST one, never a doubled concatenation.
/// * **Partial results** (`finalResult == false`) are forwarded verbatim
///   as provisional text and never touch the accumulated text. The UI
///   should display the text of the most recent callback.
/// * The platform may still deliver one final result AFTER [onEnd] (the
///   final flush that follows [stop] or an error); the UI must tolerate
///   that late `(text, true)` callback.
///
/// [onEnd] fires EXACTLY ONCE per [start] session, at the earliest of:
/// an explicit [stop], the platform `done` status (all results delivered —
/// this includes the end-of-speech timeout), or a platform error. It also
/// fires directly from [start] when recognition is not
/// [SpeechAvailability.ready], so the UI never gets stuck in a "listening"
/// state.
///
/// [isListening] mirrors the service's own session state (true from a
/// successful [start] until [stop], a `notListening`/`done` status, or an
/// error) and is deliberately independent of the plugin's internal flag.
class SpeechService {
  SpeechService({SpeechToText? stt}) : _stt = stt ?? SpeechToText();

  final SpeechToText _stt;

  SpeechAvailability? _availability;
  Future<SpeechAvailability>? _pendingReady;

  bool _listening = false;
  bool _endNotified = false;
  String _finalText = '';
  void Function(String text, bool finalResult)? _onResult;
  VoidCallbackLike? _onEnd;

  /// True while a dictation session started by [start] is running; false
  /// once [stop] is called, the session completes (platform `done` status /
  /// end-of-speech timeout) or the session fails.
  bool get isListening => _listening;

  /// Initializes the engine (and triggers the permission prompt) at most
  /// once per instance; later calls return the cached result immediately.
  Future<SpeechAvailability> ensureReady() {
    final SpeechAvailability? cached = _availability;
    if (cached != null) {
      return Future<SpeechAvailability>.value(cached);
    }
    return _pendingReady ??= _initialize();
  }

  /// Starts (or restarts) a dictation session for [localeCode] ('en',
  /// 'id', 'es' — resolved through [resolvedSpeechLocale]).
  ///
  /// Results are delivered through [onResult] per the class-doc contract;
  /// [onEnd] fires exactly once when the session is over. When recognition
  /// is not [SpeechAvailability.ready] the session ends immediately
  /// ([onEnd] fires without any result and nothing is listened to).
  /// Calling [start] while a session is active first stops that previous
  /// session (its [onEnd] still fires).
  Future<void> start({
    required String localeCode,
    required void Function(String text, bool finalResult) onResult,
    VoidCallbackLike? onEnd,
  }) async {
    final SpeechAvailability availability = await ensureReady();
    if (availability != SpeechAvailability.ready) {
      _runGuarded(onEnd);
      return;
    }
    if (_listening) await stop();
    _onResult = onResult;
    _onEnd = onEnd;
    _finalText = '';
    _endNotified = false;
    _listening = true;
    try {
      await _stt.listen(
        onResult: _onPlatformResult,
        listenOptions: SpeechListenOptions(
          cancelOnError: true,
          partialResults: true,
          listenMode: ListenMode.dictation,
          localeId: resolvedSpeechLocale(localeCode),
        ),
      );
    } catch (_) {
      // Engine refused to start (busy, missing engine, channel error) —
      // end the session instead of throwing into the UI.
      _listening = false;
      _notifyEnd();
    }
  }

  /// Stops the active session. A no-op (that does NOT fire [onEnd]) when
  /// nothing is listening — there is no session to end. The platform may
  /// still deliver a final result after this returns.
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    try {
      await _stt.stop();
    } catch (_) {
      // The session is over for the UI regardless.
    }
    _notifyEnd();
  }

  /// Final results replace the accumulated text (never append); partials
  /// are forwarded verbatim without touching the accumulation.
  void _onPlatformResult(SpeechRecognitionResult result) {
    final void Function(String text, bool finalResult)? onResult = _onResult;
    if (onResult == null) return;
    final String words = result.recognizedWords;
    if (result.finalResult) {
      _finalText = words;
      _runGuarded(() => onResult(_finalText, true));
    } else {
      _runGuarded(() => onResult(words, false));
    }
  }

  void _onPlatformStatus(String status) {
    switch (status) {
      case SpeechToText.listeningStatus:
        _listening = true;
      case SpeechToText.notListeningStatus:
        // Microphone closed but the final result may still be flushed —
        // wait for `done` / error / stop before notifying the end.
        _listening = false;
      case SpeechToText.doneStatus:
        _listening = false;
        _notifyEnd();
    }
  }

  void _onPlatformError(SpeechRecognitionError error) {
    if (_isPermissionError(error.errorMsg)) {
      _availability = SpeechAvailability.notAuthorized;
    }
    // Any error ends the current session (cancelOnError is enabled).
    // Non-permission errors deliberately do NOT downgrade the cached
    // availability — transient failures (no match, busy, network) must
    // not hide the dictation button for the rest of the app run.
    _listening = false;
    _notifyEnd();
  }

  Future<SpeechAvailability> _initialize() async {
    try {
      final bool ok = await _stt.initialize(
        onError: _onPlatformError,
        onStatus: _onPlatformStatus,
      );
      _availability = ok
          ? SpeechAvailability.ready
          : _availabilityFromFailure();
    } catch (_) {
      _availability = _availabilityFromFailure();
    }
    return _availability!;
  }

  SpeechAvailability _availabilityFromFailure() {
    final SpeechRecognitionError? error = _stt.lastError;
    if (error != null && _isPermissionError(error.errorMsg)) {
      return SpeechAvailability.notAuthorized;
    }
    return SpeechAvailability.unavailable;
  }

  bool _isPermissionError(String message) =>
      message == 'error_permission' ||
      message == 'error_insufficient_permissions';

  void _notifyEnd() {
    if (_endNotified) return;
    _endNotified = true;
    final VoidCallbackLike? onEnd = _onEnd;
    if (onEnd != null) _runGuarded(onEnd);
  }

  /// Runs a UI callback, swallowing its exceptions: a throwing composer
  /// callback must not kill the platform channel handler.
  void _runGuarded(VoidCallbackLike? callback) {
    if (callback == null) return;
    try {
      callback();
    } catch (_) {
      // Intentionally ignored — see doc comment.
    }
  }
}
