import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';

/// One entry in the app's file workspace.
class FsEntry {
  const FsEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modified,
  });

  final String name;
  final String relativePath;
  final bool isDirectory;
  final int sizeBytes;
  final DateTime modified;

  String get extension => name.contains('.') && !isDirectory
      ? name.split('.').last.toLowerCase()
      : '';
}

/// Thrown when an archive is encrypted (ZipCrypto or WinZip AES) and no
/// password was supplied to [FileSystemService.unzip].
class ZipPasswordRequiredException implements Exception {
  const ZipPasswordRequiredException(this.filename);

  final String filename;

  @override
  String toString() => 'ZipPasswordRequiredException: $filename';
}

/// Thrown when the supplied password does not decrypt the archive.
class ZipWrongPasswordException implements Exception {
  const ZipWrongPasswordException();

  @override
  String toString() => 'ZipWrongPasswordException';
}

/// All file-management operations for the in-app File Manager and the
/// zip/unzip features. Every path is sandboxed under the app documents
/// directory — traversal attempts are rejected.
class FileSystemService {
  FileSystemService({required this.resolveBaseDir, this.offloadIsolate = true});

  /// Where per-chat workspace roots resolve from.
  final Future<Directory> Function() resolveBaseDir;

  /// v1.34.0 ANR hardening: deflate/inflate (zip/unzip) is pure-CPU work
  /// that used to run on the UI isolate — a multi-MB archive froze the
  /// whole app for seconds. When true the archive encode/decode runs in
  /// a short-lived worker isolate. Test doubles / widget tests pass
  /// false (real isolate replies never arrive inside a FakeAsync zone).
  final bool offloadIsolate;

  /// Runs [work] off the main isolate when enabled, synchronously (in a
  /// future) otherwise — the result is identical either way.
  Future<T> _maybeIsolate<T>(T Function() work) =>
      offloadIsolate ? Isolate.run(work) : Future<T>.value(work());

  Future<String> _root() async => (await resolveBaseDir()).path;

  /// Resolves [relative] under the root, rejecting traversal. Dot segments
  /// (`..`, `.`) are normalized the same way the tool executor does it.
  Future<String?> resolve(String relative) async {
    final String root = await _root();
    if (relative.trim().isEmpty || relative == '.' || relative == '/') {
      return root;
    }
    try {
      final String normalizedRoot = root.endsWith(Platform.pathSeparator)
          ? root
          : '$root${Platform.pathSeparator}';
      final String resolved = Directory(normalizedRoot).uri
          .resolve(relative)
          .toFilePath();
      if (!resolved.startsWith(normalizedRoot)) return null;
      return resolved;
    } catch (_) {
      return null;
    }
  }

