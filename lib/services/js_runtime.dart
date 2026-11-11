import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Resolves an fs-bridge path (v1.29.0). Absolute paths pass through;
/// RELATIVE paths anchor to [sandboxRoots].first — the run's working
/// directory (`state/` for module runs, the session sandbox for plain
/// runs) — instead of the Dart process CWD. `.` and `..` segments are
/// normalized lexically so a `state/../..` traversal still resolves to
/// its real location and the sandbox check can reject it.
///
/// Pure and top-level so the path contract is directly unit-testable.
String zResolveFsPath(String rawPath, List<String> sandboxRoots) {
  final bool isAbsolute =
      rawPath.startsWith(Platform.pathSeparator) ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(rawPath);
  final String base = sandboxRoots.isNotEmpty
      ? sandboxRoots.first
      : Directory.current.path;
  final String joined = isAbsolute
      ? rawPath
      : rawPath.isEmpty
      ? base
      : '$base${Platform.pathSeparator}$rawPath';
  final List<String> parts = joined.split(Platform.pathSeparator);
  final bool hasDrive =
      parts.isNotEmpty && RegExp(r'^[A-Za-z]:$').hasMatch(parts.first);
  final List<String> out = <String>[];
  for (final String part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      // Never pop past the root (or the Windows drive prefix).
      if (out.length > (hasDrive ? 1 : 0)) out.removeLast();
      continue;
    }
    out.add(part);
  }
  final String prefix = hasDrive ? '' : Platform.pathSeparator;
  return '$prefix${out.join(Platform.pathSeparator)}';
}

/// True when [path] (already normalized by [zResolveFsPath]) sits under
/// [root]: prefix match with a trailing separator, so a sibling directory
/// sharing the root's text prefix (`/state-old`) never matches, and the
/// root itself matches (writing the root dir itself is legitimate).
bool zIsUnderRoot(String path, String root) {
  final String p = path.endsWith(Platform.pathSeparator)
      ? path
      : '$path${Platform.pathSeparator}';
  final String r = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  return p.startsWith(r);
}

/// Normalizes a JavaScript source before it enters the CommonJS registry:
/// a UTF-8 BOM and a leading shebang line (`#!...`) are stripped.
///
/// Node strips both in its module loader, so scripts copied straight from
/// Node keep working. The embedded runtime evaluates sources through
/// `new Function(...)`, where the body is parsed with the function-body
/// grammar — a `#!` first line there is an "Invalid or unexpected token",
/// not a comment. Stripping happens only at byte 0, exactly like the spec
/// allows for Script/Module parse goals.
String zNormalizeJsSource(String source) {
  String src = source;
  if (src.startsWith('\uFEFF')) src = src.substring(1);
  if (src.startsWith('#!')) {
    final int nl = src.indexOf('\n');
    src = nl < 0 ? '' : src.substring(nl + 1);
  }
  return src;
}

/// Conservative ES-module-syntax detector: matches `import`/`export`
/// DECLARATIONS at line starts only (require statements, comments or
/// strings mid-line never match), so a valid CommonJS module is never
/// flagged on a false positive.
final RegExp _zEsModuleSyntax = RegExp(
  r"""^\s*(import\s+[\w*{'"]|export\s+(default\b|\{|\*|const\b|let\b|var\b|function\b|class\b|async\b))""",
  multiLine: true,
);

bool zLooksLikeEsModuleSyntax(String source) =>
    _zEsModuleSyntax.hasMatch(source);

/// Rewrites a cryptic JS-engine parse failure into an actionable hint when
/// one of the registered sources uses ES module syntax (the embedded
/// runtime loads modules with the CommonJS wrapper — `new Function(...)`
/// — where import/export is a SyntaxError). Any other error passes
/// through untouched, and the original message always stays in brackets.
String? zExplainJsError(String? raw, Iterable<String> sources) {
  if (raw == null) return raw;
  final bool parseFailure =
      raw.contains('SyntaxError') ||
      raw.contains('Invalid or unexpected token') ||
      raw.contains('Unexpected token');
  if (!parseFailure) return raw;
  for (final String source in sources) {
    if (zLooksLikeEsModuleSyntax(source)) {
      return 'The module uses ES module syntax (import/export), which the '
          'embedded runtime cannot parse — it loads CommonJS modules '
          '(require() / module.exports). Rebuild the module as a CommonJS '
          'bundle (e.g. "esbuild src/main.js --bundle --format=cjs") and '
          'reinstall it. ($raw)';
    }
  }
  return raw;
}

/// Result of one embedded-JS execution.
class JsRunResult {
  const JsRunResult({required this.output, this.error, this.result});

  /// Captured console output (console.log/warn/error) joined by newlines.
  final String output;

  /// Non-null when the script threw or timed out.
  final String? error;

  /// JSON-encoded return value of the script (may be null).
  final String? result;

  bool get ok => error == null;
}

/// An embedded JavaScript runtime the agent can use for local data
/// processing ("Node.js-style"): CommonJS `require()` over the app's
/// `node_modules` folder, a Promise-based `fs` bridge sandboxed to the app
/// documents directory, and a global `fetch` proxied through Dart.
///
/// The production implementation runs inside a hidden off-screen WebView —
/// zero extra native footprint, guaranteed single-APK. Tests provide
/// scripted test doubles.
abstract class JsRuntime {
  Future<JsRunResult> run(
    String code, {
    List<String> moduleRoots = const <String>[],
    String? workingDir,
    Duration timeout = const Duration(seconds: 20),
  });

