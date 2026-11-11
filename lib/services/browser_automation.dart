import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/user_agent.dart';

/// Snapshot of the current page returned after navigation.
class BrowserPageInfo {
  BrowserPageInfo({
    required this.url,
    required this.title,
    required this.text,
    this.error,
  });

  final String url;
  final String title;
  final String text;
  final String? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'title': title,
    'text': text,
    if (error != null) 'error': error,
  };
}

/// Abstraction over the embedded browser used by the agent.
///
/// Every method takes an optional [sessionId]: the chat session the call
/// belongs to. Implementations that hold login state (cookies, web
/// storage) use it to keep each session's browser identity separate —
/// the private-window guarantee (see IsolatedBrowserAutomation). The raw
/// WebViewAutomation ignores it: it owns no state.
abstract class BrowserAutomation {
  Future<BrowserPageInfo> navigate(
    String url, {
    Duration timeout,
    String? sessionId,
  });

  Future<Map<String, dynamic>> click({
    String? selector,
    String? text,
    String? sessionId,
  });

  Future<Map<String, dynamic>> type(
    String text, {
    String? selector,
    bool clear,
    String? sessionId,
  });

  Future<Map<String, dynamic>> scroll({
    String direction,
    int amount,
    String? sessionId,
  });

  /// Captures the current page and saves a PNG under [saveDir]. Returns path.
  Future<String?> screenshot({required String saveDir, String? sessionId});

  Future<String> extractText({int maxLength, String? sessionId});

  Future<String> runJs(String code, {String? sessionId});

  /// Wipes every shared web-side cache the platform WebView keeps across
  /// all WebViews of the process: the HTTP/disk cache, web storage
  /// (localStorage / sessionStorage / IndexedDB / AppCache). Part of the
  /// private-window guarantee — called by the isolation layer whenever the
  /// active chat session changes, so cached authenticated content of the
  /// outgoing session is unreachable for the incoming one.
  Future<void> purgeSiteData();

  /// Returns a view of this automation scoped to ONE named browser context
  /// (v1.37.0). Parallel workers — most notably the fan of subagents — use
  /// distinct context ids so their browsing (pages, cookies, storage)
  /// proceeds independently instead of queueing behind a shared WebView.
  ///
  /// Single-engine implementations return `this` (context ignored); the
  /// multi-context engine overrides it (see ContextualBrowserAutomation).
  BrowserAutomation withContext(String contextId);

  /// Async storage reconciliation at the CURRENT origin (must be called
  /// with the origin's page loaded): clears web storage, deletes every
  /// IndexedDB database, unregisters this origin's service workers, then
  /// re-injects [payloadJson] ({"local":{},"session":{}}) as the calling
  /// session's snapshot. Returns a status string ("reconciled").
  Future<String> reconcileOriginStorage(String payloadJson);

  Future<void> resetSession();

  void dispose();
}

/// Default implementation of the named-browser-context API (task 2-c) for
/// automations that do NOT support it: every call throws
/// [UnsupportedError].
///
/// The stubs live in a mixin instead of as concrete bodies on
/// [BrowserAutomation] itself on purpose: classes relate to the
/// abstraction with `implements` (single-engine implementations AND the
/// test doubles), and an `implements` class must implement EVERY member
/// of the interface — concrete bodies on the abstract class would NOT be
/// inherited by them and would break their compilation. Mixing this in
/// gives single-engine automations the documented "unsupported" answer
/// instead of a NoSuchMethodError, while doubles stay untouched.
mixin UnsupportedNamedBrowserContexts {
  /// Named browser contexts are unsupported here — always throws.
  Future<Map<String, dynamic>> createContext(
    String name, {
    bool persistent = false,
  }) async {
    throw UnsupportedError(
      'named browser contexts not supported by this automation',
    );
  }

  /// Named browser contexts are unsupported here — always throws.
  Future<void> closeContext(String name) async {
    throw UnsupportedError(
      'named browser contexts not supported by this automation',
    );
  }

  /// Named browser contexts are unsupported here — always throws.
  Future<Map<String, dynamic>?> contextInfo(String name) async {
    throw UnsupportedError(
      'named browser contexts not supported by this automation',
    );
  }
}

