# Noah Module SDK

Official SDK for **Noah chat modules** — JavaScript packages that run
natively inside a chat session, isolated per chat like a browser private
window.

| File | Purpose |
|---|---|
| `zagents-sdk.js` | The runtime shim (`require('zagents-sdk')` → the injected `zagents` global). Bundled into the app; identical source of truth. |
| `index.d.ts` | TypeScript definitions — full autocomplete for `zagents.*` in your editor. |
| `package.json` | npm metadata so editors resolve the types when you develop a module. |

## Quick start

1. **Write a module** — a ZIP with a `module.json` manifest and a
   JavaScript entry point (default `main.js`):

   ```json
   {
     "name": "my-module",
     "version": "1.0.0",
     "title": "My Module",
     "description": "What it does for the user.",
     "permissions": ["storage", "chat"]
   }
   ```

   ```js
   async function main() {
     await zagents.chat.emit('Working…');
     const visits = (await zagents.storage.get('visits')) || 0;
     await zagents.storage.set('visits', visits + 1);
     zagents.log('Visits in THIS chat:', visits + 1);
     return { visits: visits + 1 };
   }
   module.exports = main();
   ```

2. **Install** — Noah app → *Settings → Modules → Install module* →
   pick the ZIP.

3. **Run** — inside a chat type `/plugins` (interactive menu) or
   `/plugins my-module`; or pick the module chip on the new-chat screen.

## API surface

Every capability is **permission-gated** (declared in `module.json`,
approved by the user at activation, enforced twice — SDK + Dart bridge):

| API | Permission | Purpose |
|---|---|---|
| `zagents.info` | — | `{ name, version, title, sessionId, entry, prompt? }` |
| `zagents.log(...)` | — | Console output, captured into the module message |
| `zagents.storage.{get,set,keys,remove}` | `storage` | Per-chat key/value store (64 KB/value, 1 MB/chat+module) |
| `zagents.fs.{readFile,writeFile,appendFile,readdir,mkdir,unlink,stat}` | `files` | Sandbox filesystem, confined to the per-chat `state/` dir |
| `zagents.http.request(url, opts)` | `network` | HTTP via the app transport (custom headers, `timeoutMs`, `headOnly` for SSE); optionally restricted by `allowedHosts` |
| `zagents.chat.emit(text)` | `chat` | Post progressive output into the conversation |
| `zagents.agent.compose(opts)` | `agent` | Ask the chat's own agent to compose ONE sentence from the live context you supply — generated on demand and gate-checked (no templates) |

## Editor setup (optional)

For autocomplete in a module project, reference the SDK as a dependency:

```bash
npm install --save-dev ./path/to/this/sdk/folder
```

…or simply copy `index.d.ts` next to your sources. At runtime the global
`zagents` is always injected by the Noah runtime itself; the shim only
forwards to it when required explicitly.

## Documentation

* **SDK reference (EN):** [`docs/modules/sdk-reference-en.md`](../docs/modules/sdk-reference-en.md)
* **SDK reference (ID):** [`docs/modules/sdk-reference-id.md`](../docs/modules/sdk-reference-id.md)
* **Runnable samples:** [`samples/`](../samples/)
* The same reference ships **in-app** (Settings → Modules → SDK docs) in
  English and Bahasa Indonesia.

## Isolation guarantees

Each (chat, module) pair executes with:

* a **fresh JavaScript context** — nothing survives between runs;
* its **own state directory and storage file** — chat A's module can
  never read chat B's data;
* **declared + approved permissions**, enforced in the SDK *and* the
  native bridge;
* **resource caps** — timeout (30 s default / 120 s max), output cap
  (400 lines / 32 KB), storage caps;
* **safe termination** — deactivating a module or stopping the chat
  cancels a live run without losing persisted state.
