import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/image_downscale.dart';

Future<List<int>> _solidPng(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(
    recorder,
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width, height);
  picture.dispose();
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<(int, int)> _decodeSize(List<int> bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(
    Uint8List.fromList(bytes),
  );
  final ui.FrameInfo frame = await codec.getNextFrame();
  final int w = frame.image.width;
  final int h = frame.image.height;
  frame.image.dispose();
  codec.dispose();
  return (w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'oversized PNG is downscaled to the max edge (aspect preserved)',
    () async {
      final List<int> big = await _solidPng(2000, 1000);
      final DownscaledImage out = await downscaleForUpload(big);
      expect(_isPngHelper(out.bytes), isTrue, reason: 'PNG stays PNG');
      expect(out.mime, 'image/png');
      final (int w, int h) = await _decodeSize(out.bytes);
      expect(w, 1568);
      expect(h, 784, reason: 'aspect ratio 2:1 is preserved');
    },
  );

  test('small PNG passes through unchanged in size', () async {
    final List<int> small = await _solidPng(400, 200);
    final DownscaledImage out = await downscaleForUpload(small);
    expect(out.mime, 'image/png');
    final (int w, int h) = await _decodeSize(out.bytes);
    expect(w, 400);
    expect(h, 200);
  });

  test('undecodable input returns the original bytes untouched', () async {
    // Garbage is not an image: the codec fails and the passthrough path
    // must keep the payload exactly as it arrived.
    final DownscaledImage garbage = await downscaleForUpload(<int>[
      1,
      2,
      3,
      4,
      5,
    ]);
    expect(garbage.bytes, <int>[1, 2, 3, 4, 5]);
    expect(garbage.mime, 'application/octet-stream');
  });

  test('mimeFromBytes sniffs common containers', () {
    expect(
      mimeFromBytes(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
      'image/png',
    );
    expect(mimeFromBytes(<int>[0xFF, 0xD8, 0xFF, 0xE0]), 'image/jpeg');
    expect(
      mimeFromBytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
      'image/gif',
    );
    expect(mimeFromBytes(<int>[1, 2, 3]), 'application/octet-stream');
  });
}

bool _isPngHelper(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;
