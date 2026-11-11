import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/js_runtime.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/services/module_runtime.dart';
import 'package:noah/services/session_sandbox.dart';

import '../support/test_doubles.dart';

/// v1.38.0 regression: two chats running modules CONCURRENTLY used to
/// overwrite each other's single-slot `_RunContext` — chat.emit, storage
/// and stop all misrouted. Every bridge op now carries its run's
/// correlation token and resolves exactly one context.
void main() {
  late Directory docs;
  late SessionSandbox sandbox;
  late ScriptedJsRuntime js;
  late ModuleRuntime runtime;

  ChatModule module(String name) {
    final String dir =
        '${docs.path}${Platform.pathSeparator}modules'
        '${Platform.pathSeparator}$name';
    Directory(dir).createSync(recursive: true);
    File('$dir${Platform.pathSeparator}module.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'name': name,
        'version': '1.0.0',
        'title': name,
        'entry': 'main.js',
        'permissions': <String>['chat', 'storage', 'files', 'network'],
      }),
    );
    File('$dir${Platform.pathSeparator}main.js').writeAsStringSync('// noop');
    return ChatModule(
      path: dir,
      installedAt: DateTime.now(),
      manifest: ModuleManifest(
        name: name,
        version: '1.0.0',
        title: name,
        description: 'test module',
        entry: 'main.js',
        permissions: <ModulePermission>{
          ModulePermission.chat,
          ModulePermission.storage,
          ModulePermission.files,
          ModulePermission.network,
        },
      ),
    );
  }

  /// The runs' setup is async (module lookup, storage read) — poll until
  /// the scripted runtime has captured [n] module invocations.
  Future<void> pumpUntilInvocations(int n) async {
    for (var i = 0; i < 200 && js.moduleInvocations.length < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Holds every module "execution" open until released — like a real
  /// serialized runtime, the bridge context must stay live while ops are
  /// driven from the test.
  final List<Completer<void>> gates = <Completer<void>>[];
  void holdExecutions() {
    gates.clear();
    js.onModuleInvocation = (ModuleInvocation _) async {
      final Completer<void> gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    };
  }

  Future<void> releaseAll() async {
    for (final Completer<void> gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    js.onModuleInvocation = null;
  }

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('module_concurrent_test');
    sandbox = SessionSandbox(resolveDocumentsDir: () async => docs);
    js = ScriptedJsRuntime();
    runtime = ModuleRuntime(
      js: js,
      resolveSandboxRoot: sandbox.rootFor,
      resolveModulePath: (String name) async {
        final String path =
            '${docs.path}${Platform.pathSeparator}modules'
            '${Platform.pathSeparator}$name';
        return Directory(path).existsSync() ? path : null;
      },
      resolveSdkSource: () async => 'module.exports = zagents;',
      resolveNpmModulesRoot: () async =>
          '${docs.path}${Platform.pathSeparator}node_modules',
    );
  });

  tearDown(() async {
    await docs.delete(recursive: true);
  });

  test('overlapping runs route chat.emit to the right chat by token', () async {
    final ChatModule modA = module('moda');
    final ChatModule modB = module('modb');
    final List<String> emittedA = <String>[];
    final List<String> emittedB = <String>[];

    holdExecutions();
    final Future<ModuleRunResult> runA = runtime.run(
      sessionId: 'sessA',
      module: modA,
      granted: modA.manifest.permissions,
      onChatEmit: emittedA.add,
    );
    // B starts while A is still executing — both contexts stay live on
    // their gates until released below.
    final Future<ModuleRunResult> runB = runtime.run(
      sessionId: 'sessB',
      module: modB,
      granted: modB.manifest.permissions,
      onChatEmit: emittedB.add,
    );

    // Both invocations are now live; each carries a UNIQUE token.
    // Pick each token by module identity — registration ORDER of two
    // concurrent runs is a scheduling race (this test flaked on it).
    await pumpUntilInvocations(2);
    expect(js.moduleInvocations.length, 2);
    final String tokenA = js.moduleInvocations
        .singleWhere((ModuleInvocation i) => i.info['name'] == 'moda')
        .contextToken!;
    final String tokenB = js.moduleInvocations
        .singleWhere((ModuleInvocation i) => i.info['name'] == 'modb')
        .contextToken!;
    expect(tokenA, isNot(tokenB));

    // Cross-emitted traffic: each emit resolves to ITS OWN chat callback
    // regardless of the order the contexts were registered in.
    await runtime.handleOp(<String, dynamic>{
      'zop': 'chat.emit',
      'text': 'hello-from-B',
      '__zctx': tokenB,
    });
    await runtime.handleOp(<String, dynamic>{
      'zop': 'chat.emit',
      'text': 'hello-from-A',
      '__zctx': tokenA,
    });
    expect(emittedB, <String>['hello-from-B']);
    expect(emittedA, <String>['hello-from-A']);

    // Storage also routes by token: B's write must never land in A's
    // per-(chat,module) storage.json.
    await runtime.handleOp(<String, dynamic>{
      'zop': 'storage.set',
      'key': 'k',
      'value': 'fromB',
      '__zctx': tokenB,
    });
    await runtime.handleOp(<String, dynamic>{
      'zop': 'storage.set',
      'key': 'k',
      'value': 'fromA',
      '__zctx': tokenA,
    });
    await releaseAll();
    final ModuleRunResult doneA = await runA;
    final ModuleRunResult doneB = await runB;
    expect(doneA.ok, isTrue);
    expect(doneB.ok, isTrue);
    final Directory dirA = await runtime.instanceDirFor('sessA', 'moda');
    final Directory dirB = await runtime.instanceDirFor('sessB', 'modb');
    final Map<String, dynamic> storageA = jsonDecode(
      File('${dirA.path}${Platform.pathSeparator}storage.json')
          .readAsStringSync(),
    );
    final Map<String, dynamic> storageB = jsonDecode(
      File('${dirB.path}${Platform.pathSeparator}storage.json')
          .readAsStringSync(),
    );
    expect(storageA['k'], 'fromA');
    expect(storageB['k'], 'fromB');
  });

  test('terminateSession cancels only that session run', () async {
    final ChatModule modA = module('cancela');
    final ChatModule modB = module('cancelb');

    holdExecutions();
    final Future<ModuleRunResult> runA = runtime.run(
      sessionId: 'sessA',
      module: modA,
      granted: modA.manifest.permissions,
    );
    final Future<ModuleRunResult> runB = runtime.run(
      sessionId: 'sessB',
      module: modB,
      granted: modB.manifest.permissions,
    );
    await pumpUntilInvocations(2);
    expect(js.moduleInvocations.length, 2);

    final List<String> terminated = runtime.terminateSession('sessA');
    expect(terminated, <String>['cancela']);

    await releaseAll();
    final ModuleRunResult resultA = await runA;
    final ModuleRunResult resultB = await runB;
    expect(resultA.terminated, isTrue);
    expect(
      resultB.terminated,
      isFalse,
      reason: 'the sibling session must keep running',
    );
  });

  test('terminate(module) hits the exact (chat, module) pair', () async {
    final ChatModule mod = module('precise');
    holdExecutions();
    final Future<ModuleRunResult> run = runtime.run(
      sessionId: 's1',
      module: mod,
      granted: mod.manifest.permissions,
    );
    await pumpUntilInvocations(1);
    expect(js.moduleInvocations.length, 1);
    expect(runtime.terminate('s1', 'other-module'), isFalse);
    expect(runtime.terminate('other-session', 'precise'), isFalse);
    expect(runtime.terminate('s1', 'precise'), isTrue);
    await releaseAll();
    final ModuleRunResult result = await run;
    expect(result.terminated, isTrue);
  });

  test(
    'token-less bridge calls only resolve when exactly one run is live',
    () async {
      final ChatModule mod = module('solo');
      holdExecutions();
      final Future<ModuleRunResult> run = runtime.run(
        sessionId: 's1',
        module: mod,
        granted: mod.manifest.permissions,
      );
      await pumpUntilInvocations(1);
      expect(js.moduleInvocations.length, 1);
      // Legacy direct-call style (tests, single live run): still works.
      final Map<String, dynamic>? ok = await runtime.handleOp(<String, dynamic>{
        'zop': 'chat.emit',
        'text': 'legacy',
      });
      expect(ok?['ok'], isTrue);

      // Two live runs without a token = ambiguous → rejected.
      final ChatModule mod2 = module('duo');
      final Future<ModuleRunResult> run2 = runtime.run(
        sessionId: 's2',
        module: mod2,
        granted: mod2.manifest.permissions,
      );
      await pumpUntilInvocations(2);
      final Map<String, dynamic>? ambiguous = await runtime.handleOp(
        <String, dynamic>{'zop': 'chat.emit', 'text': 'x'},
      );
      expect(ambiguous?['ok'], isFalse);
      await releaseAll();
      await run;
      await run2;
    },
  );
}
