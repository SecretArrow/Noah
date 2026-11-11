/**
 * RSS Reader — a per-chat RSS/Atom feed reader for ZAgents (sample module).
 *
 * Demonstrates: unrestricted `zagents.http.request` (no `allowedHosts` —
 * feeds live anywhere), tolerant regex-based XML extraction (RSS 2.0 AND
 * Atom, CDATA included), and per-chat `zagents.storage` as the subscription
 * list + read state.
 *
 * Commands (manifest `commands: ["rss"]` routes `/rss …` here):
 *   /rss add <url> [label]   subscribe (fetches + validates the feed)
 *   /rss list                subscriptions with unread counts
 *   /rss read <n> [count]    latest items of feed #n (default 10)
 *   /rss latest [count]      merged newest-first across all feeds (default 20)
 *   /rss refresh             re-fetch all feeds, show only NEW items
 *   /rss remove <n>          unsubscribe (two-step: /rss confirm)
 *   /rss confirm             execute a pending remove
 *   /rss help                this help
 */
async function main() {
  const info = zagents.info;
  const raw = (info.prompt || '').trim();
  const argv = raw.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
  const feeds = (await zagents.storage.get('rssFeeds')) || [];
  const pending = (await zagents.storage.get('rssPending')) || null;
  let out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };

  if (!argv || argv === 'help') {
    help(say, feeds);
  } else if (argv === 'list') {
    listCmd(say, feeds);
  } else if (argv.startsWith('add ')) {
    await addCmd(say, feeds, argv.slice(4).trim());
  } else if (argv === 'latest') {
    await latestCmd(say, feeds, 20);
  } else if (/^latest\s+\d+$/.test(argv)) {
    await latestCmd(say, feeds, parseInt(argv.split(/\s+/)[1], 10));
  } else if (/^read\s+\d+/.test(argv)) {
    await readCmd(say, feeds, argv);
  } else if (argv === 'refresh') {
    await refreshCmd(say, feeds);
  } else if (/^remove\s+\d+$/.test(argv)) {
    await removeCmd(say, feeds, pending, parseInt(argv.split(/\s+/)[1], 10));
  } else if (argv === 'confirm') {
    await confirmCmd(say, feeds, pending);
  } else {
    say('Unknown command. Try /rss help — e.g. /rss add <feed-url>');
  }

  for (const line of out) await zagents.log(line);
  return { module: 'rss-reader', feeds: feeds.length };
}

// ------------------------------------------------------------------ state
// feeds[] = { url, label, fetchedAt, items: [{guid,title,link,date,summary}],
//             seen: {guid: isoDate} } — items capped per feed, seen capped.

const MAX_ITEMS_PER_FEED = 60;
const MAX_SEEN = 250;

function help(say, feeds) {
  say('📰 RSS Reader — subscriptions live in THIS chat (' + feeds.length + ' active). Commands:');
  say('  /rss add <url> [label]   subscribe to an RSS 2.0 / Atom feed');
  say('  /rss list                subscriptions + unread counts');
  say('  /rss read <n> [count]    read feed #n (default 10 items)');
  say('  /rss latest [count]      all feeds merged, newest first');
  say('  /rss refresh             fetch all, show only NEW items');
  say('  /rss remove <n>          unsubscribe (then /rss confirm)');
  say('');
  say('Tip: most sites expose a feed at /feed, /rss, /atom.xml or /feed.xml,');
  say('or advertise it in the page <head> (link rel="alternate").');
}

function listCmd(say, feeds) {
  if (!feeds.length) {
    say('📰 No subscriptions in this chat yet — /rss add <feed-url>');
    say('   Try: /rss add https://hnrss.org/frontpage');
    return;
  }
  say('📰 Subscriptions in THIS chat:');
  feeds.forEach((f, i) => {
    const unread = f.items.filter(it => !f.seen[it.guid]).length;
    say(String(i + 1).padStart(3) + '. ' + (f.label || f.title || f.url));
    say('      ' + f.url);
    say('      ' + f.items.length + ' items cached · ' + unread + ' unread · fetched ' + ago(f.fetchedAt));
  });
}

