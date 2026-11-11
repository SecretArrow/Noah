import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'remote_guard.dart';

/// A module installed in the app's `node_modules` folder.
class InstalledModule {
  const InstalledModule({
    required this.name,
    required this.version,
    required this.path,
  });

  final String name;
  final String version;
  final String path;
}

/// Result of an npm install operation.
class NpmInstallResult {
  const NpmInstallResult({
    required this.ok,
    required this.message,
    this.installed = const <String>[],
  });

  final bool ok;
  final String message;

  /// Every package written to disk (name@version), dependencies included.
  final List<String> installed;
}

/// Manages Node.js modules for the embedded JS runtime, "auto add/remove
/// as needed":
///  * [install] downloads a package tarball from the npm registry, unpacks
///    it into `<docs>/node_modules/<name>` and recursively installs the
///    runtime dependencies declared in its package.json.
///  * [remove] deletes a package directory.
///  * [search] queries the public registry search API.
///
/// The registry host is injectable so unit tests run fully offline.
class NpmService {
  NpmService({
    required this.resolveBaseDir,
    http.Client? client,
    this.registryHost = 'registry.npmjs.org',
  }) : _client = client ?? http.Client();

  final Future<Directory> Function() resolveBaseDir;
  final http.Client _client;
  final String registryHost;

  static const int _maxDepth = 6;

  /// Registry metadata is small; a package tarball can legitimately be tens of
  /// megabytes, but never unbounded.
  static const int _maxMetadataBytes = 8 * 1024 * 1024;
  static const int _maxTarballBytes = 64 * 1024 * 1024;
  static const int _maxUnpackedBytes = 128 * 1024 * 1024;
  static const int _maxFiles = 4000;

  Directory? _modulesDirCache;

