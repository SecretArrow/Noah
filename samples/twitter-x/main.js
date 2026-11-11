/**
 * Twitter/X Assistant — ZAgents chat module (samples/twitter-x).
 *
 * Auto-reply assistant for X/Twitter mentions, driven by /tw slash
 * commands (manifest "commands: [tw]" — the message is routed to this
 * module instead of the LLM, so command runs never consume an AI turn).
 * One check pass per activation:
 *   - GET /2/users/{id}/mentions (X API v2, OAuth 1.0a user context)
 *   - filter out already-seen ids + our own tweets, classify intent by
 *     Indonesian/English keywords (komplain/rusak/kecewa/broken/bad ->
 *     support; bagus/mantap/keren/love/great/good -> praise; kapan/
 *     bagaimana/bisa/apakah/how/when/price/harga -> question; else generic)
 *   - pick a template variant ({name}/{me} slot-filled), let the chat's
 *     own agent POLISH it via zagents.agent.polish (maxChars 280, tone
 *     casual, avoid the last 8 sent replies) — polish failure falls back
 *     to the slot-filled template, NEVER crashes the run
 *   - POST /2/tweets with JSON body {"text", "reply":{"in_reply_to_tweet_id"}}
 *     — the JSON body is NEVER part of the OAuth 1.0a signature
 *   - human-like delay 6-15 s between replies, progress via chat.emit
 *
 * Design:
 *   - OAuth 1.0a signing lives in ./lib/oauth1.js — self-contained pure
 *     JS (SHA-1 + HMAC-SHA1 + RFC 3986 percent encoding), zero deps.
 *   - Per-chat isolation: credentials, seen-mentions, templates, stats
 *     live in THIS chat's zagents.storage only. Secrets are never logged
 *     — output shows '••••' + the last 4 characters only.
 *   - allowedHosts: api.x.com (api.twitter.com as network-level fallback).
 *     ALL network via zagents.http.request — no fetch, no node APIs, no
 *     setInterval.
 *   - Free-tier honesty: reading mentions needs Basic/Premium; a 403
 *     client-not-enrolled says so out loud (posting still works, 500/mo).
 *   - Storage hygiene: seenMentions capped at 300 ids, sent replies at
 *     10, fails map pruned — well inside the 64 KB/value cap.
 *
 * Commands:
 *   /tw                          help
 *   /tw status                   login check, masked keys, metrics, stats
 *   /tw check                    one pass: new mentions -> (auto-)replies
 *   /tw auto [seconds]           burst watch every N s (min 10, ~110 s/run)
 *   /tw on | off                 toggle auto-reply for THIS chat
 *   /tw template [key] [A|B|C]   template manager (5 keys, <=4 variants)
 *   /tw tweet <text>             post a raw standalone tweet
 *   /tw tweet polish <text>      post with AI polish (max 280 chars)
 *   /tw reply <url|id> [key]     manual reply to one tweet
 *   /tw logout                   wipe credentials + mention state
 *   /tw help                     this list
 *
 * Zero npm dependencies. Requires the ZAgents module runtime.
 * ==========================================================================*/

'use strict';

const oauth1 = require('./lib/oauth1.js');
const percentEncode = oauth1.percentEncode;

// --------------------------------------------------------------- constants

const API_HOSTS = ['https://api.x.com', 'https://api.twitter.com'];
const TWEET_LIMIT = 280;
const MAX_SEEN = 300;    // seenMentions ids kept (oldest dropped)
const MAX_SENT = 10;     // recent sent replies kept (feeds polish avoid[])
const MAX_FAILS = 100;   // fails map entries kept
const FAIL_LIMIT = 3;    // a mention is dropped after this many failed replies
const BURST_MS = 110000; // ~110 s of work, 8 s margin before the 120 s timeout

const TEMPLATE_KEYS = ['support', 'praise', 'question', 'generic', 'away'];

const DEFAULT_TEMPLATES = {
  support: [
    'Halo {name}, maaf banget pengalamannya kurang nyaman. Ceritakan detailnya ke DM kami ya, tim kami bantu sampai beres.',
    'Halo {name}, terima kasih sudah lapor dan mohon maaf atas ketidaknyamanannya. DM kami dengan detail kendalanya ya, kami cek sekarang.',
    'Wah, maaf banget {name}. Kirim detail masalahnya via DM ya, biar kami tuntaskan secepatnya.'
  ],
  praise: [
    'Terima kasih banyak {name}! Senang banget dengarnya. Dukungan seperti ini bikin kami makin semangat.',
    'Makasih {name}, bikin senyum tim {me} sepanjang hari. Salam hangat untukmu juga!',
    'Wah, makasih banyak {name}. Kabar baik seperti ini selalu enak didengar. Semoga harimu menyenangkan juga!'
  ],
  question: [
    'Halo {name}, pertanyaan bagus. Detailnya kami jawab lewat DM ya, ditunggu.',
    'Halo {name}, terima kasih sudah bertanya. Info lengkapnya kami kirim via DM secepatnya ya.',
    'Halo {name}, untuk info lebih lanjut silakan cek DM kami atau halaman resmi {me}. Senang membantu!'
  ],
  generic: [
    'Halo {name}, makasih udah nyebut kami. Senang bisa terhubung di sini!',
    'Halo {name}, terima kasih atas mentionnya. Salam dari tim {me}!',
    'Hai {name}, makasih banyak sudah menyapa. Semoga harimu menyenangkan!'
  ],
  away: [
    'Halo {name}, makasih sudah menghubungi. Kami sedang di luar jam kerja, akan dibalas secepatnya ya.',
    'Halo {name}, tim {me} sedang tidak di meja. Pesanmu tercatat, akan dibalas begitu kami kembali.',
    'Halo {name}, kami akan segera kembali. Pesanmu kami catat dan direspons sebentar lagi.'
  ]
};

