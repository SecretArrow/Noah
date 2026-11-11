import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import 'image_downscale.dart';
import 'session_sandbox.dart';

/// Why a chat attachment pick ended. Surfaced as a result field — the
/// service NEVER throws for expected outcomes.
enum AttachmentErrorType {
  /// The user dismissed the system image picker (nothing selected).
  cancelled,

  /// The picked file is not a supported image (jpg/jpeg/png/webp/gif).
  notAnImage,

  /// The picked file exceeds [AttachmentService.maxSourceBytes] (20 MB).
  tooLarge,

  /// Reading the picked file or storing it into the sandbox failed.
  saveFailed,
}

/// Outcome of [AttachmentService.attachToSession] — both success and failure
/// are values; check [ok] first.
class AttachmentResult {
  const AttachmentResult._({
    this.errorType,
    this.errorMessage,
    this.relativePath,
    this.absolutePath,
    this.bytes,
    this.originalBytes,
  });

  /// Failure constructor; [AttachmentErrorType] tells the UI which message
  /// to show.
  factory AttachmentResult.failure(
    AttachmentErrorType errorType,
    String message,
  ) => AttachmentResult._(errorType: errorType, errorMessage: message);

  /// Non-null (and [ok] true) only for a successfully stored attachment.
  final AttachmentErrorType? errorType;

  /// Human-readable failure detail; always null on success.
  final String? errorMessage;

  /// Sandbox-relative path of the stored file, always forward slashes:
  /// `attachments/ATT-<yyyyMMdd-HHmmss>-<rand4>.<ext>`.
  final String? relativePath;

  /// Platform absolute path of the stored file (inside the chat sandbox).
  final String? absolutePath;

  /// The bytes actually stored (possibly downscale/re-encode optimized).
  final Uint8List? bytes;

  /// Size of the originally picked source file, in bytes.
  final int? originalBytes;

  /// True when the attachment was picked, validated and stored.
  bool get ok => errorType == null;

  /// Message-ready reference to the stored image, e.g.
  /// `[image: attachments/ATT-20260214-093015-k3f9.png]`.
  ///
  /// The UI appends this to the outgoing chat text. The AGENT later reads
  /// the image through its own per-chat sandbox fs tool — cross-chat
  /// isolation is automatic because [relativePath] always lives inside the
  /// session sandbox (`documents/sessions/<sessionId>/attachments/...`),
  /// so no other chat can ever resolve it. `null` session ids keep the
  /// legacy documents-root behavior, matching SessionSandbox.
  ///
  /// Null on failure results (see [ok]).
  String? get reference => ok ? '[image: $relativePath]' : null;
}

/// Picks a single image file. Defaults to the system file selector filtered
/// to images (`openFile` with an `image/*` type group — file_selector 1.1.0
/// has no openImage); faked in tests.
typedef PickImage = Future<XFile?> Function();

/// Resolves the workspace ROOT for a chat session: the active chat's own
/// sandbox `documents/sessions/<sessionId>/`, or the documents root when
/// [sessionId] is null/empty (legacy layout — exactly SessionSandbox.rootFor
/// semantics). DI wires `sandbox.rootFor` directly; tests fake it.
typedef SandboxDirResolver = Future<Directory> Function(String? sessionId);

/// Chat image attachments with per-chat isolation as the first principle.
///
/// Pipeline ([attachToSession]):
/// 1. pick one image via [pickImage] (cancel => cancelled result),
/// 2. size gate: source files over [maxSourceBytes] (20 MB) are refused
///    BEFORE being read into memory (length probe + re-check after read),
/// 3. validate the image by extension AND/OR content magic
///    (jpg/jpeg/png/webp/gif); when the extension claims a concrete image
///    type the bytes must agree, and an unknown extension is still accepted
///    when the content sniffs as a supported image,
/// 4. optimize: sources at or below [copyThroughMaxBytes] (~300 KB) that
///    are already JPEG/PNG are stored BYTE-FOR-BYTE (no re-encode — they
///    are chat-sized already; re-encoding only costs CPU and degrades
///    quality, and PNG would lose crispness). Everything else goes through
///    `downscaleForUpload` (image_downscale.dart, reused as-is): long edge
///    capped at [maxLongEdge] (1600 px, aspect preserved, never upscaled),
///    re-encoded as JPEG at [jpegQuality] (85) — PNG stays PNG so
///    transparency survives. If a re-encode would not shrink the file it
///    is discarded and the original bytes are stored instead. Animated
///    GIFs are flattened to their first frame (JPEG).
/// 5. store as `<sandbox>/attachments/ATT-<yyyyMMdd-HHmmss>-<rand4>.<ext>`
///    inside the SESSION's sandbox, never anywhere shared between chats.
///
/// The result's [AttachmentResult.reference] is appended to the chat
/// message; the agent reads the file through its own per-chat fs tool.
class AttachmentService {
  AttachmentService({
    SandboxDirResolver? resolveSandboxDir,
    PickImage? pickImage,
  }) : resolveSandboxDir = resolveSandboxDir ?? _defaultSandboxDir,
       pickImage = pickImage ?? _defaultPickImage;

