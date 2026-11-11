import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../models/local_model.dart';

const Uuid _uuid = Uuid();

/// Size of one file chunk fed to the streaming sha256 sink (64 KiB keeps
/// memory flat for multi-GB GGUFs).
const int _hashChunkBytes = 64 * 1024;

/// Joins [dir] and [name] with the platform separator (session_export
/// style — no package:path dependency).
String _join(String dir, String name) => '$dir${Platform.pathSeparator}$name';

/// Resolves the default local-models directory — v1.51.0:
/// `<external-storage>/local_models` when the platform provides an
/// external app directory (Android), else `<app-documents>/local_models`
/// (other platforms / degraded storage). Shared by the downloader, the
/// importer and the store so every feature writes to the same folder.
Future<Directory> resolveLocalModelsDir() async {
  Directory? base;
  try {
    base = await getExternalStorageDirectory();
  } catch (_) {
    // No external storage (or no platform channel in unit tests):
    // fall through to the app documents directory.
  }
  base ??= await getApplicationDocumentsDirectory();
  return Directory(_join(base.path, 'local_models'));
}

/// Collects the single digest produced by a chunked hash conversion.
class _DigestSink implements Sink<Digest> {
  final List<Digest> events = <Digest>[];

  @override
  void add(Digest data) => events.add(data);

  @override
  void close() {}
}

/// Streams [file] through sha256 in [_hashChunkBytes]-sized chunks and
/// returns the lowercase hex digest — a multi-GB GGUF must never be
/// loaded into memory just to be fingerprinted.
Future<String> _sha256OfFile(File file) async {
  final _DigestSink sink = _DigestSink();
  final Sink<List<int>> hasher = sha256.startChunkedConversion(sink);
  final RandomAccessFile reader = await file.open();
  try {
    await reader.setPosition(0);
    while (true) {
      final List<int> chunk = await reader.read(_hashChunkBytes);
      if (chunk.isEmpty) break;
      hasher.add(chunk);
    }
  } finally {
    await reader.close();
  }
  hasher.close();
  return sink.events.single.toString();
}

/// File-level helper for local models — v1.51.0: import a picked GGUF
/// into the models dir, export one (or all) through the share sheet,
/// delete the backing file. Pure dart:io + share_plus; the models
/// directory is injectable so unit tests never touch path_provider.
class LocalModelIo {
  LocalModelIo({Directory? modelsDir, this.resolveTmpDir})
    : _injectedDir = modelsDir;

  final Directory? _injectedDir;

  /// Temporary directory used to stage share-sheet copies; defaults to
  /// the platform temp dir (lazily — only touched inside export calls).
  final Future<Directory> Function()? resolveTmpDir;

  Directory? _resolvedDir;

  Future<Directory> _modelsDir() async {
    _resolvedDir ??= _injectedDir ?? await resolveLocalModelsDir();
    return _resolvedDir!;
  }

  Future<Directory> _tmpDir() async {
    if (resolveTmpDir != null) return resolveTmpDir!();
    return getTemporaryDirectory();
  }

  /// Copies a user-picked GGUF ([sourcePath]) into the models dir under
  /// a fresh uuid file name and returns the persisted entry (uuid id,
  /// display name derived from [fileNameHint] minus a trailing `.gguf`,
  /// size + streaming sha256 stamped). Returns null when the source is
  /// missing or the copy fails — the caller shows a snackbar, import
  /// must never half-write an entry.
  Future<LocalModelEntry?> importFromFile({
    required String sourcePath,
    required String fileNameHint,
  }) async {
    try {
      final File source = File(sourcePath);
      if (!await source.exists()) return null;
      final Directory dir = await _modelsDir();
      await dir.create(recursive: true);
      final String id = _uuid.v4();
      String name = fileNameHint.trim();
      if (name.toLowerCase().endsWith('.gguf')) {
        name = name.substring(0, name.length - '.gguf'.length).trim();
      }
      if (name.isEmpty) name = 'Imported model';
      final String fileName = '$id.gguf';
      final File dest = File(_join(dir.path, fileName));
      await source.copy(dest.path);
      final int size = await dest.length();
      final String sha = await _sha256OfFile(dest);
      return LocalModelEntry(
        id: id,
        name: name,
        source: LocalModelSource.imported,
        fileName: fileName,
        sizeBytes: size,
        sha256: sha,
        addedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // Missing source, unwritable dir, vanished file: no entry.
      return null;
    }
  }

  /// Exports one model through the share sheet (session_export pattern:
  /// copy into the tmp dir first — share sheets need a plain file path
  /// and the models dir may be app-private). Returns false when the
  /// model file is missing or sharing fails.
  Future<bool> exportModel(LocalModelEntry entry) async {
    try {
      final Directory modelsDir = await _modelsDir();
      final File source = File(_join(modelsDir.path, entry.fileName));
      if (!await source.exists()) return false;
      final Directory tmp = await _tmpDir();
      await tmp.create(recursive: true);
      final File staged = File(_join(tmp.path, _exportFileName(entry)));
      await source.copy(staged.path);
      final ShareResult result = await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(staged.path)]),
      );
      return result.status == ShareResultStatus.success;
    } catch (_) {
      // Missing file or a dismissed/broken share sheet: not an error.
      return false;
    }
  }

  /// Fase 2 bulk export — stages every model file and hands them ALL to
  /// a single share sheet. Returns the number of models actually staged
  /// and shared (0 when nothing could be exported or sharing failed).
  Future<int> exportModels(List<LocalModelEntry> entries) async {
    try {
      final Directory modelsDir = await _modelsDir();
      final Directory tmp = await _tmpDir();
      await tmp.create(recursive: true);
      final List<XFile> staged = <XFile>[];
      for (final LocalModelEntry entry in entries) {
        final File source = File(_join(modelsDir.path, entry.fileName));
        if (!await source.exists()) continue;
        final File copy = File(_join(tmp.path, _exportFileName(entry)));
        await source.copy(copy.path);
        staged.add(XFile(copy.path));
      }
      if (staged.isEmpty) return 0;
      final ShareResult result = await SharePlus.instance.share(
        ShareParams(files: staged),
      );
      return result.status == ShareResultStatus.success ? staged.length : 0;
    } catch (_) {
      // Bulk export is best-effort: a failure exports nothing.
      return 0;
    }
  }

  /// Deletes the backing GGUF of [entry] (best-effort — removing the
  /// entry from the store must succeed even when the file is already
  /// gone or the storage is unwritable).
  Future<void> deleteModelFile(LocalModelEntry entry) async {
    try {
      final Directory dir = await _modelsDir();
      final File file = File(_join(dir.path, entry.fileName));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort: the store entry is removed regardless.
    }
  }

  /// Share-sheet file name: `<name>.gguf`, deduplicated with a short id
  /// suffix so two same-named exports never overwrite each other in the
  /// staging dir.
  static String _exportFileName(LocalModelEntry entry) {
    final String clean = entry.name.trim().isEmpty
        ? 'model'
        : entry.name.trim();
    final String safe = clean.replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '_');
    final String suffix = entry.id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    return '$safe-${suffix.length > 6 ? suffix.substring(0, 6) : suffix}.gguf';
  }
}
