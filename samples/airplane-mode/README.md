# Airplane Mode — sample ZAgents chat module

Controls Android **airplane mode** from the chat and **rotates the carrier
IP**. Two modes, chosen per device automatically — no blind trust anywhere:
every report states the ACTUAL verified state.

## Usage

1. Install the ZIP (Settings → Modules → Install module, or Files screen).
2. In any chat:
   * pick the module from the module picker, then type `/airplane cycle` as
     the first message — or simply type `/airplane cycle` at any point in a
     chat (the module auto-activates and runs — no LLM involved);
   * `/airplane cycle` (aliases: `ip`, `rotate`) runs the ONE-command IP
     rotation on rooted phones: airplane ON → hold → OFF → settle. The
     carrier assigns a NEW IP when the radio re-registers (airplane back
     OFF), so the cycle always ends OFF — online again;
   * `/airplane off` disables it, `/airplane status` reports the state
     and the active mode (AUTO / MANUAL).

## CYCLE mode — rotate the carrier IP (v1.3, rooted)

* One command via `zagents.device.airplaneCycle`: the bridge ensures
  airplane ON (the radio deregisters), holds it briefly, turns airplane
  OFF (the radio re-registers and the carrier hands out a NEW IP), then
  settles — every step verified by reading the setting back, and the
  cycle ALWAYS ends with airplane OFF (online).
* Purpose: a fresh carrier IP on demand (e.g. after rate-limits or
  IP-flagged sessions).
* Requires root + Settings → Modules → **Device commands (root)**. On
  non-rooted devices the module prints the guided-manual fallback
  (`/airplane on` / `off` steps) instead.

## AUTO mode — rooted phones

* Requires `su` (grant ZAgents) **and** Settings → Modules →
  **Device commands (root)** switched ON (off by default).
* `cmd connectivity airplane-mode enable|disable` first, fallback
  `settings put global airplane_mode_on 0|1` + legacy `AIRPLANE_MODE`
  broadcast, then a verification read-back.

## MANUAL mode — non-rooted phones (v1.32.0)

* No root needed; the state is read from the **world-readable native
  probe** (`zagents.device.airplane`), which works OFFLINE.
* `/airplane on` / `off` print the exact guided steps; the user flips the
  radio from Quick Settings, and `/airplane status` verifies the REAL
  state — a bare "yes" is never trusted.
* The commands run **app-side**, so they keep working while airplane mode
  is ON and the AI chat itself is unreachable.
* While airplane mode is ON the AI chat is offline (expected). Turn it
  back OFF when done: auto-retry (v1.30.0+) delivers the queued messages
  and the task continues automatically — no retry budget is burned while
  the radio is off. The agent can double-check the state with its
  `device_status` tool at any time.

## Requirements

* ZAgents v1.34.0+ for `/airplane cycle` (`zagents.device.airplaneCycle`);
  v1.32.0+ for the airplane probe + `device_status` agent tool.
* Rooted phone only for AUTO toggles and the IP cycle; MANUAL mode works
  on any device.

Package and install: see [`../README.md`](../README.md).