const KEYWORDS = {
  support: ['komplain', 'rusak', 'kecewa', 'broken', 'bad'],
  praise: ['bagus', 'mantap', 'keren', 'love', 'great', 'good'],
  question: ['kapan', 'bagaimana', 'bisa', 'apakah', 'how', 'when', 'price', 'harga']
};

// ----------------------------------------------------------------- helpers

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function nowIso() { return new Date().toISOString(); }
function clip(s, n) { const t = String(s || ''); return t.length <= n ? t : t.slice(0, n - 1) + '…'; }
function errMsg(e) { return e && e.message ? String(e.message) : String(e); }
function normHandle(h) { return String(h || '').trim().replace(/^@+/, '').toLowerCase(); }
function mask(v) { const s = String(v || ''); return s.length > 4 ? '••••' + s.slice(-4) : '••••'; }
function fmtDate(d) {
  const t = new Date(d);
  if (isNaN(t)) return String(d).slice(0, 16);
  return t.toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
}
function fmtEpoch(v) {
  const n = Number(v);
  if (!isFinite(n) || n <= 0) return String(v);
  try { return new Date(n * 1000).toString(); } catch (e) { return String(v); }
}
function fillTemplate(tpl, name, me) {
  return String(tpl || '').split('{name}').join('@' + name).split('{me}').join('@' + me);
}
function trimSent(sent) { while (sent.length > MAX_SENT) sent.shift(); }
function trimSeen(seen) { while (seen.length > MAX_SEEN) seen.shift(); }

/** defensive storage read — zagents.storage already parses, but be safe */
async function getJson(key, fallback) {
  try {
    const v = await zagents.storage.get(key);
    if (v === undefined || v === null) return fallback;
    if (typeof v === 'string') {
      try { return JSON.parse(v); } catch (e) { return fallback; }
    }
    return v;
  } catch (e) {
    return fallback;
  }
}

async function setJson(key, value) {
  try { await zagents.storage.set(key, value); } catch (e) { /* keep going */ }
}

async function removeKey(key) {
  try { await zagents.storage.remove(key); } catch (e) { /* keep going */ }
}

async function bumpStats(fn) {
  const stats = (await getJson('stats', {})) || {};
  try { fn(stats); } catch (e) { /* keep going */ }
  await setJson('stats', stats);
  return stats;
}

async function needAuth(say) {
  const auth = await getJson('auth', null);
  if (auth) return auth;
  say('🐦 Kredensial X belum ada di chat ini.');
  say('   Isi setup form Twitter/X Assistant dulu (API Key + Secret, Access Token + Secret dari developer.x.com, Read and Write).');
  return null;
}

/** merge stored templates with defaults (new keys always available) */
async function loadTemplates() {
  const stored = (await getJson('templates', null)) || {};
  const merged = {};
  for (const key of TEMPLATE_KEYS) {
    const v = stored[key];
    merged[key] = (Array.isArray(v) && v.length) ? v.map(String) : DEFAULT_TEMPLATES[key].slice();
  }
  return merged;
}

function pruneFails(fails, seen) {
  const seenSet = {};
  for (const id of seen || []) seenSet[String(id)] = true;
  const out = {};
  for (const k of Object.keys(fails || {})) {
    const v = Number(fails[k] || 0);
    if (v > 0 && !seenSet[String(k)]) out[String(k)] = v;
  }
  const keys = Object.keys(out);
  while (keys.length > MAX_FAILS) delete out[keys.shift()];
  return out;
}

// ------------------------------------------------------------------- X API

