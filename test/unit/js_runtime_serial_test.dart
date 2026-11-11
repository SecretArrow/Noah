import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/js_runtime.dart';

/// Inner runtime whose runs take a controllable amount of time and record
/// their lifecycle, so tests can prove parallel calls execute one after
/// another (never interleaved inside one hidden WebView).
class _SlowScriptedRuntime implements JsRuntime {
  final List<String> events = <String>[];
  final List<Completer<void>> gates = <Completer<void>>[];

  /// Resolves when the run at [index] may finish. Waits (event-loop)
  /// until that run has actually started — callers may release before the
  /// serialized wrapper got a chance to invoke the inner runtime.
  Future<void> release(int index) async {
    while (gates.length <= index) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    gates[index].complete();
  }

  @override
  Future<JsRunResult> run(
    String code, {
    List<String> moduleRoots = const <String>[],
    String? workingDir,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Completer<void> gate = Completer<void>();
    gates.add(gate);
    events.add('start:$code');
    await gate.future;
    events.add('end:$code');
    if (code == 'explode') {
      throw StateError('boom');
    }
    return JsRunResult(output: code, result: '"$code"');
  }

  @override
  Future<JsRunResult> runModule(ModuleInvocation invocation) async =>
      JsRunResult(output: invocation.entrySource);

  @override
  void dispose() => events.add('dispose');
}

void main() {
  group('SerializedJsRuntime', () {
    test('runs submitted in parallel execute strictly one at a time', () async {
      final inner = _SlowScriptedRuntime();
      final runtime = SerializedJsRuntime(inner);

      // Two chat sessions fire node_run at the same moment.
      final f1 = runtime.run('first');
      final f2 = runtime.run('second');

      // Neither may finish until its gate opens; the second must not have
      // STARTED before the first ends (no interleaving in one WebView).
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(inner.events, <String>['start:first']);

      await inner.release(0);
      await f1;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(inner.events, <String>[
        'start:first',
        'end:first',
        'start:second',
      ]);

      await inner.release(1);
      final r2 = await f2;
      expect(inner.events.last, 'end:second');
      expect(r2.result, '"second"');
    });

    test('a failing run does not poison the queue', () async {
      final inner = _SlowScriptedRuntime();
      final runtime = SerializedJsRuntime(inner);

      final f1 = runtime.run('explode');
      final f2 = runtime.run('after');
      await inner.release(0);
      await expectLater(f1, throwsA(isA<StateError>()));

      await inner.release(1);
      final r2 = await f2;
      expect(r2.output, 'after');
      expect(inner.events, contains('start:after'));
    });

    test('results and errors from the inner runtime pass through', () async {
      final inner = _SlowScriptedRuntime();
      final runtime = SerializedJsRuntime(inner);

      final f1 = runtime.run('ok');
      await inner.release(0);
      final ok = await f1;
      expect(ok.ok, isTrue);
      expect(ok.output, 'ok');

      final f2 = runtime.run('explode');
      await inner.release(1);
      final bad = await f2.catchError((Object e) {
        return JsRunResult(output: '', error: '$e');
      });
      expect(bad.error, isNotNull);
    });

    test('dispose forwards to the inner runtime', () async {
      final inner = _SlowScriptedRuntime();
      final runtime = SerializedJsRuntime(inner);
      runtime.dispose();
      expect(inner.events, <String>['dispose']);
    });
  });

  group('zNormalizeJsSource — BOM + shebang before new Function', () {
    test('plain source passes through untouched', () {
      const String src = 'const x = 1;\nmodule.exports = x;\n';
      expect(zNormalizeJsSource(src), src);
    });

    test('leading shebang line is stripped (Node loader parity)', () {
      const String src = '#!/usr/bin/env node\nconst x = 1;\n';
      expect(zNormalizeJsSource(src), 'const x = 1;\n');
    });

    test('shebang with CRLF endings is stripped', () {
      const String src = '#!/usr/bin/env node\r\nconst x = 1;\n';
      expect(zNormalizeJsSource(src), 'const x = 1;\n');
    });

    test('shebang-only source collapses to empty', () {
      expect(zNormalizeJsSource('#!/usr/bin/env node'), '');
    });

    test('UTF-8 BOM is stripped before the shebang check', () {
      const String src = '\uFEFF#!/usr/bin/env node\nconst x = 1;\n';
      expect(zNormalizeJsSource(src), 'const x = 1;\n');
      expect(zNormalizeJsSource('\uFEFFconst x = 1;\n'), 'const x = 1;\n');
    });

    test('a hash mid-file is NOT touched (only byte 0 counts)', () {
      const String src = 'const color = 1;\n// #not-a-shebang\n';
      expect(zNormalizeJsSource(src), src);
    });
  });

  group('zLooksLikeEsModuleSyntax — conservative line-start detection', () {
    test('import declarations are flagged', () {
      expect(zLooksLikeEsModuleSyntax("import fs from 'fs';\n"), isTrue);
      expect(zLooksLikeEsModuleSyntax("import { x } from 'y';\n"), isTrue);
      expect(zLooksLikeEsModuleSyntax("import * as z from 'z';\n"), isTrue);
      expect(zLooksLikeEsModuleSyntax('\n  import x from "y";\n'), isTrue);
    });

    test('export declarations are flagged', () {
      expect(zLooksLikeEsModuleSyntax('export default 1;\n'), isTrue);
      expect(zLooksLikeEsModuleSyntax('export const a = 1;\n'), isTrue);
      expect(zLooksLikeEsModuleSyntax('export function f() {}\n'), isTrue);
      expect(zLooksLikeEsModuleSyntax('export { a, b };\n'), isTrue);
      expect(zLooksLikeEsModuleSyntax('export * from "m";\n'), isTrue);
    });

    test('CommonJS modules are NEVER flagged (no false positives)', () {
      expect(zLooksLikeEsModuleSyntax('const fs = require("fs");\n'), isFalse);
      expect(zLooksLikeEsModuleSyntax('module.exports = { run };\n'), isFalse);
      // "import"/"export" mid-line or in comments/strings do not match.
      expect(
        zLooksLikeEsModuleSyntax('// import x from "y";\nconst a = 1;\n'),
        isFalse,
      );
      expect(
        zLooksLikeEsModuleSyntax("const msg = 'please import the file';\n"),
        isFalse,
      );
      expect(zLooksLikeEsModuleSyntax('exports.export = 1;\n'), isFalse);
    });
  });

  group('zExplainJsError — parse failures become actionable', () {
    test('non-parse errors pass through untouched', () {
      expect(
        zExplainJsError("Cannot find module 'x'", const <String>[]),
        "Cannot find module 'x'",
      );
      expect(zExplainJsError(null, const <String>[]), isNull);
    });

    test('SyntaxError + ES syntax source → CommonJS rebuild hint', () {
      const String raw = "SyntaxError: Unexpected identifier 'fs'";
      final String? explained = zExplainJsError(raw, const <String>[
        "import fs from 'fs';\nmodule.exports = fs;\n",
      ]);
      expect(explained, contains('ES module syntax'));
      expect(explained, contains('--format=cjs'));
      expect(explained, contains(raw));
    });

    test('the raw "Invalid or unexpected token" form is matched too', () {
      expect(
        zExplainJsError('Invalid or unexpected token', const <String>[
          'export default 1;\n',
        ]),
        contains('ES module syntax'),
      );
    });

    test('SyntaxError WITHOUT ES syntax passes through', () {
      const String raw = 'SyntaxError: Unexpected token ';
      expect(zExplainJsError(raw, const <String>['const x = ;\n']), raw);
    });
  });
}
