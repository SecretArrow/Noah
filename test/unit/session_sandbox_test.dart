import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/session_sandbox.dart';

void main() {
  late Directory tempDir;
  late SessionSandbox sandbox;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_sandbox_test');
    sandbox = SessionSandbox(resolveDocumentsDir: () async => tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('null session falls back to the legacy documents root', () async {
    final Directory root = await sandbox.rootFor(null);
    expect(root.path, tempDir.path);
  });

  test('rootFor creates an isolated directory per session id', () async {
    final Directory a = await sandbox.rootFor('session-a');
    final Directory b = await sandbox.rootFor('session-b');
    expect(a.path, '${tempDir.path}/sessions/session-a');
    expect(b.path, '${tempDir.path}/sessions/session-b');
    expect(a.existsSync(), isTrue);
    expect(b.existsSync(), isTrue);
    expect(a.path == b.path, isFalse);
  });

  test('legacy shared files migrate once into the first session', () async {
    // Pre-update layout: uploads/ + stray agent files at the root, plus
    // service dirs that must stay put.
    Directory('${tempDir.path}/uploads').createSync(recursive: true);
    File('${tempDir.path}/uploads/old.txt').writeAsStringSync('legacy');
    File('${tempDir.path}/notes.txt').writeAsStringSync('agent note');
    Directory('${tempDir.path}/chats').createSync();
    Directory('${tempDir.path}/node_modules').createSync();
    Directory('${tempDir.path}/exports').createSync();
    File('${tempDir.path}/chats/c1.json').writeAsStringSync('{}');
    File('${tempDir.path}/node_modules/pkg.js').writeAsStringSync('');
    File('${tempDir.path}/exports/e.json').writeAsStringSync('{}');

    final Directory a = await sandbox.rootFor('session-a');
    // Legacy entries moved into the first session's workspace.
    expect(File('${a.path}/uploads/old.txt').existsSync(), isTrue);
    expect(File('${a.path}/notes.txt').existsSync(), isTrue);
    expect(Directory('${tempDir.path}/uploads').existsSync(), isFalse);
    expect(File('${tempDir.path}/notes.txt').existsSync(), isFalse);
    // Reserved service dirs stay in place.
    expect(File('${tempDir.path}/chats/c1.json').existsSync(), isTrue);
    expect(File('${tempDir.path}/node_modules/pkg.js').existsSync(), isTrue);
    expect(File('${tempDir.path}/exports/e.json').existsSync(), isTrue);
    // Marker prevents a second import.
    expect(
      File('${tempDir.path}/sessions/.legacy-imported').existsSync(),
      isTrue,
    );

    // New files added to the root afterwards are NOT re-imported.
    File('${tempDir.path}/later.txt').writeAsStringSync('x');
    final Directory b = await sandbox.rootFor('session-b');
    expect(File('${b.path}/later.txt').existsSync(), isFalse);
    expect(File('${b.path}/notes.txt').existsSync(), isFalse);
  });

  test('fsFor hands out services scoped to each session workspace', () async {
    await sandbox.fsFor('session-a').mkdir('only-in-a');
    expect(await sandbox.fsFor('session-a').exists('only-in-a'), isTrue);
    expect(await sandbox.fsFor('session-b').exists('only-in-a'), isFalse);
    expect(
      (await sandbox.fsFor('session-b').list('')).map((e) => e.name),
      isEmpty,
    );
  });

  group('deleteSession (v1.29.0)', () {
    test('removes the whole session workspace with the chat', () async {
      final Directory root = await sandbox.rootFor('gone');
      await File('${root.path}/data.json').writeAsString('{}');
      Directory('${root.path}/modules/x/state').createSync(recursive: true);
      await File('${root.path}/modules/x/state/data.json')
          .writeAsString('{"a":1}');
      await sandbox.deleteSession('gone');
      expect(root.existsSync(), isFalse);
      expect(Directory('${tempDir.path}/sessions').existsSync(), isTrue);
    });

    test('refuses dangerous ids and ignores unknown ones', () async {
      await sandbox.rootFor('keep');
      // Traversal and relative-path ids are refused outright.
      await sandbox.deleteSession('../keep');
      await sandbox.deleteSession('a/b');
      await sandbox.deleteSession('.hidden');
      await sandbox.deleteSession('');
      expect(Directory('${tempDir.path}/sessions/keep').existsSync(), isTrue);
      // Unknown id: a no-op, never an exception.
      await sandbox.deleteSession('never-existed');
    });
  });
}
