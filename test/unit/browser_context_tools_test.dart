import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/browser_automation.dart';
import 'package:noah/services/browser_session_isolation.dart';
import 'package:noah/services/tool_executor.dart';

import '../support/test_doubles.dart';

/// Cookie gateway double recording every mutation (copied per the
/// browser_contexts_test.dart file convention).
class _Jar implements CookieGateway {
  final Map<String, Map<String, String>> jar = <String, Map<String, String>>{};

  @override
  Future<Map<String, String>> readForUrl(String url) async =>
      Map<String, String>.of(jar[url] ?? const <String, String>{});

  @override
  Future<void> clearAll() async => jar.clear();

  @override
  Future<void> writeForUrl(String url, Map<String, String> cookies) async =>
      jar.putIfAbsent(url, () => <String, String>{}).addAll(cookies);

  @override
  Future<void> deleteForUrl(String url, {Set<String>? names}) async {
    final Map<String, String>? bucket = jar[url];
    if (bucket == null) return;
    if (names == null) {
      jar.remove(url);
    } else {
      bucket.removeWhere((String name, _) => names.contains(name));
    }
  }
}

/// Inner engine double: one instance per slot (copied per the
/// browser_contexts_test.dart file convention).
class _FakeEngine implements BrowserAutomation {
  _FakeEngine(this.shared) {
    shared.created.add(this);
  }

  final _Shared shared;
  final List<String> calls = <String>[];
  bool disposed = false;
  String pageUrl = 'about:blank';

  @override
  Future<BrowserPageInfo> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    String? sessionId,
  }) async {
    calls.add('navigate:$url');
    pageUrl = url;
    return BrowserPageInfo(url: url, title: 'T', text: 'body');
  }

  @override
  Future<Map<String, dynamic>> click({
    String? selector,
    String? text,
    String? sessionId,
  }) async => <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> type(
    String text, {
    String? selector,
    bool clear = true,
    String? sessionId,
  }) async => <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> scroll({
    String direction = 'down',
    int amount = 800,
    String? sessionId,
  }) async => <String, dynamic>{'ok': true};

  @override
  Future<String?> screenshot({
    required String saveDir,
    String? sessionId,
  }) async => null;

  @override
  Future<String> extractText({int maxLength = 8000, String? sessionId}) async =>
      'body';

  @override
  Future<String> runJs(String code, {String? sessionId}) async => 'null';

  @override
  Future<void> purgeSiteData() async => calls.add('purge');

  @override
  Future<String> reconcileOriginStorage(String payloadJson) async =>
      'reconciled';

  @override
  Future<void> resetSession() async {}

  @override
  BrowserAutomation withContext(String contextId) => this;

  @override
  void dispose() {
    disposed = true;
    shared.disposedEngines.add(this);
  }
}

class _Shared {
  final List<_FakeEngine> created = <_FakeEngine>[];
  final List<_FakeEngine> disposedEngines = <_FakeEngine>[];
  late _Jar cookies;
}

class _Harness {
  _Harness(this.store) {
    shared.cookies = _Jar();
    manager = ContextualBrowserAutomation(
      makeInner: () => _FakeEngine(shared),
      store: store,
      cookies: shared.cookies,
      maxContexts: 4,
    );
  }

  final _Shared shared = _Shared();
  final BrowserStateStore store;
  late final ContextualBrowserAutomation manager;

  _FakeEngine engine(int n) => shared.created[n];
}

BrowserStateStore _store(Directory temp) => BrowserStateStore(
  rootFor: (String? sessionId) async {
    if (sessionId == null) return temp;
    return Directory('${temp.path}${Platform.pathSeparator}$sessionId');
  },
);

