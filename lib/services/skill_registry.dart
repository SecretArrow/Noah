import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ar;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'remote_guard.dart';
import 'settings_repository.dart' show SecretBox, FlutterSecretBox;

/// One declared configuration input of a skill (SKILL.md `config:` block).
/// Secret values live in the skill's local config file and are injected
/// into the script environment at run time — they are NEVER echoed back
/// into the conversation or logs.
class SkillConfigField {
  const SkillConfigField({
    required this.name,
    this.label = '',
    this.secret = false,
    this.required = false,
  });

  final String name;
  final String label;
  final bool secret;
  final bool required;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'label': label,
    'secret': secret,
    'required': required,
  };

  static SkillConfigField fromJson(Map<String, dynamic> json) =>
      SkillConfigField(
        name: json['name']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        secret: json['secret'] == true,
        required: json['required'] == true,
      );
}

/// Lifecycle status of one installed skill. [disabled] (v1.49.0) means the
/// user turned the skill off in the Skills manager — it overrides every
/// other state (an off skill never reports ready/needs-config).
enum SkillStatus { ready, needsConfig, broken, disabled }

/// One installed skill: an on-disk folder under `<docs>/skills/<name>/`
/// with a SKILL.md (front-matter: name/description/version/permissions/
/// config) plus optional scripts.
class InstalledSkill {
  const InstalledSkill({
    required this.name,
    required this.version,
    required this.title,
    required this.description,
    required this.source,
    required this.permissions,
    required this.configFields,
    required this.dirPath,
    required this.installedAt,
    this.requiresBins = const <String>[],
    this.wallet = false,
    this.enabled = true,
  });

  final String name;
  final String version;
  final String title;
  final String description;
  final String source;
  final List<String> permissions;
  final List<SkillConfigField> configFields;
  final String dirPath;
  final DateTime installedAt;

  /// Native executables the skill declares (`requires.bins`). The embedded
  /// JS runtime provides NO shell and NO child processes, so a skill that
  /// needs one of these cannot be executed here — that is reported to the
  /// model and the user instead of faking a successful run.
  final List<String> requiresBins;

  /// True when the skill declares `wallet: true` in its SKILL.md: it drives
  /// an asset-holding wallet, so `skill_run` on it is treated as a
  /// value-moving action and requires the user's explicit approval every
  /// time (one approval authorizes exactly one run).
  final bool wallet;

  /// v1.49.0: user-owned on/off switch (Skills manager). A disabled skill
  /// stays installed with its stored config but reports
  /// [SkillStatus.disabled]; the list APIs still return it so callers can
  /// render the flag and decide. Preserved across reinstalls/updates —
  /// turning a skill off must not be silently undone by an update.
  final bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'version': version,
    'title': title,
    'description': description,
    'source': source,
    'permissions': permissions,
    'requiresBins': requiresBins,
    'wallet': wallet,
    'enabled': enabled,
    'config': configFields.map((SkillConfigField f) => f.toJson()).toList(),
    'installedAt': installedAt.toIso8601String(),
  };

  static InstalledSkill fromJson(Map<String, dynamic> json, String dirPath) =>
      InstalledSkill(
        name: json['name']?.toString() ?? '',
        version: json['version']?.toString() ?? '0.0.0',
        title: json['title']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        source: json['source']?.toString() ?? '',
        permissions:
            ((json['permissions'] as List<dynamic>?) ?? const <dynamic>[])
                .map((Object? e) => e.toString())
                .toList(),
        requiresBins:
            ((json['requiresBins'] as List<dynamic>?) ?? const <dynamic>[])
                .map((Object? e) => e.toString())
                .toList(),
        wallet: json['wallet'] == true,
        enabled: json['enabled'] != false,
        configFields: ((json['config'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(SkillConfigField.fromJson)
            .toList(),
        dirPath: dirPath,
        installedAt:
            DateTime.tryParse(json['installedAt']?.toString() ?? '') ??
            DateTime.now(),
      );

  /// Ready when the folder exists, instructions are readable and no
  /// required config value is missing. A user-disabled skill reports
  /// [SkillStatus.disabled] regardless of its config state (v1.49.0).
  SkillStatus status(Set<String> missingRequiredConfig) {
    if (!enabled) return SkillStatus.disabled;
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync() ||
        !File('$dirPath${Platform.pathSeparator}SKILL.md').existsSync()) {
      return SkillStatus.broken;
    }
    return missingRequiredConfig.isEmpty
        ? SkillStatus.ready
        : SkillStatus.needsConfig;
  }

  /// Reads the SKILL.md instructions (the agent's manual for this skill).
  String readInstructions() {
    try {
      return File('$dirPath${Platform.pathSeparator}SKILL.md')
          .readAsStringSync();
    } catch (_) {
      return '';
    }
  }

  /// Relative paths of the files shipped with the skill (docs, references,
  /// helper scripts). Many real skills require reading `references/*.md`
  /// before every command, so the agent must be able to SEE them.
  List<String> listFiles({int max = 200}) {
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) return const <String>[];
    final String sep = Platform.pathSeparator;
    final String prefix = dirPath.endsWith(sep) ? dirPath : '$dirPath$sep';
    final String nodeModules = '${sep}node_modules$sep';
    final List<String> out = <String>[];
    try {
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        final String path = entity.path;
        if (!path.startsWith(prefix)) continue;
        final String rel = path.substring(prefix.length);
        if (rel == 'SKILL.md' || rel == '.zconfig.json') continue;
        if (rel.contains(nodeModules)) continue;
        out.add(rel);
        if (out.length >= max) break;
      }
    } catch (_) {
      // Unreadable directory: report what was collected so far.
    }
    out.sort();
    return out;
  }

  /// Reads one file INSIDE the skill directory. Returns null when the path
  /// is absolute, escapes the directory, or cannot be read — the caller
  /// reports that instead of silently returning the instructions.
  String? readFile(String relative) {
    final String cleaned = relative.trim().replaceAll('\\', '/');
    if (cleaned.isEmpty || cleaned.startsWith('/')) return null;
    for (final String segment in cleaned.split('/')) {
      if (segment == '..' || segment == '.') return null;
    }
    if (cleaned == '.zconfig.json') return null;
    final String sep = Platform.pathSeparator;
    final File file = File('$dirPath$sep${cleaned.replaceAll('/', sep)}');
    if (!file.existsSync()) return null;
    try {
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }
}

/// Structured outcome of one skill installation.
class SkillInstallReport {
  const SkillInstallReport({
    required this.skill,
    this.notes = const <String>[],
  });

  final InstalledSkill skill;
  final List<String> notes;
}

/// v1.41.0 — outcome of [SkillRegistry.update]: either the install was
/// already at the remote version ([upToDate]) or the atomic replace ran
/// ([report] carries the install notes).
class SkillUpdateReport {
  const SkillUpdateReport({
    required this.upToDate,
    required this.previousVersion,
    required this.remoteVersion,
    required this.skill,
    this.report,
  });

  /// True when the remote version matched — nothing was replaced.
  final bool upToDate;

  /// Version installed BEFORE the update attempt (always the installed one).
  final String previousVersion;

  /// Version parsed from the remote SKILL.md (null when unreadable).
  final String? remoteVersion;

  /// The skill AFTER the update (or the unchanged install when up to date).
  final InstalledSkill skill;

  /// Install notes when a replacement actually happened.
  final SkillInstallReport? report;
}

/// Thrown on invalid sources/skills — the message is agent-readable.
class SkillRegistryException implements Exception {
  const SkillRegistryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Installs/lists/configures/removes EXTERNAL agent skills (v1.38.0) —
/// the real, non-simulated pipeline behind the `skill_*` tools.
///
/// Layout: `<documents>/skills/<skill-name>/` (global — a skill is
/// installed ONCE and available in every chat), `registry.json` next to
/// the folders, per-skill secret config in `<skill>/.zconfig.json` (same
/// trust domain as module storage.json; values masked in every
/// LLM-visible surface).
///
/// Sources: GitHub shorthand `owner/repo` or `owner/repo/path/to/skill`
/// (optionally `@branch`), any https tarball URL, or a local
/// `.zip`/`.tar.gz` path the agent downloaded into its workspace.
/// Archives are decoded through package:archive (proven npm pipeline),
/// every entry path-safety checked (zip-slip), size-capped, and staged
/// BEFORE an atomic rename into place.
class SkillRegistry {
  SkillRegistry({
    required this.resolveBaseDir,
    http.Client? client,
    SecretBox? secretBox,
  }) : _client = client ?? http.Client(),
       // v1.49.0: secret config values live in the encrypted store. The
       // default is the device Keystore-backed box — the SAME default
       // [PrefsSettingsRepository] uses — so secrets survive restarts
       // without a di.dart change. (An in-memory default would silently
       // destroy user secrets on every app restart, because [writeConfig]
       // strips the plaintext file once the box confirms the value.)
       // Tests inject [InMemorySecretBox] explicitly.
       _secrets = secretBox ?? const FlutterSecretBox();

