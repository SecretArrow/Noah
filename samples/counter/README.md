# Hello Counter (sample)

Minimal ZAgents chat module demonstrating the **`storage`** permission:
a per-chat activation counter.

* Manifest: `module.json` — requests only `storage`.
* Entry: `main.js` — `zagents.storage.get/set/keys` + `zagents.log`.
* Isolation demo: the counter is stored **per chat** — running the
  module twice in one chat counts 1 → 2; a different chat starts
  from 1 again.

Package and install: see [`../README.md`](../README.md).
