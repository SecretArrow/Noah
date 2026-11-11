import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/local_model.dart';
import 'package:noah/services/local_ai/llm_benchmark.dart'
    show BenchmarkRunState, BenchmarkRunStatus;
import 'package:noah/services/local_ai/llm_server_controller.dart'
    show FakeLlmServerPlatform;
import 'package:noah/services/local_ai/local_model_io.dart';
import 'package:noah/services/local_ai/local_model_store.dart'
    show MemoryLocalModelRepository;
import 'package:noah/services/local_ai/model_downloader.dart'
    show DownloadProgress, DownloadStatus, DownloadQueueController;
import 'package:noah/ui/screens/ollama_manage_screen.dart';

import '../../test/support/test_doubles.dart';

/// Recording stand-in for the download queue: starts with [initial] rows
/// (rendered by the Downloads tab) and records everything enqueued through
/// the Catalog buttons. No network, no disk — the real controller would
/// resolve registry refs over http.
class _FakeDownloadQueueController extends DownloadQueueController {
  _FakeDownloadQueueController([this.initial = const <DownloadProgress>[]]);

  final List<DownloadProgress> initial;
  final List<LocalModelEntry> enqueued = <LocalModelEntry>[];

  @override
  List<DownloadProgress> build() => initial;

  @override
  Future<String> modelsDirPath() async => '/tmp/local_models';

  @override
  Future<void> enqueue(LocalModelEntry entry) async {
    enqueued.add(entry);
  }

  @override
  Future<void> pause(String modelId) async {}

  @override
  Future<void> resume(String modelId) async {}

  @override
  Future<void> cancel(String modelId) async {}

  @override
  void clearFinished() {}
}

/// Recording stand-in for the bulk-export path: v1.52.0 wires the
/// “Export selected” button through `localModelIoProvider` — the provider
/// is already injectable, so tests spy by OVERRIDING `exportModels` on a
/// LocalModelIo subclass (Dart methods are virtual; no production shape
/// was changed to make this possible).
class _RecordingLocalModelIo extends LocalModelIo {
  _RecordingLocalModelIo(this.outcome);

  /// What exportModels reports (2 = happy path, 0 = graceful failure).
  final int outcome;

  final List<List<String>> exportCalls = <List<String>>[];

  @override
  Future<int> exportModels(List<LocalModelEntry> entries) async {
    exportCalls.add(<String>[for (final LocalModelEntry e in entries) e.id]);
    return outcome;
  }
}

/// MockClient serving the llama-server endpoints needed by the screen:
/// `/health` → 200 and `/v1/chat/completions` → canned SSE.
http.Client _llmEndpointsClient(String sseBody) =>
    MockClient((http.Request request) async {
      if (request.url.path.endsWith('/health')) {
        return http.Response('{"status":"ok"}', 200);
      }
      return http.Response(sseBody, 200);
    });

