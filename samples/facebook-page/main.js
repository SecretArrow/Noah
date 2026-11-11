/* ============================================================================
 *  Facebook Page Assistant — ZAgents chat module (samples/facebook-page)
 *  ----------------------------------------------------------------------------
 *  Auto-login ke Fanspage via Page Access Token, lalu membalas pesan
 *  Messenger dan komentar post secara otomatis, natural seperti manusia:
 *    - /fb (kosong) | status : validasi token (GET /me), identitas page,
 *                              config, statistik, antrean yang belum diproses
 *    - /fb check             : SATU pass penuh — poll conversations + posts,
 *                              klasifikasi intent, template + polish AI,
 *                              kirim dengan jeda manusiawi
 *    - /fb auto [detik]      : burst watch — pass berulang tiap N detik
 *                              sampai budget run (~110 dtk) hampir habis
 *    - /fb template [..]     : kelola 8 template (greeting/question/price/
 *                              shipping/thanks/complaint/generic/away)
 *    - /fb on|off, speed, logout, help
 *
 *  Konvensi penting:
 *    - Semua HTTP lewat zagents.http.request (TIDAK ada global fetch) dan
 *      HANYA ke graph.facebook.com (allowedHosts) — Graph API v21.0.
 *    - GET: semua param di query string (termasuk access_token, di-encode).
 *      POST JSON: body JSON.stringify + header Content-Type application/json.
 *    - Token page disimpan per chat (zagents.storage) dan TIDAK PERNAH
 *      ditampilkan utuh (hanya '••••' + 4 karakter terakhir).
 *    - Setiap balasan: template intent dipilih acak -> placeholder diisi
 *      sendiri SEBELUM dipolish -> zagents.agent.polish (try/catch; gagal =
 *      fallback ke template yang sudah diisi) -> kirim -> dicatat ke 'sent'
 *      (maks 10) untuk avoid/anti-repetisi.
 *    - Kegagalan kirim (termasuk jendela 24 jam Messenger: subcode 2018278
 *      / code 10) tidak pernah membatalkan pass: tandai sudah dibaca,
 *      emit catatan singkat, lanjut item berikutnya.
 *
 *  Zero npm dependencies. Requires the ZAgents module runtime.
 * ==========================================================================*/

'use strict';

/* --------------------------------------------------------------- konstanta */

const API_BASE = 'https://graph.facebook.com/v21.0';
const MAX_SEEN = 300;             // cap seenMsg / seenCmt (buang terlama)
const MAX_SENT = 10;              // riwayat balasan untuk anti-repetisi
const MAX_AVOID = 8;              // jumlah 'avoid' yang dikirim ke polish
const REPLY_MAXCHARS = 300;       // maxChars untuk zagents.agent.polish
const BUDGET_MS = 110000;         // budget run (manifest timeout 120 dtk)
const MARGIN_MS = 8000;           // margin aman sebelum tepi budget
const CHECK_DEADLINE_MS = 100000; // deadline satu pass /fb check
const HTTP_TIMEOUT_MS = 15000;    // timeout per request Graph
const MIN_INTERVAL_S = 10;        // /fb auto: jarak pass minimum (detik)
const MAX_INTERVAL_S = 60;        // /fb auto: jarak pass maksimum (detik)

// jeda antar balasan per mode kecepatan (min..max, milidetik)
const SPEEDS = { fast: [3000, 6000], normal: [6000, 15000], slow: [15000, 30000] };

const TEMPLATE_KEYS = ['greeting', 'question', 'price', 'shipping', 'thanks', 'complaint', 'generic', 'away'];

/* Template bawaan — gaya fanpage Indonesia kasual natural. Placeholder:
   {name} = nama depan pengirim, {page} = nama halaman.                       */
