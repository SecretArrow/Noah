/**
 * File Notes — ZAgents chat module (sample).
 *
 * Demonstrates: `zagents.fs` (permission `files`) — the sandboxed
 * filesystem confined to this (chat, module) instance's `state/`
 * directory. Paths outside the state directory are rejected by the
 * bridge, so a module can never read or write another chat's data.
 */
async function main() {
  const notePath = 'notes/session.txt';
  const stamp = new Date().toISOString();

  // Read the previous note (first activation in this chat: absent).
  let previousAppends = 0;
  try {
    const previous = await zagents.fs.readFile(notePath);
    previousAppends = previous.trim().split('\n').filter(Boolean).length;
  } catch (_) {
    // No note yet — this is the first run in THIS chat.
  }

  await zagents.fs.mkdir('notes');
  await zagents.fs.appendFile(notePath, stamp + '\n');

  const note = await zagents.fs.readFile(notePath);
  const entries = await zagents.fs.readdir('.');
  const stat = await zagents.fs.stat(notePath);

  zagents.log('state/ entries:', entries.join(', '));
  zagents.log('Note size:', stat.size, 'bytes');
  zagents.log('Appends so far in THIS chat:', previousAppends + 1);

  return {
    appendsInThisChat: previousAppends + 1,
    noteSizeBytes: stat.size,
    noteModified: stat.modified,
    stateEntries: entries,
    firstLineOfNote: note.split('\n')[0],
  };
}

module.exports = main();
