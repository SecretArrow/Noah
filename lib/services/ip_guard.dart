import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../di.dart';
import '../l10n/app_strings.dart';

/// Chat-switch IP guard (v1.48.0): before a user-initiated switch into a
/// chat, optionally compare the device's current public IP with the last
/// IP recorded for THAT chat and ask for confirmation when they match.
///
/// Failure contract: the guard is a convenience warning, never a gate.
/// ANY problem fetching or parsing the IP (offline, timeout, captive
/// portal HTML, garbage body) degrades silently to "no warning, proceed".
/// The recorded memo is only refreshed when the current IP is actually
/// known — a failed fetch never overwrites previously stored data.
class IpGuard {
  IpGuard({required this.prefs, Future<String?> Function()? fetchIp})
    : _fetchIpOverride = fetchIp,
      client = null,
      resolveUserAgent = null,
      timeout = defaultTimeout;

  /// Creates the production guard with the default HTTP probe chain.
  ///
  /// [timeout] is injectable so tests can exercise the abort-on-stall path
  /// without waiting out the real 5 s budget. [resolveUserAgent] injects
  /// the User-Agent picked in Settings → User Agent — the probe is a
  /// plain web interaction (NOT the AgentRouter API), so it must present
  /// the chosen browser identity instead of Dart's default `Dart/x.y`
  /// string, which several echo services and middleboxes treat with
  /// suspicion.
  IpGuard.withClient({
    required this.prefs,
    this.client,
    this.resolveUserAgent,
    this.timeout = defaultTimeout,
  }) : _fetchIpOverride = null;

  final Future<String?> Function()? _fetchIpOverride;

  /// Optional HTTP client override (tests inject a MockClient here).
  final http.Client? client;

  /// Resolves the User-Agent header for probe requests — the identity
  /// the user picked in Settings (injected from di.dart in production;
  /// null means "send no explicit UA", e.g. in old-style unit tests).
  final String? Function()? resolveUserAgent;

  /// SharedPreferences holding the per-chat last-IP memo (injected via
  /// ipMemoPrefsProvider in production; a mock instance in tests).
  final SharedPreferences prefs;

  /// Plain-text public-IP echo services, tried IN ORDER until one answers
  /// with a plausible literal — no JSON, no HTML: the response body IS the
  /// address. The first entry is the primary; the rest are fallbacks for
  /// networks that block, misroute or mangle the primary (the single-endpoint
  /// v1.48.0 probe degraded silently on such networks, which made the whole
  /// guard look dead even with the toggle ON).
  static const List<String> probeUrls = <String>[
    'https://api.ipify.org',
    'https://checkip.amazonaws.com',
    'https://icanhazip.com',
    'https://ifconfig.me/ip',
  ];

  /// Production connect + response budget FOR THE WHOLE CHAIN. A chat
  /// switch must stay snappy; when no endpoint answers in time the
  /// switch simply proceeds unguarded. Each attempt gets its share of
  /// the remaining budget (remaining ÷ endpoints still untried), so one
  /// hanging endpoint can never starve the fallbacks.
  static const Duration defaultTimeout = Duration(seconds: 5);

  /// Per-instance budget (see [IpGuard.withClient]).
  final Duration timeout;

  /// SharedPreferences key holding the per-chat last-IP memo
  /// (`{'<chatId>': '<ip>', ...}` as JSON, most-recent last, capped).
  static const String memoKey = 'zagents.ipmemo.v1';

  /// Upper bound of tracked chats. The memo is a rotating fingerprint of
  /// recent usage, not an archive — the oldest entry is dropped first.
  static const int memoCap = 200;

  /// Fetches the current public IP. Returns null whenever the address
  /// cannot be determined — callers must treat null as "skip the check".
  Future<String?> fetchPublicIp() async {
    if (_fetchIpOverride != null) return _fetchIpOverride();
    return _fetchIpFromChain();
  }

  /// Walks [probeUrls] inside the overall [timeout] budget. The injected
  /// [client] (tests) is reused for every attempt; production opens one
  /// short-lived client for the whole chain.
  Future<String?> _fetchIpFromChain() async {
    final Stopwatch clock = Stopwatch()..start();
    final http.Client probeClient = client ?? http.Client();
    try {
      for (int index = 0; index < probeUrls.length; index++) {
        final Duration remaining = timeout - clock.elapsed;
        if (remaining <= Duration.zero) return null;
        // Split the remaining budget over the endpoints still untried so
        // every fallback gets a fair slice even if the primary stalls.
        final Duration attempt = remaining ~/ (probeUrls.length - index);
        final String? ip = await _probeOnce(
          probeClient,
          probeUrls[index],
          attempt,
        );
        if (ip != null) return ip;
      }
      return null;
    } finally {
      // Only close a client THIS call created (test clients stay open).
      if (client == null) {
        probeClient.close();
      }
    }
  }

