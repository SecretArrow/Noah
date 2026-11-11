# Module Documentation

Official documentation for **Noah chat modules** (plugins).

| Document | Language | Contents |
|---|---|---|
| [`sdk-reference-en.md`](sdk-reference-en.md) | English | Package layout, manifest, installation, full `zagents` API reference, isolation model, examples |
| [`sdk-reference-id.md`](sdk-reference-id.md) | Bahasa Indonesia | Same reference in Indonesian |

Both references ship **inside the app** as well: *Settings → Modules →
SDK docs* (language follows the app language).

## Related directories

* [`../sdk/`](../sdk/) — the official SDK (`zagents-sdk.js`, TypeScript
  definitions `index.d.ts`, `package.json`).
* [`../../samples/`](../../samples/) — complete, installable example
  modules covering every permission (`storage`, `network`, `files`,
  `chat`).

## Building a module from chat

Since v1.27.0 you can also have the chat agent BUILD a module for you:
type **`/make_plugins <description>`** (aliases `/make_plugin`,
`/make_module`) in any running chat. The agent scaffolds the folder,
packs a valid zip and stages it behind a confirmation card — you decide
whether to install. Session data (uploads, files, earlier messages) is
baked into the module when your description asks for it.

## Quick manifest checklist

- [ ] `name` — lowercase `[a-z0-9._-]`, max 40 chars (also the install
      directory name)
- [ ] `entry` — JavaScript entry point present in the ZIP (default
      `main.js`)
- [ ] `permissions` — request the minimum set the module needs
- [ ] `allowedHosts` — declare when the module talks to the network
- [ ] `timeoutSeconds` — raise only when the workload needs it
      (max 120)
