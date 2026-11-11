import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

/// Exports a chat's private workspace folder to the DEVICE file manager
/// (v1.29.0) — "every chat has its own folder".
///
/// * Android 10+ (API 29): the folder tree is copied into
///   `Download/Noah/<folder>/` through MediaStore — no storage
///   permission needed, visible in any Files app under Downloads.
/// * Older Android: the whole workspace is zipped (into the app's
///   exports dir) and handed to the share sheet, so the user can save
///   it anywhere. Reported as [SharedZipExport].
class DeviceExportService {
  DeviceExportService({MethodInvoker? invoke})
    : _invoke = invoke ?? _defaultInvoke;

  /// Invoker for the platform channel — injectable for tests.
  final MethodInvoker _invoke;

  static const MethodChannel _channel = MethodChannel('zagents/background');

  static Future<Object?> _defaultInvoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) => _channel.invokeMethod(method, arguments);

  /// Exports [root]'s file tree. Returns a [MediaStoreExport] on Android
  /// 10+, or a [SharedZipExport] on older versions (the caller opens the
  /// share sheet). Throws [ExportTooLargeException] beyond the caps and
  /// [ExportFailedException] when nothing could be exported.
  Future<DeviceExportResult> exportChatFolder({
    required String folderName,
    required Directory root,
  }) async {
    final List<ExportFile> files = await collectFiles(root);
    final int? sdk = await _invoke('getSdkInt') as int?;
    if (sdk != null && sdk >= 29) {
      final int? count = await _invoke('exportChatFolder', <String, dynamic>{
        'name': folderName,
        'files': <Map<String, String>>[
          for (final ExportFile f in files)
            <String, String>{'rel': f.rel, 'abs': f.abs},
        ],
      }) as int?;
      if (count == null || count <= 0) {
        throw ExportFailedException(
          count == null ? 'channel returned null' : 'no file exported',
        );
      }
      return MediaStoreExport(fileCount: count, folder: folderName);
    }
    return _zipFallback(folderName, root);
  }

  /// Pre-Android-10 fallback: zip the whole workspace into the app's
  /// exports directory and let the caller share it.
  Future<SharedZipExport> _zipFallback(
    String folderName,
    Directory root,
  ) async {
    final List<ExportFile> files = await collectFiles(root);
    final Archive archive = Archive();
    for (final ExportFile f in files) {
      final List<int> bytes = await File(f.abs).readAsBytes();
      archive.addFile(ArchiveFile('$folderName/${f.rel}', bytes.length, bytes));
    }
    final List<int> encoded = ZipEncoder().encode(archive);
    final Directory exports = Directory(
      '${root.path}${Platform.pathSeparator}..'
      '${Platform.pathSeparator}exports',
    );
    if (!exports.existsSync()) exports.createSync(recursive: true);
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final File out = File(
      '${exports.path}${Platform.pathSeparator}'
      'chat-folder-$folderName-$stamp.zip',
    );
    await out.writeAsBytes(encoded);
    return SharedZipExport(zipPath: out.path, fileCount: files.length);
  }
}

/// Platform-channel invoker signature (test seam).
typedef MethodInvoker = Future<Object?> Function(
  String method, [
  Map<String, dynamic>? arguments,
]);

/// One file of the workspace: [rel] is the posix-style path inside the
/// chat folder, [abs] the absolute source path.
class ExportFile {
  const ExportFile({required this.rel, required this.abs, required this.size});
  final String rel;
  final String abs;
  final int size;
}

/// Hard caps so a runaway workspace can never freeze the export.
const int kExportMaxFiles = 2000;
const int kExportMaxTotalBytes = 512 * 1024 * 1024;

/// Walks [root] recursively (links not followed) and returns every file
/// as posix-relative paths, deterministically sorted. Throws
/// [ExportTooLargeException] when the file-count or size caps are hit.
Future<List<ExportFile>> collectFiles(Directory root) async {
  final String rootPath = await root.resolveSymbolicLinks();
  final List<ExportFile> out = <ExportFile>[];
  int total = 0;
  final List<Directory> stack = <Directory>[root];
  while (stack.isNotEmpty) {
    final Directory dir = stack.removeLast();
    final List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(followLinks: false);
    } catch (_) {
      continue; // unreadable subfolder: skip, export the rest
    }
    for (final FileSystemEntity entity in entities) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue; // hidden internals stay internal
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        stack.add(Directory(entity.path));
        continue;
      }
      if (type != FileSystemEntityType.file) continue;
      if (out.length >= kExportMaxFiles) {
        throw ExportTooLargeException('more than $kExportMaxFiles files');
      }
      final int size = File(entity.path).lengthSync();
      total += size;
      if (total > kExportMaxTotalBytes) {
        throw ExportTooLargeException('workspace larger than 512 MB');
      }
      out.add(
        ExportFile(
          rel: _posixRelative(entity.path, rootPath),
          abs: entity.path,
          size: size,
        ),
      );
    }
  }
  out.sort((ExportFile a, ExportFile b) => a.rel.compareTo(b.rel));
  return out;
}

String _posixRelative(String path, String rootPath) {
  String rel = path.startsWith(rootPath)
      ? path.substring(rootPath.length)
      : path;
  rel = rel.replaceAll(Platform.pathSeparator, '/');
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

/// Builds the device folder name for a chat: the (sanitized) chat title
/// plus a short session-id suffix so two same-titled chats never merge.
String deviceFolderName(String title, String sessionId) {
  String clean = title.replaceAll(RegExp(r'[^\w \-()]+'), '_').trim();
  clean = clean.replaceAll(RegExp(r'\s+'), ' ');
  if (clean.length > 40) clean = clean.substring(0, 40).trim();
  String suffix = sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  suffix = suffix.length > 6 ? suffix.substring(0, 6) : suffix;
  if (clean.isEmpty) clean = 'chat';
  return '$clean-$suffix';
}

/// Result of a chat-folder export.
sealed class DeviceExportResult {
  const DeviceExportResult();
  int get fileCount;
}

/// Copied into `Download/Noah/<folder>/` via MediaStore.
class MediaStoreExport extends DeviceExportResult {
  const MediaStoreExport({required this.fileCount, required this.folder});
  @override
  final int fileCount;
  final String folder;
}

/// Zipped + handed to the share sheet (pre-Android-10 fallback).
class SharedZipExport extends DeviceExportResult {
  const SharedZipExport({required this.zipPath, required this.fileCount});
  final String zipPath;
  @override
  final int fileCount;
}

class ExportTooLargeException implements Exception {
  const ExportTooLargeException(this.reason);
  final String reason;
  @override
  String toString() => 'Export too large: $reason';
}

class ExportFailedException implements Exception {
  const ExportFailedException(this.reason);
  final String reason;
  @override
  String toString() => 'Export failed: $reason';
}
