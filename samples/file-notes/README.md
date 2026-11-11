# File Notes (sample)

ZAgents chat module demonstrating the **`files`** permission: a sandboxed
filesystem rooted at this (chat, module) instance's `state/` directory.

* Manifest: `module.json` — requests only `files`.
* Entry: `main.js` — `zagents.fs.mkdir/appendFile/readFile/readdir/stat`
  plus `try/catch` for the "file does not exist yet" first run.
* Isolation demo: `state/notes/session.txt` is unique per chat — notes
  written in one chat are invisible everywhere else, and the file
  disappears with the chat's sandbox.

Package and install: see [`../README.md`](../README.md).
