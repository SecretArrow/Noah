# RSS Reader (sample module)

A **per-chat RSS/Atom feed reader** in the conversation: subscribe to any
RSS 2.0 or Atom feed, read the latest items, get a merged newest-first
digest across all subscriptions, and refresh to see only what is new —
with read-state tracked per chat.

```
RSS Reader · /rss
├─ add <url> [label]   subscribe (fetches + validates the feed first)
├─ list                subscriptions + unread counts
├─ read <n> [count]    read feed #n (default 10 items, 🆕 marks unread)
├─ latest [count]      all feeds merged, newest first
├─ refresh             re-fetch all feeds, report only NEW items
├─ remove <n> + confirm  unsubscribe (two-step, 10-minute window)
└─ help
```

## Feed formats

The parser is a small, tolerant regex pipeline covering both worlds:

- **RSS 2.0** — `<item>`, `title/link/guid/pubDate/description`, plus
  `content:encoded` and `dc:date` namespace extensions
- **Atom** — `<entry>`, `title/link@href(alternate)/id/published|updated/summary`

CDATA blocks, numeric entities and the common five named entities are
decoded; summaries are clipped to 200 chars so a feed never floods the
chat (run output is capped at 400 lines).

## Per-chat subscriptions

Everything lives in `zagents.storage` under this chat's key: feed list,
cached items (60/feed) and the `seen` map (250 GUIDs, LRU-trimmed). Items
present at subscribe-time start as *read*, so `/rss refresh` only ever
announces items published afterwards. Another chat starts empty by design.

## Network scope — intentionally unrestricted

The manifest declares `network` **without `allowedHosts`**: feeds can live
on any host the user chooses. No files, device or agent permissions.

## Files

- `module.json` — manifest (`network`, `storage`, `chat`; command `rss`)
- `main.js` — command router + RSS/Atom parser + read-state store

## Try it

1. Install the ZIP: **Settings → Modules → Install module**.
2. `/rss add https://hnrss.org/frontpage HN`
3. `/rss read 1 5`
4. `/rss latest 15`
5. Later: `/rss refresh` → only new items are announced.
