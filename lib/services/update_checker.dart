import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of an in-app update check against GitHub Releases.
///
/// Deliberately a plain data class: the UI layer decides what to do with
/// it (banner, dialog, "skip this version" preference, opening the
/// release page or the APK URL). This service never downloads anything
/// and stores no state.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.ok,
    this.error,
    this.latestTag = '',
    this.releaseUrl,
    this.apkDownloadUrl,
    this.updateAvailable = false,
  });

  /// Whether the request itself succeeded (HTTP 200 with a parseable
  /// release payload). False does not mean "no update available" — it
  /// means the check could not be completed; [error] then says why.
  final bool ok;

  /// Human-readable failure reason (network error, HTTP status, rate
  /// limit, malformed payload). Null when [ok] is true.
  final String? error;

  /// Latest published release tag, e.g. `v1.44.0`. Empty when [ok] is
  /// false.
  final String latestTag;

  /// HTML page of the release (GitHub `html_url`), when the payload
  /// provides one.
  final String? releaseUrl;

  /// Direct download URL of the APK asset to sideload. Prefers the
  /// *universal* build: the first `.apk` asset whose file name carries
  /// no ABI suffix such as `arm64-v8a` (the release pipeline ships a
  /// universal APK plus per-ABI splits). Falls back to the first `.apk`
  /// asset when only per-ABI splits exist. Null when the release ships
  /// no APK asset at all.
  final String? apkDownloadUrl;

  /// Whether [latestTag] is semver-newer than the running version (see
  /// [isNewerVersion]). Always false when [ok] is false.
  final bool updateAvailable;
}

/// File-name markers that identify per-ABI split APKs
/// (`Noah-<ver>-arm64-v8a.apk` and friends). A `.apk` asset whose
/// lowercased name contains none of these is the universal build.
const List<String> _abiSplitMarkers = <String>[
  'arm64-v8a',
  'armeabi-v7a',
  'x86_64',
];

/// Numeric core segments plus the optional `-prerelease` suffix of a
/// version string; `+build` metadata is stripped away before parsing.
class _ParsedVersion {
  const _ParsedVersion(this.core, this.prerelease);

  final List<int> core;
  final String? prerelease;
}

/// Reports whether [latest] is strictly newer than [current], using a
/// numeric semver comparison — never a string comparison, so `1.10.0`
/// is correctly newer than `1.9.0`.
///
/// Deterministic rules:
/// - Leading `v`/`V` and build metadata from the first `+` onward
///   (`1.43.1+59` → `1.43.1`) are stripped before comparing; a differing
///   `+build` number alone therefore never counts as an update.
/// - Cores are compared segment by segment, numerically. Missing
///   segments count as 0 (`1.44` equals `1.44.0`), and non-numeric
///   segments parse as 0 (defensive against odd tags).
/// - A `-prerelease` suffix is separated before the core comparison.
///   With equal cores:
///   - latest prerelease, current stable → NOT newer (`1.44.0-beta`
///     does not supersede an installed `1.44.0`);
///   - latest stable, current prerelease → newer (the stable `1.44.0`
///     supersedes an installed `1.44.0-beta`);
///   - both prereleases → semver identifier comparison (numeric
///     identifiers numerically, otherwise ASCII-lexicographic; the
///     shorter identifier list loses when all shared ones are equal).
/// - Everything else compares false, including exact equality.
bool isNewerVersion(String latest, String current) {
  final _ParsedVersion a = _parseVersion(latest);
  final _ParsedVersion b = _parseVersion(current);
  final int segments = a.core.length > b.core.length
      ? a.core.length
      : b.core.length;
  for (int i = 0; i < segments; i++) {
    final int ai = i < a.core.length ? a.core[i] : 0;
    final int bi = i < b.core.length ? b.core[i] : 0;
    if (ai != bi) return ai > bi;
  }
  if (a.prerelease == null && b.prerelease == null) return false;
  if (a.prerelease != null && b.prerelease == null) return false;
  if (a.prerelease == null && b.prerelease != null) return true;
  return _comparePrerelease(a.prerelease!, b.prerelease!) > 0;
}

/// Splits a raw version/tag into its numeric core and optional
/// prerelease, applying the stripping rules documented on
/// [isNewerVersion].
_ParsedVersion _parseVersion(String raw) {
  String s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final int plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);
  String? prerelease;
  final int dash = s.indexOf('-');
  if (dash >= 0) {
    prerelease = s.substring(dash + 1);
    s = s.substring(0, dash);
  }
  final List<int> core = <int>[
    for (final String segment in s.split('.'))
      int.tryParse(segment.trim()) ?? 0,
  ];
  return _ParsedVersion(core, prerelease);
}

