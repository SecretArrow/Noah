/**
 * Chat Streamer — ZAgents chat module (sample).
 *
 * Demonstrates: `zagents.chat.emit` (permission `chat`) — progressive
 * output posted into the conversation while the module runs. Each
 * emitted text appears as its own message with the module badge; the
 * agent in the chat can read and discuss them.
 *
 * Deactivating the module or stopping the chat cancels a live run:
 * delivery stops immediately, already-posted messages stay.
 */
async function main() {
  const steps = [
    'Step 1/3 — reading module metadata…',
    'Step 2/3 — everything stays inside THIS chat (no storage, no network).',
    'Step 3/3 — streaming complete.',
  ];

  for (const step of steps) {
    await zagents.chat.emit(step);
  }

  zagents.log('Streamed', steps.length, 'updates into the conversation');

  return {
    streamed: steps.length,
    module: zagents.info.name,
    version: zagents.info.version,
  };
}

module.exports = main();
