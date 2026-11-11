# OnHomeroom Daily — advanced sample (permissions: `storage`, `network`, `agent`)

A real-world module converted from the standalone **onhomeroom-bot** script
(the uploaded `onhomeroom-daily.zip`). It works
[app.onhomeroom.com](https://app.onhomeroom.com) one paced cycle per
activation — the challenge board first, then the routine tasks — and every
sentence it publishes is **composed live by the chat's own agent** via
`zagents.agent.compose`. The old hand-written fragment tables are gone:
there are no templates, no message pools, no canned replies — and no
canned app-idea list either: when the board asks for a build request, the
agent invents the whole app concept (name + what it does) on the spot.

## What it does per activation

1. **Auto login** — session cookie is kept in THIS chat's storage; re-login
   only when the session expires.
2. **Challenge board** (`#leaderboard/challenges`) — reads every challenge
   and works what can be worked: try N apps, send useful feedback, propose
   an app change (issue → builder review → up for the vote), join apps,
   build requests. What only a human can do (invites, external accounts)
   is reported honestly and never acted.
3. **Votes — always YES** on every open proposal it can reach.
4. **One chat reply** in `#general` — the agent reads the last lines and
   composes one casual sentence that fits the topic. Quiet if the last
   message is yours or very recent.
5. **DM answers & decisions** — homeroom-bot question cards, green-lights
   and approvals are handled through the agent's one-sentence replies.
6. **Try apps** — opens untried running apps and spends a short dwell
   inside them (activity pings, like an open tab).
7. **Run summary** — a compact stats line is emitted at the end; state is
   persisted so the next activation continues where this one stopped.

One activation performs **at most one text submission** (the others are
skipped and carried over), and the human pacing window
(`textGapSeconds`, default 60s) is anchored across activations through the
persisted `lastTextAt` — fast re-activations respect the same rule a real
member typing on the site would.

## Setup (per chat, private-window style)

State never mixes between chats: each chat holds its own credentials,
session, counters and pipelines.

1. Install the module ZIP (Settings → Modules → Install module).
2. On a **new chat**, pick **OnHomeroom Daily** and send as the first
   message:

   ```
   setup your-email@example.com your-password
   ```

   The message is exposed to the module as `zagents.info.prompt`; the
   module stores the credentials in the chat's own storage and starts the
   first cycle immediately.
3. Later: deactivate/reactivate the module (or `/plugins onhomeroom-daily`
   again) to run another cycle. Useful commands:

   ```
   status    print the saved state summary (no login)
   reset     wipe the runtime state (credentials kept)
   ```

## Composer — agent-backed (the point of this sample)

Where the original script picked from hand-written fragment arrays (and a
hand-written app-idea table for build requests), this module asks the chat
agent for every sentence — including the app concept itself:

```js
// the agent invents the app, then describes it, then wraps the request
const { title, body } = await Composer.buildAppIdea(usedTitles);

const { text } = await zagents.agent.compose({
  task: 'chat-reply',
  context: recentChatLines.join('\n'),
  instruction: 'react to the last message',
  maxWords: 16,
  avoid: recentlySentTexts,
});
```

The host regulates every output: exactly one casual English sentence, no
`!` `:` `;` `—` `–` `?`, no emoji, word cap, no repeats of the `avoid`
list, with an automatic corrective retry plus a deterministic sanitize
pass. Composer failures (missing API key, provider down) degrade
gracefully — the affected action is skipped and logged, never replaced
with canned text. That includes the green-light DM: when the site ships
no button label for a decision card, the agent composes the go-ahead
sentence, and if composing fails the card simply waits for the next
activation.

## Config knobs (stored in the chat's `config`)

`account` (set via `setup`), `pacing` (call pauses, text gap, dwell per
app), `tasks` (challenges / vote / chat / tryApps / propose / buildApp —
each with an `enabled` switch), `agent.model` (the model the SITE's
builder uses for change sessions — unrelated to your chat agent, which is
configured in ZAgents Settings).

## Notes

* Manifest `allowedHosts` is `*.onhomeroom.com` — app + every app
  subdomain, nothing else.
* `timeoutSeconds: 120` (the maximum); the module keeps its own internal
  100 s deadline so state always survives.
* The "propose an app change" pipeline deliberately spans several
  activations: file issue → builder review → up for the vote. Progress is
  tracked in the chat's storage.