  /// Executes one chat-module entry point inside a fresh, permission-gated
  /// context: the [ModuleInvocation.permissions] decide which `zagents` SDK
  /// capabilities exist, [ModuleInvocation.bridge] carries the Dart-side
  /// operations, and nothing survives the run.
  Future<JsRunResult> runModule(ModuleInvocation invocation);

  void dispose();
}

/// One chat-module execution request handed to [JsRuntime.runModule].
class ModuleInvocation {
  ModuleInvocation({
    required this.entrySource,
    this.moduleRoots = const <String>[],
    this.workingDir,
    this.permissions = const <String>{},
    this.info = const <String, dynamic>{},
    this.allowedHosts,
    required this.bridge,
    this.sdkSource = '',
    this.timeout = const Duration(seconds: 30),
    this.contextToken,
  });

  /// Source of the module entry point (e.g. `main.js`).
  final String entrySource;

  /// Roots used to resolve `require()` specifiers: the module directory
  /// first, then the shared npm library.
  final List<String> moduleRoots;

  /// Directory the `fs` bridge is sandboxed to (the module's per-chat
  /// state directory).
  final String? workingDir;

  /// Granted capability names (`storage`, `network`, `files`, `chat`) —
  /// the subset of the manifest permissions the user approved.
  final Set<String> permissions;

  /// Metadata exposed to the module as `zagents.info` (name, version,
  /// sessionId, ...).
  final Map<String, dynamic> info;

  /// When non-empty, `zagents.http` may only reach these hosts.
  final List<String>? allowedHosts;

  /// Dart-side capability provider; every SDK call lands here and
  /// re-checks permissions (defense in depth).
  final ModuleBridge bridge;

  /// Source of the official SDK shim — registered as the virtual module
  /// `zagents-sdk` so `require('zagents-sdk')` works in addition to the
  /// injected `zagents` global.
  final String sdkSource;

  final Duration timeout;

  /// Correlation token (v1.38.0): stamped onto every bridge request this
  /// run emits (`__zctx` field) so a shared [ModuleBridge] can route each
  /// call to the exact execution that produced it. Required now that two
  /// chats may queue module runs concurrently — the bridge can no longer
  /// assume a single live context.
  final String? contextToken;
}

/// Dart-side capability provider for one module run. The JS SDK surfaces
/// these operations as the `zagents` global (`storage`, `fs`, `http`,
/// `chat`); the implementation enforces the granted permissions, per-chat
/// storage scoping and host allowlists.
abstract class ModuleBridge {
  Future<Map<String, dynamic>?> handleOp(Map<String, dynamic> request);
}

/// Hidden-WebView implementation of [JsRuntime].
///
/// How a run works:
///  1. Dart resolves the whole module graph reachable from the user script
///     (`require('…')` scan → on-disk files under [moduleRoots]).
///  2. A registry of `{path: {src, deps}}` plus a CommonJS loader are
///     evaluated in the hidden WebView; `require` inside every module is
///     pre-wired to its resolved dependencies (circular-safe).
///  3. The script result, console output and `fs`/`fetch` traffic travel
///     through the `zagentsNode` JavaScript handler; [run] awaits the
///     final `done` frame with a timeout.
///
/// Privacy guarantee (v1.20.0): every [run] boots a FRESH WebView — the
/// CommonJS cache, `window` globals and the module registry of a previous
/// run (possibly from a different chat session, e.g. git tokens embedded
/// in pushed scripts) are destroyed, matching real Node semantics where
/// each `node script.js` starts a clean process.
class WebViewJsRuntime implements JsRuntime {
  WebViewJsRuntime({this.fetchProxy, this.resolveUserAgent});

  /// Dart-side proxy for in-script `fetch()` calls (v1.38.0: REAL network
  /// — text and binary bodies, request headers, proper status codes; see
  /// [ScriptFetchProxy]). The returned map becomes the bridge response.
  final Future<Map<String, dynamic>?> Function(
    String url,
    String method,
    String? body, {
    Map<String, String> headers,
    bool bodyIsBase64,
  })?
  fetchProxy;

  /// Resolves the User-Agent applied to the sandbox WebView so in-page
  /// `fetch()` requests carry the same identity the browser automation
  /// uses (Settings → User Agent). Kept sticky per session.
  final String? Function()? resolveUserAgent;

  HeadlessInAppWebView? _webview;
  Completer<String>? _done;
  final List<String> _console = <String>[];
  List<String> _sandboxRoots = const <String>[];

  /// While a MODULE run is in flight: the granted permission names, used
  /// to gate the `fs` bridge on the Dart side too (defense in depth — the
  /// JS SDK already hides unauthorized APIs). Null during plain node_run
  /// executions, which keep their unrestricted (workspace-sandboxed) fs
  /// semantics.
  Set<String>? _modulePermissions;
  ModuleBridge? _moduleBridge;

  /// Correlation token of the in-flight module run (v1.38.0) — stamped
  /// onto every `zapi` bridge request so the shared ModuleBridge can
  /// route ops to the exact run that produced them.
  String? _moduleContextToken;

