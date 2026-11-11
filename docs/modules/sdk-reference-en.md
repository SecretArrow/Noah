# Noah Module SDK (v1.31.0)

Official guide for building **chat modules**: JavaScript packages that run
natively inside a Noah chat session, isolated per chat like a browser
private window.

Where things live in this repository:

| Path | Contents |
|---|---|
| `sdk/` | Official SDK — `zagents-sdk.js` shim, `index.d.ts` TypeScript definitions, `package.json` |
| `samples/` | Complete, installable example modules (counter, network fetcher, file notes, chat streamer, onhomeroom daily) |
| `docs/modules/` | This reference (English + Bahasa Indonesia) — also shipped in-app |

## 1. Package layout

A module is a ZIP archive:

```
my-module.zip
├── module.json        (manifest — recommended)
├── main.js            (entry point, default)
├── lib/util.js        (any extra files, required relatively)
└── node_modules/…     (optional; or use packages installed via npm tools)
```

### Manifest — `module.json`

```json
{
  "name": "my-module",
  "version": "1.0.0",
  "title": "My Module",
  "description": "What the module does for the user.",
  "entry": "main.js",
  "permissions": ["storage", "network", "files", "chat"],
  "allowedHosts": ["api.example.com"],
  "timeoutSeconds": 30,
  "commands": ["airplane"],
  "setup": {
    "title": "My Module account",
    "description": "Collected once per chat before the first run.",
    "fields": [
      { "key": "username", "label": "Username", "type": "text", "required": true },
      { "key": "password", "label": "Password", "type": "password", "required": true },
      { "key": "retries", "label": "Max retries", "type": "number" },
      { "key": "verbose", "label": "Verbose logging", "type": "boolean" }
    ]
  }
}
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Lowercase `[a-z0-9._-]`, max 40 chars. Also the install directory name. |
| `version` | — | Shown in the Modules screen. |
| `title` | — | Display name (defaults to `name`). |
| `description` | — | Shown to the user and injected into the chat context. |
| `entry` | — | Entry point, default `main.js`. |
| `permissions` | — | `storage`, `network`, `files`, `chat`, `agent`, `device` — the user approves each activation. |
| `allowedHosts` | — | Restrict `zagents.http` to these hosts (`*.example.com` allows subdomains). Omit for any host. |
| `timeoutSeconds` | — | Execution budget per run (30 default, 120 max). |
| `setup` | — | Per-chat setup form — see below. |
| `commands` | — | Slash keywords the module handles (v1.31.0) — see below. |

Without `module.json`, a `package.json` (`name`, `version`, `main`) is
honored; with neither, the ZIP file name becomes the module name.

### Setup form — module.json `setup`

Declare the user input your module needs and the app collects it with a
**per-chat form BEFORE the module's first run in that chat** — no failed
first cycle, no `setup <…>` parsing required:

* `title`, `description` — form heading and helper line (optional).
* `fields` — up to 12 entries. Each field: `key` (machine name,
  `[a-z0-9_]`, max 40), `label`, `type` (`text`, `password`, `number`,
  `boolean`), `required`, `placeholder`, `description`.
* While any **required** field is unfilled for this chat, the host keeps
  the module from executing and shows the form instead; submitting it
  saves the values and runs the module automatically.
* Values live in the (chat, module) storage under the cooperative key
  `zagentsSetup` — written by the host on submit, and mirrored by the
  module itself when it changes its configuration another way (e.g. a
  text-command setup), so the gate always reflects reality. Other chats
  ask again: setup is per chat by design.
* Read the values in the module via `zagents.info.setup` (see below) or
  `await zagents.storage.get('zagentsSetup')`.
* A manifest without a `setup` block (or without required fields) never
  triggers the form — behavior is unchanged for existing modules.

### Slash commands — module.json `commands` (v1.31.0)

Declare keywords your module handles and the user can run it by typing
`/<keyword> …` directly in the chat — from the FIRST message of a fresh
chat and MID-chat:

```json
{ "name": "airplane-mode", "commands": ["airplane"], "permissions": ["device"] }
```

* Typing **`/airplane on`** in a chat where such a module is active runs
  the module's entry point again — the raw message arrives as
  `zagents.info.prompt` — and the LLM is NOT called for that turn.
* When no module is active yet, an installed module declaring the keyword
  is **auto-activated** by the command (typing it IS the intent); its
  permission consent still applies as usual.
* When a staged module declares the typed keyword, the first message is
  consumed by the staged activation — same `info.prompt` contract.
* Sanitized strictly: lowercase `[a-z0-9_-]`, at most 4 keywords, max 24
  chars each; the built-ins `plugins`, `make_plugins` and `doctor` are
  reserved and rejected.
* Command runs re-use the full sandbox (per-chat state, permissions,
  timeout) and land in the transcript as a module message.

## 2. Installing and running

1. **Modules screen** → *Install module* → pick the ZIP.
2. Run it inside a chat:
   * Type **`/plugins`** → pick the module from the interactive menu, or
   * Type **`/plugins my-module`**, or
   * Select it as a chip on the new-chat screen, or
   * Modules screen → module → *Start in new chat*.

### Building a module FROM chat — `/make_plugins`

Since v1.27.0 the chat agent can build a module for you inside a running
chat: type **`/make_plugins <description>`** (aliases `/make_plugin`,
`/make_module`). The agent writes the module folder, self-checks it,
packs the zip and calls `module_stage_repair`; you confirm the install
on the card. Reference session data (uploads, workspace files, earlier
messages) in your description and it gets copied INTO the module —
modules cannot read the chat workspace at runtime, so the zip is always
self-contained.

3. The entry point executes once per activation. Console output and the
   return value are posted into the conversation as a module message; the
   agent can read and discuss it.
   **Shebang-friendly:** a leading `#!...` line (Node-style shebang) and a
   UTF-8 BOM are stripped automatically before the source runs, so scripts
   copied straight from a Node project work as-is.
   **Setup-first:** when the manifest declares required setup fields, the
   app shows the per-chat setup form instead of running the module; the
   run happens right after the form is submitted (see above).
   **Setup tip:** when a module is selected on a NEW chat (staged), the
   first message you send is exposed to the module as `zagents.info.prompt`
   — modules can still implement commands like `setup <credentials>`,
   `status` or `reset` on that message for re-configuring an already
   set-up chat.

