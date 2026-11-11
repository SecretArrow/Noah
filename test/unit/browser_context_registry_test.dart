import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/browser_automation.dart';
import 'package:noah/services/browser_context_registry.dart';
import 'package:noah/services/browser_session_isolation.dart';

/// Controllable clock: registry rows get deterministic createdAt /
/// lastUsedAt stamps, so LRU ordering never depends on wall time.
class _Clock {
  DateTime _now = DateTime.utc(2024, 1, 1);

  DateTime get now => _now;

  DateTime call() => _now;

  void advance([int ms = 25]) {
    _now = _now.add(Duration(milliseconds: ms));
  }
}

/// Cookie gateway double recording every mutation (mirrors
/// browser_contexts_test.dart).
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

/// State shared by all engines of one manager under test (mirrors
/// browser_contexts_test.dart).
class _Shared {
  int navigationsStarted = 0;
  int barrierAt = 0;
  Completer<void>? barrier;
  final List<_FakeEngine> created = <_FakeEngine>[];
  final List<_FakeEngine> disposedEngines = <_FakeEngine>[];
  late _Jar cookies;
}

/// Inner engine double: one instance per slot, recorded in
/// [shared.created]; answers the capture JS with the last loaded page and
/// the cookies this fake "site" set during navigate.
class _FakeEngine implements BrowserAutomation {
  _FakeEngine(this.shared) {
    shared.created.add(this);
  }

  final _Shared shared;
  final List<String> calls = <String>[];
  bool disposed = false;
  String pageUrl = 'about:blank';

  /// Site cookies written into the shared jar when a page loads.
  Map<String, String> siteCookies = const <String, String>{};