const String _benchmarkSse =
    ''
    'data: {"choices":[{"delta":{"content":"one two "}}]}\n'
    'data: {"choices":[{"delta":{"content":"three four "}}]}\n'
    'data: {"choices":[{"delta":{"content":"five"}}]}\n'
    'data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":20}}\n'
    'data: [DONE]\n';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('noah_ollama_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 15),
  );

  /// v1.49.6: feedback arrives as a centered modal dialog — acknowledge it
  /// via the OK button so the dialog barrier cannot swallow the next tap.
  Future<void> dismissAppMessage(WidgetTester tester) async {
    final Finder ok = find.byKey(const Key('app-message-ok'));
    if (ok.evaluate().isNotEmpty) {
      await tester.tap(ok);
      await settle(tester);
    }
  }

  /// The vertical catalog list. Two disambiguations: the screen owns the
  /// TabBarView's horizontal PageView scrollable (so a global
  /// `find.byType(Scrollable).first` would drag TABS, not the list), and
  /// the catalog subtree itself contains the custom-URL TextField's own
  /// horizontal Scrollable — the list's Scrollable is its ANCESTOR, so
  /// traversal reports it first and `.first` is unambiguous.
  Finder catalogScrollable() => find
      .descendant(
        of: find.byKey(const Key('ollama-catalog-list')),
        matching: find.byType(Scrollable),
      )
      .first;

  /// Pumps the app, navigates Settings → Local AI tile, and lands on the
  /// Ollama Manage screen with the in-memory model store pre-seeded with
  /// [installed], the scriptable platform fake and a recording download
  /// queue; returns the container. The REAL server controller runs against
  /// the fake platform (no method channel inside the test zone).
  Future<ProviderContainer> openOllamaScreen(
    WidgetTester tester, {
    List<LocalModelEntry> installed = const <LocalModelEntry>[],
    FakeLlmServerPlatform? platform,
    _FakeDownloadQueueController? queue,
    List<DownloadProgress> downloads = const <DownloadProgress>[],
    http.Client? httpClient,
    LocalModelIo? modelIo,
  }) async {
    late ProviderContainer container;
    final FakeLlmServerPlatform platformFake =
        platform ?? FakeLlmServerPlatform();
    final _FakeDownloadQueueController queueController =
        queue ?? _FakeDownloadQueueController(downloads);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(dir: tempDir),
          localModelRepositoryProvider.overrideWithValue(
            MemoryLocalModelRepository(LocalModelState(installed: installed)),
          ),
          llmServerPlatformProvider.overrideWithValue(platformFake),
          downloadQueueProvider.overrideWith(() => queueController),
          if (httpClient != null)
            llmHttpClientProvider.overrideWithValue(httpClient),
          if (modelIo != null) localModelIoProvider.overrideWithValue(modelIo),
        ],
        child: Builder(
          builder: (BuildContext context) {
            container = ProviderScope.containerOf(context);
            return const NoahApp();
          },
        ),
      ),
    );
    await tester.pump();

    // Navigate: Settings tab → the Local AI tile sits right below the
    // Cron jobs section (lazy ListView — reveal it before tapping).
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('ollama-manage-tile')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('ollama-manage-tile')));
    await settle(tester);
    expect(find.byType(OllamaManageScreen), findsOneWidget);
    return container;
  }

  testWidgets('renders all four tabs and switches between them', (
    WidgetTester tester,
  ) async {
    await openOllamaScreen(tester);

    // All four tabs are in the AppBar with their contract keys.
    expect(find.byKey(const Key('ollama-tab-server')), findsOneWidget);
    expect(find.byKey(const Key('ollama-tab-catalog')), findsOneWidget);
    expect(find.byKey(const Key('ollama-tab-installed')), findsOneWidget);
    expect(find.byKey(const Key('ollama-tab-downloads')), findsOneWidget);
    // The Server tab is active first — its list is on screen (the
    // TabBarView builds pages lazily; at most a cached neighbor exists).
    expect(find.byKey(const Key('ollama-server-list')), findsOneWidget);
    expect(
      find.byKey(const Key('ollama-server-list')).hitTestable(),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('ollama-tab-catalog')));
    await settle(tester);
    expect(find.byKey(const Key('ollama-catalog-list')), findsOneWidget);
    expect(find.byKey(const Key('ollama-custom-url')), findsOneWidget);
    expect(find.byKey(const Key('ollama-import')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ollama-tab-installed')));
    await settle(tester);
    expect(find.byKey(const Key('ollama-installed-empty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ollama-tab-downloads')));
    await settle(tester);
    expect(find.byKey(const Key('ollama-downloads-empty')), findsOneWidget);
  });

  testWidgets(
    'server tab shows the runtime-unavailable banner when the platform '
    'reports runtimeAvailable: false',
    (WidgetTester tester) async {
      // An armeabi-v7a-style build: the runtime .so is missing → the real
      // controller's refresh() maps it to the `unavailable` status.
      await openOllamaScreen(
        tester,
        platform: FakeLlmServerPlatform(available: false),
      );

      expect(
        find.byKey(const Key('ollama-unavailable-banner')),
        findsOneWidget,
      );
      expect(find.text('Unavailable'), findsOneWidget);
      final FilledButton start = tester.widget<FilledButton>(
        find.byKey(const Key('ollama-start')),
      );
      expect(start.onPressed, isNull);
      expect(find.byKey(const Key('ollama-stop')), findsNothing);
      // No models installed: the empty hint + catalog shortcut render.
      expect(find.byKey(const Key('ollama-model-empty')), findsOneWidget);
      expect(find.byKey(const Key('ollama-go-catalog')), findsOneWidget);
    },
  );

  testWidgets('catalog renders the model cards; tier-1 enqueues directly, '
      'upper-bound asks first', (WidgetTester tester) async {
    final _FakeDownloadQueueController queue = _FakeDownloadQueueController();
    await openOllamaScreen(tester, queue: queue);

    await tester.tap(find.byKey(const Key('ollama-tab-catalog')));
    await settle(tester);

    // First catalog card (tier 1) is on screen; its Download button
    // enqueues without any confirmation.
    expect(find.byKey(const Key('ollama-catalog-qwen3:0.6b')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ollama-download-qwen3:0.6b')));
    await settle(tester);
    expect(queue.enqueued, hasLength(1));
    expect(queue.enqueued.single.ollamaRef, 'qwen3:0.6b');
    expect(queue.enqueued.single.source, LocalModelSource.catalog);
    expect(queue.enqueued.single.name, 'qwen3:0.6b');
    expect(queue.enqueued.single.fileName, endsWith('.gguf'));

    // Acknowledge the queued feedback dialog before the next tap.
    await dismissAppMessage(tester);

    // The upper-bound card sits deep in the lazy list — drag it into
    // view (dragUntilVisible builds offscreen items).
    await tester.dragUntilVisible(
      find.byKey(const Key('ollama-download-minicpm5-2b')),
      catalogScrollable(),
      const Offset(0, -250),
    );
    await settle(tester);
    await tester.tap(find.byKey(const Key('ollama-download-minicpm5-2b')));
    await settle(tester);
    // Heavy tier: the OOM-risk confirmation dialog appears first.
    expect(find.byKey(const Key('ollama-risk-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ollama-risk-confirm')));
    await settle(tester);
    expect(queue.enqueued, hasLength(2));
    expect(queue.enqueued.last.ollamaRef, 'minicpm5-2b');
  });

  testWidgets(
    'installed tab lists seeded models and deletes after confirmation',
    (WidgetTester tester) async {
      const LocalModelEntry entry = LocalModelEntry(
        id: 'm-1',
        name: 'Qwen3 0.6B',
        source: LocalModelSource.catalog,
        ollamaRef: 'qwen3:0.6b',
        fileName: 'm-1.gguf',
        sizeBytes: 548577280,
        addedAtMs: 1736500000000,
      );
      final ProviderContainer container = await openOllamaScreen(
        tester,
        installed: const <LocalModelEntry>[entry],
      );

      await tester.tap(find.byKey(const Key('ollama-tab-installed')));
      await settle(tester);
      expect(find.byKey(const Key('ollama-installed-m-1')), findsOneWidget);
      expect(find.text('Qwen3 0.6B'), findsOneWidget);
      expect(find.byKey(const Key('ollama-start-m-1')), findsOneWidget);
      expect(find.byKey(const Key('ollama-export-m-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ollama-delete-m-1')));
      await settle(tester);
      expect(find.byKey(const Key('ollama-delete-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ollama-delete-confirm')));
      await settle(tester);
      expect(container.read(localModelsProvider).installed, isEmpty);
      expect(find.byKey(const Key('ollama-installed-empty')), findsOneWidget);
    },
  );

  testWidgets('downloads tab renders live progress rows with actions', (
    WidgetTester tester,
  ) async {
    const List<DownloadProgress> rows = <DownloadProgress>[
      DownloadProgress(
        modelId: 'd1',
        modelName: 'qwen3:0.6b',
        receivedBytes: 314572800,
        totalBytes: 548577280,
        status: DownloadStatus.running,
      ),
      DownloadProgress(
        modelId: 'd2',
        modelName: 'smollm2:135m',
        receivedBytes: 0,
        // Determinate on purpose: an unknown total renders an
        // INDETERMINATE LinearProgressIndicator whose endless animation
        // makes pumpAndSettle time out — the unknown-total look is not
        // what this test is about.
        totalBytes: 284246016,
        status: DownloadStatus.queued,
      ),
    ];
    await openOllamaScreen(tester, downloads: rows);

    await tester.tap(find.byKey(const Key('ollama-tab-downloads')));
    await settle(tester);
    expect(find.byKey(const Key('ollama-download-row-d1')), findsOneWidget);
    expect(find.byKey(const Key('ollama-download-row-d2')), findsOneWidget);
    expect(find.text('qwen3:0.6b'), findsOneWidget);
    // "x of y MB" progress text + status chips.
    expect(find.text('300 of 523 MB'), findsOneWidget);
    expect(find.text('Downloading'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    // One indicator per row (indeterminate when the total is unknown).
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    // Running + queued rows expose pause and cancel; nothing finished yet,
    // so the clear-finished action stays hidden.
    expect(find.byKey(const Key('ollama-pause-d1')), findsOneWidget);
    expect(find.byKey(const Key('ollama-cancel-d1')), findsOneWidget);
    expect(find.byKey(const Key('ollama-pause-d2')), findsOneWidget);
    expect(find.byKey(const Key('ollama-clear-finished')), findsNothing);
  });

  // -- v1.52.0 (Fase 2) ------------------------------------------------------

  testWidgets(
    'server tab renders the battery and device-RAM lines from the fake '
    'platform, including the low-battery warning',
    (WidgetTester tester) async {
      final FakeLlmServerPlatform platformFake = FakeLlmServerPlatform()
        ..batteryPercent = 73
        ..batteryCharging = true;
      // FakeLlmServerPlatform defaults to 8 GiB total RAM → "8.0 GB".
      await openOllamaScreen(tester, platform: platformFake);

      expect(find.byKey(const Key('ollama-battery')), findsOneWidget);
      expect(find.text('Battery 73% · charging'), findsOneWidget);
      expect(find.byKey(const Key('ollama-ram-line')), findsOneWidget);
      expect(find.text('Device RAM 8.0 GB'), findsOneWidget);

      // Battery flips to critical while discharging → the 3 s poll picks
      // it up and the line turns into the red low-battery warning.
      platformFake.batteryPercent = 12;
      platformFake.batteryCharging = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await settle(tester);
      expect(find.text('Battery 12% — low'), findsOneWidget);
      expect(find.text('Battery 73% · charging'), findsNothing);
    },
  );

  testWidgets(
    'benchmark button runs against the mocked client and lands on done',
    (WidgetTester tester) async {
      final _FakeDownloadQueueController queue = _FakeDownloadQueueController();
      final ProviderContainer container = await openOllamaScreen(
        tester,
        platform: FakeLlmServerPlatform(),
        queue: queue,
        httpClient: _llmEndpointsClient(_benchmarkSse),
        installed: const <LocalModelEntry>[
          LocalModelEntry(
            id: 'm-1',
            name: 'qwen3:0.6b',
            source: LocalModelSource.catalog,
            ollamaRef: 'qwen3:0.6b',
            fileName: 'm-1.gguf',
            addedAtMs: 1,
          ),
        ],
      );

      // Bring the (real) controller to running: fake platform launch +
      // health 200 from the shared mock client. start() also refreshes
      // logTail so the log block renders.
      final bool ok = await container
          .read(llmServerProvider.notifier)
          .start(modelPath: '/tmp/m-1.gguf', modelName: 'qwen3:0.6b');
      expect(ok, isTrue);
      await settle(tester);

      // The benchmark button only exists while running.
      expect(find.byKey(const Key('ollama-benchmark')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ollama-benchmark')));
      await settle(tester);

      final BenchmarkRunState bench = container.read(benchmarkRunProvider);
      expect(bench.status, BenchmarkRunStatus.done);
      expect(bench.result!.totalTokens, 20);
      expect(bench.result!.promptTokens, 10);
      // Localized result line inside the status card.
      expect(find.byKey(const Key('ollama-benchmark-result')), findsOneWidget);
      expect(find.textContaining('tok/s'), findsOneWidget);
      expect(find.textContaining('20 tokens'), findsOneWidget);
    },
  );

  testWidgets(
    'a failing benchmark reports the failure through the same result line',
    (WidgetTester tester) async {
      final http.Client failing = MockClient(
        (http.Request request) async => http.Response(
          '{"status":"ok"}',
          request.url.path.endsWith('/health') ? 200 : 500,
        ),
      );
      final ProviderContainer container = await openOllamaScreen(
        tester,
        platform: FakeLlmServerPlatform(),
        httpClient: failing,
      );

      expect(
        await container
            .read(llmServerProvider.notifier)
            .start(modelPath: '/tmp/x.gguf', modelName: 'x'),
        isTrue,
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-benchmark')));
      await settle(tester);

      final BenchmarkRunState bench = container.read(benchmarkRunProvider);
      expect(bench.status, BenchmarkRunStatus.failed);
      expect(bench.message, 'HTTP 500');
      expect(find.byKey(const Key('ollama-benchmark-result')), findsOneWidget);
      expect(find.text('HTTP 500'), findsOneWidget);
    },
  );

  testWidgets('log viewer shows the full log, copies it and closes', (
    WidgetTester tester,
  ) async {
    String? copied;
    // Returns void — call as a statement (an await on it would not
    // compile).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>?)?['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final FakeLlmServerPlatform platformFake = FakeLlmServerPlatform()
      ..logs.addAll(<String>[
        'llama-server listening on 127.0.0.1:11434',
        'model loaded — alias qwen3:0.6b',
        'ready',
      ]);
    final ProviderContainer container = await openOllamaScreen(
      tester,
      platform: platformFake,
      httpClient: _llmEndpointsClient(_benchmarkSse),
    );

    // start() flips the status to running and seeds logTail.
    expect(
      await container
          .read(llmServerProvider.notifier)
          .start(modelPath: '/tmp/m.gguf', modelName: 'qwen3:0.6b'),
      isTrue,
    );
    await settle(tester);

    // The v1.52.0 battery/RAM lines pushed the log section below the
    // lazy viewport — reveal it before asserting/tapping.
    await tester.dragUntilVisible(
      find.byKey(const Key('ollama-log-tail')),
      find.byType(ListView).first,
      const Offset(0, -250),
    );
    await settle(tester);
    expect(find.byKey(const Key('ollama-log-tail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ollama-log-viewer')));
    await settle(tester);

    // Full-screen viewer: monospace body with every line.
    expect(find.byKey(const Key('ollama-log-viewer-body')), findsOneWidget);
    expect(find.textContaining('llama-server listening'), findsOneWidget);
    expect(find.textContaining('ready'), findsOneWidget);

    // Copy-all lands the joined log on the system clipboard.
    await tester.tap(find.byKey(const Key('ollama-log-viewer-copy')));
    await settle(tester);
    expect(copied, platformFake.logs.join('\n'));
    expect(find.text('Copied'), findsOneWidget);
    await dismissAppMessage(tester);

    await tester.tap(find.byKey(const Key('ollama-log-viewer-close')));
    await settle(tester);
    expect(find.byKey(const Key('ollama-log-viewer-body')), findsNothing);
    expect(find.byType(OllamaManageScreen), findsOneWidget);
  });

  testWidgets(
    'RAM auto-filter hides non-fitting cards and the risk dialog gates '
    '"download anyway" for non-upperBound tiers',
    (WidgetTester tester) async {
      // 2 GiB device → 55% limit = 1181116006: qwen3:0.6b (1 GiB) fits,
      // gemma3:1b (1.2 GiB) and bonsai-2:4b (2.6 GiB) do not.
      final FakeLlmServerPlatform platformFake = FakeLlmServerPlatform()
        ..totalRamBytes = 2 * 1024 * 1024 * 1024;
      final _FakeDownloadQueueController queue = _FakeDownloadQueueController();
      await openOllamaScreen(tester, platform: platformFake, queue: queue);

      await tester.tap(find.byKey(const Key('ollama-tab-catalog')));
      await settle(tester);

      // Filter defaults ON: fitting card visible, too-big cards hidden.
      expect(
        find.byKey(const Key('ollama-catalog-qwen3:0.6b')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('ollama-catalog-gemma3:1b')), findsNothing);
      expect(
        find.byKey(
          const Key('ollama-catalog-bonsai-2:4b'),
          skipOffstage: false,
        ),
        findsNothing,
      );

      // Toggle the chip OFF: every card shows, too-big ones flagged red.
      await tester.tap(find.byKey(const Key('ollama-fit-filter')));
      await settle(tester);
      expect(
        find.byKey(const Key('ollama-catalog-qwen3:0.6b')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('ollama-catalog-gemma3:1b')), findsOneWidget);
      expect(find.text('Too large for this device'), findsWidgets);

      // gemma3:1b is tier 1 but does not fit → the risk dialog gates it.
      await tester.tap(find.byKey(const Key('ollama-download-gemma3:1b')));
      await settle(tester);
      expect(find.byKey(const Key('ollama-risk-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ollama-risk-confirm')));
      await settle(tester);
      expect(queue.enqueued, hasLength(1));
      expect(queue.enqueued.single.ollamaRef, 'gemma3:1b');
    },
  );

  testWidgets(
    'remote catalog refresh overlays the built-ins and reset clears it',
    (WidgetTester tester) async {
      // One replacement (qwen3:0.6b with a different download size) plus
      // one brand-new ref.
      const String remoteJson =
          '{"version":1,"models":['
          '{"ollamaRef":"qwen3:0.6b","downloadBytes":419430400,'
          '"ramEstBytes":1073741824,"contextTokens":40960,'
          '"tier":"tier1","license":"Apache-2.0"},'
          '{"ollamaRef":"new-model:1b","downloadBytes":306184192,'
          '"ramEstBytes":751619276,"contextTokens":32768,'
          '"tier":"tier1","license":"MIT"}]}';
      final http.Client client = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/health')) {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response(remoteJson, 200);
      });
      final ProviderContainer container = await openOllamaScreen(
        tester,
        httpClient: client,
      );

      await tester.tap(find.byKey(const Key('ollama-tab-catalog')));
      await settle(tester);
      // No overlay yet → no Reset action.
      expect(find.byKey(const Key('ollama-catalog-reset')), findsNothing);

      await tester.tap(find.byKey(const Key('ollama-catalog-refresh')));
      await settle(tester);
      expect(find.text('Catalog updated: 2 models.'), findsOneWidget);
      await dismissAppMessage(tester);

      // Overlay persisted in the store and merged into the visible list.
      expect(container.read(localModelsProvider).remoteCatalog, hasLength(2));
      expect(find.textContaining('400 MB'), findsOneWidget); // replaced values
      await tester.dragUntilVisible(
        find.byKey(const Key('ollama-catalog-new-model:1b')),
        catalogScrollable(),
        const Offset(0, -250),
      );
      await settle(tester);
      expect(
        find.byKey(const Key('ollama-catalog-new-model:1b')),
        findsOneWidget,
      );

      // Reset clears the overlay → built-in values again. The deep drag
      // above left the list scrolled far DOWN — the Reset button lives at
      // the TOP of the catalog list and was disposed by the lazy builder,
      // so scroll back up before tapping it.
      await tester.dragUntilVisible(
        find.byKey(const Key('ollama-catalog-reset')),
        catalogScrollable(),
        const Offset(0, 250),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-catalog-reset')));
      await settle(tester);
      expect(find.text('Back to the built-in catalog.'), findsOneWidget);
      await dismissAppMessage(tester);
      expect(container.read(localModelsProvider).remoteCatalog, isEmpty);
      expect(find.textContaining('523 MB'), findsOneWidget);
      expect(
        find.byKey(
          const Key('ollama-catalog-new-model:1b'),
          skipOffstage: false,
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'bulk export: selection mode, checkboxes, export through the IO provider',
    (WidgetTester tester) async {
      const LocalModelEntry first = LocalModelEntry(
        id: 'm-1',
        name: 'Qwen3 0.6B',
        source: LocalModelSource.catalog,
        ollamaRef: 'qwen3:0.6b',
        fileName: 'm-1.gguf',
        sizeBytes: 548405248,
        addedAtMs: 1736500000000,
      );
      const LocalModelEntry second = LocalModelEntry(
        id: 'm-2',
        name: 'Gemma3 270M',
        source: LocalModelSource.imported,
        fileName: 'm-2.gguf',
        sizeBytes: 306184192,
        addedAtMs: 1736500000001,
      );
      final _RecordingLocalModelIo io = _RecordingLocalModelIo(2);
      await openOllamaScreen(
        tester,
        installed: const <LocalModelEntry>[first, second],
        modelIo: io,
      );

      await tester.tap(find.byKey(const Key('ollama-tab-installed')));
      await settle(tester);
      // Non-empty installed list → the checklist toggle appears.
      expect(find.byKey(const Key('ollama-select-mode')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ollama-select-mode')));
      await settle(tester);
      expect(find.byKey(const Key('ollama-select-m-1')), findsOneWidget);
      expect(find.byKey(const Key('ollama-select-m-2')), findsOneWidget);

      // Leaving the Installed tab exits selection mode.
      await tester.tap(find.byKey(const Key('ollama-tab-server')));
      await settle(tester);
      expect(
        find.byKey(const Key('ollama-select-m-1'), skipOffstage: false),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('ollama-tab-installed')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-select-mode')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-select-m-1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-select-m-2')));
      await settle(tester);
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ollama-export-selected')));
      await settle(tester);
      // The IO provider was called once with BOTH ids, in list order.
      expect(io.exportCalls, hasLength(1));
      expect(io.exportCalls.single, <String>['m-1', 'm-2']);
      expect(find.text('Exported 2 models.'), findsOneWidget);
      await dismissAppMessage(tester);
      // Selection mode exited after the export.
      expect(
        find.byKey(const Key('ollama-select-m-1'), skipOffstage: false),
        findsNothing,
      );
      expect(find.byKey(const Key('ollama-select-mode')), findsOneWidget);
    },
  );

  testWidgets(
    'bulk export with nothing shareable reports "No models exported."',
    (WidgetTester tester) async {
      const LocalModelEntry only = LocalModelEntry(
        id: 'm-1',
        name: 'Qwen3 0.6B',
        source: LocalModelSource.catalog,
        ollamaRef: 'qwen3:0.6b',
        fileName: 'm-1.gguf',
        addedAtMs: 1,
      );
      // outcome 0: the real LocalModelIo degrades to 0 on missing files /
      // a dismissed share sheet — the spy models that graceful path.
      final _RecordingLocalModelIo io = _RecordingLocalModelIo(0);
      await openOllamaScreen(
        tester,
        installed: const <LocalModelEntry>[only],
        modelIo: io,
      );

      await tester.tap(find.byKey(const Key('ollama-tab-installed')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-select-mode')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-select-m-1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ollama-export-selected')));
      await settle(tester);
      expect(io.exportCalls, hasLength(1));
      expect(find.text('No models exported.'), findsOneWidget);
      // Error feedback must be acknowledged before teardown.
      await dismissAppMessage(tester);
    },
  );
}
