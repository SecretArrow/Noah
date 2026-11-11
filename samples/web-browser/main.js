/**
 * Web Browser — a text-mode web browser inside the ZAgents chat (sample module).
 *
 * Demonstrates: `zagents.http.request` with an intentionally UNRESTRICTED
 * manifest (no `allowedHosts` — a browser must reach any host), heavy pure-JS
 * HTML post-processing, per-chat `zagents.storage` as the browser profile
 * (current page, link table, navigation history), and `zagents.info.prompt`
 * as the address bar (both the `/web …` command path and the staged-module
 * plain-message path).
 *
 * Commands (manifest `commands: ["web"]` routes `/web …` here):
 *   /web open <url>     open a URL in reader mode (first page of text)
 *   /web more           next page of the current page's text
 *   /web links [n]      numbered links of the current page (25 per page)
 *   /web goto <n>       follow link #n from the last listing or search
 *   /web search <q>     web search (DuckDuckGo Lite/HTML, Mojeek, with
 *                       Wikipedia + DuckDuckGo Instant Answers fallbacks)
 *   /web back           back in this chat's navigation history
 *   /web raw <url>      raw body preview (JSON / XML / API debugging)
 *   /web status         current page, history depth, link count
 *   /web clear          wipe this chat's browser profile
 *   /web help           this help
 *
 * A staged activation with a plain message (no leading "/") is treated like
 * an address bar: something URL-shaped opens, anything else searches.
 *
 * Sample quality notes: the HTML → text extraction is deliberately small
 * (regex pipeline, no DOM) — good for articles and docs, not a layout
 * engine. Everything is per-chat: another chat browses with a clean slate.
 */
async function main() {
  const info = zagents.info;
  const raw = (info.prompt || '').trim();
  // strip the leading slash keyword ("/web …" → rest of the line)
  const argv = raw.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
  const state = (await zagents.storage.get('wb')) || newState();
  let out = [];

  const say = (...xs) => { out.push(xs.map(String).join(' ')); };

  // ------------------------------------------------------------- commands
  if (!argv || argv === 'help') {
    help(say);
  } else if (argv === 'status') {
    statusCmd(say, state);
  } else if (argv === 'clear') {
    await zagents.storage.remove('wb');
    say('🧹 Browser profile for this chat cleared (history, page, links).');
  } else if (argv === 'more') {
    moreCmd(say, state);
  } else if (argv.startsWith('open ')) {
    await openCmd(say, state, argv.slice(5).trim());
  } else if (argv === 'back') {
    await backCmd(say, state);
  } else if (argv.startsWith('links')) {
    await linksCmd(say, state, argv.slice(5).trim());
  } else if (argv.startsWith('goto ')) {
    await gotoCmd(say, state, argv.slice(5).trim());
  } else if (argv.startsWith('search ')) {
    await searchCmd(say, state, argv.slice(7).trim());
  } else if (argv.startsWith('raw ')) {
    await rawCmd(say, argv.slice(4).trim());
  } else if (/^(open|links|goto|search|raw)$/.test(argv)) {
    say('Usage:');
    say('  /web ' + argv + ' <' +
        (argv === 'goto' || argv === 'links' ? 'number' :
         argv === 'search' ? 'query' : 'url') + '>');
  } else {
    // staged activation with a plain message → treat like an address bar
    if (looksLikeUrl(argv)) await openCmd(say, state, argv);
    else await searchCmd(say, state, argv);
  }

  for (const line of out) await zagents.log(line);
  return { module: 'web-browser', handled: argv || '(staged)' };
}

// ============================================================ state / help

function newState() {
  return { url: null, title: null, text: '', cursor: 0,
           links: [], linkSource: null, history: [] };
}

const VIEW_LINES = 82;      // text lines per page (output cap is 400 lines/run)
const LINKS_PER_PAGE = 25;  // links per /web links page
const MAX_TEXT_CHARS = 32000;
const MAX_LINKS = 120;
const MAX_HISTORY = 25;

function help(say) {
  say('🌐 Web Browser — text-mode browsing in this chat. Commands:');
  say('  /web open <url>    open a page in reader mode');
  say('  /web more          next page of the current page');
  say('  /web links [page]  numbered links (25/page)');
  say('  /web goto <n>      follow link #n (listings & search results)');
  say('  /web search <q>    search the web (DuckDuckGo → Mojeek →');
  say('                     Wikipedia/DDG-Instant fallbacks)');
  say('  /web back          back in history');
  say('  /web raw <url>     raw body preview (JSON/API)');
  say('  /web status · /web clear · /web help');
  say('');
  say('Tip: stage this module and just type a URL or a question — it is');
  say('treated like an address bar (URL-shaped → open, else → search).');
  say('The page text and links live in THIS chat only (per-chat storage).');
}