## 3. The `zagents` SDK

Available as a global — or `const zagents = require('zagents-sdk')`.

### `zagents.info`
Metadata: `name`, `version`, `title`, `sessionId`, `entry` — plus `prompt`
(the activating user message) when the run was triggered by a staged
module's first message, `userAgent` — the identity the user picked in
Settings → User Agent — and `setup`: the per-chat setup-form values
submitted for this chat (empty object when not set up yet).

**User-Agent policy:** modules always present the identity configured in
Settings → User Agent. `zagents.http` sends it on every request, and a
module-supplied `User-Agent` header is dropped by the bridge — the
setting wins, always. Read the active identity via
`zagents.info.userAgent` (for display or debugging only).

### `zagents.log(...)` — always available
Console output, captured into the module message.

### `zagents.storage` — permission `storage`
Per-chat key/value store. Different chats NEVER share it.

```js
await zagents.storage.set('visits', 1);
const visits = await zagents.storage.get('visits'); // 1
const keys = await zagents.storage.keys();          // ['visits']
await zagents.storage.remove('visits');
```

Caps: 64 KB per value, 1 MB per (chat, module) store.

### `zagents.fs` — permission `files`
File access confined to the module's per-chat `state/` directory.

```js
await zagents.fs.writeFile('note.txt', 'hello');
const text = await zagents.fs.readFile('note.txt');
await zagents.fs.appendFile('note.txt', '\nmore');
const files = await zagents.fs.readdir('.');
await zagents.fs.mkdir('sub');
await zagents.fs.unlink('note.txt');
const info = await zagents.fs.stat('sub'); // { isDirectory, size, modified }
```

Paths outside the state directory are rejected. Writes are enforced
strictly on the Dart side (v1.43.1): every mutating action
(`writeFile` / `appendFile` / `mkdir` / `unlink`) must resolve under the
run's per-chat `state/` directory — the module's own global program
directory and the npm root stay read-only, so nothing a module persists
can ever reach another chat. Reads of module code (for `require`) keep
working.

### `zagents.http` — permission `network`
HTTP through the app (status + body + response headers), optionally
host-restricted by the manifest `allowedHosts`.

```js
const res = await zagents.http.request('https://api.example.com/data', {
  method: 'POST',
  body: JSON.stringify({ q: 'hi' }),
  headers: { 'Content-Type': 'application/json' },
});
if (res.ok) {
  const data = await res.json();
  const cookie = res.headers['set-cookie']; // lowercased response headers
}
```

Options: `method`, `body`, `headers` (hop-by-hop fields like `Host` and
`Connection` are dropped; `User-Agent` is dropped too — requests always
carry the Settings → User Agent identity, see `zagents.info.userAgent`),
`timeoutMs` (whole-request cap, max 60000) and
`headOnly: true` — return as soon as the status line + headers arrive,
without reading the body (kick off an SSE stream without waiting for it
to end).

### `zagents.agent` — permission `agent`
Ask the chat's own agent (the provider/model configured for THIS chat) to
compose ONE short casual English sentence from the live context your
module supplies. There are no templates: every sentence is generated at
the moment it is needed, and the host enforces the composer contract
before the module sees the text:

