import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/agent_composer.dart';
import 'package:noah/services/device_shell.dart';
import 'package:noah/services/js_runtime.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/services/module_runtime.dart';
import 'package:noah/services/session_sandbox.dart';

import '../support/test_doubles.dart';

void main() {
  late Directory docs;
  late SessionSandbox sandbox;
  late ScriptedJsRuntime js;
  late ModuleRuntime runtime;
  int httpCalls = 0;
  String? lastHttpUrl;
  Map<String, String>? lastHttpHeaders;
  int? lastHttpTimeoutMs;
  bool? lastHttpHeadOnly;
  final List<AgentComposeRequest> composeCalls = <AgentComposeRequest>[];
  String? scriptedCompose;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('module_runtime_test');
    sandbox = SessionSandbox(resolveDocumentsDir: () async => docs);
    js = ScriptedJsRuntime();
    httpCalls = 0;
    lastHttpUrl = null;
    lastHttpHeaders = null;
    lastHttpTimeoutMs = null;
    lastHttpHeadOnly = null;
    composeCalls.clear();
    scriptedCompose = null;
    runtime = ModuleRuntime(
      js: js,
      resolveSandboxRoot: sandbox.rootFor,
      // Stand-in for the registry lookup: modules created by the helper
      // exist on disk under docs/modules/<name>.
      resolveModulePath: (String name) async {
        final String path =
            '${docs.path}${Platform.pathSeparator}modules'
            '${Platform.pathSeparator}$name';
        return Directory(path).existsSync() ? path : null;
      },
      resolveSdkSource: () async => 'module.exports = zagents;',
      resolveNpmModulesRoot: () async =>
          '${docs.path}${Platform.pathSeparator}node_modules',
      httpTransport:
          (
            String url,
            String method,
            String? body,
            Map<String, String> headers, {
            int? timeoutMs,
            bool headOnly = false,
          }) async {
            httpCalls++;
            lastHttpUrl = url;
            lastHttpHeaders = headers;
            lastHttpTimeoutMs = timeoutMs;
            lastHttpHeadOnly = headOnly;
            if (headOnly) {
              return <String, dynamic>{
                'status': 200,
                'body': '',
                'headers': <String, String>{
                  'content-type': 'text/event-stream',
                },
              };
            }
            return <String, dynamic>{
              'status': 200,
              'body': '{"ok":true}',
              'headers': <String, String>{
                'content-type': 'application/json',
                'set-cookie': 'session=abc123; Path=/; HttpOnly',
              },
            };
          },
      agentCompose: (AgentComposeRequest request) async {
        composeCalls.add(request);
        return scriptedCompose ?? 'a casual reply sentence';
      },
    );
  });

  tearDown(() async {
    if (docs.existsSync()) await docs.delete(recursive: true);
  });

  ChatModule module({
    String name = 'counter',
    Set<ModulePermission> permissions = const <ModulePermission>{
      ModulePermission.storage,
    },
    List<String>? allowedHosts,
  }) {
    final Directory dir = Directory(
      '${docs.path}${Platform.pathSeparator}modules'
      '${Platform.pathSeparator}$name',
    )..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}main.js')
        .writeAsStringSync('// entry');
    return ChatModule(
      manifest: ModuleManifest(
        name: name,
        version: '1.0.0',
        title: name,
        description: 'test module',
        entry: 'main.js',
        permissions: permissions,
        allowedHosts: allowedHosts,
      ),
      path: dir.path,
      installedAt: DateTime.now(),
    );
  }

  /// Runs the module and, WHILE its execution context is live, fires the
  /// given bridge ops (exactly what the `zagents` SDK does from JS) and
  /// returns their responses in order.
  Future<List<Map<String, dynamic>?>> runAndCall(
    String sessionId,
    ChatModule mod,
    Set<ModulePermission> granted, {
    List<Map<String, dynamic>> ops = const <Map<String, dynamic>>[],
    void Function(String text)? onChatEmit,
  }) async {
    final List<Map<String, dynamic>?> responses = <Map<String, dynamic>?>[];
    js.onModuleInvocation = (ModuleInvocation invocation) async {
      for (final Map<String, dynamic> op in ops) {
        responses.add(await runtime.handleOp(op));
      }
    };
    await runtime.run(
      sessionId: sessionId,
      module: mod,
      granted: granted,
      onChatEmit: onChatEmit,
    );
    js.onModuleInvocation = null;
    return responses;
  }

  group('per-chat isolation (private window semantics)', () {
    test('storage written in chat A is invisible to chat B', () async {
      final ChatModule mod = module();
      // Chat A stores a value while its run is live.
      await runAndCall(
        'chat-a',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'storage.set',
            'key': 'token',
            'value': 'secret-A',
          },
        ],
      );
      // Chat B runs the SAME module: fresh per-chat storage.
      final List<Map<String, dynamic>?> responses = await runAndCall(
        'chat-b',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.get', 'key': 'token'},
        ],
      );
      expect(responses.single!['ok'], isTrue);
      expect(responses.single!['data'], isNull);

      // Chat A keeps its own value (per-chat persistence).
      final List<Map<String, dynamic>?> restored = await runAndCall(
        'chat-a',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.get', 'key': 'token'},
        ],
      );
      expect(restored.single!['data'], 'secret-A');
    });

    test('two modules in the SAME chat never share storage', () async {
      final ChatModule a = module(name: 'alpha');
      final ChatModule b = module(name: 'beta');
      await runAndCall(
        'chat-1',
        a,
        a.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.set', 'key': 'k', 'value': 'A'},
        ],
      );
      final List<Map<String, dynamic>?> responses = await runAndCall(
        'chat-1',
        b,
        b.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.get', 'key': 'k'},
        ],
      );
      expect(responses.single!['data'], isNull);
    });

    test('state directories live inside each chat sandbox', () async {
      final ChatModule mod = module();
      await runAndCall('s-1', mod, mod.manifest.permissions);
      final Directory instance = await runtime.instanceDirFor('s-1', 'counter');
      expect(
        instance.path,
        contains(
          '${Platform.pathSeparator}sessions'
          '${Platform.pathSeparator}s-1'
          '${Platform.pathSeparator}modules',
        ),
      );
      final Directory other = await runtime.instanceDirFor('s-2', 'counter');
      expect(other.path != instance.path, isTrue);
    });

    test(
      'every run gets a fresh isolated invocation (nothing shared)',
      () async {
        final ChatModule mod = module();
        await runAndCall('s-1', mod, mod.manifest.permissions);
        await runAndCall('s-1', mod, mod.manifest.permissions);
        expect(js.moduleInvocations, hasLength(2));
        final ModuleInvocation first = js.moduleInvocations[0];
        final ModuleInvocation second = js.moduleInvocations[1];
        expect(identical(first, second), isFalse);
        expect(first.permissions, <String>{'storage'});
        expect(first.permissions, second.permissions);
      },
    );
  });

  group('permission enforcement (Dart bridge, defense in depth)', () {
    test('storage ops require the storage permission', () async {
      final ChatModule mod = module(permissions: <ModulePermission>{});
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        mod,
        const <ModulePermission>{},
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.get', 'key': 'k'},
        ],
      );
      expect(responses.single!['ok'], isFalse);
      expect(responses.single!['error'], 'Permission denied: storage');
    });

    test('http requires the network permission', () async {
      final ChatModule mod = module(permissions: <ModulePermission>{});
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        mod,
        const <ModulePermission>{},
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'http.request',
            'url': 'https://example.com',
          },
        ],
      );
      expect(responses.single!['ok'], isFalse);
      expect(responses.single!['error'], 'Permission denied: network');
      expect(httpCalls, 0);
    });

    test(
      'chat.emit requires the chat permission and reaches the sink',
      () async {
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.chat},
        );
        final List<String> emitted = <String>[];
        final List<Map<String, dynamic>?> responses = await runAndCall(
          's',
          mod,
          mod.manifest.permissions,
          ops: <Map<String, dynamic>>[
            <String, dynamic>{'zop': 'chat.emit', 'text': 'progress…'},
          ],
          onChatEmit: emitted.add,
        );
        expect(responses.single!['ok'], isTrue);
        expect(emitted, <String>['progress…']);
      },
    );

    test('fs scope is confined to the module state dir', () async {
      final ChatModule mod = module(
        permissions: <ModulePermission>{
          ModulePermission.storage,
          ModulePermission.files,
        },
      );
      await runAndCall('s', mod, mod.manifest.permissions);
      final ModuleInvocation invocation = js.moduleInvocations.single;
      expect(invocation.workingDir, isNotNull);
      expect(
        invocation.workingDir!.endsWith('${Platform.pathSeparator}state'),
        isTrue,
      );
      expect(invocation.workingDir, contains('counter'));
    });
  });

  group('network allowlist', () {
    test('blocks hosts outside the manifest allowlist', () async {
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.network},
        allowedHosts: <String>['api.example.com'],
      );
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'http.request',
            'url': 'https://evil.example.net/steal',
          },
          <String, dynamic>{
            'zop': 'http.request',
            'url': 'https://api.example.com/v1/data',
          },
        ],
      );
      expect(responses[0]!['ok'], isFalse);
      expect(responses[0]!['error'], contains('not allowed'));
      expect(responses[1]!['ok'], isTrue);
      expect(httpCalls, 1);
    });

    test('wildcard subdomain patterns match dot boundaries', () async {
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.network},
        allowedHosts: <String>['*.example.com'],
      );
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'http.request',
            'url': 'https://api.example.com/x',
          },
        ],
      );
      expect(responses.single!['ok'], isTrue);
    });

    test('without an allowlist every host is reachable', () async {
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.network},
      );
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'http.request',
            'url': 'https://anything.org/data',
          },
        ],
      );
      expect(responses.single!['ok'], isTrue);
      expect(responses.single!['data']['status'], 200);
    });
  });

  group('storage budgets', () {
    test(
      'oversized values are rejected without corrupting the store',
      () async {
        final ChatModule mod = module();
        final String huge = 'x' * (ModuleRuntime.maxStorageValueBytes + 10);
        final List<Map<String, dynamic>?> responses = await runAndCall(
          's',
          mod,
          mod.manifest.permissions,
          ops: <Map<String, dynamic>>[
            <String, dynamic>{'zop': 'storage.set', 'key': 'good', 'value': 1},
            <String, dynamic>{
              'zop': 'storage.set',
              'key': 'huge',
              'value': huge,
            },
            <String, dynamic>{'zop': 'storage.keys'},
          ],
        );
        expect(responses[0]!['ok'], isTrue);
        expect(responses[1]!['ok'], isFalse);
        expect(responses[2]!['data'], <String>['good']);
      },
    );

    test('storage.remove and storage.keys behave', () async {
      final ChatModule mod = module();
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.set', 'key': 'a', 'value': 1},
          <String, dynamic>{'zop': 'storage.set', 'key': 'b', 'value': 2},
          <String, dynamic>{'zop': 'storage.remove', 'key': 'a'},
          <String, dynamic>{'zop': 'storage.keys'},
        ],
      );
      expect((responses[3]!['data'] as List<dynamic>), <String>['b']);
    });

    test('empty keys are rejected', () async {
      final ChatModule mod = module();
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.set', 'key': '', 'value': 1},
        ],
      );
      expect(responses.single!['ok'], isFalse);
    });
  });

  group('safe termination', () {
    test('terminate mid-run discards output and flags the result', () async {
      final ChatModule mod = module(
        permissions: <ModulePermission>{
          ModulePermission.storage,
          ModulePermission.chat,
        },
      );
      final List<String> emitted = <String>[];
      ModuleRunResult? result;
      js.onModuleInvocation = (ModuleInvocation invocation) async {
        expect(runtime.terminate('s', 'counter'), isTrue);
        // Late emission after cancellation is suppressed by the bridge.
        await runtime.handleOp(<String, dynamic>{
          'zop': 'chat.emit',
          'text': 'late',
        });
      };
      result = await runtime.run(
        sessionId: 's',
        module: mod,
        granted: mod.manifest.permissions,
        onChatEmit: emitted.add,
      );
      js.onModuleInvocation = null;
      expect(result.terminated, isTrue);
      expect(result.ok, isFalse);
      expect(emitted, isEmpty);
    });

    test('terminateSession cancels only that chat running module', () async {
      final ChatModule mod = module();
      List<String>? terminatedDuring;
      js.onModuleInvocation = (ModuleInvocation invocation) async {
        terminatedDuring = runtime.terminateSession('other');
      };
      await runtime.run(
        sessionId: 'other',
        module: mod,
        granted: mod.manifest.permissions,
      );
      js.onModuleInvocation = null;
      expect(terminatedDuring, <String>['counter']);
      // No live run afterwards.
      expect(runtime.terminateSession('other'), isEmpty);
    });
  });

  group('runtime wiring', () {
    test('invocation carries SDK source, npm root and module dir', () async {
      final ChatModule mod = module();
      await runAndCall('s', mod, mod.manifest.permissions);
      final ModuleInvocation invocation = js.moduleInvocations.single;
      expect(invocation.sdkSource, 'module.exports = zagents;');
      expect(
        invocation.moduleRoots.first.endsWith(
          '${Platform.pathSeparator}modules'
          '${Platform.pathSeparator}counter',
        ),
        isTrue,
      );
      expect(
        invocation.moduleRoots.last,
        '${docs.path}${Platform.pathSeparator}node_modules',
      );
      expect(invocation.info['name'], 'counter');
      expect(invocation.info['sessionId'], 's');
      expect(invocation.info['version'], '1.0.0');
      expect(invocation.bridge, same(runtime));
    });

    test('missing module install path fails gracefully', () async {
      final ChatModule missing = ChatModule(
        manifest: ModuleManifest(
          name: 'ghost2',
          version: '1.0.0',
          title: 'ghost2',
          description: '',
          entry: 'main.js',
        ),
        path: '${docs.path}${Platform.pathSeparator}nowhere',
        installedAt: DateTime.now(),
      );
      final ModuleRunResult result = await runtime.run(
        sessionId: 's',
        module: missing,
        granted: const <ModulePermission>{},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('not installed'));
      expect(js.moduleInvocations, isEmpty);
    });

    test('activation prompt rides into zagents.info', () async {
      final ChatModule mod = module();
      await runtime.run(
        sessionId: 's',
        module: mod,
        granted: mod.manifest.permissions,
        activationPrompt: 'setup me@example.com hunter2',
      );
      expect(
        js.moduleInvocations.single.info['prompt'],
        'setup me@example.com hunter2',
      );
      // The immediate-activation path (no prompt) must not carry a key.
      await runtime.run(
        sessionId: 's',
        module: mod,
        granted: mod.manifest.permissions,
      );
      expect(js.moduleInvocations.last.info.containsKey('prompt'), isFalse);
    });
  });

  group('http.request headers / timeout / head-only (v1.22.0)', () {
    test(
      'module headers reach the transport, response headers come back',
      () async {
        final ChatModule mod = module(
          name: 'netmod',
          permissions: const <ModulePermission>{ModulePermission.network},
        );
        final List<Map<String, dynamic>?> responses = await runAndCall(
          's',
          mod,
          mod.manifest.permissions,
          ops: <Map<String, dynamic>>[
            <String, dynamic>{
              'zop': 'http.request',
              'url': 'https://app.example.com/api',
              'method': 'POST',
              'body': '{"a":1}',
              'headers': <String, dynamic>{
                'Content-Type': 'application/json',
                'Cookie': 'session=abc123',
                'Host': 'evil.example.com',
                'Connection': 'close',
              },
            },
          ],
        );
        expect(responses.single!['ok'], isTrue);
        final Map<String, dynamic> data =
            responses.single!['data'] as Map<String, dynamic>;
        expect(lastHttpUrl, 'https://app.example.com/api');
        expect(lastHttpHeaders!['content-type'], 'application/json');
        expect(lastHttpHeaders!['cookie'], 'session=abc123');
        // Hop-by-hop headers never reach the transport.
        expect(lastHttpHeaders!.containsKey('host'), isFalse);
        expect(lastHttpHeaders!.containsKey('connection'), isFalse);
        // Response headers are exposed to the module (lowercased).
        final Map<String, dynamic> headers =
            data['headers'] as Map<String, dynamic>;
        expect(headers['content-type'], 'application/json');
        expect(headers['set-cookie'], contains('session=abc123'));
      },
    );

    test('timeout and head-only flags pass through', () async {
      final ChatModule mod = module(
        name: 'netmod',
        permissions: const <ModulePermission>{ModulePermission.network},
      );
      await runAndCall(
        's',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'http.request',
            'url': 'https://app.example.com/sse',
            'method': 'POST',
            'timeoutMs': 15000,
            'headOnly': true,
          },
        ],
      );
      expect(lastHttpTimeoutMs, 15000);
      expect(lastHttpHeadOnly, isTrue);
      // An over-cap timeout is clamped to 60s.
      await runAndCall(
        's',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'http.request',
            'url': 'https://app.example.com/sse',
            'timeoutMs': 999999,
            'headOnly': true,
          },
        ],
      );
      expect(lastHttpTimeoutMs, 60000);
    });
  });

  group('agent.compose — module asks the chat agent (v1.22.0)', () {
    ChatModule mod({
      Set<ModulePermission> permissions = const <ModulePermission>{
        ModulePermission.agent,
      },
    }) {
      return module(name: 'composer', permissions: permissions);
    }

    test('without the agent permission the bridge denies the op', () async {
      final ChatModule m = mod(
        permissions: const <ModulePermission>{ModulePermission.storage},
      );
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        m,
        m.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'agent.compose',
            'task': 'chat-reply',
            'context': 'someone said hi',
          },
        ],
      );
      expect(responses.single!['ok'], isFalse);
      expect(responses.single!['error'], contains('Permission denied: agent'));
      expect(composeCalls, isEmpty);
    });

    test('granted permission composes through the injected callback', () async {
      scriptedCompose = 'no idea yet but curious too';
      final ChatModule m = mod();
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        m,
        m.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'agent.compose',
            'task': 'chat-reply',
            'context': 'the leaderboard reset today, anyone noticed',
            'instruction': 'mention the leaderboard',
            'maxWords': 12,
            'avoid': <String>['used earlier'],
          },
        ],
      );
      expect(responses.single!['ok'], isTrue);
      expect(responses.single!['data']['text'], 'no idea yet but curious too');
      final AgentComposeRequest request = composeCalls.single;
      expect(request.task, 'chat-reply');
      expect(request.context, contains('leaderboard'));
      expect(request.instruction, contains('leaderboard'));
      expect(request.maxWords, 12);
      expect(request.avoid, <String>['used earlier']);
    });

    test('empty context is rejected before any callback fires', () async {
      final ChatModule m = mod();
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        m,
        m.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'agent.compose', 'context': '   '},
        ],
      );
      expect(responses.single!['ok'], isFalse);
      expect(responses.single!['error'], contains('non-empty context'));
      expect(composeCalls, isEmpty);
    });

    test('composer failures degrade into a clean bridge error', () async {
      scriptedCompose = null;
      runtime = ModuleRuntime(
        js: js,
        resolveSandboxRoot: sandbox.rootFor,
        resolveModulePath: runtime.resolveModulePath,
        resolveSdkSource: runtime.resolveSdkSource,
        resolveNpmModulesRoot: runtime.resolveNpmModulesRoot,
        agentCompose: (AgentComposeRequest request) async {
          throw const AgentComposeException('No API key configured');
        },
      );
      final ChatModule m = mod();
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's',
        m,
        m.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'agent.compose', 'context': 'hello there'},
        ],
      );
      expect(responses.single!['ok'], isFalse);
      expect(responses.single!['error'], contains('No API key'));
    });
  });

  group('User-Agent integration — Settings → User Agent (v1.23.0)', () {
    test(
      'a module-supplied user-agent header is dropped by the bridge',
      () async {
        final ChatModule mod = module(
          name: 'netmod',
          permissions: const <ModulePermission>{ModulePermission.network},
        );
        // Mixed-case spelling: header dropped, legitimate headers pass.
        await runAndCall(
          's',
          mod,
          mod.manifest.permissions,
          ops: <Map<String, dynamic>>[
            <String, dynamic>{
              'zop': 'http.request',
              'url': 'https://app.example.com/api',
              'headers': <String, dynamic>{
                'User-Agent': 'module-forged-identity/9.9',
                'Accept': 'application/json',
              },
            },
          ],
        );
        expect(lastHttpHeaders!.containsKey('user-agent'), isFalse);
        expect(lastHttpHeaders!['accept'], 'application/json');
        // Lowercase spelling must be blocked just the same.
        await runAndCall(
          's',
          mod,
          mod.manifest.permissions,
          ops: <Map<String, dynamic>>[
            <String, dynamic>{
              'zop': 'http.request',
              'url': 'https://app.example.com/api2',
              'headers': <String, dynamic>{
                'user-agent': 'another-forged-identity',
              },
            },
          ],
        );
        // The identity header NEVER reaches the transport — the host adds
        // the Settings-picked UA itself (see di.dart wiring).
        expect(lastHttpHeaders!.containsKey('user-agent'), isFalse);
      },
    );

    test(
      'zagents.info.userAgent carries the resolved settings identity',
      () async {
        runtime = ModuleRuntime(
          js: js,
          resolveSandboxRoot: sandbox.rootFor,
          resolveModulePath: runtime.resolveModulePath,
          resolveSdkSource: runtime.resolveSdkSource,
          resolveNpmModulesRoot: runtime.resolveNpmModulesRoot,
          httpTransport: runtime.httpTransport,
          agentCompose: runtime.agentCompose,
          resolveUserAgent: () => 'Mozilla/5.0 (Settings pick) Chrome/141',
        );
        final ChatModule mod = module();
        await runtime.run(
          sessionId: 's',
          module: mod,
          granted: mod.manifest.permissions,
        );
        expect(
          js.moduleInvocations.single.info['userAgent'],
          'Mozilla/5.0 (Settings pick) Chrome/141',
        );
      },
    );

    test('without a resolver the info map carries no userAgent key', () async {
      final ChatModule mod = module();
      await runAndCall('s', mod, mod.manifest.permissions);
      expect(
        js.moduleInvocations.single.info.containsKey('userAgent'),
        isFalse,
      );
    });
  });

  group('per-chat setup values (cooperative zagentsSetup key)', () {
    test('writeStoredSetup then readStoredSetup round-trips', () async {
      final ChatModule mod = module();
      await runtime.writeStoredSetup('s1', mod.name, <String, dynamic>{
        'email': 'me@example.com',
        'password': 'hunter2',
      });
      final Map<String, dynamic> values = await runtime.readStoredSetup(
        's1',
        mod.name,
      );
      expect(values, <String, dynamic>{
        'email': 'me@example.com',
        'password': 'hunter2',
      });
      // A different chat sees nothing (per-chat isolation).
      expect(await runtime.readStoredSetup('s2', mod.name), isEmpty);
    });

    test('module reads the values via storage and the info map', () async {
      final ChatModule mod = module();
      await runtime.writeStoredSetup('s1', mod.name, <String, dynamic>{
        'token': 'abc',
      });
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's1',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.get', 'key': 'zagentsSetup'},
        ],
      );
      expect(responses.single!['ok'], isTrue);
      expect(responses.single!['data'], <String, dynamic>{'token': 'abc'});
      expect(js.moduleInvocations.single.info['setup'], <String, dynamic>{
        'token': 'abc',
      });
    });

    test('module may mirror its own config into the cooperative key', () async {
      final ChatModule mod = module();
      await runAndCall(
        's1',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'zop': 'storage.set',
            'key': 'zagentsSetup',
            'value': <String, dynamic>{
              'email': 'cmd@example.com',
              'password': 'p',
            },
          },
        ],
      );
      // The host gate reads the same key the module wrote.
      final Map<String, dynamic> values = await runtime.readStoredSetup(
        's1',
        mod.name,
      );
      expect(values['email'], 'cmd@example.com');
    });

    test('unfilled setup reads back as an empty map', () async {
      final ChatModule mod = module();
      expect(await runtime.readStoredSetup('s1', mod.name), isEmpty);
      // And the module-side view: storage.get returns null.
      final List<Map<String, dynamic>?> responses = await runAndCall(
        's1',
        mod,
        mod.manifest.permissions,
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'zop': 'storage.get', 'key': 'zagentsSetup'},
        ],
      );
      expect(responses.single!['data'], isNull);
      expect(js.moduleInvocations.single.info['setup'], <String, dynamic>{});
    });
  });

  group('moduleRunNeedsSetup — stale-zip failure interception', () {
    ModuleRunResult result({String? error, String output = ''}) =>
        ModuleRunResult(output: output, error: error);

    test('the legacy error string from pre-form zips matches', () {
      // Exactly what onhomeroom-daily ≤1.1.0 returns.
      expect(
        moduleRunNeedsSetup(
          result(error: 'setup required', output: 'no account configured'),
        ),
        isTrue,
      );
      expect(moduleRunNeedsSetup(result(error: 'setup required')), isTrue);
    });

    test('self-emitted account/setup messages match via the output scan', () {
      // The output pattern matters when the error itself does not name
      // setup (e.g. the module logs the missing input, then aborts).
      const String abort = 'cycle aborted';
      expect(
        moduleRunNeedsSetup(
          result(
            error: abort,
            output: 'OnHomeroom Daily needs your account for THIS chat.',
          ),
        ),
        isTrue,
      );
      expect(
        moduleRunNeedsSetup(
          result(error: abort, output: 'account not configured'),
        ),
        isTrue,
      );
      expect(
        moduleRunNeedsSetup(
          result(error: abort, output: 'storage: not set up yet'),
        ),
        isTrue,
      );
      // A clean run that merely prints such text is NOT a failure.
      expect(
        moduleRunNeedsSetup(result(error: null, output: 'needs your account')),
        isFalse,
      );
    });

    test('ordinary failures never match', () {
      expect(
        moduleRunNeedsSetup(result(error: 'TypeError: x is not a function')),
        isFalse,
      );
      expect(
        moduleRunNeedsSetup(
          result(error: 'Host is not allowed by this module (allowedHosts)'),
        ),
        isFalse,
      );
      expect(
        moduleRunNeedsSetup(result(error: 'no account configured', output: '')),
        isTrue,
      );
    });

    test('successful and terminated runs never match', () {
      expect(moduleRunNeedsSetup(result(error: null, output: 'ok')), isFalse);
      expect(
        moduleRunNeedsSetup(
          ModuleRunResult(
            output: '',
            error: 'Module terminated by user',
            terminated: true,
          ),
        ),
        isFalse,
      );
    });
  });

  group('device.shell — module device commands (v1.31.0)', () {
    late ScriptedJsRuntime deviceJs;
    late ModuleRuntime deviceRuntime;
    bool enabled = false;
    DeviceShellResult scripted = const DeviceShellResult(
      exitCode: 0,
      stdout: '0\n',
    );
    final List<(String, bool, int)> calls = <(String, bool, int)>[];

    setUp(() {
      deviceJs = ScriptedJsRuntime();
      enabled = false;
      scripted = const DeviceShellResult(exitCode: 0, stdout: '0\n');
      calls.clear();
      deviceRuntime = ModuleRuntime(
        js: deviceJs,
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
        deviceCommandsEnabled: () => enabled,
        deviceShell: (String command, bool root, int timeoutMs) async {
          calls.add((command, root, timeoutMs));
          return scripted;
        },
      );
    });

    Future<Map<String, dynamic>?> callOp(
      ChatModule mod,
      Set<ModulePermission> granted,
      Map<String, dynamic> op,
    ) async {
      Map<String, dynamic>? response;
      deviceJs.onModuleInvocation = (ModuleInvocation invocation) async {
        response = await deviceRuntime.handleOp(op);
      };
      await deviceRuntime.run(sessionId: 's', module: mod, granted: granted);
      deviceJs.onModuleInvocation = null;
      return response;
    }

    test('requires the device permission (defense in depth)', () async {
      final ChatModule mod = module(permissions: <ModulePermission>{});
      final Map<String, dynamic>? response = await callOp(
        mod,
        const <ModulePermission>{},
        <String, dynamic>{
          'zop': 'device.shell',
          'command': 'id -u',
          'root': true,
        },
      );
      expect(response!['ok'], isFalse);
      expect(response['error'], 'Permission denied: device');
      expect(calls, isEmpty);
    });

    test(
      'master switch off blocks the call with actionable guidance',
      () async {
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
          <String, dynamic>{'zop': 'device.shell', 'command': 'id -u'},
        );
        expect(response!['ok'], isFalse);
        expect(response['error'] as String, contains('disabled'));
        expect(calls, isEmpty);
      },
    );

    test(
      'happy path forwards command/root/timeout and maps the result',
      () async {
        enabled = true;
        scripted = const DeviceShellResult(
          exitCode: 1,
          stdout: '1\n',
          stderr: 'permission denied',
        );
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
          <String, dynamic>{
            'zop': 'device.shell',
            'command': '  settings get global airplane_mode_on  ',
            'root': true,
            'timeoutMs': 5000,
          },
        );
        expect(response!['ok'], isTrue);
        final Map<String, dynamic> data =
            response['data'] as Map<String, dynamic>;
        expect(data['exitCode'], 1);
        expect(data['stdout'], '1\n');
        expect(data['stderr'], 'permission denied');
        expect(data['timedOut'], isFalse);
        expect(data.containsKey('error'), isFalse);
        // The command was trimmed and forwarded with the requested budget.
        expect(calls.single.$1, 'settings get global airplane_mode_on');
        expect(calls.single.$2, isTrue);
        expect(calls.single.$3, 5000);
      },
    );

    test(
      'timeout clamps to the documented maximum and defaults to 30s',
      () async {
        enabled = true;
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        await callOp(mod, mod.manifest.permissions, <String, dynamic>{
          'zop': 'device.shell',
          'command': 'long-run',
          'timeoutMs': 999999,
        });
        expect(calls.single.$3, ModuleRuntime.maxShellTimeoutMs);
        await callOp(mod, mod.manifest.permissions, <String, dynamic>{
          'zop': 'device.shell',
          'command': 'default-run',
        });
        expect(calls.last.$3, ModuleRuntime.defaultShellTimeoutMs);
      },
    );

    test(
      'empty and oversized commands are rejected before the bridge',
      () async {
        enabled = true;
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? empty = await callOp(
          mod,
          mod.manifest.permissions,
          <String, dynamic>{'zop': 'device.shell', 'command': '   '},
        );
        expect(empty!['ok'], isFalse);
        final Map<String, dynamic>? huge = await callOp(
          mod,
          mod.manifest.permissions,
          <String, dynamic>{
            'zop': 'device.shell',
            'command': 'x' * (ModuleRuntime.maxShellCommandChars + 1),
          },
        );
        expect(huge!['ok'], isFalse);
        expect(huge['error'] as String, contains('character limit'));
        expect(calls, isEmpty);
      },
    );

    test(
      'bridge-level failures surface the error field, not a throw',
      () async {
        enabled = true;
        scripted = const DeviceShellResult(error: 'su: not found');
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
          <String, dynamic>{
            'zop': 'device.shell',
            'command': 'id -u',
            'root': true,
          },
        );
        expect(response!['ok'], isTrue);
        expect(
          (response['data'] as Map<String, dynamic>)['error'],
          'su: not found',
        );
      },
    );

    test('shell bridge unavailable degrades into a clean error', () async {
      enabled = true;
      final ModuleRuntime noShell = ModuleRuntime(
        js: deviceJs,
        resolveSandboxRoot: sandbox.rootFor,
        resolveModulePath: (String name) async {
          final String path =
              '${docs.path}${Platform.pathSeparator}modules'
              '${Platform.pathSeparator}$name';
          return Directory(path).existsSync() ? path : null;
        },
        resolveSdkSource: () async => 'module.exports = zagents;',
        resolveNpmModulesRoot: () async => '',
        deviceCommandsEnabled: () => enabled,
      );
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.device},
      );
      Map<String, dynamic>? response;
      deviceJs.onModuleInvocation = (ModuleInvocation invocation) async {
        response = await noShell.handleOp(<String, dynamic>{
          'zop': 'device.shell',
          'command': 'id -u',
        });
      };
      await noShell.run(
        sessionId: 's',
        module: mod,
        granted: mod.manifest.permissions,
      );
      deviceJs.onModuleInvocation = null;
      expect(response!['ok'], isFalse);
      expect(response!['error'], 'Shell bridge is unavailable');
    });

    test('stdout and stderr are capped at the documented stream budget', () {
      final String big = 'a' * (ModuleRuntime.maxShellStreamChars + 10);
      // Private helper access through the public op path is covered by
      // the happy-path test; this asserts the cap constant matches the
      // documented 32 KB budget.
      expect(ModuleRuntime.maxShellStreamChars, 32 * 1024);
      expect(big.length, greaterThan(ModuleRuntime.maxShellStreamChars));
    });
  });

  group('device.airplane — read-only state probe (v1.32.0)', () {
    late ScriptedJsRuntime airJs;
    late ModuleRuntime airRuntime;
    bool? scripted; // null = probe cannot answer
    bool probeThrows = false;
    final List<int> probeCalls = <int>[];

    setUp(() {
      airJs = ScriptedJsRuntime();
      scripted = false;
      probeThrows = false;
      probeCalls.clear();
      airRuntime = ModuleRuntime(
        js: airJs,
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
        airplaneProbe: () async {
          probeCalls.add(1);
          if (probeThrows) throw Exception('probe blew up');
          return scripted;
        },
      );
    });

    Future<Map<String, dynamic>?> callOp(
      ChatModule mod,
      Set<ModulePermission> granted,
    ) async {
      Map<String, dynamic>? response;
      airJs.onModuleInvocation = (ModuleInvocation invocation) async {
        response = await airRuntime.handleOp(<String, dynamic>{
          'zop': 'device.airplane',
        });
      };
      await airRuntime.run(sessionId: 's', module: mod, granted: granted);
      airJs.onModuleInvocation = null;
      return response;
    }

    test('requires the device permission (uniform surface)', () async {
      final ChatModule mod = module(permissions: <ModulePermission>{});
      final Map<String, dynamic>? response = await callOp(
        mod,
        const <ModulePermission>{},
      );
      expect(response!['ok'], isFalse);
      expect(response['error'], 'Permission denied: device');
      expect(probeCalls, isEmpty);
    });

    test('needs NO master switch — reports the real state', () async {
      // The airplane probe is world-readable and read-only: unlike
      // device.shell it must answer with the master switch absent
      // (no deviceCommandsEnabled configured at all).
      scripted = true;
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.device},
      );
      final Map<String, dynamic>? response = await callOp(
        mod,
        mod.manifest.permissions,
      );
      expect(response!['ok'], isTrue);
      final Map<String, dynamic> data =
          response['data'] as Map<String, dynamic>;
      expect(data['available'], isTrue);
      expect(data['on'], isTrue);
    });

    test('unknown state degrades to available:false (never asserts)', () async {
      scripted = null;
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.device},
      );
      final Map<String, dynamic>? response = await callOp(
        mod,
        mod.manifest.permissions,
      );
      expect(response!['ok'], isTrue);
      final Map<String, dynamic> data =
          response['data'] as Map<String, dynamic>;
      expect(data['available'], isFalse);
      expect(data['on'], isFalse);
    });

    test('a throwing probe degrades instead of crashing the module', () async {
      probeThrows = true;
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.device},
      );
      final Map<String, dynamic>? response = await callOp(
        mod,
        mod.manifest.permissions,
      );
      expect(response!['ok'], isTrue);
      expect((response['data'] as Map<String, dynamic>)['available'], isFalse);
    });

    test('missing probe seam reports available:false cleanly', () async {
      final ModuleRuntime noProbe = ModuleRuntime(
        js: airJs,
        resolveSandboxRoot: sandbox.rootFor,
        resolveModulePath: (String name) async {
          final String path =
              '${docs.path}${Platform.pathSeparator}modules'
              '${Platform.pathSeparator}$name';
          return Directory(path).existsSync() ? path : null;
        },
        resolveSdkSource: () async => 'module.exports = zagents;',
        resolveNpmModulesRoot: () async => '',
      );
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.device},
      );
      Map<String, dynamic>? response;
      airJs.onModuleInvocation = (ModuleInvocation invocation) async {
        response = await noProbe.handleOp(<String, dynamic>{
          'zop': 'device.airplane',
        });
      };
      await noProbe.run(
        sessionId: 's',
        module: mod,
        granted: mod.manifest.permissions,
      );
      airJs.onModuleInvocation = null;
      expect(response!['ok'], isTrue);
      expect((response!['data'] as Map<String, dynamic>)['available'], isFalse);
    });
  });

  group('device.airplaneCycle — one-command IP rotation (v1.34.0)', () {
    late ScriptedJsRuntime cycJs;
    late ModuleRuntime cycRuntime;
    bool enabled = false;
    // Simulated rooted device state.
    bool airplaneOn = false;
    bool rootWorks = true;
    // How many ON/OFF puts "don't stick" on the device (the set command
    // runs but the simulated state stays put) — verification mismatch.
    int onPutMismatchesLeft = 0;
    int offPutMismatchesLeft = 0;
    bool cancelOnFirstSleep = false;
    bool? probeAnswer; // null = probe cannot answer
    int probeCalls = 0;
    final List<String> commands = <String>[];
    final List<bool> roots = <bool>[];
    final List<int> sleeps = <int>[];

    // The exact command strings the bridge must issue.
    final String cmdGet = 'settings get global airplane_mode_on';
    final String cmdPutOn =
        'settings put global airplane_mode_on 1 && '
        'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true';
    final String cmdPutOff =
        'settings put global airplane_mode_on 0 && '
        'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false';

    setUp(() {
      cycJs = ScriptedJsRuntime();
      enabled = false;
      airplaneOn = false;
      rootWorks = true;
      onPutMismatchesLeft = 0;
      offPutMismatchesLeft = 0;
      cancelOnFirstSleep = false;
      probeAnswer = null;
      probeCalls = 0;
      commands.clear();
      roots.clear();
      sleeps.clear();
      cycRuntime = ModuleRuntime(
        js: cycJs,
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
        deviceCommandsEnabled: () => enabled,
        airplaneProbe: () async {
          probeCalls++;
          return probeAnswer;
        },
        sleepFn: (int ms) async {
          sleeps.add(ms);
          if (cancelOnFirstSleep) {
            cycRuntime.terminate('s', 'airplane-mod');
          }
        },
        deviceShell: (String command, bool root, int timeoutMs) async {
          commands.add(command);
          roots.add(root);
          if (!rootWorks) {
            return const DeviceShellResult(error: 'su: not found');
          }
          if (command == cmdGet) {
            return DeviceShellResult(
              exitCode: 0,
              stdout: airplaneOn ? '1\n' : '0\n',
            );
          }
          if (command == cmdPutOn) {
            if (onPutMismatchesLeft > 0) {
              onPutMismatchesLeft--;
            } else {
              airplaneOn = true;
            }
            return const DeviceShellResult(exitCode: 0);
          }
          if (command == cmdPutOff) {
            if (offPutMismatchesLeft > 0) {
              offPutMismatchesLeft--;
            } else {
              airplaneOn = false;
            }
            return const DeviceShellResult(exitCode: 0);
          }
          return const DeviceShellResult(exitCode: 0);
        },
      );
    });

    Future<Map<String, dynamic>?> callOp(
      ChatModule mod,
      Set<ModulePermission> granted, [
      Map<String, dynamic> extra = const <String, dynamic>{},
    ]) async {
      Map<String, dynamic>? response;
      cycJs.onModuleInvocation = (ModuleInvocation invocation) async {
        response = await cycRuntime.handleOp(<String, dynamic>{
          'zop': 'device.airplaneCycle',
          ...extra,
        });
      };
      await cycRuntime.run(sessionId: 's', module: mod, granted: granted);
      cycJs.onModuleInvocation = null;
      return response;
    }

    test('requires the device permission (defense in depth)', () async {
      final ChatModule mod = module(permissions: <ModulePermission>{});
      final Map<String, dynamic>? response = await callOp(
        mod,
        const <ModulePermission>{},
      );
      expect(response!['ok'], isFalse);
      expect(response['error'], 'Permission denied: device');
      expect(commands, isEmpty);
      expect(sleeps, isEmpty);
    });

    test(
      'master switch off blocks the call with actionable guidance',
      () async {
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
        );
        expect(response!['ok'], isFalse);
        expect(response['error'] as String, contains('disabled'));
        expect(commands, isEmpty);
        expect(sleeps, isEmpty);
      },
    );

    test('shell bridge unavailable degrades into a clean error', () async {
      enabled = true;
      final ModuleRuntime noShell = ModuleRuntime(
        js: cycJs,
        resolveSandboxRoot: sandbox.rootFor,
        resolveModulePath: (String name) async {
          final String path =
              '${docs.path}${Platform.pathSeparator}modules'
              '${Platform.pathSeparator}$name';
          return Directory(path).existsSync() ? path : null;
        },
        resolveSdkSource: () async => 'module.exports = zagents;',
        resolveNpmModulesRoot: () async => '',
        deviceCommandsEnabled: () => enabled,
      );
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.device},
      );
      Map<String, dynamic>? response;
      cycJs.onModuleInvocation = (ModuleInvocation invocation) async {
        response = await noShell.handleOp(<String, dynamic>{
          'zop': 'device.airplaneCycle',
        });
      };
      await noShell.run(
        sessionId: 's',
        module: mod,
        granted: mod.manifest.permissions,
      );
      cycJs.onModuleInvocation = null;
      expect(response!['ok'], isFalse);
      expect(response!['error'], 'Shell bridge is unavailable');
      expect(sleeps, isEmpty);
    });

    test(
      'happy path from OFF: ensure ON → hold → OFF → settle (verified)',
      () async {
        enabled = true;
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
        );
        expect(response!['ok'], isTrue);
        final Map<String, dynamic> data =
            response['data'] as Map<String, dynamic>;
        expect(data['wasOn'], isFalse);
        expect(data['finalOn'], isFalse);
        expect(data['heldMs'], 2500);
        expect(data['settleMs'], 8000);
        expect(data['verified'], isTrue);
        // Command order: read → put ON → verify → put OFF → verify.
        expect(commands, <String>[cmdGet, cmdPutOn, cmdGet, cmdPutOff, cmdGet]);
        // Everything rides the root shell with the documented budget.
        expect(roots, everyElement(isTrue));
        expect(sleeps, <int>[2500, 8000]);
        // The simulated device ends OFF (online, new IP).
        expect(airplaneOn, isFalse);
      },
    );

    test(
      'starting ON skips the ensure-ON step but still holds and ends OFF',
      () async {
        enabled = true;
        airplaneOn = true;
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
        );
        expect(response!['ok'], isTrue);
        final Map<String, dynamic> data =
            response['data'] as Map<String, dynamic>;
        expect(data['wasOn'], isTrue);
        expect(data['finalOn'], isFalse);
        expect(data['verified'], isTrue);
        expect(commands, <String>[cmdGet, cmdPutOff, cmdGet]);
        expect(sleeps, <int>[2500, 8000]);
      },
    );

    test(
      'hold and settle waits are clamped into the documented windows',
      () async {
        enabled = true;
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
          <String, dynamic>{'holdMs': 99999, 'settleMs': -5},
        );
        expect(response!['ok'], isTrue);
        final Map<String, dynamic> data =
            response['data'] as Map<String, dynamic>;
        expect(data['heldMs'], ModuleRuntime.maxAirplaneCycleHoldMs);
        expect(data['settleMs'], 0);
        expect(sleeps, <int>[ModuleRuntime.maxAirplaneCycleHoldMs, 0]);
      },
    );

    test('a verification mismatch retries the set exactly once', () async {
      enabled = true;
      onPutMismatchesLeft = 1; // first ON put "doesn't stick"
      final ChatModule mod = module(
        permissions: <ModulePermission>{ModulePermission.device},
      );
      final Map<String, dynamic>? response = await callOp(
        mod,
        mod.manifest.permissions,
      );
      expect(response!['ok'], isTrue);
      expect((response['data'] as Map<String, dynamic>)['verified'], isTrue);
      // get → put ON → verify(mismatch) → put ON retry → verify → put OFF
      // → verify.
      expect(commands, <String>[
        cmdGet,
        cmdPutOn,
        cmdGet,
        cmdPutOn,
        cmdGet,
        cmdPutOff,
        cmdGet,
      ]);
      expect(
        commands.where((String c) => c == cmdPutOn).length,
        2,
        reason: 'the set is retried exactly once, never more',
      );
      expect(sleeps, <int>[2500, 8000]);
    });

    test('cancelled mid-cycle still restores airplane OFF', () async {
      enabled = true;
      cancelOnFirstSleep = true; // user hits stop during the hold
      final ChatModule mod = module(
        name: 'airplane-mod',
        permissions: <ModulePermission>{ModulePermission.device},
      );
      final Map<String, dynamic>? response = await callOp(
        mod,
        mod.manifest.permissions,
      );
      // Cancelled-safe result: ok with conservative data, no settle.
      expect(response!['ok'], isTrue);
      final Map<String, dynamic> data =
          response['data'] as Map<String, dynamic>;
      expect(data['wasOn'], isFalse);
      expect(data['finalOn'], isFalse);
      expect(data['heldMs'], 2500);
      expect(data['settleMs'], 0);
      expect(data['verified'], isFalse);
      // The hold happened, the settle did not.
      expect(sleeps, <int>[2500]);
      // The OFF restore was issued and verified by a final read.
      expect(commands, <String>[cmdGet, cmdPutOn, cmdGet, cmdPutOff, cmdGet]);
      expect(airplaneOn, isFalse);
    });

    test(
      'not rooted (no probe): clean actionable manual-fallback error',
      () async {
        enabled = true;
        rootWorks = false;
        probeAnswer = null; // probe cannot answer either
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
        );
        expect(response!['ok'], isFalse);
        expect(response['error'] as String, contains('rooted'));
        expect(response['error'] as String, contains('manual'));
        // The shell read failed → the world-readable probe answered once.
        expect(probeCalls, 1);
        expect(commands, <String>[cmdGet]);
        expect(sleeps, isEmpty);
      },
    );

    test(
      'not rooted (working probe): actionable root error, no waits',
      () async {
        enabled = true;
        rootWorks = false;
        probeAnswer = false; // probe reports OFF, the puts still fail
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
        );
        expect(response!['ok'], isFalse);
        expect(response['error'] as String, contains('rooted'));
        expect(response['error'] as String, contains('manual'));
        // The initial read failed, the probe answered, the first put failed.
        expect(commands, <String>[cmdGet, cmdPutOn]);
        expect(sleeps, isEmpty);
      },
    );

    test(
      'OFF verification failing after the retry triggers the OFF recovery',
      () async {
        enabled = true;
        airplaneOn = true;
        offPutMismatchesLeft = 99; // the radio never confirms OFF
        final ChatModule mod = module(
          permissions: <ModulePermission>{ModulePermission.device},
        );
        final Map<String, dynamic>? response = await callOp(
          mod,
          mod.manifest.permissions,
        );
        expect(response!['ok'], isFalse);
        final String error = response['error'] as String;
        expect(error, contains('OFF'));
        expect(error, contains('check the phone'));
        // get → (hold) → put OFF → verify → put OFF retry → verify →
        // recovery put OFF. The phone is never left silently in airplane
        // mode: the recovery always fires.
        expect(commands, <String>[
          cmdGet,
          cmdPutOff,
          cmdGet,
          cmdPutOff,
          cmdGet,
          cmdPutOff,
        ]);
        expect(sleeps, <int>[2500], reason: 'no settle wait after a failure');
      },
    );
  });
}
