/// Minimal vixie-cron compatible expression parser — v1.49.9.
///
/// Supports the standard 5-field form
///
///     minute  hour  day-of-month  month  day-of-week
///
/// with `*`, lists (`a,b,c`), ranges (`a-b`), steps (`*/n`, `a-b/n`),
/// month/day names (`jan…dec`, `sun…sat`, case-insensitive) and the
/// `@hourly @daily @weekly @monthly @yearly` shortcuts. The vixie OR
/// rule for restricted day-of-month AND day-of-week is implemented: when
/// both fields are restricted the job fires when EITHER matches.
///
/// Pure Dart with an injectable "now" so [nextAfter] is fully
/// deterministic in tests. Seconds are not supported (minute
/// granularity matches the app's 15 s scheduler tick).
library;

/// Parsed, validated cron expression. Construct via [CronExpression.parse]
/// (throws [CronFormatException] on bad input).
class CronExpression {
  CronExpression._(
    this.source, {
    required this.minutes,
    required this.hours,
    required this.daysOfMonth,
    required this.months,
    required this.daysOfWeek,
    required this.domRestricted,
    required this.dowRestricted,
  });

  /// The exact source text this expression was parsed from.
  final String source;

  /// Match sets (sorted, deduplicated, within valid ranges).
  final Set<int> minutes; // 0-59
  final Set<int> hours; // 0-23
  final Set<int> daysOfMonth; // 1-31
  final Set<int> months; // 1-12
  final Set<int> daysOfWeek; // 0-6 (0 = Sunday)

  final bool domRestricted;
  final bool dowRestricted;

  /// Shortcuts accepted instead of the 5-field form.
  static const Map<String, String> shortcuts = <String, String>{
    '@hourly': '0 * * * *',
    '@daily': '0 0 * * *',
    '@midnight': '0 0 * * *',
    '@weekly': '0 0 * * 0',
    '@monthly': '0 0 1 * *',
    '@yearly': '0 0 1 1 *',
    '@annually': '0 0 1 1 *',
  };

