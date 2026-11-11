import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/browser_automation.dart';
import 'package:noah/services/browser_session_isolation.dart';

/// Cookie gateway double recording every mutation.
class _Jar implements CookieGateway {
  final Map<String, Map<String, String>> jar = <String, Map<String, String>>{};
  int clearCalls = 0;
  final List<String> deletions = <String>[];

  @override
  Future<Map<String, String>> readForUrl(String url) async =>
      Map<String, String>.of(jar[url] ?? const <String, String>{});

  @override
  Future<void> clearAll() async {
    clearCalls++;
    jar.clear();
  }

  @override
  Future<void> writeForUrl(String url, Map<String, String> cookies) async {
    jar.putIfAbsent(url, () => <String, String>{}).addAll(cookies);
  }

  @override
  Future<void> deleteForUrl(String url, {Set<String>? names}) async {
    deletions.add(
      '$url|${names == null ? '*' : (names.toList()..sort()).join(',')}',
    );
    final bucket = jar[url];
    if (bucket == null) return;
    if (names == null) {
      jar.remove(url);
    } else {
      bucket.removeWhere((String name, _) => names.contains(name));
    }
  }
}

/// State shared by all engines of one manager under test.
class _Shared {
  int navigationsStarted = 0;
  int barrierAt = 0;
  Completer<void>? barrier;
  final List<_FakeEngine> created = <_FakeEngine>[];
  final List<_FakeEngine> disposedEngines = <_FakeEngine>[];
  late _Jar cookies;
}

/// Inner engine double: one instance per slot (recorded in [shared.created]),
/// supports a barrier so tests can prove two contexts really run at the
/// same time.
class _FakeEngine implements BrowserAutomation {
  _FakeEngine(this.shared) {
    shared.created.add(this);
  }

  final _Shared shared;
  final List<String> calls = <String>[];
  bool disposed = false;
  String pageUrl = 'about:blank';

  /// When set, a navigate whose URL contains [holdOnUrl] blocks until
  /// [holdGate] completes — lets a test park one context mid-operation.
  String? holdOnUrl;
  Completer<void>? holdGate;

  /// Site cookies written into the shared jar when a page loads.
  Map<String, String> siteCookies = const <String, String>{};

  void _startBarrier() {
    shared.navigationsStarted++;
    if (shared.navigationsStarted >= shared.barrierAt) {
      shared.barrier?.complete();
      shared.barrier = null;
    }
    shared.barrier ??= Completer<void>();
  }

