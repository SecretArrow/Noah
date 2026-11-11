import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/file_system_service.dart';

void main() {
  late Directory tempDir;
  late FileSystemService fs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_fs_test');
    fs = FileSystemService(resolveBaseDir: () async => tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('mkdir + list shows folders first with metadata', () async {
    await File('${tempDir.path}/a.txt').writeAsString('hello');
    await fs.mkdir('docs');
    await File('${tempDir.path}/docs/note.md').writeAsString('# hi');

    final List<FsEntry> entries = await fs.list('');
    expect(entries, hasLength(2));
    expect(entries.first.isDirectory, isTrue); // folders first
    expect(entries.first.name, 'docs');
    expect(entries.last.name, 'a.txt');
    expect(entries.last.sizeBytes, 5);

    final List<FsEntry> docs = await fs.list('docs');
    expect(docs.single.name, 'note.md');
  });

  test('rename works for files and rejects traversal names', () async {
    await File('${tempDir.path}/old.txt').writeAsString('x');
    await fs.rename('old.txt', 'new.txt');
    expect(await fs.exists('new.txt'), isTrue);
    expect(await fs.exists('old.txt'), isFalse);

    expect(
      () => fs.rename('new.txt', '../escape'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('copy (paste) duplicates files and whole directories', () async {
    await Directory('${tempDir.path}/src/sub').create(recursive: true);
    await File('${tempDir.path}/src/a.txt').writeAsString('A');
    await File('${tempDir.path}/src/sub/b.txt').writeAsString('B');
    await fs.mkdir('dst');

    await fs.copy('src/a.txt', 'dst/a.txt');
    expect(await File('${tempDir.path}/dst/a.txt').readAsString(), 'A');

    await fs.copy('src', 'dst/copy-of-src');
    expect(
      await File('${tempDir.path}/dst/copy-of-src/sub/b.txt').readAsString(),
      'B',
    );
    // Original untouched.
    expect(await fs.exists('src/a.txt'), isTrue);
  });

  test('move (cut+paste) relocates and removes the source', () async {
    await File('${tempDir.path}/src.txt').writeAsString('move-me');
    await fs.mkdir('other');
    await fs.move('src.txt', 'other/src.txt');
    expect(await fs.exists('src.txt'), isFalse);
    expect(
      await File('${tempDir.path}/other/src.txt').readAsString(),
      'move-me',
    );
  });

  test('delete removes files and directories recursively', () async {
    await Directory('${tempDir.path}/dir').create(recursive: true);
    await File('${tempDir.path}/dir/x.txt').writeAsString('x');
    await fs.delete('dir');
    expect(await fs.exists('dir'), isFalse);
    await fs.delete('dir'); // no-op, no crash
  });

  test('zip + unzip roundtrip restores content', () async {
    await Directory('${tempDir.path}/proj/nested').create(recursive: true);
    await File('${tempDir.path}/proj/a.txt').writeAsString('alpha');
    await File('${tempDir.path}/proj/nested/b.txt').writeAsString('beta');

    final String zipRel = await fs.zip('proj');
    expect(zipRel, 'proj.zip');
    expect(await fs.exists('proj.zip'), isTrue);

    // 'proj' already exists (the source) — the extract lands in a
    // non-colliding sibling folder.
    final String extractedRel = await fs.unzip('proj.zip');
    expect(extractedRel, 'proj_extracted');
    expect(
      await File('${tempDir.path}/$extractedRel/a.txt').readAsString(),
      'alpha',
    );
    expect(
      await File('${tempDir.path}/$extractedRel/nested/b.txt').readAsString(),
      'beta',
    );
  });

  test('zip a single file', () async {
    await File('${tempDir.path}/solo.txt').writeAsString('only');
    final String zipRel = await fs.zip('solo.txt');
    expect(zipRel, 'solo.txt.zip');
    final String extracted = await fs.unzip('solo.txt.zip');
    expect(extracted, 'solo.txt_extracted');
    expect(
      await File('${tempDir.path}/$extracted/solo.txt').readAsString(),
      'only',
    );
  });

  test('path traversal is rejected everywhere', () async {
    expect(await fs.resolve('../outside'), isNull);
    expect(await fs.list('../outside'), isEmpty);
  });

  test('unzip refuses entries that escape the destination '
      '(zip-slip)', () async {
    // A hand-built archive whose entry name climbs out of the folder the
    // extractor creates. Attaching a file like this used to write
    // anywhere in the app sandbox.
    final Archive evil = Archive()
      ..addFile(ArchiveFile('../escaped.txt', 4, <int>[101, 118, 105, 108]))
      ..addFile(ArchiveFile('ok.txt', 2, <int>[111, 107]));
    await File('${tempDir.path}/evil.zip')
        .writeAsBytes(ZipEncoder().encode(evil));

    await expectLater(
      fs.unzip('evil.zip'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await File('${tempDir.path}/escaped.txt').exists(),
      isFalse,
      reason: 'nothing may be written outside the destination',
    );
    expect(
      await Directory('${tempDir.path}/evil_extracted').exists(),
      isFalse,
      reason: 'a hostile archive must extract nothing at all',
    );
  });

  test('unzip normalises harmless entry names', () async {
    final Archive ok = Archive()
      ..addFile(ArchiveFile('./sub//note.txt', 2, <int>[104, 105]));
    await File('${tempDir.path}/ok.zip').writeAsBytes(ZipEncoder().encode(ok));

    final String dir = await fs.unzip('ok.zip');
    expect(
      await File('${tempDir.path}/$dir/sub/note.txt').readAsString(),
      'hi',
    );
  });

  test('readText truncates long files', () async {
    await File('${tempDir.path}/big.txt').writeAsString('x' * 50000);
    final String text = await fs.readText('big.txt', maxChars: 100);
    expect(text.length, 100);
  });
}