const DEFAULT_TEMPLATES = {
  greeting: [
    'Halo {name}, makasih sudah mampir ke {page}. Ada yang bisa kami bantu?',
    'Hai {name}, selamat datang di {page}. Silakan tanya apa saja ya.',
    'Halo kak {name}, senang kamu mampir ke {page}. Mau cari apa hari ini?',
  ],
  question: [
    'Halo {name}, pertanyaan yang bagus. Tim {page} bantu jawab sebentar ya.',
    'Hai {name}, makasih sudah bertanya. Kami cek dulu dan segera dibalas detailnya ya.',
    'Halo {name}, tim {page} jawab di sini ya. Kalau masih ada yang mau ditanyakan, langsung saja.',
  ],
  price: [
    'Halo {name}, untuk harga terbaru bisa dicek di katalog {page} ya. Kalau mau penawaran khusus, kabarin kami.',
    'Hai {name}, harganya berbeda tiap varian. Sebutkan varian yang kamu maksud, nanti kami kirim detail harganya.',
  ],
  shipping: [
    'Halo {name}, {page} kirim ke seluruh Indonesia dan ongkirnya dihitung sesuai lokasi ya.',
    'Hai {name}, pesanan diproses 1-2 hari kerja lalu dikirim lengkap dengan nomor resi. Cek ongkirnya kami bantu ya.',
  ],
  thanks: [
    'Terima kasih banyak {name}, senang bisa membantu. Salam hangat dari tim {page}.',
    'Sama-sama {name}, makasih sudah support {page}. Sering-sering mampir ya.',
  ],
  complaint: [
    'Halo {name}, mohon maaf atas ketidaknyamanannya. Tim {page} mau bantu selesaikan — boleh kami tahu detail kendalanya?',
    'Hai {name}, kami mohon maaf sebesar-besarnya. Langsung chat {page} ya, laporan kamu kami proses dengan prioritas.',
  ],
  generic: [
    'Halo {name}, makasih sudah menyapa {page}. Ada yang bisa kami bantu?',
    'Hai {name}, pesan kamu sudah kami baca ya. Tim {page} siap membantu kalau ada pertanyaan.',
  ],
  away: [
    'Halo {name}, tim {page} sedang tidak di tempat. Tinggalkan pesan, kami balas secepatnya di jam kerja ya.',
    'Hai {name}, kami balas pesanmu segera setelah kembali ya. Makasih sudah menghubungi {page}.',
  ],
};

// klasifikasi intent berbasis kata kunci (Indonesia + Inggris), urutan penting
const INTENT_RULES = [
  ['price', /\b(harga|buy|price|beli)\b/i],
  ['shipping', /\b(kirim|ongkir|shipping|delivery)\b/i],
  ['thanks', /\b(terima\s+kasih|thanks|makasih)\b/i],
  ['complaint', /\b(rusak|kecewa|komplain|complain|bad)\b/i],
  ['greeting', /\b(halo|hai|min|sis|kak)\b/i],
  ['question', /\b(kapan|bagaimana|bisa|apakah|how|when)\b/i],
];

/* ------------------------------------------------------------------- utils */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowIso = () => new Date().toISOString();

function clip(s, n) {
  const t = String(s || '');
  return t.length <= n ? t : t.slice(0, n - 1) + '…';
}

function errMsg(e) {
  return e && e.message ? String(e.message) : String(e);
}

async function log(...parts) {
  try { await zagents.log(parts.join(' ')); } catch (e) { /* keep going */ }
}

async function emit(text) {
  try { await zagents.chat.emit(text); } catch (e) { /* keep going */ }
}

function boolish(v, dflt) {
  if (v === undefined || v === null || v === '') return dflt;
  if (typeof v === 'string') return !(v === 'false' || v === '0' || v === 'no' || v === 'off');
  return !!v;
}

function pushCapped(list, value, cap) {
  if (value === undefined || value === null) return list;
  list.push(String(value));
  while (list.length > cap) list.shift();
  return list;
}

function maskToken(token) {
  const t = String(token || '');
  return t.length >= 8 ? '••••' + t.slice(-4) : '••••';
}

function fmtTime(iso) {
  if (!iso) return 'belum ada';
  const t = new Date(iso);
  if (isNaN(t.getTime())) return String(iso);
  return t.toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
}

function speedLabel(speed) {
  const r = SPEEDS[speed] || SPEEDS.normal;
  return (r[0] / 1000) + '-' + (r[1] / 1000) + ' dtk';
}

function delayMs(speed) {
  const r = SPEEDS[speed] || SPEEDS.normal;
  return r[0] + Math.floor(Math.random() * (r[1] - r[0] + 1));
}

function classifyIntent(text) {
  const t = String(text || '');
  for (const rule of INTENT_RULES) {
    if (rule[1].test(t)) return rule[0];
  }
  return 'generic';
}

// nama depan pengirim; fallback 'kak' untuk id, kosong untuk en
function firstNameOf(fullName, lang) {
  const full = String(fullName || '').trim();
  const dflt = String(lang || '').toLowerCase() === 'en' ? '' : 'kak';
  if (!full) return dflt;
  return full.split(/\s+/)[0] || dflt;
}

function displayName(fullName, lang) {
  return firstNameOf(fullName, lang) || 'pengguna';
}

/* ------------------------------------------------- storage (per chat, aman) */

async function loadRaw(key) {
  try { return await zagents.storage.get(key); } catch (e) { return undefined; }
}

async function saveJson(key, value) {
  try {
    await zagents.storage.set(key, value);
    return true;
  } catch (e) {
    await log('⚠️ Gagal menyimpan ' + key + ': ' + clip(errMsg(e), 120));
    return false;
  }
}

async function removeKey(key) {
  try { await zagents.storage.remove(key); } catch (e) { /* ignore */ }
}

