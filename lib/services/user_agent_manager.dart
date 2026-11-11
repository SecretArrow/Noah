import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart' show AppSettings;
import '../models/user_agent.dart';
import '../di.dart';

/// Resolves the User-Agent used by every embedded browser surface
/// (browser automation, in-page fetch) according to the configured
/// [UaMode].
///
/// Selection policy (stability first):
/// * **Auto** resolves to the Android category — the embedded engine is a
///   real Android WebView, so an Android User-Agent is the truthful,
///   best-compatible identity.
/// * The active pick per category is **sticky**: it is persisted in
///   settings and survives restarts. It never changes by itself during a
///   session; only an explicit rotate (user action) moves to the next id.
/// * Rotation walks the category list in order and wraps around — no
///   repeats until the whole pool has been used once.
/// * If a stored id no longer exists (database shrank), resolution falls
///   back to the first record and self-heals on the next rotate.
class UserAgentManager {
  UserAgentManager(this._ref);

  final Ref _ref;

  /// Category a mode maps to. Auto = device-native (Android).
  UserAgentCategory categoryFor(UaMode mode) => mode == UaMode.desktop
      ? UserAgentCategory.desktop
      : UserAgentCategory.android;

  /// The active, sticky record for [mode].
  UserAgentRecord resolve(UaMode mode) {
    final AppSettings settings = _ref.read(settingsProvider);
    final UserAgentCategory category = categoryFor(mode);
    final int savedId = category == UserAgentCategory.desktop
        ? settings.uaDesktopId
        : settings.uaAndroidId;
    final List<UserAgentRecord> pool = userAgentsOf(category);
    for (final UserAgentRecord r in pool) {
      if (r.id == savedId) return r;
    }
    return pool.first;
  }

  /// Convenience: resolved record for the currently configured mode.
  UserAgentRecord resolveCurrent() =>
      resolve(_ref.read(settingsProvider).uaMode);

  /// Moves the sticky pick of [mode] to the next record of its category
  /// (wrapping around, no repeats within a full cycle) and persists it.
  Future<UserAgentRecord> rotate(UaMode mode) async {
    final AppSettings settings = _ref.read(settingsProvider);
    final UserAgentCategory category = categoryFor(mode);
    final List<UserAgentRecord> pool = userAgentsOf(category);
    final int savedId = category == UserAgentCategory.desktop
        ? settings.uaDesktopId
        : settings.uaAndroidId;
    int index = 0;
    for (var i = 0; i < pool.length; i++) {
      if (pool[i].id == savedId) {
        index = i;
        break;
      }
    }
    final UserAgentRecord next = pool[(index + 1) % pool.length];
    final AppSettings updated = category == UserAgentCategory.desktop
        ? settings.copyWith(uaDesktopId: next.id)
        : settings.copyWith(uaAndroidId: next.id);
    await _ref.read(settingsProvider.notifier).update(updated);
    return next;
  }

  /// Picks a genuinely RANDOM record of [mode]'s category (never the
  /// currently active one) and persists it as the new sticky pick. Used by
  /// the "New chat" prompt when the user accepts a random identity change.
  ///
  /// The exclusion target is the RESOLVED current record — not the raw
  /// persisted id. When the saved id is absent from the pool (fresh
  /// install default, database shrank), [resolve] falls back to
  /// `pool.first`; excluding only the raw id would let the random pick
  /// land on `pool.first` — i.e. hand back the record the user already
  /// has. [rng] is injectable for deterministic tests; production uses
  /// `Random.secure()`.
  Future<UserAgentRecord> rotateRandom(UaMode mode, {Random? rng}) async {
    final UserAgentCategory category = categoryFor(mode);
    final UserAgentRecord current = resolve(mode);
    final List<UserAgentRecord> pool = userAgentsOf(category);
    final List<UserAgentRecord> candidates = <UserAgentRecord>[
      for (final UserAgentRecord r in pool)
        if (r.id != current.id) r,
    ];
    // Degenerate pool (single record): keep the current one.
    if (candidates.isEmpty) return current;
    final UserAgentRecord next =
        candidates[(rng ?? Random.secure()).nextInt(candidates.length)];
    final AppSettings settings = _ref.read(settingsProvider);
    final AppSettings updated = category == UserAgentCategory.desktop
        ? settings.copyWith(uaDesktopId: next.id)
        : settings.copyWith(uaAndroidId: next.id);
    await _ref.read(settingsProvider.notifier).update(updated);
    return next;
  }
}
