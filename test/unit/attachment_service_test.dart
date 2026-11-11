import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:noah/services/attachment_service.dart';

/// Unit tests for [AttachmentService] — no platform channels: the picker is
/// faked with path-backed XFiles and the sandbox resolver with temp dirs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<Directory> temps = <Directory>[];
  late Directory sandboxA;
  late Directory sandboxB;
  late Directory legacyRoot;
  late SandboxDirResolver resolver;

  setUp(() async {
    sandboxA = await _tempDir(temps, 'zatt_sandbox_a');
    sandboxB = await _tempDir(temps, 'zatt_sandbox_b');
    legacyRoot = await _tempDir(temps, 'zatt_legacy_root');
    resolver = (String? sessionId) async {
      if (sessionId == null) return legacyRoot;
      if (sessionId == 'chat-a') return sandboxA;
      return sandboxB;
    };
  });

  tearDown(() async {
    for (final Directory dir in temps) {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (_) {
        // best effort cleanup
      }
    }
    temps.clear();
  });

  Future<XFile> writeFixture(String name, List<int> bytes) async {
    final Directory dir = await _tempDir(temps, 'zatt_source');
    final File file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return XFile(file.path);
  }

  PickImage pickerOf(XFile file) =>
      () async => file;

  Uint8List tinyPng() =>
      Uint8List.fromList(img.encodePng(img.Image(width: 24, height: 24)));

  Uint8List tinyJpeg() => Uint8List.fromList(
    img.encodeJpg(img.Image(width: 32, height: 32), quality: 85),
  );

  File storedFile(AttachmentResult result, Directory root) {
    final String name = result.relativePath!.split('/').last;
    return File(
      '${root.path}${Platform.pathSeparator}'
      '${AttachmentService.attachmentsDirName}'
      '${Platform.pathSeparator}$name',
    );
  }

  Directory attachmentsDirOf(Directory root) => Directory(
    '${root.path}${Platform.pathSeparator}'
    '${AttachmentService.attachmentsDirName}',
  );

  group('AttachmentService.attachToSession', () {
    test('small PNG is stored byte-for-byte in the chat sandbox', () async {
      final Uint8List png = tinyPng();
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(await writeFixture('photo.png', png)),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isTrue, reason: result.errorMessage);
      expect(result.errorType, isNull);
      expect(
        result.relativePath,
        matches(RegExp(r'^attachments/ATT-\d{8}-\d{6}-[a-z0-9]{4}\.png$')),
      );
      final File stored = storedFile(result, sandboxA);
      expect(result.absolutePath, stored.path);
      expect(stored.existsSync(), isTrue);
      // <=300KB JPEG/PNG copy-through: identical bytes, no re-encode.
      expect(await stored.readAsBytes(), png);
      expect(result.bytes, png);
      expect(result.originalBytes, png.length);
      expect(result.reference, '[image: ${result.relativePath}]');
    });

    test('.jpeg extension is normalized to .jpg on copy-through', () async {
      final Uint8List jpeg = tinyJpeg();
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(await writeFixture('shot.jpeg', jpeg)),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isTrue, reason: result.errorMessage);
      expect(result.relativePath, endsWith('.jpg'));
      expect(await storedFile(result, sandboxA).readAsBytes(), jpeg);
    });

    test('image content is trusted over a wrong extension', () async {
      // A real PNG misnamed .txt: content sniffing accepts it and the
      // stored file gets the true extension.
      final Uint8List png = tinyPng();
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(await writeFixture('screenshot.txt', png)),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isTrue, reason: result.errorMessage);
      expect(result.relativePath, endsWith('.png'));
      expect(result.bytes, png);
    });

    test('cancelling the picker yields a cancelled result', () async {
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: () async => null,
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isFalse);
      expect(result.errorType, AttachmentErrorType.cancelled);
      expect(result.reference, isNull);
      expect(
        attachmentsDirOf(sandboxA).existsSync(),
        isFalse,
        reason: 'a cancelled pick must not create any folder',
      );
    });

    test('a text file is rejected as notAnImage', () async {
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(
          await writeFixture('notes.txt', 'hello world'.codeUnits),
        ),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isFalse);
      expect(result.errorType, AttachmentErrorType.notAnImage);
      expect(result.reference, isNull);
    });

    test(
      'png extension with non-png content is rejected as notAnImage',
      () async {
        final AttachmentService service = AttachmentService(
          resolveSandboxDir: resolver,
          pickImage: pickerOf(
            await writeFixture('fake.png', <int>[1, 2, 3, 4, 5, 6, 7, 8]),
          ),
        );

        final AttachmentResult result = await service.attachToSession(
          sessionId: 'chat-a',
        );

        expect(result.ok, isFalse);
        expect(result.errorType, AttachmentErrorType.notAnImage);
        expect(attachmentsDirOf(sandboxA).existsSync(), isFalse);
      },
    );

    test('large JPEG is downscaled and re-encoded smaller', () async {
      final Uint8List big = noisyJpeg(2000, 1600);
      // Fixture preconditions: big enough to hit the optimize path, small
      // enough not to trip the 20 MB source cap.
      expect(big.length, greaterThan(AttachmentService.copyThroughMaxBytes));
      expect(big.length, lessThan(AttachmentService.maxSourceBytes));
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(await writeFixture('camera.jpg', big)),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isTrue, reason: result.errorMessage);
      expect(result.relativePath, endsWith('.jpg'));
      expect(result.originalBytes, big.length);
      expect(result.bytes!.length, lessThan(big.length));
      final File stored = storedFile(result, sandboxA);
      expect(stored.existsSync(), isTrue);
      expect(await stored.length(), lessThan(big.length));
      expect(result.bytes, await stored.readAsBytes());
    });

    test('different sessions never share an attachments folder', () async {
      final Uint8List png = tinyPng();
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(await writeFixture('photo.png', png)),
      );

      final AttachmentResult inA = await service.attachToSession(
        sessionId: 'chat-a',
      );
      final AttachmentResult inB = await service.attachToSession(
        sessionId: 'chat-b',
      );

      expect(inA.ok, isTrue, reason: inA.errorMessage);
      expect(inB.ok, isTrue, reason: inB.errorMessage);
      final File fileA = storedFile(inA, sandboxA);
      final File fileB = storedFile(inB, sandboxB);
      expect(fileA.existsSync(), isTrue);
      expect(fileB.existsSync(), isTrue);
      expect(inA.absolutePath, startsWith(sandboxA.path));
      expect(inB.absolutePath, startsWith(sandboxB.path));
      expect(inA.absolutePath, isNot(inB.absolutePath));
      // chat-b's file never leaks into chat-a's sandbox.
      expect(storedFile(inB, sandboxA).existsSync(), isFalse);
      expect(storedFile(inA, sandboxB).existsSync(), isFalse);
    });

    test('null session id lands in the legacy documents root', () async {
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(await writeFixture('photo.png', tinyPng())),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: null,
      );

      expect(result.ok, isTrue, reason: result.errorMessage);
      expect(result.absolutePath, startsWith(legacyRoot.path));
      expect(storedFile(result, legacyRoot).existsSync(), isTrue);
    });

    test('oversized source (> 20 MB) is refused as tooLarge', () async {
      final Uint8List huge = Uint8List(AttachmentService.maxSourceBytes + 1);
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: pickerOf(await writeFixture('huge.png', huge)),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      // Size gates run BEFORE content validation on purpose: the caller
      // gets tooLarge, not notAnImage, even though the bytes are junk.
      expect(result.ok, isFalse);
      expect(result.errorType, AttachmentErrorType.tooLarge);
      expect(attachmentsDirOf(sandboxA).existsSync(), isFalse);
    });

    test('sandbox resolver failure surfaces as saveFailed', () async {
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: (String? sessionId) async =>
            throw StateError('workspace gone'),
        pickImage: pickerOf(await writeFixture('photo.png', tinyPng())),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isFalse);
      expect(result.errorType, AttachmentErrorType.saveFailed);
      expect(result.errorMessage, contains('workspace gone'));
    });

    test('picker crash surfaces as saveFailed (never throws)', () async {
      final AttachmentService service = AttachmentService(
        resolveSandboxDir: resolver,
        pickImage: () async => throw StateError('picker exploded'),
      );

      final AttachmentResult result = await service.attachToSession(
        sessionId: 'chat-a',
      );

      expect(result.ok, isFalse);
      expect(result.errorType, AttachmentErrorType.saveFailed);
      expect(result.errorMessage, contains('picker failed'));
    });
  });
}

Future<Directory> _tempDir(List<Directory> registry, String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  registry.add(dir);
  return dir;
}

/// A clearly-large JPEG fixture: incompressible noise at 2000x1600 encoded
/// at quality 100 stays several MB, so the service must take the downscale
/// path and shrink it.
Uint8List noisyJpeg(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  int seed = 20260214;
  int next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed;
  }

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgb(x, y, next() & 0xff, next() & 0xff, next() & 0xff);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 100));
}