  /// One echo attempt: chosen User-Agent, plain-text Accept, strict body
  /// validation via [normalizeIp]. ANY failure (socket, timeout, status,
  /// garbage body) degrades to null so the chain can try the next
  /// endpoint — and so a fully unreachable network never blocks a switch.
  Future<String?> _probeOnce(
    http.Client probeClient,
    String url,
    Duration attempt,
  ) async {
    try {
      final Map<String, String> headers = <String, String>{
        'Accept': 'text/plain',
      };
      final String? ua = resolveUserAgent?.call();
      if (ua != null && ua.isNotEmpty) {
        headers['User-Agent'] = ua;
      }
      final http.Response response = await probeClient
          .get(Uri.parse(url), headers: headers)
          .timeout(attempt);
      if (response.statusCode != 200) return null;
      return normalizeIp(response.body);
    } catch (_) {
      // Offline / timeout / socket error / redirect-to-portal: this
      // endpoint failed — the chain decides whether to try another.
      return null;
    }
  }

  /// Trims a candidate body and accepts it only when it looks like a
  /// plausible IPv4 or IPv6 literal — never HTML, JSON or an error page.
  /// Returns null for anything implausible.
  static String? normalizeIp(String body) {
    final String candidate = body.trim();
    if (candidate.isEmpty || candidate.length > 45) return null;
    // A literal address can only contain hex digits, dots and colons —
    // this alone rejects HTML pages, JSON envelopes and "invalid request"
    // prose from misbehaving mirrors.
    if (RegExp(r'^[0-9A-Fa-f.:]+$').allMatches(candidate).isEmpty) {
      return null;
    }
    if (_isPlausibleIpv4(candidate) || _isPlausibleIpv6(candidate)) {
      return candidate;
    }
    return null;
  }

  static bool _isPlausibleIpv4(String value) {
    final List<String> parts = value.split('.');
    if (parts.length != 4) return false;
    for (final String part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      final int? octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return false;
    }
    return true;
  }

  static bool _isPlausibleIpv6(String value) {
    // Light validation on purpose: at least one ':' (so bare IPv4 never
    // takes this path), hex groups only, and a sane length. Full RFC 4291
    // parsing is overkill for a warning heuristic.
    if (!value.contains(':')) return false;
    if (RegExp(r':::{2,}').hasMatch(value)) return false;
    return RegExp(r'^[0-9A-Fa-f:]{2,45}$').hasMatch(value);
  }

  /// Centralized pre-switch check. Returns true when the caller may
  /// proceed with the chat switch, false when the user cancelled.
  ///
  /// Order of guarantees:
  /// 1. Setting off → allow immediately (no network call).
  /// 2. IP unknown → allow (never block on a failed probe).
  /// 3. No memo / different IP → allow AND refresh the memo.
  /// 4. Same IP → warn; Cancel → abort (false), Continue → refresh memo
  ///    and allow.
  Future<bool> confirmChatSwitch(
    BuildContext context,
    WidgetRef ref,
    String targetChatId,
  ) async {
    if (!ref.read(settingsProvider).ipSwitchWarnEnabled) return true;
    final String? currentIp = await fetchPublicIp();
    if (currentIp == null) return true;
    if (!context.mounted) return false;
    final String? lastIp = readMemo()[targetChatId];
    if (lastIp != null && lastIp == currentIp) {
      final AppStrings strings = stringsOf(context);
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          key: const Key('ip-switch-warn-dialog'),
          title: Text(strings.ipSwitchWarnDialogTitle),
          content: Text(strings.ipSwitchWarnDialogBody(currentIp)),
          actions: <Widget>[
            TextButton(
              key: const Key('ip-switch-warn-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const Key('ip-switch-warn-continue'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.ipSwitchWarnContinue),
            ),
          ],
        ),
      );
      if (proceed != true) return false;
    }
    // Refresh the memo BEFORE returning so the next switch compares
    // against fresh data (also covers the no-warning-needed path).
    recordMemo(targetChatId, currentIp);
    return true;
  }

  /// Reads the per-chat last-IP map. A missing/corrupted entry degrades to
  /// an empty map — the guard then behaves like "first visit".
  Map<String, String> readMemo() {
    try {
      final String? raw = prefs.getString(memoKey);
      if (raw == null || raw.isEmpty) return <String, String>{};
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, String>{};
      return <String, String>{
        for (final MapEntry<String, dynamic> e in decoded.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  /// Stores [ip] as the last-seen IP for [chatId], marking it the most
  /// recent entry and evicting the oldest beyond [memoCap].
  void recordMemo(String chatId, String ip) {
    final Map<String, String> memo = readMemo()
      ..remove(chatId)
      ..[chatId] = ip;
    while (memo.length > memoCap) {
      memo.remove(memo.keys.first);
    }
    try {
      prefs.setString(memoKey, jsonEncode(memo));
    } catch (_) {
      // A failed memo write only means the next switch may warn once more.
    }
  }
}