/// v1.49.0 (wave-2) — the `browser_context_*` TOOL EXECUTOR: the tool defs
/// existed since 2-c core, but nothing executed them. These tests pin the
/// executor ↔ ContextualBrowserAutomation contract (manager-level APIs,
/// sessionId of the calling chat, honest error mapping) end-to-end.
void main() {
  late Directory temp;
  late Directory workspace;
  late _Harness h;
  late ToolExecutor executor;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('browser_ctx_tools');
    workspace = await Directory.systemTemp.createTemp('browser_ctx_tools_ws');
    h = _Harness(_store(temp));
    executor = ToolExecutor(
      browser: h.manager,
      resolveBaseDir: (_) async => workspace,
      isAutomationEnabled: () => true,
    );
  });

  tearDown(() async {
    h.manager.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  group('browser_context_create', () {
    test('creates a named context for THIS chat and reports it', () async {
      final ToolResult result = await executor.execute(
        'browser_context_create',
        <String, dynamic>{'name': 'work-account', 'persistent': true},
        sessionId: 'chat-1',
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('work-account'));
      expect(result.llmOutput, contains('persistent: true'));
      // The registry row exists (list proves it)…
      final ToolResult list = await executor.execute(
        'browser_context_list',
        <String, dynamic>{},
        sessionId: 'chat-1',
      );
      expect(list.ok, isTrue);
      expect(list.llmOutput, contains('- work-account [persistent]'));
      expect(list.llmOutput, contains('- default'));
    });

    test('duplicate name is an honest error, not a crash', () async {
      await executor.execute('browser_context_create', <String, dynamic>{
        'name': 'work',
      }, sessionId: 'chat-1');
      final ToolResult again = await executor.execute(
        'browser_context_create',
        <String, dynamic>{'name': 'work'},
        sessionId: 'chat-1',
      );
      expect(again.ok, isFalse);
      expect(again.llmOutput, contains('already exists'));
    });

    test('invalid and reserved names are honest errors', () async {
      for (final String name in <String>['Bad Name', '-nope', 'default']) {
        final ToolResult result = await executor.execute(
          'browser_context_create',
          <String, dynamic>{'name': name},
          sessionId: 'chat-1',
        );
        expect(result.ok, isFalse, reason: name);
        expect(result.llmOutput, contains('browser_context_create'));
      }
    });

    test('the same name coexists across DIFFERENT chats (isolation)', () async {
      final ToolResult a = await executor.execute(
        'browser_context_create',
        <String, dynamic>{'name': 'work'},
        sessionId: 'chat-a',
      );
      final ToolResult b = await executor.execute(
        'browser_context_create',
        <String, dynamic>{'name': 'work'},
        sessionId: 'chat-b',
      );
      expect(a.ok, isTrue);
      expect(b.ok, isTrue);
    });
  });

  group('browser_context_list', () {
    test(
      'scopes the rows to THIS chat and always includes the default',
      () async {
        await executor.execute('browser_context_create', <String, dynamic>{
          'name': 'a-of-chat-1',
        }, sessionId: 'chat-1');
        await executor.execute('browser_context_create', <String, dynamic>{
          'name': 'b-of-chat-2',
        }, sessionId: 'chat-2');
        final ToolResult list1 = await executor.execute(
          'browser_context_list',
          <String, dynamic>{},
          sessionId: 'chat-1',
        );
        expect(list1.llmOutput, contains('a-of-chat-1'));
        expect(list1.llmOutput, isNot(contains('b-of-chat-2')));
        expect(list1.displayText, '2 context(s)');
      },
    );
  });

  group('browser_context_close', () {
    test('closes an existing named context', () async {
      await executor.execute('browser_context_create', <String, dynamic>{
        'name': 'temp',
      }, sessionId: 'chat-1');
      final ToolResult closed = await executor.execute(
        'browser_context_close',
        <String, dynamic>{'name': 'temp'},
        sessionId: 'chat-1',
      );
      expect(closed.ok, isTrue);
      final ToolResult list = await executor.execute(
        'browser_context_list',
        <String, dynamic>{},
        sessionId: 'chat-1',
      );
      expect(list.llmOutput, isNot(contains('- temp ')));
    });

    test('unknown and reserved names are honest errors', () async {
      final ToolResult unknown = await executor.execute(
        'browser_context_close',
        <String, dynamic>{'name': 'ghost'},
        sessionId: 'chat-1',
      );
      expect(unknown.ok, isFalse);
      expect(unknown.llmOutput, contains('no such browser context'));

      final ToolResult reserved = await executor.execute(
        'browser_context_close',
        <String, dynamic>{'name': 'default'},
        sessionId: 'chat-1',
      );
      expect(reserved.ok, isFalse);
      expect(reserved.llmOutput, contains('reserved'));
    });
  });

  group('browser_navigate with a named context', () {
    test('routes the page into the DEDICATED context engine', () async {
      await executor.execute('browser_context_create', <String, dynamic>{
        'name': 'work',
      }, sessionId: 'chat-1');
      final int before = h.shared.created.length;
      final ToolResult nav = await executor.execute(
        'browser_navigate',
        <String, dynamic>{'url': 'https://example.test/', 'context': 'work'},
        sessionId: 'chat-1',
      );
      expect(nav.ok, isTrue);
      // Exactly ONE engine booted (the named slot) — the chat-default
      // slot was never created for this navigation.
      expect(h.shared.created.length, before + 1);
      expect(h.engine(before).pageUrl, 'https://example.test/');
      // The registry row recorded the visit.
      final ToolResult list = await executor.execute(
        'browser_context_list',
        <String, dynamic>{},
        sessionId: 'chat-1',
      );
      expect(list.llmOutput, contains('lastUrl: https://example.test/'));
    });

    test(
      'an unknown context name is an honest error, no engine booted',
      () async {
        final int before = h.shared.created.length;
        final ToolResult nav = await executor.execute(
          'browser_navigate',
          <String, dynamic>{'url': 'https://example.test/', 'context': 'ghost'},
          sessionId: 'chat-1',
        );
        expect(nav.ok, isFalse);
        expect(nav.llmOutput, contains('ghost'));
        expect(h.shared.created.length, before);
      },
    );
  });

  group('single-engine automations', () {
    test(
      'answer every context tool with an honest unsupported error',
      () async {
        final ToolExecutor single = ToolExecutor(
          browser: ScriptedBrowserAutomation(workspace.path),
          resolveBaseDir: (_) async => workspace,
          isAutomationEnabled: () => true,
        );
        for (final (String tool, Map<String, dynamic> args)
            in <(String, Map<String, dynamic>)>[
              ('browser_context_create', <String, dynamic>{'name': 'work'}),
              ('browser_context_list', <String, dynamic>{}),
              ('browser_context_close', <String, dynamic>{'name': 'work'}),
            ]) {
          final ToolResult result = await single.execute(
            tool,
            args,
            sessionId: 'chat-1',
          );
          expect(result.ok, isFalse, reason: tool);
          expect(result.llmOutput, contains('not supported'), reason: tool);
        }
        // And browser_navigate with a context refuses honestly, too.
        final ToolResult nav = await single.execute(
          'browser_navigate',
          <String, dynamic>{'url': 'https://example.test/', 'context': 'work'},
          sessionId: 'chat-1',
        );
        expect(nav.ok, isFalse);
        expect(nav.llmOutput, contains('not supported'));
      },
    );
  });
}