  /// Lists entries of [relative] directory (names, sizes, mtimes), sorted
  /// folders-first then alphabetically.
  Future<List<FsEntry>> list(String relative) async {
    final String? dirPath = await resolve(relative);
    if (dirPath == null) return const <FsEntry>[];
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) return const <FsEntry>[];
    final List<FsEntry> out = <FsEntry>[];
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue; // hidden/internal files
      try {
        final FileStat stat = entity.statSync();
        final bool isDir = stat.type == FileSystemEntityType.directory;
        final String rel = relative.trim().isEmpty || relative == '.'
            ? name
            : '$relative${Platform.pathSeparator}$name';
        out.add(
          FsEntry(
            name: name,
            relativePath: rel,
            isDirectory: isDir,
            sizeBytes: isDir ? 0 : stat.size,
            modified: stat.modified,
          ),
        );
      } catch (_) {
        // Unreadable entry: skip, never crash the manager.
      }
    }
    out.sort((FsEntry a, FsEntry b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<bool> exists(String relative) async {
    final String? path = await resolve(relative);
    return path != null &&
        FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  }

  Future<void> mkdir(String relative) async {
    final String? path = await resolve(relative);
    if (path == null) throw const FileSystemException('Invalid path');
    await Directory(path).create(recursive: true);
  }

  Future<void> rename(String relative, String newName) async {
    final String? path = await resolve(relative);
    if (path == null) throw const FileSystemException('Invalid path');
    if (newName.contains('/') ||
        newName.contains('\\') ||
        newName.trim().isEmpty) {
      throw const FileSystemException('Invalid name');
    }
    final FileSystemEntity entity =
        FileSystemEntity.typeSync(path) == FileSystemEntityType.directory
        ? Directory(path)
        : File(path);
    final String parent = path.substring(
      0,
      path.lastIndexOf(Platform.pathSeparator),
    );
    await entity.rename('$parent${Platform.pathSeparator}$newName');
  }

  Future<void> delete(String relative) async {
    final String? path = await resolve(relative);
    if (path == null) throw const FileSystemException('Invalid path');
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return;
    final FileSystemEntity entity = type == FileSystemEntityType.directory
        ? Directory(path)
        : File(path);
    await entity.delete(recursive: true);
  }

  /// Copies a file or a whole directory (recursive). [destRelative] is the
  /// full destination path (file name for files).
  Future<void> copy(String srcRelative, String destRelative) async {
    final String? src = await resolve(srcRelative);
    final String? dest = await resolve(destRelative);
    if (src == null || dest == null) {
      throw const FileSystemException('Invalid path');
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(src);
    if (type == FileSystemEntityType.directory) {
      await _copyDir(Directory(src), Directory(dest));
    } else if (type == FileSystemEntityType.file) {
      await File(src).parent.create(recursive: true);
      await File(src).copy(dest);
    } else {
      throw const FileSystemException('Source not found');
    }
  }

  /// Moves (cut+paste) a file or directory.
  Future<void> move(String srcRelative, String destRelative) async {
    final String? src = await resolve(srcRelative);
    final String? dest = await resolve(destRelative);
    if (src == null || dest == null) {
      throw const FileSystemException('Invalid path');
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(src);
    if (type == FileSystemEntityType.notFound) {
      throw const FileSystemException('Source not found');
    }
    await File(dest).parent.create(recursive: true);
    final FileSystemEntity entity = type == FileSystemEntityType.directory
        ? Directory(src)
        : File(src);
    try {
      await entity.rename(dest);
    } on FileSystemException {
      // Cross-container rename fallback: copy + delete.
      if (type == FileSystemEntityType.directory) {
        await _copyDir(Directory(src), Directory(dest));
        await Directory(src).delete(recursive: true);
      } else {
        await File(src).copy(dest);
        await File(src).delete();
      }
    }
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final FileSystemEntity entity in from.list(followLinks: false)) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      final String destPath = '${to.path}${Platform.pathSeparator}$name';
      final FileSystemEntityType type = FileSystemEntity.typeSync(entity.path);
      if (type == FileSystemEntityType.directory) {
        await _copyDir(entity as Directory, Directory(destPath));
      } else if (type == FileSystemEntityType.file) {
        await (entity as File).copy(destPath);
      }
    }
  }

  /// Compresses a file or directory into `<name>.zip` next to it.
  /// Returns the zip's relative path.
  Future<String> zip(String srcRelative) async {
    final String? src = await resolve(srcRelative);
    if (src == null) throw const FileSystemException('Invalid path');
    final FileSystemEntityType type = FileSystemEntity.typeSync(src);
    if (type == FileSystemEntityType.notFound) {
      throw const FileSystemException('Source not found');
    }
    final bool isDir = type == FileSystemEntityType.directory;
    final String baseName = src.split(Platform.pathSeparator).last;
    // v1.34.0: gather the raw bytes on the main isolate (async IO) and
    // build + deflate the archive in a worker isolate — ZipEncoder used
    // to block the UI for the whole compression.
    final Map<String, List<int>> entries = <String, List<int>>{};
    final Map<String, int> mtimes = <String, int>{};
    if (isDir) {
      await for (final FileSystemEntity entity in Directory(
        src,
      ).list(recursive: true, followLinks: false)) {
        final FileSystemEntityType t = FileSystemEntity.typeSync(entity.path);
        // Entries are stored relative to the compressed folder itself so
        // extracting proj.zip yields proj_extracted/a.txt (no double nest).
        final String relInZip = entity.path
            .substring(src.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        if (t == FileSystemEntityType.file) {
          final File file = entity as File;
          final List<int> bytes = await file.readAsBytes();
          entries[relInZip] = bytes;
          mtimes[relInZip] = file.lastModifiedSync().millisecondsSinceEpoch;
        }
      }
    } else {
      entries[baseName] = await File(src).readAsBytes();
    }
    final List<int> encoded = await _maybeIsolate(() {
      final Archive archive = Archive();
      for (final MapEntry<String, List<int>> entry in entries.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value)
            ..lastModTime = mtimes[entry.key] ?? 0,
        );
      }
      return ZipEncoder().encode(archive);
    });
    final String zipPath = '$src.zip';
    await File(zipPath).writeAsBytes(encoded);
    final String root = await _root();
    return zipPath.startsWith(root)
        ? zipPath.substring(root.length + 1)
        : zipPath;
  }

  /// Extracts [zipRelative] into a sibling folder named after the archive
  /// (or [destName]). Returns the destination's relative path.
  ///
  /// Encrypted archives (legacy ZipCrypto and WinZip AES-128/192/256) are
  /// decrypted with [password]. Passing no password to an encrypted archive
  /// throws [ZipPasswordRequiredException]; a wrong password throws
  /// [ZipWrongPasswordException].
  Future<String> unzip(
    String zipRelative, {
    String? destName,
    String? password,
  }) async {
    final String? zipPath = await resolve(zipRelative);
    if (zipPath == null) throw const FileSystemException('Invalid path');
    final List<int> bytes = await File(zipPath).readAsBytes();
    // The archive package decrypts lazily: encryption problems surface
    // while entries are read, not only during decodeBytes. v1.34.0: the
    // whole decode + entry-read + decrypt runs in a worker isolate —
    // inflate/AES on a big archive used to freeze the UI — and only the
    // plain (name → bytes) map crosses back for async file writes.
    final bool hasPassword = password != null && password.isNotEmpty;
    final Object? extracted = await _maybeIsolate(() {
      try {
        final Archive archive = ZipDecoder().decodeBytes(
          bytes,
          password: hasPassword ? password : null,
        );
        final Map<String, List<int>> files = <String, List<int>>{};
        final List<String> dirs = <String>[];
        for (final ArchiveFile file in archive.files) {
          if (file.isFile) {
            files[file.name] = (file.content as List<int>).toList();
          } else {
            dirs.add(file.name);
          }
        }
        return <String, Object>{'ok': true, 'files': files, 'dirs': dirs};
      } on ArchiveException catch (error) {
        // The archive package reports encryption problems through message
        // text only; map them onto markers the main isolate rethrows as
        // typed exceptions (custom archive types are not isolate-safe).
        final String message = error.message;
        if (message.contains('A password is needed')) {
          return <String, Object>{'ok': false, 'kind': 'password_needed'};
        }
        if (message.contains('Wrong password')) {
          return <String, Object>{'ok': false, 'kind': 'wrong_password'};
        }
        return <String, Object>{
          'ok': false,
          'kind': 'archive',
          'message': message,
        };
      }
    });
    final Map<Object?, Object?> result = extracted is Map
        ? extracted.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    if (result['ok'] != true) {
      switch (result['kind']) {
        case 'password_needed':
          throw ZipPasswordRequiredException(
            zipPath.split(Platform.pathSeparator).last,
          );
        case 'wrong_password':
          throw const ZipWrongPasswordException();
        default:
          throw const FileSystemException('Corrupted archive');
      }
    }
    final Map<String, List<int>> rawFiles = (result['files'] as Map)
        .cast<String, List<int>>();
    final List<String> rawDirs = (result['dirs'] as List).cast<String>();
    // SECURITY (v1.41.0): entry names are attacker-controlled. They used
    // to be concatenated straight onto the destination folder, so a name
    // like `../../databases/app.db` wrote OUTSIDE it (zip-slip) — for a
    // file the user merely attached that is an arbitrary write in the app
    // sandbox. The whole listing is validated BEFORE anything is created,
    // so a hostile archive extracts nothing at all.
    final Map<String, List<int>> files = <String, List<int>>{};
    for (final MapEntry<String, List<int>> entry in rawFiles.entries) {
      final String? safe = _safeArchiveEntry(entry.key);
      if (safe == null) {
        throw const FileSystemException('Archive contains an unsafe path');
      }
      if (safe.isNotEmpty) files[safe] = entry.value;
    }
    final List<String> dirs = <String>[];
    for (final String name in rawDirs) {
      final String? safe = _safeArchiveEntry(name);
      if (safe == null) {
        throw const FileSystemException('Archive contains an unsafe path');
      }
      if (safe.isNotEmpty) dirs.add(safe);
    }
    final String zipName = zipPath.split(Platform.pathSeparator).last;
    final String parentDir = zipPath.substring(
      0,
      zipPath.lastIndexOf(Platform.pathSeparator),
    );
    String folderName =
        destName ??
        (zipName.toLowerCase().endsWith('.zip')
            ? zipName.substring(0, zipName.length - 4)
            : '${zipName}_extracted');
    // Never collide with an existing entry next to the archive (e.g.
    // extracting proj.zip next to the original proj/ folder).
    if (FileSystemEntity.typeSync(
          '$parentDir${Platform.pathSeparator}$folderName',
        ) !=
        FileSystemEntityType.notFound) {
      folderName = '${folderName}_extracted';
    }
    final Directory dest = Directory(
      '$parentDir${Platform.pathSeparator}$folderName',
    );
    await dest.create(recursive: true);
    for (final String dirName in dirs) {
      await Directory(
        '${dest.path}${Platform.pathSeparator}${dirName.replaceAll('/', Platform.pathSeparator)}',
      ).create(recursive: true);
    }
    for (final MapEntry<String, List<int>> file in files.entries) {
      final File outFile = File(
        '${dest.path}${Platform.pathSeparator}${file.key.replaceAll('/', Platform.pathSeparator)}',
      );
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.value);
    }
    final String root = await _root();
    return dest.path.startsWith(root)
        ? dest.path.substring(root.length + 1)
        : dest.path;
  }

  /// Normalises one archive entry name, or returns null when it must be
  /// refused (v1.41.0, zip-slip defence).
  ///
  /// Accepted: `a/b.txt`, `./a/b.txt`, `a//b.txt`, backslash separators.
  /// Refused: absolute paths, any `..` segment, drive letters / `:` and
  /// NUL bytes. Returns '' for a name that normalises to nothing (a bare
  /// `./` or `/` entry).
  static String? _safeArchiveEntry(String name) {
    if (name.contains('\u0000')) return null;
    final String cleaned = name.replaceAll('\\', '/');
    if (cleaned.startsWith('/')) return null;
    final List<String> parts = <String>[];
    for (final String part in cleaned.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') return null;
      if (part.contains(':')) return null;
      parts.add(part);
    }
    return parts.join('/');
  }

  /// Reads a text preview (max [maxChars]) of a file.
  Future<String> readText(String relative, {int maxChars = 20000}) async {
    final String? path = await resolve(relative);
    if (path == null) throw const FileSystemException('Invalid path');
    final String content = await File(path).readAsString();
    return content.length > maxChars ? content.substring(0, maxChars) : content;
  }
}
