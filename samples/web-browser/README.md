# Web Browser (sample module)

A **text-mode web browser** that lives inside a ZAgents chat. It turns the
conversation into a browsing session: open pages in reader mode, page
through long articles, list and follow numbered links, search the web with
fallback engines, and go back in history — all per chat, all sandboxed.

```
Web Browser · /web
├─ open <url>      reader mode: title, description, cleaned text
├─ more            next page of the current text (82 lines/page)
├─ links [page]    numbered link table (25/page)
├─ goto <n>        follow link #n (page listings AND search results)
├─ search <query>  DuckDuckGo Lite → HTML → Mojeek → Wikipedia →
│                  DuckDuckGo Instant Answers (first engine that answers)
├─ back            this chat's navigation history (25 entries)
├─ raw <url>       raw body preview — JSON/XML/API debugging
├─ status          current page, cursor, link count, history depth
├─ clear           wipe this chat's browser profile
└─ help
```

## Why "browser" without a webview

ZAgents modules run in a fresh JavaScript context per run — there is no
rendering surface. So this module does what lynx/w3m did: it fetches HTML
through `zagents.http.request`, strips scripts/styles/nav/footer noise,
prefers `<article>/<main>` content, keeps headings (`## `) and list items
(`• `), decodes entities, and prints clean text. Links are absolutized
(relative, `//`, `../`, `?query` forms all resolve) into a numbered table.

## Address-bar mode

When the module is staged and you send a plain message (no leading `/`),
`zagents.info.prompt` is treated like an address bar:

- something URL-shaped (`example.com`, `https://…`) → **open**
- anything else → **search**

## Network scope — intentionally unrestricted

The manifest declares `network` **without `allowedHosts`**: a browser must
be able to reach any site the user asks for. Every other capability stays
sandboxed — the browsing profile (current page, link table, history) is
per-chat storage, so two chats never share state, and no file/device/agent
permissions are requested.

## Anti-bot reality

Some sites and search engines serve challenge pages to non-browser
clients. The module detects 403/429/202 + challenge markup and says so
instead of dumping garbage; search falls through five engines (including
the plain JSON Wikipedia and DuckDuckGo Instant Answer APIs, which never
challenge) until one returns real results.

## Files

- `module.json` — manifest (`network`, `storage`, `chat`; command `web`)
- `main.js` — command router, fetch/extract engine, search engines

## Try it

1. Install the ZIP: **Settings → Modules → Install module**.
2. `/web open example.com`
3. `/web links` → `/web goto 2`
4. `/web search flutter dart`
5. `/web more` · `/web back` · `/web raw https://api.github.com/zen`
