import 'dart:typed_data';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Result of [downscaleForUpload]: the (possibly re-encoded) bytes plus the
/// mime type that matches the OUTPUT format (the re-encode may change it,
/// e.g. a downscaled JPEG no longer matches the original .png file name).
class DownscaledImage {
  const DownscaledImage({required this.bytes, required this.mime});

  final List<int> bytes;
  final String mime;
}

/// Prepares an image attachment for the chat wire: images travel as base64
/// data URLs, and an untouched 12 MP photo would mean megabytes of base64
/// per message. The long edge is capped at [maxEdge] (aspect preserved,
/// never upscaled) and everything non-PNG becomes JPEG at [quality].
///
/// Small PNGs (within the size box) pass through with their crispness kept
/// — screenshots with text stay readable. Any decode failure returns the
/// original bytes untouched: sending SOMETHING beats crashing the chat.
Future<DownscaledImage> downscaleForUpload(
  List<int> bytes, {
  int maxEdge = 1568,
  int quality = 82,
}) async {
  final Uint8List data = Uint8List.fromList(bytes);
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(data);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    try {
      final int w = image.width;
      final int h = image.height;
      final bool withinBox = w <= maxEdge && h <= maxEdge;
      final bool png = _isPng(data);

      // Small PNG: keep as-is (encode via dart:ui to normalize the bytes).
      if (withinBox && png) {
        final ByteData? encoded = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (encoded != null) {
          return DownscaledImage(
            bytes: encoded.buffer.asUint8List(),
            mime: 'image/png',
          );
        }
        return DownscaledImage(bytes: data, mime: 'image/png');
      }

      // Downscale when needed (aspect preserved, never upscale), then
      // re-encode: PNG keeps the PNG format, everything else becomes JPEG.
      final double scale = withinBox ? 1.0 : maxEdge / (w > h ? w : h);
      final int tw = (w * scale).round().clamp(1, maxEdge * 4);
      final int th = (h * scale).round().clamp(1, maxEdge * 4);

      if (png) {
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final ui.Canvas canvas = ui.Canvas(
          recorder,
          ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        );
        canvas.drawImageRect(
          image,
          ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
          ui.Paint(),
        );
        final ui.Picture picture = recorder.endRecording();
        final ui.Image scaled = await picture.toImage(tw, th);
        picture.dispose();
        final ByteData? encoded = await scaled.toByteData(
          format: ui.ImageByteFormat.png,
        );
        scaled.dispose();
        if (encoded != null) {
          return DownscaledImage(
            bytes: encoded.buffer.asUint8List(),
            mime: 'image/png',
          );
        }
        return DownscaledImage(bytes: data, mime: 'image/png');
      }

      // JPEG path: raw RGBA -> pure-Dart JPEG encoder.
      final ByteData? raw = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (raw == null) {
        return DownscaledImage(bytes: data, mime: 'image/jpeg');
      }
      // v1.34.0 ANR hardening: copyResize + encodeJpg on a 12MP RGBA
      // buffer is 100ms–1s+ of pure-CPU work that used to run on the UI
      // isolate at send-time AND on every history replay. The pure-Dart
      // pipeline (construct from bytes → resize → encode) now runs in a
      // short-lived worker isolate; only bytes cross the boundary (the
      // dart:ui decode stays here — GPU types cannot cross isolates).
      final Uint8List rawBytes = raw.buffer.asUint8List(
        raw.offsetInBytes,
        raw.lengthInBytes,
      );
      final List<int> jpg = await Isolate.run(() {
        final img.Image decoded = img.Image.fromBytes(
          width: w,
          height: h,
          bytes: rawBytes.buffer,
          numChannels: 4,
        );
        if (!withinBox) {
          final img.Image resized = img.copyResize(
            decoded,
            width: tw,
            height: th,
            interpolation: img.Interpolation.average,
          );
          return img.encodeJpg(resized, quality: quality);
        }
        return img.encodeJpg(decoded, quality: quality);
      });
      return DownscaledImage(bytes: jpg, mime: 'image/jpeg');
    } finally {
      image.dispose();
    }
  } catch (_) {
    // Undecodable input: the original bytes still travel (the provider may
    // accept the format even when the local codec does not).
    return DownscaledImage(bytes: data, mime: mimeFromBytes(data));
  }
}

/// Sniffs the container magic to pick the data-URL mime for [bytes].
String mimeFromBytes(List<int> bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'application/octet-stream';
}

bool _isPng(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;
