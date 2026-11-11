import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/services/speech_service.dart';
import 'package:noah/ui/widgets/composer.dart';
import 'package:noah/ui/widgets/composer_actions.dart';

import '../support/test_doubles.dart';

/// Minimal fake implementing the public `SpeechToText` interface that
/// [SpeechService] uses (same pattern as test/unit/speech_service_test.dart)
/// — everything is driven synchronously by the tests, no platform channels.
class _FakeSpeechToText implements SpeechToText {
  @override
  SpeechErrorListener? errorListener;
  @override
  SpeechStatusListener? statusListener;
  SpeechResultListener? resultListener;

  SpeechRecognitionError? lastEmittedError;
  String lastStatusValue = '';
  int initializeCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  final List<String?> listenLocaleIds = <String?>[];
  bool _listening = false;

  /// Test drivers that replay plugin events onto the captured listeners.
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
  bool get isAvailable => true;

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
    return true;
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
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('composer_actions_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// Pumps the real Composer and hands back the scope's [ProviderContainer]
  /// so the tests can drive the shared controller directly.
  Future<ProviderContainer> pumpComposer(
    WidgetTester tester, {
    List<Override> extra = const <Override>[],
  }) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(dir: tempDir, writeScreenshots: false),
          ...extra,
        ],
        child: Builder(
          builder: (BuildContext context) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                zLocalizationsDelegate,
              ],
              supportedLocales: const <Locale>[Locale('en'), Locale('id')],
              home: const Scaffold(body: Composer()),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  TextEditingController fieldController(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('composer-field')))
      .controller!;

  group('insertText / insertDictation', () {
    testWidgets('insertText appends prompt content into the field, '
        'newline-joined with the caret parked at the end', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = await pumpComposer(tester);
      final ComposerActionsController actions = container.read(
        composerActionsProvider.notifier,
      );

      actions.insertText('First prompt');
      await tester.pump();
      final TextEditingController controller = fieldController(tester);
      expect(controller.text, 'First prompt');
      expect(
        controller.selection,
        const TextSelection.collapsed(offset: 'First prompt'.length),
      );

      actions.insertText('Second');
      await tester.pump();
      expect(controller.text, 'First prompt\nSecond');
      expect(
        controller.selection,
        const TextSelection.collapsed(offset: 'First prompt\nSecond'.length),
      );

      // An empty field receives the content verbatim (no leading newline).
      controller.clear();
      actions.insertText('Only');
      await tester.pump();
      expect(controller.text, 'Only');
    });

    testWidgets('insertDictation (final speech result) space-joins instead '
        'of newline-joining', (WidgetTester tester) async {
      final ProviderContainer container = await pumpComposer(tester);
      final ComposerActionsController actions = container.read(
        composerActionsProvider.notifier,
      );

      actions.insertDictation('hello');
      await tester.pump();
      final TextEditingController controller = fieldController(tester);
      expect(controller.text, 'hello');

      actions.insertDictation('world one');
      await tester.pump();
      expect(controller.text, 'hello world one');
    });

    testWidgets('with no composer bound, insertText falls back to the '
        'ACTIVE chat draft store', (WidgetTester tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          child: Builder(
            builder: (BuildContext context) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                locale: const Locale('en'),
                localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                  zLocalizationsDelegate,
                ],
                supportedLocales: const <Locale>[Locale('en'), Locale('id')],
                home: Scaffold(
                  body: SizedBox.shrink(key: const Key('placeholder')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();

      container
          .read(composerActionsProvider.notifier)
          .insertText('orphan words');
      await tester.pump();

      expect(
        container.read(chatControllerProvider.notifier).draftTextFor(null),
        'orphan words',
      );
    });
  });

  group('mic toggle (shared dictation state)', () {
    testWidgets('tap starts a session: listening flips, the preview row '
        'appears, finals land in the field, second tap stops', (
      WidgetTester tester,
    ) async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final ProviderContainer container = await pumpComposer(
        tester,
        extra: <Override>[
          speechServiceProvider.overrideWithValue(SpeechService(stt: fake)),
        ],
      );

      await tester.tap(find.byKey(const Key('mic-button')));
      await tester.pumpAndSettle();
      expect(fake.initializeCalls, 1);
      expect(fake.listenCalls, 1);
      expect(container.read(composerActionsProvider).listening, isTrue);
      expect(find.byKey(const Key('speech-listening-row')), findsOneWidget);
      final IconButton mic = tester.widget<IconButton>(
        find.byKey(const Key('mic-button')),
      );
      expect(
        mic.tooltip,
        const AppStringsEn().speechStop,
        reason: 'the mic control turns into a stop control',
      );

      // A final recognition result is appended to the field; a partial
      // only feeds the inline preview row.
      fake.emitResult(fake.resultOf('hello world', true));
      await tester.pump();
      expect(fieldController(tester).text, 'hello world');
      fake.emitResult(fake.resultOf('typing more', false));
      await tester.pump();
      expect(find.text('typing more'), findsOneWidget);
      expect(fieldController(tester).text, 'hello world');
      expect(
        container.read(composerActionsProvider).speechPartial,
        'typing more',
      );

      // Second tap stops the session.
      await tester.tap(find.byKey(const Key('mic-button')));
      await tester.pumpAndSettle();
      expect(fake.stopCalls, 1);
      expect(container.read(composerActionsProvider).listening, isFalse);
      expect(find.byKey(const Key('speech-listening-row')), findsNothing);
    });

    testWidgets('the end-of-session callback (platform done status) clears '
        'the listening state without a tap', (WidgetTester tester) async {
      final _FakeSpeechToText fake = _FakeSpeechToText();
      final ProviderContainer container = await pumpComposer(
        tester,
        extra: <Override>[
          speechServiceProvider.overrideWithValue(SpeechService(stt: fake)),
        ],
      );

      await tester.tap(find.byKey(const Key('mic-button')));
      await tester.pumpAndSettle();
      expect(container.read(composerActionsProvider).listening, isTrue);

      fake.emitStatus(SpeechToText.doneStatus);
      await tester.pumpAndSettle();
      expect(container.read(composerActionsProvider).listening, isFalse);
      expect(find.byKey(const Key('speech-listening-row')), findsNothing);
    });
  });

  group('attach (picker path)', () {
    // file_selector's Pigeon channel never answers inside the test zone —
    // the await would hang forever and leave the picking spinner spinning
    // (pumpAndSettle timeout). The platform instance is swapped for a
    // synchronous fake instead: same production surface, deterministic
    // replies. The finally block in [ComposerActionsController.pickFile]
    // must ALWAYS clear the in-flight flag, whatever the picker does.
    testWidgets('a canceled picker clears the picking state and surfaces '
        'no error', (WidgetTester tester) async {
      FileSelectorPlatform.instance = _CanceledFileSelector();
      final ProviderContainer container = await pumpComposer(tester);

      await tester.tap(find.byKey(const Key('attach-button')));
      await tester.pumpAndSettle();

      expect(container.read(composerActionsProvider).picking, isFalse);
      expect(find.text(const AppStringsEn().operationFailed), findsNothing);
      // The paperclip is back (no spinner stuck in the icon slot).
      final IconButton attach = tester.widget<IconButton>(
        find.byKey(const Key('attach-button')),
      );
      expect(attach.onPressed, isNotNull);
    });

    testWidgets('a failing picker surfaces the failure snackbar and the '
        'picking state clears', (WidgetTester tester) async {
      FileSelectorPlatform.instance = _ThrowingFileSelector();
      final ProviderContainer container = await pumpComposer(tester);

      await tester.tap(find.byKey(const Key('attach-button')));
      await tester.pumpAndSettle();

      expect(container.read(composerActionsProvider).picking, isFalse);
      expect(find.text(const AppStringsEn().operationFailed), findsOneWidget);
      final IconButton attach = tester.widget<IconButton>(
        find.byKey(const Key('attach-button')),
      );
      expect(attach.onPressed, isNotNull);
    });
  });
}

/// Deterministic [FileSelectorPlatform] stand-ins (see the group doc):
/// the real Pigeon channel cannot answer inside the widget-test zone.
class _CanceledFileSelector extends FileSelectorPlatform {
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => null;
}

class _ThrowingFileSelector extends FileSelectorPlatform {
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => throw Exception('picker unavailable');
}
