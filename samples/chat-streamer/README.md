# Chat Streamer (sample)

ZAgents chat module demonstrating the **`chat`** permission: progressive
output posted into the conversation while the module runs.

* Manifest: `module.json` — requests only `chat` (no storage, no
  network, no files).
* Entry: `main.js` — `zagents.chat.emit` for each step, `zagents.log`
  for the console summary, and `zagents.info` metadata in the return
  value.
* Lifecycle demo: deactivating the module or stopping the chat cancels
  a live run — delivery stops immediately, already-posted messages
  stay in the transcript.

Package and install: see [`../README.md`](../README.md).