async function loadList(key, cap) {
  const v = await loadRaw(key);
  if (!Array.isArray(v)) return [];
  return v.filter((x) => typeof x === 'string').slice(-cap);
}

function sanitizeConfig(c) {
  return {
    autoMessages: boolish(c ? c.autoMessages : undefined, true),
    autoComments: boolish(c ? c.autoComments : undefined, true),
    language: c && typeof c.language === 'string' ? c.language.trim().toLowerCase() : '',
    speed: c && SPEEDS[c.speed] ? c.speed : 'normal',
  };
}

function sanitizeTemplates(t) {
  const out = {};
  for (const key of TEMPLATE_KEYS) {
    const v = t ? t[key] : null;
    if (Array.isArray(v)) {
      const vs = v.filter((x) => typeof x === 'string' && x.trim()).map((x) => clip(x.trim(), 300));
      out[key] = vs.length ? vs : DEFAULT_TEMPLATES[key].slice();
    } else {
      out[key] = DEFAULT_TEMPLATES[key].slice();
    }
  }
  return out;
}

function sanitizeStats(s) {
  return {
    messages: Number(s ? s.messages : 0) || 0,
    comments: Number(s ? s.comments : 0) || 0,
    lastCheck: s && typeof s.lastCheck === 'string' ? s.lastCheck : '',
    startedAt: s && typeof s.startedAt === 'string' && s.startedAt ? s.startedAt : nowIso(),
  };
}

function defaultTemplates() {
  return sanitizeTemplates(null);
}

async function loadState() {
  const S = {
    token: '',
    page: null,
    config: null,
    templates: null,
    seenMsg: await loadList('seenMsg', MAX_SEEN),
    seenCmt: await loadList('seenCmt', MAX_SEEN),
    sent: await loadList('sent', MAX_SENT),
    stats: null,
    authOk: null,
    authError: '',
  };
  const tok = await loadRaw('token');
  if (typeof tok === 'string' && tok.trim()) S.token = tok.trim();
  const page = await loadRaw('page');
  if (page && typeof page === 'object' && page.id) S.page = page;
  const cfg = await loadRaw('config');
  if (cfg && typeof cfg === 'object') S.config = sanitizeConfig(cfg);
  const tpl = await loadRaw('templates');
  if (tpl && typeof tpl === 'object') S.templates = sanitizeTemplates(tpl);
  const st = await loadRaw('stats');
  if (st && typeof st === 'object') S.stats = sanitizeStats(st);
  return S;
}

/* --------------------------------------------------------------- Graph API */

// query string aman: semua param di-encode (termasuk access_token)
function qs(params) {
  const parts = [];
  for (const k of Object.keys(params)) {
    const v = params[k];
    if (v === undefined || v === null) continue;
    parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
  }
  return parts.join('&');
}

async function readJson(res) {
  try {
    if (res && typeof res.json === 'function') {
      const j = await res.json();
      if (j && typeof j === 'object') return j;
    }
  } catch (e) { /* fall through */ }
  try {
    const raw = res && typeof res.body === 'string' ? res.body
      : (res && res.body && typeof res.body === 'object' ? JSON.stringify(res.body) : '');
    const j = raw ? JSON.parse(raw) : null;
    if (j && typeof j === 'object') return j;
  } catch (e) { /* ignore */ }
  return null;
}

function graphFailure(errObj) {
  const e = new Error(errObj && typeof errObj.message === 'string' ? errObj.message : 'Graph API error');
  e.graph = true;
  e.code = errObj && errObj.code !== undefined ? Number(errObj.code) || 0 : 0;
  e.subcode = errObj && errObj.error_subcode !== undefined ? Number(errObj.error_subcode) || 0 : 0;
  return e;
}

function isWindowError(e) {
  return !!(e && e.graph && (e.subcode === 2018278 || e.code === 10));
}

async function graphGet(path, params, token) {
  const url = API_BASE + path + '?' + qs(Object.assign({}, params, { access_token: token }));
  let res;
  try {
    res = await zagents.http.request(url, { method: 'GET', timeoutMs: HTTP_TIMEOUT_MS });
  } catch (e) {
    throw new Error('koneksi ke Graph API gagal: ' + clip(errMsg(e), 120));
  }
  const data = await readJson(res);
  if (data && data.error) throw graphFailure(data.error);
  if (!res || !res.ok) throw new Error('HTTP ' + (res && res.status ? res.status : '?') + ' dari Graph API');
  return data || {};
}

