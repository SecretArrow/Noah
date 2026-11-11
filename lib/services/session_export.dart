import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'chat_store.dart';
import 'html_export.dart';

const Uuid _uuid = Uuid();

/// Exports all chat sessions to a portable JSON file and imports them back.
///
/// Export format:
/// ```json
/// { "app": "Noah", "format": 1, "exportedAt": "...",
///   "sessions": [ { "id","title","updatedAt","messages":[…] } ] }
/// ```
class SessionExporter {
  SessionExporter({
    required this.store,
    required this.resolveBaseDir,
    this.offloadIsolate = true,
  });

  final ChatStore store;
  final Future<Directory> Function() resolveBaseDir;

  /// v1.34.0 ANR hardening: the pretty-printed whole-app JSON export and
  /// the import decode run off the UI isolate. Test zones pass false
  /// (real isolate replies never arrive inside a FakeAsync zone).
  final bool offloadIsolate;

  Future<T> _maybeIsolate<T>(T Function() work) =>
      offloadIsolate ? Isolate.run(work) : Future<T>.value(work());

  /// Writes every stored session into
  /// `<docs>/exports/zagents-sessions-<timestamp>.json` and returns the file.
  Future<File> exportAll() async {
    final List<ChatSummary> summaries = await store.listSummaries();
    final List<Map<String, dynamic>> sessions = <Map<String, dynamic>>[];
    for (final ChatSummary summary in summaries) {
      final List<ChatMessage>? messages = await store.load(summary.id);
      if (messages == null) continue; // Corrupted entry: skip silently.
      sessions.add(<String, dynamic>{
        'id': summary.id,
        'title': summary.title,
        'updatedAt': summary.updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      });
    }
    final Directory base = await resolveBaseDir();
    final Directory exportsDir = Directory(
      '${base.path}${Platform.pathSeparator}exports',
    );
    if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
    final String stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final File file = File(
      '${exportsDir.path}${Platform.pathSeparator}zagents-sessions-$stamp.json',
    );
    await file.writeAsString(
      // v1.34.0: pretty-printing every session is pure CPU — off-isolate.
      await _maybeIsolate(
        () => const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'app': 'Noah',
          'format': 1,
          'exportedAt': DateTime.now().toIso8601String(),
          'sessions': sessions,
        }),
      ),
    );
    return file;
  }

  /// Parses a previously exported (or hand-edited) JSON file and stores
  /// every session under a NEW id (imports never overwrite existing chats).
  /// Returns the number of imported sessions.
  Future<int> importFrom(String filePath) async {
    final String raw = await File(filePath).readAsString();
    // v1.34.0: whole-file decode off the UI isolate.
    final Object? decoded = await _maybeIsolate(() => jsonDecode(raw));
    if (decoded is! Map || decoded['sessions'] is! List) {
      throw const FormatException('Not a Noah sessions export file');
    }
    var imported = 0;
    for (final Object? rawSession in decoded['sessions'] as List<Object?>) {
      if (rawSession is! Map) continue;
      final Object? rawMessages = rawSession['messages'];
      if (rawMessages is! List) continue;
      final List<ChatMessage> messages = <ChatMessage>[
        for (final Object? m in rawMessages)
          if (m is Map<String, dynamic>) ChatMessage.fromJson(m),
      ];
      final String title = rawSession['title']?.toString() ?? 'Imported';
      await store.save(id: _uuid.v4(), title: title, messages: messages);
      imported++;
    }
    return imported;
  }

  /// Exports ONE session as a human-readable Markdown file under
  /// `<docs>/exports/` (v1.17.0). Returns the written file, or null when
  /// the session id is unknown.
  Future<File?> exportMarkdown(String sessionId) async {
    final List<ChatSummary> summaries = await store.listSummaries();
    ChatSummary? summary;
    for (final ChatSummary s in summaries) {
      if (s.id == sessionId) {
        summary = s;
        break;
      }
    }
    if (summary == null) return null;
    final List<ChatMessage>? messages = await store.load(sessionId);
    if (messages == null) return null;

    final StringBuffer md = StringBuffer()
      ..writeln('# ${summary.title}')
      ..writeln()
      ..writeln(
        '> Exported from Noah on '
        '${DateTime.now().toIso8601String().substring(0, 19)} · '
        '${messages.length} messages',
      )
      ..writeln();

    for (final ChatMessage message in messages) {
      final String when = message.createdAt.toIso8601String().substring(0, 19);
      md.writeln('---');
      switch (message.role) {
        case Role.user:
          md
            ..writeln('**You** · $when')
            ..writeln();
          if (message.content.isNotEmpty) md.writeln(message.content);
          for (final ChatAttachment att in message.attachments) {
            md.writeln('- 📎 ${att.name}');
          }
        case Role.assistant:
          final String model = message.model ?? 'assistant';
          md
            ..writeln('**$model** · $when')
            ..writeln();
          if (message.content.isNotEmpty) md.writeln(message.content);
          for (final ToolCall call in message.toolCalls) {
            final String status = switch (call.status) {
              ToolStatus.success => '✓',
              ToolStatus.error => '✗',
              _ => '…',
            };
            md.writeln('- `$status ${call.name}`');
          }
        case Role.system:
        case Role.tool:
          break;
      }
      md.writeln();
    }

    final Directory base = await resolveBaseDir();
    final Directory exportsDir = Directory(
      '${base.path}${Platform.pathSeparator}exports',
    );
    if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
    final String stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final String safeTitle = summary.title.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]+'),
      '_',
    );
    final File file = File(
      '${exportsDir.path}${Platform.pathSeparator}chat-$safeTitle-$stamp.md',
    );
    await file.writeAsString(md.toString());
    return file;
  }

  /// Exports ONE session as a single self-contained HTML file under
  /// `<docs>/exports/` (v1.51.0, inline CSS via [buildChatHtml]).
  /// Returns the written file, or null when the session id is unknown.
  Future<File?> exportHtml(String sessionId) async {
    final List<ChatSummary> summaries = await store.listSummaries();
    ChatSummary? summary;
    for (final ChatSummary s in summaries) {
      if (s.id == sessionId) {
        summary = s;
        break;
      }
    }
    if (summary == null) return null;
    final List<ChatMessage>? messages = await store.load(sessionId);
    if (messages == null) return null;
    final String html = buildChatHtml(
      title: summary.title,
      messages: messages,
      exportedAt: DateTime.now(),
    );
    final Directory base = await resolveBaseDir();
    final Directory exportsDir = Directory(
      '${base.path}${Platform.pathSeparator}exports',
    );
    if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
    final String stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final String safeTitle = summary.title.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]+'),
      '_',
    );
    final File file = File(
      '${exportsDir.path}${Platform.pathSeparator}chat-$safeTitle-$stamp.html',
    );
    await file.writeAsString(html);
    return file;
  }
}
