import '../data/user_agents.g.dart';

/// User-Agent selection mode (Settings → User Agent).
///
/// * [auto]    — pick the category that matches the device context: the
///   embedded browser engine IS an Android WebView, so Auto uses an Android
///   User-Agent (the truthful identity, best session stability).
/// * [desktop] — restrict selection to the PC/desktop pool (the classic
///   "desktop site" compatibility override).
/// * [android] — restrict selection to the Android pool.
enum UaMode { auto, desktop, android }

/// Parses the persisted mode name; unknown values fall back to [UaMode.auto].
UaMode uaModeFromName(String? name) {
  for (final UaMode mode in UaMode.values) {
    if (mode.name == name) return mode;
  }
  return UaMode.auto;
}

/// Category of a User-Agent record.
enum UserAgentCategory { desktop, android }

/// Browser family a User-Agent record represents.
enum UserAgentBrowser {
  chrome,
  edge,
  firefox,
  safari,
  opera,
  samsungInternet,
  vivaldi,
}

/// One entry of the bundled User-Agent database (1000 records).
///
/// Every record was generated and format-validated by
/// `scripts/gen_user_agents.py` so [ua] matches the wire format of the real
/// browser it claims to be: Edge/EdgA majors equal their Chromium major,
/// Samsung Internet versions map to their bundled Chromium, phone UAs
/// carry the `Mobile` token while tablet UAs never do, and Android versions
/// are plausible for each device model. As of v1.41.5 every Chromium-based
/// record carries a Chromium major of 153+ (currently-supported trains
/// only), Firefox records use the newest trains (150+) and live ESR lines,
/// and Safari records use the 26.x/27.x trains.
class UserAgentRecord {
  const UserAgentRecord({
    required this.id,
    required this.category,
    required this.browser,
    required this.label,
    required this.ua,
  });

  /// Stable id, unique across the whole database (1..1000). The v1.41.5
  /// freshness refresh replaced the older 1200-149-era trains with the
  /// 153+-era ones, so a persisted id now identifies the pool SLOT, not a
  /// byte-frozen string; [UserAgentManager] falls back to the first record
  /// when a saved id no longer exists and self-heals on the next rotate.
  final int id;

  final UserAgentCategory category;

  final UserAgentBrowser browser;

  /// Human-readable summary, e.g. `Chrome 143 · Windows 10/11` or
  /// `Samsung Internet 27 · Samsung Galaxy S24 (Android 15)`.
  final String label;

  /// The full User-Agent string as sent over the wire.
  final String ua;

  bool get isDesktop => category == UserAgentCategory.desktop;
}

/// All records (168 desktop + 832 Android), generated + validated.
List<UserAgentRecord> get userAgentDatabase => kUserAgentDatabase;

/// Records of one category, ordered by id.
List<UserAgentRecord> userAgentsOf(UserAgentCategory category) =>
    kUserAgentDatabase
        .where((UserAgentRecord r) => r.category == category)
        .toList();