  static const List<String> _monthNames = <String>[
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  static const List<String> _dayNames = <String>[
    'sun',
    'mon',
    'tue',
    'wed',
    'thu',
    'fri',
    'sat',
  ];

  /// Parses [input]; throws [CronFormatException] when invalid.
  factory CronExpression.parse(String input) {
    String source = input.trim();
    if (source.isEmpty) {
      throw const CronFormatException('expression is empty');
    }
    final String? expanded = shortcuts[source.toLowerCase()];
    if (expanded != null) source = expanded;
    final List<String> fields = source
        .split(RegExp(r'\s+'))
        .where((f) => f.isNotEmpty)
        .toList();
    if (fields.length != 5) {
      throw CronFormatException(
        'expected 5 fields (minute hour dom month dow), got ${fields.length}',
      );
    }
    return CronExpression._(
      input.trim(),
      minutes: _parseField(fields[0], 0, 59, null),
      hours: _parseField(fields[1], 0, 23, null),
      daysOfMonth: _parseField(fields[2], 1, 31, null),
      months: _parseField(fields[3], 1, 12, _monthNames),
      daysOfWeek: _normalizeDow(_parseField(fields[4], 0, 7, _dayNames)),
      domRestricted: !_isWildcard(fields[2]),
      dowRestricted: !_isWildcard(fields[4]),
    );
  }

  /// vixie cron allows 0 and 7 for Sunday; normalize 7 → 0.
  static Set<int> _normalizeDow(Set<int> values) =>
      values.map((v) => v == 7 ? 0 : v).toSet();

  static bool _isWildcard(String field) =>
      field.trim() == '*' || field.trim().startsWith('*/');

  /// Parses one comma-separated cron field into a set of ints.
  static Set<int> _parseField(
    String field,
    int min,
    int max,
    List<String>? names,
  ) {
    final Set<int> out = <int>{};
    for (final String part in field.split(',')) {
      if (part.isEmpty) {
        throw CronFormatException('empty list element in "$field"');
      }
      // step syntax: "*", "*/n", "a-b/n", "a/n" (treated as a-b/a/n... vixie
      // treats "a/n" as "a-max/n"; keep the same behaviour).
      final List<String> stepSplit = part.split('/');
      if (stepSplit.length > 2) {
        throw CronFormatException('too many "/" in "$part"');
      }
      final String rangePart = stepSplit[0];
      int? step;
      if (stepSplit.length == 2) {
        step = int.tryParse(stepSplit[1]);
        if (step == null || step < 1) {
          throw CronFormatException('invalid step "/${stepSplit[1]}"');
        }
      }
      int lo;
      int hi;
      if (rangePart == '*') {
        lo = min;
        hi = max;
      } else if (rangePart.contains('-')) {
        final List<String> bounds = rangePart.split('-');
        if (bounds.length != 2) {
          throw CronFormatException('invalid range "$rangePart"');
        }
        lo = _value(bounds[0], min, max, names);
        hi = _value(bounds[1], min, max, names);
        // vixie allows wrapped ranges (5-2 = 5,6,7,...,2); keep it simple
        // and correct for the common case: require lo <= hi.
        if (lo > hi) {
          throw CronFormatException('reversed range "$rangePart"');
        }
      } else {
        lo = hi = _value(rangePart, min, max, names);
      }
      if (lo < min || hi > max) {
        throw CronFormatException('value out of range ($min-$max) in "$part"');
      }
      if (step == null) {
        for (int v = lo; v <= hi; v++) {
          out.add(v);
        }
      } else {
        for (int v = lo; v <= hi; v += step) {
          out.add(v);
        }
      }
    }
    if (out.isEmpty) {
      throw CronFormatException('field "$field" matches nothing');
    }
    return out;
  }

  static int _value(String token, int min, int max, List<String>? names) {
    final String t = token.trim().toLowerCase();
    if (names != null) {
      final int index = names.indexOf(t);
      if (index >= 0) {
        // months are 1-based; day names are 0-based.
        return min == 1 ? index + 1 : index;
      }
    }
    final int? value = int.tryParse(t);
    if (value == null) {
      throw CronFormatException('invalid value "$token"');
    }
    return value;
  }

  /// Whether [time] matches this expression (calendar fields only).
  bool matches(DateTime time) {
    if (!minutes.contains(time.minute)) return false;
    if (!hours.contains(time.hour)) return false;
    if (!months.contains(time.month)) return false;
    final bool domMatch = daysOfMonth.contains(time.day);
    final bool dowMatch = daysOfWeek.contains(time.weekday % 7);
    // Dart: Monday=1 … Sunday=7 → cron: Sunday=0 … Saturday=6.
    if (domRestricted && dowRestricted) {
      return domMatch || dowMatch; // vixie OR rule
    }
    if (domRestricted) return domMatch;
    if (dowRestricted) return dowMatch;
    return true;
  }

  /// Next matching instant strictly AFTER [from], or null when nothing
  /// matches within the next 366 days. The returned DateTime is in local
  /// time with seconds/milliseconds zeroed.
  DateTime? nextAfter(DateTime from) {
    DateTime t = from
        .add(const Duration(minutes: 1))
        .copyWith(second: 0, millisecond: 0, microsecond: 0);
    final DateTime limit = t.add(const Duration(days: 366));
    while (t.isBefore(limit)) {
      // Skip whole months when the month can never match.
      if (!months.contains(t.month)) {
        t = DateTime(t.year, t.month + 1, 1);
        continue;
      }
      if (!matches(t)) {
        // Advance in whole-hour hops when the hour is out of range; the
        // per-minute check inside [matches] still guards correctness.
        // Regression v1.49.9: the previous 30-minute hop re-floored
        // minutes to :00, so an anchor already sitting on an excluded
        // hour boundary (e.g. 11:00 with "0 8 * * *") recomputed the
        // SAME instant forever and spun the isolate at 100% CPU.
        // DateTime(hour + 1) always advances (and normalizes 24 → next
        // day), so termination is guaranteed by the 366-day limit.
        if (!hours.contains(t.hour)) {
          t = DateTime(t.year, t.month, t.day, t.hour + 1);
          continue;
        }
        t = t.add(const Duration(minutes: 1));
        continue;
      }
      return t;
    }
    return null;
  }
}

/// Thrown by [CronExpression.parse] with a human-readable reason (shown
/// verbatim in the editor UI).
class CronFormatException implements Exception {
  const CronFormatException(this.message);
  final String message;

  @override
  String toString() => 'CronFormatException: $message';
}
