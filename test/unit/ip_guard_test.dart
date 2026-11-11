import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/ip_guard.dart';
import 'package:noah/services/settings_repository.dart';

/// Builds a guard whose HTTP probe answers with [status]/[body] and
/// records the request for endpoint assertions.
IpGuard respondingGuard(
  SharedPreferences prefs, {
  int status = 200,
  String body = '',
  List<http.Request>? seen,
}) => IpGuard.withClient(
  prefs: prefs,
  client: MockClient((http.Request request) async {
    seen?.add(request);
    return http.Response(body, status);
  }),
);

Future<SharedPreferences> mockPrefs([
  Map<String, Object> initial = const <String, Object>{},
]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SharedPreferences.getInstance();
}

void main() {
  group('IpGuard.normalizeIp', () {
    test('accepts a plain IPv4 and trims whitespace', () {
      expect(IpGuard.normalizeIp(' 203.0.113.7 \n'), '203.0.113.7');
    });

    test('accepts a plausible IPv6 literal', () {
      expect(IpGuard.normalizeIp('2001:db8::1'), '2001:db8::1');
    });

    test('rejects HTML, JSON and prose (captive portals)', () {
      expect(IpGuard.normalizeIp('<html><body>hi</body></html>'), isNull);
      expect(IpGuard.normalizeIp('{"ip":"1.2.3.4"}'), isNull);
      expect(IpGuard.normalizeIp('not an ip at all'), isNull);
    });

    test('rejects empty and out-of-range candidates', () {
      expect(IpGuard.normalizeIp(''), isNull);
      expect(IpGuard.normalizeIp('   '), isNull);
      expect(IpGuard.normalizeIp('999.999.999.999'), isNull);
      expect(IpGuard.normalizeIp('1.2.3'), isNull);
      expect(IpGuard.normalizeIp('1.2.3.4.5'), isNull);
    });
  });

  group('IpGuard.fetchPublicIp', () {
    test(
      'GETs the plain-text echo endpoint and parses the IPv4 body',
      () async {
        final List<http.Request> seen = <http.Request>[];
        final IpGuard guard = respondingGuard(
          await mockPrefs(),
          body: '198.51.100.23\n',
          seen: seen,
        );

        expect(await guard.fetchPublicIp(), '198.51.100.23');
        expect(seen.single.url, Uri.parse('https://api.ipify.org'));
      },
    );

    test('parses an IPv6 echo body', () async {
      final IpGuard guard = respondingGuard(
        await mockPrefs(),
        body: '2001:0db8:85a3:0000:0000:8a2e:0370:7334',
      );
      expect(
        await guard.fetchPublicIp(),
        '2001:0db8:85a3:0000:0000:8a2e:0370:7334',
      );
    });

    test('a stalled response degrades to null (timeout)', () async {
      final IpGuard guard = IpGuard.withClient(
        prefs: await mockPrefs(),
        timeout: const Duration(milliseconds: 40),
        client: MockClient(
          (http.Request request) => Completer<http.Response>().future,
        ),
      );

      expect(await guard.fetchPublicIp(), isNull);
    });

    test('a network error degrades to null', () async {
      final IpGuard guard = IpGuard.withClient(
        prefs: await mockPrefs(),
        client: MockClient(
          (http.Request request) async => throw Exception('offline'),
        ),
      );

      expect(await guard.fetchPublicIp(), isNull);
    });

    test('a non-200 status degrades to null', () async {
      final IpGuard guard = respondingGuard(
        await mockPrefs(),
        status: 503,
        body: '1.2.3.4',
      );

      expect(await guard.fetchPublicIp(), isNull);
    });

    test('an HTML/garbage body degrades to null', () async {
      final IpGuard guard = respondingGuard(
        await mockPrefs(),
        body: '<html>wifi login</html>',
      );

      expect(await guard.fetchPublicIp(), isNull);
    });

    test('falls back to the next echo endpoint when the primary misbehaves '
        '(v1.49.0 reliability fix)', () async {
      final List<http.Request> seen = <http.Request>[];
      final IpGuard guard = IpGuard.withClient(
        prefs: await mockPrefs(),
        client: MockClient((http.Request request) async {
          seen.add(request);
          // Primary endpoint answers garbage (captive portal), the
          // first fallback answers a clean literal.
          if (request.url.host == 'api.ipify.org') {
            return http.Response('<html>login</html>', 200);
          }
          return http.Response('198.51.100.77\n', 200);
        }),
      );

      expect(await guard.fetchPublicIp(), '198.51.100.77');
      expect(seen.map((http.Request r) => r.url.host).toList(), <String>[
        'api.ipify.org',
        'checkip.amazonaws.com',
      ]);
    });

    test(
      'a stalled primary does not starve the fallbacks (budget split)',
      () async {
        final IpGuard guard = IpGuard.withClient(
          prefs: await mockPrefs(),
          timeout: const Duration(milliseconds: 600),
          client: MockClient((http.Request request) {
            if (request.url.host == 'api.ipify.org') {
              return Completer<http.Response>().future; // hangs forever
            }
            return Future<http.Response>.value(
              http.Response('203.0.113.9\n', 200),
            );
          }),
        );

        expect(await guard.fetchPublicIp(), '203.0.113.9');
      },
    );

    test(
      'the probe carries the User-Agent chosen in Settings '
      '(plain web interaction — never the AgentRouter claude-cli identity)',
      () async {
        final List<http.Request> seen = <http.Request>[];
        final IpGuard guard = IpGuard.withClient(
          prefs: await mockPrefs(),
          resolveUserAgent: () => 'Mozilla/5.0 (Linux; Android 15) Chosen/1',
          client: MockClient((http.Request request) async {
            seen.add(request);
            return http.Response('203.0.113.5', 200);
          }),
        );

        expect(await guard.fetchPublicIp(), '203.0.113.5');
        expect(
          seen.single.headers['User-Agent'],
          'Mozilla/5.0 (Linux; Android 15) Chosen/1',
        );
      },
    );

    test('without a resolver the probe sends no explicit User-Agent', () async {
      final List<http.Request> seen = <http.Request>[];
      final IpGuard guard = IpGuard.withClient(
        prefs: await mockPrefs(),
        client: MockClient((http.Request request) async {
          seen.add(request);
          return http.Response('203.0.113.5', 200);
        }),
      );

      expect(await guard.fetchPublicIp(), '203.0.113.5');
      expect(seen.single.headers.containsKey('User-Agent'), isFalse);
    });
  });

  group('IpGuard memo', () {
    test('records, refreshes (most-recent last) and reads back', () async {
      final IpGuard guard = IpGuard(prefs: await mockPrefs());

      guard.recordMemo('chat-a', '1.1.1.1');
      guard.recordMemo('chat-b', '2.2.2.2');
      expect(guard.readMemo(), <String, String>{
        'chat-a': '1.1.1.1',
        'chat-b': '2.2.2.2',
      });

      guard.recordMemo('chat-a', '3.3.3.3');
      expect(guard.readMemo().keys.toList(), <String>['chat-b', 'chat-a']);
      expect(guard.readMemo()['chat-a'], '3.3.3.3');
    });

    test(
      'caps the map at the 200 most recent entries (oldest dropped)',
      () async {
        final IpGuard guard = IpGuard(prefs: await mockPrefs());
        for (int i = 0; i < IpGuard.memoCap + 5; i++) {
          guard.recordMemo('chat-$i', '10.0.0.$i');
        }

        final Map<String, String> memo = guard.readMemo();
        expect(memo.length, IpGuard.memoCap);
        expect(memo.containsKey('chat-0'), isFalse);
        expect(memo.containsKey('chat-4'), isFalse);
        expect(memo['chat-5'], '10.0.0.5');
        expect(
          memo['chat-${IpGuard.memoCap + 4}'],
          '10.0.0.${IpGuard.memoCap + 4}',
        );
      },
    );

    test('re-touching an existing entry never evicts beyond the cap', () async {
      final IpGuard guard = IpGuard(prefs: await mockPrefs());
      for (int i = 0; i < IpGuard.memoCap; i++) {
        guard.recordMemo('chat-$i', '10.0.0.$i');
      }
      guard.recordMemo('chat-0', '10.9.9.9');

      final Map<String, String> memo = guard.readMemo();
      expect(memo.length, IpGuard.memoCap);
      expect(memo.keys.first, 'chat-1');
      expect(memo.keys.last, 'chat-0');
      expect(memo['chat-0'], '10.9.9.9');
    });

    test('a corrupted memo degrades to an empty map', () async {
      final IpGuard guard = IpGuard(
        prefs: await mockPrefs(<String, Object>{
          IpGuard.memoKey: '{not json!!',
        }),
      );

      expect(guard.readMemo(), isEmpty);
    });
  });

  group('IpGuard.confirmChatSwitch', () {
    bool? result;

    /// Pumps a minimal screen whose only button runs the guard against
    /// [chatId] and stores the verdict in [result].
    Future<void> pumpHarness(
      WidgetTester tester, {
      required IpGuard guard,
      required AppSettings settings,
      required String chatId,
    }) async {
      result = null;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            settingsRepositoryProvider.overrideWithValue(
              MemorySettingsRepository(settings),
            ),
            ipGuardProvider.overrideWithValue(guard),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: const <Locale>[Locale('en'), Locale('id')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              zLocalizationsDelegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) => Center(
                child: TextButton(
                  key: const Key('trigger-switch'),
                  onPressed: () async {
                    result = await ref
                        .read(ipGuardProvider)
                        .confirmChatSwitch(context, ref, chatId);
                  },
                  child: const Text('switch'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    AppSettings settingsWith({bool warn = true}) =>
        AppSettings(ipSwitchWarnEnabled: warn);

    testWidgets('setting OFF allows the switch and never fetches', (
      WidgetTester tester,
    ) async {
      int fetches = 0;
      final SharedPreferences prefs = await mockPrefs();
      final IpGuard guard = IpGuard(
        prefs: prefs,
        fetchIp: () async {
          fetches++;
          return '1.2.3.4';
        },
      );
      await pumpHarness(
        tester,
        guard: guard,
        settings: settingsWith(warn: false),
        chatId: 'chat-a',
      );

      await tester.tap(find.byKey(const Key('trigger-switch')));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(fetches, 0, reason: 'the probe must not run when disabled');
      expect(prefs.getString(IpGuard.memoKey), isNull);
    });

    testWidgets('ON with a different IP proceeds and refreshes the memo', (
      WidgetTester tester,
    ) async {
      final SharedPreferences prefs = await mockPrefs();
      final IpGuard guard = IpGuard(
        prefs: prefs,
        fetchIp: () async => '203.0.113.50',
      );
      guard.recordMemo('chat-a', '198.51.100.1');
      await pumpHarness(
        tester,
        guard: guard,
        settings: settingsWith(),
        chatId: 'chat-a',
      );

      await tester.tap(find.byKey(const Key('trigger-switch')));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(find.byKey(const Key('ip-switch-warn-dialog')), findsNothing);
      expect(guard.readMemo()['chat-a'], '203.0.113.50');
    });

    testWidgets('ON with no memo proceeds and records the first IP', (
      WidgetTester tester,
    ) async {
      final SharedPreferences prefs = await mockPrefs();
      final IpGuard guard = IpGuard(
        prefs: prefs,
        fetchIp: () async => '203.0.113.77',
      );
      await pumpHarness(
        tester,
        guard: guard,
        settings: settingsWith(),
        chatId: 'chat-a',
      );

      await tester.tap(find.byKey(const Key('trigger-switch')));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(guard.readMemo()['chat-a'], '203.0.113.77');
    });

    testWidgets('ON with the SAME IP warns: Cancel aborts and keeps the '
        'memo untouched', (WidgetTester tester) async {
      final SharedPreferences prefs = await mockPrefs();
      final IpGuard guard = IpGuard(
        prefs: prefs,
        fetchIp: () async => '203.0.113.50',
      );
      guard.recordMemo('chat-a', '203.0.113.50');
      guard.recordMemo('chat-b', '198.51.100.9');
      await pumpHarness(
        tester,
        guard: guard,
        settings: settingsWith(),
        chatId: 'chat-a',
      );

      await tester.tap(find.byKey(const Key('trigger-switch')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ip-switch-warn-dialog')), findsOneWidget);
      expect(
        find.textContaining('203.0.113.50'),
        findsWidgets,
        reason: 'the dialog body must name the matching IP',
      );
      expect(find.text('Same IP as last session'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ip-switch-warn-cancel')));
      await tester.pumpAndSettle();

      expect(result, isFalse, reason: 'Cancel must abort the switch');
      expect(guard.readMemo().keys.toList(), <String>[
        'chat-a',
        'chat-b',
      ], reason: 'a cancelled switch must not rewrite the memo');
    });

    testWidgets('ON with the SAME IP warns: Continue proceeds and moves '
        'the chat to the most-recent slot', (WidgetTester tester) async {
      final SharedPreferences prefs = await mockPrefs();
      final IpGuard guard = IpGuard(
        prefs: prefs,
        fetchIp: () async => '203.0.113.50',
      );
      guard.recordMemo('chat-a', '203.0.113.50');
      guard.recordMemo('chat-b', '198.51.100.9');
      await pumpHarness(
        tester,
        guard: guard,
        settings: settingsWith(),
        chatId: 'chat-a',
      );

      await tester.tap(find.byKey(const Key('trigger-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ip-switch-warn-continue')));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(guard.readMemo().keys.toList(), <String>[
        'chat-b',
        'chat-a',
      ], reason: 'Continue must refresh the recorded IP before returning');
      expect(guard.readMemo()['chat-a'], '203.0.113.50');
    });

    testWidgets('a failed fetch proceeds and never overwrites the memo', (
      WidgetTester tester,
    ) async {
      final SharedPreferences prefs = await mockPrefs();
      final IpGuard guard = IpGuard(prefs: prefs, fetchIp: () async => null);
      guard.recordMemo('chat-a', '198.51.100.1');
      guard.recordMemo('chat-b', '198.51.100.2');
      await pumpHarness(
        tester,
        guard: guard,
        settings: settingsWith(),
        chatId: 'chat-a',
      );

      await tester.tap(find.byKey(const Key('trigger-switch')));
      await tester.pumpAndSettle();

      expect(result, isTrue, reason: 'an unknown IP must never block');
      expect(find.byKey(const Key('ip-switch-warn-dialog')), findsNothing);
      expect(guard.readMemo().keys.toList(), <String>[
        'chat-a',
        'chat-b',
      ], reason: 'a failed fetch must not overwrite existing memo data');
      expect(guard.readMemo()['chat-a'], '198.51.100.1');
    });
  });
}