/** one request to one host; returns {ok, status, headers, data, text} */
async function xOnce(method, url, params, bodyObj, auth) {
  const p = params || {};
  const paramKeys = Object.keys(p);
  let fullUrl = url;
  if (method === 'GET' && paramKeys.length) {
    const qs = paramKeys.map((k) => percentEncode(k) + '=' + percentEncode(p[k])).join('&');
    fullUrl += '?' + qs;
  }
  // OAuth 1.0a signature covers query params (GET) + oauth params — NEVER
  // the JSON body of a POST.
  const headers = {
    Authorization: oauth1.sign(method, url, method === 'GET' ? p : {}, auth)
  };
  const opts = { method: method, headers: headers };
  if (method === 'POST') {
    headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(bodyObj || {});
  }
  const res = await zagents.http.request(fullUrl, opts);
  let text = '';
  try { text = await res.text(); } catch (e) { text = ''; }
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
  const ok = !!res.ok || (res.status >= 200 && res.status < 300);
  return { ok: ok, status: res.status, headers: res.headers || {}, data: data, text: text };
}

/** request api.x.com; on a NETWORK-level failure retry api.twitter.com once */
async function xApi(method, path, params, bodyObj, auth) {
  let lastErr = null;
  for (let i = 0; i < API_HOSTS.length; i++) {
    try {
      return await xOnce(method, API_HOSTS[i] + path, params, bodyObj, auth);
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr;
}

function errorKind(res) {
  if (!res) return 'network';
  const title = res.data && res.data.title ? String(res.data.title) : '';
  const detail = res.data && res.data.detail ? String(res.data.detail) : '';
  const text = String(res.text || '');
  if (res.status === 401) return 'auth';
  if (res.status === 403 && (title === 'client-not-enrolled' || /client-not-enrolled/i.test(text) || /access denied/i.test(detail))) return 'tier';
  if (res.status === 403) return 'forbidden';
  if (res.status === 429) return 'ratelimit';
  if (res.status >= 500) return 'server';
  return 'http';
}

function describeError(say, res, indent) {
  const pad = indent || '';
  const kind = errorKind(res);
  const detail = res && res.data && res.data.detail ? String(res.data.detail) : '';
  if (kind === 'network') {
    say(pad + '❌ Koneksi ke api.x.com gagal (jaringan/timeout).');
    return;
  }
  if (kind === 'auth') {
    say(pad + '❌ HTTP 401 — token invalid/expired.');
    say(pad + '   Regenerate Access Token + Secret di developer.x.com (User authentication settings: Read and write), lalu perbarui setup form.');
    return;
  }
  if (kind === 'tier') {
    say(pad + '⚠️ HTTP 403 client-not-enrolled — tier Free TIDAK punya akses baca mentions.');
    say(pad + '   Auto-reply butuh paket Basic/Premium. Posting tweet tetap jalan (500 tweet/bulan).');
    return;
  }
  if (kind === 'forbidden') {
    say(pad + '❌ HTTP 403' + (detail ? ' — ' + detail : '') + ' (cek izin token: Read and Write; juga jangan kirim tweet duplikat).');
    return;
  }
  if (kind === 'ratelimit') {
    say(pad + '⏳ HTTP 429 — rate limit X API tercapai.');
    const reset = res.headers ? res.headers['x-rate-limit-reset'] : null;
    if (reset) say(pad + '   Limit reset pada ' + fmtEpoch(reset) + ' (waktu lokal).');
    return;
  }
  if (kind === 'server') {
    say(pad + '🛠️ HTTP ' + res.status + ' — X API sedang bermasalah' + (detail ? ' (' + detail + ')' : '') + '.');
    return;
  }
  say(pad + '❌ HTTP ' + res.status + (detail ? ' — ' + detail : ''));
}

// --------------------------------------------------------------- bootstrap

function sameAuth(a, b) {
  if (!a) return false;
  return a.apiKey === b.apiKey && a.apiKeySecret === b.apiKeySecret &&
    a.accessToken === b.accessToken && a.accessTokenSecret === b.accessTokenSecret &&
    normHandle(a.handle) === b.handle;
}

/**
 * First run after setup: persist 'auth' + 'config' from zagents.info.setup,
 * verify via /2/users/me once, emit the logged-in username. Later runs are
 * no-ops unless the setup values changed.
 */
async function bootstrap(say, emit) {
  const info = zagents.info || {};
  const setup = info.setup || {};
  const fields = ['apiKey', 'apiKeySecret', 'accessToken', 'accessTokenSecret', 'handle'];
  let have = true;
  for (const f of fields) {
    const v = setup[f];
    if (v === undefined || v === null || String(v).trim() === '') have = false;
  }

  // 'config' persisted on first run; honours the setup form's autoReply toggle
  const ensureConfig = async () => {
    const cfg = await getJson('config', null);
    if (!cfg || typeof cfg.autoReply !== 'boolean') {
      const initial = typeof setup.autoReply === 'boolean' ? setup.autoReply : true;
      await setJson('config', { autoReply: initial });
    }
  };

  if (have) {
    const cand = {
      apiKey: String(setup.apiKey).trim(),
      apiKeySecret: String(setup.apiKeySecret).trim(),
      accessToken: String(setup.accessToken).trim(),
      accessTokenSecret: String(setup.accessTokenSecret).trim(),
      handle: normHandle(setup.handle)
    };
    const cur = await getJson('auth', null);
    if (!sameAuth(cur, cand)) {
      await setJson('auth', cand);
      await removeKey('me');       // force re-verification for new creds
      await setJson('fails', {});  // stale fail counters belong to old creds
      await ensureConfig();
      say('🔑 Kredensial X disimpan di storage chat ini (tidak dibagikan ke chat lain).');
      const me = await resolveMe(say);
      if (me) emit('🐦 Masuk sebagai @' + me.username + ' — akun terverifikasi untuk chat ini.');
      else emit('⚠️ Kredensial tersimpan, tapi verifikasi ke api.x.com gagal — jalankan /tw status untuk detail.');
      return true;
    }
  }

  await ensureConfig();
  return false;
}

/** our own id/username — cached in 'me' after the first verification */
async function resolveMe(say) {
  const cached = await getJson('me', null);
  if (cached && cached.id && cached.username) return cached;
  const auth = await getJson('auth', null);
  if (!auth) return null;
  const res = await xApi('GET', '/2/users/me', { 'user.fields': 'username,public_metrics' }, null, auth);
  if (!res.ok || !res.data || !res.data.data) {
    describeError(say, res);
    return null;
  }
  const u = res.data.data;
  const me = { id: String(u.id), username: String(u.username || '') };
  await setJson('me', me);
  if (auth.handle && me.username && normHandle(me.username) !== auth.handle) {
    say('⚠️ Handle setup (@' + auth.handle + ') ≠ akun token (@' + me.username + ') — aksi tetap jalan sebagai @' + me.username + '.');
  }
  return me;
}

// ---------------------------------------------------------------- commands

function helpCmd(say) {
  say('🐦 Twitter/X Assistant — auto-reply mentions dengan template + AI polish. Perintah:');
  say('  /tw status                cek login, kredensial (ter-mask), metrics & statistik');
  say('  /tw check                 satu pass: ambil mention baru, balas (jika auto-reply ON)');
  say('  /tw auto [detik]          burst watch tiap N detik (min 10, default 20, ±110 dtk/run)');
  say('  /tw on | off              toggle auto-reply mentions untuk chat ini');
  say('  /tw template [key] [teks] kelola template: ' + TEMPLATE_KEYS.join('/') + ' (reset: /tw template reset)');
  say('  /tw tweet <teks>          posting tweet baru apa adanya');
  say('  /tw tweet polish <teks>   posting dengan polish AI (maks ' + TWEET_LIMIT + ' karakter)');
  say('  /tw reply <url|id> [key]  balas manual satu tweet (default template: generic)');
  say('  /tw logout                hapus kredensial + state mention chat ini');
  say('  /tw help                  daftar perintah ini');
  say('Kredensial disimpan per-chat, tidak pernah ditampilkan penuh, dan hanya dikirim ke api.x.com.');
}

async function statusCmd(say) {
  const auth = await needAuth(say);
  if (!auth) return;
  const cfg = (await getJson('config', {})) || {};
  const stats = (await getJson('stats', {})) || {};
  say('🐦 Twitter/X Assistant — status chat ini:');
  say('   API Key: ' + mask(auth.apiKey));
  say('   API Key Secret: ' + mask(auth.apiKeySecret));
  say('   Access Token: ' + mask(auth.accessToken));
  say('   Access Token Secret: ' + mask(auth.accessTokenSecret));
  say('   Handle (setup): @' + (auth.handle || '?'));
  say('   Auto-reply mentions: ' + (cfg.autoReply ? 'ON' : 'OFF'));
  say('   Statistik: ' + (stats.replies || 0) + ' balasan · ' + (stats.tweets || 0) + ' tweet · cek terakhir ' + (stats.lastCheck ? fmtDate(stats.lastCheck) : 'belum pernah'));
  say('⏳ Verifikasi token ke api.x.com …');
  const res = await xApi('GET', '/2/users/me', { 'user.fields': 'username,public_metrics' }, null, auth);
  if (!res.ok || !res.data || !res.data.data) {
    describeError(say, res);
    return;
  }
  const u = res.data.data;
  await setJson('me', { id: String(u.id), username: String(u.username || '') });
  const m = u.public_metrics || {};
  say('✅ Login sebagai @' + u.username + ' (id ' + u.id + ')');
  say('   Followers: ' + (m.followers_count != null ? m.followers_count : '?') +
    ' · Following: ' + (m.following_count != null ? m.following_count : '?') +
    ' · Tweets: ' + (m.tweet_count != null ? m.tweet_count : '?'));
  if (auth.handle && normHandle(u.username) !== auth.handle) {
    say('⚠️ Handle setup (@' + auth.handle + ') ≠ akun token (@' + u.username + ') — cek ulang setup form.');
  }
}

/**
 * One check pass: mentions GET -> filter -> optional auto-replies.
 * opts: { deadline: ms, quiet: bool }. Returns counters + a stop reason.
 */
async function checkPass(say, emit, opts) {
  const options = opts || {};
  const deadline = options.deadline || (Date.now() + BURST_MS);
  const quiet = !!options.quiet;
  const result = { pending: 0, replied: 0, errors: 0, stop: null, noAuth: false };

  const auth = await getJson('auth', null);
  if (!auth) {
    result.noAuth = true;
    say('🐦 Kredensial X belum ada di chat ini — isi setup form modul dulu.');
    return result;
  }

  const me = await resolveMe(say);
  if (!me) {
    result.errors++;
    return result;
  }

  const res = await xApi('GET', '/2/users/' + me.id + '/mentions', {
    max_results: '25',
    'tweet.fields': 'created_time,author_id,conversation_id,in_reply_to_user_id',
    expansions: 'author_id'
  }, null, auth);
  if (!res.ok) {
    describeError(say, res);
    result.errors++;
    const kind = errorKind(res);
    if (kind === 'tier' || kind === 'auth' || kind === 'ratelimit') result.stop = kind;
    await bumpStats((s) => { s.lastCheck = nowIso(); });
    return result;
  }

  const tweets = (res.data && res.data.data) || [];
  const users = ((res.data && res.data.includes && res.data.includes.users) || []);
  const nameById = {};
  for (const u of users) nameById[String(u.id)] = String(u.username || 'user');

  const seen = (await getJson('seenMentions', [])) || [];
  const isSeen = {};
  for (const id of seen) isSeen[String(id)] = true;

  const pending = [];
  for (const t of tweets) {
    const tid = String(t.id || '');
    if (!tid || isSeen[tid]) continue;
    if (t.author_id && String(t.author_id) === me.id) continue; // our own tweet
    // in_reply_to_user_id == me -> orang lain membalas di thread kita: tetap dijawab
    pending.push(t);
  }
  result.pending = pending.length;

  if (!pending.length) {
    await bumpStats((s) => { s.lastCheck = nowIso(); });
    if (!quiet) say('✅ Tidak ada mention baru.');
    return result;
  }

  const cfg = (await getJson('config', {})) || {};
  if (!cfg.autoReply) {
    await bumpStats((s) => { s.lastCheck = nowIso(); });
    if (!quiet) {
      say('📋 ' + pending.length + ' mention baru, auto-reply OFF (/tw on untuk mengaktifkan):');
      for (const t of pending.slice(0, 5)) {
        say('   • @' + (nameById[String(t.author_id)] || 'user') + ': ' + clip(String(t.text || ''), 80));
      }
      if (pending.length > 5) say('   … +' + (pending.length - 5) + ' lagi');
    }
    return result;
  }

  const templates = await loadTemplates();
  const fails = (await getJson('fails', {})) || {};
  const sent = (await getJson('sent', [])) || [];

  for (let i = 0; i < pending.length; i++) {
    const t = pending[i];
    const tid = String(t.id);
    const uname = nameById[String(t.author_id)] || 'user';
    const tweetText = String(t.text || '');

    if (Date.now() + 8000 > deadline) {
      say('⏱️ Waktu run hampir habis — sisa mention diproses di run berikutnya.');
      break;
    }

    emit('Membalas @' + uname + '…');

    const intent = classify(tweetText);
    const filled = fillTemplate(pick(templates[intent] || DEFAULT_TEMPLATES.generic), uname, auth.handle || me.username);
    const reply = await polishReply(say, filled, tweetText, sent);

    const post = await xApi('POST', '/2/tweets', null, {
      text: reply,
      reply: { in_reply_to_tweet_id: tid }
    }, auth);
    if (post.ok && post.data && post.data.data && post.data.data.id) {
      sent.push({ text: reply, at: nowIso() });
      trimSent(sent);
      await setJson('sent', sent);
      seen.push(tid);
      trimSeen(seen);
      await setJson('seenMentions', seen);
      delete fails[tid];
      await setJson('fails', pruneFails(fails, seen));
      await bumpStats((s) => { s.replies = (s.replies || 0) + 1; s.lastCheck = nowIso(); });
      result.replied++;
      emit('   ✅ @' + uname + ' (' + intent + ') → https://x.com/' + (auth.handle || me.username) + '/status/' + post.data.data.id);
    } else {
      result.errors++;
      describeError(say, post, '   ');
      emit('   ⚠️ Gagal membalas @' + uname + ' (HTTP ' + (post ? post.status : '?') + ').');
      fails[tid] = (fails[tid] || 0) + 1;
      if (fails[tid] >= FAIL_LIMIT) {
        seen.push(tid);
        trimSeen(seen);
        delete fails[tid];
        await setJson('seenMentions', seen);
        say('   ⏭️ ' + tid + ' (@' + uname + ') ditandai selesai setelah ' + FAIL_LIMIT + 'x gagal — menghindari loop.');
      }
      await setJson('fails', pruneFails(fails, seen));
      const pkind = errorKind(post);
      if (pkind === 'ratelimit' || pkind === 'auth' || pkind === 'tier') {
        result.stop = pkind;
        break;
      }
    }

    if (i < pending.length - 1) {
      const wait = 6000 + Math.random() * 9000; // human-like 6-15 s
      if (Date.now() + wait + 3000 > deadline) {
        say('⏱️ Waktu run hampir habis — sisa mention diproses di run berikutnya.');
        break;
      }
      await sleep(wait);
    }
  }

  await bumpStats((s) => { s.lastCheck = nowIso(); });
  return result;
}

async function checkCmd(say, emit) {
  if (!(await needAuth(say))) return;
  const r = await checkPass(say, emit, { deadline: Date.now() + BURST_MS, quiet: false });
  say('');
  if (r.errors > 0) {
    say('📋 Check selesai: ' + r.pending + ' mention baru · ' + r.replied + ' dibalas · ' + r.errors + ' error (lihat catatan di atas).');
  } else if (r.pending === 0) {
    say('✅ Check selesai — tidak ada mention baru.');
  } else {
    say('📋 Check selesai: ' + r.pending + ' mention baru · ' + r.replied + ' dibalas.');
  }
  if (r.stop === 'tier') say('ℹ️ Membaca mentions butuh tier Basic/Premium — /tw tweet dan /tw reply manual tetap jalan di Free.');
  if (r.stop === 'ratelimit') say('ℹ️ Rate limit — tunggu beberapa menit lalu /tw check lagi.');
  if (r.stop === 'auth') say('ℹ️ Perbaiki token di setup form, lalu /tw check lagi.');
}

async function autoCmd(say, emit, argv) {
  if (!(await needAuth(say))) return;
  const parts = argv.split(/\s+/);
  let interval = parts[1] ? parseInt(parts[1], 10) : 20;
  if (!isFinite(interval) || interval <= 0) interval = 20;
  if (interval < 10) interval = 10;
  const deadline = Date.now() + BURST_MS;
  let pass = 0;
  let pending = 0;
  let replied = 0;
  let errors = 0;
  emit('👀 Burst watch: interval ' + interval + 's · batas ±' + Math.round(BURST_MS / 1000) + 's per run.');
  for (;;) {
    pass++;
    const r = await checkPass(say, emit, { deadline: deadline, quiet: true });
    pending += r.pending;
    replied += r.replied;
    errors += r.errors;
    emit('— Pass ' + pass + ': ' + r.pending + ' mention baru · ' + r.replied + ' dibalas · ' + r.errors + ' error');
    if (r.noAuth) break;
    if (r.stop) {
      if (r.stop === 'tier') emit('ℹ️ Tier tidak mendukung baca mentions — burst dihentikan (posting tetap jalan).');
      if (r.stop === 'auth') emit('ℹ️ Token invalid — burst dihentikan, perbaiki setup form.');
      if (r.stop === 'ratelimit') emit('ℹ️ Rate limit — burst dihentikan, jalankan /tw auto lagi nanti.');
      break;
    }
    const remaining = deadline - Date.now();
    if (remaining < interval * 1000 + 1500) break;
    await sleep(Math.min(interval * 1000, remaining - 1000));
  }
  emit('📊 Total ' + pass + ' pass · ' + pending + ' mention baru · ' + replied + ' balasan · ' + errors + ' error.');
  emit('Burst selesai — jalankan /tw auto lagi untuk lanjut.');
}

async function toggleCmd(say, on) {
  const cfg = (await getJson('config', {})) || {};
  cfg.autoReply = !!on;
  await setJson('config', cfg);
  say('🔧 Auto-reply mentions: ' + (on ? 'ON' : 'OFF') + ' — disimpan untuk chat ini.');
  if (on) say('   /tw check untuk satu pass, atau /tw auto [detik] untuk burst watch.');
}

function showTemplateKey(say, key, variants) {
  say('  ' + key + ':');
  const vs = (variants && variants.length) ? variants : DEFAULT_TEMPLATES[key];
  for (let i = 0; i < vs.length; i++) say('    ' + (i + 1) + '. ' + vs[i]);
}

function listTemplates(say, templates) {
  say('🧩 Template balasan chat ini — placeholder {name} = @pengirim, {me} = @akunmu:');
  for (const key of TEMPLATE_KEYS) {
    showTemplateKey(say, key, (templates || {})[key]);
  }
  say('   Set varian: /tw template <key> Teks A | Teks B (1-4 varian, maks 240 karakter)');
  say('   Reset semua: /tw template reset');
}

async function templateCmd(say, argv) {
  const rest = argv.replace(/^template/, '').trim();
  const stored = await loadTemplates();
  if (!rest) {
    listTemplates(say, stored);
    return;
  }
  if (rest === 'reset') {
    await setJson('templates', JSON.parse(JSON.stringify(DEFAULT_TEMPLATES)));
    say('♻️ Semua template dikembalikan ke bawaan:');
    listTemplates(say, DEFAULT_TEMPLATES);
    return;
  }
  const sp = rest.indexOf(' ');
  const key = (sp < 0 ? rest : rest.slice(0, sp)).toLowerCase();
  if (TEMPLATE_KEYS.indexOf(key) < 0) {
    say('❌ Kunci template tidak dikenal: "' + key + '" — pilih: ' + TEMPLATE_KEYS.join(', '));
    return;
  }
  const body = sp < 0 ? '' : rest.slice(sp + 1).trim();
  if (!body) {
    showTemplateKey(say, key, stored[key]);
    return;
  }
  const variants = body.split('|').map((s) => s.trim()).filter((s) => s.length > 0);
  if (!variants.length) {
    showTemplateKey(say, key, stored[key]);
    return;
  }
  const trimmed = [];
  let cut = false;
  for (const v of variants.slice(0, 4)) {
    if (v.length > 240) { cut = true; trimmed.push(v.slice(0, 240)); }
    else trimmed.push(v);
  }
  stored[key] = trimmed;
  await setJson('templates', stored);
  say('✅ Template "' + key + '" disimpan (' + trimmed.length + ' varian' + (cut ? ', varian di atas 240 karakter dipangkas' : '') + '):');
  showTemplateKey(say, key, trimmed);
}

async function tweetCmd(say, rest) {
  const auth = await needAuth(say);
  if (!auth) return;
  let withPolish = false;
  let text = String(rest || '');
  if (/^polish(\s|$)/i.test(text)) {
    withPolish = true;
    text = text.replace(/^polish\s*/i, '').trim();
  }
  if (!text) {
    say('Usage: /tw tweet <teks> · /tw tweet polish <teks>');
    return;
  }
  if (text.length > TWEET_LIMIT) {
    say('⚠️ Teks ' + text.length + ' karakter — dipangkas ke ' + TWEET_LIMIT + '.');
    text = text.slice(0, TWEET_LIMIT - 1) + '…';
  }
  let finalText = text;
  if (withPolish) {
    const sent = (await getJson('sent', [])) || [];
    finalText = await polishReply(say, text, text, sent);
    say('✨ Hasil polish: ' + finalText);
  }
  const me = await resolveMe(say);
  const post = await xApi('POST', '/2/tweets', null, { text: finalText }, auth);
  if (!post.ok || !post.data || !post.data.data || !post.data.data.id) {
    describeError(say, post);
    return;
  }
  await bumpStats((s) => { s.tweets = (s.tweets || 0) + 1; });
  const handle = (me && me.username) || auth.handle || 'i';
  say('🚀 Tweet terkirim: https://x.com/' + handle + '/status/' + post.data.data.id);
}

function extractTweetId(s) {
  const t = String(s || '').trim();
  const um = /(?:https?:\/\/)?(?:www\.)?(?:x|twitter)\.com\/[^\s]+\/status\/(\d+)/i.exec(t);
  if (um) return um[1];
  const bm = /^(\d{1,25})$/.exec(t);
  return bm ? bm[1] : null;
}

async function replyCmd(say, rest) {
  const auth = await needAuth(say);
  if (!auth) return;
  const parts = String(rest || '').split(/\s+/);
  const ref = parts[0] || '';
  const wantedKey = parts[1] ? parts[1].toLowerCase() : 'generic';
  const tid = extractTweetId(ref);
  if (!tid) {
    say('❌ ID tweet tidak ditemukan. Contoh: /tw reply https://x.com/user/status/123456 [templateKey] atau /tw reply 123456 praise');
    return;
  }
  const templates = await loadTemplates();
  const tplKey = TEMPLATE_KEYS.indexOf(wantedKey) >= 0 ? wantedKey : 'generic';
  say('⏳ Membaca tweet ' + tid + ' …');
  const res = await xApi('GET', '/2/tweets/' + tid, {
    'tweet.fields': 'author_id',
    expansions: 'author_id'
  }, null, auth);
  if (!res.ok || !res.data || !res.data.data) {
    describeError(say, res);
    return;
  }
  const t = res.data.data;
  let uname = 'user';
  const users = ((res.data.includes || {}).users) || [];
  for (const u of users) {
    if (String(u.id) === String(t.author_id)) uname = String(u.username || 'user');
  }
  say('↩️ Membalas @' + uname + ' (template: ' + tplKey + '): ' + clip(String(t.text || ''), 90));
  const filled = fillTemplate(pick(templates[tplKey] || DEFAULT_TEMPLATES.generic), uname, auth.handle);
  const reply = await polishReply(say, filled, String(t.text || ''), (await getJson('sent', [])) || []);
  const post = await xApi('POST', '/2/tweets', null, {
    text: reply,
    reply: { in_reply_to_tweet_id: String(t.id) }
  }, auth);
  if (!post.ok || !post.data || !post.data.data || !post.data.data.id) {
    describeError(say, post);
    return;
  }
  const sent = (await getJson('sent', [])) || [];
  sent.push({ text: reply, at: nowIso() });
  trimSent(sent);
  await setJson('sent', sent);
  const seen = (await getJson('seenMentions', [])) || [];
  seen.push(String(t.id)); // sudah dibalas manual — jangan di-auto-reply lagi
  trimSeen(seen);
  await setJson('seenMentions', seen);
  await bumpStats((s) => { s.replies = (s.replies || 0) + 1; });
  const me = await resolveMe(say);
  const handle = (me && me.username) || auth.handle || 'i';
  say('✅ Balasan terkirim: https://x.com/' + handle + '/status/' + post.data.data.id);
}

async function logoutCmd(say) {
  await removeKey('auth');
  await removeKey('me');
  await removeKey('seenMentions');
  say('🔓 Logout: kredensial, cache akun, dan riwayat mention chat ini dihapus.');
  say('   Catatan: jika setup form masih terisi, run berikutnya akan otomatis menyimpan & memverifikasi ulang kredensial yang sama.');
  say('   Untuk berhenti total, nonaktifkan modul ini di chat — atau logout lalu ubah kredensial di setup form.');
}

// ------------------------------------------------------------ AI polishing

/**
 * Slot-filled template -> zagents.agent.polish (NEW SDK API) -> final text.
 * Polish THROWS on failure: always caught here, falling back to the
 * already slot-filled template. Never lets polish errors crash the run.
 */
async function polishReply(say, filled, contextText, sent) {
  let reply = String(filled || '');
  try {
    const avoid = [];
    for (const s of (sent || []).slice(-8)) avoid.push(String(s.text || ''));
    const res = await zagents.agent.polish({
      template: filled,                                   // required
      vars: {},                                           // optional
      context: (contextText && String(contextText).trim()) ? String(contextText) : filled, // required, non-empty
      language: 'auto',                                   // 'auto' | 'id' | 'en' | ...
      tone: 'casual',                                     // 'friendly' | 'professional' | 'casual'
      maxChars: TWEET_LIMIT,                              // X free-account limit (host clamps 20..500)
      allowEmoji: false,
      avoid: avoid                                        // up to 8 recent sent replies
    });
    if (res && typeof res.text === 'string' && res.text.trim().length > 0) {
      reply = res.text.trim();
    }
  } catch (e) {
    say('   ℹ️ polish gagal (' + errMsg(e) + ') — memakai varian template.');
  }
  if (reply.length > TWEET_LIMIT) reply = reply.slice(0, TWEET_LIMIT - 1) + '…';
  return reply;
}

/** keyword-based intent classification (Indonesian + English) */
function classify(text) {
  const words = String(text || '').toLowerCase().match(/[a-z0-9]+/g) || [];
  const has = (list) => {
    for (const w of words) { if (list.indexOf(w) >= 0) return true; }
    return false;
  };
  if (has(KEYWORDS.support)) return 'support';
  if (has(KEYWORDS.praise)) return 'praise';
  if (has(KEYWORDS.question)) return 'question';
  return 'generic';
}

// -------------------------------------------------------------------- main

async function run() {
  const info = zagents.info || {};
  const raw = String(info.prompt || '');
  const argv = raw.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
  const out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };
  const emit = async (t) => {
    try { await zagents.chat.emit(String(t)); } catch (e) { /* keep going */ }
  };

  // first run after setup: persist creds + config, verify once
  await bootstrap(say, emit);

  if (!argv || argv === 'help') {
    helpCmd(say);
  } else if (argv === 'status') {
    await statusCmd(say);
  } else if (argv === 'check') {
    await checkCmd(say, emit);
  } else if (argv === 'auto' || argv.indexOf('auto ') === 0) {
    await autoCmd(say, emit, argv);
  } else if (argv === 'on') {
    await toggleCmd(say, true);
  } else if (argv === 'off') {
    await toggleCmd(say, false);
  } else if (argv === 'template' || argv.indexOf('template ') === 0) {
    await templateCmd(say, argv);
  } else if (argv === 'tweet') {
    say('Usage: /tw tweet <teks> · /tw tweet polish <teks>');
  } else if (argv.indexOf('tweet ') === 0) {
    await tweetCmd(say, argv.slice(6).trim());
  } else if (argv.indexOf('reply ') === 0) {
    await replyCmd(say, argv.slice(6).trim());
  } else if (argv === 'logout') {
    await logoutCmd(say);
  } else {
    say('❓ Perintah tidak dikenal: "' + argv + '"');
    say('');
    helpCmd(say);
  }

  for (const line of out) await zagents.log(line);
  return { cmd: argv ? argv.split(/\s+/)[0] : 'help' };
}

async function main() {
  try {
    const r = await run();
    return Object.assign({ module: 'twitter-x' }, r || {});
  } catch (e) {
    try { await zagents.log('❌ twitter-x error: ' + errMsg(e)); } catch (e2) { /* ignore */ }
    return { module: 'twitter-x', error: errMsg(e) };
  }
}

module.exports = main();