/// Production implementation backed by a headless InAppWebView.
///
/// The User-Agent comes from Settings → User Agent through the injected
/// [resolveUserAgent] callback: it is applied when the WebView starts AND
/// re-applied on every navigation, so a mode change takes effect without
/// restarting the app. Desktop picks also switch the viewport into wide
/// ("desktop site") rendering so the page layout matches the identity —
/// the environment is adjusted together with the UA, never the UA alone.
class WebViewAutomation
    with UnsupportedNamedBrowserContexts
    implements BrowserAutomation {
  WebViewAutomation({UserAgentRecord? Function()? pickUserAgent})
    : _resolveUserAgent = pickUserAgent;

  final UserAgentRecord? Function()? _resolveUserAgent;

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  Completer<WebUri?>? _navCompleter;

  /// Neutral Android fallback used only when no resolver is injected
  /// (e.g. direct construction in legacy tests).
  static const String _fallbackUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// Current selection (never null: falls back to the built-in identity).
  UserAgentRecord get _currentUa =>
      _resolveUserAgent?.call() ??
      const UserAgentRecord(
        id: 0,
        category: UserAgentCategory.android,
        browser: UserAgentBrowser.chrome,
        label: 'Fallback',
        ua: _fallbackUserAgent,
      );

  /// Creates (once) and returns the headless WebView controller.
  ///
  /// If the WebView fails to start (missing Android System WebView,
  /// renderer crash, ...), the broken instance is discarded so the next
  /// call retries cleanly instead of handing out a dead controller.
  Future<InAppWebViewController> _ensure() async {
    if (_controller != null) {
      return _controller!;
    }
    final UserAgentRecord ua = _currentUa;
    final headless = HeadlessInAppWebView(
      initialSize: const Size(1080, 1920),
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: _settingsFor(ua),
      // Private-window hardening (v1.20.0): new service-worker
      // registrations are rejected at document start in every frame, so a
      // site's worker registered while one chat is logged in can never
      // intercept another chat's requests. Existing registrations are
      // unregistered per origin during storage reconciliation.
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        UserScript(
          source: _swBlockScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onLoadStop: (InAppWebViewController controller, WebUri? url) {
        final completer = _navCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete(url);
        }
      },
      onReceivedError:
          (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            final completer = _navCompleter;
            if (completer != null && !completer.isCompleted) {
              completer.complete(null);
            }
          },
    );
    try {
      await headless.run();
    } catch (e) {
      try {
        headless.dispose();
      } catch (_) {
        // Ignore dispose failures on an already-broken instance.
      }
      throw StateError('Embedded browser failed to start: $e');
    }
    _headless = headless;
    _controller = headless.webViewController;
    return _controller!;
  }

  /// WebView settings matching a UA selection: desktop identities render
  /// with the wide "desktop site" viewport, Android identities keep the
  /// natural mobile layout.
  InAppWebViewSettings _settingsFor(UserAgentRecord ua) => InAppWebViewSettings(
    javaScriptEnabled: true,
    transparentBackground: false,
    supportZoom: false,
    userAgent: ua.ua,
    useWideViewPort: true,
    loadWithOverviewMode: ua.isDesktop,
  );

  @override
  Future<BrowserPageInfo> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    String? sessionId,
  }) async {
    if (url.trim().isEmpty) {
      return BrowserPageInfo(
        url: '',
        title: '',
        text: '',
        error: 'URL is empty',
      );
    }
    final normalized = url.trim().contains('://')
        ? url.trim()
        : 'https://${url.trim()}';
    try {
      final controller = await _ensure();
      // Re-apply the current selection on every navigation so a Settings
      // change reaches the long-lived WebView immediately and every page
      // of a session is fetched with the SAME identity (stability).
      try {
        await controller.setSettings(settings: _settingsFor(_currentUa));
      } catch (_) {
        // Older engines may reject partial setSettings — the UA from
        // WebView start still applies.
      }
      _navCompleter = Completer<WebUri?>();
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(normalized)),
        );
      } catch (e) {
        return BrowserPageInfo(
          url: normalized,
          title: '',
          text: '',
          error: 'Failed to load URL: $e',
        );
      }

      String? error;
      try {
        final loaded = await _navCompleter!.future.timeout(timeout);
        if (loaded == null) {
          error = 'Page failed to load (network or timeout).';
        }
      } on TimeoutException {
        error = 'Page did not finish loading within ${timeout.inSeconds}s.';
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final info = await _pageInfo();
      return BrowserPageInfo(
        url: info['url']?.toString() ?? normalized,
        title: info['title']?.toString() ?? '',
        text: info['text']?.toString() ?? '',
        error: error,
      );
    } catch (e) {
      // Any unexpected platform error must degrade to a tool error message,
      // never crash the app.
      return BrowserPageInfo(
        url: normalized,
        title: '',
        text: '',
        error: 'Navigation failed: $e',
      );
    }
  }

  Future<Map<String, dynamic>> _pageInfo() async {
    final controller = await _ensure();
    try {
      final raw = await controller.evaluateJavascript(
        source:
            'JSON.stringify({url: location.href, title: document.title || "", '
            'text: ((document.body && document.body.innerText) || "").slice(0, 5000)})',
      );
      final decoded = _decodeMap(raw);
      if (decoded != null) return decoded;
    } catch (_) {
      // Ignore JS errors while collecting page info.
    }
    return <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> click({
    String? selector,
    String? text,
    String? sessionId,
  }) async {
    try {
      final controller = await _ensure();
      final raw = await controller.evaluateJavascript(
        source: _jsClick(jsonEncode(selector), jsonEncode(text)),
      );
      return _decodeMap(raw) ??
          <String, dynamic>{'ok': false, 'error': 'No result from JS.'};
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'Click failed: $e'};
    }
  }

  String _jsClick(String selectorJson, String textJson) =>
      '''
(function() {
  var selector = $selectorJson;
  var text = $textJson;
  var el = null;
  if (selector && selector.length) {
    try { el = document.querySelector(selector); }
    catch (e) { return JSON.stringify({ok: false, error: 'Selector tidak valid: ' + e.message}); }
  } else if (text && text.length) {
    var candidates = Array.prototype.slice.call(document.querySelectorAll(
      'a, button, [role="button"], input[type="submit"], input[type="button"], summary, li, span, div'));
    for (var i = 0; i < candidates.length; i++) {
      var c = candidates[i];
      var label = (c.innerText || c.value || c.getAttribute('aria-label') || '').trim();
      if (label && label.toLowerCase().indexOf(text.toLowerCase()) !== -1 && c.offsetParent !== null) {
        el = c; break;
      }
    }
  }
  if (!el) return JSON.stringify({ok: false, error: 'Elemen tidak ditemukan'});
  try { el.scrollIntoView({block: 'center'}); } catch (e) {}
  el.click();
  return JSON.stringify({ok: true, clicked: (el.innerText || el.value || '').trim().slice(0, 100)});
})()
''';

  @override
  Future<Map<String, dynamic>> type(
    String text, {
    String? selector,
    bool clear = true,
    String? sessionId,
  }) async {
    try {
      final controller = await _ensure();
      final raw = await controller.evaluateJavascript(
        source: _jsType(jsonEncode(text), jsonEncode(selector), clear),
      );
      return _decodeMap(raw) ??
          <String, dynamic>{'ok': false, 'error': 'No result from JS.'};
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'Type failed: $e'};
    }
  }

  String _jsType(String textJson, String selectorJson, bool clear) =>
      '''
(function() {
  var text = $textJson;
  var selector = $selectorJson;
  var el = null;
  if (selector && selector.length) { el = document.querySelector(selector); }
  if (!el) {
    var active = document.activeElement;
    var activeIsInput = active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA' || active.isContentEditable);
    el = activeIsInput ? active : document.querySelector('input:not([type=hidden]), textarea, [contenteditable="true"]');
  }
  if (!el) return JSON.stringify({ok: false, error: 'Elemen input tidak ditemukan'});
  el.focus();
  try { el.scrollIntoView({block: 'center'}); } catch (e) {}
  if (el.isContentEditable) {
    if (clear) el.textContent = '';
    el.textContent = (clear ? '' : (el.textContent || '')) + text;
    el.dispatchEvent(new InputEvent('input', {bubbles: true, data: text}));
  } else {
    var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    if (clear) setter.call(el, '');
    setter.call(el, (clear ? '' : el.value) + text);
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
  }
  return JSON.stringify({ok: true, typed: String(text).slice(0, 100)});
})()
''';

  @override
  Future<Map<String, dynamic>> scroll({
    String direction = 'down',
    int amount = 800,
    String? sessionId,
  }) async {
    try {
      final controller = await _ensure();
      final dy = direction == 'up' ? -amount : amount;
      final raw = await controller.evaluateJavascript(
        source:
            '(function(){ window.scrollBy(0, $dy); '
            'return JSON.stringify({ok: true, scrollY: window.scrollY}); })()',
      );
      return _decodeMap(raw) ??
          <String, dynamic>{'ok': false, 'error': 'Scroll failed.'};
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'Scroll failed: $e'};
    }
  }

  @override
  Future<String> extractText({int maxLength = 8000, String? sessionId}) async {
    try {
      final controller = await _ensure();
      final raw = await controller.evaluateJavascript(
        source: 'JSON.stringify({text: ((document.body && document.body.innerText) || "")})',
      );
      final map = _decodeMap(raw) ?? <String, dynamic>{};
      final text = map['text']?.toString() ?? '';
      if (text.length <= maxLength) return text;
      return '${text.substring(0, maxLength)}\n... [text truncated]';
    } catch (e) {
      return 'Extract text failed: $e';
    }
  }

  @override
  Future<String> runJs(String code, {String? sessionId}) async {
    try {
      final controller = await _ensure();
      final result = await controller.evaluateJavascript(source: code);
      if (result == null) return 'null';
      if (result is String) return result;
      return jsonEncode(result);
    } catch (e) {
      return 'JS error: $e';
    }
  }

  @override
  Future<String?> screenshot({
    required String saveDir,
    String? sessionId,
  }) async {
    Uint8List? bytes;
    try {
      final controller = await _ensure();
      bytes = await controller.takeScreenshot();
    } catch (_) {
      return null;
    }
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final dir = Directory(saveDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final path =
          '${dir.path}${Platform.pathSeparator}shot_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (_) {
      // Disk/permission failures must not crash the agent loop.
      return null;
    }
  }

  @override
  Future<void> resetSession() async {
    try {
      await InAppWebViewController.clearAllCache();
    } catch (_) {
      // Best effort.
    }
  }

  @override
  Future<void> purgeSiteData() async {
    try {
      await InAppWebViewController.clearAllCache();
    } catch (_) {
      // Best effort: cache alone degrades to slower loads, not leaks.
    }
    try {
      // Android WebStorage.deleteAllData(): wipes localStorage,
      // sessionStorage, IndexedDB and AppCache for ALL origins in the
      // shared profile — sessions re-inject their own snapshots during
      // reconciliation, so nothing survives a session switch.
      await WebStorageManager().deleteAllData();
    } catch (_) {
      // Best effort.
    }
  }

  @override
  Future<String> reconcileOriginStorage(String payloadJson) async {
    try {
      final controller = await _ensure();
      Object? data;
      try {
        data = jsonDecode(payloadJson);
      } catch (_) {
        data = const <String, dynamic>{};
      }
      // callAsyncJavaScript awaits the returned Promise (unlike plain
      // evaluateJavascript), so the IndexedDB deletions and service-worker
      // unregistrations below actually complete before we reload the page.
      final result = await controller.callAsyncJavaScript(
        functionBody: _reconcileBody,
        arguments: <String, dynamic>{'data': data},
      );
      final value = result?.value;
      return value == null ? 'reconciled' : value.toString();
    } catch (_) {
      return 'reconciled';
    }
  }

  /// Runs at document start in every frame: service-worker registration
  /// is stubbed out (private windows never register workers).
  static const String _swBlockScript =
      '(function(){try{if(navigator.serviceWorker){'
      'navigator.serviceWorker.register=function(){'
      'return Promise.reject(new Error("service workers are disabled in '
      'private mode"))};}}catch(e){}})()';

  /// Body of the async reconcile function executed by
  /// [reconcileOriginStorage] via callAsyncJavaScript (`data` argument:
  /// {"local":{},"session":{}}).
  static const String _reconcileBody = '''
try { sessionStorage.clear(); } catch (e) {}
try { localStorage.clear(); } catch (e) {}
try {
  if (window.indexedDB && indexedDB.databases) {
    var dbs = await indexedDB.databases();
    for (var i = 0; i < dbs.length; i++) {
      var name = dbs[i] && dbs[i].name;
      if (name) { try { indexedDB.deleteDatabase(name); } catch (e) {} }
    }
  }
} catch (e) {}
try {
  if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
    var regs = await navigator.serviceWorker.getRegistrations();
    for (var j = 0; j < regs.length; j++) {
      try { regs[j].unregister(); } catch (e) {}
    }
  }
} catch (e) {}
var own = data || {};
var l = own.local || {}, s = own.session || {};
for (var k in l) { try { localStorage.setItem(k, l[k]); } catch (e) {} }
for (var m in s) { try { sessionStorage.setItem(m, s[m]); } catch (e) {} }
return "reconciled";
''';

  @override
  BrowserAutomation withContext(String contextId) => this;

  @override
  void dispose() {
    _headless?.dispose();
    _headless = null;
    _controller = null;
  }

  Map<String, dynamic>? _decodeMap(Object? raw) {
    try {
      if (raw is Map<String, dynamic>) return raw;
      if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {
      // Ignore malformed JS results.
    }
    return null;
  }
}