  /// Documents-root resolver — public read-only on purpose (tools and
  /// tests introspect it).
  final Future<Directory> Function() resolveBaseDir;
  final http.Client _client;

  /// Encrypted store behind secret skill config values (v1.49.0).
  final SecretBox _secrets;

  /// Skills whose legacy-plaintext config was already migrated into the
  /// secret box during this registry's lifetime. Re-checked after every
  /// registry (re)load — cheap and idempotent.
  final Set<String> _migratedSkills = <String>{};

  /// Mask returned by [readConfig] for encrypted secret values when
  /// [revealSecrets] is false (module pattern: never echo the value).
  static const String secretMask = '••••';

  static const String registryFileName = 'registry.json';
  static const String configFileName = '.zconfig.json';

  /// Archive caps (mirrors ModuleRegistry): a hostile archive can neither
  /// exhaust disk nor pin the extractor.
  static const int maxArchiveBytes = 48 * 1024 * 1024;
  static const int maxUnpackedBytes = 32 * 1024 * 1024;
  static const int maxFileCount = 800;
  static const int maxSingleFileBytes = 8 * 1024 * 1024;

  /// Names owned by app services (the session sandbox refuses them too).
  static const Set<String> reservedNames = <String>{
    'chats',
    'node_modules',
    'modules',
    'exports',
    'sessions',
    'shots',
    'skills',
  };

  /// Sync cache (ModuleRegistry pattern): the system-prompt wire build
  /// reads the installed list WITHOUT async I/O.
  List<InstalledSkill> _cache = const <InstalledSkill>[];
  bool _cacheLoaded = false;

  Future<Directory> skillsDir() async {
    final Directory base = await resolveBaseDir();
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}skills',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Loads the registry cache once; required before [listSync].
  Future<void> ensureCacheLoaded() async {
    if (_cacheLoaded) return;
    _cache = await _readRegistry();
    _cacheLoaded = true;
  }

  /// Installed skills (call [ensureCacheLoaded] first — the prompt wire
  /// uses this on the hot path).
  List<InstalledSkill> listSync() => List<InstalledSkill>.unmodifiable(_cache);

  Future<List<InstalledSkill>> list() async {
    await ensureCacheLoaded();
    return listSync();
  }

  Future<InstalledSkill?> get(String name) async {
    await ensureCacheLoaded();
    for (final InstalledSkill s in _cache) {
      if (s.name == name) return s;
    }
    return null;
  }

  // -- Installation -------------------------------------------------------

  /// Installs a skill from a GitHub shorthand or https archive URL.
  ///
  /// Accepted forms (v1.39.0):
  ///   * `owner/repo/path/to/skill[@branch]`
  ///   * `https://github.com/owner/repo[/tree/<branch>/<path>]`
  ///   * `npx skills add owner/repo/path` (the CLI form the UI suggests)
  ///   * any https archive URL (zip / tar.gz)
  Future<SkillInstallReport> install(String source) async {
    final String trimmed = _normalizeSkillSource(source);
    if (trimmed.isEmpty) {
      throw const SkillRegistryException('Skill source is empty.');
    }
    final List<int> bytes;
    final String resolvedSource;
    // v1.39.0: GitHub URLs must go through the GitHub path — they used to
    // be treated as a raw archive URL and 404'd. The shorthand parser
    // already understands both spellings, and its subPath is now actually
    // passed to the extractor (a repo whose skill lives in a subdirectory
    // used to fail with "No SKILL.md found").
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      final GitHubSkillRef ref = parseGitHubSource(trimmed);
      resolvedSource = 'github:$trimmed';
      bytes = await _downloadGitHubTarball(ref);
      return installFromArchiveBytes(
        bytes,
        source: resolvedSource,
        subPath: ref.subPath.isEmpty ? null : ref.subPath,
      );
    }
    if (trimmed.startsWith('https://github.com/')) {
      final GitHubSkillRef ref = parseGitHubSource(trimmed);
      resolvedSource =
          'github:${ref.owner}/${ref.repo}'
          '${ref.subPath.isEmpty ? '' : '/${ref.subPath}'}';
      bytes = await _downloadGitHubTarball(ref);
      return installFromArchiveBytes(
        bytes,
        source: resolvedSource,
        subPath: ref.subPath.isEmpty ? null : ref.subPath,
      );
    }
    resolvedSource = trimmed;
    bytes = await _downloadUrl(trimmed);
    return installFromArchiveBytes(bytes, source: resolvedSource);
  }