async function graphPost(path, bodyObj, token) {
  const url = API_BASE + path + '?' + qs({ access_token: token });
  let res;
  try {
    res = await zagents.http.request(url, {
      method: 'POST',
      body: JSON.stringify(bodyObj),
      headers: { 'Content-Type': 'application/json' },
      timeoutMs: HTTP_TIMEOUT_MS,
    });
  } catch (e) {
    throw new Error('koneksi ke Graph API gagal: ' + clip(errMsg(e), 120));
  }
  const data = await readJson(res);
  if (data && data.error) throw graphFailure(data.error);
  if (!res || !res.ok) throw new Error('HTTP ' + (res && res.status ? res.status : '?') + ' dari Graph API');
  return data || {};
}

/* --------------------------------------------- setup form + validasi token */

function readHostSetup() {
  try {
    const s = zagents.info && zagents.info.setup;
    if (s && typeof s === 'object' && Object.keys(s).length) return s;
  } catch (e) { /* host tanpa info.setup */ }
  return null;
}

function applySetupConfig(setup) {
  return {
    autoMessages: boolish(setup ? setup.autoMessages : undefined, true),
    autoComments: boolish(setup ? setup.autoComments : undefined, true),
    language: setup && typeof setup.language === 'string' ? setup.language.trim().toLowerCase() : '',
    speed: 'normal',
  };
}

// Mirror setup form -> storage. Return true bila token BARU diterapkan
// (fresh login): config diambil ulang dari form, page divalidasi ulang.
async function mirrorSetup(S) {
  const setup = readHostSetup();
  const setupToken = setup && typeof setup.pageToken === 'string' ? setup.pageToken.trim() : '';
  let fresh = false;
  if (setupToken && setupToken !== S.token) {
    S.token = setupToken;
    await saveJson('token', S.token);
    S.page = null;
    await removeKey('page');
    S.config = applySetupConfig(setup);
    await saveJson('config', S.config);
    fresh = true;
  }
  if (!S.config) { S.config = applySetupConfig(setup); await saveJson('config', S.config); }
  if (!S.templates) { S.templates = defaultTemplates(); await saveJson('templates', S.templates); }
  if (!S.stats) { S.stats = sanitizeStats(null); await saveJson('stats', S.stats); }
  return fresh;
}

// GET /me — bukti auto-login; simpan identitas page + emit namanya
async function validateToken(S, fresh) {
  try {
    const me = await graphGet('/me', { fields: 'id,name,category' }, S.token);
    const page = {
      id: me && me.id !== undefined ? String(me.id) : '',
      name: me && typeof me.name === 'string' ? me.name : '',
      category: me && typeof me.category === 'string' ? me.category : '',
    };
    S.authOk = true;
    S.authError = '';
    if (fresh || !S.page || S.page.id !== page.id) {
      S.page = page;
      await saveJson('page', S.page);
      await emit('🔐 Login otomatis OK: ' + (page.name || 'Page') + (page.category ? ' · ' + page.category : ''));
    }
  } catch (e) {
    S.authOk = false;
    S.authError = errMsg(e);
  }
}

/* --------------------------------------------------------------- collector */

// 1) Messenger: conversation terbaru + pesan di dalamnya
async function collectMessages(S) {
  const pageId = S.page && S.page.id ? String(S.page.id) : '';
  const data = await graphGet('/me/conversations', {
    fields: 'id,updated_time,participants,messages.limit(15){id,from,message,created_time}',
    limit: 10,
  }, S.token);
  const items = [];
  const convs = data && Array.isArray(data.data) ? data.data : [];
  for (const conv of convs) {
    const msgs = conv && conv.messages && Array.isArray(conv.messages.data) ? conv.messages.data : [];
    for (const m of msgs) {
      if (!m || !m.id || S.seenMsg.indexOf(m.id) !== -1) continue;
      const from = m.from || null;
      if (!from || !from.id) continue;
      if (pageId && String(from.id) === pageId) continue; // pesan page sendiri
      items.push({
        kind: 'message',
        id: m.id,
        fromId: String(from.id),
        name: from && typeof from.name === 'string' ? from.name : '',
        text: typeof m.message === 'string' ? m.message : '',
        at: typeof m.created_time === 'string' ? m.created_time : '',
      });
    }
  }
  items.sort((a, b) => atMs(a) - atMs(b)); // terlama dulu (kronologis)
  return items;
}

// 2) Komentar: post terbaru + komentarnya
async function collectComments(S) {
  const pageId = S.page && S.page.id ? String(S.page.id) : '';
  const data = await graphGet('/me/posts', {
    fields: 'id,permalink_url,comments.limit(50){id,message,from{id,name},created_time,parent_id}',
    limit: 10,
  }, S.token);
  const items = [];
  const posts = data && Array.isArray(data.data) ? data.data : [];
  for (const p of posts) {
    const cmts = p && p.comments && Array.isArray(p.comments.data) ? p.comments.data : [];
    for (const c of cmts) {
      if (!c || !c.id || S.seenCmt.indexOf(c.id) !== -1) continue;
      const from = c.from || null;
      if (pageId && from && from.id && String(from.id) === pageId) continue; // balasan page sendiri
      items.push({
        kind: 'comment',
        id: c.id,
        name: from && typeof from.name === 'string' ? from.name : '',
        text: typeof c.message === 'string' ? c.message : '',
        at: typeof c.created_time === 'string' ? c.created_time : '',
      });
    }
  }
  items.sort((a, b) => atMs(a) - atMs(b));
  return items;
}