/// Semver-style comparison of two `-prerelease` suffixes: identifiers
/// are split on `.`, compared numerically when both are numeric,
/// otherwise ASCII-lexicographically, with numeric identifiers sorting
/// below alphanumeric ones and the shorter list losing when all shared
/// identifiers are equal.
int _comparePrerelease(String a, String b) {
  final List<String> left = a.split('.');
  final List<String> right = b.split('.');
  final int shared = left.length < right.length ? left.length : right.length;
  for (int i = 0; i < shared; i++) {
    final int? ln = int.tryParse(left[i]);
    final int? rn = int.tryParse(right[i]);
    final int cmp;
    if (ln != null && rn != null) {
      cmp = ln.compareTo(rn);
    } else if (ln != null) {
      cmp = -1;
    } else if (rn != null) {
      cmp = 1;
    } else {
      cmp = left[i].compareTo(right[i]);
    }
    if (cmp != 0) return cmp;
  }
  return left.length.compareTo(right.length);
}

/// Checks GitHub Releases for a newer Noah build — the in-app update
/// checker for the sideloaded-APK distribution channel.
///
/// Queries `https://api.github.com/repos/<repo>/releases/latest` and
/// reports the latest tag, the release page and the APK asset to
/// sideload (universal build preferred over per-ABI splits). Pure Dart:
/// no Flutter/plugin imports, no persistence, no auto-download — the UI
/// layer owns prefs, prompts and the actual install flow. Fully
/// unit-testable with a mocked [http.Client].
class UpdateChecker {
  UpdateChecker({http.Client? client, this.repo = defaultRepo})
    : _client = client ?? http.Client();

  /// GitHub repo queried for releases, as `owner/name`.
  final String repo;

  final http.Client _client;

  /// Repo whose releases are checked by default.
  static const String defaultRepo = 'SecretArrow/Noah';

  /// Hard cap for the request; a hung captive portal must not block the
  /// caller for long.
  static const Duration requestTimeout = Duration(seconds: 10);

  /// User-Agent that identifies the app to the GitHub API.
  static const String userAgent = 'Noah-UpdateChecker';

  Uri get _apiUrl =>
      Uri.parse('https://api.github.com/repos/$repo/releases/latest');

  /// Runs one update check against the latest published release.
  ///
  /// Never throws: every failure mode (timeout, network error, non-200,
  /// rate limit, invalid JSON, unexpected payload) degrades to an
  /// `ok: false` result carrying a human-readable
  /// [UpdateCheckResult.error].
  Future<UpdateCheckResult> check({required String currentVersion}) async {
    final http.Request request = http.Request('GET', _apiUrl)
      ..headers['Accept'] = 'application/vnd.github+json'
      ..headers['User-Agent'] = userAgent;

    final http.StreamedResponse response;
    final String body;
    try {
      response = await _client.send(request).timeout(requestTimeout);
      body = await response.stream.bytesToString();
    } on TimeoutException {
      return _failure(
        'Update check timed out after ${requestTimeout.inSeconds}s.',
      );
    } catch (e) {
      return _failure('Network error while checking for updates: $e');
    }

    final int status = response.statusCode;
    if (status == 404) {
      return _failure('No published release found for $repo (HTTP 404).');
    }
    if (status == 403) {
      return _failure(
        'GitHub API rate limit reached (HTTP 403). Try again later.',
      );
    }
    if (status < 200 || status >= 300) {
      return _failure('GitHub API returned HTTP $status.');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      return _failure('GitHub API response is not valid JSON: $e');
    }
    if (decoded is! Map) {
      return _failure('GitHub API response is not a JSON object.');
    }

    final Object? tag = decoded['tag_name'];
    if (tag is! String || tag.trim().isEmpty) {
      return _failure('GitHub release payload is missing tag_name.');
    }
    final String latestTag = tag.trim();

    final Object? htmlUrl = decoded['html_url'];
    final String? releaseUrl = htmlUrl is String && htmlUrl.trim().isNotEmpty
        ? htmlUrl
        : null;

    final Object? rawAssets = decoded['assets'];
    final List<Object?> assetList = <Object?>[
      if (rawAssets is List) ...rawAssets,
    ];

    return UpdateCheckResult(
      ok: true,
      latestTag: latestTag,
      releaseUrl: releaseUrl,
      apkDownloadUrl: _selectApkDownloadUrl(assetList),
      updateAvailable: isNewerVersion(latestTag, currentVersion),
    );
  }

  UpdateCheckResult _failure(String message) =>
      UpdateCheckResult(ok: false, error: message);

  /// Picks the download URL of the APK asset to sideload: the first
  /// `.apk` asset whose name carries no ABI marker (the universal
  /// build), else the first `.apk` asset at all, else null (release
  /// without APK assets, e.g. source-only releases).
  static String? _selectApkDownloadUrl(List<Object?> assets) {
    String? firstApkUrl;
    for (final Object? asset in assets) {
      if (asset is! Map) continue;
      final Object? name = asset['name'];
      final Object? url = asset['browser_download_url'];
      if (name is! String || url is! String || url.trim().isEmpty) continue;
      final String lower = name.toLowerCase();
      if (!lower.endsWith('.apk')) continue;
      firstApkUrl ??= url;
      final bool isAbiSplit = _abiSplitMarkers.any(lower.contains);
      if (!isAbiSplit) return url;
    }
    return firstApkUrl;
  }
}