  /// Resolves the sandbox root for the given session id (see
  /// [SandboxDirResolver]).
  final SandboxDirResolver resolveSandboxDir;

  /// Picks the image; returning null means the user cancelled.
  final PickImage pickImage;

  /// Long-edge cap for optimized attachments.
  static const int maxLongEdge = 1600;

  /// JPEG re-encode quality for optimized attachments.
  static const int jpegQuality = 85;

  /// Sources at or below this size that are already JPEG/PNG are copied
  /// through untouched (~300 KB threshold, see class doc).
  static const int copyThroughMaxBytes = 300 * 1024;

  /// Hard cap for a picked source file.
  static const int maxSourceBytes = 20 * 1024 * 1024;

  /// Subfolder inside every chat sandbox that holds attachments.
  static const String attachmentsDirName = 'attachments';

  static const String _mimeJpeg = 'image/jpeg';
  static const String _mimePng = 'image/png';
  static const String _mimeGif = 'image/gif';
  static const String _mimeWebp = 'image/webp';

  static const Map<String, String> _extToMime = <String, String>{
    'jpg': _mimeJpeg,
    'jpeg': _mimeJpeg,
    'png': _mimePng,
    'gif': _mimeGif,
    'webp': _mimeWebp,
  };

  static const Map<String, String> _mimeToExt = <String, String>{
    _mimeJpeg: 'jpg',
    _mimePng: 'png',
    _mimeGif: 'gif',
    _mimeWebp: 'webp',
  };

