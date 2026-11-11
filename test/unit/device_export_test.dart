import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/device_export.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_device_export');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Directory makeWorkspace() {
    final Directory root = Directory('${tempDir.path}/sessions/abc');
    Directory('${root.path}/uploads').createSync(recursive: true);
    Directory('${root.path}/modules/counter/state').createSync(recursive: true);
    File('${root.path}/data.json').writeAsStringSync('{}');
    File('${root.path}/uploads/note.txt').writeAsStringSync('hi');
    File('${root.path}/modules/counter/state/data.json')
        .writeAsStringSync('{"n":1}');
    // Hidden internals never leave the sandbox.
    File('${root.path}/.secret').writeAsStringSync('nope');
    return root;
  }

  group('collectFiles', () {
    test('walks the workspace into sorted posix-relative paths', () async {
      final Directory root = makeWorkspace();
      final List<ExportFile> files = await collectFiles(root);
      expect(files.map((ExportFile f) => f.rel).toList(), <String>[
        'data.json',
        'modules/counter/state/data.json',
        'uploads/note.txt',
      ]);
      expect(File(files[0].abs).readAsStringSync(), '{}');
    });

    test('an empty workspace exports nothing (not an error)', () async {
      final Directory root = Directory('${tempDir.path}/sessions/empty')
        ..createSync(recursive: true);
      expect(await collectFiles(root), isEmpty);
    });
  });

  group('deviceFolderName', () {
    test('uses the chat title plus a short id suffix', () {
      expect(
        deviceFolderName('Research notes', 'abcd1234-ef56-7890'),
        'Research notes-abcd12',
      );
    });

    test('sanitizes hostile characters and falls back to "chat"', () {
      final String name = deviceFolderName('../../etc⧉data', 'xyz789');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('..')));
      expect(name.endsWith('-xyz789'), isTrue);
      expect(deviceFolderName('   ', 'abc123'), 'chat-abc123');
    });
  });

  group('DeviceExportService', () {
    test('MediaStore path on Android 10+: sends rel/abs pairs', () async {
      final Directory root = makeWorkspace();
      final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
      final DeviceExportService service = DeviceExportService(
        invoke: <T>(String method, [Map<String, dynamic>? args]) async {
          calls.add(<String, dynamic>{'method': method, 'args': args});
          if (method == 'getSdkInt') return 33;
          if (method == 'exportChatFolder') return 3;
          return null;
        },
      );
      final DeviceExportResult result = await service.exportChatFolder(
        folderName: 'Chat-abc123',
        root: root,
      );
      expect(result, isA<MediaStoreExport>());
      expect((result as MediaStoreExport).fileCount, 3);
      expect(
        calls.map((Map<String, dynamic> c) => c['method']).toList(),
        <String>['getSdkInt', 'exportChatFolder'],
      );
      final Map<String, dynamic> args =
          calls[1]['args'] as Map<String, dynamic>;
      expect(args['name'], 'Chat-abc123');
      final List<dynamic> files = args['files'] as List<dynamic>;
      expect(files, hasLength(3));
      expect((files[0] as Map<dynamic, dynamic>)['rel'], 'data.json');
    });

    test(
      'pre-Android-10: falls back to a zipped folder for the share sheet',
      () async {
        final Directory root = makeWorkspace();
        final DeviceExportService service = DeviceExportService(
          invoke: <T>(String method, [Map<String, dynamic>? args]) async {
            if (method == 'getSdkInt') return 27;
            throw StateError('no other call expected, got $method');
          },
        );
        final DeviceExportResult result = await service.exportChatFolder(
          folderName: 'Chat-abc123',
          root: root,
        );
        expect(result, isA<SharedZipExport>());
        final SharedZipExport zip = result as SharedZipExport;
        expect(zip.fileCount, 3);
        final File zipFile = File(zip.zipPath);
        expect(zipFile.existsSync(), isTrue);
        // The zip lands in the app's exports directory, not inside the chat.
        expect(zipFile.parent.path.endsWith('exports'), isTrue);
      },
    );

    test('a failed MediaStore export surfaces ExportFailedException', () async {
      final Directory root = makeWorkspace();
      final DeviceExportService service = DeviceExportService(
        invoke: <T>(String method, [Map<String, dynamic>? args]) async {
          if (method == 'getSdkInt') return 30;
          return 0; // nothing exported
        },
      );
      await expectLater(
        service.exportChatFolder(folderName: 'x', root: root),
        throwsA(isA<ExportFailedException>()),
      );
    });
  });
}
