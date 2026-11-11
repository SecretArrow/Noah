/// `/make_plugins` — build a NEW chat module (plugin) from inside a
/// running chat session.
///
/// The user types `/make_plugins <description>` (aliases: `/make_plugin`,
/// `/make_module`, `/make_modules`, case-insensitive). The command stays
/// in the transcript verbatim, but the WIRE text the model receives is
/// expanded into the [makePluginsBuilderPrompt] specification below so
/// the agent follows the exact, installable module layout. The expansion
/// is deterministic (same input -> same brief), so replaying the history
/// on later turns re-produces the identical wire text.
///
/// Whether the plugin may use session data is the USER'S choice made in
/// the description: if it references this chat's messages or workspace
/// files, the brief tells the agent to copy that data INTO the module
/// folder (modules are isolated and cannot read the chat workspace at
/// runtime); otherwise the plugin is built standalone.
library;

/// Matches a make-plugins command at the start of [text] (trimmed,
/// case-insensitive). Returns the remainder after the command — the
/// build description, possibly empty — or null when [text] is not a
/// make-plugins command.
String? matchMakePluginsCommand(String text) {
  final String trimmed = text.trim();
  final Match? match = RegExp(
    r'^/make_(plugins?|modules?)\b',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) return null;
  return trimmed.substring(match.end).trim();
}

/// True when [text] is a make-plugins command (any alias).
bool isMakePluginsCommand(String text) => matchMakePluginsCommand(text) != null;

/// Expands a chat message for the LLM wire: make-plugins commands become
/// the builder specification; everything else passes through untouched.
String expandMakePluginsPrompt(String text) {
  final String? args = matchMakePluginsCommand(text);
  if (args == null) return text;
  return makePluginsBuilderPrompt(args);
}

/// The builder specification sent to the model in place of the raw
/// command. [request] is what the user typed after `/make_plugins` (may
/// be empty — the brief then tells the model to ask first).
///
/// Every claim here mirrors the real runtime contract: CommonJS entry,
/// permission names (`storage, network, files, chat, agent`), the
/// `zagents` SDK surface, storage caps, the setup form and the
/// stage -> user-confirmed-install flow (`module_stage_repair`).
String makePluginsBuilderPrompt(String request) {
  final String description = request.trim().isEmpty
      ? '(no description given — do NOT build anything yet. Reply in the '
            'user\'s language asking 2-4 short questions about what the '
            'plugin should do, then stop and wait for their next message.)'
      : '```\n${request.trim()}\n```';
  return '''
# Task: build a NEW Noah chat module (plugin) from this chat

The user typed a `/make_plugins` command. Build a complete, installable
module in THIS chat's workspace and stage it for the user to install.
The user request is below; follow the specification exactly.

## User request
$description

## Session-data policy
If the request references data from THIS chat (messages above, uploaded
files under `uploads/`, files in this workspace), USE it: copy the needed
data INTO the module folder so the zip is self-contained. Modules run
isolated — at runtime they CANNOT read this chat workspace; their only
writable scope is their own per-chat `state/` directory via `zagents.fs`.
If the request does not reference session data, build standalone.

## Step 1 — module folder
Create `plugins/<module-name>/` in this workspace with `write_file`.
Files sit at the folder ROOT: `module.json`, the entry script (default
`main.js`) and any extra files (require them by relative path, e.g.
`require('./lib/util.js')`).

## Step 2 — module.json (manifest)
```json
{
  "name": "lowercase-a-z-0-9-max-40-chars",
  "version": "1.0.0",
  "title": "Human Name",
  "description": "What it does — shown to the user and injected into chats.",
  "entry": "main.js",
  "permissions": ["storage", "network", "files", "chat", "agent"],
  "allowedHosts": ["api.example.com"],
  "timeoutSeconds": 30,
  "setup": { "title": "...", "description": "...", "fields": [] }
}
```
- `permissions`: declare ONLY what the code uses — `storage`, `network`,
  `files`, `chat`, `agent` — the user approves them at activation.
- `allowedHosts` (network only): host allowlist, `*.example.com`
  wildcards allowed. Omit for any host.
- `timeoutSeconds`: per-run budget, default 30, max 120.
- `setup` (optional): per-chat form collected BEFORE the first run; the
  values arrive as `zagents.info.setup`. Fields:
  `{"key":"api_key","label":"API key","type":"text|password|number|boolean",
  "required":true,"placeholder":"...","description":"..."}` (keys are
  lowercase `[a-z0-9_]`). Omit the block entirely when no input is needed.

## Step 3 — entry script (CommonJS ONLY)
Plain CommonJS: `require` / `module.exports`; top-level `await` works.
NEVER emit ES-module syntax (`import` / `export`) — it fails to parse.
The entry executes ONCE per activation; console output (`zagents.log`,
`console.log`) and the final return value post into the chat as a module
message. Persist state between activations with `zagents.storage`.

SDK — the global `zagents` (or `const zagents = require('zagents-sdk')`);
every part is gated by its permission:
- `zagents.info`: `{name, version, title, sessionId, entry, prompt,
  userAgent, setup}` (metadata for this run/chat).
- `zagents.log(...)`: console output captured into the module message.
- `zagents.storage.get/set/keys/remove` (perm `storage`): per-chat
  key/value store; 64 KB per value, 1 MB per chat.
- `zagents.fs.writeFile/readFile/appendFile/readdir/mkdir/unlink/stat`
  (perm `files`): confined to the module's per-chat `state/` directory.
- `zagents.http.request(url, {method, body, headers, timeoutMs, headOnly})`
  (perm `network`): goes through the app; response
  `{ok, status, headers, text(), json()}`; `timeoutMs` max 60000;
  `headOnly: true` returns after the status line + headers (start SSE
  streams without waiting for the body). The User-Agent always comes
  from the user's Settings — a custom UA header is dropped.
- `zagents.agent.compose({context, maxWords, avoid})` (perm `agent`):
  returns `{text}` — ONE short, casual, human-sounding English sentence
  composed live by this chat's model (never a template). Honor the
  composer contract; skip gracefully when it errors.
Handle errors: wrap awaits in try/catch, degrade gracefully, never crash
the whole run for one failing step.

## Step 4 — self-check before packaging
You cannot execute a module directly here, so:
1. Validate `module.json` parses: `node_run` with
   `JSON.parse(require('fs').readFileSync('plugins/<module-name>/module.json','utf8'))`.
2. Dry-run the core logic with `node_run` (CommonJS) against a STUBBED
   `zagents` object to catch syntax and logic errors before packaging.

## Step 5 — package + stage
1. `zip_file` the FOLDER `plugins/<module-name>` — the archive appears
   next to it as `plugins/<module-name>.zip`.
2. Call `module_stage_repair` with the zip path
   (`plugins/<module-name>.zip`). It validates the archive (manifest,
   entry, size caps, path safety) and shows the user an Install card.
NEVER claim the plugin is installed — the USER decides by tapping
Install on the card. After install it appears on the Modules screen and
starts in any chat with `/plugins <name>` or the `/plugins` menu. Every
chat gets its own isolated storage/state and its own setup form.

## Step 6 — final answer (in the user's language)
Summarize: what the plugin does, which permissions it needs and why,
any setup it will ask for. Then tell the user to tap Install on the card
and start it with `/plugins <name>` (or the /plugins menu).
''';
}
