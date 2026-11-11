import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noah/services/device_shell.dart';
import 'package:noah/services/file_system_service.dart';
import 'package:archive/archive.dart';
import 'package:noah/services/js_runtime.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/services/module_runtime.dart';
import 'package:noah/services/session_sandbox.dart';
import 'package:noah/services/npm_service.dart';
import 'package:noah/services/tool_executor.dart';
import 'package:noah/services/web_fetcher.dart';

import '../support/test_doubles.dart';

/// Builds a module zip file on disk.
File writeModuleZip(String path, Map<String, String> files) {
  final Archive archive = Archive();
  files.forEach((String name, String content) {
    final List<int> bytes = content.codeUnits;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return File(path)..writeAsBytesSync(ZipEncoder().encode(archive));
}

void main() {
  late Directory tempDir;
  late ScriptedBrowserAutomation scriptedBrowser;
  late ToolExecutor executor;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_exec_test');
    scriptedBrowser = ScriptedBrowserAutomation(tempDir.path);
    executor = ToolExecutor(
      browser: scriptedBrowser,
      resolveBaseDir: (_) async => tempDir,
      isAutomationEnabled: () => true,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('browser_navigate returns page info JSON', () async {
    final ToolResult result = await executor.execute(
      'browser_navigate',
      <String, dynamic>{'url': 'https://example.com'},
    );
    expect(result.ok, isTrue);
    expect(result.llmOutput, contains('Example Domain'));
    expect(scriptedBrowser.calls.first, 'navigate:https://example.com');
  });

  test('browser_screenshot saves PNG and returns path', () async {
    final ToolResult result = await executor.execute(
      'browser_screenshot',
      <String, dynamic>{},
    );
    expect(result.ok, isTrue);
    expect(result.screenshotPath, isNotNull);
    expect(File(result.screenshotPath!).existsSync(), isTrue);
  });

  test('write_file + read_file roundtrip', () async {
    final ToolResult write = await executor.execute(
      'write_file',
      <String, dynamic>{'path': 'docs/report.md', 'content': '# Laporan'},
    );
    expect(write.ok, isTrue);
    expect(File('${tempDir.path}/docs/report.md').existsSync(), isTrue);

    final ToolResult read = await executor.execute(
      'read_file',
      <String, dynamic>{'path': 'docs/report.md'},
    );
    expect(read.ok, isTrue);
    expect(read.llmOutput, '# Laporan');
  });

  test('path traversal is rejected', () async {
    final ToolResult result = await executor.execute(
      'read_file',
      <String, dynamic>{'path': '../../etc/passwd'},
    );
    expect(result.ok, isFalse);
  });

  test('browser tools blocked when automation disabled', () async {
    final ToolExecutor guarded = ToolExecutor(
      browser: scriptedBrowser,
      resolveBaseDir: (_) async => tempDir,
      isAutomationEnabled: () => false,
    );
    final ToolResult result = await guarded.execute(
      'browser_navigate',
      <String, dynamic>{'url': 'x'},
    );
    expect(result.ok, isFalse);
    expect(result.llmOutput, contains('disabled'));
  });

  test('unknown tool returns error result instead of throwing', () async {
    final ToolResult result = await executor.execute(
      'nope',
      <String, dynamic>{},
    );
    expect(result.ok, isFalse);
    expect(result.llmOutput, contains('Unknown tool'));
  });

  test('browser interface rejects empty URL', () async {
    final ToolResult result = await executor.execute(
      'browser_navigate',
      <String, dynamic>{'url': ''},
    );
    expect(result.ok, isFalse);
  });

  test('browser platform failure degrades to error result, no crash', () async {
    final ToolExecutor crashing = ToolExecutor(
      browser: ThrowingBrowserAutomation(),
      resolveBaseDir: (_) async => tempDir,
      isAutomationEnabled: () => true,
    );
    for (final String tool in <String>[
      'browser_navigate',
      'browser_click',
      'browser_type',
      'browser_scroll',
      'browser_screenshot',
      'browser_extract_text',
      'run_js',
    ]) {
      final ToolResult result = await crashing.execute(tool, <String, dynamic>{
        'url': 'https://example.com',
        'code': '1',
      });
      expect(result.ok, isFalse, reason: '$tool must not throw');
      expect(result.llmOutput, isNotEmpty);
    }
  });

  test('read_file on binary content returns error result, no crash', () async {
    final File binary = File(
      '${tempDir.path}${Platform.pathSeparator}blob.bin',
    );
    await binary.writeAsBytes(<int>[0x00, 0xFF, 0xFE, 0x80, 0x81]);
    final ToolResult result = await executor.execute(
      'read_file',
      <String, dynamic>{'path': 'blob.bin'},
    );
    // Either read fine or degraded to an error — never a crash.
    expect(result.ok, anyOf(isTrue, isFalse));
    expect(result.llmOutput, isNotEmpty);
  });

  test('write_file failure degrades to error result, no crash', () async {
    // A FILE occupies the intermediate path segment, so creating the
    // parent directory of the target fails with a filesystem error.
    final File blocker = File('${tempDir.path}${Platform.pathSeparator}sub');
    await blocker.writeAsString('x');
    final ToolResult result = await executor.execute(
      'write_file',
      <String, dynamic>{'path': 'sub/dir/file.txt', 'content': 'hi'},
    );
    expect(result.ok, isFalse);
    expect(result.llmOutput, contains('Could not write file'));
  });

  test('node_run executes through the injected JS runtime', () async {
    final ScriptedJsRuntime js = ScriptedJsRuntime(
      const JsRunResult(output: 'hello from node', result: '"42"'),
    );
    final ToolExecutor nodeExecutor = ToolExecutor(
      browser: scriptedBrowser,
      resolveBaseDir: (_) async => tempDir,
      isAutomationEnabled: () => true,
      js: js,
    );
    final ToolResult result = await nodeExecutor.execute(
      'node_run',
      <String, dynamic>{'code': 'return 42;'},
    );
    expect(result.ok, isTrue);
    expect(result.llmOutput, contains('hello from node'));
    expect(result.llmOutput, contains('=> "42"'));
    expect(js.runs.single, 'return 42;');
  });

  test('node_run surfaces script errors without crashing', () async {
    final ScriptedJsRuntime js = ScriptedJsRuntime(
      const JsRunResult(output: 'starting…', error: 'boom'),
    );
    final ToolExecutor nodeExecutor = ToolExecutor(
      browser: scriptedBrowser,
      resolveBaseDir: (_) async => tempDir,
      isAutomationEnabled: () => true,
      js: js,
    );
    final ToolResult result = await nodeExecutor.execute(
      'node_run',
      <String, dynamic>{'code': 'throw new Error("boom")'},
    );
    expect(result.ok, isFalse);
    expect(result.llmOutput, contains('starting…'));
    expect(result.llmOutput, contains('boom'));
  });

  test(
    'node tools degrade gracefully when the runtime is unavailable',
    () async {
      for (final String tool in <String>[
        'node_run',
        'node_install',
        'node_remove',
      ]) {
        final ToolResult result = await executor.execute(
          tool,
          <String, dynamic>{'code': '1', 'package': 'x'},
        );
        expect(result.ok, isFalse, reason: '$tool must not throw');
        expect(result.llmOutput, isNotEmpty);
      }
    },
  );

  test('node_install / node_remove go through the npm service', () async {
    final NpmService npm = NpmService(
      resolveBaseDir: () async => tempDir,
      client: MockClient(
        (http.Request request) async => http.Response('not found', 404),
      ),
    );
    final ToolExecutor nodeExecutor = ToolExecutor(
      browser: scriptedBrowser,
      resolveBaseDir: (_) async => tempDir,
      isAutomationEnabled: () => true,
      npm: npm,
    );

    final ToolResult fail = await nodeExecutor.execute(
      'node_install',
      <String, dynamic>{'package': 'missing-pkg'},
    );
    expect(fail.ok, isFalse);

    // Create an installed package fixture, then remove it via the tool.
    final Directory pkg = Directory('${tempDir.path}/node_modules/left-pad');
    await pkg.create(recursive: true);
    await File('${pkg.path}/package.json')
        .writeAsString('{"name":"left-pad","version":"1.0.0"}');
    final ToolResult removed = await nodeExecutor.execute(
      'node_remove',
      <String, dynamic>{'package': 'left-pad'},
    );
    expect(removed.ok, isTrue);
    expect(pkg.existsSync(), isFalse);
  });

  group('todo_write (plan tool)', () {
    test('valid plan returns progress json for the model', () async {
      final ToolResult result = await executor.execute(
        'todo_write',
        <String, dynamic>{
          'todos': <dynamic>[
            <String, dynamic>{'content': 'research', 'status': 'completed'},
            <String, dynamic>{'content': 'draft', 'status': 'in_progress'},
            <String, dynamic>{'content': 'review', 'status': 'pending'},
          ],
        },
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('"total":3'));
      expect(result.llmOutput, contains('"completed":1'));
      expect(result.llmOutput, contains('"in_progress":1'));
      expect(result.llmOutput, contains('"pending":1'));
      expect(result.displayText, 'plan 1/3');
    });

    test(
      'missing or empty todos is an error the model can retry from',
      () async {
        final ToolResult missing = await executor.execute(
          'todo_write',
          <String, dynamic>{},
        );
        expect(missing.ok, isFalse);
        expect(missing.llmOutput, contains('todos'));

        final ToolResult empty = await executor.execute(
          'todo_write',
          <String, dynamic>{
            'todos': <dynamic>[
              <String, dynamic>{'status': 'pending'},
            ],
          },
        );
        expect(empty.ok, isFalse);
      },
    );

    test('todo_write is never gated by the automation switch', () async {
      final ToolExecutor gated = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => false,
      );
      final ToolResult result = await gated.execute(
        'todo_write',
        <String, dynamic>{
          'todos': <dynamic>[
            <String, dynamic>{'content': 'step', 'status': 'pending'},
          ],
        },
      );
      expect(result.ok, isTrue);
    });

    test('v1.49.0: blocked steps + blocked_reason + depends_on are accepted '
        'end-to-end (unknown dependency ids stay stored as-is)', () async {
      final ToolResult result = await executor.execute(
        'todo_write',
        <String, dynamic>{
          'todos': <dynamic>[
            <String, dynamic>{
              'content': 'buy coins',
              'status': 'blocked',
              'blocked_reason': 'user has not funded the wallet',
              'depends_on': <String>['3', 'ghost-id'],
            },
            <String, dynamic>{'content': 'draft', 'status': 'in_progress'},
          ],
        },
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('"total":2'));
      expect(result.llmOutput, contains('"blocked":1'));
      expect(result.llmOutput, contains('"in_progress":1'));
      expect(result.llmOutput, contains('"pending":0'));
      // The transcript-side parser (same call path as the controller) keeps
      // the blocked metadata verbatim — unknown depends_on ids included.
      final ToolResult blockedOnly = await executor.execute(
        'todo_write',
        <String, dynamic>{
          'todos': <dynamic>[
            <String, dynamic>{
              'content': 'hard stop',
              'status': 'blocked',
              'blocked_reason': 'x' * 500,
            },
          ],
        },
      );
      expect(blockedOnly.ok, isTrue);
    });

    test(
      'v1.49.0: a blocked todo WITHOUT a reason degrades to pending',
      () async {
        final ToolResult result = await executor.execute(
          'todo_write',
          <String, dynamic>{
            'todos': <dynamic>[
              <String, dynamic>{'content': 'mystery', 'status': 'blocked'},
            ],
          },
        );
        expect(result.ok, isTrue);
        expect(result.llmOutput, contains('"blocked":0'));
        expect(result.llmOutput, contains('"pending":1'));
      },
    );
  });

  group('archive tools (zip_file / unzip_file)', () {
    late ToolExecutor fsExecutor;

    setUp(() {
      fsExecutor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        fs: FileSystemService(resolveBaseDir: () async => tempDir),
      );
    });

    test(
      'unzip_file extracts an archive and lists the JS files inside',
      () async {
        // Build a source folder that mimics an uploaded JS project, then
        // compress it with the very same service the tool delegates to.
        final Directory src = Directory('${tempDir.path}/proj');
        src.createSync(recursive: true);
        File('${src.path}/index.js').writeAsStringSync("console.log('hi');");
        final Directory lib = Directory('${src.path}/lib');
        lib.createSync(recursive: true);
        File('${lib.path}/util.js').writeAsStringSync('module.exports = 42;');
        final String zipRel = await FileSystemService(
          resolveBaseDir: () async => tempDir,
        ).zip('proj');

        final ToolResult result = await fsExecutor.execute(
          'unzip_file',
          <String, dynamic>{'path': zipRel},
        );
        expect(result.ok, isTrue);
        // 'proj' still exists next to the archive -> extraction lands in
        // proj_extracted and both extracted files are listed for the model.
        expect(result.llmOutput, contains('proj_extracted'));
        expect(result.llmOutput, contains('proj_extracted/index.js'));
        expect(result.llmOutput, contains('proj_extracted/lib/util.js'));
        expect(
          File('${tempDir.path}/proj_extracted/index.js').readAsStringSync(),
          "console.log('hi');",
        );
      },
    );

    test(
      'unzip_file without a password reports password-protected archives',
      () async {
        final Directory uploads = Directory('${tempDir.path}/uploads');
        uploads.createSync(recursive: true);
        File('${uploads.path}/locked.zip').writeAsBytesSync(
          File('test/fixtures/zipcrypto.zip').readAsBytesSync(),
        );

        final ToolResult result = await fsExecutor.execute(
          'unzip_file',
          <String, dynamic>{'path': 'uploads/locked.zip'},
        );
        expect(result.ok, isFalse);
        expect(result.llmOutput, contains('password-protected'));
        expect(result.llmOutput, contains('password'));
      },
    );

    test(
      'unzip_file decrypts encrypted archives when given the password',
      () async {
        final Directory uploads = Directory('${tempDir.path}/uploads');
        uploads.createSync(recursive: true);
        File('${uploads.path}/locked.zip').writeAsBytesSync(
          File('test/fixtures/zipcrypto.zip').readAsBytesSync(),
        );

        final ToolResult result = await fsExecutor.execute(
          'unzip_file',
          <String, dynamic>{
            'path': 'uploads/locked.zip',
            'password': 'fixt-pass-42',
          },
        );
        expect(result.ok, isTrue);
        expect(result.llmOutput, contains('uploads/locked/hello.txt'));
        expect(
          File('${tempDir.path}/uploads/locked/hello.txt').readAsStringSync(),
          'Hello from an encrypted zip! ZAgents can decrypt this.\n',
        );
      },
    );

    test(
      'unzip_file with a wrong password tells the model to re-ask',
      () async {
        final Directory uploads = Directory('${tempDir.path}/uploads');
        uploads.createSync(recursive: true);
        File('${uploads.path}/locked.zip').writeAsBytesSync(
          File('test/fixtures/zipcrypto.zip').readAsBytesSync(),
        );

        final ToolResult result = await fsExecutor.execute(
          'unzip_file',
          <String, dynamic>{'path': 'uploads/locked.zip', 'password': 'guess'},
        );
        expect(result.ok, isFalse);
        expect(result.llmOutput, contains('wrong'));
        expect(result.llmOutput, contains('"password"'));
      },
    );

    test('zip_file compresses a folder into a .zip next to it', () async {
      final Directory notes = Directory('${tempDir.path}/notes');
      notes.createSync(recursive: true);
      File('${notes.path}/a.txt').writeAsStringSync('hello');
      final ToolResult result = await fsExecutor.execute(
        'zip_file',
        <String, dynamic>{'path': 'notes'},
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('notes.zip'));
      expect(File('${tempDir.path}/notes.zip').existsSync(), isTrue);
    });

    test('archive tools degrade gracefully without the fs service', () async {
      final ToolResult result = await executor.execute(
        'unzip_file',
        <String, dynamic>{'path': 'whatever.zip'},
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('not available'));
    });

    test('path traversal and empty path are rejected', () async {
      final ToolResult bad = await fsExecutor.execute(
        'unzip_file',
        <String, dynamic>{'path': '../../x.zip'},
      );
      expect(bad.ok, isFalse);
      final ToolResult empty = await fsExecutor.execute(
        'zip_file',
        <String, dynamic>{'path': '  '},
      );
      expect(empty.ok, isFalse);
    });
  });

  group('per-session workspace isolation', () {
    late Map<String, Directory> roots;

    setUp(() async {
      roots = <String, Directory>{
        'a': Directory('${tempDir.path}/sessions/a'),
        'b': Directory('${tempDir.path}/sessions/b'),
      };
      for (final Directory dir in roots.values) {
        await dir.create(recursive: true);
      }
    });

    FileSystemService fsForSid(String? sid) => FileSystemService(
      resolveBaseDir: () async => sid == null ? tempDir : roots[sid] ?? tempDir,
    );

    test('write_file in one session is invisible to another session', () async {
      final ToolExecutor executor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (String? sid) async =>
            sid == null ? tempDir : roots[sid] ?? tempDir,
        isAutomationEnabled: () => true,
        fsFor: fsForSid,
      );

      final ToolResult write = await executor.execute(
        'write_file',
        <String, dynamic>{'path': 'notes.txt', 'content': 'secret-a'},
        sessionId: 'a',
      );
      expect(write.ok, isTrue);

      final ToolResult readA = await executor.execute(
        'read_file',
        <String, dynamic>{'path': 'notes.txt'},
        sessionId: 'a',
      );
      expect(readA.ok, isTrue);
      expect(readA.llmOutput, 'secret-a');

      final ToolResult readB = await executor.execute(
        'read_file',
        <String, dynamic>{'path': 'notes.txt'},
        sessionId: 'b',
      );
      expect(readB.ok, isFalse);
      expect(readB.llmOutput, contains('File not found'));
    });

    test('zip_file archives stay inside their own session workspace', () async {
      final ToolExecutor executor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (String? sid) async =>
            sid == null ? tempDir : roots[sid] ?? tempDir,
        isAutomationEnabled: () => true,
        fsFor: fsForSid,
      );
      Directory('${roots['a']!.path}/proj').createSync();
      File('${roots['a']!.path}/proj/data.txt').writeAsStringSync('data');

      final ToolResult zip = await executor.execute(
        'zip_file',
        <String, dynamic>{'path': 'proj'},
        sessionId: 'a',
      );
      expect(zip.ok, isTrue);

      final ToolResult readB = await executor.execute(
        'read_file',
        <String, dynamic>{'path': 'proj.zip'},
        sessionId: 'b',
      );
      expect(readB.ok, isFalse);
      expect(readB.llmOutput, contains('File not found'));
    });

    test('browser screenshots land in the session workspace', () async {
      final ToolExecutor executor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (String? sid) async =>
            sid == null ? tempDir : roots[sid] ?? tempDir,
        isAutomationEnabled: () => true,
      );
      final ToolResult shot = await executor.execute(
        'browser_screenshot',
        <String, dynamic>{},
        sessionId: 'a',
      );
      expect(shot.ok, isTrue);
      expect(
        Directory('${roots['a']!.path}/browser_shots').existsSync(),
        isTrue,
      );
      expect(
        Directory('${roots['b']!.path}/browser_shots').existsSync(),
        isFalse,
      );
    });

    test('node_run works inside the session but npm stays global', () async {
      final RecordingJsRuntime js = RecordingJsRuntime();
      final ToolExecutor executor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (String? sid) async =>
            sid == null ? tempDir : roots[sid] ?? tempDir,
        isAutomationEnabled: () => true,
        js: js,
      );
      final ToolResult run = await executor.execute(
        'node_run',
        <String, dynamic>{'code': 'return 1;'},
        sessionId: 'a',
      );
      expect(run.ok, isTrue);
      expect(js.workingDirs.single, roots['a']!.path);
      expect(js.moduleRoots.single, <String>[
        '${tempDir.path}${Platform.pathSeparator}node_modules',
      ]);
    });
  });

  group('web_fetch + git tools (v1.16.0)', () {
    test('web_fetch returns the fetcher output', () async {
      final ToolExecutor withFetcher = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        fetcher: WebFetcher(
          client: MockClient(
            (http.Request request) async => http.Response(
              'hello web world',
              200,
              headers: <String, String>{'content-type': 'text/plain'},
            ),
          ),
        ),
      );
      final ToolResult result = await withFetcher.execute(
        'web_fetch',
        <String, dynamic>{'url': 'https://example.test/page'},
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, 'hello web world');
      expect(result.displayText, contains('example.test'));
    });

    test('web_fetch without a fetcher degrades gracefully', () async {
      final ToolResult result = await executor.execute(
        'web_fetch',
        <String, dynamic>{'url': 'https://example.test/page'},
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('not available'));
    });

    test(
      'git_clone builds an isomorphic-git script inside the sandbox',
      () async {
        final RespondingJsRuntime js = RespondingJsRuntime(
          (String code) => const JsRunResult(
            output: 'Cloned 3 top-level entries',
            result: '"clone ok"',
          ),
        );
        final ToolExecutor gitExecutor = ToolExecutor(
          browser: scriptedBrowser,
          resolveBaseDir: (_) async => tempDir,
          isAutomationEnabled: () => true,
          js: js,
          npm: _ScriptedNpm(hasIsoGit: true),
        );
        final ToolResult result = await gitExecutor.execute(
          'git_clone',
          <String, dynamic>{'url': 'https://github.com/user/repo.git'},
          sessionId: 'a',
        );
        expect(result.ok, isTrue);
        expect(js.scripts.single, contains('git.clone'));
        expect(js.scripts.single, contains('isomorphic-git'));
        // Destination defaults to the repo name, inside the session sandbox.
        expect(
          js.scripts.single,
          contains('${tempDir.path}${Platform.pathSeparator}repo'),
        );
        expect(js.workingDirs.single, tempDir.path);
        expect(js.moduleRoots.single, <String>[
          '${tempDir.path}${Platform.pathSeparator}node_modules',
        ]);
      },
    );

    test('git tools auto-install isomorphic-git when missing', () async {
      final _ScriptedNpm npm = _ScriptedNpm(hasIsoGit: false);
      final ToolExecutor gitExecutor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        js: RespondingJsRuntime(
          (String code) => const JsRunResult(output: 'branch: main'),
        ),
        npm: npm,
      );
      final ToolResult result = await gitExecutor.execute(
        'git_status',
        <String, dynamic>{},
        sessionId: 'a',
      );
      expect(result.ok, isTrue);
      expect(npm.installed, <String>['isomorphic-git']);
      expect(result.llmOutput, contains('branch: main'));
    });

    test(
      'git tools fail with a clear error when npm cannot provide the package',
      () async {
        final ToolExecutor gitExecutor = ToolExecutor(
          browser: scriptedBrowser,
          resolveBaseDir: (_) async => tempDir,
          isAutomationEnabled: () => true,
          js: RespondingJsRuntime(
            (String code) => const JsRunResult(output: ''),
          ),
          npm: _ScriptedNpm(hasIsoGit: false, installOk: false),
        );
        final ToolResult result = await gitExecutor.execute(
          'git_log',
          <String, dynamic>{},
          sessionId: 'a',
        );
        expect(result.ok, isFalse);
        expect(result.llmOutput, contains('isomorphic-git'));
      },
    );

    test('git_commit requires message + author identity', () async {
      final ToolExecutor gitExecutor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        js: RespondingJsRuntime(
          (String code) => const JsRunResult(output: 'x'),
        ),
        npm: _ScriptedNpm(hasIsoGit: true),
      );
      final ToolResult noAuthor = await gitExecutor.execute(
        'git_commit',
        <String, dynamic>{'message': 'hi'},
        sessionId: 'a',
      );
      expect(noAuthor.ok, isFalse);
      expect(noAuthor.llmOutput, contains('authorName'));
    });

    test('git_clone rejects destination traversal', () async {
      final ToolExecutor gitExecutor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        js: RespondingJsRuntime(
          (String code) => const JsRunResult(output: 'x'),
        ),
        npm: _ScriptedNpm(hasIsoGit: true),
      );
      final ToolResult result = await gitExecutor.execute(
        'git_clone',
        <String, dynamic>{
          'url': 'https://github.com/user/repo.git',
          'destination': '../escape',
        },
        sessionId: 'a',
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('Invalid destination'));
    });
  });
  group('module doctor tools', () {
    late ModuleRegistry registry;
    late SessionSandbox sandbox;
    late ModuleRuntime moduleRuntime;
    late ToolExecutor doctor;

    setUp(() async {
      registry = ModuleRegistry(resolveBaseDir: () async => tempDir);
      sandbox = SessionSandbox(resolveDocumentsDir: () async => tempDir);
      moduleRuntime = ModuleRuntime(
        js: ScriptedJsRuntime(),
        resolveSandboxRoot: sandbox.rootFor,
        resolveModulePath: (String name) async =>
            (await registry.get(name))?.path,
        resolveSdkSource: () async => 'module.exports = zagents;',
        resolveNpmModulesRoot: () async =>
            '${tempDir.path}${Platform.pathSeparator}node_modules',
      );
      doctor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        modules: registry,
        moduleRuntime: moduleRuntime,
      );
    });

    test('module_list reports installed modules', () async {
      writeModuleZip('${tempDir.path}/list.zip', <String, String>{
        'module.json':
            '{"name":"listing","version":"3.1.0","title":"Listing",'
            '"permissions":["storage","agent"]}',
        'main.js': '//',
      });
      await registry.installFromZip('${tempDir.path}/list.zip');

      final ToolResult result = await doctor.execute('module_list', {});
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('listing v3.1.0'));
      expect(result.llmOutput, contains('permissions: storage,agent'));
      expect(result.llmOutput, contains('setup form: no'));
    });

    test(
      'module_list reports per-chat setup completion with masked secrets',
      () async {
        writeModuleZip('${tempDir.path}/acct.zip', <String, String>{
          'module.json':
              '{"name":"acct","version":"1.0.0","title":"Acct",'
              '"setup":{"title":"Acct account","fields":['
              '{"key":"email","label":"Email","type":"text","required":true},'
              '{"key":"password","label":"Password","type":"password","required":true}]}}',
          'main.js': '//',
        });
        await registry.installFromZip('${tempDir.path}/acct.zip');

        // Nothing stored for this chat yet: NOT completed.
        final ToolResult missing = await doctor.execute(
          'module_list',
          const <String, dynamic>{},
          sessionId: 'chatA',
        );
        expect(missing.ok, isTrue);
        expect(missing.llmOutput, contains('setup form: yes'));
        expect(
          missing.llmOutput,
          contains('setup for this chat: NOT completed'),
        );

        // The user submits the form for chatA: COMPLETED for this chat,
        // the email is visible, the password is ALWAYS masked.
        await moduleRuntime.writeStoredSetup('chatA', 'acct', <String, dynamic>{
          'email': 'me@example.com',
          'password': 'hunter2',
        });
        final ToolResult done = await doctor.execute(
          'module_list',
          const <String, dynamic>{},
          sessionId: 'chatA',
        );
        expect(done.llmOutput, contains('setup for this chat: COMPLETED'));
        expect(done.llmOutput, contains('Email: me@example.com'));
        expect(done.llmOutput, contains('Password: ********'));
        expect(done.llmOutput, isNot(contains('hunter2')));

        // Per-chat isolation: another chat still reports NOT completed.
        final ToolResult other = await doctor.execute(
          'module_list',
          const <String, dynamic>{},
          sessionId: 'chatB',
        );
        expect(other.llmOutput, contains('setup for this chat: NOT completed'));
      },
    );

    test('module_list degrades gracefully without a registry', () async {
      final ToolResult result = await executor.execute('module_list', {});
      expect(result.ok, isFalse);
    });

    test('module_read reads a file and lists with an empty path', () async {
      writeModuleZip('${tempDir.path}/read.zip', <String, String>{
        'module.json': '{"name":"inspect","version":"1.0.0"}',
        'main.js': 'module.exports = 42;',
        'lib/x.js': 'exports.n = 1;',
      });
      await registry.installFromZip('${tempDir.path}/read.zip');

      final ToolResult content = await doctor.execute(
        'module_read',
        <String, dynamic>{'name': 'inspect', 'path': 'main.js'},
      );
      expect(content.ok, isTrue);
      expect(content.llmOutput, contains('module.exports = 42;'));

      final ToolResult listing = await doctor.execute(
        'module_read',
        <String, dynamic>{'name': 'inspect', 'path': ''},
      );
      expect(listing.ok, isTrue);
      expect(listing.llmOutput, contains('lib/x.js'));
    });

    test('module_read rejects traversal and unknown modules', () async {
      writeModuleZip('${tempDir.path}/trav.zip', <String, String>{
        'module.json': '{"name":"trav","version":"1.0.0"}',
        'main.js': '//',
      });
      await registry.installFromZip('${tempDir.path}/trav.zip');

      expect(
        (await doctor.execute('module_read', <String, dynamic>{
          'name': 'trav',
          'path': '../registry.json',
        })).ok,
        isFalse,
      );
      expect(
        (await doctor.execute('module_read', <String, dynamic>{
          'name': 'ghost',
          'path': 'main.js',
        })).ok,
        isFalse,
      );
      expect(
        (await doctor.execute('module_read', <String, dynamic>{})).ok,
        isFalse,
      );
    });

    test('module_export writes an installable zip into the sandbox', () async {
      writeModuleZip('${tempDir.path}/exp.zip', <String, String>{
        'module.json': '{"name":"expmod","version":"9.9.9"}',
        'main.js': '// export target',
      });
      await registry.installFromZip('${tempDir.path}/exp.zip');

      final ToolResult result = await doctor.execute(
        'module_export',
        <String, dynamic>{'name': 'expmod'},
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('exports/expmod-v9.9.9.zip'));
      expect(
        File('${tempDir.path}/exports/expmod-v9.9.9.zip').existsSync(),
        isTrue,
      );

      // The export round-trips through installFromZip.
      final ModuleInstallResult reinstall = await registry.installFromZip(
        '${tempDir.path}/exports/expmod-v9.9.9.zip',
      );
      expect(reinstall.ok, isTrue, reason: reinstall.message);
    });

    test(
      'module_stage_repair validates and carries staging metadata',
      () async {
        writeModuleZip('${tempDir.path}/repaired.zip', <String, String>{
          'module.json':
              '{"name":"fixme","version":"1.0.1","permissions":["storage"]}',
          'main.js': 'module.exports = "fixed";',
        });

        final ToolResult result = await doctor.execute(
          'module_stage_repair',
          <String, dynamic>{'path': 'repaired.zip'},
        );
        expect(result.ok, isTrue, reason: result.llmOutput);
        expect(result.data, isNotNull);
        expect(result.data!['name'], 'fixme');
        expect(result.data!['version'], '1.0.1');
        expect(result.data!['permissions'], <String>['storage']);
        expect(File(result.data!['zipPath'] as String).existsSync(), isTrue);
        // Staging does NOT install.
        expect(await registry.get('fixme'), isNull);
      },
    );

    test('module_stage_repair rejects invalid zips and traversal', () async {
      // Not a module: missing entry.
      writeModuleZip('${tempDir.path}/notamodule.zip', <String, String>{
        'module.json': '{"name":"nope"}',
      });
      final ToolResult invalid = await doctor.execute(
        'module_stage_repair',
        <String, dynamic>{'path': 'notamodule.zip'},
      );
      expect(invalid.ok, isFalse);
      expect(invalid.llmOutput, contains('not a valid module'));

      // Traversal out of the workspace.
      expect(
        (await doctor.execute('module_stage_repair', <String, dynamic>{
          'path': '../../etc/passwd',
        })).ok,
        isFalse,
      );

      // Missing path argument.
      expect((await doctor.execute('module_stage_repair', {})).ok, isFalse);
    });
  });

  group('device_status tool (v1.32.0)', () {
    // Scripted shell bridge: answers the airplane probe and the root
    // probe (`exec` with root=true) from a mutable script.
    late bool? airplaneState;
    late DeviceShellResult rootProbe;
    int rootProbes = 0;
    late ToolExecutor deviceExecutor;

    setUp(() {
      airplaneState = false;
      rootProbe = const DeviceShellResult(exitCode: 0, stdout: '0\n');
      rootProbes = 0;
      final DeviceShellService shell = DeviceShellService(
        invoker: (String method, Map<String, Object?> args) async {
          if (method == 'getAirplaneMode') return airplaneState;
          if (method == 'exec' && args['root'] == true) {
            rootProbes++;
            return rootProbe.toJson();
          }
          throw MissingPluginException('not scripted: $method');
        },
      );
      deviceExecutor = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
        deviceStatus: () => shell,
      );
    });

    test('reports the verified airplane state and root availability', () async {
      airplaneState = true;
      final ToolResult result = await deviceExecutor.execute(
        'device_status',
        <String, dynamic>{},
      );
      expect(result.ok, isTrue);
      expect(result.llmOutput, contains('airplane_mode: ON'));
      expect(result.llmOutput, contains('root_available: true'));
      expect(result.llmOutput, contains('no internet'));
      expect(result.displayText, contains('airplane: ON'));
      expect(rootProbes, 1);
    });

    test(
      'airplane OFF reports OFF with root denied counted as no root',
      () async {
        airplaneState = false;
        rootProbe = const DeviceShellResult(
          exitCode: 1,
          stderr: 'su: permission denied',
        );
        final ToolResult result = await deviceExecutor.execute(
          'device_status',
          <String, dynamic>{},
        );
        expect(result.ok, isTrue);
        expect(result.llmOutput, contains('airplane_mode: OFF'));
        expect(result.llmOutput, contains('root_available: false'));
      },
    );

    test('the expensive root probe is cached across calls', () async {
      await deviceExecutor.execute('device_status', <String, dynamic>{});
      await deviceExecutor.execute('device_status', <String, dynamic>{});
      expect(rootProbes, 1);
    });

    test(
      'an unanswerable airplane probe reads as unknown, not a state',
      () async {
        airplaneState = null;
        final ToolResult result = await deviceExecutor.execute(
          'device_status',
          <String, dynamic>{},
        );
        expect(result.ok, isTrue);
        expect(result.llmOutput, contains('airplane_mode: unknown'));
        expect(result.displayText, contains('airplane: ?'));
      },
    );

    test('degrades cleanly without a shell bridge', () async {
      final ToolExecutor bare = ToolExecutor(
        browser: scriptedBrowser,
        resolveBaseDir: (_) async => tempDir,
        isAutomationEnabled: () => true,
      );
      final ToolResult result = await bare.execute(
        'device_status',
        <String, dynamic>{},
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('unavailable'));
    });
  });
}