function atMs(item) {
  const t = Date.parse(item.at || '');
  return isNaN(t) ? 0 : t;
}

function markSeen(S, item) {
  if (item.kind === 'message') pushCapped(S.seenMsg, item.id, MAX_SEEN);
  else pushCapped(S.seenCmt, item.id, MAX_SEEN);
}

/* ------------------------------------------------------------ balasan + AI */

function templateVariants(templates, key) {
  const v = templates ? templates[key] : null;
  if (Array.isArray(v) && v.length) return v;
  return (DEFAULT_TEMPLATES[key] || DEFAULT_TEMPLATES.generic).slice();
}

// template dipilih acak -> placeholder diisi -> polish (fallback = template)
async function composeReply(S, item) {
  const intent = classifyIntent(item.text);
  const lang = String(S.config.language || '').toLowerCase();
  const name = firstNameOf(item.name, lang);
  const pageName = S.page && S.page.name ? S.page.name : 'kami';
  const variants = templateVariants(S.templates, intent);
  const variant = variants[Math.floor(Math.random() * variants.length)] || '';
  const filled = variant.split('{name}').join(name).split('{page}').join(pageName);
  return polishReply({
    template: filled,
    context: item.text,
    language: lang || 'auto',
    avoid: S.sent.slice(-MAX_AVOID),
  });
}

async function polishReply(opts) {
  const fallback = opts.template; // sudah slot-filled
  if (!opts.context || !String(opts.context).trim()) return fallback;
  try {
    const res = await zagents.agent.polish({
      template: opts.template,
      vars: {},
      context: String(opts.context),
      language: opts.language || 'auto',
      tone: 'friendly',
      maxChars: REPLY_MAXCHARS,
      allowEmoji: false,
      avoid: Array.isArray(opts.avoid) ? opts.avoid.slice(0, MAX_AVOID) : [],
    });
    const text = res && typeof res.text === 'string' ? res.text.trim() : '';
    return text || fallback;
  } catch (e) {
    return fallback; // polish gagal (API key/provider) — jangan crash pass
  }
}

/* ----------------------------------------------------------- mesin pass */