function statusCmd(say, s) {
  if (!s.url) {
    say('🌐 No page open. Try /web open <url> or /web search <query>.');
    return;
  }
  say('🌐 Current: ' + s.url);
  if (s.title) say('   Title: ' + s.title);
  say('   Text loaded: ' + s.text.split('\n').length + ' lines · read up to line ' + s.cursor);
  say('   Links: ' + s.links.length + (s.linkSource ? ' (source: ' + s.linkSource + ')' : ''));
  say('   History: ' + s.history.length + ' entr' + (s.history.length === 1 ? 'y' : 'ies') + ' back');
}

// ================================================================ fetching

async function fetchBody(url, method) {
  let resp;
  try {
    resp = await zagents.http.request(url, { method: method || 'GET', timeoutMs: 20000 });
  } catch (e) {
    throw new Error('request failed — ' + (e && e.message ? e.message : e));
  }
  const body = await resp.text();
  return { resp, body };
}

function hostOf(u) {
  const m = /^https?:\/\/([^/:?#]+)/i.exec(u);
  return m ? m[1].toLowerCase() : '(unknown)';
}

async function openCmd(say, s, target) {
  const url = normalizeUrl(target);
  if (!url) { say('❌ Not a URL: "' + target + '". Try /web open example.com'); return; }
  const { resp, body } = await fetchBody(url);
  if (!resp.ok) {
    say('❌ HTTP ' + resp.status + ' from ' + hostOf(url) + ' — ' + url);
    if (resp.status === 403 || resp.status === 429 || resp.status === 202) {
      say('   The site is likely bot-blocking non-browser traffic. Try');
      say('   another URL, or /web search to find an accessible mirror.');
    }
    return;
  }
  const ctype = String(resp.headers['content-type'] || '');
  if (/json/i.test(ctype) || /^\s*[[{]/.test(body)) return openJson(say, s, url, body);
  if (/html/i.test(ctype) || /<html[\s>]/i.test(body)) {
    return openHtml(say, s, url, body);
  }
  // plain text / xml / anything else
  const text = capText(decodeEntities(stripTags(body)).trim());
  await setPage(s, url, hostOf(url), text, []);
  say('📄 ' + url + '  (' + ctype.split(';')[0].trim() + ', ' + body.length + ' chars)');
  printTextPage(say, s);
}

function openJson(say, s, url, body) {
  let pretty = body;
  try { pretty = JSON.stringify(JSON.parse(body), null, 2); } catch (_) { /* raw */ }
  pretty = capText(pretty, MAX_TEXT_CHARS);
  say('🧾 JSON · ' + url);
  const lines = pretty.split('\n').slice(0, VIEW_LINES);
  for (const l of lines) say(l);
  const left = pretty.split('\n').length - VIEW_LINES;
  if (left > 0) say('… +' + left + ' more lines — /web raw ' + url + ' to inspect in raw mode.');
}

async function openHtml(say, s, url, body) {
  const r = extractReadable(body, url);
  await setPage(s, url, r.title || hostOf(url), r.text, r.links);
  say('📄 ' + (r.title || hostOf(url)));
  if (r.site && r.site !== r.title) say('   ' + hostOf(url) + ' · ' + r.text.split('\n').length + ' lines · ' + r.links.length + ' links');
  if (r.description) say('   ' + clip(r.description, 200));
  say('');
  printTextPage(say, s);
  if (s.links.length) say('🔗 ' + s.links.length + ' links — /web links to list, /web goto <n> to follow.');
}

async function setPage(s, url, title, text, links) {
  if (s.url && s.url !== url) {
    s.history.push(s.url);
    if (s.history.length > MAX_HISTORY) s.history.shift();
  }
  s.url = url; s.title = title; s.text = text; s.cursor = 0;
  s.links = links.slice(0, MAX_LINKS); s.linkSource = 'page';
  await zagents.storage.set('wb', s);
}

function printTextPage(say, s) {
  const lines = s.text.split('\n');
  const start = s.cursor;
  const slice = lines.slice(start, start + VIEW_LINES);
  if (!slice.length) { say('(end of page — /web open another URL or /web back)'); return; }
  for (const l of slice) say(l);
  s.cursor = start + slice.length;
  const left = lines.length - s.cursor;
  if (left > 0) say('');
  if (left > 0) say('… +' + left + ' more lines — /web more');
  // cursor is view-state; persist it best-effort (storage failures must not break reading)
  zagents.storage.set('wb', s).catch(() => {});
}

function moreCmd(say, s) {
  if (!s.url) { say('No page open — /web open <url> first.'); return; }
  printTextPage(say, s);
}

async function backCmd(say, s) {
  if (!s.history.length) { say('History is empty — nothing to go back to.'); return; }
  const prev = s.history.pop();
  await zagents.storage.set('wb', s);
  say('⬅️ ' + prev);
  return openCmd(say, s, prev);
}

async function linksCmd(say, s, pageArg) {
  if (pageArg && /^\d+$/.test(pageArg) && s.url && s.links.length) {
    return printLinks(say, s, parseInt(pageArg, 10));
  }
  if (pageArg) { // /web links <url> — fetch a page and list ITS links
    const url = normalizeUrl(pageArg);
    if (!url) { say('❌ Not a URL: "' + pageArg + '"'); return; }
    const { resp, body } = await fetchBody(url);
    if (!resp.ok) { say('❌ HTTP ' + resp.status + ' from ' + hostOf(url)); return; }
    const r = extractReadable(body, url);
    s.links = r.links.slice(0, MAX_LINKS); s.linkSource = 'page:' + url;
    await zagents.storage.set('wb', s);
    say('🔗 ' + r.links.length + ' links on ' + (r.title || hostOf(url)) + ':');
    return printLinks(say, s, 1);
  }
  if (!s.links.length) { say('No links yet — /web open <url> or /web search first.'); return; }
  printLinks(say, s, 1);
}

function printLinks(say, s, page) {
  const pages = Math.max(1, Math.ceil(s.links.length / LINKS_PER_PAGE));
  const p = Math.min(Math.max(1, page), pages);
  const slice = s.links.slice((p - 1) * LINKS_PER_PAGE, p * LINKS_PER_PAGE);
  for (const l of slice) {
    say(String(l.n).padStart(3) + '. ' + clip(l.text, 72));
    say('      ' + l.url);
  }
  say('');
  say('— page ' + p + '/' + pages + ' · /web links ' + (p < pages ? (p + 1) : 1) + ' · /web goto <n> to open');
}

async function gotoCmd(say, s, nArg) {
  const n = parseInt(nArg, 10);
  if (!n || n < 1 || n > s.links.length) {
    say('❌ No link #' + nArg + '. /web links shows the current table (' + s.links.length + ' links).');
    return;
  }
  const link = s.links[n - 1];
  say('➡️ [' + n + '] ' + link.text);
  return openCmd(say, s, link.url);
}

async function rawCmd(say, target) {
  const url = normalizeUrl(target);
  if (!url) { say('❌ Not a URL: "' + target + '"'); return; }
  const { resp, body } = await fetchBody(url);
  say('🧾 RAW ' + resp.status + ' · ' + url);
  say('   content-type: ' + String(resp.headers['content-type'] || '(none)').split(';')[0]);
  const head = capText(body, 2800);
  for (const l of head.split('\n').slice(0, 60)) say(l);
}

// ================================================================ search

async function searchCmd(say, s, query) {
  if (!query) { say('Usage: /web search <query>'); return; }
  say('🔍 Searching: "' + query + '"');
  const engines = [
    { name: 'duckduckgo-lite', fn: searchDdgLite },
    { name: 'duckduckgo-html', fn: searchDdgHtml },
    { name: 'mojeek', fn: searchMojeek },
    { name: 'wikipedia', fn: searchWikipedia },
    { name: 'ddg-instant', fn: searchDdgInstant },
  ];
  for (const eng of engines) {
    let results = null;
    try { results = await eng.fn(query); } catch (_) { results = null; }
    if (results && results.length) {
      say('✅ ' + results.length + ' results via ' + eng.name);
      say('');
      const links = [];
      results.slice(0, MAX_LINKS).forEach((r, i) => {
        links.push({ n: i + 1, url: r.url, text: r.title });
        say(String(i + 1).padStart(3) + '. ' + clip(r.title, 72));
        if (r.snippet) say('      ' + clip(r.snippet, 90));
        say('      ' + r.url);
      });
      s.links = links; s.linkSource = 'search:' + eng.name;
      if (s.history.length > MAX_HISTORY) s.history.shift();
      await zagents.storage.set('wb', s);
      say('');
      say('➡️ /web goto <n> opens a result · /web search <q> searches again');
      return;
    }
  }
  say('❌ No search engine returned results (they may be bot-challenging');
  say('   this network). Try again in a moment, or /web open a known URL.');
}

function unwrapDdgRedirect(href) {
  if (!href) return href;
  const m = /[?&]uddg=([^&]+)/.exec(href);
  return m ? decodeURIComponent(m[1]) : href;
}

// generic anchor harvest: attrs-agnostic, works for all engine layouts
function harvestAnchors(html, opts) {
  const keep = [];
  const re = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html))) {
    const attrs = m[1];
    const inner = decodeEntities(stripTags(m[2])).replace(/\s+/g, ' ').trim();
    const hrefm = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(attrs);
    if (!hrefm) continue;
    const raw = hrefm[1] || hrefm[2] || hrefm[3] || '';
    if (opts.classRe && !opts.classRe.test(attrs)) continue;
    // unwrap engine redirects (e.g. DDG's /l/?uddg=…) BEFORE the protocol
    // check — those links start with "//duckduckgo.com/l/" by design
    const href = opts.unwrap ? opts.unwrap(raw) : raw;
    if (opts.excludeRe && opts.excludeRe.test(href)) continue;
    if (!opts.allowRelative && !/^https?:\/\//i.test(href)) continue;
    if (!inner || inner.length < 2) continue;
    keep.push({ href: href, text: inner });
    if (keep.length >= (opts.limit || 60)) break;
  }
  return keep;
}

async function searchDdgLite(q) {
  const { resp, html } = await (async () => {
    const r = await fetchBody('https://lite.duckduckgo.com/lite/?q=' + encodeURIComponent(q));
    return { resp: r.resp, html: r.body };
  })();
  const anchors = harvestAnchors(html, {
    classRe: /result-link/i, unwrap: unwrapDdgRedirect, limit: 25,
  });
  const snippets = [];
  const sre = /class="result-snippet"[^>]*>([\s\S]*?)<\/td>/gi;
  let sm;
  while ((sm = sre.exec(html)) && snippets.length < anchors.length) {
    snippets.push(decodeEntities(stripTags(sm[1])).replace(/\s+/g, ' ').trim());
  }
  const results = anchors.map((a, i) => ({
    url: a.href, title: a.text, snippet: snippets[i] || '',
  })).filter(r => looksLikeUrl(r.url));
  return results.length ? results : null;
}

async function searchDdgHtml(q) {
  const { resp, body } = await fetchBody('https://html.duckduckgo.com/html/?q=' + encodeURIComponent(q));
  if (!resp.ok || /anomaly|challenge/i.test(body.slice(0, 2000))) return null;
  const anchors = harvestAnchors(body, {
    classRe: /result__a/i, unwrap: unwrapDdgRedirect, limit: 25,
  });
  const results = anchors.map(a => ({ url: a.href, title: a.text, snippet: '' }))
    .filter(r => looksLikeUrl(r.url));
  return results.length ? results : null;
}

async function searchMojeek(q) {
  const { resp, body } = await fetchBody('https://www.mojeek.com/search?q=' + encodeURIComponent(q));
  if (!resp.ok) return null;
  const anchors = harvestAnchors(body, {
    excludeRe: /mojeek\.com/, limit: 20,
  });
  const seen = new Set();
  const results = [];
  for (const a of anchors) {
    const key = a.href.replace(/\/$/, '');
    if (seen.has(key)) continue;
    seen.add(key);
    results.push({ url: a.href, title: a.text, snippet: '' });
  }
  return results.length ? results : null;
}

async function searchWikipedia(q) {
  const api = 'https://en.wikipedia.org/w/api.php?action=opensearch&limit=10&format=json&namespace=0&search=';
  const { resp, body } = await fetchBody(api + encodeURIComponent(q));
  if (!resp.ok) return null;
  const data = JSON.parse(body);
  const titles = data[1] || [], urls = data[3] || [];
  const results = [];
  for (let i = 0; i < titles.length && i < urls.length; i++) {
    results.push({ url: urls[i], title: titles[i] + ' — Wikipedia', snippet: '' });
  }
  return results.length ? results : null;
}

async function searchDdgInstant(q) {
  const api = 'https://api.duckduckgo.com/?format=json&no_html=1&skip_disambig=1&q=';
  const { resp, body } = await fetchBody(api + encodeURIComponent(q));
  if (!resp.ok) return null;
  const d = JSON.parse(body);
  const results = [];
  if (d.AbstractText && d.AbstractURL) {
    results.push({ url: d.AbstractURL, title: d.Heading || q, snippet: d.AbstractText });
  }
  for (const t of (d.RelatedTopics || [])) {
    if (t.FirstURL && t.Text) results.push({ url: t.FirstURL, title: t.Text.split(' - ')[0], snippet: t.Text });
    if (results.length >= 15) break;
  }
  return results.length ? results : null;
}

// ===================================================== URL & HTML toolbox

function looksLikeUrl(s) {
  if (!s || /\s/.test(s)) return false;
  if (/^https?:\/\//i.test(s)) return true;
  // host-shaped: example.com, sub.domain.org/path, host:port …
  return /^[\w-]+(\.[\w-]+)+(:\d+)?([/?#].*)?$/.test(s);
}

function normalizeUrl(s) {
  const t = (s || '').trim();
  if (!t || /\s/.test(t)) return null;
  if (/^https?:\/\//i.test(t)) return t;
  if (looksLikeUrl(t)) return 'https://' + t;
  return null;
}

const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  mdash: '—', ndash: '–', hellip: '…', rsquo: '’', lsquo: '‘',
  rdquo: '”', ldquo: '“', copy: '©', reg: '®', trade: '™',
  middot: '·', laquo: '«', raquo: '»', times: '×', plusmn: '±',
  deg: '°', euro: '€', pound: '£', yen: '¥', cent: '¢', bull: '•',
  dagger: '†', sect: '§', para: '¶', rarr: '→', larr: '←',
  shy: '', zwnj: '', zwj: '',
};

function decodeEntities(s) {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeFromCode(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeFromCode(parseInt(d, 10)))
    .replace(/&([a-z][a-z0-9]*);/gi, (whole, name) => {
      const lower = name.toLowerCase();
      return Object.prototype.hasOwnProperty.call(ENTITIES, lower) ? ENTITIES[lower] : whole;
    });
}

function safeFromCode(cp) {
  try { return String.fromCodePoint(cp); } catch (_) { return ''; }
}

function stripTags(s) {
  return String(s || '').replace(/<[^>]{0,2000}>/g, ' ');
}

function clip(s, n) {
  const t = String(s || '');
  return t.length <= n ? t : t.slice(0, n - 1) + '…';
}

function capText(s, max) {
  const cap = max || MAX_TEXT_CHARS;
  if (s.length <= cap) return s;
  const cut = s.lastIndexOf('\n', cap);
  return s.slice(0, cut > cap * 0.5 ? cut : cap) + '\n…[truncated]';
}

// resolve href against base — small manual resolver (no URL API assumed)
function absolutize(href, base) {
  if (!href) return null;
  const h = href.trim();
  if (!h || h[0] === '#') return null;
  if (/^(javascript|mailto|tel|data|sms|about|blob):/i.test(h)) return null;
  const bm = /^(https?:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(base);
  if (!bm) return null;
  const origin = bm[1] + '//' + bm[2];
  const basePath = bm[3] || '/';
  let out = null;
  if (/^https?:\/\//i.test(h)) out = h;
  else if (/^\/\//.test(h)) out = bm[1] + h;
  else if (h[0] === '/') out = origin + h;
  else if (h[0] === '?') out = origin + basePath + h;
  else {
    const dir = basePath.slice(0, basePath.lastIndexOf('/') + 1) || '/';
    out = origin + dir + h;
  }
  if (out) out = out.split('#')[0];
  if (out) out = resolveDots(out);
  return /^https?:\/\//i.test(out || '') ? out : null;
}

function resolveDots(url) {
  const m = /^(https?:\/\/[^/?#]*)([^?#]*)(\?.*)?$/i.exec(url);
  if (!m) return url;
  const segs = [];
  for (const seg of m[2].split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') segs.pop();
    else segs.push(seg);
  }
  let path = '/' + segs.join('/');
  if (m[2].endsWith('/') || m[2].endsWith('/.') || m[2].endsWith('/..')) path += '/';
  return m[1] + path + (m[3] || '');
}

/**
 * Reader-mode extraction: title, meta description, cleaned text and the
 * link table from an HTML document. Deliberately a small regex pipeline:
 * strips head-noise (script/style/svg/nav/header/footer/aside/forms),
 * prefers <article>/<main> content when present, keeps h1-h3 as "## "
 * markers and list items as "• " lines, then normalizes whitespace.
 */
function extractReadable(html, pageUrl) {
  const doc = String(html || '');
  const meta = (re) => { const m = re.exec(doc); return m ? decodeEntities(m[1]).trim() : ''; };

  let title = meta(/<title[^>]*>([\s\S]{0,300}?)<\/title>/i);
  if (!title) title = meta(/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']{0,200})["']/i);
  if (!title) title = meta(/<meta[^>]+content=["']([^"']{0,200})["'][^>]+property=["']og:title["']/i);
  title = title.replace(/\s+/g, ' ').trim();

  let description =
    meta(/<meta[^>]+name=["']description["'][^>]+content=["']([^"']{0,300})["']/i) ||
    meta(/<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']{0,300})["']/i);

  const canonical = meta(/<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']/i);
  const base = canonical && /^https?:\/\//i.test(canonical) ? canonical : pageUrl;

  // link table BEFORE any stripping (anchors must survive as data)
  const links = [];
  const seen = new Set();
  const are = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
  let am;
  while ((am = are.exec(doc)) && links.length < MAX_LINKS + 80) {
    const hrefm = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(am[1]);
    if (!hrefm) continue;
    const abs = absolutize(hrefm[1] || hrefm[2] || hrefm[3], base);
    if (!abs) continue;
    const text = decodeEntities(stripTags(am[2])).replace(/\s+/g, ' ').trim();
    if (!text || text.length > 160) continue;
    const key = abs.replace(/\/$/, '');
    if (seen.has(key)) { // keep the first, but prefer a longer anchor text
      const prev = links.find(l => l.url.replace(/\/$/, '') === key);
      if (prev && text.length > prev.text.length && text.length <= 60) prev.text = text;
      continue;
    }
    seen.add(key);
    links.push({ n: links.length + 1, url: abs, text: text });
  }

  // strip noise elements (block-level removal)
  let body = doc
    .replace(/<!--[\s\S]{0,4000}?-->/g, ' ')
    .replace(/<(script|style|noscript|svg|template|iframe|object|embed|canvas|audio|video|form|select|textarea|button|input|label|dialog)\b[\s\S]{0,60000}?<\/\1\s*>/gi, ' ')
    .replace(/<(nav|header|footer|aside)\b[\s\S]{0,60000}?<\/\1\s*>/gi, ' ');

  // prefer <article> or <main> when either exists (longest match wins)
  const candidates = [];
  const artRe = /<(article|main)\b[^>]*>([\s\S]{0,120000}?)<\/\1\s*>/gi;
  let cm;
  while ((cm = artRe.exec(body))) candidates.push(cm[2]);
  if (candidates.length) {
    body = candidates.sort((a, b) => b.length - a.length)[0];
  }

  body = body
    .replace(/<h([1-6])[^>]*>/gi, (mm, lv) => (+lv <= 3 ? '\n\n## ' : '\n\n'))
    .replace(/<\/h[1-6]>/gi, '\n')
    .replace(/<li[^>]*>/gi, '\n• ')
    .replace(/<br\s*\/?\s*>/gi, '\n')
    .replace(/<\/(p|div|section|tr|blockquote|pre|li|dt|dd|figcaption|summary)\s*>/gi, '\n')
    .replace(/<\/(table|thead|tbody|ul|ol|article|main|h[1-6])\s*>/gi, '\n')
    .replace(/<(hr)\s*\/?\s*>/gi, '\n———\n')
    .replace(/<td[^>]*>/gi, ' ');

  let text = decodeEntities(stripTags(body));

  text = text
    .split('\n')
    .map(l => l.replace(/[ \t\u00a0]+/g, ' ').trim())
    .filter((l, i, arr) => !(l === '' && arr[i - 1] === ''))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  // drop boilerplate fragments the block-filter could not catch
  text = text
    .split('\n')
    .filter(l => !/^(cookie|accept all|skip to (main )?content|sign in|subscribe now?|all rights reserved|privacy policy|terms of (service|use))\b/i.test(l))
    .join('\n');

  return {
    title: title || null,
    description: description || null,
    text: capText(text),
    links: links
      .filter(l => !isNavJunk(l.text, l.url))
      .slice(0, MAX_LINKS),
  };
}

function isNavJunk(text, url) {
  if (/^(home|menu|search|login|log in|sign in|sign up|register|share|tweet|next →?|previous|→|←|read more|more|skip|back to top|top)$/i.test(text)) return true;
  if (/facebook\.com\/sharer|twitter\.com\/(share|intent)|linkedin\.com\/share|wa\.me|t\.me\/share/i.test(url)) return true;
  return false;
}

module.exports = main();
