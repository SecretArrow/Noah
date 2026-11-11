import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/js_runtime.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/services/module_runtime.dart';
import 'package:noah/services/session_sandbox.dart';
import 'package:noah/ui/screens/settings_screen.dart';

import '../test/support/test_doubles.dart';

/// End-to-end flows executed on a real Android emulator via GitHub Actions.
/// External dependencies (LLM, browser) are replaced with deterministic test doubles
/// so the suite is fast and hermetic.

/// Scrolls a lazy ListView until [key] is built and visible, then taps it
/// (dragUntilVisible builds offscreen items; ensureVisible aligns the
/// exact offset after the language switch reflows the list).
Future<void> tapScrollable(WidgetTester tester, Key key) async {
  if (find.byKey(key).evaluate().isEmpty) {
    await tester.dragUntilVisible(
      find.byKey(key),
      find.byType(ListView),
      const Offset(0, -250),
    );
  }
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('e2e: chat + agent tool call + settings', (
    WidgetTester tester,
  ) async {
    // Real IO must run inside tester.runAsync within widget tests.
    final Directory tempDir = (await tester.runAsync<Directory>(
      () => Directory.systemTemp.createTemp('zagents_e2e'),
    ))!;

    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 'e2e-1',
            name: 'browser_navigate',
            argumentsJson: jsonEncode(<String, dynamic>{
              'url': 'https://example.com',
            }),
          ),
        ],
      ),
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 'e2e-2',
            name: 'node_run',
            argumentsJson: jsonEncode(<String, dynamic>{
              'code': '[1,2,3].reduce((a,b)=>a+b)',
            }),
          ),
        ],
      ),
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 'e2e-3',
            name: 'browser_screenshot',
            argumentsJson: '{}',
          ),
        ],
      ),
      AssistantTurn(
        content: 'E2E selesai: halaman dibuka, node dijalankan & screenshot diambil.',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'e2e-key'),
        ),
        child: const NoahApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final BuildContext chatContext = tester.element(find.byType(NoahApp));
    final ProviderContainer chatContainer = ProviderScope.containerOf(
      chatContext,
    );

    // 1. Send a prompt from the composer.
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      'Buka example.com',
    );
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump();

    // 2. Drive the run to completion with a BOUNDED predicate loop.
    // v1.49 lesson (mirrors the module e2e tests): the run's real IO
    // (session persistence, screenshot bytes) only progresses inside
    // tester.runAsync, and the thinking spinner keeps scheduling frames
    // for the whole run — pumpAndSettle would either return too early
    // (bare pump) or throw "timed out" (never-settling spinner). A plain
    // pump() cannot time out, advances the fake clock, and the interleaved
    // runAsync windows let real IO progress; the loop exits as soon as
    // the LAST expected artifact (final answer) is visible.
    bool done = false;
    for (int i = 0; i < 60 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      done =
          find.text('browser_navigate').evaluate().isNotEmpty &&
          find.text('node_run').evaluate().isNotEmpty &&
          find.text('browser_screenshot').evaluate().isNotEmpty &&
          find.textContaining('E2E selesai').evaluate().isNotEmpty;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }

    // All tool cards + final answer rendered — with a full diagnostic
    // dump so a regression names itself from the CI log alone (content
    // AND per-message tool calls — a lost toolCalls list is the #1
    // suspect when tool cards go missing).
    String transcript() => chatContainer
        .read(chatControllerProvider)
        .messages
        .map(
          (ChatMessage m) =>
              '[${m.role.name}] ${m.content}'
              '${m.toolCalls.isEmpty ? '' : ' tools=${m.toolCalls.map((ToolCall c) => '${c.name}:${c.status.name}').join(',')}'}',
        )
        .join(' ||| ');
    expect(
      find.text('browser_navigate'),
      findsOneWidget,
      reason:
          'tool card missing. error='
          '${chatContainer.read(chatControllerProvider).error} '
          'loading=${chatContainer.read(chatControllerProvider).isLoading} '
          'llmCalls=${llm.calls.length} transcript=[${transcript()}]',
    );
    expect(find.text('node_run'), findsOneWidget);
    expect(find.text('browser_screenshot'), findsOneWidget);
    expect(find.textContaining('E2E selesai'), findsOneWidget);

    // 3. LLM received a well-formed wire: system + user + tool results.
    final List<Map<String, dynamic>> firstCall = llm.calls.first;
    expect(firstCall.first['role'], 'system');
    expect(firstCall[1]['role'], 'user');
    expect(llm.calls[2].any((m) => m['role'] == 'tool'), isTrue);

    // 4. Settings screen is reachable; provider CRUD works through the
    // full-screen manager (per-provider API key + explicit save button).
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    final BuildContext context = tester.element(find.byType(SettingsScreen));
    final ProviderContainer container = ProviderScope.containerOf(context);

    await tester.tap(find.byKey(const Key('providers-tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('provider-OpenRouter')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('editor-api-key-field')),
      'e2e-key-2',
    );
    await tester.tap(find.byKey(const Key('editor-save-api-key-button')));
    await tester.pumpAndSettle();
    // v1.49.6: the save confirmation is a centered modal dialog now —
    // acknowledge it when present, the barrier would otherwise swallow
    // the BackButton tap below.
    final Finder appMessageOk = find.byKey(const Key('app-message-ok'));
    if (appMessageOk.evaluate().isNotEmpty) {
      await tester.tap(appMessageOk);
      await tester.pumpAndSettle();
    }
    // OpenRouter is the active provider: the live connection picks the
    // key up immediately and the preset stores it.
    expect(container.read(settingsProvider).apiKey, 'e2e-key-2');
    expect(
      container
          .read(settingsProvider)
          .presets
          .firstWhere((ProviderPreset p) => p.name == 'OpenRouter')
          .apiKey,
      'e2e-key-2',
    );

    // Leave the editor first — the providers manager is behind it.
    await tester.tap(find.byType(BackButton).first);
    await tester.pumpAndSettle();

    // v1.10.0: long-pressing a (non-active) provider card opens the
    // confirmation dialog; cancelling keeps the connection unchanged.
    await tester.longPress(find.byKey(const Key('provider-InferHub')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('provider-activate-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel-activate-provider')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('provider-activate-dialog')), findsNothing);

    // Leave the providers manager.
    await tester.tap(find.byType(BackButton).first);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    // 5. Language option: English is the default, Bahasa Indonesia switches
    // the whole UI and the choice persists in settings. The settings list
    // is lazy and the module manager tile (v1.21.0) shifts section
    // heights, so each language button may need scrolling (and building)
    // before it can be tapped.
    await tapScrollable(tester, const Key('lang-id'));
    expect(find.text('Pengaturan'), findsOneWidget);
    expect(
      ProviderScope.containerOf(context).read(settingsProvider).languageCode,
      'id',
    );
    await tapScrollable(tester, const Key('lang-en'));
    expect(find.text('Settings'), findsOneWidget);
    expect(
      ProviderScope.containerOf(context).read(settingsProvider).languageCode,
      'en',
    );

    // 6. New v1.4.0 controls exist: theme picker + max-steps custom input
    // + Node.js manager tile + files tile.
    // The language section is at the bottom; drag back UP to reveal the
    // appearance section first (ListView builds lazily).
    await tester.dragUntilVisible(
      find.byKey(const Key('theme-mode-segmented')),
      find.byType(ListView),
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-mode-segmented')), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const Key('max-steps-field')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('max-steps-field')), findsOneWidget);
    // v1.8.0: "Run until done" switch sits right above the max-steps row.
    expect(find.byKey(const Key('run-until-done-switch')), findsOneWidget);
    // v1.9.0: plan-first (Todos) switch sits right below it, on by default.
    expect(find.byKey(const Key('plan-first-switch')), findsOneWidget);
    expect(container.read(settingsProvider).planFirst, isTrue);
    await tester.dragUntilVisible(
      find.byKey(const Key('node-manager-tile')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node-manager-tile')), findsOneWidget);
    expect(find.byKey(const Key('files-tile')), findsOneWidget);
    // The context tile sits above the node section — reveal it too.
    await tester.dragUntilVisible(
      find.byKey(const Key('context-manager-tile')),
      find.byType(ListView),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-manager-tile')), findsOneWidget);
    // v1.7.0: the User-Agent mode dropdown sits one section higher still —
    // keep dragging UP.
    await tester.dragUntilVisible(
      find.byKey(const Key('ua-mode-dropdown')),
      find.byType(ListView),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ua-mode-dropdown')), findsOneWidget);
    expect(find.byKey(const Key('ua-rotate-button')), findsOneWidget);

    try {
      await tester.runAsync(() => tempDir.delete(recursive: true));
    } catch (_) {}
  });

  testWidgets('e2e: module installs from ZIP, runs on the real embedded '
      'runtime with the zagents SDK, and stays per-chat isolated', (
    WidgetTester tester,
  ) async {
    final Directory tempDir = (await tester.runAsync<Directory>(
      () => Directory.systemTemp.createTemp('zagents_e2e_module'),
    ))!;

    // -- 1. Build a module ZIP on disk (real IO). -------------------------
    const String manifestJson =
        '{"name":"e2e-module","version":"1.0.0","title":"E2E Module",'
        '"description":"Counts activations per chat",'
        '"permissions":["storage","chat"],"entry":"main.js"}';
    // The entry source starts with a Node-style shebang ON PURPOSE: the
    // embedded runtime evaluates sources through `new Function`, where a
    // leading `#!` line would be "Invalid or unexpected token" unless the
    // registry strips it first (Node's loader does the same). Guards the
    // shebang regression end-to-end on a real WebView.
    const String entrySource =
        '#!/usr/bin/env node\n'
        '''
async function main() {
  const previous = (await zagents.storage.get('count')) || 0;
  await zagents.storage.set('count', previous + 1);
  await zagents.chat.emit('Hello from the module! count=' + (previous + 1));
  return { count: previous + 1 };
}
module.exports = main();
''';
    final File zipFile = File(
      '${tempDir.path}${Platform.pathSeparator}e2e-module.zip',
    );
    await tester.runAsync(() async {
      final Archive archive = Archive()
        ..addFile(
          ArchiveFile(
            'module.json',
            utf8.encode(manifestJson).length,
            utf8.encode(manifestJson),
          ),
        )
        ..addFile(
          ArchiveFile(
            'main.js',
            utf8.encode(entrySource).length,
            utf8.encode(entrySource),
          ),
        );
      zipFile.writeAsBytesSync(ZipEncoder().encode(archive));
    });

    // -- 2. App with the REAL registry + REAL WebView-backed runtime. ----
    final ModuleRegistry registry = ModuleRegistry(
      resolveBaseDir: () async => tempDir,
    );
    final ModuleInstallResult installed = (await tester.runAsync(
      () => registry.installFromZip(zipFile.path),
    ))!;
    expect(installed.ok, isTrue, reason: installed.message);

    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'Module output acknowledged.'),
    ]);
    final SessionSandbox sandbox = SessionSandbox(
      resolveDocumentsDir: () async => tempDir,
    );

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'e2e-key', autoTitle: false),
          writeScreenshots: false,
        ),
        moduleRegistryProvider.overrideWithValue(registry),
        moduleRuntimeProvider.overrideWith(
          (Ref ref) => ModuleRuntime(
            // The REAL hidden-WebView runtime: exercises the module
            // bootstrap, the zagents SDK global and the Dart bridge.
            js: SerializedJsRuntime(WebViewJsRuntime()),
            resolveSandboxRoot: sandbox.rootFor,
            resolveModulePath: (String name) async =>
                (await registry.get(name))?.path,
            resolveSdkSource: () async =>
                rootBundle.loadString('sdk/zagents-sdk.js'),
            resolveNpmModulesRoot: () async =>
                '${tempDir.path}${Platform.pathSeparator}node_modules',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoahApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // -- 3. Activation + first message, executed in the real async zone.
    // The integration binding runs test bodies in a fake-async zone where
    // real platform async (registry IO, the hidden WebView) never
    // completes — controller work therefore runs inside tester.runAsync
    // (the /plugins menu + permission dialog UI flows are covered by the
    // widget suite). activateModule on a fresh draft stages the module;
    // the FIRST message activates it: transcript order reads user ->
    // module output -> assistant reply.
    await tester.runAsync(() async {
      final ChatController controller = container.read(
        chatControllerProvider.notifier,
      );
      await controller.activateModule('e2e-module');
      expect(
        container.read(chatControllerProvider).pendingModule,
        'e2e-module',
      );
      expect(container.read(chatControllerProvider).activeModules, isEmpty);
      await controller.send('what did the module say?');
    });

    // The entry output, emit and badge are all in the transcript now.
    final String moduleContent = container
        .read(chatControllerProvider)
        .messages
        .map(
          (ChatMessage m) =>
              '[${m.role.name}/${m.moduleName ?? '-'}] ${m.content}',
        )
        .join(' ||| ');
    expect(
      moduleContent,
      contains('Hello from the module! count=1'),
      reason:
          'module entry output never appeared. state.error='
          '${container.read(chatControllerProvider).error} '
          'transcript: $moduleContent',
    );
    expect(
      moduleContent,
      contains('[assistant/e2e-module]'),
      reason: 'the module message badge must be persisted in the model',
    );
    expect(container.read(chatControllerProvider).activeModules, <String>[
      'e2e-module',
    ]);

    // Per-chat state was materialized inside the session sandbox.
    final Directory instanceDir = (await tester.runAsync(
      () => sandbox
          .rootFor(container.read(chatControllerProvider).sessionId!)
          .then(
            (Directory root) => Directory(
              '${root.path}${Platform.pathSeparator}modules'
              '${Platform.pathSeparator}e2e-module',
            ),
          ),
    ))!;
    expect(instanceDir.existsSync(), isTrue);
    final File storage = File(
      '${instanceDir.path}${Platform.pathSeparator}storage.json',
    );
    expect(storage.existsSync(), isTrue);
    expect(storage.readAsStringSync(), contains('"count":1'));

    try {
      await tester.runAsync(() => tempDir.delete(recursive: true));
    } catch (_) {}
  });

  testWidgets('e2e: module setup form gates the first run, then the '
      'submitted values reach the real runtime as zagents.info.setup', (
    WidgetTester tester,
  ) async {
    final Directory tempDir = (await tester.runAsync<Directory>(
      () => Directory.systemTemp.createTemp('zagents_e2e_setup'),
    ))!;

    // -- 1. Module ZIP with a required per-chat setup field. --------------
    const String manifestJson =
        '{"name":"e2e-setup","version":"1.0.0","title":"E2E Setup",'
        '"description":"Needs a token",'
        '"permissions":["storage","chat"],"entry":"main.js",'
        '"setup":{"title":"Access token",'
        '"description":"Collected once per chat.",'
        '"fields":[{"key":"token","label":"Token","type":"text",'
        '"required":true}]}}';
    const String entrySource = '''
async function main() {
  const setup = (zagents.info && zagents.info.setup) || {};
  await zagents.chat.emit('setup token received: ' + (setup.token || '(none)'));
  return { token: setup.token || null };
}
module.exports = main();
''';
    final File zipFile = File(
      '${tempDir.path}${Platform.pathSeparator}e2e-setup.zip',
    );
    await tester.runAsync(() async {
      final Archive archive = Archive()
        ..addFile(
          ArchiveFile(
            'module.json',
            utf8.encode(manifestJson).length,
            utf8.encode(manifestJson),
          ),
        )
        ..addFile(
          ArchiveFile(
            'main.js',
            utf8.encode(entrySource).length,
            utf8.encode(entrySource),
          ),
        );
      zipFile.writeAsBytesSync(ZipEncoder().encode(archive));
    });

    // -- 2. App with the REAL registry + REAL WebView-backed runtime. ----
    final ModuleRegistry registry = ModuleRegistry(
      resolveBaseDir: () async => tempDir,
    );
    final ModuleInstallResult installed = (await tester.runAsync(
      () => registry.installFromZip(zipFile.path),
    ))!;
    expect(installed.ok, isTrue, reason: installed.message);

    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'Setup flow acknowledged.'),
    ]);
    final SessionSandbox sandbox = SessionSandbox(
      resolveDocumentsDir: () async => tempDir,
    );

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'e2e-key', autoTitle: false),
          writeScreenshots: false,
        ),
        moduleRegistryProvider.overrideWithValue(registry),
        moduleRuntimeProvider.overrideWith(
          (Ref ref) => ModuleRuntime(
            js: SerializedJsRuntime(WebViewJsRuntime()),
            resolveSandboxRoot: sandbox.rootFor,
            resolveModulePath: (String name) async =>
                (await registry.get(name))?.path,
            resolveSdkSource: () async =>
                rootBundle.loadString('sdk/zagents-sdk.js'),
            resolveNpmModulesRoot: () async =>
                '${tempDir.path}${Platform.pathSeparator}node_modules',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoahApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    String transcript() => container
        .read(chatControllerProvider)
        .messages
        .map(
          (ChatMessage m) =>
              '[${m.role.name}/${m.moduleName ?? '-'}] ${m.content}',
        )
        .join(' ||| ');

    // -- 3. First activation: the gate BLOCKS the run and surfaces the
    // form request instead of a failed cycle.
    await tester.runAsync(() async {
      final ChatController controller = container.read(
        chatControllerProvider.notifier,
      );
      await controller.activateModule('e2e-setup');
      await controller.send('start the module');
    });
    expect(
      transcript(),
      isNot(contains('setup token received')),
      reason: 'the module must not execute before the form is submitted',
    );
    expect(container.read(chatControllerProvider).setupRequest, isNotNull);

    // -- 4. The home shell auto-opens the per-chat setup form.
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byKey(const Key('module-setup-sheet')), findsOneWidget);
    // The title shows on the sheet AND in the needs-setup module message.
    expect(find.text('Access token'), findsWidgets);
    // Dismiss: the banner stays, submission happens through the
    // controller (the sheet's own button flow is covered by the widget
    // suite — inside the integration binding its await would starve).
    await tester.tap(find.byKey(const Key('module-setup-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('module-setup-sheet')), findsNothing);
    expect(find.byKey(const Key('module-setup-banner')), findsOneWidget);

    // -- 5. Submit the form: values persist per chat and the module
    // RE-RUNS immediately on the real WebView.
    await tester.runAsync(() async {
      final ChatController controller = container.read(
        chatControllerProvider.notifier,
      );
      final bool submitted = await controller.submitModuleSetup(
        'e2e-setup',
        <String, dynamic>{'token': 'secret123'},
      );
      expect(submitted, isTrue, reason: 'form submission must succeed');
    });

    // -- 6. The module ran with the submitted values.
    expect(
      transcript(),
      contains('setup token received: secret123'),
      reason:
          'module output missing after setup submission. state.error='
          '${container.read(chatControllerProvider).error} '
          'transcript: ${transcript()}',
    );
    expect(container.read(chatControllerProvider).setupRequest, isNull);

    // -- 7. The values live in the per-chat instance storage.
    final Directory instanceDir = (await tester.runAsync(
      () => sandbox
          .rootFor(container.read(chatControllerProvider).sessionId!)
          .then(
            (Directory root) => Directory(
              '${root.path}${Platform.pathSeparator}modules'
              '${Platform.pathSeparator}e2e-setup',
            ),
          ),
    ))!;
    final File storage = File(
      '${instanceDir.path}${Platform.pathSeparator}storage.json',
    );
    expect(storage.existsSync(), isTrue);
    expect(storage.readAsStringSync(), contains('"token":"secret123"'));

    try {
      await tester.runAsync(() => tempDir.delete(recursive: true));
    } catch (_) {}
  });
}
