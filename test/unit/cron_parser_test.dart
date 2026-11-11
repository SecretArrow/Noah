import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/cron_parser.dart';

void main() {
  group('CronExpression.parse', () {
    test('accepts the 5-field form', () {
      final CronExpression cron = CronExpression.parse('30 8 * * *');
      expect(cron.minutes, <int>{30});
      expect(cron.hours, <int>{8});
      expect(cron.daysOfMonth.length, 31);
      expect(cron.months.length, 12);
      expect(cron.daysOfWeek.length, 7);
    });

    test('rejects wrong field counts', () {
      expect(
        () => CronExpression.parse('* * * *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse('* * * * * *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse(''),
        throwsA(isA<CronFormatException>()),
      );
    });

    test('expands @shortcuts', () {
      expect(CronExpression.parse('@daily').hours, <int>{0});
      expect(CronExpression.parse('@HOURLY').minutes, <int>{0});
      expect(CronExpression.parse('@weekly').daysOfWeek, <int>{0});
      expect(CronExpression.parse('@monthly').daysOfMonth, <int>{1});
      expect(CronExpression.parse('@yearly').months, <int>{1});
    });

    test('parses lists, ranges, steps and names', () {
      // Month names belong in the MONTH field (4th); the pre-fix typo put
      // "jan,mar" in the day-of-week slot, where the parser correctly
      // rejects them (day names are sun..sat).
      final CronExpression cron = CronExpression.parse(
        '0,15,30 9-11 */2 jan,mar *',
      );
      expect(cron.minutes, <int>{0, 15, 30});
      expect(cron.hours, <int>{9, 10, 11});
      expect(cron.daysOfMonth, <int>{
        1,
        3,
        5,
        7,
        9,
        11,
        13,
        15,
        17,
        19,
        21,
        23,
        25,
        27,
        29,
        31,
      });
      expect(cron.months, <int>{1, 3});
    });

    test('parses day names and normalizes sunday=7 to 0', () {
      expect(CronExpression.parse('0 0 * * mon-fri').daysOfWeek, <int>{
        1,
        2,
        3,
        4,
        5,
      });
      expect(CronExpression.parse('0 0 * * SUN').daysOfWeek, <int>{0});
      expect(CronExpression.parse('0 0 * * 7').daysOfWeek, <int>{0});
    });

    test('rejects out-of-range and malformed values', () {
      expect(
        () => CronExpression.parse('60 * * * *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse('* 24 * * *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse('* * 0 * *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse('* * * 13 *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse('*/0 * * * *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse('a * * * *'),
        throwsA(isA<CronFormatException>()),
      );
      expect(
        () => CronExpression.parse('5-2 * * * *'),
        throwsA(isA<CronFormatException>()),
      );
    });
  });

  group('CronExpression.nextAfter', () {
    // Fixed anchor: Wednesday 2026-01-14 10:30 local.
    final DateTime anchor = DateTime(2026, 1, 14, 10, 30);

    test('returns strictly the next minute match', () {
      final DateTime? next = CronExpression.parse('32 10 * * *')
          .nextAfter(anchor);
      expect(next, DateTime(2026, 1, 14, 10, 32));
    });

    test('skips to the next day when today no longer matches', () {
      final DateTime? next = CronExpression.parse('0 8 * * *')
          .nextAfter(anchor);
      expect(next, DateTime(2026, 1, 15, 8, 0));
    });

    test('respects day-of-week names', () {
      // anchor is a Wednesday → next mon-fri match is Thursday; next
      // mon-only match is the following Monday (2026-01-19).
      expect(
        CronExpression.parse('0 9 * * mon').nextAfter(anchor),
        DateTime(2026, 1, 19, 9, 0),
      );
      expect(
        CronExpression.parse('0 9 * * mon-fri').nextAfter(anchor),
        DateTime(2026, 1, 15, 9, 0),
      );
    });

    test('respects months and jumps whole non-matching months', () {
      expect(
        CronExpression.parse('0 8 1 3 *').nextAfter(anchor),
        DateTime(2026, 3, 1, 8, 0),
      );
      expect(
        CronExpression.parse('0 8 1 1 *').nextAfter(anchor),
        DateTime(2027, 1, 1, 8, 0),
      );
    });

    test('vixie OR rule: restricted dom OR dow fires on either', () {
      final CronExpression cron = CronExpression.parse('0 8 13 * fri');
      // dom=13, dow=fri; 2026-01-16 is a Friday → fires even though dom≠13.
      final DateTime? first = cron.nextAfter(anchor);
      expect(first, DateTime(2026, 1, 16, 8, 0));
      // With dow restricted, EVERY Friday is a fire — chain through them
      // and confirm 2026-02-13 (a Friday that is also the 13th) still
      // fires exactly ONCE: never skipped, never doubled.
      final List<DateTime> fires = <DateTime>[first!];
      DateTime cursor = first;
      for (var i = 0; i < 5; i++) {
        cursor = cron.nextAfter(cursor)!;
        fires.add(cursor);
      }
      expect(fires, <DateTime>[
        DateTime(2026, 1, 16, 8, 0),
        DateTime(2026, 1, 23, 8, 0),
        DateTime(2026, 1, 30, 8, 0),
        DateTime(2026, 2, 6, 8, 0),
        DateTime(2026, 2, 13, 8, 0),
        DateTime(2026, 2, 20, 8, 0),
      ]);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('steps and ranges compute matches', () {
      expect(
        CronExpression.parse('*/15 10 * * *').nextAfter(anchor),
        DateTime(2026, 1, 14, 10, 45),
      );
      expect(
        CronExpression.parse('*/15 11 * * *').nextAfter(anchor),
        DateTime(2026, 1, 14, 11, 0),
      );
    });

    test('never fires in the past (strictly after)', () {
      final DateTime? next = CronExpression.parse('30 10 * * *')
          .nextAfter(anchor);
      // Same wall-clock minute as the anchor must be skipped.
      expect(next, DateTime(2026, 1, 15, 10, 30));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('year boundary works', () {
      final DateTime? next = CronExpression.parse('0 0 1 1 *')
          .nextAfter(DateTime(2026, 12, 31, 12, 0));
      expect(next, DateTime(2027, 1, 1, 0, 0));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
      'hour-boundary anchor never stalls the hour hop (regression v1.49.9)',
      () {
        // The old 30-minute hop re-floored minutes to :00, so an anchor
        // already sitting on an excluded hour boundary recomputed the
        // SAME instant forever (100% CPU spin, silent test hang). Both
        // anchors below hit that exact trap with "0 8 * * *".
        expect(
          CronExpression.parse('0 8 * * *')
              .nextAfter(DateTime(2026, 1, 14, 11)),
          DateTime(2026, 1, 15, 8),
        );
        expect(
          CronExpression.parse('0 8 * * *')
              .nextAfter(DateTime(2026, 1, 14, 13, 31)),
          DateTime(2026, 1, 15, 8),
        );
        // Midnight boundary: hour 0 excluded, hour 24 normalization.
        expect(
          CronExpression.parse('30 9 * * *')
              .nextAfter(DateTime(2026, 1, 14, 23, 59)),
          DateTime(2026, 1, 15, 9, 30),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