// Satu pass = poll pesan + komentar, lalu balas item baru dengan jeda
// manusiawi. Tidak pernah melempar error ke caller; deadline menjaga
// agar state selalu tersimpan sebelum timeout modul.
async function runPass(S, deadlineMs) {
  const summary = {
    pendingMessages: 0, pendingComments: 0,
    messagesSent: 0, commentsSent: 0,
    failed: 0, skipped: 0, stoppedEarly: false, allOff: false,
  };
  if (!S.config.autoMessages && !S.config.autoComments) {
    summary.allOff = true;
    await emit('⏸️ Auto-reply pesan dan komentar sedang OFF — aktifkan dengan /fb on messages atau /fb on comments.');
    return summary;
  }

  // 1) poll Messenger
  let msgItems = [];
  try { msgItems = await collectMessages(S); }
  catch (e) { await emit('⚠️ Gagal polling Messenger: ' + clip(errMsg(e), 140)); }

  // 2) poll komentar post
  let cmtItems = [];
  try { cmtItems = await collectComments(S); }
  catch (e) { await emit('⚠️ Gagal polling komentar: ' + clip(errMsg(e), 140)); }

  // 3) antrean: pesan dulu (bila autoMessages), lalu komentar (bila autoComments)
  const queue = [];
  if (S.config.autoMessages) for (const it of msgItems) queue.push(it);
  if (S.config.autoComments) for (const it of cmtItems) queue.push(it);
  summary.pendingMessages = msgItems.length;
  summary.pendingComments = cmtItems.length;

  if (!queue.length) {
    await emit('✅ Bersih — tidak ada pesan/komentar baru untuk dibalas.');
    S.stats.lastCheck = nowIso();
    await saveJson('stats', S.stats);
    return summary;
  }

  let attempts = 0;
  for (const item of queue) {
    if (Date.now() > deadlineMs) { summary.stoppedEarly = true; break; }

    // item tanpa teks (stiker/lampiran): tandai dibaca, jangan dibalas
    if (!String(item.text || '').trim()) { markSeen(S, item); summary.skipped++; continue; }

    const who = displayName(item.name, S.config.language);
    await emit(item.kind === 'message'
      ? '💬 Balas pesan dari ' + who + '…'
      : 'Balas komentar dari ' + who + '…');

    const reply = await composeReply(S, item);
    if (Date.now() > deadlineMs) { summary.stoppedEarly = true; break; }

    // jeda manusiawi ANTAR pengiriman (fast 3-6 / normal 6-15 / slow 15-30 dtk)
    if (attempts > 0) {
      const wait = Math.min(delayMs(S.config.speed), Math.max(0, deadlineMs - Date.now() - 500));
      if (wait > 0) await sleep(wait);
      if (Date.now() > deadlineMs) { summary.stoppedEarly = true; break; }
    }

    // 5) kirim
    try {
      if (item.kind === 'message') {
        // psid = id pengirim pada pesan tersebut
        await graphPost('/me/messages', {
          recipient: { id: item.fromId },
          message: { text: reply },
        }, S.token);
      } else {
        await graphPost('/' + encodeURIComponent(item.id) + '/comments', {
          message: reply,
        }, S.token);
      }
      attempts++;
      pushCapped(S.sent, reply, MAX_SENT);
      markSeen(S, item);
      if (item.kind === 'message') { S.stats.messages++; summary.messagesSent++; }
      else { S.stats.comments++; summary.commentsSent++; }
    } catch (e) {
      // 8) gagal kirim: tandai dibaca, catatan singkat, lanjut (jangan abort)
      attempts++;
      markSeen(S, item);
      summary.failed++;
      if (isWindowError(e)) {
        await emit('⏭️ ' + who + ' di luar jendela balasan 24 jam / izin API kurang — ditandai dibaca tanpa dibalas.');
      } else {
        await emit('⚠️ Gagal balas ' + (item.kind === 'message' ? 'pesan' : 'komentar') + ' ' + who
          + ': ' + clip(errMsg(e), 120) + ' — lanjut item berikutnya.');
      }
    }
  }

  await saveJson('seenMsg', S.seenMsg);
  await saveJson('seenCmt', S.seenCmt);
  await saveJson('sent', S.sent);
  S.stats.lastCheck = nowIso();
  await saveJson('stats', S.stats);

  // 7) ringkasan pass
  await emit('📊 Pass selesai: ' + summary.messagesSent + ' pesan · ' + summary.commentsSent
    + ' komentar dibalas · ' + summary.failed + ' gagal · ' + summary.skipped
    + ' dilewati (tanpa teks).');
  return summary;
}

/* --------------------------------------------------------------- perintah */

async function statusCmd(S, say) {
  if (!S.token) {
    say('📘 Facebook Page Assistant — belum login di chat ini.');
    say('Isi form setup modul (Page Access Token) — form muncul otomatis saat modul dijalankan pertama kali.');
    say('Token disimpan per chat dan tidak pernah ditampilkan utuh.');
    return;
  }
  if (S.authOk === false) {
    say('❌ Token page ditolak Graph API: ' + clip(S.authError, 160));
    say('   Perbarui Page Access Token lewat form setup (token bisa expired), lalu jalankan /fb lagi.');
    return;
  }
  const page = S.page || { name: 'Page', category: '' };
  say('📘 ' + (page.name || 'Page') + (page.category ? ' · ' + page.category : ''));
  say('Login otomatis via Page Access Token: OK (token ' + maskToken(S.token) + ')');
  say('Auto-reply: pesan Messenger ' + (S.config.autoMessages ? 'ON' : 'OFF')
    + ' · komentar ' + (S.config.autoComments ? 'ON' : 'OFF'));
  say('Bahasa balasan: ' + (S.config.language || 'ikuti bahasa pengirim')
    + ' · jeda antar balasan: ' + S.config.speed + ' (' + speedLabel(S.config.speed) + ')');
  say('Statistik: ' + S.stats.messages + ' balasan pesan · ' + S.stats.comments
    + ' balasan komentar · cek terakhir: ' + fmtTime(S.stats.lastCheck));
  say('Aktif sejak: ' + fmtTime(S.stats.startedAt));
  let qm = '?';
  let qc = '?';
  try { qm = String((await collectMessages(S)).length); } catch (e) { qm = '?'; }
  try { qc = String((await collectComments(S)).length); } catch (e) { qc = '?'; }
  say('Antrean: ' + qm + ' pesan belum dibalas · ' + qc + ' komentar baru');
}

async function checkCmd(S) {
  if (!S.token) {
    await emit('Belum ada Page Access Token di chat ini — isi form setup modul dulu ya.');
    return { ok: false, error: 'no token' };
  }
  if (S.authOk === false) {
    await emit('Token page ditolak Graph API: ' + clip(S.authError, 140));
    return { ok: false, error: 'auth' };
  }
  return runPass(S, Date.now() + CHECK_DEADLINE_MS);
}

