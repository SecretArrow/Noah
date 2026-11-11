import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/model_catalog.dart';
import 'package:noah/ui/widgets/model_picker.dart';

import '../../test/support/test_doubles.dart';

/// Scripted catalog: returns [models] or throws [error].
class ScriptedModelCatalog implements ModelCatalogClient {
  ScriptedModelCatalog({this.models = const <RemoteModel>[], this.error});

  final List<RemoteModel> models;
  final Object? error;

  int callCount = 0;

  @override
  Future<List<RemoteModel>> fetchModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    callCount++;
    final Object? failure = error;
    if (failure != null) throw failure;
    return models;
  }

  @override
  List<RemoteModel> parseCatalog(String body) => models;
}

RemoteModel m(
  String id, {
  String? name,
  bool tools = false,
  bool free = false,
  int? ctx,
}) => RemoteModel(
  id: id,
  name: name ?? id,
  supportsTools: tools,
  isFree: free,
  contextLength: ctx,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_picker_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 25 models so the default page size (5) yields exactly 5 pages.
  List<RemoteModel> bigCatalog() => <RemoteModel>[
    for (var i = 0; i < 25; i++)
      m('vendor/model-${i.toString().padLeft(2, '0')}'),
  ];

  /// The home-screen model chip shows the same text as catalog tiles, so
  /// every text assertion must be scoped to the picker sheet.
  Finder inSheet(Finder finder) =>
      find.descendant(of: find.byType(ModelPickerSheet), matching: finder);

  Future<ProviderContainer> openSheet(
    WidgetTester tester, {
    required ScriptedModelCatalog catalog,
    AppSettings? settings,
  }) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(
            dir: tempDir,
            // A distinct default model keeps the custom-model TextField from
            // colliding (find.text also matches EditableText) with catalog
            // tile texts like 'z-ai/glm-4.6'.
            settings:
                settings ??
                AppSettings(apiKey: 'sk-test', model: 'default/model-x'),
          ),
          modelCatalogProvider.overrideWithValue(catalog),
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

    await tester.tap(find.byKey(const Key('model-chip')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(find.byType(ModelPickerSheet), findsOneWidget);
    return container;
  }

  testWidgets('fetches and lists the live catalog with paging', (
    WidgetTester tester,
  ) async {
    await openSheet(
      tester,
      catalog: ScriptedModelCatalog(models: bigCatalog()),
    );

    // Page 1 of 5: indicator shown, first item visible, page-2 item absent.
    expect(inSheet(find.byKey(const Key('model-list-page-0'))), findsOneWidget);
    expect(inSheet(find.text('Page 1 of 5')), findsOneWidget);
    expect(inSheet(find.text('vendor/model-00')), findsOneWidget);
    expect(inSheet(find.text('vendor/model-05')), findsNothing);

    // Next page: first page-2 item becomes visible, page-1 item is gone.
    await tester.tap(find.byKey(const Key('model-page-next')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('Page 2 of 5')), findsOneWidget);
    expect(inSheet(find.text('vendor/model-05')), findsOneWidget);
    expect(inSheet(find.text('vendor/model-00')), findsNothing);

    // Prev button returns to page 1.
    await tester.tap(find.byKey(const Key('model-page-prev')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('Page 1 of 5')), findsOneWidget);
  });

  testWidgets('search box filters models by id and name', (
    WidgetTester tester,
  ) async {
    await openSheet(
      tester,
      catalog: ScriptedModelCatalog(
        models: <RemoteModel>[
          m('z-ai/glm-4.6', name: 'Z.AI: GLM 4.6'),
          m('google/gemini-2.5-pro', name: 'Gemini 2.5 Pro'),
          m('openai/gpt-4.1', name: 'OpenAI: GPT 4.1'),
        ],
      ),
    );

    await tester.enterText(
      find.byKey(const Key('model-search-field')),
      'gemini',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(inSheet(find.text('google/gemini-2.5-pro')), findsOneWidget);
    expect(inSheet(find.text('z-ai/glm-4.6')), findsNothing);
    expect(inSheet(find.text('openai/gpt-4.1')), findsNothing);

    // Search also matches display names.
    await tester.enterText(find.byKey(const Key('model-search-field')), 'GLM');
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('z-ai/glm-4.6')), findsOneWidget);

    // No match shows the empty state.
    await tester.enterText(find.byKey(const Key('model-search-field')), 'zzz');
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('No models match')), findsOneWidget);
  });

  testWidgets('filter chips narrow the catalog', (WidgetTester tester) async {
    await openSheet(
      tester,
      catalog: ScriptedModelCatalog(
        models: <RemoteModel>[
          m('paid/tool-model', tools: true),
          m('paid/plain-model'),
          m('x/free-model', free: true, tools: true),
        ],
      ),
    );

    // Tools filter: only tool-calling models remain.
    await tester.tap(find.byKey(const Key('model-filter-tools')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('paid/tool-model')), findsOneWidget);
    expect(inSheet(find.text('x/free-model')), findsOneWidget);
    expect(inSheet(find.text('paid/plain-model')), findsNothing);

    // Free filter.
    await tester.tap(find.byKey(const Key('model-filter-free')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('x/free-model')), findsOneWidget);
    expect(inSheet(find.text('paid/tool-model')), findsNothing);

    // Back to all.
    await tester.tap(find.byKey(const Key('model-filter-all')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('paid/plain-model')), findsOneWidget);
  });

  testWidgets('selecting a model updates settings and closes the sheet', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await openSheet(
      tester,
      catalog: ScriptedModelCatalog(
        models: <RemoteModel>[m('chosen/model-1'), m('chosen/model-2')],
      ),
    );
    expect(container.read(settingsProvider).model, isNot('chosen/model-1'));

    await tester.tap(inSheet(find.text('chosen/model-1')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(container.read(settingsProvider).model, 'chosen/model-1');
    expect(find.byType(ModelPickerSheet), findsNothing);
  });

  testWidgets('without an API key shows the hint and offline suggestions', (
    WidgetTester tester,
  ) async {
    final ScriptedModelCatalog catalog = ScriptedModelCatalog(
      models: <RemoteModel>[m('should/not-be-fetched')],
    );
    await openSheet(
      tester,
      catalog: catalog,
      // Distinct model id so the custom-model TextField does not collide
      // with the 'z-ai/glm-4.6' suggestion tile (find.text also matches
      // EditableText values).
      settings: AppSettings(apiKey: '', model: 'default/model-x'),
    );

    expect(catalog.callCount, 0);
    expect(inSheet(find.textContaining('Enter your API key')), findsOneWidget);
    // Static fallback suggestions are paged too: page 1 holds the first
    // five (alphabetical), the rest sit behind the pager.
    expect(inSheet(find.text('anthropic/claude-sonnet-4.5')), findsOneWidget);
    expect(inSheet(find.text('z-ai/glm-4.6')), findsNothing);
    await tester.tap(find.byKey(const Key('model-suggest-page-next')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('z-ai/glm-4.6')), findsOneWidget);
  });

  testWidgets('fetch failure shows error card with retry and suggestions', (
    WidgetTester tester,
  ) async {
    final ScriptedModelCatalog catalog = ScriptedModelCatalog(
      error: ModelCatalogException('Unauthorized — check the API key.'),
    );
    await openSheet(tester, catalog: catalog);

    expect(
      inSheet(find.text('Failed to load the model list.')),
      findsOneWidget,
    );
    expect(inSheet(find.textContaining('Unauthorized')), findsOneWidget);
    // Suggestions render paged: jump to the second page to see z-ai.
    expect(inSheet(find.text('z-ai/glm-4.6')), findsNothing);
    await tester.tap(find.byKey(const Key('model-suggest-page-next')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('z-ai/glm-4.6')), findsOneWidget);

    // Retry re-invokes the catalog; the scripted double still throws, so the error
    // card remains visible.
    await tester.tap(find.byKey(const Key('model-retry-button')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(catalog.callCount, 2);
    expect(
      inSheet(find.text('Failed to load the model list.')),
      findsOneWidget,
    );
  });

  testWidgets('header is scoped to the provider set in settings', (
    WidgetTester tester,
  ) async {
    final ProviderContainer localContainer = await openSheet(
      tester,
      catalog: ScriptedModelCatalog(
        models: <RemoteModel>[m('inferhub/model-1')],
      ),
      settings: AppSettings(
        providerName: 'InferHub',
        baseUrl: 'https://api.inferhub.dev/v1',
        apiKey: 'sk-airo-x',
        model: 'default/model-x',
      ),
    );

    // The picker shows which provider (and host) the list comes from.
    expect(inSheet(find.textContaining('InferHub')), findsOneWidget);
    expect(inSheet(find.textContaining('api.inferhub.dev')), findsOneWidget);

    // The catalog client receives THAT provider's credentials.
    final AppSettings settings = localContainer.read(settingsProvider);
    expect(settings.providerName, 'InferHub');
  });

  testWidgets('a successful fetch is cached on the active preset', (
    WidgetTester tester,
  ) async {
    final ProviderContainer localContainer = await openSheet(
      tester,
      catalog: ScriptedModelCatalog(
        models: <RemoteModel>[m('vendor/fresh-1'), m('vendor/fresh-2')],
      ),
    );

    expect(localContainer.read(settingsProvider).model, 'default/model-x');
    // Pick a model so the sheet closes; the cache must be persisted.
    await tester.tap(inSheet(find.text('vendor/fresh-1')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    final AppSettings settings = localContainer.read(settingsProvider);
    expect(settings.model, 'vendor/fresh-1');
    final ProviderPreset? active = settings.activePreset;
    expect(active, isNotNull);
    expect(
      active!.modelsCache,
      containsAll(<String>['vendor/fresh-1', 'vendor/fresh-2']),
    );
  });

  testWidgets('when the fetch fails, the cached provider list is shown', (
    WidgetTester tester,
  ) async {
    final ScriptedModelCatalog catalog = ScriptedModelCatalog(
      error: ModelCatalogException('Offline.'),
    );
    await openSheet(
      tester,
      catalog: catalog,
      settings: AppSettings(
        apiKey: 'sk-test',
        model: 'default/model-x',
        presets: <ProviderPreset>[
          const ProviderPreset(
            id: 'p-openrouter',
            name: 'OpenRouter',
            baseUrl: 'https://openrouter.ai/api/v1',
            apiKey: 'sk-test',
            modelsCache: <String>['cached/model-a', 'cached/model-b'],
          ),
        ],
      ),
    );

    // The offline note is shown instead of the hard error card, and the
    // cached models of THIS provider are selectable.
    expect(inSheet(find.textContaining('last fetched list')), findsOneWidget);
    expect(inSheet(find.text('cached/model-a')), findsOneWidget);
    expect(inSheet(find.text('cached/model-b')), findsOneWidget);
    expect(inSheet(find.text('z-ai/glm-4.6')), findsNothing);

    // Search filters the cached list too.
    await tester.enterText(
      find.byKey(const Key('model-search-field')),
      'model-b',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('cached/model-b')), findsOneWidget);
    expect(inSheet(find.text('cached/model-a')), findsNothing);
  });

  testWidgets('without a key the search still filters the suggestions', (
    WidgetTester tester,
  ) async {
    await openSheet(
      tester,
      catalog: ScriptedModelCatalog(),
      settings: AppSettings(apiKey: '', model: 'default/model-x'),
    );

    await tester.enterText(
      find.byKey(const Key('model-search-field')),
      'gemini',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(inSheet(find.text('google/gemini-2.5-pro')), findsOneWidget);
    expect(inSheet(find.text('z-ai/glm-4.6')), findsNothing);
  });
}