* exactly one sentence, casual, human-sounding, English;
* never contains `!` `:` `;` `—` `–` `?` and no emoji;
* at most `maxWords` words (default 24, clamp 1–40);
* never repeats anything passed in `avoid` (recent texts);
* a corrective retry happens automatically, then a deterministic
  sanitize pass — outputs that still violate the rules raise an error so
  the module can skip that action gracefully.

```js
const { text } = await zagents.agent.compose({
  task: 'chat-reply',
  context: recentChatLines.join('\n'),
  instruction: 'react to the last message',
  maxWords: 16,
  avoid: recentSentTexts,
});
```

Failures (no API key, provider down, repeated violations) throw — wrap
the call in try/catch and skip the text action when composition is not
possible.

#### `zagents.agent.polish({ template, context, ... })` — permission `agent` (v1.45.0)

Rewrite a reply TEMPLATE into ONE natural, human-sounding social reply
that answers the incoming message — built for Facebook comment /
Messenger auto-replies and X/Twitter mention auto-replies (see
[`samples/facebook-page/`](../../samples/facebook-page/) and
[`samples/twitter-x/`](../../samples/twitter-x/)). Freer than `compose`:
1–3 sentences, normal punctuation (periods, commas, question marks), and
the reply language matches the sender's language:

* the module fills all template slots itself and passes the final
  template — an unfilled `{slot}` in the output is rejected;
* no markdown, no lists, no invented links (URLs are only allowed when
  the template or the incoming message already had one), no assistant
  phrasing ("as an AI", "hope this helps", …);
* char budget via `maxChars` (default 280, clamped 20–500) instead of a
  word budget; emoji off by default (`allowEmoji: true` allows one);
* every promise/fact in the template must survive — the agent may not
  invent prices, dates, names or features;
* the same validate → corrective retry → sanitize → re-validate pipeline
  as `compose`; failures throw so the module can fall back to its
  template.

```js
const { text } = await zagents.agent.polish({
  template: 'Halo {name}, makasih sudah menghubungi kami...'.replace('{name}', firstName),
  context: incomingCommentText,
  language: 'auto',   // or 'id', 'en', ...
  tone: 'friendly',   // or 'professional', 'casual'
  maxChars: 300,
  allowEmoji: false,
  avoid: recentSentReplies,
});
```

### `zagents.chat` — permission `chat`
Post progressive output into the conversation while running:

```js
await zagents.chat.emit('Step 1 done…');
```

### `zagents.device` — permission `device` (v1.31.0)
Run ONE shell command on the device — rooted-phone automation such as
airplane-mode toggles, VPN switches, profile changes:

```js
const r = await zagents.device.shell('settings get global airplane_mode_on', {
  root: true,     // runs via `su -c` — needs a rooted phone
  timeoutMs: 20000,
});
// r.ok, r.exitCode, r.stdout, r.stderr, r.timedOut, r.error
```

* `root: true` routes the command through `su -c`; without it the command
  runs as the app's own uid via `sh -c`.
* Triple-gated: the manifest `device` permission (user approves at
  activation) AND the Settings → Modules **"Device commands (root)"
  master switch (off by default)** AND the native bridge. Unauthorized
  calls throw `Permission denied: device` / explain the switch.
* Caps: command ≤ 2000 chars, timeout 1–120 s (default 30 s), stdout and
  stderr each capped at 32 KB.
* Failures (missing `su`, spawn errors) return a result with `error` set
  instead of throwing — branch on `r.ok`.
* See [`samples/airplane-mode/`](../../samples/airplane-mode/) for a
  complete rooted automation module using slash commands.

### `zagents.device.airplane()` — permission `device` (v1.32.0)
Read the **airplane-mode state WITHOUT root** from the world-readable
`Settings.Global.AIRPLANE_MODE_ON` setting:

```js
const p = await zagents.device.airplane();
// p.available — true when this platform can read the real state
// p.on        — the actual airplane-mode state
```

* NO root and NOT gated by the "Device commands" master switch — the
  probe cannot change anything, it only reads one harmless setting.
* Works **offline** (no network involved), so a manual airplane module
  can verify the real state while the radio is off and the AI chat is
  unreachable.
* `available: false` (non-Android, missing native side) means "unknown"
  — fall back to manual instructions instead of asserting a state.

```js
// Manual (non-root) pattern — verify, never trust a bare "yes":
const p = await zagents.device.airplane();
if (p.available && p.on) {
  await zagents.log('Airplane mode is ON (verified).');
} else {
  await zagents.log('Still OFF — enable it from Quick Settings, then re-run.');
}
```

### `zagents.device.airplaneCycle(options?)` — permission `device` (v1.34.0)
Rotate the carrier IP with ONE command — the whole airplane-mode cycle in
a single verified call:

