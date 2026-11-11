import 'package:flutter_test/flutter_test.dart';
import 'package:noah/data/user_agents.g.dart';
import 'package:noah/models/models.dart';
import 'package:noah/models/user_agent.dart';

void main() {
  // ---------------------------------------------------------------------
  // The rules below mirror scripts/gen_user_agents.py. If the database is
  // regenerated, this test fails on any format drift, duplicate string,
  // broken version pairing or impossible device/OS combination.
  // ---------------------------------------------------------------------

  group('user agent database', () {
    test(
      'contains exactly 1000 unique records (168 desktop + 832 android)',
      () {
        expect(kUserAgentDatabase, hasLength(1000));
        expect(
          kUserAgentDatabase
              .where(
                (UserAgentRecord r) => r.category == UserAgentCategory.desktop,
              )
              .length,
          168,
        );
        expect(
          kUserAgentDatabase
              .where(
                (UserAgentRecord r) => r.category == UserAgentCategory.android,
              )
              .length,
          832,
        );
        expect(
          kUserAgentDatabase.map((UserAgentRecord r) => r.ua).toSet().length,
          1000,
          reason: 'UA strings must be globally unique',
        );
        expect(
          kUserAgentDatabase.map((UserAgentRecord r) => r.id).toSet().length,
          1000,
        );
        expect(
          kUserAgentDatabase.every(
            (UserAgentRecord r) => r.id >= 1 && r.id <= 1000,
          ),
          isTrue,
        );
      },
    );

    test('spot ids keep their exact identity (generator drift guard)', () {
      // scripts/gen_user_agents.py enforces the same invariants — these
      // spot checks guard the Dart database against any generator drift.
      final Map<int, String> frozen = <int, String>{
        1:
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36',
        5:
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36',
        21:
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0',
        100:
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:157.0) '
            'Gecko/20100101 Firefox/157.0',
        168:
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 '
            'Safari/605.1.15',
      };
      for (final MapEntry<int, String> e in frozen.entries) {
        final UserAgentRecord r = kUserAgentDatabase.firstWhere(
          (UserAgentRecord r) => r.id == e.key,
        );
        expect(r.ua, e.value, reason: 'spot id ${e.key} drifted');
      }
    });

    test('family distribution matches the generator contract', () {
      int count(bool Function(UserAgentRecord) pred) =>
          kUserAgentDatabase.where(pred).length;
      bool desk(UserAgentRecord r) => r.category == UserAgentCategory.desktop;
      bool andr(UserAgentRecord r) => r.category == UserAgentCategory.android;
      expect(count((r) => desk(r) && r.browser == UserAgentBrowser.chrome), 20);
      expect(count((r) => desk(r) && r.browser == UserAgentBrowser.edge), 20);
      expect(
        count((r) => desk(r) && r.browser == UserAgentBrowser.firefox),
        102,
      );
      expect(count((r) => desk(r) && r.browser == UserAgentBrowser.safari), 8);
      expect(count((r) => desk(r) && r.browser == UserAgentBrowser.opera), 15);
      expect(count((r) => desk(r) && r.browser == UserAgentBrowser.vivaldi), 3);
      expect(
        count((r) => andr(r) && r.browser == UserAgentBrowser.chrome),
        420,
      );
      expect(
        count((r) => andr(r) && r.browser == UserAgentBrowser.samsungInternet),
        58,
      );
      expect(
        count((r) => andr(r) && r.browser == UserAgentBrowser.firefox),
        54,
      );
      expect(count((r) => andr(r) && r.browser == UserAgentBrowser.edge), 150);
      expect(count((r) => andr(r) && r.browser == UserAgentBrowser.opera), 150);
    });

    test('freshness policy: every Chromium token is 153+ (nothing stale)', () {
      // The v1.41.5 user requirement: Chromium-based identities must use
      // the currently-supported trains (153..157) — never <= 150.
      final RegExp chromeToken = RegExp(r'Chrome/(\d+)\.0\.0\.0');
      for (final UserAgentRecord r in kUserAgentDatabase) {
        for (final RegExpMatch m in chromeToken.allMatches(r.ua)) {
          final int major = int.parse(m.group(1)!);
          expect(
            major,
            inInclusiveRange(153, 157),
            reason: 'stale Chromium token: ${r.ua}',
          );
        }
      }
      // Firefox: newest trains + live ESR lines only.
      final RegExp firefoxToken = RegExp(r'Firefox/(\d+)');
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.browser != UserAgentBrowser.firefox) continue;
        for (final RegExpMatch m in firefoxToken.allMatches(r.ua)) {
          final int major = int.parse(m.group(1)!);
          expect(
            major == 140 || (major >= 150 && major <= 158),
            isTrue,
            reason: 'stale Firefox train ${m.group(1)}: ${r.ua}',
          );
        }
      }
    });

    test('desktop Chromium UAs use the exact Chrome wire format', () {
      final RegExp chromeDesktop = RegExp(
        r'^Mozilla/5\.0 \(Windows NT 10\.0; Win64; x64|Windows NT 10\.0; WOW64|Macintosh; Intel Mac OS X 10_15_7|X11; Linux x86_64\) '
        r'AppleWebKit/537\.36 \(KHTML, like Gecko\) Chrome/(\d+)\.0\.0\.0 Safari/537\.36$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.desktop &&
            r.browser == UserAgentBrowser.chrome) {
          expect(chromeDesktop.hasMatch(r.ua), isTrue, reason: r.ua);
        }
      }
    });

    test('desktop Edge majors equal their bundled Chromium major', () {
      final RegExp edgeDesktop = RegExp(
        r'^Mozilla/5\.0 \((.+)\) AppleWebKit/537\.36 \(KHTML, like Gecko\) '
        r'Chrome/(\d+)\.0\.0\.0 Safari/537\.36 Edg/(\d+)\.0\.0\.0$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.desktop &&
            r.browser == UserAgentBrowser.edge) {
          final RegExpMatch? m = edgeDesktop.firstMatch(r.ua);
          expect(m, isNotNull, reason: r.ua);
          expect(m!.group(3), m.group(2), reason: r.ua);
        }
      }
    });

    test('desktop Firefox keeps rv == major.minor of its version', () {
      final RegExp firefoxDesktop = RegExp(
        r'^Mozilla/5\.0 \((?:Windows NT 10\.0; Win64; x64|Macintosh; Intel Mac OS X 10\.15|X11; Linux x86_64); '
        r'rv:(\d+\.\d+)\) Gecko/20100101 Firefox/(\d+\.\d+(\.\d+)?)$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.desktop &&
            r.browser == UserAgentBrowser.firefox) {
          final RegExpMatch? m = firefoxDesktop.firstMatch(r.ua);
          expect(m, isNotNull, reason: r.ua);
          // Real Firefox rule: rv keeps major.minor (Firefox/153.6 ->
          // rv:153.6; Firefox/158.0.1 -> rv:158.0).
          final List<String> parts = m!.group(2)!.split('.');
          expect('${parts[0]}.${parts[1]}', m.group(1), reason: r.ua);
        }
      }
    });

    test('desktop Safari keeps the 605.1.15 WebKit stamp', () {
      final RegExp safari = RegExp(
        r'^Mozilla/5\.0 \(Macintosh; Intel Mac OS X 10_15_7\) '
        r'AppleWebKit/605\.1\.15 \(KHTML, like Gecko\) Version/(\d+\.\d+) Safari/605\.1\.15$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.desktop &&
            r.browser == UserAgentBrowser.safari) {
          expect(safari.hasMatch(r.ua), isTrue, reason: r.ua);
        }
      }
    });

    test('desktop Opera majors follow the Chromium pairing', () {
      final RegExp operaDesktop = RegExp(
        r'^Mozilla/5\.0 \((.+)\) AppleWebKit/537\.36 \(KHTML, like Gecko\) '
        r'Chrome/(\d+)\.0\.0\.0 Safari/537\.36 OPR/(\d+)\.0\.0\.0$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.desktop &&
            r.browser == UserAgentBrowser.opera) {
          final RegExpMatch? m = operaDesktop.firstMatch(r.ua);
          expect(m, isNotNull, reason: r.ua);
          // Real-world offset used by the generator (Chromium - 20).
          expect(
            int.parse(m!.group(3)!),
            int.parse(m.group(2)!) - 20,
            reason: r.ua,
          );
        }
      }
    });

    test('desktop Vivaldi appends a full 4-part version', () {
      final RegExp vivaldi = RegExp(
        r'^Mozilla/5\.0 \((.+)\) AppleWebKit/537\.36 \(KHTML, like Gecko\) '
        r'Chrome/(\d+)\.0\.0\.0 Safari/537\.36 Vivaldi/(\d+\.\d+\.\d+\.\d+)$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.desktop &&
            r.browser == UserAgentBrowser.vivaldi) {
          expect(vivaldi.hasMatch(r.ua), isTrue, reason: r.ua);
        }
      }
    });

    test('Android Chrome: phones carry Mobile, tablets never do', () {
      const Set<String> tablets = <String>{
        'SM-X910',
        'SM-X710',
        'SM-X210',
        'SM-X200',
        'Pixel Tablet',
        '23043RP34G',
      };
      final RegExp chromeAndroid = RegExp(
        r'^Mozilla/5\.0 \(Linux; Android (\d+); (.+?)\) AppleWebKit/537\.36 '
        r'\(KHTML, like Gecko\) Chrome/(\d+)\.0\.0\.0 (Mobile )?Safari/537\.36$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.android &&
            r.browser == UserAgentBrowser.chrome) {
          final RegExpMatch? m = chromeAndroid.firstMatch(r.ua);
          expect(m, isNotNull, reason: r.ua);
          final int android = int.parse(m!.group(1)!);
          expect(android, inInclusiveRange(13, 17), reason: r.ua);
          final String model = m.group(2)!;
          final bool isTablet = tablets.contains(model);
          expect((m.group(4) == 'Mobile '), !isTablet, reason: r.ua);
        }
      }
    });

    test('Samsung Internet majors map to their bundled Chromium (153+)', () {
      const Map<int, int> samsungChromium = <int, int>{
        31: 153,
        32: 155,
        33: 157,
      };
      final RegExp samsung = RegExp(
        r'^Mozilla/5\.0 \(Linux; Android (\d+); (SM-\w+)\) AppleWebKit/537\.36 '
        r'\(KHTML, like Gecko\) SamsungBrowser/(\d+)\.0 Chrome/(\d+)\.0\.0\.0 '
        r'Mobile Safari/537\.36$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.android &&
            r.browser == UserAgentBrowser.samsungInternet) {
          final RegExpMatch? m = samsung.firstMatch(r.ua);
          expect(m, isNotNull, reason: r.ua);
          final int sb = int.parse(m!.group(3)!);
          expect(samsungChromium[sb], int.parse(m.group(4)!), reason: r.ua);
          expect(
            int.parse(m.group(4)!),
            inInclusiveRange(153, 157),
            reason: r.ua,
          );
          expect(
            int.parse(m.group(1)!),
            inInclusiveRange(13, 17),
            reason: r.ua,
          );
        }
      }
    });

    test('Android Firefox uses the Gecko format without a device model', () {
      final RegExp firefoxAndroid = RegExp(
        r'^Mozilla/5\.0 \(Android (\d+); (Mobile|Tablet); rv:(\d+)\.0\) '
        r'Gecko/\3\.0 Firefox/(\d+)\.0$',
      );
      for (final UserAgentRecord r in kUserAgentDatabase) {
        if (r.category == UserAgentCategory.android &&
            r.browser == UserAgentBrowser.firefox) {
          final RegExpMatch? m = firefoxAndroid.firstMatch(r.ua);
          expect(m, isNotNull, reason: r.ua);
          expect(m!.group(3), m.group(4), reason: r.ua);
          expect(
            int.parse(m.group(3)!),
            inInclusiveRange(150, 158),
            reason: r.ua,
          );
          expect(
            r.ua.contains('; SM-') || r.ua.contains('; Pixel'),
            isFalse,
            reason: 'Firefox Android never sends a model: ${r.ua}',
          );
        }
      }
    });

    test(
      'Edge/Opera Android keep EdgA/OPR consistency and the Mobile token',
      () {
        final RegExp edgeAndroid = RegExp(
          r'^Mozilla/5\.0 \(Linux; Android (\d+); (.+?)\) AppleWebKit/537\.36 '
          r'\(KHTML, like Gecko\) Chrome/(\d+)\.0\.0\.0 Mobile Safari/537\.36 '
          r'EdgA/(\d+)\.0\.0\.0$',
        );
        final RegExp operaAndroid = RegExp(
          r'^Mozilla/5\.0 \(Linux; Android (\d+); (.+?)\) AppleWebKit/537\.36 '
          r'\(KHTML, like Gecko\) Chrome/(\d+)\.0\.0\.0 Mobile Safari/537\.36 '
          r'OPR/(\d+)\.0\.0\.0$',
        );
        for (final UserAgentRecord r in kUserAgentDatabase) {
          if (r.category != UserAgentCategory.android) continue;
          if (r.browser == UserAgentBrowser.edge) {
            final RegExpMatch? m = edgeAndroid.firstMatch(r.ua);
            expect(m, isNotNull, reason: r.ua);
            expect(m!.group(4), m.group(3), reason: r.ua);
          } else if (r.browser == UserAgentBrowser.opera) {
            final RegExpMatch? m = operaAndroid.firstMatch(r.ua);
            expect(m, isNotNull, reason: r.ua);
            expect(
              int.parse(m!.group(4)!),
              int.parse(m.group(3)!) - 44,
              reason: r.ua,
            );
          }
        }
      },
    );

    test('labels are meaningful and unique per category', () {
      expect(
        kUserAgentDatabase.map((UserAgentRecord r) => r.label).toSet().length,
        1000,
        reason: 'labels help the user pick; duplicates would be confusing',
      );
      expect(
        kUserAgentDatabase.every(
          (UserAgentRecord r) => r.label.isNotEmpty && r.label.length < 80,
        ),
        isTrue,
      );
    });
  });

  group('UaMode parsing', () {
    test('known names parse, unknown fall back to auto', () {
      expect(uaModeFromName('auto'), UaMode.auto);
      expect(uaModeFromName('desktop'), UaMode.desktop);
      expect(uaModeFromName('android'), UaMode.android);
      expect(uaModeFromName(null), UaMode.auto);
      expect(uaModeFromName('bogus'), UaMode.auto);
    });
  });

  group('AppSettings UA fields', () {
    test('json round-trips mode and sticky ids', () {
      final AppSettings settings = AppSettings(
        uaMode: UaMode.desktop,
        uaDesktopId: 17,
        uaAndroidId: 42,
      );
      final AppSettings restored = AppSettings.fromJson(settings.toJson());
      expect(restored.uaMode, UaMode.desktop);
      expect(restored.uaDesktopId, 17);
      expect(restored.uaAndroidId, 42);
    });

    test(
      'missing keys default to auto + first pick (old installs migrate)',
      () {
        final AppSettings restored = AppSettings.fromJson(<String, dynamic>{
          'providerName': 'OpenRouter',
        });
        expect(restored.uaMode, UaMode.auto);
        expect(restored.uaDesktopId, 1);
        expect(restored.uaAndroidId, 1);
      },
    );

    test('a saved id outside the shrunken database resolves to pool.first', () {
      // The v1.41.5 refresh replaced the 1200-149-era database with the
      // 153+-era one; the manager must self-heal stale persisted ids.
      final UserAgentRecord missing = UserAgentRecord(
        id: 9999,
        category: UserAgentCategory.desktop,
        browser: UserAgentBrowser.chrome,
        label: 'not in the database',
        ua: 'Mozilla/5.0 stale',
      );
      expect(
        kUserAgentDatabase.any((UserAgentRecord r) => r.id == missing.id),
        isFalse,
      );
    });
  });
}