/// NpmService test double: reports whether isomorphic-git is already installed and
/// records installs instead of touching the registry.
class _ScriptedNpm extends NpmService {
  _ScriptedNpm({required this.hasIsoGit, this.installOk = true})
    : super(resolveBaseDir: () async => Directory.systemTemp);

  final bool hasIsoGit;
  final bool installOk;
  final List<String> installed = <String>[];

  @override
  Future<List<InstalledModule>> listInstalled() async => hasIsoGit
      ? <InstalledModule>[
          InstalledModule(
            name: 'isomorphic-git',
            version: '1.25.0',
            path: '/stub/isomorphic-git',
          ),
        ]
      : const <InstalledModule>[];

  @override
  Future<NpmInstallResult> install(String name, {String? version}) async {
    installed.add(name);
    return NpmInstallResult(
      ok: installOk,
      message: installOk ? 'installed $name' : 'registry offline',
    );
  }
}

/// JsRuntime test double that records generated scripts (assertions run on the
/// isomorphic-git calls) and returns canned results.
class RespondingJsRuntime implements JsRuntime {
  RespondingJsRuntime(this.respond);

  final JsRunResult Function(String code) respond;
  final List<String> scripts = <String>[];
  final List<String?> workingDirs = <String?>[];
  final List<List<String>> moduleRoots = <List<String>>[];

  @override
  Future<JsRunResult> run(
    String code, {
    List<String> moduleRoots = const <String>[],
    String? workingDir,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    scripts.add(code);
    workingDirs.add(workingDir);
    this.moduleRoots.add(moduleRoots);
    return respond(code);
  }

  @override
  Future<JsRunResult> runModule(ModuleInvocation invocation) async =>
      respond(invocation.entrySource);

  @override
  void dispose() {}
}

/// JsRuntime test double that records workingDir/moduleRoots for isolation tests.
class RecordingJsRuntime implements JsRuntime {
  final List<String?> workingDirs = <String?>[];
  final List<List<String>> moduleRoots = <List<String>>[];

  @override
  Future<JsRunResult> run(
    String code, {
    List<String> moduleRoots = const <String>[],
    String? workingDir,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    workingDirs.add(workingDir);
    this.moduleRoots.add(moduleRoots);
    return const JsRunResult(output: 'ok', result: '"ok"');
  }

  @override
  Future<JsRunResult> runModule(ModuleInvocation invocation) async =>
      const JsRunResult(output: 'ok', result: '"ok"');

  @override
  void dispose() {}
}
