import '../models/models.dart';

/// Escapes text for safe inclusion in HTML (pure).
String escapeHtml(String input) => input
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Builds ONE self-contained HTML document for a chat transcript
/// (v1.51.0): inline CSS, no external assets, message bodies escaped.
/// Pure function — unit-tested without any IO.
String buildChatHtml({
  required String title,
  required List<ChatMessage> messages,
  required DateTime exportedAt,
}) {
  final StringBuffer body = StringBuffer();
  for (final ChatMessage m in messages) {
    if (m.role == Role.system || m.role == Role.tool) continue;
    final String who = m.role == Role.user ? 'You' : (m.model ?? 'Assistant');
    final String cls = m.role == Role.user ? 'user' : 'assistant';
    body
      ..writeln('<section class="msg $cls">')
      ..writeln(
        '<header>${escapeHtml(who)} · '
        '${escapeHtml(m.createdAt.toIso8601String().substring(0, 19))}</header>',
      )
      ..writeln('<pre>${escapeHtml(m.content)}</pre>');
    for (final ToolCall call in m.toolCalls) {
      body.writeln(
        '<div class="tool">tool: ${escapeHtml(call.name)} '
        '(${escapeHtml(call.status.name)})</div>',
      );
    }
    body.writeln('</section>');
  }
  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)} — Noah export</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem auto; max-width: 760px; padding: 0 1rem; background: #0d0e12; color: #e8e9eb; }
h1 { font-size: 1.3rem; }
.meta { color: #9aa0a6; font-size: .85rem; margin-bottom: 1.5rem; }
.msg { border: 1px solid #2a2d34; border-radius: 12px; padding: 1rem; margin-bottom: 1rem; background: #15171c; }
.msg.user { background: #182233; }
.msg header { font-size: .8rem; color: #9aa0a6; margin-bottom: .5rem; }
.msg pre { white-space: pre-wrap; word-wrap: break-word; margin: 0; font: inherit; }
.tool { font-size: .8rem; color: #9aa0a6; margin-top: .4rem; }
</style>
</head>
<body>
<h1>${escapeHtml(title)}</h1>
<div class="meta">Exported from Noah on ${escapeHtml(exportedAt.toIso8601String().substring(0, 19))} · ${messages.length} messages</div>
$body</body>
</html>
''';
}