  /// `<docs>/node_modules` (created on demand).
  Future<Directory> modulesDir() async {
    if (_modulesDirCache != null) return _modulesDirCache!;
    final Directory base = await resolveBaseDir();
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}node_modules',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _modulesDirCache = dir;
    return dir;
  }

  /// Lists installed top-level packages (name@version).
  Future<List<InstalledModule>> listInstalled() async {
    final Directory dir = await modulesDir();
    final List<InstalledModule> out = <InstalledModule>[];
    if (!dir.existsSync()) return out;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! Directory) continue;
      final String folder = entity.path.split(Platform.pathSeparator).last;
      if (folder.startsWith('.')) continue;
      if (folder.startsWith('@')) {
        // Scoped packages: @scope/pkg
        await for (final FileSystemEntity inner in entity.list()) {
          if (inner is! Directory) continue;
          final InstalledModule? mod = await _readModule(inner);
          if (mod != null) {
            out.add(
              InstalledModule(
                name: '$folder/${mod.name}',
                version: mod.version,
                path: mod.path,
              ),
            );
          }
        }
        continue;
      }
      final InstalledModule? mod = await _readModule(entity);
      if (mod != null) out.add(mod);
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  Future<InstalledModule?> _readModule(Directory dir) async {
    final File pkgJson = File(
      '${dir.path}${Platform.pathSeparator}package.json',
    );
    if (!pkgJson.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(pkgJson.readAsStringSync());
      if (decoded is! Map) return null;
      final Object? name = decoded['name'];
      final Object? version = decoded['version'];
      return InstalledModule(
        name: name?.toString() ?? dir.path.split(Platform.pathSeparator).last,
        version: version?.toString() ?? '?',
        path: dir.path,
      );
    } catch (_) {
      return null;
    }
  }

  /// Installs [name] (optionally at [version]) plus its runtime
  /// dependencies. Pure-JS packages only — native addons cannot run inside
  /// the embedded runtime and are skipped with a warning.
  Future<NpmInstallResult> install(String name, {String? version}) async {
    final String pkg = name.trim();
    if (pkg.isEmpty) {
      return const NpmInstallResult(ok: false, message: 'Package name empty');
    }
    if (!isValidPackageName(pkg)) {
      return NpmInstallResult(
        ok: false,
        message: 'Invalid package name: "$pkg"',
      );
    }
    try {
      final List<String> installed = <String>[];
      await _installWithDeps(pkg, version, installed, 0);
      return NpmInstallResult(
        ok: true,
        message: 'Installed ${installed.join(', ')}',
        installed: installed,
      );
    } catch (e) {
      return NpmInstallResult(ok: false, message: 'Install failed: $e');
    }
  }

  Future<void> _installWithDeps(
    String name,
    String? version,
    List<String> installed,
    int depth,
  ) async {
    if (depth > _maxDepth) return;
    final Directory modules = await modulesDir();
    final String target = '${modules.path}${Platform.pathSeparator}$name';
    if (Directory(target).existsSync()) {
      return; // Already present (satisfied by an earlier install).
    }

    // 1. Resolve metadata.
    final String metaPath = version == null || version.trim().isEmpty
        ? '/$name'
        : '/$name/$version';
    final List<int> metaBytes;
    try {
      metaBytes = await RemoteGuard.download(
        _client,
        Uri.https(registryHost, metaPath),
        headers: const <String, String>{'Accept': 'application/json'},
        maxBytes: _maxMetadataBytes,
        timeout: const Duration(seconds: 30),
      );
    } on RemoteGuardException catch (e) {
      throw 'registry lookup for "$name" failed: ${e.message}';
    }
    final Object? decodedMeta = jsonDecode(utf8.decode(metaBytes));
    if (decodedMeta is! Map) throw 'unexpected registry payload for "$name"';

    // Dist-tags resolve through the full metadata document.
    String resolvedVersion = version ?? '';
    Object? meta = decodedMeta;
    if (resolvedVersion.isEmpty) {
      final Object? distTags = (meta as Map)['dist-tags'];
      if (distTags is Map && distTags['latest'] != null) {
        resolvedVersion = distTags['latest'].toString();
      }
      final Object? versions = meta['versions'];
      if (versions is Map && versions[resolvedVersion] is Map) {
        meta = versions[resolvedVersion] as Map;
      }
    }
    final Object? dist = (meta as Map)['dist'];
    final Object? tarballUrl = dist is Map ? dist['tarball'] : null;
    if (tarballUrl is! String || tarballUrl.isEmpty) {
      throw 'no tarball found for "$name@$resolvedVersion"';
    }

    // 2. Download + unpack into a temp dir, then move into node_modules.
    final List<int> tarBytes;
    try {
      tarBytes = await RemoteGuard.download(
        _client,
        Uri.parse(tarballUrl),
        maxBytes: _maxTarballBytes,
      );
    } on RemoteGuardException catch (e) {
      throw 'tarball download for "$name" failed: ${e.message}';
    }
    final Archive archive = TarDecoder().decodeBytes(
      GZipDecoder().decodeBytes(tarBytes),
    );
    // Every entry is validated BEFORE anything is written: a hostile tarball
    // could otherwise use `../` names to escape node_modules (the old
    // `extractArchiveToDisk` wrote whatever path the archive declared).
    final List<ArchiveFile> entries = <ArchiveFile>[];
    int unpacked = 0;
    for (final ArchiveFile entry in archive.files) {
      if (!entry.isFile) continue;
      final String rel = entry.name.replaceAll('\\', '/');
      if (!_isSafeEntryPath(rel)) {
        throw 'unsafe path in package tarball: ${entry.name}';
      }
      unpacked += entry.size;
      if (unpacked > _maxUnpackedBytes) {
        throw 'package "$name" unpacks to more than 128 MB';
      }
      if (entries.length >= _maxFiles) {
        throw 'package "$name" contains more than $_maxFiles files';
      }
      entries.add(entry);
    }
    final Directory temp = await modulesDir().then(
      (Directory d) => Directory(
        '${d.parent.path}${Platform.pathSeparator}.npm_tmp_${DateTime.now().millisecondsSinceEpoch}',
      ).create(recursive: true),
    );
    try {
      for (final ArchiveFile entry in entries) {
        final String rel = entry.name.replaceAll('\\', '/');
        final Object content = entry.content;
        if (content is! List<int>) {
          throw 'unreadable entry in package tarball: ${entry.name}';
        }
        final File destFile = File(
          '${temp.path}${Platform.pathSeparator}'
          '${rel.replaceAll('/', Platform.pathSeparator)}',
        );
        await destFile.parent.create(recursive: true);
        await destFile.writeAsBytes(content, flush: true);
      }
      // npm tarballs wrap everything in a "package/" root.
      final Directory unpackedRoot = Directory(
        '${temp.path}${Platform.pathSeparator}package',
      );
      final Directory sourceDir = unpackedRoot.existsSync()
          ? unpackedRoot
          : temp;
      await sourceDir.rename(target);
    } on FileSystemException {
      // Cross-device rename fallback: copy then clean up.
      final Directory unpackedRoot = Directory(
        '${temp.path}${Platform.pathSeparator}package',
      );
      final Directory sourceDir = unpackedRoot.existsSync()
          ? unpackedRoot
          : temp;
      await _copyDir(sourceDir, Directory(target));
      await temp.delete(recursive: true);
    }
    installed.add('$name@$resolvedVersion');

    // 3. Recurse into runtime dependencies.
    final File pkgJson = File('$target${Platform.pathSeparator}package.json');
    if (pkgJson.existsSync()) {
      try {
        final Object? decoded = jsonDecode(pkgJson.readAsStringSync());
        if (decoded is Map) {
          final Object? deps = decoded['dependencies'];
          if (deps is Map) {
            for (final MapEntry<dynamic, dynamic> dep in deps.entries) {
              await _installWithDeps(
                dep.key.toString(),
                null,
                installed,
                depth + 1,
              );
            }
          }
        }
      } catch (_) {
        // Unreadable package.json: the package itself is usable.
      }
    }
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final FileSystemEntity entity in from.list()) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (entity is Directory) {
        await _copyDir(
          entity,
          Directory('${to.path}${Platform.pathSeparator}$name'),
        );
      } else if (entity is File) {
        await entity.copy('${to.path}${Platform.pathSeparator}$name');
      }
    }
  }

  /// True when a tarball entry stays inside the extraction root: no absolute
  /// paths, no `..` segments, no Windows drive/UNC prefixes.
  static bool _isSafeEntryPath(String rel) {
    if (rel.isEmpty || rel.startsWith('/') || rel.startsWith('\\')) {
      return false;
    }
    if (rel.contains(':') || rel.contains('\u0000')) return false;
    for (final String segment in rel.split('/')) {
      if (segment == '..') return false;
    }
    return true;
  }

  /// True when [name] is a well-formed npm package name that cannot escape
  /// the node_modules directory. `../../skills/x` used to be accepted and
  /// deleted arbitrary app folders.
  static bool isValidPackageName(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 214) return false;
    if (trimmed.contains('\\') || trimmed.contains(':')) return false;
    if (trimmed.contains('..')) return false;
    final String body = trimmed.startsWith('@')
        ? trimmed.substring(1)
        : trimmed;
    final List<String> segments = body.split('/');
    if (segments.length > 2) return false;
    for (final String segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') return false;
    }
    return true;
  }

  /// Removes a package from node_modules. Returns true when it existed.
  Future<bool> remove(String name) async {
    if (!isValidPackageName(name)) {
      throw 'invalid package name: "$name"';
    }
    final Directory modules = await modulesDir();
    final Directory target = Directory(
      '${modules.path}${Platform.pathSeparator}$name',
    );
    // Defence in depth: the resolved path must stay under node_modules.
    final String modulesPath = modules.absolute.path;
    final String targetPath = target.absolute.path;
    if (!targetPath.startsWith('$modulesPath${Platform.pathSeparator}')) {
      throw 'invalid package name: "$name"';
    }
    if (!target.existsSync()) return false;
    await target.delete(recursive: true);
    return true;
  }

  /// Registry keyword search (top [limit] hits).
  Future<List<Map<String, String>>> search(
    String query, {
    int limit = 8,
  }) async {
    final http.Response res = await _client.get(
      Uri.https(registryHost, '/-/v1/search', <String, String>{
        'text': query,
        'size': '$limit',
      }),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (res.statusCode != 200) {
      throw 'registry search returned HTTP ${res.statusCode}';
    }
    final Object? decoded = jsonDecode(res.body);
    final List<Map<String, String>> out = <Map<String, String>>[];
    if (decoded is Map && decoded['objects'] is List) {
      for (final Object? item in decoded['objects'] as List<Object?>) {
        if (item is Map && item['package'] is Map) {
          final Map pkg = item['package'] as Map;
          out.add(<String, String>{
            'name': pkg['name']?.toString() ?? '',
            'version': pkg['version']?.toString() ?? '',
            'description': pkg['description']?.toString() ?? '',
          });
        }
      }
    }
    return out;
  }
}