  @override
  Future<BrowserPageInfo> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    String? sessionId,
  }) async {
    calls.add('navigate:$url');
    pageUrl = url;
    if (holdOnUrl != null && url.contains(holdOnUrl!)) {
      holdGate ??= Completer<void>();
      await holdGate!.future;
    }
    if (shared.barrierAt > 0) {
      _startBarrier();
      // Serialized engines deadlock here: the sibling navigate can never
      // start while this one blocks the single shared lock.
      await shared.barrier!.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    if (siteCookies.isNotEmpty) {
      await shared.cookies.writeForUrl(url, siteCookies);
    }
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
  Future<String> runJs(String code, {String? sessionId}) async {
    if (code.contains('location.href')) {
      return jsonEncode(<String, dynamic>{
        'href': pageUrl,
        'cookie': siteCookies.entries
            .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
            .join('; '),
        'local': <String, String>{},
        'session': <String, String>{},
      });
    }
    return 'null';
  }

  @override
  Future<void> purgeSiteData() async {
    calls.add('purge');
  }

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

class _Harness {
  _Harness(this.store, {this.maxContexts = 4, this.configureEngine}) {
    shared.cookies = _Jar();
    manager = ContextualBrowserAutomation(
      makeInner: () {
        final _FakeEngine engine = _FakeEngine(shared);
        configureEngine?.call(shared.created.length - 1, engine);
        return engine;
      },
      store: store,
      cookies: shared.cookies,
      maxContexts: maxContexts,
    );
  }

  final _Shared shared = _Shared();
  final BrowserStateStore store;
  final int maxContexts;
  final void Function(int index, _FakeEngine engine)? configureEngine;
  late final ContextualBrowserAutomation manager;

  /// Engine created Nth (slot creation follows first use of each context).
  _FakeEngine engine(int n) => shared.created[n];
}

BrowserStateStore _store(Directory temp) => BrowserStateStore(
  rootFor: (String? sessionId) async {
    if (sessionId == null) return temp;
    return Directory('${temp.path}${Platform.pathSeparator}$sessionId');
  },
);

void main() {
  late Directory temp;
  late BrowserStateStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('browser_ctx_test');
    store = _store(temp);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('context engine basics', () {
    test('each named context gets its OWN engine, reused across ops', () async {
      final _Harness h = _Harness(store);
      await h.manager.withContext('sub-1').navigate('https://a.test/');
      await h.manager.withContext('sub-1').extractText();
      await h.manager.withContext('sub-2').navigate('https://b.test/');
      // Two contexts -> exactly two engines; the same context reused its
      // engine for the second operation.
      expect(h.shared.created, hasLength(2));
      expect(h.engine(0).calls.length, greaterThanOrEqualTo(2));
      h.manager.dispose();
    });

    test('parallel contexts do NOT wait for each other', () async {
      final _Harness h = _Harness(store)..shared.barrierAt = 2;
      // Both engines must be inside navigate TOGETHER: a serialized engine
      // would deadlock (2s timeout) and fail this test.
      final Future<BrowserPageInfo> a = h.manager
          .withContext('sub-a')
          .navigate('https://a.test/');
      final Future<BrowserPageInfo> b = h.manager
          .withContext('sub-b')
          .navigate('https://b.test/');
      final List<BrowserPageInfo> results = await Future.wait(
        <Future<BrowserPageInfo>>[a, b],
      );
      expect(results, hasLength(2));
      expect(h.shared.navigationsStarted, greaterThanOrEqualTo(2));
      h.manager.dispose();
    });

    test('same context serializes its own operations', () async {
      final _Harness h = _Harness(store);
      final List<int> order = <int>[];
      final Future<String> t1 = h.manager.withContext('c').runJs('1').then((
        String v,
      ) {
        order.add(1);
        return v;
      });
      final Future<String> t2 = h.manager.withContext('c').runJs('2').then((
        String v,
      ) {
        order.add(2);
        return v;
      });
      await Future.wait(<Future<String>>[t1, t2]);
      expect(order, <int>[1, 2]);
      h.manager.dispose();
    });
  });

  group('state persistence', () {
    test(
      'chat-session context persists browser_state.json in its sandbox',
      () async {
        final _Harness h = _Harness(
          store,
          configureEngine: (int n, _FakeEngine e) =>
              e.siteCookies = <String, String>{'sid': 'abc'},
        );
        await h.manager.navigate('https://x.test/home', sessionId: 'sess-1');
        final file = File(
          '${temp.path}${Platform.pathSeparator}sess-1${Platform.pathSeparator}'
          'browser_state.json',
        );
        expect(file.existsSync(), isTrue);
        final BrowserState state = await store.load('sess-1');
        expect(state.origins['https://x.test']!.cookies['sid'], 'abc');
        h.manager.dispose();
      },
    );

    test('ephemeral subagent context never persists state to disk', () async {
      final _Harness h = _Harness(
        store,
        configureEngine: (int n, _FakeEngine e) =>
            e.siteCookies = <String, String>{'sid': 'sub'},
      );
      await h.manager
          .withContext('sub-1')
          .navigate('https://x.test/home', sessionId: 'sess-1');
      final file = File(
        '${temp.path}${Platform.pathSeparator}sess-1${Platform.pathSeparator}'
        'browser_state.json',
      );
      expect(file.existsSync(), isFalse);
      h.manager.dispose();
    });
  });

  group('shared cookie jar hygiene', () {
    test(
      'first operation of the process purges the jar exactly once',
      () async {
        final _Harness h = _Harness(store);
        await h.manager.navigate('https://a.test/', sessionId: 's1');
        expect(h.shared.cookies.clearCalls, 1);
        expect(h.engine(0).calls.contains('purge'), isTrue);
        await h.manager
            .withContext('sub-1')
            .navigate('https://b.test/', sessionId: 's1');
        expect(
          h.shared.cookies.clearCalls,
          1,
          reason: 'purge is process-once; parallel-era contexts never clearAll',
        );
        h.manager.dispose();
      },
    );

    test(
      'first visit of an origin removes IDLE other-context cookie names',
      () async {
        final _Harness h = _Harness(
          store,
          configureEngine: (int n, _FakeEngine e) {
            if (n == 0) e.siteCookies = <String, String>{'sid': 'A-token'};
          },
        );
        // Context A logs into x.test.
        await h.manager.withContext('a').navigate('https://x.test/home');
        expect(h.shared.cookies.jar['https://x.test/home']!['sid'], 'A-token');

        // Context B (A idle now) visits the same origin: A's names must be
        // taken off the shared jar before B's first load.
        await h.manager.withContext('b').navigate('https://x.test/other');
        expect(
          h.shared.cookies.deletions.any(
            (String d) => d == 'https://x.test/home|sid',
          ),
          isTrue,
        );
        expect(
          h.shared.cookies.jar['https://x.test/home']!.containsKey('sid'),
          isFalse,
        );
        h.manager.dispose();
      },
    );

    test('a BUSY other context is never yanked from the jar', () async {
      final _Harness h = _Harness(
        store,
        configureEngine: (int n, _FakeEngine e) {
          if (n == 0) e.siteCookies = <String, String>{'sid': 'A-token'};
        },
      );
      await h.manager.withContext('a').navigate('https://x.test/home');

      // Park context A mid-navigation on the same origin.
      final Completer<void> releaseA = Completer<void>();
      final _FakeEngine engineA = h.engine(0);
      engineA.holdOnUrl = 'hold';
      engineA.holdGate = releaseA;
      final Future<BrowserPageInfo> blockedA = h.manager
          .withContext('a')
          .navigate('https://x.test/hold');
      // Let A's navigate actually enter its engine before B claims.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engineA.pageUrl, 'https://x.test/hold');

      // B visits the same origin while A is mid-op.
      await h.manager.withContext('b').navigate('https://x.test/other');
      expect(
        h.shared.cookies.deletions,
        isEmpty,
        reason: 'A is mid-op on x.test; B must not delete its cookies',
      );
      releaseA.complete();
      await blockedA;
      h.manager.dispose();
    });
  });

  group('eviction', () {
    test(
      'LRU eviction disposes the idle engine and releases its cookies',
      () async {
        final _Harness h = _Harness(
          store,
          maxContexts: 1,
          configureEngine: (int n, _FakeEngine e) {
            if (n == 0) e.siteCookies = <String, String>{'sid': 'A-token'};
          },
        );
        await h.manager.withContext('a').navigate('https://x.test/home');
        final _FakeEngine engineA = h.engine(0);

        await h.manager.withContext('b').navigate('https://y.test/');
        // Cap=1: A's slot must have been evicted (async cleanup).
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(engineA.disposed, isTrue);
        expect(
          h.shared.cookies.deletions.any(
            (String d) => d == 'https://x.test/home|sid',
          ),
          isTrue,
          reason: 'evicted ephemeral context logs out of the shared jar',
        );
        // The evicted context is recreated on demand (fresh engine).
        await h.manager.withContext('a').navigate('https://x.test/home2');
        expect(h.shared.created.length, greaterThanOrEqualTo(3));
        h.manager.dispose();
      },
    );
  });
}