  /// v1.43.1 — module-mode write root: the run's per-chat state dir.
  /// While a module runs, WRITE fs actions (writeFile / appendFile /
  /// mkdir / unlink) must resolve under this directory; reads keep the
  /// full sandbox-root scope (module code, npm) so `require`-adjacent
  /// reads still work. Null during plain runs, which keep their
  /// workspace-sandboxed write semantics. Closes the last theoretical
  /// cross-chat channel: the sandbox roots also contain the module's
  /// GLOBAL program directory, so without this lock two chats running
  /// the same module could exchange data through that shared folder.
  String? _writeRoot;

  /// fs actions that mutate the filesystem — gated to [_writeRoot] in
  /// module mode (v1.43.1). Read actions (readFile / readdir / stat)
  /// keep the sandbox-root scope.
  static const Set<String> _fsWriteActions = <String>{
    'writeFile',
    'appendFile',
    'mkdir',
    'unlink',
  };

  static const String _handlerName = 'zagentsNode';

  Future<void> _ensureRunning({String? bootstrap}) async {
    if (_webview != null) return;
    final Completer<void> ready = Completer<void>();
    final HeadlessInAppWebView wv = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: '<html><body></body></html>',
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        javaScriptEnabled: true,
        disableContextMenu: true,
        userAgent: resolveUserAgent?.call(),
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        controller.addJavaScriptHandler(
          handlerName: _handlerName,
          callback: _handleMessage,
        );
      },
      onLoadStop: (_, _) {
        if (!ready.isCompleted) ready.complete();
      },
    );
    _webview = wv;
    await wv.run();
    await ready.future.timeout(const Duration(seconds: 20));
    await wv.webViewController!.evaluateJavascript(
      source: bootstrap ?? _bootstrap,
    );
  }

  /// Single entry point for all frames coming from the JS side.
  Future<List<dynamic>> _handleMessage(List<dynamic> args) async {
    Map<String, dynamic>? request;
    if (args.isNotEmpty && args.first is Map) {
      request = Map<String, dynamic>.from(args.first as Map<dynamic, dynamic>);
    }
    if (request == null) return const <dynamic>[null];
    try {
      final Map<String, dynamic>? response = await _dispatch(request);
      return <dynamic>[response];
    } catch (e) {
      return <dynamic>[
        <String, dynamic>{'ok': false, 'error': '$e'},
      ];
    }
  }

  Future<Map<String, dynamic>?> _dispatch(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'log':
        _console.add(request['text']?.toString() ?? '');
        return null;
      case 'done':
        if (!(_done?.isCompleted ?? true)) {
          _done!.complete(jsonEncode(request));
        }
        return null;
      case 'zapi':
        // Module-mode runs report their final frame over the same zapi
        // channel as every other SDK call (single guaranteed-delivery
        // path); plain post() frames proved lossy under the integration
        // test binding.
        if (request['zop'] == 'done') {
          if (!(_done?.isCompleted ?? true)) {
            _done!.complete(jsonEncode(request));
          }
          return const <String, dynamic>{'ok': true};
        }
        final ModuleBridge? bridge = _moduleBridge;
        if (bridge == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'Module API is unavailable',
          };
        }
        try {
          return await bridge.handleOp(<String, dynamic>{
            ...request,
            if (_moduleContextToken != null) '__zctx': _moduleContextToken,
          });
        } catch (e) {
          return <String, dynamic>{'ok': false, 'error': '$e'};
        }
      case 'fs':
        return _fsOp(request);
      case 'fetch':
        final Future<Map<String, dynamic>?> Function(
          String,
          String,
          String?, {
          Map<String, String> headers,
          bool bodyIsBase64,
        })?
        proxy = fetchProxy;
        if (proxy == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'fetch is unavailable',
          };
        }
        final Object? rawHeaders = request['headers'];
        return proxy(
          request['url']?.toString() ?? '',
          request['method']?.toString() ?? 'GET',
          request['body']?.toString(),
          headers: rawHeaders is Map
              ? rawHeaders.map(
                  (Object? k, Object? v) =>
                      MapEntry<String, String>('$k', '$v'),
                )
              : const <String, String>{},
          bodyIsBase64: request['bodyB64'] == true,
        );
      default:
        return null;
    }
  }

  /// Sandbox the fs bridge to the app documents dir + module roots.
  bool _isSandboxed(String path) {
    if (_sandboxRoots.isEmpty) return false;
    for (final String root in _sandboxRoots) {
      if (zIsUnderRoot(path, root)) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> _fsOp(Map<String, dynamic> request) async {
    final String action = request['action']?.toString() ?? '';
    try {
      // Module runs need the explicit `files` permission for ANY fs access
      // (the JS SDK hides zagents.fs without it; this is the Dart-side
      // backstop).
      final Set<String>? modulePerms = _modulePermissions;
      if (modulePerms != null && !modulePerms.contains('files')) {
        return <String, dynamic>{
          'ok': false,
          'error': 'Permission denied: files',
        };
      }
      final String rawPath = request['path']?.toString() ?? '';
      // v1.29.0 fix: relative paths are anchored to the run's working
      // directory (the FIRST sandbox root) instead of the Dart process
      // CWD — before this fix the documented `zagents.fs.writeFile(
      // 'data.json', …)` usage was ALWAYS rejected by the sandbox check
      // (`/data.json` is outside every sandbox root).
      final String resolved = zResolveFsPath(rawPath, _sandboxRoots);
      if (!_isSandboxed(resolved)) {
        return <String, dynamic>{
          'ok': false,
          'error': 'fs path is outside the app sandbox',
        };
      }
      // v1.43.1 (module mode): write actions are locked to the run's
      // per-chat state dir. The sandbox roots also include the module's
      // GLOBAL program directory and the npm root — without this lock
      // two chats running the same module could exchange data through
      // those shared folders. Reads are unaffected.
      if (modulePerms != null && _fsWriteActions.contains(action)) {
        final String? writeRoot = _writeRoot;
        if (writeRoot == null || !zIsUnderRoot(resolved, writeRoot)) {
          return <String, dynamic>{
            'ok': false,
            'error': 'fs write is confined to this chat\'s module state dir',
          };
        }
      }
      switch (action) {
        case 'readFile':
          return <String, dynamic>{
            'ok': true,
            'data': await File(resolved).readAsString(),
          };
        case 'writeFile':
          await File(resolved).parent.create(recursive: true);
          await File(resolved).writeAsString(request['data']?.toString() ?? '');
          return const <String, dynamic>{'ok': true};
        case 'appendFile':
          await File(resolved).parent.create(recursive: true);
          await File(resolved).writeAsString(
            request['data']?.toString() ?? '',
            mode: FileMode.append,
          );
          return const <String, dynamic>{'ok': true};
        case 'readdir':
          final List<FileSystemEntity> entities = await Directory(resolved)
              .list()
              .toList();
          return <String, dynamic>{
            'ok': true,
            'data': <String>[
              for (final FileSystemEntity e in entities)
                e.path.split(Platform.pathSeparator).last,
            ],
          };
        case 'mkdir':
          await Directory(resolved).create(recursive: true);
          return const <String, dynamic>{'ok': true};
        case 'unlink':
          final FileSystemEntity entity =
              FileSystemEntity.typeSync(resolved) ==
                  FileSystemEntityType.directory
              ? Directory(resolved)
              : File(resolved);
          await entity.delete(recursive: true);
          return const <String, dynamic>{'ok': true};
        case 'stat':
          final FileSystemEntity entity =
              FileSystemEntity.typeSync(resolved) ==
                  FileSystemEntityType.directory
              ? Directory(resolved)
              : File(resolved);
          final FileStat stat = await entity.stat();
          return <String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'isDirectory': stat.type == FileSystemEntityType.directory,
              'size': stat.size,
              'modified': stat.modified.toIso8601String(),
            },
          };
        default:
          return <String, dynamic>{'ok': false, 'error': 'Unknown fs action'};
      }
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  /// Shared CommonJS core: message bridge, `fs` shim, module loader and
  /// console capture — used by BOTH plain runs and module runs.
  static String get _coreJs =>
      '''
  function post(msg){ try { return window.flutter_inappwebview.callHandler('$_handlerName', msg); } catch(e){ return Promise.resolve(null); } }
  function fmt(v){
    if (v === undefined) return 'undefined';
    if (v === null) return 'null';
    if (typeof v === 'string') return v;
    try { return JSON.stringify(v); } catch(e) { return String(v); }
  }
  var cache = {};
  var fsShim = {
    readFile: function(p){ return post2({op:'fs', action:'readFile', path:p}); },
    writeFile: function(p,d){ return post2({op:'fs', action:'writeFile', path:p, data:String(d)}); },
    appendFile: function(p,d){ return post2({op:'fs', action:'appendFile', path:p, data:String(d)}); },
    readdir: function(p){ return post2({op:'fs', action:'readdir', path:p}); },
    mkdir: function(p){ return post2({op:'fs', action:'mkdir', path:p}); },
    unlink: function(p){ return post2({op:'fs', action:'unlink', path:p}); },
    stat: function(p){ return post2({op:'fs', action:'stat', path:p}); }
  };
  function post2(msg){
    return window.flutter_inappwebview.callHandler('$_handlerName', msg).then(function(res){
      if (res && res.ok === false) throw new Error(res.error || 'fs error');
      return res ? res.data : null;
    });
  }
  function exec(path){
    if (cache[path] !== undefined) return cache[path].exports;
    var entry = window.__zRegistry[path];
    if (entry === undefined) throw new Error("Cannot find module '" + path + "'");
    var module = { exports: {} };
    cache[path] = module;
    var localRequire = function(spec){
      if (spec === 'fs') return fsShim;
      var resolved = entry.deps[spec];
      if (!resolved) throw new Error("Cannot find module '" + spec + "'. Install it with the node_install tool (Settings > Node.js runtime).");
      return exec(resolved);
    };
    var fn = new Function('module','exports','require','__filename','__dirname', entry.src);
    fn(module, module.exports, localRequire, path, path.substring(0, path.lastIndexOf('/')) || '.');
    return module.exports;
  }
  window.console = {
    log: function(){ return post({op:'log', text: Array.prototype.map.call(arguments, fmt).join(' ')}); },
    info: function(){ return post({op:'log', text: Array.prototype.map.call(arguments, fmt).join(' ')}); },
    warn: function(){ return post({op:'log', text: 'WARN ' + Array.prototype.map.call(arguments, fmt).join(' ')}); },
    error: function(){ return post({op:'log', text: 'ERROR ' + Array.prototype.map.call(arguments, fmt).join(' ')}); }
  };
  window.__zRun = function(entryPath){
    return (async function(){ return exec(entryPath); })().then(
      async function(v){ await post({op:'done', ok:true, result: fmt(v)}); },
      async function(e){ await post({op:'done', ok:false, error: (e && e.message) ? e.message : String(e)}); }
    );
  };
''';

  /// Plain-run bootstrap (node_run): adds the proxied global `fetch`.
  static final String _bootstrap =
      '''
window.__zDone = false;
(function(){
  \$_core
  function zB64ToBuf(b64){
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes.buffer;
  }
  function zBufToB64(buf){
    var bytes = new Uint8Array(buf);
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
  }
  window.fetch = function(url, opts){
    opts = opts || {};
    var rawBody = opts.body;
    var isStringBody = typeof rawBody === 'string';
    return post2({
      op:'fetch', url: String(url),
      method: opts.method || 'GET',
      body: rawBody == null ? null : (isStringBody ? rawBody : zBufToB64(rawBody.buffer ? rawBody.buffer : rawBody)),
      bodyB64: rawBody != null && !isStringBody,
      headers: opts.headers || {}
    }).then(function(res){
      if (!res || typeof res.status !== 'number') {
        throw new Error((res && res.error) ? res.error : 'fetch proxy failed');
      }
      var bodyText = res.body != null ? String(res.body) : '';
      return {
        ok: res.status >= 200 && res.status < 300,
        status: res.status,
        statusText: res.statusText || '',
        headers: res.headers || {},
        text: function(){ return Promise.resolve(bodyText); },
        json: function(){ return Promise.resolve(JSON.parse(bodyText)); },
        arrayBuffer: function(){ return Promise.resolve(res.bodyBase64 ? zB64ToBuf(res.bodyBase64) : new ArrayBuffer(0)); }
      };
    });
  };
})();
'''
          .replaceAll(r'$_core', _coreJs);

  /// Module-run bootstrap: NO global fetch (network goes through the
  /// permission-gated `zagents.http`) plus the official `zagents` SDK
  /// object. Every SDK capability checks `window.__zPerms` on the JS side;
  /// the Dart bridge re-checks on every call.
  static final String _moduleBootstrap =
      '''
window.__zDone = false;
(function(){
  \$_core
  function zHas(p){ return Object.prototype.hasOwnProperty.call(window.__zPermsMap, p); }
  function zDeny(p){ throw new Error('Permission denied: ' + p); }
  function zCall(op, payload){
    var msg = { op:'zapi', zop: op };
    for (var k in payload) { msg[k] = payload[k]; }
    return window.flutter_inappwebview.callHandler('$_handlerName', msg).then(function(res){
      if (res && res.ok === false) throw new Error(res.error || 'module API error');
      return res ? res.data : null;
    });
  }
  // Module runs deliver their completion frame + logs over the zapi
  // channel (awaited, guaranteed) instead of the fire-and-forget post().
  window.__zRun = function(entryPath){
    return (async function(){ return exec(entryPath); })().then(
      async function(v){ await zCall('done', { ok: true, result: fmt(v) }); },
      async function(e){ await zCall('done', { ok: false, error: (e && e.message) ? e.message : String(e) }); }
    );
  };
  window.zagents = {
    // LIVE reference: the runner injects window.__zInfo AFTER this
    // bootstrap evaluated (the module bootstrap runs once per WebView,
    // the per-run info arrives with the runner script). A plain
    // `info: window.__zInfo` would copy `undefined` forever — a getter
    // resolves at access time, so zagents.info always reflects the
    // CURRENT run (name, sessionId, prompt, userAgent, setup values).
    get info() { return window.__zInfo; },
    log: function(){
      return zCall('log', { text: Array.prototype.map.call(arguments, fmt).join(' ') });
    },
    chat: {
      emit: function(text){
        if (!zHas('chat')) return zDeny('chat');
        return zCall('chat.emit', { text: String(text) });
      }
    },
    http: {
      request: function(url, opts){
        if (!zHas('network')) return zDeny('network');
        opts = opts || {};
        return zCall('http.request', {
          url: String(url),
          method: opts.method || 'GET',
          body: (opts.body === undefined || opts.body === null) ? null : String(opts.body),
          headers: opts.headers || {},
          timeoutMs: typeof opts.timeoutMs === 'number' ? opts.timeoutMs : null,
          headOnly: opts.headOnly === true
        }).then(function(data){
          var body = data ? data.body : null;
          var status = data && data.status ? data.status : 200;
          return {
            ok: status >= 200 && status < 300,
            status: status,
            body: body,
            headers: (data && data.headers) || {},
            text: function(){ return Promise.resolve(typeof body === 'string' ? body : JSON.stringify(body)); },
            json: function(){ return Promise.resolve(typeof body === 'string' ? JSON.parse(body) : body); }
          };
        });
      }
    },
    agent: {
      compose: function(opts){
        if (!zHas('agent')) return zDeny('agent');
        opts = opts || {};
        return zCall('agent.compose', {
          task: (opts.task === undefined || opts.task === null) ? '' : String(opts.task),
          context: (opts.context === undefined || opts.context === null) ? '' : String(opts.context),
          instruction: (opts.instruction === undefined || opts.instruction === null) ? '' : String(opts.instruction),
          maxWords: typeof opts.maxWords === 'number' ? opts.maxWords : null,
          avoid: Array.isArray(opts.avoid) ? opts.avoid.map(String) : [],
          trailingPeriod: opts.trailingPeriod === true
        }).then(function(data){
          return { text: (data && data.text) ? data.text : '' };
        });
      },
      // v1.45.0 — reply polisher: turns a slot-filled template into one
      // natural multi-sentence social reply that answers the incoming
      // message (Facebook comment/Messenger, X/Twitter mention). Freer
      // than compose: normal punctuation allowed, language matched to
      // the incoming message, char budget instead of a word budget.
      polish: function(opts){
        if (!zHas('agent')) return zDeny('agent');
        opts = opts || {};
        return zCall('agent.polish', {
          template: (opts.template === undefined || opts.template === null) ? '' : String(opts.template),
          context: (opts.context === undefined || opts.context === null) ? '' : String(opts.context),
          language: (opts.language === undefined || opts.language === null) ? '' : String(opts.language),
          tone: (opts.tone === undefined || opts.tone === null) ? '' : String(opts.tone),
          maxChars: typeof opts.maxChars === 'number' ? opts.maxChars : null,
          allowEmoji: opts.allowEmoji === true,
          avoid: Array.isArray(opts.avoid) ? opts.avoid.map(String) : []
        }).then(function(data){
          return { text: (data && data.text) ? data.text : '' };
        });
      }
    },
    storage: {
      get: function(k){ if (!zHas('storage')) return zDeny('storage'); return zCall('storage.get', { key: String(k) }); },
      set: function(k, v){ if (!zHas('storage')) return zDeny('storage'); return zCall('storage.set', { key: String(k), value: (v === undefined) ? null : v }); },
      keys: function(){ if (!zHas('storage')) return zDeny('storage'); return zCall('storage.keys', {}); },
      remove: function(k){ if (!zHas('storage')) return zDeny('storage'); return zCall('storage.remove', { key: String(k) }); }
    },
    fs: {
      readFile: function(p){ if (!zHas('files')) return zDeny('files'); return post2({op:'fs', action:'readFile', path:p}); },
      writeFile: function(p, d){ if (!zHas('files')) return zDeny('files'); return post2({op:'fs', action:'writeFile', path:p, data:String(d)}); },
      appendFile: function(p, d){ if (!zHas('files')) return zDeny('files'); return post2({op:'fs', action:'appendFile', path:p, data:String(d)}); },
      readdir: function(p){ if (!zHas('files')) return zDeny('files'); return post2({op:'fs', action:'readdir', path:p}); },
      mkdir: function(p){ if (!zHas('files')) return zDeny('files'); return post2({op:'fs', action:'mkdir', path:p}); },
      unlink: function(p){ if (!zHas('files')) return zDeny('files'); return post2({op:'fs', action:'unlink', path:p}); },
      stat: function(p){ if (!zHas('files')) return zDeny('files'); return post2({op:'fs', action:'stat', path:p}); }
    },
    device: {
      // v1.31.0 — permission `device` + the Settings → Modules master
      // switch (the Dart bridge re-checks both on every call). Runs one
      // shell command; root:true routes through `su -c` (rooted phones).
      shell: function(cmd, opts){
        if (!zHas('device')) return zDeny('device');
        opts = opts || {};
        return zCall('device.shell', {
          command: String(cmd),
          root: opts.root === true,
          timeoutMs: typeof opts.timeoutMs === 'number' ? opts.timeoutMs : null
        }).then(function(data){
          return {
            exitCode: (data && typeof data.exitCode === 'number') ? data.exitCode : -1,
            stdout: (data && data.stdout) ? data.stdout : '',
            stderr: (data && data.stderr) ? data.stderr : '',
            timedOut: !!(data && data.timedOut),
            error: (data && data.error) ? data.error : null,
            ok: !!(data && !data.error && !data.timedOut && data.exitCode === 0)
          };
        });
      },
      // v1.32.0 — read-only airplane-mode state WITHOUT root and WITHOUT
      // the master switch (a world-readable setting). available:false on
      // platforms that cannot answer lets modules pick manual fallbacks.
      airplane: function(){
        if (!zHas('device')) return zDeny('device');
        return zCall('device.airplane', {}).then(function(data){
          return {
            available: !!(data && data.available),
            on: !!(data && data.on)
          };
        });
      },
      // v1.34.0 — ONE-command airplane-mode cycle that rotates the carrier
      // IP: the data IP changes when the radio RE-REGISTERS (airplane back
      // OFF), so the bridge ensures ON (radio deregisters) → holds → OFF
      // (re-register, carrier assigns a new IP) → settle. The cycle ALWAYS
      // ends with airplane OFF (online). Root + master switch, verified
      // steps; errors reject with the actionable bridge message.
      airplaneCycle: function(opts){
        if (!zHas('device')) return zDeny('device');
        opts = opts || {};
        return zCall('device.airplaneCycle', {
          holdMs: typeof (opts && opts.holdMs) === 'number' ? opts.holdMs : null,
          settleMs: typeof (opts && opts.settleMs) === 'number' ? opts.settleMs : null
        }).then(function(data){
          return {
            wasOn: !!(data && data.wasOn),
            finalOn: !!(data && data.finalOn),
            heldMs: (data && typeof data.heldMs === 'number') ? data.heldMs : 0,
            settleMs: (data && typeof data.settleMs === 'number') ? data.settleMs : 0,
            verified: !!(data && data.verified)
          };
        });
      }
    }
  };
})();
'''
          .replaceAll(r'$_core', _coreJs);

  /// Builds the module registry reachable from [code].
  Map<String, Map<String, dynamic>> _buildRegistry(
    String code,
    List<String> moduleRoots,
  ) {
    final Map<String, Map<String, dynamic>> registry =
        <String, Map<String, dynamic>>{};
    final String userEntry = '__user__.js';
    final String normalized = zNormalizeJsSource(code);
    final Map<String, String> userDeps = <String, String>{};
    for (final String spec in _extractRequires(normalized)) {
      final String? resolved = _resolveSpec(spec, moduleRoots);
      if (resolved != null) userDeps[spec] = resolved;
    }
    registry[userEntry] = <String, dynamic>{
      'src': normalized,
      'deps': userDeps,
    };

    final Queue<String> pending = Queue<String>.of(userDeps.values);
    final Set<String> seen = <String>{...userDeps.values};
    while (pending.isNotEmpty) {
      final String path = pending.removeFirst();
      String source;
      try {
        source = zNormalizeJsSource(File(path).readAsStringSync());
      } catch (_) {
        continue;
      }
      final String dir = path.contains(Platform.pathSeparator)
          ? path.substring(0, path.lastIndexOf(Platform.pathSeparator))
          : '.';
      final Map<String, String> deps = <String, String>{};
      for (final String spec in _extractRequires(source)) {
        String? resolved;
        if (spec.startsWith('./') || spec.startsWith('../')) {
          resolved = _resolveRelative(dir, spec);
        } else if (spec != 'fs') {
          resolved = _resolveSpec(spec, moduleRoots);
        }
        if (resolved != null) {
          deps[spec] = resolved;
          if (!seen.contains(resolved)) {
            seen.add(resolved);
            pending.add(resolved);
          }
        }
      }
      registry[path] = <String, dynamic>{'src': source, 'deps': deps};
    }
    return registry;
  }

  static final RegExp _requireRegex = RegExp(
    r'''require\s*\(\s*['"]([^'"]+)['"]\s*\)''',
  );

  static List<String> _extractRequires(String source) => <String>[
    for (final Match match in _requireRegex.allMatches(source))
      if ((match.group(1) ?? '').isNotEmpty) match.group(1)!,
  ];

  /// Resolves a bare specifier (pkg, pkg/sub, @scope/pkg[/sub]) to a file
  /// under one of [moduleRoots], honoring package.json "main".
  String? _resolveSpec(String spec, List<String> moduleRoots) {
    String pkg = spec;
    if (spec.startsWith('@')) {
      final List<String> parts = spec.split('/');
      pkg = parts.length >= 2 ? '${parts[0]}/${parts[1]}' : spec;
    } else {
      pkg = spec.split('/').first;
    }
    final String subPath = spec.contains('/')
        ? spec.substring(spec.indexOf('/') + 1)
        : '';
    for (final String root in moduleRoots) {
      final String base =
          '$root${Platform.pathSeparator}$pkg${Platform.pathSeparator}';
      final File pkgJson = File('${base}package.json');
      String main = 'index.js';
      if (pkgJson.existsSync()) {
        try {
          final Object? meta = jsonDecode(pkgJson.readAsStringSync());
          if (meta is Map) {
            final Object? mainField = meta['main'];
            if (mainField is String && mainField.isNotEmpty) main = mainField;
          }
        } catch (_) {}
      }
      final List<String> candidates = <String>[
        if (subPath.isNotEmpty) ...<String>[
          base + subPath,
          '$base$subPath.js',
          '$base$subPath${Platform.pathSeparator}index.js',
        ],
        base + main,
        '${base}index.js',
      ];
      for (final String candidate in candidates) {
        if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.file) {
          return candidate;
        }
      }
    }
    return null;
  }

  /// Resolves './x' / '../x' relative to [fromDir].
  String? _resolveRelative(String fromDir, String spec) {
    final List<String> segments = fromDir.split(Platform.pathSeparator);
    for (final String part in spec.split('/')) {
      if (part == '.' || part.isEmpty) continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else {
        segments.add(part);
      }
    }
    final String base = segments.join(Platform.pathSeparator);
    for (final String candidate in <String>[
      base,
      '$base.js',
      '$base${Platform.pathSeparator}index.js',
    ]) {
      if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.file) {
        return candidate;
      }
    }
    return null;
  }

  @override
  Future<JsRunResult> run(
    String code, {
    List<String> moduleRoots = const <String>[],
    String? workingDir,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    // Fresh context per run (v1.20.0): dispose whatever WebView exists —
    // its JS heap holds the previous run's module cache, window globals
    // and __zRegistry (which contains literal script sources, including
    // any credentials embedded there) — then boot a clean one.
    try {
      await _recycle();
      await _ensureRunning();
    } catch (e) {
      return JsRunResult(output: '', error: 'JS runtime failed to start: $e');
    }
    _console.clear();
    _sandboxRoots = <String>[?workingDir, ...moduleRoots];
    // Plain runs are NOT module runs — drop any module-mode state a
    // previous module run left on this shared runtime instance, or this
    // run's fs bridge would be wrongly permission-gated and its bridge
    // ops stamped with a dead context token.
    _modulePermissions = null;
    _moduleBridge = null;
    _moduleContextToken = null;
    _writeRoot = null;
    final Map<String, Map<String, dynamic>> registry = _buildRegistry(
      code,
      moduleRoots,
    );
    _done = Completer<String>();

    final String runner =
        '''
(function(){
  window.__zRegistry = ${jsonEncode(registry)};
  __zRun('__user__.js');
})();
''';

    String? raw;
    try {
      _webview!.webViewController!.evaluateJavascript(source: runner);
      raw = await _done!.future.timeout(timeout);
    } on TimeoutException {
      await _recycle();
      return JsRunResult(
        output: _console.join('\n'),
        error: 'Script timed out after ${timeout.inSeconds}s.',
      );
    } catch (e) {
      await _recycle();
      return JsRunResult(output: _console.join('\n'), error: '$e');
    }

    try {
      final Object? payload = jsonDecode(raw);
      if (payload is Map<String, dynamic>) {
        return JsRunResult(
          output: _console.join('\n'),
          error: payload['ok'] == true
              ? null
              : zExplainJsError(
                  payload['error']?.toString(),
                  registry.values.map(
                    (Map<String, dynamic> e) => e['src']?.toString() ?? '',
                  ),
                ),
          result: payload['result']?.toString(),
        );
      }
    } catch (_) {}
    return JsRunResult(
      output: _console.join('\n'),
      error: 'JS runtime returned an unreadable result.',
    );
  }

  /// Module runs boot the same fresh-WebView pipeline as [run] but swap
  /// in the module bootstrap (permission-gated `zagents` SDK, no global
  /// fetch) and register the SDK shim as a require-able virtual module.
  @override
  Future<JsRunResult> runModule(ModuleInvocation invocation) async {
    try {
      await _recycle();
      await _ensureRunning(bootstrap: _moduleBootstrap);
    } catch (e) {
      return JsRunResult(output: '', error: 'JS runtime failed to start: $e');
    }
    _console.clear();
    _modulePermissions = invocation.permissions;
    _moduleBridge = invocation.bridge;
    _moduleContextToken = invocation.contextToken;
    _sandboxRoots = <String>[?invocation.workingDir, ...invocation.moduleRoots];
    // v1.43.1: writes lock to the per-chat state dir (workingDir) — the
    // global module program dir and the npm root stay READ-only for
    // modules, so nothing a module persists can outlive or leave the
    // chat that produced it.
    _writeRoot = invocation.workingDir;
    final Map<String, Map<String, dynamic>> registry = _buildRegistry(
      invocation.entrySource,
      invocation.moduleRoots,
    );
    // Register the official SDK shim so `require('zagents-sdk')` works
    // next to the injected `zagents` global.
    if (invocation.sdkSource.trim().isNotEmpty) {
      registry['zagents-sdk.js'] = <String, dynamic>{
        'src': zNormalizeJsSource(invocation.sdkSource),
        'deps': const <String, String>{},
      };
      final Map<String, dynamic> entry = registry['__user__.js']!;
      (entry['deps'] as Map<String, dynamic>)['zagents-sdk'] = 'zagents-sdk.js';
    }
    _done = Completer<String>();

    final String runner =
        '''
(function(){
  window.__zRegistry = ${jsonEncode(registry)};
  window.__zPermsMap = {};
  ${jsonEncode(invocation.permissions.toList())}.forEach(function(p){ window.__zPermsMap[p] = true; });
  window.__zInfo = ${jsonEncode(invocation.info)};
  __zRun('__user__.js');
})();
''';

    String? raw;
    try {
      _webview!.webViewController!.evaluateJavascript(source: runner);
      raw = await _done!.future.timeout(invocation.timeout);
    } on TimeoutException {
      await _recycle();
      return JsRunResult(
        output: _console.join('\n'),
        error: 'Module timed out after ${invocation.timeout.inSeconds}s.',
      );
    } catch (e) {
      await _recycle();
      return JsRunResult(output: _console.join('\n'), error: '$e');
    } finally {
      _modulePermissions = null;
      _moduleBridge = null;
      _moduleContextToken = null;
    }

    try {
      final Object? payload = jsonDecode(raw);
      if (payload is Map<String, dynamic>) {
        return JsRunResult(
          output: _console.join('\n'),
          error: payload['ok'] == true
              ? null
              : zExplainJsError(
                  payload['error']?.toString(),
                  registry.values.map(
                    (Map<String, dynamic> e) => e['src']?.toString() ?? '',
                  ),
                ),
          result: payload['result']?.toString(),
        );
      }
    } catch (_) {}
    return JsRunResult(
      output: _console.join('\n'),
      error: 'JS runtime returned an unreadable result.',
    );
  }

  Future<void> _recycle() async {
    try {
      await _webview?.dispose();
    } catch (_) {}
    _webview = null;
  }

  @override
  void dispose() {
    _recycle();
  }
}

/// Serializes executions through an inner [JsRuntime] so parallel calls
/// (node_run from multiple chat sessions running at once) never interleave
/// inside one hidden WebView: each run completes before the next starts,
/// and a failing run never poisons the queue.
///
/// Combined with [WebViewJsRuntime]'s fresh-context-per-run this is the
/// cross-chat privacy guarantee for the embedded Node.js runtime.
class SerializedJsRuntime implements JsRuntime {
  SerializedJsRuntime(this._inner);

  final JsRuntime _inner;

  Future<void> _tail = Future<void>.value();

  @override
  Future<JsRunResult> run(
    String code, {
    List<String> moduleRoots = const <String>[],
    String? workingDir,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final Future<JsRunResult> run = _tail.then(
      (_) => _inner.run(
        code,
        moduleRoots: moduleRoots,
        workingDir: workingDir,
        timeout: timeout,
      ),
    );
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<JsRunResult> runModule(ModuleInvocation invocation) {
    final Future<JsRunResult> run = _tail.then(
      (_) => _inner.runModule(invocation),
    );
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  void dispose() => _inner.dispose();
}