  static const XTypeGroup _imageTypeGroup = XTypeGroup(
    label: 'Images',
    mimeTypes: <String>['image/*'],
    extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'gif'],
  );

  static Future<XFile?> _defaultPickImage() =>
      openFile(acceptedTypeGroups: <XTypeGroup>[_imageTypeGroup]);

  /// Standalone default resolver (a private SessionSandbox over the app
  /// documents directory — its one-time legacy import is marker-guarded, so
  /// a second instance is safe). App DI normally wires the SHARED sandbox
  /// instance instead: `AttachmentService(resolveSandboxDir: sandbox.rootFor)`.
  static final SessionSandbox _defaultSandbox = SessionSandbox(
    resolveDocumentsDir: getApplicationDocumentsDirectory,
  );

  /// True when [fileName]'s extension maps to a supported image type.
  /// The composer uses this to route picked files into [optimizeAndStore]
  /// (images get optimized) vs the plain upload copy (everything else).
  static bool looksLikeImage(String fileName) {
    final List<String> parts = fileName.split('.');
    if (parts.length < 2) return false;
    return _extToMime.containsKey(parts.last.toLowerCase());
  }

  static Future<Directory> _defaultSandboxDir(String? sessionId) =>
      _defaultSandbox.rootFor(sessionId);

  /// Picks an image, optimizes it and stores it into the ACTIVE session's
  /// own sandbox. Never throws for expected outcomes — failures come back
  /// as [AttachmentResult.errorType].
  ///
  /// The image picker is a system dialog: the user can switch chats while
  /// it is open. Callers must capture the active sessionId BEFORE awaiting
  /// this method and pass that captured value here, so a mid-pick switch
  /// can never file the image into another chat's workspace.
  Future<AttachmentResult> attachToSession({required String? sessionId}) async {
    // 1) Pick.
    final XFile? picked;
    try {
      picked = await pickImage();
    } catch (error) {
      return AttachmentResult.failure(
        AttachmentErrorType.saveFailed,
        'Image picker failed: $error',
      );
    }
    if (picked == null) {
      return AttachmentResult.failure(
        AttachmentErrorType.cancelled,
        'No image was selected.',
      );
    }
    return optimizeAndStore(sessionId: sessionId, picked: picked);
  }

  /// Optimizes an already-picked image and stores it into the given
  /// session's sandbox (steps 2-5 of the [attachToSession] pipeline).
  /// Exists for callers that own the picker themselves — the composer's
  /// generic attach flow picks ANY file and routes images here, so both
  /// entry points share one optimization + storage path. Never throws for
  /// expected outcomes.
  Future<AttachmentResult> optimizeAndStore({
    required String? sessionId,
    required XFile picked,
  }) async {
    // 2) Cheap size gate before reading the whole file into memory.
    try {
      final int length = await picked.length();
      if (length > maxSourceBytes) return _tooLarge(length);
    } catch (_) {
      // Length probe unavailable — the read below re-checks the size.
    }
    final Uint8List original;
    try {
      original = await _readPicked(picked);
    } catch (error) {
      return AttachmentResult.failure(
        AttachmentErrorType.saveFailed,
        'Could not read the picked file: $error',
      );
    }
    if (original.lengthInBytes > maxSourceBytes) {
      return _tooLarge(original.lengthInBytes);
    }
    if (original.isEmpty) {
      return AttachmentResult.failure(
        AttachmentErrorType.notAnImage,
        '"${_pickedName(picked)}" is empty.',
      );
    }

    // 3) Validate: extension and/or content magic must say "image".
    final String name = _pickedName(picked);
    final String ext = _extensionOf(name);
    final ({bool ok, String ext, String mime, String problem}) checked =
        _validateImage(original, ext);
    if (!checked.ok) {
      return AttachmentResult.failure(
        AttachmentErrorType.notAnImage,
        '"$name" is not a supported image (jpg, jpeg, png, webp, gif): '
        '${checked.problem}',
      );
    }

    // 4) Optimize (or pass small JPEG/PNG through byte-for-byte).
    final Uint8List optimized;
    final String storedExt;
    if (original.lengthInBytes <= copyThroughMaxBytes &&
        (checked.mime == _mimeJpeg || checked.mime == _mimePng)) {
      optimized = original;
      storedExt = checked.ext;
    } else {
      final DownscaledImage down = await downscaleForUpload(
        original,
        maxEdge: maxLongEdge,
        quality: jpegQuality,
      );
      Uint8List candidate = Uint8List.fromList(down.bytes);
      String extOut = _mimeToExt[down.mime] ?? checked.ext;
      if (candidate.lengthInBytes >= original.lengthInBytes) {
        // Re-encoding would not shrink it (e.g. incompressible noise):
        // keep the original bytes instead of storing something bigger.
        candidate = original;
        extOut = checked.ext;
      }
      optimized = candidate;
      storedExt = extOut;
    }

    // 5) Store inside this session's sandbox only.
    final Directory root;
    try {
      root = await resolveSandboxDir(sessionId);
    } catch (error) {
      return AttachmentResult.failure(
        AttachmentErrorType.saveFailed,
        'Could not resolve the chat workspace: $error',
      );
    }
    final String fileName =
        'ATT-${_stamp(DateTime.now())}-${_randomSuffix()}.$storedExt';
    final Directory dir = Directory(
      '${root.path}${Platform.pathSeparator}$attachmentsDirName',
    );
    final File dest = File('${dir.path}${Platform.pathSeparator}$fileName');
    try {
      await dir.create(recursive: true);
      await dest.writeAsBytes(optimized, flush: true);
    } catch (error) {
      return AttachmentResult.failure(
        AttachmentErrorType.saveFailed,
        'Could not store the attachment: $error',
      );
    }

    return AttachmentResult._(
      relativePath: '$attachmentsDirName/$fileName',
      absolutePath: dest.path,
      bytes: optimized,
      originalBytes: original.lengthInBytes,
    );
  }

  AttachmentResult _tooLarge(int length) => AttachmentResult.failure(
    AttachmentErrorType.tooLarge,
    'Image is ${(length / (1024 * 1024)).toStringAsFixed(1)} MB — '
    'the limit is ${maxSourceBytes ~/ (1024 * 1024)} MB.',
  );

  Future<Uint8List> _readPicked(XFile picked) async {
    if (picked.path.isEmpty) return picked.readAsBytes();
    return File(picked.path).readAsBytes();
  }

  String _pickedName(XFile picked) {
    final String name = picked.name;
    if (name.isNotEmpty) return name;
    return picked.path.split(Platform.pathSeparator).last;
  }

  String _extensionOf(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// Extension/mime agreement check. Returns the NORMALIZED storage
  /// extension (jpeg -> jpg) plus the content mime, or ok:false with a
  /// human-readable [problem].
  ({bool ok, String ext, String mime, String problem}) _validateImage(
    Uint8List bytes,
    String ext,
  ) {
    final String sniffed = mimeFromBytes(bytes);
    final String? claimed = _extToMime[ext];
    if (claimed != null) {
      if (sniffed == claimed) {
        return (
          ok: true,
          ext: ext == 'jpeg' ? 'jpg' : ext,
          mime: claimed,
          problem: '',
        );
      }
      return (
        ok: false,
        ext: ext,
        mime: sniffed,
        problem: sniffed == 'application/octet-stream'
            ? 'the file content is not a valid image'
            : 'the content is $sniffed but the name suggests $claimed',
      );
    }
    final String? contentExt = _mimeToExt[sniffed];
    if (contentExt != null) {
      // Unknown/missing extension but the content is a supported image:
      // trust the content and store it under the true extension.
      return (ok: true, ext: contentExt, mime: sniffed, problem: '');
    }
    return (
      ok: false,
      ext: ext,
      mime: sniffed,
      problem: 'unsupported type "${ext.isEmpty ? 'no extension' : '.$ext'}"',
    );
  }

  /// `yyyyMMdd-HHmmss` for the ATT- filename.
  String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}'
        '${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  String _randomSuffix() {
    const String chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final Random rng = Random.secure();
    return List<String>.generate(
      4,
      (_) => chars[rng.nextInt(chars.length)],
    ).join();
  }
}
