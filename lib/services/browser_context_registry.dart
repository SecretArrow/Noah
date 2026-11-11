/// In-memory registry of NAMED browser contexts (task 2-c).
///
/// One row per `browser_context_create`, keyed
/// `'nctx:<sessionId>:<name>'` — a namespace that can never collide with
/// the chat-default slot (`'s:<sessionId>'`), the subagent-fan slots
/// (`'ctx:<id>'`) or the legacy slot (`'_legacy'`) of the multi-context
/// browser engine. The registry tracks metadata only (who owns the
/// context, whether it persists, when it was last used, its last URL);
/// the cookies/storage themselves live in the engine's slots and — for
/// persistent contexts — in the session sandbox.
///
/// Pure Dart on purpose: no Flutter imports, so unit tests exercise it
/// without a binding and the browser service can embed it directly.
class BrowserContextInfo {
  const BrowserContextInfo({
    required this.key,
    required this.label,
    required this.persistent,
    required this.ownerSessionId,
    required this.createdAt,
    required this.lastUsedAt,
    this.lastUrl = '',
    this.originCount = 0,
  });

  /// Slot/registry key: `nctx:<sessionId>:<name>`.
  final String key;

  /// Human-facing name; the engine always registers with label == name.
  final String label;

  /// Whether the context hibernates to the session sandbox and survives
  /// restarts / evictions (`persistent=true`), or lives for the run only.
  final bool persistent;

  /// Chat session that created (and owns) this context.
  final String ownerSessionId;

  final DateTime createdAt;
  final DateTime lastUsedAt;

  /// Last URL routed into the context (empty when it never navigated).
  final String lastUrl;

  /// Number of origins captured in the context's state.
  final int originCount;

  BrowserContextInfo copyWith({
    String? label,
    bool? persistent,
    DateTime? lastUsedAt,
    String? lastUrl,
    int? originCount,
  }) => BrowserContextInfo(
    key: key,
    label: label ?? this.label,
    persistent: persistent ?? this.persistent,
    ownerSessionId: ownerSessionId,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    lastUrl: lastUrl ?? this.lastUrl,
    originCount: originCount ?? this.originCount,
  );
}

/// Tracks the named browser contexts of every chat session.
///
/// The registry is in-memory by design: persistent contexts are restored
/// from their sandbox files by the browser engine (which re-registers
/// them with their original creation time on `createContext`), so nothing
/// here needs its own storage.
class BrowserContextRegistry {
  /// Overridable clock so tests can make LRU ordering deterministic.
  BrowserContextRegistry({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  final Map<String, BrowserContextInfo> _contexts =
      <String, BrowserContextInfo>{};

  static final RegExp _namePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');

  /// Slot-key prefix that namespaces named contexts per chat session.
  static const String keyPrefix = 'nctx:';

  /// Names a context may never take: `default` is the chat's own slot and
  /// `_legacy` is the pre-isolation global slot; both must stay
  /// unreachable through the named-context API.
  static const Set<String> reservedNames = <String>{'default', '_legacy'};

  /// 1-32 chars: lowercase letter/digit first, then also `-` and `_`.
  static bool isValidName(String name) => _namePattern.hasMatch(name);

  /// Deterministic slot key for [name] inside chat session [sessionId].
  static String keyFor(String sessionId, String name) =>
      '$keyPrefix$sessionId:$name';

  /// Context name parsed back out of a `'nctx:<sessionId>:<name>'` key.
  static String nameFromKey(String key) {
    final String body = key.substring(keyPrefix.length);
    final int idx = body.lastIndexOf(':');
    return idx < 0 ? body : body.substring(idx + 1);
  }

  /// Registers a new named context and returns its info row.
  ///
  /// Throws [StateError] when [name] is already taken inside [sessionId].
  /// [createdAt]/[lastUrl]/[originCount] are restore hooks: the engine
  /// passes the original values back when re-registering a persistent
  /// context from its hibernation file.
  BrowserContextInfo register({
    required String sessionId,
    required String name,
    required bool persistent,
    String? label,
    DateTime? createdAt,
    String? lastUrl,
    int? originCount,
  }) {
    final String key = keyFor(sessionId, name);
    if (_contexts.containsKey(key)) {
      throw StateError('browser context already exists: $name');
    }
    final DateTime now = _now();
    return _contexts[key] = BrowserContextInfo(
      key: key,
      label: label ?? name,
      persistent: persistent,
      ownerSessionId: sessionId,
      createdAt: createdAt ?? now,
      lastUsedAt: now,
      lastUrl: lastUrl ?? '',
      originCount: originCount ?? 0,
    );
  }

  /// Marks [key] used now; updates [lastUrl] / [originCount] when given.
  /// Unknown keys are a no-op (the registry never tracks dead contexts).
  void touch(String key, {String? lastUrl, int? originCount}) {
    final BrowserContextInfo? current = _contexts[key];
    if (current == null) return;
    _contexts[key] = current.copyWith(
      lastUsedAt: _now(),
      lastUrl: lastUrl,
      originCount: originCount,
    );
  }

  bool isRegistered(String key) => _contexts.containsKey(key);

  BrowserContextInfo? info(String key) => _contexts[key];

  /// Contexts owned by [sessionId], oldest creation first.
  List<BrowserContextInfo> list(String sessionId) {
    final List<BrowserContextInfo> rows =
        _contexts.values
            .where(
              (BrowserContextInfo info) => info.ownerSessionId == sessionId,
            )
            .toList()
          ..sort(
            (BrowserContextInfo a, BrowserContextInfo b) =>
                a.createdAt.compareTo(b.createdAt),
          );
    return rows;
  }

  /// All registered keys, least-recently-used first — the order in which
  /// a full cache should give its contexts up.
  List<String> evictionOrder() {
    final List<BrowserContextInfo> rows = _contexts.values.toList()
      ..sort(
        (BrowserContextInfo a, BrowserContextInfo b) =>
            a.lastUsedAt.compareTo(b.lastUsedAt),
      );
    return <String>[for (final BrowserContextInfo info in rows) info.key];
  }

  /// Removes [key] and returns its info; null when it was not registered.
  BrowserContextInfo? unregister(String key) => _contexts.remove(key);

  int get length => _contexts.length;

  /// Test hook: forgets every registration.
  void clear() => _contexts.clear();
}