async function addCmd(say, feeds, arg) {
  const parts = arg.split(/\s+/);
  const url = normalizeUrl(parts[0]);
  const label = parts.slice(1).join(' ') || null;
  if (!url) { say('❌ Not a URL: "' + parts[0] + '". Usage: /rss add <feed-url> [label]'); return; }
  if (feeds.some(f => f.url === url)) { say('⚠️ Already subscribed: ' + url); return; }
  say('⏳ Fetching ' + url + ' …');
  const fetched = await fetchFeed(say, url);
  if (!fetched) return;
  const feed = {
    url: url, label: label, title: fetched.title,
    fetchedAt: new Date().toISOString(),
    items: fetched.items, seen: {},
  };
  // existing items start as "seen" so /rss refresh only reports future news
  for (const it of feed.items) feed.seen[it.guid] = feed.fetchedAt;
  trimSeen(feed);
  feeds.push(feed);
  await zagents.storage.set('rssFeeds', feeds);
  await zagents.storage.remove('rssPending');
  say('✅ Subscribed: ' + (label || fetched.title || url));
  say('   ' + fetched.kind + ' · ' + fetched.items.length + ' items cached (marked read).');
  say('   /rss read ' + feeds.length + ' 5 to peek · /rss refresh for future updates.');
}

async function fetchFeed(say, url) {
  let resp, body;
  try {
    const r = await zagents.http.request(url, { timeoutMs: 20000 });
    resp = r; body = await r.text();
  } catch (e) {
    say('❌ Fetch failed — ' + (e && e.message ? e.message : e));
    return null;
  }
  if (!resp.ok) { say('❌ HTTP ' + resp.status + ' from ' + url); return null; }
  const parsed = parseFeed(body);
  if (!parsed.items.length) {
    say('❌ No RSS/Atom items found at that URL — it may be HTML.');
    say('   Look for a <link rel="alternate" type="application/rss+xml"> on the page.');
    return null;
  }
  return parsed;
}

async function readCmd(say, feeds, argv) {
  if (!feeds.length) { say('No subscriptions — /rss add <feed-url>'); return; }
  const parts = argv.split(/\s+/);
  const n = parseInt(parts[1], 10);
  const count = parts[2] ? Math.min(parseInt(parts[2], 10), 25) : 10;
  const f = feeds[n - 1];
  if (!f) { say('❌ No feed #' + n + ' — /rss list shows the list.'); return; }
  await printItems(say, f, f.items.slice(0, count), true);
}

async function latestCmd(say, feeds, count) {
  if (!feeds.length) { say('No subscriptions — /rss add <feed-url>'); return; }
  const merged = [];
  feeds.forEach((f, i) => {
    for (const it of f.items) merged.push({ feed: i + 1, feedTitle: f.label || f.title || f.url, ...it });
  });
  merged.sort((a, b) => ts(b.date) - ts(a.date));
  const top = merged.slice(0, Math.min(count, 25));
  if (!top.length) { say('No items cached yet — /rss refresh.'); return; }
  say('📰 Latest across ' + feeds.length + ' feed' + (feeds.length > 1 ? 's' : '') + ' (newest first):');
  say('');
  for (const it of top) {
    say('[' + it.feed + '] ' + clip(it.title, 78));
    say('    ' + (it.date ? fmtDate(it.date) + ' · ' : '') + clip(it.feedTitle, 40));
    if (it.link) say('    ' + it.link);
    say('');
  }
  say('➡️ /rss read <n> opens feed #n · /rss refresh checks for new items');
}