  /// Normalizes the human/CLI spellings of a skill source into one of the
  /// forms [install] understands.
  ///
  /// The agent prompt tells users they can paste
  /// `npx skills add owner/repo/path`; without this the owner would be
  /// parsed as `npx skills add owner` and the install 404s.
  static String _normalizeSkillSource(String raw) {
    String work = raw.trim();
    if (work.length >= 2) {
      final String first = work[0];
      final String last = work[work.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        work = work.substring(1, work.length - 1).trim();
      }
    }
    // `npx skills add X`, `npx -y skills add X`, `skills add X`.
    work = work.replaceFirst(
      RegExp(
        r'^(?:npx\s+(?:-\S+\s+)*)?skills\s+(?:add|install)\s+',
        caseSensitive: false,
      ),
      '',
    );
    // `https://github.com/owner/repo/tree/<branch>/<path>` →
    // `owner/repo/<path>@<branch>`.
    final RegExpMatch? tree = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/(.+)$',
    ).firstMatch(work);
    if (tree != null) {
      work =
          '${tree.group(1)}/${tree.group(2)}/${tree.group(4)}'
          '@${tree.group(3)}';
    } else {
      // v1.41.0: branch ROOT (no subpath) — the regex above required a
      // trailing path, so this spelling fell through, produced the
      // nonsense subPath "tree/<branch>" and failed with "Nothing to
      // install". Normalize it to `owner/repo@<branch>`.
      final RegExpMatch? treeRoot = RegExp(
        r'^https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)$',
      ).firstMatch(work);
      if (treeRoot != null) {
        work =
            '${treeRoot.group(1)}/${treeRoot.group(2)}'
            '@${treeRoot.group(3)}';
      }
    }
    return work.trim();
  }

  /// Installs a skill from archive bytes (URL path above, or a local
  /// zip/tar.gz the agent downloaded into its workspace).
  Future<SkillInstallReport> installFromArchiveBytes(
    List<int> bytes, {
    required String source,
    String? subPath,
  }) async {
    if (bytes.length > maxArchiveBytes) {
      throw const SkillRegistryException(
        'Skill archive exceeds the 48 MB limit.',
      );
    }
    final Map<String, List<int>> files = _decodeArchive(bytes);
    final Directory staging = await _makeStagingDir();
    try {
      // Extract with zip-slip protection + caps. The longest common
      // top-level dir is unwrapped (module pipeline does the same for
      // `repo-main/...` layouts).
      int totalUnpacked = 0;
      int fileCount = 0;
      bool droppedConfig = false;
      final List<String> paths = files.keys.toList();
      final String stripPrefix = _longestCommonPrefix(paths);
      for (final MapEntry<String, List<int>> entry in files.entries) {
        String rel = entry.key;
        if (stripPrefix.isNotEmpty && rel.startsWith(stripPrefix)) {
          rel = rel.substring(stripPrefix.length);
        }
        if (subPath != null && subPath.isNotEmpty) {
          if (!rel.startsWith('$subPath/')) continue;
          rel = rel.substring(subPath.length + 1);
        }
        if (rel.isEmpty) continue;
        // SECURITY (v1.41.0): stored config is USER-owned. An archive that
        // ships `.zconfig.json` used to have it written straight into the
        // install, pre-filling credentials/endpoints for third-party code
        // (the carry-over below only protects an EXISTING config). The
        // entry is dropped, never installed.
        if (rel.split('/').last == configFileName) {
          droppedConfig = true;
          continue;
        }
        if (!_isSafeRelativePath(rel)) {
          throw SkillRegistryException(
            'Archive contains an unsafe path: ${entry.key}',
          );
        }
        final List<int> content = entry.value;
        totalUnpacked += content.length;
        fileCount++;
        if (totalUnpacked > maxUnpackedBytes) {
          throw const SkillRegistryException(
            'Skill unpacked size exceeds the 32 MB limit.',
          );
        }
        if (fileCount > maxFileCount) {
          throw SkillRegistryException(
            'Skill archive contains more than $maxFileCount files.',
          );
        }
        if (content.length > maxSingleFileBytes) {
          throw const SkillRegistryException(
            'A single file in the skill archive exceeds the 8 MB limit.',
          );
        }
        final File target = File(
          '${staging.path}${Platform.pathSeparator}'
          '${rel.replaceAll('/', Platform.pathSeparator)}',
        );
        await target.parent.create(recursive: true);
        await target.writeAsBytes(content, flush: true);
      }
      if (fileCount == 0) {
        throw const SkillRegistryException(
          'Nothing to install at the requested path — check the source '
          '(for owner/repo/path installs the path must contain SKILL.md).',
        );
      }
      _unwrapSingleDir(staging);

      final File skillMd = File(
        '${staging.path}${Platform.pathSeparator}SKILL.md',
      );
      if (!skillMd.existsSync()) {
        throw const SkillRegistryException(
          'No SKILL.md found — not a Noah/agents skill folder '
          '(expected SKILL.md with at least a name + description).',
        );
      }
      final _SkillManifest manifest = _parseSkillManifest(
        skillMd.readAsStringSync(),
      );
      if (manifest.name.isEmpty) {
        throw const SkillRegistryException(
          'SKILL.md front-matter has no "name:" field.',
        );
      }
      final String name = sanitizeSkillName(manifest.name);
      if (reservedNames.contains(name)) {
        throw SkillRegistryException('"$name" is a reserved app name.');
      }
      // v1.49.0: carry the user's enabled choice over a reinstall/update.
      final bool preservedEnabled = await _previousEnabled(name);

      // Atomic-ish replace: move the old install aside, stage the new,
      // drop the old — a failed move rolls the previous install back.
      final Directory root = await skillsDir();
      final Directory finalDir = Directory(
        '${root.path}${Platform.pathSeparator}$name',
      );
      final Directory backup = Directory(
        '${root.path}${Platform.pathSeparator}.$name.bak',
      );
      if (backup.existsSync()) backup.deleteSync(recursive: true);
      if (finalDir.existsSync()) finalDir.renameSync(backup.path);
      try {
        final InstalledSkill skill = InstalledSkill(
          name: name,
          version: manifest.version,
          title: manifest.title,
          description: manifest.description,
          source: source,
          permissions: manifest.permissions,
          requiresBins: manifest.requiresBins,
          wallet: manifest.wallet,
          configFields: manifest.configFields,
          dirPath: finalDir.path,
          installedAt: DateTime.now(),
          enabled: preservedEnabled,
        );
        // v1.40.0: a reinstall must not throw away the user's stored secrets.
        // `.zconfig.json` never comes from the archive (it is blocked from
        // listing/reading), so the previous install's config is carried over
        // before the staged tree replaces it.
        bool configCarried = false;
        if (backup.existsSync()) {
          final File oldConfig = File(
            '${backup.path}${Platform.pathSeparator}$configFileName',
          );
          final File stagedConfig = File(
            '${staging.path}${Platform.pathSeparator}$configFileName',
          );
          if (oldConfig.existsSync() && !stagedConfig.existsSync()) {
            oldConfig.copySync(stagedConfig.path);
            configCarried = true;
          }
        }
        // v1.39.0: registry entry AFTER the files are in place. The old
        // order left registry.json describing an install that a failed
        // rename rolled back.
        staging.renameSync(finalDir.path);
        await _upsertRegistryEntry(skill);
        if (backup.existsSync()) backup.deleteSync(recursive: true);
        await ensureCacheLoaded();
        return SkillInstallReport(
          skill: skill,
          notes: <String>[
            if (configCarried)
              'The previous install\'s stored config was kept (secrets are '
                  'never re-downloaded or echoed).',
            if (droppedConfig)
              'A bundled .zconfig.json was ignored — stored config belongs '
                  'to the user and is never taken from an archive.',
            if (manifest.requiresBins.isNotEmpty)
              'This skill declares a NATIVE dependency: '
                  '${manifest.requiresBins.join(', ')}. The embedded '
                  'JavaScript runtime cannot start external executables, so '
                  'its commands CANNOT be run here. Tell the user this '
                  'limitation plainly instead of claiming the skill works; '
                  'you can still read its instructions and help with '
                  'anything that only needs HTTP.',
            if (manifest.configFields.isNotEmpty)
              'This skill declares ${manifest.configFields.length} config '
                  'field(s): ${manifest.configFields.map((SkillConfigField f) => f.name).join(', ')}. '
                  'Collect the values from the user and store them with '
                  'skill_config (secret values are saved locally, never '
                  'echoed back).',
            'Read the full instructions with skill_info("$name") before '
                'first use and follow them exactly.',
          ],
        );
      } catch (_) {
        // Roll the previous install back, whether the failure happened
        // before or after the staged directory was moved into place.
        if (finalDir.existsSync()) {
          try {
            finalDir.deleteSync(recursive: true);
          } catch (_) {
            // Best effort.
          }
        }
        if (backup.existsSync()) backup.renameSync(finalDir.path);
        rethrow;
      }
    } finally {
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {
          // Best effort.
        }
      }
    }
  }

  /// Installs from a local archive path (already inside a session
  /// workspace — the tool layer resolves and validates the path).
  Future<SkillInstallReport> installFromFile(String absolutePath) async {
    final File file = File(absolutePath);
    if (!file.existsSync()) {
      throw SkillRegistryException('File not found: $absolutePath');
    }
    if (file.lengthSync() > maxArchiveBytes) {
      throw const SkillRegistryException(
        'Skill archive exceeds the 48 MB limit.',
      );
    }
    final String lower = absolutePath.toLowerCase();
    if (!lower.endsWith('.zip') &&
        !lower.endsWith('.tar.gz') &&
        !lower.endsWith('.tgz')) {
      throw const SkillRegistryException(
        'Unsupported archive type — use .zip, .tar.gz or .tgz.',
      );
    }
    return installFromArchiveBytes(
      file.readAsBytesSync(),
      source: 'file:$absolutePath',
    );
  }

  /// v1.38.1 — installs a skill BUNDLED with the app binary
  /// (`assets/skills/<bundledName>/SKILL.md`): a REAL on-disk install
  /// that needs no network. The SKILL.md still passes the same
  /// front-matter validation, reserved-name check and atomic replace as
  /// every other source. [bundledName] is the asset name; the skill's own
  /// front-matter `name:` decides the installed identity.
  Future<SkillInstallReport> installBundled({
    required String bundledName,
    required String skillMd,
    String? sourceOverride,
  }) async {
    final Directory staging = await _makeStagingDir();
    try {
      final File file = File(
        '${staging.path}${Platform.pathSeparator}SKILL.md',
      );
      await file.writeAsString(skillMd, flush: true);
      final _SkillManifest manifest = _parseSkillManifest(skillMd);
      if (manifest.name.isEmpty) {
        throw const SkillRegistryException(
          'Bundled SKILL.md front-matter has no "name:" field.',
        );
      }
      final String name = sanitizeSkillName(manifest.name);
      if (reservedNames.contains(name)) {
        throw SkillRegistryException('"$name" is a reserved app name.');
      }
      // v1.49.0: carry the user's enabled choice over a bundled reinstall.
      final bool preservedEnabled = await _previousEnabled(name);
      final Directory root = await skillsDir();
      final Directory finalDir = Directory(
        '${root.path}${Platform.pathSeparator}$name',
      );
      final Directory backup = Directory(
        '${root.path}${Platform.pathSeparator}.$name.bak',
      );
      if (backup.existsSync()) backup.deleteSync(recursive: true);
      if (finalDir.existsSync()) finalDir.renameSync(backup.path);
      try {
        final InstalledSkill skill = InstalledSkill(
          name: name,
          version: manifest.version,
          title: manifest.title,
          description: manifest.description,
          source: sourceOverride ?? 'builtin:$bundledName',
          permissions: manifest.permissions,
          requiresBins: manifest.requiresBins,
          wallet: manifest.wallet,
          configFields: manifest.configFields,
          dirPath: finalDir.path,
          installedAt: DateTime.now(),
          enabled: preservedEnabled,
        );
        // v1.41.0: a bundled reinstall must not throw away the user's
        // stored secrets — same policy as installFromArchiveBytes. The
        // carry-over runs BEFORE the staged tree replaces the old one.
        bool configCarried = false;
        if (backup.existsSync()) {
          final File oldConfig = File(
            '${backup.path}${Platform.pathSeparator}$configFileName',
          );
          final File stagedConfig = File(
            '${staging.path}${Platform.pathSeparator}$configFileName',
          );
          if (oldConfig.existsSync() && !stagedConfig.existsSync()) {
            oldConfig.copySync(stagedConfig.path);
            configCarried = true;
          }
        }
        // v1.41.0: registry entry AFTER the files are in place. The old
        // order left registry.json describing an install that a failed
        // rename rolled back (and the catch below never repaired it).
        staging.renameSync(finalDir.path);
        await _upsertRegistryEntry(skill);
        if (backup.existsSync()) backup.deleteSync(recursive: true);
        await ensureCacheLoaded();
        return SkillInstallReport(
          skill: skill,
          notes: <String>[
            if (configCarried)
              'The previous install\'s stored config was kept (secrets are '
                  'never re-created or echoed).',
            if (manifest.requiresBins.isNotEmpty)
              'This skill declares a NATIVE dependency: '
                  '${manifest.requiresBins.join(', ')} — its commands '
                  'CANNOT run in the embedded runtime.',
            'This skill ships with Noah — no download happened. '
                'Read the full instructions with skill_info("$name") '
                'before first use and follow them exactly.',
          ],
        );
      } catch (_) {
        // Roll the previous install back, whether the failure happened
        // before or after the staged directory was moved into place.
        if (finalDir.existsSync()) {
          try {
            finalDir.deleteSync(recursive: true);
          } catch (_) {
            // Best effort.
          }
        }
        if (backup.existsSync()) backup.renameSync(finalDir.path);
        rethrow;
      }
    } finally {
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {
          // Best effort.
        }
      }
    }
  }

  /// v1.49.0: user enable/disable switch (Skills manager). Updates the
  /// in-memory cache AND persists the flag into registry.json (atomic
  /// write, flush). Unknown names are a no-op — the UI only calls this
  /// for skills it listed.
  Future<void> setEnabled(String name, bool value) async {
    final List<InstalledSkill> all = await _readRegistry();
    final int index = all.indexWhere((InstalledSkill s) => s.name == name);
    if (index == -1) return;
    final List<InstalledSkill> updated = List<InstalledSkill>.of(all)
      ..[index] = _withEnabled(all[index], value);
    await _writeRegistry(updated);
  }

  /// Copy of [skill] with a new [InstalledSkill.enabled] value.
  InstalledSkill _withEnabled(InstalledSkill skill, bool value) =>
      InstalledSkill(
        name: skill.name,
        version: skill.version,
        title: skill.title,
        description: skill.description,
        source: skill.source,
        permissions: skill.permissions,
        configFields: skill.configFields,
        dirPath: skill.dirPath,
        installedAt: skill.installedAt,
        requiresBins: skill.requiresBins,
        wallet: skill.wallet,
        enabled: value,
      );

  /// v1.49.0: the enabled flag of the CURRENTLY stored install with
  /// [name] (read from registry.json, not the cache) so a reinstall or
  /// update carries the user's choice over instead of resetting it.
  Future<bool> _previousEnabled(String name) async {
    try {
      for (final InstalledSkill s in await _readRegistry()) {
        if (s.name == name) return s.enabled;
      }
    } catch (_) {
      // A registry read hiccup must never block an install.
    }
    return true;
  }

  Future<void> remove(String name) async {
    final InstalledSkill? skill = await get(name);
    if (skill == null) {
      throw SkillRegistryException('Skill "$name" is not installed.');
    }
    final Directory dir = Directory(skill.dirPath);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    await _deleteRegistryEntry(name);
    // v1.49.0: encrypted secrets are keyed by skill name OUTSIDE the skill
    // folder, so they would silently outlive an uninstall. Purge them.
    for (final SkillConfigField f in skill.configFields) {
      if (!f.secret || f.name.isEmpty) continue;
      await _safeBoxDelete(secretBoxKey(skill.name, f.name));
    }
  }

  /// v1.41.0 — re-downloads the skill's declared REMOTE source and replaces
  /// the install when the remote SKILL.md version differs from the installed
  /// one. The replace goes through the same atomic pipeline as a fresh
  /// install, so the user's stored config/secrets are carried over. Bundled
  /// (`builtin:`) and local-file (`file:`) installs are reported honestly
  /// instead of pretending an update happened.
  Future<SkillUpdateReport> update(String name) async {
    final InstalledSkill? current = await get(name);
    if (current == null) {
      throw SkillRegistryException('Skill "$name" is not installed.');
    }
    final String source = current.source;
    if (source.startsWith('builtin:')) {
      throw SkillRegistryException(
        '"$name" is bundled with the app ($source). Its updates ship with '
        'Noah updates — there is nothing to update from here.',
      );
    }
    if (source.startsWith('file:')) {
      throw SkillRegistryException(
        '"$name" was installed from a local archive ($source). To refresh '
        'it, download a new archive into the chat workspace and run '
        'skill_install with that path.',
      );
    }
    final List<int> bytes;
    final String? subPath;
    if (source.startsWith('github:')) {
      final GitHubSkillRef ref = parseGitHubSource(source.substring(7));
      bytes = await _downloadGitHubTarball(ref);
      subPath = ref.subPath.isEmpty ? null : ref.subPath;
    } else {
      bytes = await _downloadUrl(source);
      subPath = null;
    }
    final String? remoteVersion = _peekManifestVersion(bytes, subPath);
    if (remoteVersion != null && remoteVersion == current.version) {
      return SkillUpdateReport(
        upToDate: true,
        previousVersion: current.version,
        remoteVersion: remoteVersion,
        skill: current,
      );
    }
    final SkillInstallReport report = await installFromArchiveBytes(
      bytes,
      source: source,
      subPath: subPath,
    );
    return SkillUpdateReport(
      upToDate: false,
      previousVersion: current.version,
      remoteVersion: remoteVersion,
      skill: report.skill,
      report: report,
    );
  }

  /// Reads the SKILL.md version out of a downloaded archive WITHOUT
  /// installing anything. Null when the archive has no readable SKILL.md at
  /// [subPath] (the install pipeline then reports the real problem).
  ///
  /// Mirrors the install pipeline's path handling: the longest common
  /// top-level prefix (e.g. `repo-main/`) is stripped first, then the
  /// [subPath] filter applies — otherwise a wrapped archive (`demo/SKILL.md`)
  /// would never match a root-level SKILL.md lookup.
  String? _peekManifestVersion(List<int> bytes, String? subPath) {
    try {
      final Map<String, List<int>> files = _decodeArchive(bytes);
      final List<String> paths = files.keys.toList();
      final String stripPrefix = _longestCommonPrefix(paths);
      String? skillMdPath;
      for (final String path in paths) {
        String rel = path;
        if (stripPrefix.isNotEmpty && rel.startsWith(stripPrefix)) {
          rel = rel.substring(stripPrefix.length);
        }
        if (subPath != null && subPath.isNotEmpty) {
          if (!rel.startsWith('$subPath/')) continue;
          rel = rel.substring(subPath.length + 1);
        }
        if (rel == 'SKILL.md') {
          skillMdPath = path;
          break;
        }
      }
      if (skillMdPath == null) return null;
      return _parseSkillManifest(utf8.decode(files[skillMdPath]!)).version;
    } catch (_) {
      return null;
    }
  }

  // -- Config (secrets) ---------------------------------------------------

  File _configFile(String dirPath) =>
      File('$dirPath${Platform.pathSeparator}$configFileName');

  /// Secret-box key for one skill config field. Encrypted values live
  /// OUTSIDE the skill folder on purpose: they survive reinstalls (the
  /// atomic replace swaps the whole directory) and can be purged on
  /// uninstall.
  static String secretBoxKey(String skillName, String field) =>
      'zagents.skill.$skillName.$field';

  /// Secret-declared field names of [skill] (non-empty ones only).
  List<String> _secretFields(InstalledSkill skill) => skill.configFields
      .where((SkillConfigField f) => f.secret && f.name.isNotEmpty)
      .map((SkillConfigField f) => f.name)
      .toList();

  /// Raw config file map — plaintext values exactly as stored on disk.
  /// Internal helper for the file-level stores; NEVER masked.
  Map<String, String> _readPlainConfig(InstalledSkill skill) {
    final File file = _configFile(skill.dirPath);
    if (!file.existsSync()) return const <String, String>{};
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return decoded.map(
          (String k, dynamic v) => MapEntry<String, String>(k, v.toString()),
        );
      }
    } catch (_) {
      // Corrupt config = unset, never a crash.
    }
    return const <String, String>{};
  }

  // The box wrappers swallow every failure: secure storage can be
  // unavailable (platform channel, Keystore trouble) and the registry must
  // degrade to the legacy plaintext behaviour instead of crashing — the
  // same documented trade-off as PrefsSettingsRepository.

  Future<String?> _safeBoxRead(String key) async {
    try {
      return await _secrets.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _safeBoxWrite(String key, String value) async {
    try {
      await _secrets.write(key, value);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _safeBoxDelete(String key) async {
    try {
      await _secrets.delete(key);
    } catch (_) {
      // Best effort.
    }
  }

  /// v1.49.0 one-shot migration per skill: a secret-declared value still
  /// sitting as PLAINTEXT in `.zconfig.json` (pre-encryption installs, or
  /// saves made while secure storage was unavailable) is copied into the
  /// secret box and stripped from the file. Rules:
  /// * the box value is never overwritten — the encrypted copy is newer;
  /// * the plaintext is stripped once the box provably holds that key;
  /// * an emptied file is deleted, matching [writeConfig];
  /// * never throws — when the box is unavailable the plaintext stays as
  ///   the working fallback and migration is retried after a registry
  ///   reload;
  /// * guarded by [_migratedSkills] so reads stay cheap.
  Future<void> _migrateLegacySecrets(InstalledSkill skill) async {
    if (_migratedSkills.contains(skill.name)) return;
    _migratedSkills.add(skill.name);
    try {
      final List<String> secretFields = _secretFields(skill);
      if (secretFields.isEmpty) return;
      final Map<String, String> plain = Map<String, String>.of(
        _readPlainConfig(skill),
      );
      bool changed = false;
      for (final String field in secretFields) {
        final String? value = plain[field];
        if (value == null || value.isEmpty) continue;
        final String key = secretBoxKey(skill.name, field);
        if (await _safeBoxRead(key) == null) {
          if (!await _safeBoxWrite(key, value)) continue; // box unavailable
        }
        // The box now holds this key — the file copy must not survive it.
        plain.remove(field);
        changed = true;
      }
      if (!changed) return;
      final File file = _configFile(skill.dirPath);
      if (plain.isEmpty) {
        if (file.existsSync()) await file.delete();
      } else {
        await file.writeAsString(jsonEncode(plain), flush: true);
      }
    } catch (_) {
      // Migration must never break a read.
    }
  }

  /// Stored config for [skill]. Secret-declared fields that live in the
  /// encrypted store are MASKED ([secretMask], '••••') unless
  /// [revealSecrets] — this is the value handed to UI/LLM-visible
  /// surfaces. Legacy plaintext values (secure storage unavailable) are
  /// returned as-is so the skill keeps working until the box recovers;
  /// internal consumers needing the real value pass `revealSecrets: true`
  /// or use [readSecret].
  Future<Map<String, String>> readConfig(
    InstalledSkill skill, {
    bool revealSecrets = false,
  }) async {
    await _migrateLegacySecrets(skill);
    final Map<String, String> out = Map<String, String>.of(
      _readPlainConfig(skill),
    );
    for (final String field in _secretFields(skill)) {
      final String? boxed = await _safeBoxRead(secretBoxKey(skill.name, field));
      if (boxed == null) continue; // unset, or plaintext-fallback mode
      out[field] = revealSecrets ? boxed : secretMask;
    }
    return out;
  }

  /// v1.49.0: the DECRYPTED value of one config field (or null). The
  /// run path (env injection) and any internal consumer that needs the
  /// real secret value goes through this instead of a masked
  /// [readConfig].
  Future<String?> readSecret(InstalledSkill skill, String field) async {
    await _migrateLegacySecrets(skill);
    final String? boxed = await _safeBoxRead(secretBoxKey(skill.name, field));
    if (boxed != null) return boxed;
    return _readPlainConfig(skill)[field];
  }

  /// Persists config values for [skill]. A `null` value REMOVES the key
  /// from BOTH stores (v1.41.0 unset support — previously a stored key
  /// could only be blanked by reinstalling the skill). When nothing
  /// remains the file is deleted.
  ///
  /// v1.49.0 secrecy: values for fields declared `secret: true` are
  /// stored ENCRYPTED in the secret box under
  /// [secretBoxKey] (`zagents.skill.<skillName>.<fieldName>`) and STRIPPED
  /// from the plaintext file. When the box write fails (secure storage
  /// unavailable) the plaintext stays in the file as the working
  /// fallback — the same documented trade-off as PrefsSettingsRepository.
  Future<void> writeConfig(
    InstalledSkill skill,
    Map<String, String?> values,
  ) async {
    if (values.isEmpty) return;
    await _migrateLegacySecrets(skill);
    final Map<String, String> fileMap = Map<String, String>.of(
      _readPlainConfig(skill),
    );
    final List<String> secretFields = _secretFields(skill);
    bool changed = false;
    for (final MapEntry<String, String?> entry in values.entries) {
      final String field = entry.key;
      if (entry.value == null) {
        await _safeBoxDelete(secretBoxKey(skill.name, field));
        if (fileMap.remove(field) != null) changed = true;
        continue;
      }
      if (secretFields.contains(field)) {
        if (await _safeBoxWrite(
          secretBoxKey(skill.name, field),
          entry.value!,
        )) {
          // Encrypted — the plaintext copy must not survive it.
          if (fileMap.remove(field) != null) changed = true;
        } else if (fileMap[field] != entry.value) {
          // Fallback: secure storage unavailable — keep plaintext.
          fileMap[field] = entry.value!;
          changed = true;
        }
        continue;
      }
      if (fileMap[field] != entry.value) {
        fileMap[field] = entry.value!;
        changed = true;
      }
    }
    final File file = _configFile(skill.dirPath);
    if (!changed) return;
    if (fileMap.isEmpty) {
      if (file.existsSync()) await file.delete();
      return;
    }
    await file.writeAsString(jsonEncode(fileMap), flush: true);
  }

  Set<String> missingRequiredConfig(InstalledSkill skill) {
    return skill.configFields
        .where((SkillConfigField f) => f.required && f.name.isNotEmpty)
        .map((SkillConfigField f) => f.name)
        .toSet();
  }

  /// Required fields still missing VALUES (not merely declared) — the
  /// real gate for run/readiness decisions. Reads with
  /// `revealSecrets: true`: an encrypted secret counts as present.
  Future<Set<String>> missingConfigValues(InstalledSkill skill) async {
    final Map<String, String> stored = await readConfig(
      skill,
      revealSecrets: true,
    );
    return missingRequiredConfig(skill)
        .where((String f) => !stored.containsKey(f) || stored[f]!.isEmpty)
        .toSet();
  }

  /// Ready/needs-config/disabled/broken considering the stored config
  /// values and the user's enabled switch (v1.49.0).
  Future<SkillStatus> statusOf(InstalledSkill skill) async {
    return skill.status(await missingConfigValues(skill));
  }

  /// Masked config summary for LLM-visible surfaces (module pattern):
  /// keys + set/unset state, NEVER values.
  String describeConfig(InstalledSkill skill, Map<String, String> values) {
    if (skill.configFields.isEmpty) return 'no config fields';
    return skill.configFields
        .map((SkillConfigField f) {
          final bool set =
              values.containsKey(f.name) && values[f.name]!.trim().isNotEmpty;
          return '${f.name}(${f.required ? 'required' : 'optional'}, '
              '${set ? 'set' : 'unset'})';
        })
        .join(', ');
  }

  // -- Archive decoding ----------------------------------------------------

  /// Detects by magic bytes: gzip `1f 8b`, zip `PK\x03\x04`. Returns
  /// `{path: bytes}` for FILES only (directories implied by paths).
  Map<String, List<int>> _decodeArchive(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      _checkGzipBudget(bytes);
      final ar.Archive archive = ar.TarDecoder().decodeBytes(
        ar.GZipDecoder().decodeBytes(bytes),
      );
      return _archiveToFiles(archive);
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      _checkZipBudget(bytes);
      final ar.Archive archive = ar.ZipDecoder().decodeBytes(bytes);
      return _archiveToFiles(archive);
    }
    throw const SkillRegistryException(
      'Unrecognized archive format (expected tar.gz or zip).',
    );
  }

  /// Rejects a zip bomb BEFORE decoding: `ZipDecoder` inflates every entry
  /// eagerly, so the post-extraction caps used to run only after gigabytes
  /// had already been allocated. The central directory declares each entry's
  /// uncompressed size, which is enough to refuse the archive up front.
  static void _checkZipBudget(List<int> bytes) {
    final Uint8List data = bytes is Uint8List
        ? bytes
        : Uint8List.fromList(bytes);
    final ByteData view = ByteData.sublistView(data);
    int eocd = -1;
    final int stop = data.length - 22;
    final int floor = stop - 65535 > 0 ? stop - 65535 : 0;
    for (int i = stop; i >= floor; i--) {
      if (data[i] == 0x50 &&
          data[i + 1] == 0x4b &&
          data[i + 2] == 0x05 &&
          data[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw const SkillRegistryException(
        'Corrupt zip: no end-of-central-directory record.',
      );
    }
    final int entries = view.getUint16(eocd + 10, Endian.little);
    final int cdSize = view.getUint32(eocd + 12, Endian.little);
    final int cdOffset = view.getUint32(eocd + 16, Endian.little);
    // ZIP64 markers: refuse instead of guessing (a 4 GB+ skill is not a
    // legitimate use case here, and the archive package's handling of the
    // extended records is not something this app depends on).
    if (entries == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff) {
      throw const SkillRegistryException(
        'ZIP64 skill archives are not supported.',
      );
    }
    if (cdOffset + cdSize > data.length) {
      throw const SkillRegistryException('Corrupt zip: bad central directory.');
    }
    if (entries > maxFileCount) {
      throw SkillRegistryException(
        'Skill archive contains more than $maxFileCount files.',
      );
    }
    int total = 0;
    int p = cdOffset;
    for (int i = 0; i < entries; i++) {
      if (p + 46 > data.length ||
          !(data[p] == 0x50 &&
              data[p + 1] == 0x4b &&
              data[p + 2] == 0x01 &&
              data[p + 3] == 0x02)) {
        throw const SkillRegistryException(
          'Corrupt zip: bad central directory entry.',
        );
      }
      total += view.getUint32(p + 24, Endian.little);
      if (total > maxUnpackedBytes) {
        throw const SkillRegistryException(
          'Skill unpacked size exceeds the 32 MB limit.',
        );
      }
      final int nameLen = view.getUint16(p + 28, Endian.little);
      final int extraLen = view.getUint16(p + 30, Endian.little);
      final int commentLen = view.getUint16(p + 32, Endian.little);
      p += 46 + nameLen + extraLen + commentLen;
    }
  }

  /// gzip's footer stores the uncompressed size (mod 2^32). It is a hint, not
  /// a guarantee, but it catches the ordinary bomb before inflating; the
  /// post-extraction cap still runs afterwards as the authoritative check.
  static void _checkGzipBudget(List<int> bytes) {
    if (bytes.length < 18) {
      throw const SkillRegistryException('Corrupt gzip archive.');
    }
    final ByteData view = ByteData.sublistView(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    final int isize = view.getUint32(bytes.length - 4, Endian.little);
    // A tar wraps the same payload with a 512-byte header + padding per
    // entry, so the hint gets a small allowance above the content cap.
    if (isize > maxUnpackedBytes + 2 * 1024 * 1024) {
      throw const SkillRegistryException(
        'Skill unpacked size exceeds the 32 MB limit.',
      );
    }
  }

  Map<String, List<int>> _archiveToFiles(ar.Archive archive) {
    final Map<String, List<int>> out = <String, List<int>>{};
    int total = 0;
    for (final ar.ArchiveFile f in archive.files) {
      if (!f.isFile) continue;
      final List<int> content = f.content as List<int>;
      total += content.length;
      if (total > maxUnpackedBytes) {
        throw const SkillRegistryException(
          'Skill unpacked size exceeds the 32 MB limit.',
        );
      }
      if (content.length > maxSingleFileBytes) {
        throw const SkillRegistryException(
          'A single file in the skill archive exceeds the 8 MB limit.',
        );
      }
      if (out.length >= maxFileCount) {
        throw SkillRegistryException(
          'Skill archive contains more than $maxFileCount files.',
        );
      }
      out[f.name.replaceAll('\\', '/')] = content;
    }
    return out;
  }

  // -- GitHub ---------------------------------------------------------------

  /// True only for public `https` endpoints (see [RemoteGuard]): plain `http`
  /// is tamperable in transit, and a loopback / link-local / private-range
  /// host would let a hostile source reach the device or the user's LAN.
  static bool isAllowedRemoteUrl(String url) => RemoteGuard.isAllowedUrl(url);

  /// Downloads [uri] through [RemoteGuard]: per-hop URL validation, manual
  /// redirect handling and a streaming byte cap.
  Future<List<int>> _safeDownload(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    try {
      return await RemoteGuard.download(
        _client,
        uri,
        headers: headers,
        maxBytes: maxArchiveBytes,
        timeout: timeout,
      );
    } on RemoteGuardException catch (e) {
      throw SkillRegistryException(e.message);
    }
  }

  Future<List<int>> _downloadUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) {
      throw SkillRegistryException('Invalid URL: $url');
    }
    return _safeDownload(uri);
  }

  Future<List<int>> _downloadGitHubTarball(GitHubSkillRef ref) async {
    String branch = ref.branch;
    if (branch.isEmpty) {
      final List<int> metaBytes = await _safeDownload(
        Uri.parse('https://api.github.com/repos/${ref.owner}/${ref.repo}'),
        headers: const <String, String>{'Accept': 'application/json'},
        timeout: const Duration(seconds: 30),
      );
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(metaBytes));
      } catch (_) {
        // A 200 with an HTML/error body: rate-limit pages and outages do
        // this. The old code surfaced a raw FormatException with no hint.
        throw const SkillRegistryException(
          'GitHub metadata returned a non-JSON response (rate limit or '
          'outage). Try again later, or install from a full archive URL.',
        );
      }
      if (decoded is! Map ||
          decoded['default_branch'] is! String ||
          (decoded['default_branch'] as String).isEmpty) {
        throw SkillRegistryException(
          'GitHub metadata has no default_branch — "${ref.owner}/${ref.repo}" '
          'may not exist or may be private. Check the owner/repo spelling '
          '(anonymous API access is rate-limited to 60 requests/hour).',
        );
      }
      branch = decoded['default_branch'] as String;
    }
    return _downloadUrl(
      'https://codeload.github.com/${ref.owner}/${ref.repo}'
      '/tar.gz/refs/heads/$branch',
    );
  }

  /// `owner/repo`, `owner/repo/sub/dir`, `owner/repo@branch`,
  /// `owner/repo/sub/dir@branch`, and full github.com URLs.
  GitHubSkillRef parseGitHubSource(String source) {
    String work = source.replaceFirst(RegExp(r'^github:'), '');
    if (work.startsWith('https://github.com/')) {
      work = work.substring('https://github.com/'.length);
    }
    if (work.endsWith('.git')) {
      work = work.substring(0, work.length - 4);
    }
    String branch = '';
    final int at = work.indexOf('@');
    if (at != -1) {
      branch = work.substring(at + 1).trim();
      work = work.substring(0, at);
    }
    final List<String> parts = work
        .split('/')
        .where((String p) => p.trim().isNotEmpty)
        .toList();
    if (parts.length < 2) {
      throw const SkillRegistryException(
        'Use owner/repo (optionally owner/repo/path/to/skill[@branch]).',
      );
    }
    return GitHubSkillRef(
      owner: parts[0],
      repo: parts[1],
      subPath: parts.length > 2 ? parts.sublist(2).join('/') : '',
      branch: branch,
    );
  }

  // -- Bundled skills (v1.38.1 / v1.49.0 catalog) ---------------------------

  /// SKILL.md assets bundled with the app binary. Mirrors the list wired
  /// into the tool executor (di.dart `bundledSkills()`); bundled skills
  /// are NOT registry-managed until installed, so the Skills manager
  /// needs this catalog to render their install tiles.
  static const List<String> bundledSkillNames = <String>[
    'web3-wallet-basics',
    'binance-agentic-wallet',
  ];

  /// True when [source] is a bundled (`builtin:`) install — its updates
  /// ship with app updates, so the manager hides the Update action.
  static bool isBuiltinSource(String source) => source.startsWith('builtin:');

  /// v1.49.0 convenience for the Skills manager's one-tap bundled install:
  /// loads the SKILL.md straight from the app asset and installs it.
  /// Throws the same [SkillRegistryException]s as [installBundled]; a
  /// missing asset fails with a clear message instead of a raw loader
  /// error.
  /// v1.51.0 — skill_save: saves a NEW reusable skill authored in chat
  /// (name + description + instructions) as a real installed skill. The
  /// generated SKILL.md passes the same validation as every other
  /// install path; the recorded source is `chat:<name>`.
  Future<SkillInstallReport> saveSkillFromChat({
    required String name,
    required String description,
    required String instructions,
  }) async {
    final String safeName = sanitizeSkillName(name);
    final String desc = description.replaceAll('\n', ' ').trim();
    final String body = instructions.trim();
    if (body.isEmpty) {
      throw const SkillRegistryException(
        'Skill instructions must not be empty.',
      );
    }
    final String quotedDesc = desc
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"');
    final String skillMd =
        '---\n'
        'name: $safeName\n'
        'title: $safeName\n'
        'description: "$quotedDesc"\n'
        'version: "1.0"\n'
        '---\n\n'
        '# $safeName\n\n'
        '$body\n';
    return installBundled(
      bundledName: safeName,
      skillMd: skillMd,
      sourceOverride: 'chat:$safeName',
    );
  }

  Future<SkillInstallReport> installBundledAsset(String bundledName) async {
    final String skillMd;
    try {
      skillMd = await rootBundle.loadString(
        'assets/skills/$bundledName/SKILL.md',
      );
    } catch (_) {
      throw SkillRegistryException('No bundled skill named "$bundledName".');
    }
    return installBundled(bundledName: bundledName, skillMd: skillMd);
  }

  /// Loads and parses the bundled catalog for the Skills manager. A
  /// missing or unreadable asset simply does not appear; never throws.
  /// (Widget tests get the real assets through rootBundle; unit tests
  /// never call this.)
  Future<List<BundledSkillInfo>> bundledCatalog() async {
    final List<BundledSkillInfo> out = <BundledSkillInfo>[];
    for (final String bundledName in bundledSkillNames) {
      try {
        final String md = await rootBundle.loadString(
          'assets/skills/$bundledName/SKILL.md',
        );
        final _SkillManifest manifest = _parseSkillManifest(md);
        if (manifest.name.isEmpty) continue;
        out.add(
          BundledSkillInfo(
            bundledName: bundledName,
            name: sanitizeSkillName(manifest.name),
            title: manifest.title,
            description: manifest.description,
            version: manifest.version,
            wallet: manifest.wallet,
          ),
        );
      } catch (_) {
        // A missing bundled asset simply does not appear in the list.
      }
    }
    return out;
  }

  // -- Paths & helpers ------------------------------------------------------

  Future<Directory> _makeStagingDir() async {
    final Directory root = await skillsDir();
    return Directory(
      '${root.path}${Platform.pathSeparator}'
      '.staging_${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
  }

  /// SKILL.md YAML front-matter — a small, defensive line parser (the
  /// agents/skills ecosystem standard: `---` block with name/description,
  /// optional version/permissions/config list).
  _SkillManifest _parseSkillManifest(String raw) {
    final _SkillManifest manifest = _SkillManifest();
    final List<String> lines = raw.split('\n');
    int index = 0;
    while (index < lines.length && lines[index].trim() != '---') {
      index++;
    }
    if (index >= lines.length) {
      // No front-matter: fall back to the first heading + first paragraph.
      final RegExp heading = RegExp(r'^#\s+(.+)$');
      for (final String line in lines) {
        final RegExpMatch? m = heading.firstMatch(line.trim());
        if (m != null) {
          manifest.title = m.group(1)!.trim();
          manifest.name = sanitizeSkillName(manifest.title);
          break;
        }
      }
      manifest.description = _firstParagraph(raw);
      return manifest;
    }
    index++; // past '---'
    String? currentListKey;
    Map<String, String>? currentConfigItem;
    // Block scalar (`description: |` / `>`) accumulator: the ecosystem's
    // SKILL.md files use multi-line descriptions, and the old parser
    // stored the literal "|" as the description.
    String? blockKey;
    StringBuffer? blockBuffer;
    void flushBlock() {
      final String? key = blockKey;
      final StringBuffer? buf = blockBuffer;
      blockKey = null;
      blockBuffer = null;
      if (key == null || buf == null) return;
      final String text = buf.toString().trim();
      if (text.isEmpty) return;
      if (key == 'description') {
        manifest.description = text;
      } else if (key == 'title') {
        manifest.title = text;
      }
    }

    for (; index < lines.length; index++) {
      final String line = lines[index];
      final String trimmed = line.trim();
      if (blockKey != null) {
        // Blank lines and indented lines belong to the block scalar; the
        // first non-indented, non-blank line closes it.
        if (trimmed.isEmpty) {
          blockBuffer!.writeln();
          continue;
        }
        if (line.startsWith(' ') || line.startsWith('\t')) {
          blockBuffer!.writeln(trimmed);
          continue;
        }
        flushBlock();
      }
      if (trimmed == '---' || trimmed == '...') break;
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('- ') || trimmed == '-') {
        final String item = trimmed == '-' ? '' : trimmed.substring(2).trim();
        if (currentListKey == 'permissions') {
          if (item.isNotEmpty) manifest.permissions.add(item);
        } else if (currentListKey == 'bins') {
          if (item.isNotEmpty) manifest.requiresBins.add(_unquote(item));
        } else if (currentListKey == 'config') {
          if (item.contains(':')) {
            final int split = item.indexOf(':');
            final Map<String, String> inline = <String, String>{
              item.substring(0, split).trim(): item.substring(split + 1).trim(),
            };
            manifest.configItems.add(inline);
            currentConfigItem = inline;
          } else if (item.isNotEmpty) {
            final Map<String, String> named = <String, String>{'name': item};
            manifest.configItems.add(named);
            currentConfigItem = named;
          }
        }
        continue;
      }
      // Continuation of the current config mapping item (indented).
      if (currentConfigItem != null &&
          line.startsWith('  ') &&
          trimmed.contains(':')) {
        final int split = trimmed.indexOf(':');
        currentConfigItem[trimmed.substring(0, split).trim()] = trimmed
            .substring(split + 1)
            .trim();
        continue;
      }
      final int colon = trimmed.indexOf(':');
      if (colon == -1) continue;
      final String key = trimmed.substring(0, colon).trim();
      final String value = trimmed.substring(colon + 1).trim();
      // Nested keys (e.g. `metadata.version`) must not clobber the
      // top-level manifest fields.
      final bool nested = line.startsWith(' ') || line.startsWith('\t');
      currentConfigItem = null;
      if (value == '|' || value == '>') {
        blockKey = key;
        blockBuffer = StringBuffer();
        currentListKey = null;
        continue;
      }
      if (value.startsWith('[') && value.endsWith(']')) {
        final List<String> items = value
            .substring(1, value.length - 1)
            .split(',')
            .map((String s) => _unquote(s.trim()))
            .where((String s) => s.isNotEmpty)
            .toList();
        if (key == 'bins') {
          manifest.requiresBins.addAll(items);
        } else if (key == 'permissions') {
          manifest.permissions.addAll(items);
        }
        currentListKey = null;
        continue;
      }
      switch (key) {
        case 'name':
          if (!nested) manifest.name = _unquote(value);
        case 'description':
          if (!nested) manifest.description = _unquote(value);
        case 'version':
          if (!nested) manifest.version = _unquote(value);
        case 'title':
          if (!nested) manifest.title = _unquote(value);
        case 'wallet':
          if (!nested) {
            final String flag = _unquote(value).toLowerCase();
            manifest.wallet = flag == 'true' || flag == 'yes' || flag == '1';
          }
        case 'permissions':
        case 'config':
        case 'bins':
          currentListKey = key;
        default:
          currentListKey = null;
      }
    }
    flushBlock();
    for (final Map<String, String> item in manifest.configItems) {
      manifest.configFields.add(
        SkillConfigField(
          name: item['name'] ?? '',
          label: item['label'] ?? item['description'] ?? '',
          secret: _truthy(item['secret']),
          required: _truthy(item['required']),
        ),
      );
    }
    if (manifest.title.isEmpty) manifest.title = manifest.name;
    return manifest;
  }

  static bool _truthy(String? raw) =>
      raw != null && <String>['true', 'yes', '1'].contains(raw.toLowerCase());

  /// Strips matching single/double quotes from a YAML scalar.
  static String _unquote(String raw) {
    String value = raw.trim();
    if (value.length >= 2) {
      final String first = value[0];
      final String last = value[value.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        value = value.substring(1, value.length - 1).trim();
      }
    }
    return value;
  }

  String _firstParagraph(String markdown) {
    for (final String block in markdown.split('\n\n')) {
      final String cleaned = block
          .split('\n')
          .where((String l) => !l.trim().startsWith('#') && l.trim() != '---')
          .join(' ')
          .trim();
      if (cleaned.isNotEmpty) {
        return cleaned.length > 300 ? '${cleaned.substring(0, 300)}…' : cleaned;
      }
    }
    return '';
  }

  String sanitizeSkillName(String raw) {
    final String cleaned = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-_]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (cleaned.isEmpty) {
      throw const SkillRegistryException(
        'Skill name is empty after sanitizing.',
      );
    }
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  bool _isSafeRelativePath(String rel) {
    if (rel.isEmpty || rel.startsWith('/') || rel.contains(':')) return false;
    if (rel.contains('\\')) return false;
    for (final String segment in rel.split('/')) {
      if (segment.isEmpty || segment == '.' || segment == '..') return false;
    }
    return true;
  }

  String _longestCommonPrefix(List<String> paths) {
    if (paths.isEmpty) return '';
    if (!paths.every((String p) => p.split('/').length > 1)) return '';
    String prefix = paths.first.split('/').first;
    for (final String p in paths) {
      while (!p.startsWith('$prefix/')) {
        final int cut = prefix.lastIndexOf('/');
        if (cut == -1) return '';
        prefix = prefix.substring(0, cut);
      }
    }
    return prefix.isEmpty ? '' : '$prefix/';
  }

  /// When extraction produced exactly one wrapping directory, lift its
  /// children into the staging root.
  void _unwrapSingleDir(Directory dir) {
    final List<FileSystemEntity> entries = dir.listSync();
    if (entries.length != 1 || entries.first is! Directory) return;
    final Directory inner = entries.first as Directory;
    final Directory parent = dir.parent;
    final Directory temp = Directory(
      '${parent.path}${Platform.pathSeparator}'
      '.unwrap_${DateTime.now().microsecondsSinceEpoch}',
    );
    inner.renameSync(temp.path);
    for (final FileSystemEntity e in temp.listSync()) {
      final String base = e.path.split(Platform.pathSeparator).last;
      e.renameSync('${dir.path}${Platform.pathSeparator}$base');
    }
    temp.deleteSync();
  }

  // -- registry.json --------------------------------------------------------

  Future<File> _registryFile() async {
    final Directory dir = await skillsDir();
    return File('${dir.path}${Platform.pathSeparator}$registryFileName');
  }

  Future<List<InstalledSkill>> _readRegistry() async {
    // Any registry (re)load re-arms the one-shot legacy-secret migration —
    // cheap and idempotent (a clean file makes the re-check a no-op).
    _migratedSkills.clear();
    final File file = await _registryFile();
    if (!file.existsSync()) return const <InstalledSkill>[];
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['skills'] is! Map) {
        return const <InstalledSkill>[];
      }
      final Directory root = await skillsDir();
      final List<InstalledSkill> out = <InstalledSkill>[];
      (decoded['skills'] as Map).forEach((Object? k, Object? v) {
        if (v is Map<String, dynamic>) {
          out.add(
            InstalledSkill.fromJson(
              v,
              '${root.path}${Platform.pathSeparator}$k',
            ),
          );
        }
      });
      return out;
    } catch (_) {
      return const <InstalledSkill>[];
    }
  }

  Future<void> _writeRegistry(List<InstalledSkill> skills) async {
    final File file = await _registryFile();
    final Map<String, dynamic> payload = <String, dynamic>{
      'skills': <String, dynamic>{
        for (final InstalledSkill s in skills) s.name: s.toJson(),
      },
    };
    // Atomic write (v1.35.0 lesson): temp file + rename.
    final File temp = File(
      '${file.path}.tmp_${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(jsonEncode(payload), flush: true);
    if (file.existsSync()) file.deleteSync();
    await temp.rename(file.path);
    _cache = List<InstalledSkill>.unmodifiable(skills);
    _cacheLoaded = true;
  }

  Future<void> _upsertRegistryEntry(InstalledSkill skill) async {
    final List<InstalledSkill> all = (await _readRegistry())
        .where((InstalledSkill s) => s.name != skill.name)
        .toList();
    all.add(skill);
    await _writeRegistry(all);
  }

  Future<void> _deleteRegistryEntry(String name) async {
    final List<InstalledSkill> all = (await _readRegistry())
        .where((InstalledSkill s) => s.name != name)
        .toList();
    await _writeRegistry(all);
  }
}