async function autoCmd(S, argStr) {
  if (!S.token) {
    await emit('Belum ada Page Access Token di chat ini — isi form setup modul dulu ya.');
    return { ok: false, error: 'no token' };
  }
  if (S.authOk === false) {
    await emit('Token page ditolak Graph API: ' + clip(S.authError, 140));
    return { ok: false, error: 'auth' };
  }
  const n = parseInt(String(argStr || '').trim().split(/\s+/)[0], 10);
  const interval = (isNaN(n) ? 20 : Math.max(MIN_INTERVAL_S, Math.min(MAX_INTERVAL_S, n))) * 1000;
  const burstStart = Date.now();
  const cutoff = burstStart + BUDGET_MS - MARGIN_MS;
  await emit('👀 Pantau beruntun dimulai — pass tiap ' + (interval / 1000)
    + ' detik sampai budget run (~' + ((BUDGET_MS - MARGIN_MS) / 1000) + ' dtk) habis.');
  let passes = 0;
  let messages = 0;
  let comments = 0;
  while (Date.now() - burstStart < BUDGET_MS - MARGIN_MS) {
    const t0 = Date.now();
    const s = await runPass(S, cutoff);
    passes++;
    messages += s.messagesSent || 0;
    comments += s.commentsSent || 0;
    if (s.stoppedEarly || s.allOff) break;
    const passTook = Date.now() - t0;
    if (Date.now() - burstStart >= BUDGET_MS - MARGIN_MS) break;
    if (passTook < interval) {
      const wait = Math.min(interval - passTook, Math.max(0, cutoff - Date.now()));
      if (wait > 0) await sleep(wait);
    }
  }
  await emit('Burst selesai — jalankan /fb auto lagi untuk lanjut pantau.');
  await emit('📊 Total burst: ' + passes + ' pass · ' + messages + ' pesan · ' + comments + ' komentar dibalas.');
  return { ok: true, passes: passes, messages: messages, comments: comments };
}

async function templateCmd(S, say, argStr) {
  const arg = String(argStr || '').trim();
  if (!arg) {
    say('📝 Template balasan chat ini (placeholder {name} {page}):');
    for (const key of TEMPLATE_KEYS) {
      const vs = templateVariants(S.templates, key);
      say('  ' + key + ' (' + vs.length + ' varian) — contoh: ' + clip(vs[0] || '-', 66));
    }
    say('Lihat: /fb template <key> · Ubah: /fb template <key> A | B | C · Reset: /fb template reset');
    return;
  }
  if (arg === 'reset') {
    S.templates = defaultTemplates();
    await saveJson('templates', S.templates);
    say('♻️ Semua template dikembalikan ke bawaan (' + TEMPLATE_KEYS.length + ' key).');
    return;
  }
  const sp = arg.indexOf(' ');
  const key = (sp === -1 ? arg : arg.slice(0, sp)).toLowerCase();
  const rest = sp === -1 ? '' : arg.slice(sp + 1).trim();
  if (TEMPLATE_KEYS.indexOf(key) === -1) {
    say('❌ Key template tidak dikenal: ' + key);
    say('Key valid: ' + TEMPLATE_KEYS.join(', '));
    return;
  }
  if (!rest) {
    const vs = templateVariants(S.templates, key);
    say('📝 ' + key + ' — ' + vs.length + ' varian:');
    vs.forEach((v, i) => say('  ' + (i + 1) + '. ' + v));
    say('Ubah: /fb template ' + key + ' A | B | C (maks 4 varian, 300 karakter per varian)');
    return;
  }
  const parts = rest.split('|').map((s) => s.trim()).filter((s) => s.length > 0).map((s) => clip(s, 300));
  if (!parts.length) {
    say('❌ Varian kosong — tulis minimal satu. Contoh: /fb template thanks Makasih {name}, ditunggu kunjungan berikutnya ya.');
    return;
  }
  let note = '';
  if (parts.length > 4) {
    parts.length = 4;
    note = ' (hanya 4 varian pertama yang disimpan)';
  }
  S.templates[key] = parts;
  await saveJson('templates', S.templates);
  say('✅ Template "' + key + '" diperbarui — ' + parts.length + ' varian' + note + '.');
}

async function toggleCmd(S, say, keyword, argStr) {
  const ch = String(argStr || '').trim().toLowerCase();
  if (ch !== 'messages' && ch !== 'comments') {
    say('Pemakaian: /fb ' + keyword + ' messages|comments');
    return;
  }
  const on = keyword === 'on';
  if (ch === 'messages') S.config.autoMessages = on;
  else S.config.autoComments = on;
  await saveJson('config', S.config);
  say((on ? '✅ Auto-reply' : '⏸️ Auto-reply') + ' ' + (ch === 'messages' ? 'pesan Messenger' : 'komentar')
    + ': ' + (on ? 'ON' : 'OFF') + ' (disimpan untuk chat ini).');
}