async function refreshCmd(say, feeds) {
  if (!feeds.length) { say('No subscriptions — /rss add <feed-url>'); return; }
  let newTotal = 0;
  for (let i = 0; i < feeds.length; i++) {
    const f = feeds[i];
    say('⏳ [' + (i + 1) + '/' + feeds.length + '] ' + (f.label || f.title || f.url));
    const fetched = await fetchFeed(() => {}, f.url);
    if (!fetched) { say('   ⚠️ skipped (fetch/parse failed)'); continue; }
    const fresh = fetched.items.filter(it => !f.seen[it.guid]);
    f.title = fetched.title || f.title;
    f.fetchedAt = new Date().toISOString();
    // merge: new items in front, cap the cache
    f.items = fetched.items.slice(0, MAX_ITEMS_PER_FEED);
    for (const it of fresh) f.seen[it.guid] = f.fetchedAt;
    trimSeen(f);
    say('   ✅ ' + fetched.items.length + ' items · ' + fresh.length + ' NEW');
    newTotal += fresh.length;
    for (const it of fresh.slice(0, 8)) {
      say('   • ' + clip(it.title, 76));
      if (it.link) say('     ' + it.link);
    }
    if (fresh.length > 8) say('   … +' + (fresh.length - 8) + ' more — /rss read ' + (i + 1));
  }
  await zagents.storage.set('rssFeeds', feeds);
  await zagents.storage.remove('rssPending');
  say('');
  say(newTotal ? '🆕 ' + newTotal + ' new item(s) total.' : '✅ Nothing new — all caught up.');
}

async function removeCmd(say, feeds, pending, n) {
  const f = feeds[n - 1];
  if (!f) { say('❌ No feed #' + n + ' — /rss list.'); return; }
  await zagents.storage.set('rssPending', { n: n, label: f.label || f.title || f.url, at: Date.now() });
  say('⚠️ Unsubscribe from "' + (f.label || f.title || f.url) + '"?');
  say('   Its cached items and read-state will be deleted from this chat.');
  say('   Type /rss confirm to proceed · /rss cancel to abort.');
}

async function confirmCmd(say, feeds, pending) {
  if (!pending || Date.now() - pending.at > 10 * 60 * 1000) {
    say('Nothing pending (or expired) — /rss remove <n> first.');
    return;
  }
  const f = feeds[pending.n - 1];
  if (!f || (f.label || f.title || f.url) !== pending.label) {
    say('⚠️ Feed list changed since the remove request — start again: /rss list');
    await zagents.storage.remove('rssPending');
    return;
  }
  feeds.splice(pending.n - 1, 1);
  await zagents.storage.set('rssFeeds', feeds);
  await zagents.storage.remove('rssPending');
  say('🗑️ Unsubscribed: ' + pending.label + ' (' + feeds.length + ' left).');
}

// ------------------------------------------------------- feed XML parsing
// Tolerant regex extraction covering RSS 2.0 (<item>) and Atom (<entry>),
// CDATA blocks, common namespaces (content:encoded, dc:creator …).

function parseFeed(xml) {
  const src = String(xml || '');
  const title = clean(firstTag(src, 'title'));
  const kind = /<feed[\s>]/i.test(src) && !/<rss[\s>]/i.test(src) ? 'Atom' : 'RSS 2.0';
  const blocks = kind === 'Atom'
    ? splitBlocks(src, 'entry')
    : splitBlocks(src, 'item');
  const items = [];
  for (const b of blocks) {
    const rawLink = kind === 'Atom'
      ? atomHref(b)
      : clean(firstTag(b, 'link'));
    items.push({
      guid: clean(firstTag(b, 'guid')) || clean(firstTag(b, 'id')) || rawLink || clean(firstTag(b, 'title')),
      title: clean(firstTag(b, 'title')) || '(untitled)',
      link: absolutize2(rawLink, urlOrigin(src)) || rawLink,
      date: firstTag(b, 'pubDate') || firstTag(b, 'published') || firstTag(b, 'updated') || firstTag(b, 'dc:date') || '',
      summary: clip(clean(firstTag(b, 'description')) || clean(firstTag(b, 'summary')) ||
                    clean(firstTag(b, 'content:encoded')) || clean(firstTag(b, 'content')), 200),
    });
    if (items.length >= MAX_ITEMS_PER_FEED) break;
  }
  return { title: title || null, kind: kind, items: items };
}

function splitBlocks(src, tag) {
  const out = [];
  const re = new RegExp('<' + tag + '[\\s>][\\s\\S]*?</' + tag + '\\s*>', 'gi');
  let m;
  while ((m = re.exec(src)) && out.length < MAX_ITEMS_PER_FEED * 2) out.push(m[0]);
  return out;
}