  @override
  Future<BrowserPageInfo> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    String? sessionId,
  }) async {
    calls.add('navigate:$url');
    pageUrl = url;
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

/// Manager harness: temp-sandbox store + fake engines + an INJECTED
/// registry wired to a controllable clock (so eviction order is
/// deterministic and assertable from the outside).
class _Harness {
  _Harness(
    this.store, {
    this.maxContexts = 4,
    this.configureEngine,
    _Clock? clock,
  }) : clock = clock ?? _Clock() {
    shared.cookies = _Jar();
    registry = BrowserContextRegistry(now: this.clock.call);
    manager = ContextualBrowserAutomation(
      makeInner: () {
        final _FakeEngine engine = _FakeEngine(shared);
        configureEngine?.call(shared.created.length - 1, engine);
        return engine;
      },
      store: store,
      cookies: shared.cookies,
      maxContexts: maxContexts,
      contextRegistry: registry,
    );
  }

  final _Shared shared = _Shared();
  final BrowserStateStore store;
  final int maxContexts;
  final void Function(int index, _FakeEngine engine)? configureEngine;
  late final _Clock clock;
  late final BrowserContextRegistry registry;
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

/// `<sandbox>/<sessionId>/browser_contexts/<name>.json` — where persistent
/// named contexts hibernate.
File _namedFile(Directory temp, String sessionId, String name) => File(
  '${temp.path}${Platform.pathSeparator}$sessionId'
  '${Platform.pathSeparator}browser_contexts'
  '${Platform.pathSeparator}$name.json',
);

void main() {
  late Directory temp;
  late BrowserStateStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('browser_nctx_test');
    store = _store(temp);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('BrowserContextRegistry (pure)', () {
    test(
      'isValidName accepts 1-32 chars of [a-z0-9_-], letter/digit first',
      () {
        const List<String> legal = <String>[
          'a',
          'work-account',
          'ctx_2',
          'a1b2c3',
          'abcdefghijklmnopqrstuvwxyz012345', // exactly 32
        ];
        for (final String name in legal) {
          expect(
            BrowserContextRegistry.isValidName(name),
            isTrue,
            reason: "'$name' should be a legal context name",
          );
        }
        const List<String> illegal = <String>[
          '',
          '-x',
          '_x',
          'A',
          'a b',
          'ç',
          'a.b',
          'abcdefghijklmnopqrstuvwxyz0123456', // 33 chars
        ];
        for (final String name in illegal) {
          expect(
            BrowserContextRegistry.isValidName(name),
            isFalse,
            reason: "'$name' must be rejected",
          );
        }
      },
    );

    test('keyFor builds nctx:<sessionId>:<name>; nameFromKey parses back', () {
      expect(
        BrowserContextRegistry.keyFor('sess-1', 'work'),
        'nctx:sess-1:work',
      );
      // Session ids may contain separators themselves: the NAME is the
      // segment after the LAST colon.
      expect(BrowserContextRegistry.nameFromKey('nctx:chat:1:work'), 'work');
      expect(BrowserContextRegistry.nameFromKey('nctx:sess-1:work'), 'work');
      expect(
        BrowserContextRegistry.reservedNames,
        containsAll(<String>['default', '_legacy']),
      );
    });

    test(
      'register fills key/label/timestamps with the documented defaults',
      () {
        final _Clock clock = _Clock();
        final BrowserContextRegistry registry = BrowserContextRegistry(
          now: clock.call,
        );
        final BrowserContextInfo info = registry.register(
          sessionId: 's1',
          name: 'work',
          persistent: true,
        );
        expect(info.key, 'nctx:s1:work');
        expect(info.label, 'work', reason: 'label defaults to the name');
        expect(info.persistent, isTrue);
        expect(info.ownerSessionId, 's1');
        expect(info.createdAt, clock.now);
        expect(info.lastUsedAt, clock.now, reason: 'createdAt == lastUsedAt');
        expect(info.lastUrl, isEmpty);
        expect(info.originCount, 0);
        expect(registry.isRegistered(info.key), isTrue);
        expect(registry.length, 1);
      },
    );

    test(
      'duplicate name in ONE session throws StateError; other sessions coexist',
      () {
        final BrowserContextRegistry registry = BrowserContextRegistry();
        registry.register(sessionId: 's1', name: 'work', persistent: false);
        expect(
          () => registry.register(
            sessionId: 's1',
            name: 'work',
            persistent: true,
          ),
          throwsStateError,
        );
        // The same NAME inside a DIFFERENT chat is a different context.
        final BrowserContextInfo other = registry.register(
          sessionId: 's2',
          name: 'work',
          persistent: false,
        );
        expect(other.key, 'nctx:s2:work');
        expect(registry.length, 2);
      },
    );

    test('list(sessionId) is scoped to the session, oldest creation first', () {
      final _Clock clock = _Clock();
      final BrowserContextRegistry registry = BrowserContextRegistry(
        now: clock.call,
      );
      registry.register(sessionId: 's1', name: 'a', persistent: false);
      clock.advance();
      registry.register(sessionId: 's2', name: 'x', persistent: false);
      clock.advance();
      registry.register(sessionId: 's1', name: 'b', persistent: false);
      expect(
        registry.list('s1').map((BrowserContextInfo i) => i.label).toList(),
        <String>['a', 'b'],
        reason: 'sorted by createdAt ascending',
      );
      expect(registry.list('s2').single.label, 'x');
      expect(registry.list('s3'), isEmpty);
    });

    test('touch refreshes usage/telemetry; unknown keys are a no-op', () {
      final _Clock clock = _Clock();
      final BrowserContextRegistry registry = BrowserContextRegistry(
        now: clock.call,
      );
      final BrowserContextInfo created = registry.register(
        sessionId: 's1',
        name: 'work',
        persistent: false,
      );
      clock.advance();
      registry.touch(
        created.key,
        lastUrl: 'https://x.test/home',
        originCount: 2,
      );
      final BrowserContextInfo touched = registry.info(created.key)!;
      expect(touched.lastUsedAt, clock.now);
      expect(touched.lastUrl, 'https://x.test/home');
      expect(touched.originCount, 2);
      expect(touched.createdAt, created.createdAt, reason: 'age is immutable');
      // A bare touch refreshes only the usage stamp.
      clock.advance();
      registry.touch(created.key);
      final BrowserContextInfo after = registry.info(created.key)!;
      expect(after.lastUsedAt, clock.now);
      expect(after.lastUrl, 'https://x.test/home', reason: 'kept');
      // Unknown key: silently ignored, nothing registered.
      registry.touch('nctx:s1:ghost');
      expect(registry.length, 1);
      expect(registry.isRegistered('nctx:s1:ghost'), isFalse);
    });

    test('evictionOrder is least-recently-used first and follows touch', () {
      final _Clock clock = _Clock();
      final BrowserContextRegistry registry = BrowserContextRegistry(
        now: clock.call,
      );
      registry.register(sessionId: 's1', name: 'a', persistent: false);
      clock.advance();
      registry.register(sessionId: 's1', name: 'b', persistent: false);
      clock.advance();
      registry.register(sessionId: 's1', name: 'c', persistent: false);
      expect(registry.evictionOrder(), <String>[
        'nctx:s1:a',
        'nctx:s1:b',
        'nctx:s1:c',
      ]);
      clock.advance();
      registry.touch('nctx:s1:b'); // b was just used -> out of the line of fire
      expect(
        registry.evictionOrder().first,
        'nctx:s1:a',
        reason: 'the untouched oldest is the first to give up its slot',
      );
      expect(registry.evictionOrder(), <String>[
        'nctx:s1:a',
        'nctx:s1:c',
        'nctx:s1:b',
      ]);
    });

    test(
      'unregister returns the row and clears it; second call yields null',
      () {
        final BrowserContextRegistry registry = BrowserContextRegistry();
        final BrowserContextInfo created = registry.register(
          sessionId: 's1',
          name: 'work',
          persistent: false,
        );
        final BrowserContextInfo? removed = registry.unregister(created.key);
        expect(identical(removed, created), isTrue);
        expect(registry.isRegistered(created.key), isFalse);
        expect(registry.unregister(created.key), isNull);
        expect(registry.length, 0);
      },
    );

    test('clear forgets every registration', () {
      final BrowserContextRegistry registry = BrowserContextRegistry();
      registry
        ..register(sessionId: 's1', name: 'a', persistent: false)
        ..register(sessionId: 's2', name: 'a', persistent: false);
      expect(registry.length, 2);
      registry.clear();
      expect(registry.length, 0);
      expect(registry.list('s1'), isEmpty);
      expect(registry.evictionOrder(), isEmpty);
    });
  });

  group('ContextualBrowserAutomation named contexts', () {
    test(
      'createContext returns the info map and registers the nctx slot key',
      () async {
        final _Harness h = _Harness(store);
        final Map<String, dynamic> persistentInfo = await h.manager
            .createContext('work', persistent: true, sessionId: 's1');
        expect(persistentInfo['name'], 'work');
        expect(persistentInfo['label'], 'work');
        expect(persistentInfo['persistent'], isTrue);
        expect(persistentInfo['lastUrl'], isEmpty);
        expect(persistentInfo['originCount'], 0);
        expect(h.registry.isRegistered('nctx:s1:work'), isTrue);
        expect(h.registry.info('nctx:s1:work')!.persistent, isTrue);

        final Map<String, dynamic> ephemeralInfo = await h.manager
            .createContext('shop', sessionId: 's1');
        expect(
          ephemeralInfo['persistent'],
          isFalse,
          reason: 'persistent defaults to false',
        );
        expect(h.registry.length, 2);
        h.manager.dispose();
      },
    );

    test('createContext rejects invalid and reserved names', () async {
      final _Harness h = _Harness(store);
      const List<String> bad = <String>[
        '',
        'A',
        'a b',
        'a.b',
        'ç',
        'abcdefghijklmnopqrstuvwxyz0123456', // 33 chars
        'default', // the chat's own slot can never be shadowed
        '_legacy', // the pre-isolation global slot likewise
      ];
      for (final String name in bad) {
        await expectLater(
          h.manager.createContext(name, sessionId: 's1'),
          throwsArgumentError,
        );
      }
      expect(h.registry.length, 0);
      h.manager.dispose();
    });

    test('the named-context API needs the owning chat sessionId', () async {
      final _Harness h = _Harness(store);
      await expectLater(h.manager.createContext('work'), throwsArgumentError);
      await expectLater(h.manager.closeContext('work'), throwsArgumentError);
      await expectLater(h.manager.contextInfo('work'), throwsArgumentError);
      expect(h.registry.length, 0);
      h.manager.dispose();
    });

    test(
      'duplicate createContext throws StateError and keeps ONE row',
      () async {
        final _Harness h = _Harness(store);
        await h.manager.createContext('work', sessionId: 's1');
        await expectLater(
          h.manager.createContext('work', sessionId: 's1'),
          throwsStateError,
        );
        expect(h.registry.list('s1'), hasLength(1));
        // Another session may still claim the same name.
        await h.manager.createContext('work', sessionId: 's2');
        expect(h.registry.length, 2);
        h.manager.dispose();
      },
    );

    test(
      'navigate(contextName:) routes to a dedicated slot and touches the row',
      () async {
        final _Harness h = _Harness(
          store,
          configureEngine: (int n, _FakeEngine e) {
            if (n == 0) e.siteCookies = <String, String>{'sid': 'ctx-login'};
          },
        );
        await h.manager.createContext('work', sessionId: 's1');
        final DateTime createdAt = h.registry.info('nctx:s1:work')!.createdAt;
        h.clock.advance();
        await h.manager.navigate(
          'https://x.test/home',
          sessionId: 's1',
          contextName: 'work',
        );
        // Exactly ONE engine exists — the named context's OWN slot; the
        // chat's default slot (s:s1) was never booted by this call.
        expect(h.shared.created, hasLength(1));
        expect(h.engine(0).calls, contains('navigate:https://x.test/home'));
        final BrowserContextInfo row = h.registry.info('nctx:s1:work')!;
        expect(row.lastUrl, 'https://x.test/home');
        expect(row.lastUsedAt, h.clock.now, reason: 'routing touches LRU');
        expect(row.lastUsedAt, isNot(createdAt));
        expect(row.originCount, 1, reason: 'capture refreshes the counter');
        h.manager.dispose();
      },
    );

    test(
      'navigate(contextName:) rejects unknown, foreign, anonymous calls',
      () async {
        final _Harness h = _Harness(store);
        await h.manager.createContext('work', sessionId: 's1');
        // Never created for this chat.
        await expectLater(
          h.manager.navigate(
            'https://x.test/',
            sessionId: 's1',
            contextName: 'ghost',
          ),
          throwsArgumentError,
        );
        // Same name but a DIFFERENT chat: keys are per-session namespaces.
        await expectLater(
          h.manager.navigate(
            'https://x.test/',
            sessionId: 's2',
            contextName: 'work',
          ),
          throwsArgumentError,
        );
        // Named routing without the owning session is rejected instead of
        // leaking into the legacy slot.
        await expectLater(
          h.manager.navigate('https://x.test/', contextName: 'work'),
          throwsArgumentError,
        );
        expect(h.shared.created, isEmpty, reason: 'no engine was booted');
        expect(h.registry.length, 1);
        h.manager.dispose();
      },
    );

    test(
      'closeContext protects reserved names and rejects unknown ones',
      () async {
        final _Harness h = _Harness(store);
        await expectLater(
          h.manager.closeContext('default', sessionId: 's1'),
          throwsArgumentError,
          reason: "'default' is the chat's own slot and must stay unclosable",
        );
        await expectLater(
          h.manager.closeContext('_legacy', sessionId: 's1'),
          throwsArgumentError,
        );
        await expectLater(
          h.manager.closeContext('ghost', sessionId: 's1'),
          throwsStateError,
        );
        h.manager.dispose();
      },
    );

    test(
      'closeContext unregisters, disposes the engine, deletes the file',
      () async {
        final _Harness h = _Harness(
          store,
          configureEngine: (int n, _FakeEngine e) {
            if (n == 0) e.siteCookies = <String, String>{'sid': 'login'};
          },
        );
        await h.manager.createContext(
          'work',
          persistent: true,
          sessionId: 's1',
        );
        await h.manager.navigate(
          'https://x.test/home',
          sessionId: 's1',
          contextName: 'work',
        );
        final File file = _namedFile(temp, 's1', 'work');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'a persistent context hibernates after every op',
        );

        await h.manager.closeContext('work', sessionId: 's1');
        expect(h.registry.isRegistered('nctx:s1:work'), isFalse);
        expect(await h.manager.contextInfo('work', sessionId: 's1'), isNull);
        expect(
          file.existsSync(),
          isFalse,
          reason: 'close deletes the snapshot',
        );
        // Engine teardown is async — let it land.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.engine(0).disposed, isTrue);
        expect(h.shared.disposedEngines, hasLength(1));
        // Closing twice: the context is gone -> StateError.
        await expectLater(
          h.manager.closeContext('work', sessionId: 's1'),
          throwsStateError,
        );
        // Re-creating after a close starts FRESH: the erased hibernation
        // file must not resurrect the old login.
        final Map<String, dynamic> freshInfo = await h.manager.createContext(
          'work',
          persistent: true,
          sessionId: 's1',
        );
        expect(freshInfo['lastUrl'], isEmpty);
        expect(freshInfo['originCount'], 0);
        expect(
          h.registry.info('nctx:s1:work')!.createdAt,
          h.clock.now,
          reason: 'fresh timeline — the old snapshot was deleted',
        );
        h.manager.dispose();
      },
    );

    test(
      'persistent eviction hibernates; re-create restores state and age',
      () async {
        final _Clock clock = _Clock();
        final _Harness h = _Harness(
          store,
          clock: clock,
          configureEngine: (int n, _FakeEngine e) {
            if (n == 0) e.siteCookies = <String, String>{'sid': 'login'};
          },
        );
        final DateTime originalCreatedAt = clock.now;
        await h.manager.createContext(
          'work',
          persistent: true,
          sessionId: 's1',
        );
        await h.manager.navigate(
          'https://x.test/home',
          sessionId: 's1',
          contextName: 'work',
        );

        // Fill the chat's cap so 'work' (least recently used) hibernates.
        for (final String filler in <String>['b', 'c', 'd']) {
          clock.advance();
          await h.manager.createContext(filler, sessionId: 's1');
        }
        clock.advance();
        await h.manager.createContext('e', sessionId: 's1');
        expect(
          await h.manager.contextInfo('work', sessionId: 's1'),
          isNull,
          reason: 'the LRU context gave up its slot to the overflow',
        );
        final File file = _namedFile(temp, 's1', 'work');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'a persistent evictee hibernates BEFORE teardown',
        );
        // Async teardown of the hibernated slot (jar release + dispose).
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.engine(0).disposed, isTrue);
        expect(
          h.shared.cookies.jar['https://x.test/home']?.containsKey('sid'),
          isFalse,
          reason: 'eviction logs the context out of the shared jar',
        );

        // Re-create: the hibernated state (and original age) comes back.
        clock.advance();
        final Map<String, dynamic> revivedInfo = await h.manager.createContext(
          'work',
          persistent: true,
          sessionId: 's1',
        );
        expect(revivedInfo['lastUrl'], 'https://x.test/home');
        expect(revivedInfo['originCount'], 1);
        final BrowserContextInfo row = h.registry.info('nctx:s1:work')!;
        expect(row.createdAt, originalCreatedAt, reason: 'original age');
        expect(row.originCount, 1);

        // The hibernated login survives: restoring writes the cookie back
        // into the shared jar on the context's next use (engine #2 has NO
        // site cookies of its own — only the restore can supply 'sid').
        await h.manager.navigate(
          'https://x.test/home',
          sessionId: 's1',
          contextName: 'work',
        );
        expect(h.shared.cookies.jar['https://x.test/home']!['sid'], 'login');
        h.manager.dispose();
      },
    );

    test('ephemeral eviction leaves no hibernation file behind', () async {
      final _Clock clock = _Clock();
      final _Harness h = _Harness(
        store,
        clock: clock,
        configureEngine: (int n, _FakeEngine e) {
          if (n == 0) e.siteCookies = <String, String>{'sid': 'login'};
        },
      );
      await h.manager.createContext('shop', sessionId: 's1');
      await h.manager.navigate(
        'https://x.test/home',
        sessionId: 's1',
        contextName: 'shop',
      );
      expect(
        _namedFile(temp, 's1', 'shop').existsSync(),
        isFalse,
        reason: 'ephemeral contexts never hibernate during normal ops',
      );
      for (final String filler in <String>['b', 'c', 'd']) {
        clock.advance();
        await h.manager.createContext(filler, sessionId: 's1');
      }
      clock.advance();
      await h.manager.createContext('e', sessionId: 's1');
      expect(await h.manager.contextInfo('shop', sessionId: 's1'), isNull);
      expect(
        _namedFile(temp, 's1', 'shop').existsSync(),
        isFalse,
        reason: 'an ephemeral evictee drops fully',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      h.manager.dispose();
    });

    test(
      'maxContexts cap: the 5th create evicts the LRU; touch protects',
      () async {
        final _Clock clock = _Clock();
        final _Harness h = _Harness(store, clock: clock);
        for (final String name in <String>['a', 'b', 'c', 'd']) {
          clock.advance();
          await h.manager.createContext(name, sessionId: 's1');
        }
        // 'a' is used again: it must move out of the eviction line of fire.
        clock.advance();
        await h.manager.navigate(
          'https://used.test/',
          sessionId: 's1',
          contextName: 'a',
        );
        clock.advance();
        await h.manager.createContext('e', sessionId: 's1');
        expect(
          await h.manager.contextInfo('a', sessionId: 's1'),
          isNotNull,
          reason: 'a recently used context survives the overflow',
        );
        expect(
          await h.manager.contextInfo('b', sessionId: 's1'),
          isNull,
          reason: 'the untouched oldest was evicted (evictionOrder)',
        );
        expect(h.registry.list('s1'), hasLength(4));
        expect(
          (await h.manager.listContexts('s1'))
              .map((Map<String, dynamic> row) => row['name'])
              .toList(),
          <String>['a', 'c', 'd', 'e'],
        );
        h.manager.dispose();
      },
    );

    test('a custom maxContexts is honored', () async {
      final _Clock clock = _Clock();
      final _Harness h = _Harness(store, maxContexts: 2, clock: clock);
      await h.manager.createContext('a', sessionId: 's1');
      clock.advance();
      await h.manager.createContext('b', sessionId: 's1');
      clock.advance();
      // Third context of a cap-2 chat: the oldest ('a') hibernates away.
      await h.manager.createContext('c', sessionId: 's1');
      expect(await h.manager.contextInfo('a', sessionId: 's1'), isNull);
      expect(await h.manager.contextInfo('b', sessionId: 's1'), isNotNull);
      expect(await h.manager.contextInfo('c', sessionId: 's1'), isNotNull);
      expect(h.registry.list('s1'), hasLength(2));
      h.manager.dispose();
    });

    test('the maxContexts cap is per chat session', () async {
      final _Clock clock = _Clock();
      final _Harness h = _Harness(store, clock: clock);
      for (final String name in <String>['a', 'b', 'c', 'd']) {
        await h.manager.createContext(name, sessionId: 's1');
      }
      clock.advance();
      await h.manager.createContext('mine', sessionId: 's2');
      expect(
        await h.manager.listContexts('s1'),
        hasLength(4),
        reason: "another chat's context never evicts this chat's rows",
      );
      expect(await h.manager.listContexts('s2'), hasLength(1));
      expect(h.registry.length, 5);
      h.manager.dispose();
    });

    test(
      'listContexts reports creation order; contextInfo is session-scoped',
      () async {
        final _Clock clock = _Clock();
        final _Harness h = _Harness(store, clock: clock);
        for (final String name in <String>['second', 'first', 'third']) {
          clock.advance();
          await h.manager.createContext(name, sessionId: 's1');
        }
        clock.advance();
        await h.manager.createContext('first', sessionId: 's2');
        expect(
          (await h.manager.listContexts('s1'))
              .map((Map<String, dynamic> row) => row['name'])
              .toList(),
          <String>['second', 'first', 'third'],
          reason: 'oldest creation first, regardless of the name',
        );
        expect(await h.manager.listContexts('s2'), hasLength(1));
        expect(
          await h.manager.contextInfo('second', sessionId: 's2'),
          isNull,
          reason: 'another chat cannot see this session\'s context',
        );
        h.manager.dispose();
      },
    );

    test('single-engine automations answer the named-context API with '
        'UnsupportedError', () async {
      final _Shared shared = _Shared()..cookies = _Jar();
      final IsolatedBrowserAutomation isolated = IsolatedBrowserAutomation(
        inner: _FakeEngine(shared),
        store: store,
        cookies: shared.cookies,
      );
      await expectLater(isolated.createContext('x'), throwsUnsupportedError);
      await expectLater(isolated.closeContext('x'), throwsUnsupportedError);
      await expectLater(isolated.contextInfo('x'), throwsUnsupportedError);
      expect(WebViewAutomation().withContext('a') is WebViewAutomation, isTrue);
      await expectLater(
        WebViewAutomation().createContext('x'),
        throwsUnsupportedError,
      );

      // The pinned subagent view of the multi-context engine shares the
      // same "unsupported" contract: named contexts belong to the manager.
      final _Harness h = _Harness(store);
      final BrowserAutomation view = h.manager.withContext('sub-1');
      expect(view, isA<UnsupportedNamedBrowserContexts>());
      final UnsupportedNamedBrowserContexts stub =
          view as UnsupportedNamedBrowserContexts;
      await expectLater(stub.createContext('x'), throwsUnsupportedError);
      await expectLater(stub.closeContext('x'), throwsUnsupportedError);
      await expectLater(stub.contextInfo('x'), throwsUnsupportedError);
      h.manager.dispose();
    });
  });
}
