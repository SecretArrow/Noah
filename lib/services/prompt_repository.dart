import 'dart:convert';
import 'dart:io';

import '../models/models.dart';

/// Abstraction over the persistent Prompt Library storage. The library is
/// seeded EMPTY — prompts are strictly user-created content.
abstract class PromptRepository {
  Future<List<PromptEntry>> load();
  Future<void> save(List<PromptEntry> entries);
}

/// JSON-file-backed store used in production. Entries live in a single
/// `prompts.json` under the app documents root (next to `chats/`).
class FilePromptRepository implements PromptRepository {
  FilePromptRepository({required this.resolveBaseDir});

  final Future<Directory> Function() resolveBaseDir;

  /// In-memory cache so synchronous-feeling reads never re-hit the disk;
  /// invalidated by every [save].
  List<PromptEntry>? _cache;

  Future<File> _promptsFile() async {
    final Directory base = await resolveBaseDir();
    return File('${base.path}${Platform.pathSeparator}prompts.json');
  }

  @override
  Future<List<PromptEntry>> load() async {
    if (_cache != null) return List<PromptEntry>.of(_cache!);
    try {
      final File file = await _promptsFile();
      if (await file.exists()) {
        final Object? decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          _cache = <PromptEntry>[
            for (final Object? item in decoded)
              if (item is Map<String, dynamic>) PromptEntry.fromJson(item),
          ];
          return List<PromptEntry>.of(_cache!);
        }
      }
    } catch (_) {
      // Corrupted store: behave like an empty library, never crash.
    }
    _cache = const <PromptEntry>[];
    return const <PromptEntry>[];
  }

  @override
  Future<void> save(List<PromptEntry> entries) async {
    try {
      final File file = await _promptsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<Map<String, dynamic>>[
          for (final PromptEntry e in entries) e.toJson(),
        ]),
      );
      _cache = List<PromptEntry>.of(entries);
    } catch (_) {
      // Persistence is best-effort: the in-memory library keeps working.
    }
  }
}

/// In-memory repository for unit and widget tests.
class MemoryPromptRepository implements PromptRepository {
  MemoryPromptRepository([List<PromptEntry>? initial])
    : _entries = initial ?? const <PromptEntry>[];

  List<PromptEntry> _entries;

  @override
  Future<List<PromptEntry>> load() async => List<PromptEntry>.of(_entries);

  @override
  Future<void> save(List<PromptEntry> entries) async {
    _entries = List<PromptEntry>.of(entries);
  }
}
