import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/user_agent.dart';
import 'package:noah/services/user_agent_manager.dart';

import '../../test/support/test_doubles.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_ua_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ProviderContainer container() {
    final ProviderContainer c = ProviderContainer(
      overrides: testOverrides(dir: tempDir),
    );
    addTearDown(c.dispose);
    return c;
  }

  group('UserAgentManager.resolve', () {
    test('Auto resolves to the device-native Android category', () {
      final ProviderContainer c = container();
      final UserAgentRecord record = c
          .read(userAgentManagerProvider)
          .resolve(UaMode.auto);
      expect(record.category, UserAgentCategory.android);
      expect(record.ua, isNotEmpty);
    });

    test('Desktop resolves into the desktop pool, Android into android', () {
      final ProviderContainer c = container();
      expect(
        c.read(userAgentManagerProvider).resolve(UaMode.desktop).category,
        UserAgentCategory.desktop,
      );
      expect(
        c.read(userAgentManagerProvider).resolve(UaMode.android).category,
        UserAgentCategory.android,
      );
    });

    test('selection is sticky: repeated resolves return the same record', () {
      final ProviderContainer c = container();
      final UserAgentManager manager = c.read(userAgentManagerProvider);
      final UserAgentRecord first = manager.resolve(UaMode.desktop);
      expect(manager.resolve(UaMode.desktop).id, first.id);
      expect(manager.resolve(UaMode.desktop).ua, first.ua);
    });

    test('a stored id outside the database self-heals to the first record', () {
      final ProviderContainer c = container();
      c.read(settingsRepositoryProvider); // ensure repository exists
      final UserAgentManager manager = c.read(userAgentManagerProvider);
      // Force an out-of-range id through settings.
      c
          .read(settingsProvider.notifier)
          .update(c.read(settingsProvider).copyWith(uaDesktopId: 99999));
      final UserAgentRecord record = manager.resolve(UaMode.desktop);
      expect(record.category, UserAgentCategory.desktop);
      expect(record.id, userAgentsOf(UserAgentCategory.desktop).first.id);
    });
  });

  group('UserAgentManager.rotate', () {
    test(
      'advances to the next record of the same category and persists',
      () async {
        final ProviderContainer c = container();
        final UserAgentManager manager = c.read(userAgentManagerProvider);
        final UserAgentRecord before = manager.resolve(UaMode.desktop);
        final UserAgentRecord after = await manager.rotate(UaMode.desktop);

        expect(after.category, UserAgentCategory.desktop);
        expect(after.id, isNot(before.id));
        expect(manager.resolve(UaMode.desktop).id, after.id);
        // Sticky id persisted into settings storage.
        expect(c.read(settingsProvider).uaDesktopId, after.id);
        // The other category is untouched.
        expect(c.read(settingsProvider).uaAndroidId, 1);
      },
    );

    test('wraps around without repeating within a full cycle', () async {
      final ProviderContainer c = container();
      final UserAgentManager manager = c.read(userAgentManagerProvider);
      final List<UserAgentRecord> pool = userAgentsOf(
        UserAgentCategory.android,
      );
      final UserAgentRecord start = manager.resolve(UaMode.auto);
      final Set<int> seen = <int>{start.id};

      UserAgentRecord current = start;
      for (var i = 1; i < pool.length; i++) {
        current = await manager.rotate(UaMode.auto);
        expect(
          seen.add(current.id),
          isTrue,
          reason: 'no repeats within one cycle (failed at $i)',
        );
      }
      // Full cycle completed: the next rotation returns to the start.
      expect(await manager.rotate(UaMode.auto).then((r) => r.id), start.id);
    });

    test('mode change keeps each category sticky independently', () async {
      final ProviderContainer c = container();
      final UserAgentManager manager = c.read(userAgentManagerProvider);
      final UserAgentRecord androidPick = manager.resolve(UaMode.auto);
      await manager.rotate(UaMode.desktop);
      // Rotating desktop must not move the Android pick.
      expect(manager.resolve(UaMode.auto).id, androidPick.id);
    });
  });

  group('UserAgentManager.rotateRandom', () {
    test(
      'picks a different record of the same category and persists it',
      () async {
        final ProviderContainer c = container();
        final UserAgentManager manager = c.read(userAgentManagerProvider);
        final UserAgentRecord before = manager.resolve(UaMode.android);
        final UserAgentRecord after = await manager.rotateRandom(
          UaMode.android,
        );
        expect(after.category, UserAgentCategory.android);
        expect(after.id, isNot(before.id));
        expect(after.ua, isNot(before.ua));
        // Sticky: the random pick survives further resolves ...
        expect(manager.resolve(UaMode.android).id, after.id);
        // ... and was persisted into settings.
        expect(c.read(settingsProvider).uaAndroidId, after.id);
      },
    );

    test('desktop rotation stays inside the desktop pool', () async {
      final ProviderContainer c = container();
      final UserAgentManager manager = c.read(userAgentManagerProvider);
      final UserAgentRecord after = await manager.rotateRandom(UaMode.desktop);
      expect(after.category, UserAgentCategory.desktop);
      expect(c.read(settingsProvider).uaDesktopId, after.id);
    });

    test('repeated calls always move away from the current pick', () async {
      final ProviderContainer c = container();
      final UserAgentManager manager = c.read(userAgentManagerProvider);
      UserAgentRecord current = manager.resolve(UaMode.android);
      for (var i = 0; i < 8; i++) {
        final UserAgentRecord next = await manager.rotateRandom(UaMode.android);
        expect(next.id, isNot(current.id));
        current = next;
      }
    });

    test('out-of-range saved id: rotation never returns the resolved pick '
        '(deterministic regression for the CI flake)', () async {
      // Default settings carry uaAndroidId = 1, which belongs to the
      // desktop pool. resolve(android) therefore falls back to
      // pool.first (id 169) — and rotation must never hand that record
      // back, no matter what the RNG picks. AlwaysZeroRandom forces the
      // worst case (first candidate), which pre-fix WAS pool.first.
      final ProviderContainer c = container();
      final UserAgentManager manager = c.read(userAgentManagerProvider);
      final UserAgentRecord current = manager.resolve(UaMode.android);
      expect(
        current.id,
        169,
        reason:
            'android pool starts at id 169; '
            'the default saved id (1) must be out of range for this test',
      );

      final UserAgentRecord next = await manager.rotateRandom(
        UaMode.android,
        rng: _AlwaysFirstRandom(),
      );
      expect(next.id, isNot(current.id));
      expect(next.category, UserAgentCategory.android);
      expect(c.read(settingsProvider).uaAndroidId, next.id);
    });
  });
}

/// RNG stub that always picks index 0 — the worst possible candidate.
class _AlwaysFirstRandom implements Random {
  @override
  bool nextBool() => true;

  @override
  int nextInt(int max) => 0;

  @override
  double nextDouble() => 0;
}