```js
const r = await zagents.device.airplaneCycle({ holdMs: 2500, settleMs: 8000 });
// r.wasOn — verified airplane state before the cycle
// r.finalOn — always false: the cycle ALWAYS ends airplane OFF (online)
// r.heldMs, r.settleMs — the applied waits
// r.verified — true when the final OFF state was read back from the device
```

Physics: the phone's data IP changes when the radio RE-REGISTERS — i.e.
when airplane mode goes back OFF. The host therefore runs, in order:

1. read the verified current state (`settings get`, world-readable probe
   as fallback) — never cycle blind;
2. ensure airplane ON — `settings put global airplane_mode_on 1` + the
   legacy `AIRPLANE_MODE` broadcast (one joined command), verified by
   reading back; one retry on a mismatch;
3. HOLD ON (`holdMs`, default 2500 ms, clamped 500–15000) — the radio
   deregisters;
4. airplane OFF — put + broadcast, verified by reading back (one retry)
   — the radio re-registers and the carrier assigns a NEW IP;
5. settle (`settleMs`, default 8000 ms, clamped 0–30000).

* The cycle ALWAYS ends with airplane OFF (online again). Any failing
  verification escalates to a best-effort OFF restore — the phone is
  never left silently in airplane mode.
* Gated exactly like `device.shell`: the `device` permission, the
  Settings → Modules **"Device commands (root)" master switch** and a
  rooted phone (real shell commands). Without root the call rejects with
  an actionable error — fall back to the guided manual mode.
* A run cancelled mid-cycle still restores airplane OFF, then resolves
  with `verified: false`.
* See [`samples/airplane-mode/`](../../samples/airplane-mode/) —
  `/airplane cycle` (aliases: `ip`, `rotate`).

## 4. Isolation model (private window per chat)

* **Process** — every execution boots a fresh JS context; nothing
  survives between runs.
* **State & storage** — `<session>/modules/<name>/` is created per chat;
  `storage.json` and `state/` are invisible to every other chat and to
  other modules.
* **Permissions** — declared in the manifest, approved by the user at
  activation, enforced twice (SDK + Dart bridge).
* **Network** — requires `network`; `allowedHosts` narrows it further.
* **Agent** — requires `agent`; generation goes through the chat's own
  LLM plus the host-side composer gate, so module output stays inside
  the regulated contract.
* **Device** — requires `device`; `device.shell` and `device.airplaneCycle`
  additionally require the Settings master switch (off by default) and are
  meant for rooted phones (the cycle is the verified ON → hold → OFF IP
  rotation); `device.airplane` is a read-only world-readable probe (no
  master switch, no root). Every call re-checked host-side.
* **Resources** — timeout, output caps, storage caps.
* **Termination** — deactivating a module or stopping the chat cancels a
  live run safely: delivery stops, persisted state is kept.

## 5. Minimal example

The same example, ready to install, lives at [`samples/counter/`](../../samples/counter/)
— together with more complete samples covering every permission:

| Sample | Demonstrates |
|---|---|
| [`samples/counter/`](../../samples/counter/) | `storage` — per-chat activation counter |
| [`samples/network-fetcher/`](../../samples/network-fetcher/) | `network` — `zagents.http` + `allowedHosts` |
| [`samples/file-notes/`](../../samples/file-notes/) | `files` — sandboxed note taking under `state/` |
| [`samples/chat-streamer/`](../../samples/chat-streamer/) | `chat` — progressive `chat.emit` output |
| [`samples/onhomeroom-daily/`](../../samples/onhomeroom-daily/) | `agent` — real-world daily bot whose every sentence is composed by the chat agent; per-chat setup form for its account |
| [`samples/airplane-mode/`](../../samples/airplane-mode/) | `device` — rooted airplane-mode toggle + one-command carrier-IP rotation driven by the `/airplane cycle \| on \| off \| status` slash commands (v1.31.0, cycle v1.34.0) |
| [`samples/facebook-page/`](../../samples/facebook-page/) | `agent` (`polish`) + `network` — fanspage assistant: auto-reply comments + Messenger with templates polished live by the chat agent, per-chat Page token via the setup form (`/fb` v1.45.0) |
| [`samples/twitter-x/`](../../samples/twitter-x/) | `agent` (`polish`) + `network` — X/Twitter mention auto-replies with a pure-JS OAuth 1.0a signer, per-chat user keys via the setup form (`/tw` v1.45.0) |

`module.json`

```json
{
  "name": "hello-counter",
  "version": "1.0.0",
  "title": "Hello Counter",
  "description": "Counts activations per chat.",
  "permissions": ["storage"]
}
```

`main.js`

```js
async function main() {
  const previous = (await zagents.storage.get('count')) || 0;
  await zagents.storage.set('count', previous + 1);
  zagents.log('Hello from the module! Count in THIS chat: ' + (previous + 1));
  return { count: previous + 1 };
}
module.exports = main();
```
