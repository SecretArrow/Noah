import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/js_runtime.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/module_runtime.dart';
import 'package:noah/services/session_sandbox.dart';

import '../support/test_doubles.dart';

void main() {
  late Directory tempDir;
  late ModuleRegistry registry;
  late ScriptedJsRuntime js;
  late ModuleRuntime moduleRuntime;
  late SessionSandbox sandbox;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_module_ctrl');
    registry = ModuleRegistry(resolveBaseDir: () async => tempDir);
    js = ScriptedJsRuntime();
    sandbox = SessionSandbox(resolveDocumentsDir: () async => tempDir);
    moduleRuntime = ModuleRuntime(
      js: js,
      resolveSandboxRoot: sandbox.rootFor,
      resolveModulePath: (String name) async =>
          (await registry.get(name))?.path,
      resolveSdkSource: () async => 'module.exports = zagents;',
      resolveNpmModulesRoot: () async =>
          '${tempDir.path}${Platform.pathSeparator}node_modules',
    );
  });

  tearDown(() async {
    // A module run may still be flushing a file when the test body ends; a
    // single recursive delete then fails with ENOTEMPTY ("Directory not
    // empty") and turns a green test into a red one. Retry briefly instead.
    for (int attempt = 0; attempt < 10; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// Installs a module fixture into the registry via the public ZIP path.
  Future<ChatModule> installModule(
    String name, {
    String version = '1.0.0',
    String description = 'Counts things',
    List<ModulePermission> permissions = const <ModulePermission>[
      ModulePermission.storage,
    ],
    Map<String, dynamic>? setup,
    List<String> commands = const <String>[],
  }) async {
    final String manifest = jsonEncode(<String, dynamic>{
      'name': name,
      'version': version,
      'description': description,
      'entry': 'main.js',
      'permissions': permissions.map((p) => p.name).toList(),
      'setup': ?setup,
      'commands': ?commands.isEmpty ? null : commands,
    });
    final List<int> entry = utf8.encode('// $name entry');
    final Archive archive = Archive()
      ..addFile(
        ArchiveFile(
          'module.json',
          utf8.encode(manifest).length,
          utf8.encode(manifest),
        ),
      )
      ..addFile(ArchiveFile('main.js', entry.length, entry));
    final File zip = File(
      '${tempDir.path}${Platform.pathSeparator}$name-install.zip',
    )..writeAsBytesSync(ZipEncoder().encode(archive));
    final ModuleInstallResult result = await registry.installFromZip(zip.path);
    expect(result.ok, isTrue, reason: result.message);
    return result.module!;
  }

  Future<ProviderContainer> container({
    List<AssistantTurn>? turns,
    ScriptedLlmClient? llm,
  }) async {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm:
              llm ??
              ScriptedLlmClient(
                turns ??
                    <AssistantTurn>[
                      AssistantTurn(content: 'Module output noted.'),
                    ],
              ),
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
        moduleRegistryProvider.overrideWithValue(registry),
        moduleRuntimeProvider.overrideWithValue(moduleRuntime),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'draft + activateModule stages pendingModule for the first message',
    () async {
      final ProviderContainer c = await container();
      await installModule('counter');
      await c.read(chatControllerProvider.notifier).activateModule('counter');
      expect(c.read(chatControllerProvider).pendingModule, 'counter');
    },
  );

  test('staged module activates with the first message: entry output lands '
      'in a module message before the agent reply', () async {
    final ProviderContainer c = await container();
    final ChatModule mod = await installModule('counter');
    js.nextResult = const JsRunResult(output: 'Count: 1', result: '"done"');

    final ChatController controller = c.read(chatControllerProvider.notifier);
    await controller.activateModule('counter');
    await controller.send('hello');

    final ChatState state = c.read(chatControllerProvider);
    expect(state.isRunning, isFalse);
    // Message order: user -> module -> assistant.
    expect(state.messages.first.role, Role.user);
    final ChatMessage moduleMessage = state.messages[1];
    expect(moduleMessage.moduleName, 'counter');
    expect(moduleMessage.content, contains('Count: 1'));
    expect(state.messages.last.role, Role.assistant);
    expect(state.pendingModule, isNull);

    // The module ran with per-chat state dir + granted permissions.
    final ModuleInvocation invocation = js.moduleInvocations.single;
    expect(invocation.info['sessionId'], state.sessionId);
    expect(invocation.permissions, <String>{'storage'});
    expect(invocation.entrySource, '// counter entry');
    expect(File(mod.entryPath).existsSync(), isTrue);
  });

  test(
    'staged module receives the first message as zagents.info.prompt',
    () async {
      final ProviderContainer c = await container();
      await installModule('setupme');
      js.nextResult = const JsRunResult(output: 'ready', result: '"done"');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.activateModule('setupme');
      await controller.send('setup me@example.com hunter2');

      expect(js.moduleInvocations, hasLength(1));
      expect(
        js.moduleInvocations.single.info['prompt'],
        'setup me@example.com hunter2',
      );
    },
  );

  test(
    'immediate activation on an open session carries no prompt key',
    () async {
      final ProviderContainer c = await container();
      await installModule('instant');
      js.nextResult = const JsRunResult(output: 'ok');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.send('hi there');
      await controller.activateModule('instant');

      expect(js.moduleInvocations, hasLength(1));
      expect(js.moduleInvocations.single.info.containsKey('prompt'), isFalse);
    },
  );

  test('activating on an OPEN session runs the entry immediately and '
      'persists the module list', () async {
    final ProviderContainer c = await container();
    await installModule('weather');
    js.nextResult = const JsRunResult(output: 'Weather: sunny');

    final ChatController controller = c.read(chatControllerProvider.notifier);
    await controller.send('hi there'); // creates session 1
    final String sessionId = c.read(chatControllerProvider).sessionId!;
    // The run finished; now activate the module on the SAME session.
    await controller.activateModule('weather');

    final ChatState state = c.read(chatControllerProvider);
    expect(state.activeModules, <String>['weather']);
    final ChatMessage moduleMessage = state.messages.last;
    expect(moduleMessage.moduleName, 'weather');
    expect(moduleMessage.content, contains('Weather: sunny'));

    // Persisted: a fresh store read sees the module list.
    final List<String> stored = await c
        .read(chatStoreProvider)
        .loadModules(sessionId);
    expect(stored, <String>['weather']);
  });

  test('opened sessions restore their own module scope and system prompt '
      'context', () async {
    final ProviderContainer c = await container();
    await installModule('weather');
    js.nextResult = const JsRunResult(output: 'sunny');

    final ChatController controller = c.read(chatControllerProvider.notifier);
    await controller.send('first message');
    await controller.activateModule('weather');

    // Simulate reopening from history (draft → open).
    await controller.newChat();
    final String sessionId = (await c.read(chatListProvider.future)).first.id;
    await controller.openChat(
      ChatSummary(id: sessionId, title: 't', updatedAt: DateTime.now()),
    );
    expect(c.read(chatControllerProvider).activeModules, <String>['weather']);

    // Next run: the system wire carries the module context block.
    final ScriptedLlmClient llm =
        c.read(llmClientProvider) as ScriptedLlmClient;
    llm.turns.clear();
    llm.turns.add(AssistantTurn(content: 'ok'));
    await controller.send('again');
    final List<Map<String, dynamic>> wire = llm.calls.last;
    final String system = (wire.first['content'] as String?) ?? '';
    expect(system, contains('# Active module: weather v1.0.0'));
    expect(system, contains('Counts things'));
  });

  test('deactivation removes the module, persists, and appends a module '
      'message', () async {
    final ProviderContainer c = await container();
    await installModule('weather');
    js.nextResult = const JsRunResult(output: 'sunny');

    final ChatController controller = c.read(chatControllerProvider.notifier);
    await controller.send('first');
    await controller.activateModule('weather');
    expect(await controller.deactivateModule('weather'), isTrue);
    final ChatState state = c.read(chatControllerProvider);
    expect(state.activeModules, isEmpty);
    expect(state.messages.last.moduleName, 'weather');
    expect(state.messages.last.content, contains('deactivated'));

    final String sessionId = state.sessionId!;
    expect(await c.read(chatStoreProvider).loadModules(sessionId), isEmpty);
    expect(await controller.deactivateModule('weather'), isFalse);
  });

  test('module context is per chat: activating in chat 2 does not leak '
      'into chat 1 (user regression scenario)', () async {
    final ProviderContainer c = await container();
    await installModule('weather');
    js.nextResult = const JsRunResult(output: 'sunny');

    final ChatController controller = c.read(chatControllerProvider.notifier);
    // Chat 1: activate module.
    await controller.send('chat1 start');
    await controller.activateModule('weather');
    expect(c.read(chatControllerProvider).activeModules, <String>['weather']);

    // Chat 2 (new chat, no module).
    await controller.newChat();
    await controller.send('chat2 start');
    final ChatState chat2 = c.read(chatControllerProvider);
    expect(chat2.activeModules, isEmpty);

    // Chat 2's module storage/state must be separate — chat 2's run never
    // sees chat 1's module invocation state dirs.
    final Directory chat1Modules = await moduleRuntime.instanceDirFor(
      // chat 1's id came before newChat; recover from the store list.
      (await c.read(chatListProvider.future)).last.id,
      'weather',
    );
    final Directory chat2Modules = await moduleRuntime.instanceDirFor(
      chat2.sessionId!,
      'weather',
    );
    expect(chat1Modules.path != chat2Modules.path, isTrue);
    expect(chat2Modules.path.contains(chat2.sessionId!), isTrue);
  });

  test('unknown module activation surfaces a localized error', () async {
    final ProviderContainer c = await container();
    final ChatController controller = c.read(chatControllerProvider.notifier);
    await controller.send('start');
    await controller.activateModule('ghost');
    expect(
      c.read(chatControllerProvider).error,
      appStringsFor('en').moduleNotFound('ghost'),
    );
  });

  test('module run failure degrades into the module message', () async {
    final ProviderContainer c = await container();
    await installModule('broken');
    js.nextResult = const JsRunResult(output: '', error: 'boom inside');

    final ChatController controller = c.read(chatControllerProvider.notifier);
    await controller.send('start');
    await controller.activateModule('broken');

    final ChatState state = c.read(chatControllerProvider);
    final ChatMessage moduleMessage = state.messages.last;
    expect(moduleMessage.moduleName, 'broken');
    expect(
      moduleMessage.content,
      contains(appStringsFor('en').moduleRunFailed('boom inside')),
    );
    // Ordinary failures get NO setup guidance and NO form.
    expect(state.setupRequest, isNull);
  });

  test('a STALE module zip failing with setup-required gets actionable '
      'guidance — no dead end, no impossible form', () async {
    final ProviderContainer c = await container();
    // Zips installed before the setup-form feature carry NO setup block
    // and keep failing after app updates (installed modules persist).
    await installModule('legacy');
    js.nextResult = const JsRunResult(
      output: 'OnHomeroom Daily needs your account for THIS chat.',
      error: 'setup required',
    );

    final ChatController controller = c.read(chatControllerProvider.notifier);
    await controller.send('start');
    await controller.activateModule('legacy');

    final ChatState state = c.read(chatControllerProvider);
    final ChatMessage moduleMessage = state.messages.last;
    // Both the failure line and the legacy guidance (updated zip / setup
    // command) land in the transcript.
    expect(
      moduleMessage.content,
      contains(appStringsFor('en').moduleRunFailed('setup required')),
    );
    expect(
      moduleMessage.content,
      contains(appStringsFor('en').moduleSetupLegacyHint('legacy')),
    );
    // No form can be rendered for a manifest without setup fields.
    expect(state.setupRequest, isNull);
  });

  group('module doctor (agent repair staging)', () {
    // A ScriptedLlmClient consumes turns in order across sends: send #1
    // consumes the plain turn (establishes the session), send #2 runs
    // the module_stage_repair tool call + the final answer.
    Future<ProviderContainer> repairContainer() => container(
      turns: <AssistantTurn>[
        AssistantTurn(content: 'ok'),
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 't-repair',
              name: 'module_stage_repair',
              argumentsJson: jsonEncode(<String, dynamic>{
                'path': 'repaired.zip',
              }),
            ),
          ],
        ),
        AssistantTurn(content: 'Repair staged for your confirmation.'),
      ],
    );

    Future<File> writeRepairZip(ProviderContainer c) async {
      final String sessionId = c.read(chatControllerProvider).sessionId!;
      final Directory sandbox = Directory(
        '${tempDir.path}${Platform.pathSeparator}sessions'
        '${Platform.pathSeparator}$sessionId',
      )..createSync(recursive: true);
      final String manifest = jsonEncode(<String, dynamic>{
        'name': 'fixme',
        'version': '1.0.1',
        'title': 'Fixme',
        'permissions': <String>['storage'],
      });
      final List<int> manifestBytes = utf8.encode(manifest);
      final List<int> entryBytes = utf8.encode('module.exports = "fixed";');
      final Archive archive = Archive()
        ..addFile(
          ArchiveFile('module.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(ArchiveFile('main.js', entryBytes.length, entryBytes));
      return File('${sandbox.path}${Platform.pathSeparator}repaired.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
    }

    test('a staged repair surfaces the confirmation card, install goes '
        'through the full pipeline', () async {
      final ProviderContainer c = await repairContainer();
      final ChatController controller = c.read(chatControllerProvider.notifier);
      // A repair REPLACES an installed module — install the old copy
      // first so staging sees an existing module (isNew = false).
      await installModule('fixme', version: '1.0.0');

      await controller.send('start');
      final File zip = await writeRepairZip(c);
      await controller.send('perbaiki modulnya');

      final ChatState state = c.read(chatControllerProvider);
      expect(state.pendingModuleInstall, isNotNull);
      expect(state.pendingModuleInstall!.moduleName, 'fixme');
      expect(state.pendingModuleInstall!.version, '1.0.1');
      expect(state.pendingModuleInstall!.permissions, <String>['storage']);
      expect(state.pendingModuleInstall!.zipPath, zip.path);
      expect(state.pendingModuleInstall!.isNew, isFalse);
      // Staging alone does NOT replace the installed copy: the old
      // version stays active until the user taps Install.
      expect(
        (await c.read(moduleRegistryProvider).get('fixme'))!.manifest.version,
        '1.0.0',
      );

      // User taps Install: full installFromZip pipeline runs.
      final bool ok = await controller.installStagedModule();
      expect(ok, isTrue);
      expect(
        (await c.read(moduleRegistryProvider).get('fixme'))!.manifest.version,
        '1.0.1',
      );
      final ChatState after = c.read(chatControllerProvider);
      expect(after.pendingModuleInstall, isNull);
      expect(
        after.messages.last.content,
        contains(appStringsFor('en').moduleRepairInstalled('fixme')),
      );
    });

    test('discard clears the card without installing', () async {
      final ProviderContainer c = await repairContainer();
      final ChatController controller = c.read(chatControllerProvider.notifier);

      await controller.send('start');
      await writeRepairZip(c);
      await controller.send('perbaiki modulnya');
      expect(c.read(chatControllerProvider).pendingModuleInstall, isNotNull);

      controller.discardStagedModule();
      expect(c.read(chatControllerProvider).pendingModuleInstall, isNull);
      expect(await c.read(moduleRegistryProvider).get('fixme'), isNull);
    });

    test('an invalid repair zip never stages a card', () async {
      final ProviderContainer c = await container(
        turns: <AssistantTurn>[
          AssistantTurn(content: 'ok'),
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 't-bad',
                name: 'module_stage_repair',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'path': 'broken.zip',
                }),
              ),
            ],
          ),
          AssistantTurn(content: 'Sorry, the zip was invalid.'),
        ],
      );
      final ChatController controller = c.read(chatControllerProvider.notifier);

      await controller.send('start');
      final String sessionId = c.read(chatControllerProvider).sessionId!;
      final Directory sandbox = Directory(
        '${tempDir.path}${Platform.pathSeparator}sessions'
        '${Platform.pathSeparator}$sessionId',
      )..createSync(recursive: true);
      File('${sandbox.path}${Platform.pathSeparator}broken.zip')
          .writeAsBytesSync(<int>[1, 2, 3]);

      await controller.send('perbaiki');

      expect(c.read(chatControllerProvider).pendingModuleInstall, isNull);
      final ChatState state = c.read(chatControllerProvider);
      final ChatMessage toolMessage = state.messages
          .where((m) => m.toolCalls.isNotEmpty)
          .last;
      expect(toolMessage.toolCalls.single.status, ToolStatus.error);
    });
  });

  group('/make_plugins (build a new plugin in chat)', () {
    /// Scripts: turn 1 establishes the session, turn 2 stages a freshly
    /// built plugin zip via module_stage_repair, turn 3 is the answer.
    Future<ProviderContainer> buildContainer(String zipPath) => container(
      turns: <AssistantTurn>[
        AssistantTurn(content: 'ok'),
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 't-build',
              name: 'module_stage_repair',
              argumentsJson: jsonEncode(<String, dynamic>{'path': zipPath}),
            ),
          ],
        ),
        AssistantTurn(content: 'Built it — tap Install on the card.'),
      ],
    );

    /// Writes a valid fresh-module zip the way the builder flow would
    /// (plugins/<name>/<name>.zip inside the session sandbox).
    Future<File> writeBuildZip(ProviderContainer c, String name) async {
      final String sessionId = c.read(chatControllerProvider).sessionId!;
      final Directory sandbox = Directory(
        '${tempDir.path}${Platform.pathSeparator}sessions'
        '${Platform.pathSeparator}$sessionId',
      )..createSync(recursive: true);
      final String manifest = jsonEncode(<String, dynamic>{
        'name': name,
        'version': '2.0.0',
        'title': 'Quoter',
        'permissions': <String>['storage', 'network'],
      });
      final List<int> manifestBytes = utf8.encode(manifest);
      final List<int> entryBytes = utf8.encode('module.exports = "built";');
      final Archive archive = Archive()
        ..addFile(
          ArchiveFile('module.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(ArchiveFile('main.js', entryBytes.length, entryBytes));
      final Directory folder = Directory(
        '${sandbox.path}${Platform.pathSeparator}plugins'
        '${Platform.pathSeparator}$name',
      )..createSync(recursive: true);
      return File('${folder.path}${Platform.pathSeparator}$name.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
    }

    test(
      'the command expands into the builder brief on the WIRE only',
      () async {
        final ProviderContainer c = await container(
          turns: <AssistantTurn>[AssistantTurn(content: 'Will do!')],
        );
        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );

        await controller.send('/make_plugins a daily quote plugin');

        final ChatState state = c.read(chatControllerProvider);
        // Transcript keeps the raw command verbatim.
        expect(
          state.messages.firstWhere((m) => m.role == Role.user).content,
          '/make_plugins a daily quote plugin',
        );
        // The wire carried the builder specification instead.
        final ScriptedLlmClient llm =
            c.read(llmClientProvider) as ScriptedLlmClient;
        final Map<String, dynamic> wireUser = llm.calls.first.last;
        final String content = wireUser['content'].toString();
        expect(content, contains('# Task: build a NEW Noah chat module'));
        expect(content, contains('a daily quote plugin'));
        // The raw command line itself never travels on the wire (the
        // brief legitimately mentions the /make_plugins command name).
        expect(content.contains('/make_plugins a daily quote plugin'), isFalse);
        expect(content.startsWith('/make_plugins'), isFalse);
      },
    );

    test('the brief is reproduced identically when history replays', () async {
      final ProviderContainer c = await container(
        turns: <AssistantTurn>[
          AssistantTurn(content: 'first'),
          AssistantTurn(content: 'second'),
        ],
      );
      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.send('/make_plugins counter');
      await controller.send('go on');

      final ScriptedLlmClient llm =
          c.read(llmClientProvider) as ScriptedLlmClient;
      expect(llm.calls, hasLength(2));
      final String first = (llm.calls[0].last)['content'].toString();
      final String replayed = (llm.calls[1].firstWhere(
        (m) => m['role'] == 'user',
      ))['content'].toString();
      expect(first, replayed);
      expect(replayed, contains('# Task: build a NEW Noah chat module'));
    });

    test('a freshly built plugin stages with isNew and installs with '
        'builder wording', () async {
      const String name = 'quoter';
      final ProviderContainer c = await buildContainer(
        'plugins/$name/$name.zip',
      );
      final ChatController controller = c.read(chatControllerProvider.notifier);

      await controller.send('start');
      final File zip = await writeBuildZip(c, name);
      await controller.send('/make_plugins a daily quoter');

      final ChatState state = c.read(chatControllerProvider);
      expect(state.pendingModuleInstall, isNotNull);
      expect(state.pendingModuleInstall!.moduleName, name);
      expect(state.pendingModuleInstall!.version, '2.0.0');
      expect(state.pendingModuleInstall!.permissions, <String>[
        'storage',
        'network',
      ]);
      expect(state.pendingModuleInstall!.isNew, isTrue);
      expect(state.pendingModuleInstall!.zipPath, zip.path);
      // Staging alone does NOT install.
      expect(await c.read(moduleRegistryProvider).get(name), isNull);

      // User taps Install: full installFromZip pipeline runs.
      expect(await controller.installStagedModule(), isTrue);
      expect((await c.read(moduleRegistryProvider).get(name)), isNotNull);
      final ChatState after = c.read(chatControllerProvider);
      expect(after.pendingModuleInstall, isNull);
      expect(
        after.messages.last.content,
        contains(appStringsFor('en').moduleBuildInstalled(name)),
      );
    });
  });

  group('per-chat setup gate (form before first run)', () {
    Future<ChatModule> installSetupModule(String name) => installModule(
      name,
      description: 'Needs an account',
      setup: <String, dynamic>{
        'title': 'Acct',
        'fields': <dynamic>[
          <String, dynamic>{'key': 'email', 'type': 'text', 'required': true},
          <String, dynamic>{
            'key': 'password',
            'type': 'password',
            'required': true,
          },
        ],
      },
    );

    test('agent system prompt reports COMPLETED per-chat setup with masked '
        'secret after the form is submitted', () async {
      final ProviderContainer c = await container();
      await installSetupModule('wirecomp');
      js.nextResult = const JsRunResult(output: 'cycle ran');
      final ScriptedLlmClient llm =
          c.read(llmClientProvider) as ScriptedLlmClient;
      llm.turns.clear();
      llm.turns.add(AssistantTurn(content: 'noted'));

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.activateModule('wirecomp');
      await controller.send('go');
      expect(
        await controller.submitModuleSetup('wirecomp', <String, dynamic>{
          'email': 'me@example.com',
          'password': 'hunter2',
        }),
        isTrue,
      );

      // The agent turn after the resume carries the ground truth:
      // setup is COMPLETED for this chat, the email is visible, the
      // password NEVER is — so the model stops asking for it.
      expect(llm.calls, isNotEmpty);
      final String system = llm.calls.last.first['content'] as String;
      expect(system, contains('# Active module: wirecomp'));
      expect(system, contains('Setup for THIS chat: COMPLETED'));
      // Labels fall back to the field keys when the manifest omits them.
      expect(system, contains('email: me@example.com'));
      expect(system, contains('password: ********'));
      expect(system, isNot(contains('hunter2')));
      expect(system, contains('NEVER ask the user to type or repeat'));
    });

    test('setup form in a NEW chat stays EMPTY — no cross-chat prefill '
        '(v1.41.6 isolation regression)', () async {
      final ProviderContainer c = await container();
      await installSetupModule('prefillme');
      js.nextResult = const JsRunResult(output: 'cycle ran');
      final ChatController controller = c.read(chatControllerProvider.notifier);

      // Chat 1: the user submits the form normally.
      await controller.activateModule('prefillme');
      await controller.send('go');
      expect(
        await controller.submitModuleSetup('prefillme', <String, dynamic>{
          'email': 'first@example.com',
          'password': 'hunter2',
        }),
        isTrue,
      );

      // Chat 2: a brand-new chat — its form must be COMPLETELY empty.
      // The v1.33-v1.41 cross-chat prefill leaked chat 1's values into
      // chat 2's form; the user explicitly wants strict per-chat
      // isolation for the setup form fields.
      await controller.newChat();
      await controller.activateModule('prefillme');
      await controller.send('run');

      final ModuleSetupRequest? request = c
          .read(chatControllerProvider)
          .setupRequest;
      expect(request, isNotNull);
      expect(request!.moduleName, 'prefillme');
      expect(
        request.values,
        isEmpty,
        reason: 'a new chat must never inherit another chat\'s form values',
      );
      // And chat 2's own storage stays empty: nothing was copied into it.
      expect(
        await c
            .read(moduleRuntimeProvider)
            .readStoredSetup(
              c.read(chatControllerProvider).sessionId!,
              'prefillme',
            ),
        isEmpty,
        reason: 'chat 2 storage must stay empty too',
      );
    });

    test('submitModuleSetup with awaitRun:false returns before the module '
        'runs; the run then completes in the background', () async {
      final ProviderContainer c = await container();
      await installSetupModule('eagerbg');
      js.nextResult = const JsRunResult(output: 'bg cycle');
      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.activateModule('eagerbg');
      await controller.send('go');
      expect(
        await controller.submitModuleSetup('eagerbg', <String, dynamic>{
          'email': 'me@example.com',
          'password': 'hunter2',
        }, awaitRun: false),
        isTrue,
      );
      // The heavy run was scheduled in the background: it completes on
      // its own without anyone awaiting it (this is what keeps the
      // setup sheet from freezing — v1.34.0). Poll until the whole
      // background chain (module run + queued-message release) lands.
      for (var i = 0; i < 200 && js.moduleInvocations.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(js.moduleInvocations, hasLength(1));
      ChatState state = c.read(chatControllerProvider);
      for (
        var i = 0;
        i < 200 && (state.waitingForSetup || state.isRunning);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        state = c.read(chatControllerProvider);
      }
      expect(state.waitingForSetup, isFalse);
      expect(state.isRunning, isFalse);
      final Map<String, dynamic> stored = await moduleRuntime.readStoredSetup(
        state.sessionId!,
        'eagerbg',
      );
      expect(stored['email'], 'me@example.com');
    });

    test(
      'unsatisfied setup: module does NOT run, form request surfaces',
      () async {
        final ProviderContainer c = await container();
        await installSetupModule('gated');
        js.nextResult = const JsRunResult(output: 'SHOULD NOT RUN');

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.send('start');
        await controller.activateModule('gated');

        final ChatState state = c.read(chatControllerProvider);
        // No JS execution ever happened.
        expect(js.moduleInvocations, isEmpty);
        // The module is active but blocked behind its form.
        expect(state.activeModules, <String>['gated']);
        expect(state.setupRequest, isNotNull);
        expect(state.setupRequest!.moduleName, 'gated');
        expect(state.setupRequest!.setup.fields, hasLength(2));
        // Localized needs-setup message posted into the transcript.
        final ChatMessage moduleMessage = state.messages.last;
        expect(moduleMessage.moduleName, 'gated');
        expect(
          moduleMessage.content,
          contains(appStringsFor('en').moduleSetupNeededTitle('Acct')),
        );
      },
    );

    test(
      'staged module on a fresh chat QUEUES the first message behind the '
      'setup gate (v1.29.0: the agent must not run without the input)',
      () async {
        final ProviderContainer c = await container();
        await installSetupModule('staged-gate');
        js.nextResult = const JsRunResult(output: 'nope');
        final ScriptedLlmClient llm =
            c.read(llmClientProvider) as ScriptedLlmClient;

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.activateModule('staged-gate');
        await controller.send('hello there');

        final ChatState state = c.read(chatControllerProvider);
        expect(js.moduleInvocations, isEmpty);
        expect(state.setupRequest, isNotNull);
        expect(state.waitingForSetup, isTrue);
        // v1.29.0: the user message is QUEUED, the agent never answered.
        expect(state.messages.first.role, Role.user);
        expect(state.messages.last.role, Role.user);
        expect(llm.calls, isEmpty);
        expect(state.isRunning, isFalse);
        // The queued message is persisted together with the wait flag
        // (fire-and-forget persist — poll until it lands).
        final String sessionId = state.sessionId!;
        bool waitingOnDisk = false;
        List<ChatMessage>? stored;
        for (var i = 0; i < 100 && (stored == null || !waitingOnDisk); i++) {
          stored = await c.read(chatStoreProvider).load(sessionId);
          waitingOnDisk = await c
              .read(chatStoreProvider)
              .loadWaitingForSetup(sessionId);
          if (stored == null || !waitingOnDisk) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        expect(stored, isNotEmpty);
        expect(waitingOnDisk, isTrue);
      },
    );

    test(
      'submitting the setup form releases the queued message to the agent',
      () async {
        final ProviderContainer c = await container();
        final ChatModule mod = await installSetupModule('staged-gate');
        js.nextResult = const JsRunResult(output: 'gate cleared');
        final ScriptedLlmClient llm =
            c.read(llmClientProvider) as ScriptedLlmClient;
        llm.turns.clear();
        llm.turns.add(AssistantTurn(content: 'finally processed'));

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.activateModule('staged-gate');
        await controller.send('hello there');
        expect(c.read(chatControllerProvider).waitingForSetup, isTrue);

        expect(
          await controller.submitModuleSetup('staged-gate', <String, dynamic>{
            'email': 'me@example.com',
            'password': 'hunter2',
          }),
          isTrue,
        );

        final ChatState state = c.read(chatControllerProvider);
        // The module ran once — right after the form was submitted.
        expect(js.moduleInvocations, hasLength(1));
        // The queued user message finally reached the agent.
        expect(llm.calls, isNotEmpty);
        expect(state.waitingForSetup, isFalse);
        expect(state.setupRequest, isNull);
        expect(state.messages.last.role, Role.assistant);
        expect(state.messages.last.content, 'finally processed');
        // The module received the queued text as its activation prompt.
        final Map<String, dynamic> stored = await moduleRuntime.readStoredSetup(
          state.sessionId!,
          mod.name,
        );
        expect(stored, <String, dynamic>{
          'email': 'me@example.com',
          'password': 'hunter2',
        });
        // And the wait flag is cleared on disk too.
        expect(
          await c.read(chatStoreProvider).loadWaitingForSetup(state.sessionId!),
          isFalse,
        );
      },
    );

    test(
      'a second send while waiting only queues — the agent stays idle',
      () async {
        final ProviderContainer c = await container();
        await installSetupModule('staged-gate');
        final ScriptedLlmClient llm =
            c.read(llmClientProvider) as ScriptedLlmClient;

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.activateModule('staged-gate');
        await controller.send('first');
        await controller.send('second');

        final ChatState state = c.read(chatControllerProvider);
        expect(llm.calls, isEmpty);
        expect(
          state.messages.where((ChatMessage m) => m.role == Role.user).length,
          2,
        );
        expect(state.waitingForSetup, isTrue);
      },
    );

    test(
      'regenerate and edit are refused while a message waits for setup',
      () async {
        final ProviderContainer c = await container();
        await installSetupModule('staged-gate');
        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.activateModule('staged-gate');
        await controller.send('hello there');
        final String sessionId = c.read(chatControllerProvider).sessionId!;
        expect(
          await controller.regenerate(sessionId),
          isFalse,
          reason: 'the agent must not run while the setup input is missing',
        );
        expect(
          await controller.editUserMessage(sessionId, 0, 'edited'),
          isFalse,
        );
        // And the queued message is untouched.
        expect(
          c.read(chatControllerProvider).messages.first.content,
          'hello there',
        );
      },
    );

    test(
      'deactivating the gating module releases the queued message',
      () async {
        final ProviderContainer c = await container();
        await installSetupModule('staged-gate');
        js.nextResult = const JsRunResult(output: 'nope');
        final ScriptedLlmClient llm =
            c.read(llmClientProvider) as ScriptedLlmClient;

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        // The module activates on an OPEN session — its gate surfaces the
        // form (activation path), but nothing is queued yet.
        await controller.send('start the chat');
        await controller.activateModule('staged-gate');
        expect(c.read(chatControllerProvider).setupRequest, isNotNull);
        expect(c.read(chatControllerProvider).waitingForSetup, isFalse);
        // THIS send hits the v1.29.0 send-gate: queued behind the form.
        await controller.send('hello there');
        expect(c.read(chatControllerProvider).waitingForSetup, isTrue);

        llm.turns.clear();
        llm.turns.add(AssistantTurn(content: 'released'));
        expect(await controller.deactivateModule('staged-gate'), isTrue);

        final ChatState state = c.read(chatControllerProvider);
        expect(js.moduleInvocations, isEmpty);
        expect(llm.calls, isNotEmpty);
        expect(state.waitingForSetup, isFalse);
        expect(state.setupRequest, isNull);
        expect(state.messages.last.content, 'released');
      },
    );

    test(
      'submitModuleSetup persists the values and RE-RUNS the module',
      () async {
        final ProviderContainer c = await container();
        final ChatModule mod = await installSetupModule('formflow');
        js.nextResult = const JsRunResult(output: 'cycle ran');

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.send('start');
        await controller.activateModule('formflow');
        expect(c.read(chatControllerProvider).setupRequest, isNotNull);

        // Incomplete values are rejected.
        expect(
          await controller.submitModuleSetup('formflow', <String, dynamic>{
            'email': 'me@example.com',
          }),
          isFalse,
        );
        expect(js.moduleInvocations, isEmpty);

        expect(
          await controller.submitModuleSetup('formflow', <String, dynamic>{
            'email': 'me@example.com',
            'password': 'hunter2',
          }),
          isTrue,
        );

        final ChatState state = c.read(chatControllerProvider);
        expect(state.setupRequest, isNull);
        // The module ran exactly once — after the form was submitted.
        expect(js.moduleInvocations, hasLength(1));
        // The submitted values reached the per-chat instance storage.
        final Map<String, dynamic> stored = await moduleRuntime.readStoredSetup(
          state.sessionId!,
          mod.name,
        );
        expect(stored, <String, dynamic>{
          'email': 'me@example.com',
          'password': 'hunter2',
        });
        // The re-run posted the module output.
        expect(
          state.messages.where((ChatMessage m) => m.moduleName == 'formflow'),
          isNotEmpty,
        );
      },
    );

    test('submit works AFTER the agent loop dropped its run object '
        '(staged path, e2e regression)', () async {
      final ProviderContainer c = await container();
      final ChatModule mod = await installSetupModule('lateflow');
      js.nextResult = const JsRunResult(output: 'late cycle ran');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      // Staged module + first message: gate blocks, loop finishes and
      // _executeRun removes the run object from _runs.
      await controller.activateModule('lateflow');
      await controller.send('start the module');
      expect(c.read(chatControllerProvider).setupRequest, isNotNull);

      // Submitting now must still work: the run is re-materialized from
      // the persisted module scope and the request re-derived.
      expect(
        await controller.submitModuleSetup('lateflow', <String, dynamic>{
          'email': 'late@example.com',
          'password': 'hunter2',
        }),
        isTrue,
      );

      final ChatState state = c.read(chatControllerProvider);
      expect(state.setupRequest, isNull);
      expect(js.moduleInvocations, hasLength(1));
      final Map<String, dynamic> stored = await moduleRuntime.readStoredSetup(
        state.sessionId!,
        mod.name,
      );
      expect(stored['email'], 'late@example.com');
      // v1.29.0: the queued message is now processed — the module output
      // message is on the transcript AND the agent answered after it.
      expect(
        state.messages.any(
          (ChatMessage m) =>
              m.moduleName == 'lateflow' &&
              m.content.contains('late cycle ran'),
        ),
        isTrue,
      );
      expect(state.messages.last.role, Role.assistant);
      expect(state.messages.last.moduleName, isNull);
    });

    test('satisfied setup (command-path mirror) runs immediately', () async {
      final ProviderContainer c = await container();
      await installSetupModule('cmdready');
      js.nextResult = const JsRunResult(output: 'ready cycle');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.send('start');
      final String sessionId = c.read(chatControllerProvider).sessionId!;
      // The module mirrored its configured state into the cooperative key
      // (what the onhomeroom text-command path does).
      await moduleRuntime.writeStoredSetup(
        sessionId,
        'cmdready',
        <String, dynamic>{'email': 'cmd@example.com', 'password': 'p'},
      );
      await controller.activateModule('cmdready');

      final ChatState state = c.read(chatControllerProvider);
      expect(js.moduleInvocations, hasLength(1));
      expect(state.setupRequest, isNull);
      expect(state.messages.last.content, contains('ready cycle'));
    });

    test('reopening the chat resurfaces the form request for an '
        'unconfigured module', () async {
      final ProviderContainer c = await container();
      await installSetupModule('reopen');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.send('start');
      await controller.activateModule('reopen');
      expect(c.read(chatControllerProvider).setupRequest, isNotNull);

      // Leave to a draft and reopen the same chat from history.
      final String sessionId = c.read(chatControllerProvider).sessionId!;
      await controller.newChat();
      await controller.openChat(
        ChatSummary(id: sessionId, title: 't', updatedAt: DateTime.now()),
      );
      expect(c.read(chatControllerProvider).setupRequest, isNotNull);
      expect(c.read(chatControllerProvider).setupRequest!.moduleName, 'reopen');
    });

    test('deactivating the gated module clears its form request', () async {
      final ProviderContainer c = await container();
      await installSetupModule('gatedbye');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.send('start');
      await controller.activateModule('gatedbye');
      expect(c.read(chatControllerProvider).setupRequest, isNotNull);
      await controller.deactivateModule('gatedbye');
      expect(c.read(chatControllerProvider).setupRequest, isNull);
      expect(c.read(chatControllerProvider).activeModules, isEmpty);
    });

    test('system prompt notes the per-chat setup fields', () async {
      final ProviderContainer c = await container();
      await installSetupModule('noted');
      js.nextResult = const JsRunResult(output: 'ran');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.send('start');
      final String sessionId = c.read(chatControllerProvider).sessionId!;
      await moduleRuntime.writeStoredSetup(
        sessionId,
        'noted',
        <String, dynamic>{'email': 'a@b.c', 'password': 'p'},
      );
      await controller.activateModule('noted');

      final ScriptedLlmClient llm =
          c.read(llmClientProvider) as ScriptedLlmClient;
      llm.turns.clear();
      llm.turns.add(AssistantTurn(content: 'ok'));
      await controller.send('again');
      final List<Map<String, dynamic>> wire = llm.calls.last;
      final String system = (wire.first['content'] as String?) ?? '';
      expect(system, contains('# Active module: noted v1.0.0'));
      // v1.33.0: the prompt reports the PER-CHAT setup state, not just the
      // declared fields — here the values were already stored, so the
      // model learns the credentials are on file (secret masked).
      expect(system, contains('Setup for THIS chat: COMPLETED'));
      // Labels fall back to the field keys when the manifest omits them.
      expect(system, contains('email: a@b.c, password: ********'));
      expect(system, isNot(contains('password: p')));
    });
  });

  group('module command passthrough — /cmd routes to the module (v1.31.0)', () {
    test('typed command re-runs the ACTIVE module with the raw message '
        'and never calls the LLM', () async {
      final ProviderContainer c = await container();
      await installModule(
        'airplane',
        description: 'Airplane control',
        commands: <String>['airplane'],
      );
      js.nextResult = const JsRunResult(output: 'Airplane mode: ON');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      // Fresh draft → staging only; nothing runs yet.
      await controller.activateModule('airplane');
      expect(c.read(chatControllerProvider).pendingModule, 'airplane');
      expect(js.moduleInvocations, isEmpty);

      await controller.send('/airplane on');

      final ChatState state = c.read(chatControllerProvider);
      expect(state.isRunning, isFalse);
      // Exactly ONE run: the staged activation consumed the command.
      expect(js.moduleInvocations, hasLength(1));
      expect(
        js.moduleInvocations.single.info['prompt'],
        '/airplane on',
        reason: 'the raw command arrives as zagents.info.prompt',
      );
      // Transcript: user → module (command output), NO assistant turn.
      expect(state.messages.first.role, Role.user);
      expect(state.messages.first.content, '/airplane on');
      final ChatMessage moduleMessage = state.messages[1];
      expect(moduleMessage.moduleName, 'airplane');
      expect(moduleMessage.content, contains('Airplane mode: ON'));
      expect(state.messages, hasLength(2));
      // The LLM was never involved.
      final ScriptedLlmClient llm =
          c.read(llmClientProvider) as ScriptedLlmClient;
      expect(llm.calls, isEmpty);
    });

    test(
      'installed-but-inactive module auto-activates on its command',
      () async {
        final ProviderContainer c = await container();
        await installModule(
          'airplane',
          description: 'Airplane control',
          commands: <String>['airplane'],
        );
        js.nextResult = const JsRunResult(output: 'Airplane mode: OFF');

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.send('/airplane off');

        final ChatState state = c.read(chatControllerProvider);
        expect(state.activeModules, contains('airplane'));
        expect(js.moduleInvocations, hasLength(1));
        expect(js.moduleInvocations.single.info['prompt'], '/airplane off');
        expect(state.messages[1].moduleName, 'airplane');
        final ScriptedLlmClient llm =
            c.read(llmClientProvider) as ScriptedLlmClient;
        expect(llm.calls, isEmpty);
      },
    );

    test('a staged module declaring the command consumes the first message '
        'with a single run and no LLM call', () async {
      final ProviderContainer c = await container();
      await installModule(
        'airplane',
        description: 'Airplane control',
        commands: <String>['airplane'],
      );
      js.nextResult = const JsRunResult(output: 'Airplane status: OFF');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.activateModule('airplane'); // fresh draft → staged
      expect(c.read(chatControllerProvider).pendingModule, 'airplane');
      await controller.send('/airplane status');

      final ChatState state = c.read(chatControllerProvider);
      expect(state.pendingModule, isNull);
      expect(state.activeModules, contains('airplane'));
      // ONE run total — the staged activation, not a second command run.
      expect(js.moduleInvocations, hasLength(1));
      expect(js.moduleInvocations.single.info['prompt'], '/airplane status');
      expect(state.messages[1].content, contains('Airplane status: OFF'));
      final ScriptedLlmClient llm =
          c.read(llmClientProvider) as ScriptedLlmClient;
      expect(llm.calls, isEmpty);
    });

    test('a staged module WITHOUT the command does not swallow the typed '
        'command: both run and the LLM stays out', () async {
      final ProviderContainer c = await container();
      await installModule('counter'); // no commands declared
      await installModule(
        'airplane',
        description: 'Airplane control',
        commands: <String>['airplane'],
      );
      js.nextResult = const JsRunResult(output: 'Airplane mode: ON');

      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.activateModule('counter'); // staged
      await controller.send('/airplane on');

      final ChatState state = c.read(chatControllerProvider);
      // The staged module ran with the prompt, then airplane auto-ran.
      expect(js.moduleInvocations, hasLength(2));
      expect(js.moduleInvocations.first.info['prompt'], '/airplane on');
      expect(js.moduleInvocations.last.info['prompt'], '/airplane on');
      expect(state.activeModules, containsAll(<String>['counter', 'airplane']));
      final ScriptedLlmClient llm =
          c.read(llmClientProvider) as ScriptedLlmClient;
      expect(llm.calls, isEmpty);
    });

    test('unknown slash keywords keep flowing to the LLM', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'I do not know that command.'),
      ]);
      final ProviderContainer custom = await container(llm: llm);
      await installModule(
        'airplane',
        description: 'Airplane control',
        commands: <String>['airplane'],
      );

      await custom.read(chatControllerProvider.notifier).send('/wat now');

      final ChatState state = custom.read(chatControllerProvider);
      expect(state.messages.last.role, Role.assistant);
      expect(state.messages.last.content, 'I do not know that command.');
      expect(js.moduleInvocations, isEmpty);
      expect(llm.calls, hasLength(1));
    });

    test(
      'non-command messages with an active module still reach the LLM',
      () async {
        final ProviderContainer c = await container();
        await installModule(
          'airplane',
          description: 'Airplane control',
          commands: <String>['airplane'],
        );
        js.nextResult = const JsRunResult(output: 'ready');

        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.activateModule('airplane'); // activation run
        await controller.send('hello there');

        final ChatState state = c.read(chatControllerProvider);
        // Activation ran once; 'hello there' is NOT a command — LLM replies.
        expect(js.moduleInvocations, hasLength(1));
        expect(state.messages.last.role, Role.assistant);
        final ScriptedLlmClient llm =
            c.read(llmClientProvider) as ScriptedLlmClient;
        expect(llm.calls, hasLength(1));
      },
    );
  });
}