class GitHubSkillRef {
  const GitHubSkillRef({
    required this.owner,
    required this.repo,
    this.subPath = '',
    this.branch = '',
  });
  final String owner;
  final String repo;
  final String subPath;
  final String branch;
}

/// Display info for one skill bundled with the app binary (v1.49.0) —
/// shown by the Skills manager with an install button until it is really
/// installed via [SkillRegistry.installBundled] (`builtin:<bundledName>`).
class BundledSkillInfo {
  const BundledSkillInfo({
    required this.bundledName,
    required this.name,
    required this.title,
    required this.description,
    required this.version,
    required this.wallet,
  });

  /// Asset name behind `builtin:<bundledName>` installs.
  final String bundledName;

  /// Sanitized front-matter name — the identity the install will take.
  final String name;
  final String title;
  final String description;
  final String version;

  /// Parsed `wallet: true` flag (value-moving skill — approval gated).
  final bool wallet;
}

class _SkillManifest {
  String name = '';
  String version = '0.0.0';
  String title = '';
  String description = '';
  final List<String> permissions = <String>[];

  /// True when the skill's SKILL.md declares `wallet: true`: the skill
  /// drives an asset-holding wallet, so every script it runs is treated as
  /// value-moving and needs the user's explicit approval (v1.40.0).
  bool wallet = false;

  /// Native executables the skill declares it needs (`requires.bins` /
  /// `openclaw.requires.bins`). The embedded JS runtime cannot provide
  /// these — reporting them honestly is what keeps the agent from
  /// pretending a CLI-only skill works.
  final List<String> requiresBins = <String>[];
  final List<SkillConfigField> configFields = <SkillConfigField>[];
  final List<Map<String, String>> configItems = <Map<String, String>>[];
}