async function speedCmd(S, say, argStr) {
  const v = String(argStr || '').trim().toLowerCase();
  if (!SPEEDS[v]) {
    say('Pemakaian: /fb speed fast|normal|slow');
    say('  fast 3-6 dtk · normal 6-15 dtk · slow 15-30 dtk (jeda antar balasan)');
    return;
  }
  S.config.speed = v;
  await saveJson('config', S.config);
  say('⚡ Jeda antar balasan: ' + v + ' (' + speedLabel(v) + ') — disimpan untuk chat ini.');
}

async function logoutCmd(S, say) {
  const hadToken = !!S.token;
  for (const key of ['token', 'page', 'seenMsg', 'seenCmt', 'sent', 'stats']) {
    await removeKey(key);
  }
  // hapus juga mirror form setup (cooperative key) agar form muncul lagi
  await removeKey('zagentsSetup');
  S.token = '';
  S.page = null;
  S.seenMsg = [];
  S.seenCmt = [];
  S.sent = [];
  S.stats = sanitizeStats(null);
  if (hadToken) {
    say('👋 Logout OK — token, identitas page, statistik, dan riwayat baca/balasan chat ini sudah dihapus.');
    say('Form setup akan diminta lagi pada aktivasi berikutnya.');
  } else {
    say('Belum ada token tersimpan — state lokal chat ini sudah dibersihkan.');
  }
}

function helpCmd(say) {
  say('📘 Facebook Page Assistant — perintah /fb:');
  say('  /fb                       status page, token (masked), config, statistik, antrean');
  say('  /fb check                 satu pass: poll pesan + komentar baru, lalu balas');
  say('  /fb auto [detik]          pantau beruntun tiap N detik (10-60, default 20) selama budget run');
  say('  /fb template              daftar template + jumlah varian + contoh');
  say('  /fb template <key>        lihat semua varian satu template');
  say('  /fb template <key> A | B  set varian (maks 4, 300 karakter per varian)');
  say('  /fb template reset        kembalikan semua template ke bawaan');
  say('  /fb on|off messages|comments   auto-reply per kanal (pesan / komentar)');
  say('  /fb speed fast|normal|slow     jeda antar balasan (3-6 / 6-15 / 15-30 detik)');
  say('  /fb logout                hapus token + riwayat chat ini');
  say('  /fb help                  bantuan ini');
  say('Template key: ' + TEMPLATE_KEYS.join(', '));
}

/* --------------------------------------------------------------- router */

function parseArgv() {
  const raw = String((zagents.info && zagents.info.prompt) || '').trim();
  return raw.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
}

function parseKeyword(argv) {
  const m = /^(\S+)(?:\s+([\s\S]*))?$/.exec(argv);
  if (!m) return { keyword: '', args: '' };
  return { keyword: m[1].toLowerCase(), args: m[2] ? m[2].trim() : '' };
}

async function run() {
  const S = await loadState();
  const parsed = parseKeyword(parseArgv());
  const cmd = parsed.keyword;

  // mirror setup form -> storage (tanpa network); true = token baru dipasang
  const fresh = await mirrorSetup(S);

  // validasi token: run pertama setelah setup, dan setiap perintah
  // yang butuh auth (status/check/auto)
  const needsAuth = cmd === '' || cmd === 'status' || cmd === 'check' || cmd === 'auto';
  if (S.token && (fresh || needsAuth || !S.page)) {
    await validateToken(S, fresh);
  }

  const out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };
  const result = { module: 'facebook-page', command: cmd || 'status' };

  if (cmd === '' || cmd === 'status') {
    await statusCmd(S, say);
  } else if (cmd === 'check') {
    result.summary = await checkCmd(S);
  } else if (cmd === 'auto') {
    result.burst = await autoCmd(S, parsed.args);
  } else if (cmd === 'template') {
    await templateCmd(S, say, parsed.args);
  } else if (cmd === 'on' || cmd === 'off') {
    await toggleCmd(S, say, cmd, parsed.args);
  } else if (cmd === 'speed') {
    await speedCmd(S, say, parsed.args);
  } else if (cmd === 'logout') {
    await logoutCmd(S, say);
  } else {
    helpCmd(say); // argumen tidak dikenal -> help
  }

  for (const line of out) await log(line);
  return result;
}

async function main() {
  try {
    return await run();
  } catch (e) {
    const msg = errMsg(e);
    try { await zagents.log('❌ facebook-page berhenti dengan kesalahan: ' + clip(msg, 200)); } catch (e2) { /* keep going */ }
    return { module: 'facebook-page', ok: false, error: msg };
  }
}

module.exports = main();