function firstTag(block, tag) {
  const t = tag.replace(/:/g, '\\:');
  const m = new RegExp('<(?:[A-Za-z0-9]+:)?' + t + '(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9]+:)?' + t + '\\s*>', 'i').exec(block);
  return m ? m[1] : '';
}

function atomHref(block) {
  const re = /<link\b[^>]*>/gi;
  let m, fallback = '';
  while ((m = re.exec(block))) {
    const tag = m[0];
    const href = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(tag);
    if (!href) continue;
    const url = href[1] || href[2];
    const rel = /\brel\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(tag);
    if (!rel || rel[1] === 'alternate' || rel[2] === 'alternate') return url || '';
    if (!fallback) fallback = url || '';
  }
  return fallback;
}

function clean(s) {
  return String(s || '')
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/<[^>]{0,2000}>/g, ' ')
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeFromCode(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeFromCode(parseInt(d, 10)))
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function urlOrigin(src) {
  const m = /<link[^>]*href\s*=\s*["']([^"']+)["']/i.exec(src) || /<link>([^<]+)<\/link>/i.exec(src);
  return m ? m[1] : '';
}

function absolutize2(link, origin) {
  if (!link || /^https?:\/\//i.test(link)) return link;
  const om = /^https?:\/\/[^/?#]+/i.exec(origin);
  if (om && link[0] === '/') return om[0] + link;
  if (om) return om[0] + '/' + link;
  return link;
}

// ---------------------------------------------------------------- helpers

function normalizeUrl(s) {
  const t = (s || '').trim();
  if (!t || /\s/.test(t)) return null;
  if (/^https?:\/\//i.test(t)) return t;
  if (/^[\w-]+(\.[\w-]+)+/.test(t)) return 'https://' + t;
  return null;
}

function trimSeen(feed) {
  const keys = Object.keys(feed.seen);
  if (keys.length > MAX_SEEN) {
    keys.sort((a, b) => ts(feed.seen[a]) - ts(feed.seen[b]));
    for (const k of keys.slice(0, keys.length - MAX_SEEN)) delete feed.seen[k];
  }
}

function ts(d) {
  const t = Date.parse(d);
  return isNaN(t) ? 0 : t;
}

function fmtDate(d) {
  const t = new Date(d);
  if (isNaN(t)) return String(d).slice(0, 16);
  return t.toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
}

function ago(iso) {
  const s = Math.max(0, (Date.now() - ts(iso)) / 1000);
  if (s < 90) return Math.round(s) + 's ago';
  if (s < 5400) return Math.round(s / 60) + 'm ago';
  if (s < 129600) return Math.round(s / 3600) + 'h ago';
  return Math.round(s / 86400) + 'd ago';
}

function safeFromCode(cp) {
  try { return String.fromCodePoint(cp); } catch (_) { return ''; }
}

function clip(s, n) {
  const t = String(s || '');
  return t.length <= n ? t : t.slice(0, n - 1) + '…';
}

async function printItems(say, f, items, markRead) {
  say('📰 ' + (f.label || f.title || f.url) + ' — ' + items.length + ' item(s):');
  say('');
  let marked = 0;
  for (const it of items) {
    const unread = !f.seen[it.guid];
    say((unread ? '🆕 ' : '   ') + clip(it.title, 78));
    say('    ' + (it.date ? fmtDate(it.date) + ' · ' : '') + (it.summary ? clip(it.summary, 110) : ''));
    if (it.link) say('    ' + it.link);
    say('');
    if (unread) { f.seen[it.guid] = new Date().toISOString(); marked++; }
  }
  trimSeen(f);
  if (markRead && marked) {
    const stored = (await zagents.storage.get('rssFeeds')) || [];
    const mine = stored.find(x => x.url === f.url);
    if (mine) { mine.seen = f.seen; mine.items = f.items; mine.title = f.title; mine.fetchedAt = f.fetchedAt; }
    await zagents.storage.set('rssFeeds', stored);
  }
}

module.exports = main();
