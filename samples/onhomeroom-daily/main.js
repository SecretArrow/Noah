/* ============================================================================
 *  OnHomeroom Daily — ZAgents chat module (samples/onhomeroom-daily)
 *  ----------------------------------------------------------------------------
 *  Converted from the standalone onhomeroom-bot Node.js script. Works
 *  app.onhomeroom.com ONE paced cycle per activation:
 *    - challenge board (#leaderboard/challenges) is the priority
 *    - votes are ALWAYS yes
 *    - one chat reply, DM answers, app try-ins, proposal pipeline
 *
 *  Differences vs the standalone script (module sandbox):
 *    - config + state live in the per-chat storage (zagents.storage)
 *    - HTTP goes through zagents.http (manual session cookie, allowedHosts)
 *    - EVERY text is composed by the chat's own agent via
 *      zagents.agent.compose — the old heuristic Composer is GONE. No
 *      templates, no pools, no canned fragments — including the app
 *      ideas for build requests: the agent invents the whole concept
 *      (name + what it does) from the live context this module supplies.
 *      The host-side gate (one casual English sentence, no ! : ; — – ?,
 *      word cap, no repeats) regulates every output before it is sent.
 *    - even the go-ahead DM prompt is composed, when the site ships no
 *      button label for the decision card
 *    - one text submission per activation at most — human pacing is kept
 *      across activations via the persisted lastTextAt anchor
 *    - setup/status/reset commands ride on the activation prompt
 *      (zagents.info.prompt) when the module is staged on a new chat;
 *      the PRIMARY setup path is the app's per-chat setup form — the
 *      host collects config.account (email + password) BEFORE this
 *      module's first run and hands the values over as
 *      zagents.info.setup (also stored under the cooperative storage
 *      key 'zagentsSetup')
 *
 *  Zero npm dependencies. Requires the ZAgents module runtime.
 * ==========================================================================*/

'use strict';

const BASE = 'https://app.onhomeroom.com';

/* ------------------------------------------------------------------ utils */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rand = (lo, hi) => Math.floor(lo + Math.random() * (hi - lo + 1));
const nowIso = () => new Date().toISOString();
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const today = () => nowIso().slice(0, 10);

async function log(...parts) {
  try { await zagents.log(parts.join(' ')); } catch (e) { /* keep going */ }
}
async function emit(text) {
  try { await zagents.chat.emit(text); } catch (e) { /* keep going */ }
}

function deepFill(target, defaults) {
  for (const k of Object.keys(defaults)) {
    if (target[k] === undefined) target[k] = JSON.parse(JSON.stringify(defaults[k]));
    else if (typeof defaults[k] === 'object' && defaults[k] !== null && !Array.isArray(defaults[k])) {
      if (typeof target[k] !== 'object' || target[k] === null) target[k] = {};
      deepFill(target[k], defaults[k]);
    }
  }
  return target;
}

/* ------------------------------------------------------- config and state */
const DEFAULT_CONFIG = {
  account: { email: '', password: '' },
  pacing: {
    betweenCallPauseMs: [400, 1200], // tiny human-ish pause between API calls
    textGapSeconds: 60,              // min seconds between text submissions
    gapCapSeconds: 25,               // per-run cap so one gap cannot eat the budget
    dwellSecondsPerApp: 12,          // time spent per app inside ONE run
    activityPingSeconds: 6,          // heartbeat chunk size
    betweenAppsPauseMs: [3000, 6000],
  },
  tasks: {
    challenges: { enabled: true },
    vote:    { enabled: true, choice: 'yes', maxPerRun: 8, scanAllAppsOnStart: true },
    chat:    { enabled: true, channel: 'general', quietIfMineWithinMin: 10 },
    tryApps: { enabled: true, perCycle: 2, joinBeforeTry: true },
    propose: { enabled: true, once: false, maxRounds: 3, perDay: 1 },
    buildApp: { enabled: true, target: 'usernode-2d5619', restartAfterHours: 48 },
  },
  agent: {
    model: 'claude-sonnet-5',  // used when the site's builder implements a change
    pollSeconds: 20,
  },
};

const DEFAULT_DATA = {
  meta: { createdAt: null, updatedAt: null, version: 2 },
  session: { cookie: null, savedAt: null },
  user: null,
  joinedApps: [],
  votedSessions: [],
  triedApps: [],
  proposalsFiled: [],
  chatLog: [],
  challenges: [],
  challengeState: {},
  proposePipeline: null,
  buildPipeline: null,
  dmApproved: [],
  dmAnswered: [],
  feedbackSent: [],
  proposeAppsUsed: [],
  buildsRequested: [],
  lastInvalidReplaceDay: null,
  lastTextAt: null,
  recentTexts: [],
  stats: { runs: 0, votesCast: 0, messagesSent: 0, appsTried: 0, proposalsFiled: 0, feedbackSent: 0 },
  runs: [],
};

const MAX_LIST = {
  recentTexts: 60,
  chatLog: 40,
  votedSessions: 400,
  joinedApps: 400,
  triedApps: 400,
  proposalsFiled: 120,
  feedbackSent: 120,
  dmApproved: 400,
  dmAnswered: 400,
  proposeAppsUsed: 200,
  buildsRequested: 120,
  runs: 10,
};

function trimState(state) {
  for (const [key, cap] of Object.entries(MAX_LIST)) {
    if (Array.isArray(state[key])) state[key] = state[key].slice(0, cap);
  }
  // challengeState: keep only the 60 most recent ids by lastAt
  const entries = Object.entries(state.challengeState || {})
    .sort((a, b) => String(b[1].lastAt || '').localeCompare(String(a[1].lastAt || '')))
    .slice(0, 60);
  state.challengeState = Object.fromEntries(entries);
  return state;
}

async function loadJson(key, fallback) {
  try {
    const v = await zagents.storage.get(key);
    if (v && typeof v === 'object') return v;
  } catch (e) { log('storage read failed for', key, '-', e.message); }
  return JSON.parse(JSON.stringify(fallback));
}
async function saveJson(key, value) {
  try { await zagents.storage.set(key, value); }
  catch (e) { log('storage write failed for', key, '-', e.message); }
}

/* ------------------------------------------------------- host setup form */
/* The app collects the per-chat setup form (module.json "setup") BEFORE
   this module's first run and exposes the submitted values as
   zagents.info.setup (mirrored under the cooperative storage key
   'zagentsSetup'). We merge them into config.account so the credentials
   typed into the form are the ones this chat uses; after every successful
   account check we mirror config.account BACK into the same key so the
   host's gate always reflects reality (text-command setups included).     */
function accountReady(cfg) {
  return !!(cfg && cfg.account && cfg.account.email && cfg.account.password);
}

function sameAccount(a, b) {
  return !!a && !!b && a.email === b.email && a.password === b.password;
}

function readHostSetup() {
  try {
    const viaInfo = zagents.info && zagents.info.setup;
    if (viaInfo && typeof viaInfo === 'object') return viaInfo;
  } catch (e) { /* older host without info.setup */ }
  return null;
}

async function readStoredSetup() {
  try {
    const v = await zagents.storage.get('zagentsSetup');
    if (v && typeof v === 'object') return v;
  } catch (e) { /* cooperative key unreadable — treat as absent */ }
  return null;
}

async function mirrorSetup(config) {
  if (!accountReady(config)) return;
  const stored = await readStoredSetup();
  if (stored && sameAccount(stored, config.account)) return;
  await saveJson('zagentsSetup', {
    email: config.account.email,
    password: config.account.password,
  });
}

/* ------------------------------------------------------------------- API */
class Api {
  constructor(config, state) {
    this.config = config;
    this.cookie = state.session.cookie || null;
    this.user = state.user;
  }
  async breathe() {
    const [lo, hi] = this.config.pacing.betweenCallPauseMs || [400, 1200];
    await sleep(rand(lo, hi));
  }

  async call(method, urlPath, body, opts = {}) {
    const url = urlPath.startsWith('http') ? urlPath : BASE + urlPath;
    const headers = { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' };
    if (this.cookie && !opts.noAuth) headers['Cookie'] = this.cookie;

    let status = 0, json = null, text = '', resHeaders = {};
    for (let attempt = 1; attempt <= (opts.retries || 2); attempt++) {
      const res = await zagents.http.request(url, {
        method,
        headers,
        body: body === undefined ? null : JSON.stringify(body),
        timeoutMs: opts.timeoutMs || 20000,
        headOnly: opts.headOnly === true,
      });
      status = res.status;
      resHeaders = res.headers || {};
      if (opts.headOnly) { text = ''; break; }
      text = typeof res.body === 'string' ? res.body : JSON.stringify(res.body);
      try { json = text ? JSON.parse(text) : null; } catch (e) { json = null; }
      if (status > 0) break;
      await sleep(1200 * attempt);
    }

    if (status === 401 && !opts.noAuth && !opts._retried) {
      log('session expired — re-logging in');
      if (await this.login()) {
        opts._retried = true;
        return this.call(method, urlPath, body, opts);
      }
    }
    return { status, json, text, headers: resHeaders };
  }
  get(p, o) { return this.call('GET', p, undefined, o); }
  post(p, b, o) { return this.call('POST', p, b, o); }

  /* auth */
  async login() {
    const email = this.config.account.email;
    const password = this.config.account.password;
    const res = await zagents.http.request(BASE + '/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: email, password }),
      timeoutMs: 20000,
    });
    if (res.status !== 200) {
      log('login failed (HTTP ' + res.status + ') — check the saved credentials');
      return false;
    }
    const setCookie = (res.headers && res.headers['set-cookie']) || '';
    const m = setCookie.match(/session=([^;,\s]+)/);
    if (!m) { log('login response did not include a session cookie'); return false; }
    this.cookie = 'session=' + m[1];
    await this.breathe();
    const me = await this.get('/api/auth/me');
    if (me.status === 200 && me.json && me.json.user) {
      this.user = { id: me.json.user.id, username: me.json.user.username, role: me.json.user.role };
      log('signed in as ' + this.user.username);
      return true;
    }
    log('cookie set, but the /me lookup failed — continuing anyway');
    return true;
  }

  async ensureLoggedIn() {
    if (this.cookie) {
      const me = await this.get('/api/auth/me');
      if (me.status === 200 && me.json && me.json.user) {
        this.user = { id: me.json.user.id, username: me.json.user.username, role: me.json.user.role };
        log('session still valid — hello ' + this.user.username);
        return true;
      }
    }
    return this.login();
  }

  /* discovery */
  async listApps() {
    const res = await this.get('/api/apps');
    const apps = (res.json && (res.json.apps || res.json)) || [];
    await this.breathe();
    return Array.isArray(apps) ? apps : [];
  }
  async conversations() {
    const res = await this.get('/api/conversations');
    return (res.json && res.json.conversations) || [];
  }
  async challenges() {
    const ev = await this.get('/api/v4/season-events?include_past=0');
    await this.breathe();
    const events = (ev.json && ev.json.data) || [];
    let eventId = null;
    if (Array.isArray(events) && events.length) {
      const active = events.find((e) => e.is_current) || events[0];
      eventId = active && active.id;
    }
    if (!eventId) eventId = 10; // known Season 2 fallback
    const res = await this.get('/challenges-api/challenges?season_event_id=' + eventId);
    return (res.json && res.json.data) || [];
  }
  async promoted(appSlug) {
    const res = await this.get('/api/apps/' + appSlug + '/promoted');
    await this.breathe();
    return (res.json && res.json.promoted) || [];
  }

  /* homeroom bot DM — where requests, plans and approvals live */
  async botConversationId() {
    if (this._botConvId !== undefined) return this._botConvId;
    const convs = await this.conversations();
    const bot = convs.find((c) => c.homeroom_bot === true || c.homeroomBot === true
      || (c.title || '').toLowerCase().includes('homeroom bot'));
    this._botConvId = bot ? bot.id : null;
    return this._botConvId;
  }
  async dmCards() {
    const convId = await this.botConversationId();
    if (!convId) return [];
    const res = await this.get('/api/conversations/' + convId + '/messages?limit=50');
    const msgs = (res.json && res.json.messages) || [];
    await this.breathe();
    return msgs
      .map((m) => ({ id: m.id, content: m.content, hb: m.metadata && m.metadata.homeroomBot }))
      .filter((x) => x.hb && typeof x.hb === 'object');
  }
  async botAction(actionId, choice, answers) {
    const body = answers ? { choice, answers } : { choice };
    const res = await this.post('/api/conversations/homeroom-bot/actions/' + actionId, body);
    return res.status === 200 && res.json && res.json.ok ? (res.json.label || 'ok') : null;
  }
  async botPrompt(convId, content, replyToId, threadRootId) {
    const body = {
      content,
      idempotency_key: 'hb-' + Date.now() + '-' + Math.floor(Math.random() * 1e9),
    };
    if (replyToId) body.reply_to_id = replyToId;
    if (threadRootId) body.thread_root_id = threadRootId;
    const r = await this.post('/api/conversations/' + convId + '/messages', body);
    return (r.status === 200 || r.status === 201) && r.json && r.json.message ? r.json.message : null;
  }
  async sendDmNote(content) {
    const convId = await this.botConversationId();
    if (!convId) return null;
    return this.sendMessage(convId, content);
  }

  /* change / proposal flow */
  async listSessions(appSlug) {
    const res = await this.get('/api/apps/' + encodeURIComponent(appSlug) + '/sessions');
    return (res.json && res.json.sessions) || [];
  }
  async createSession(appSlug, issueNumber) {
    const body = Number.isInteger(issueNumber) && issueNumber > 0 ? { issueNumber } : {};
    const res = await this.post('/api/apps/' + encodeURIComponent(appSlug) + '/sessions', body);
    return (res.json && res.json.session) || null;
  }
  async sessionStatus(sessionId) {
    const res = await this.get('/api/sessions/' + sessionId + '/status');
    return res.json || null;
  }
  /* kick the site's builder agent. The endpoint answers with an SSE stream
     that stays open for the whole turn — headOnly returns as soon as the
     status line + headers arrive, so the module never waits for the build. */
  async kickSession(sessionId, message, model) {
    const res = await this.post('/api/sessions/' + sessionId + '/chat', { message, model },
      { headOnly: true, timeoutMs: 25000, retries: 1 });
    if (res.status === 429) { log('agent turn refused (rate limited)'); return false; }
    if (res.status === 200 || res.status === 201) return true;
    if (res.status > 0) { log('agent turn refused (HTTP ' + res.status + ')'); return false; }
    // Timed out before headers — verify through the status endpoint.
    const st = await this.sessionStatus(sessionId).catch(() => null);
    return !!(st && (st.busy || st.phase));
  }
  async sessionChecks(sessionId) {
    const res = await this.get('/api/sessions/' + sessionId + '/checks');
    return (res.json && res.json.session) || null;
  }
  async promoteSession(sessionId) {
    const res = await this.post('/api/sessions/' + sessionId + '/promote', {});
    return res.status === 200 || res.status === 201;
  }
  async archiveSession(sessionId) {
    const res = await this.post('/api/sessions/' + sessionId + '/archive', {});
    return res.status === 200 || res.status === 201;
  }

  /* feedback */
  async sendFeedback(appSlug, text) {
    const res = await this.post('/api/feedback', { description: text, target: 'app', appSlug });
    return (res.status === 200 || res.status === 201) ? (res.json || true) : null;
  }

  /* app try-in */
  async tryApp(slug, dwellSeconds, pingSeconds) {
    const tok = await this.get('/api/iframe-token?app=' + slug);
    if (tok.status !== 200 || !tok.json || !tok.json.token) {
      log('no iframe token for ' + slug);
      return false;
    }
    await this.breathe();
    // open the app frame once (registers the visit on the app server)
    try {
      await zagents.http.request('https://' + slug + '.onhomeroom.com/?token=' + tok.json.token,
        { method: 'GET', timeoutMs: 15000 });
    } catch (e) { /* app servers can be slow — not fatal */ }
    await this.breathe();
    // spend some time: heartbeat the same way the open tab does
    let sent = 0;
    while (sent < dwellSeconds) {
      const chunk = Math.min(pingSeconds, dwellSeconds - sent);
      const r = await this.post('/api/apps/' + slug + '/activity', { seconds: chunk });
      if (r.status !== 200 || !r.json || !r.json.ok) {
        log('activity ping rejected for ' + slug + ' (HTTP ' + r.status + ')');
        break;
      }
      sent += chunk;
      await sleep(rand(3000, 6000));
    }
    return sent > 0;
  }

  /* vote */
  async vote(sessionId, choice) {
    const r = await this.post('/api/sessions/' + sessionId + '/vote', { vote: choice });
    return r.status === 200 && r.json && r.json.ok;
  }

  /* chat in channel */
  async channelMessages(convId, limit = 12) {
    const r = await this.get('/api/conversations/' + convId + '/messages?limit=' + limit);
    return (r.json && r.json.messages) || [];
  }
  async sendMessage(convId, content) {
    const r = await this.post('/api/conversations/' + convId + '/messages', { content });
    return (r.status === 200 || r.status === 201) && r.json && r.json.message ? r.json.message : null;
  }

  /* proposals */
  async fileIssue(slug, title, body) {
    const r = await this.post('/api/apps/' + slug + '/issues', { title, description: body });
    const ok = r.status === 200 || r.status === 201;
    return ok && r.json && r.json.issue ? r.json.issue : null;
  }
}

/* ============================================================
 *  COMPOSER — every sentence comes from the chat's own agent
 *  ============================================================
 *  The standalone bot assembled texts from hand-written fragment
 *  tables. That whole system is replaced: the module now DESCRIBES
 *  the live situation to the chat agent (zagents.agent.compose)
 *  and the agent generates the sentence at the moment it is needed.
 *  A light local gate re-checks the host-regulated output so a
 *  broken integration can never put malformed text on the site.
 */
const Composer = {
  FORBIDDEN: /[!?:;—–]/,
  EMOJI: /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{2B00}-\u{2BFF}]/u,

  sanitize(text, maxWords) {
    let t = String(text || '').trim().replace(/\s+/g, ' ');
    for (const q of ['"', "'", '`']) {
      if (t.length >= 2 && t.startsWith(q) && t.endsWith(q)) t = t.slice(1, -1).trim();
    }
    t = t.replace(this.EMOJI, ' ');
    t = t.replace(/[:;—–]/g, ',').replace(/[!?]/g, '');
    const ends = t.endsWith('.');
    let body = ends ? t.slice(0, -1) : t;
    body = body.replace(/\./g, ' ').replace(/\s+/g, ' ').trim();
    t = body + (ends ? '.' : '');
    const words = t.split(/\s+/).filter(Boolean);
    if (words.length > maxWords) t = words.slice(0, maxWords).join(' ');
    return t.trim().replace(/^[,.\s]+/, '');
  },

  /* last local gate — the host already enforces the same contract */
  validate(text, maxWords, allowPeriod) {
    const t = this.sanitize(text, maxWords);
    if (!t) return null;
    const body = allowPeriod && t.endsWith('.') ? t.slice(0, -1) : t;
    if (/[.!?;]/.test(body)) return null;
    if (this.FORBIDDEN.test(t)) return null;
    return t;
  },

  async compose(opts) {
    const { text } = await zagents.agent.compose({
      task: opts.task,
      context: opts.context,
      instruction: opts.instruction || '',
      maxWords: opts.maxWords || 24,
      avoid: (opts.avoid || []).slice(0, 20),
      trailingPeriod: opts.trailingPeriod === true,
    });
    const out = this.validate(text, opts.maxWords || 24, opts.trailingPeriod === true);
    if (!out) throw new Error('composer output failed the local gate');
    return out;
  },

  appRef(app) {
    const raw = app && (app.name || app.title);
    let ref = raw
      ? String(raw).replace(this.EMOJI, ' ').replace(this.FORBIDDEN, ' ').replace(/\./g, ' ')
      : String((app && app.slug) || '').replace(/-[0-9a-f]{4,}$/i, '').replace(/-/g, ' ');
    ref = ref.replace(/\s+/g, ' ').trim();
    return ref || 'this app';
  },

  /* chat reply — the agent sees the actual recent lines */
  async chatReply(ctx) {
    const lines = (ctx.messages || [])
      .filter((m) => m.sender && m.sender.username !== ctx.myUsername && !m.deleted)
      .slice(-5)
      .map((m) => (m.sender ? m.sender.username + ': ' : '') + String(m.content || '').slice(0, 140))
      .join('\n');
    return this.compose({
      task: 'chat-reply',
      context: 'Recent messages in the #general channel of an educational app community:\n'
        + (lines || '(the channel is quiet right now)'),
      instruction: 'Reply like a normal member hanging out, one short casual sentence that fits '
        + 'the last message. Stay quiet-friendly, no greeting formulas, never sound like an assistant.',
      maxWords: 14,
      avoid: ctx.recent,
    });
  },

  /* feedback — one small concrete observation about the app */
  async feedback(app, recent) {
    return this.compose({
      task: 'feedback',
      context: 'App name: ' + this.appRef(app)
        + '\nApp slug: ' + (app.slug || '')
        + '\nDescription: ' + String(app.description || app.tagline || 'n/a').slice(0, 200),
      instruction: 'Write one short useful feedback note a real user would leave after a quick visit, '
        + 'mentioning one small concrete thing (a button, a flow, a screen). One casual sentence.',
      maxWords: 18,
      avoid: recent,
    });
  },

  /* proposal — short title + one-sentence body, two agent calls */
  async proposalIdea(app, usedTitles) {
    const ref = this.appRef(app);
    const title = await this.compose({
      task: 'proposal-title',
      context: 'App name: ' + ref + '\nSlug: ' + (app.slug || '')
        + '\nDescription: ' + String(app.description || app.tagline || 'n/a').slice(0, 200)
        + '\nTitles already used for this app or others: ' + (usedTitles || []).slice(0, 10).join(' | '),
      instruction: 'Propose a short plain change title for this app, max 8 words, like a small feature '
        + 'a regular user would actually suggest. Never reuse a listed title. No ending period.',
      maxWords: 8,
      avoid: usedTitles,
    });
    const body = await this.compose({
      task: 'proposal-body',
      context: 'App name: ' + ref + '\nChosen change: ' + title,
      instruction: 'Write the proposal body as one simple everyday sentence a member would type under '
        + 'that title, casual but clear. End the sentence with a single period.',
      maxWords: 24,
      avoid: [...(usedTitles || []), title],
      trailingPeriod: true,
    });
    return { title, body };
  },

  /* new app request for the community builder — the whole concept is
     invented live by the agent, exactly like every other sentence:
     the agent dreams up a fresh app name, describes what it does, then
     wraps both in the request title. Nothing is pre-written here. */
  async buildAppIdea(usedTitles) {
    const stored = (usedTitles || []).map((t) => String(t));
    // stored titles look like "Create a new app called X" — derive the
    // bare names so the agent (and the avoid list) sees what was asked
    const bareNames = stored
      .map((t) => t.replace(/^create a new app( called)?:?\s*/i, '').replace(/^[:\s]+/, '').trim())
      .filter(Boolean);
    const seen = [...new Set([...stored, ...bareNames])];
    const listed = seen.length ? seen.slice(0, 10).join(' | ') : '(none yet)';

    // step 1 — the agent invents the app itself
    const name = await this.compose({
      task: 'build-request-concept',
      context: 'This is an educational community where members request small apps to build. '
        + 'App ideas already requested: ' + listed,
      instruction: 'Invent ONE fresh simple app concept a student community would actually use. '
        + 'Reply with the app name only — two to four plain words, no description, no ending period. '
        + 'It must be genuinely different from every idea already listed.',
      maxWords: 6,
      avoid: seen,
    });

    // step 2 — the agent describes what the invented app does
    const body = await this.compose({
      task: 'build-request-body',
      context: 'App name: ' + name
        + '\nCommunity: an educational app community. Ideas already requested: ' + listed,
      instruction: 'Write the request body as one simple sentence describing what this app does, '
        + 'the way a member asking for it would put it. End with a single period.',
      maxWords: 24,
      avoid: seen.concat(name),
      trailingPeriod: true,
    });

    // step 3 — the agent wraps both in the request title
    const title = await this.compose({
      task: 'build-request-title',
      context: 'Community app ideas already requested: ' + listed
        + '\nChosen concept: ' + name + ' — ' + body,
      instruction: 'Write the request title as: Create a new app called <name>. Max 8 words, no ending period.',
      maxWords: 8,
      avoid: seen,
    });
    return { title, body };
  },

  /* DM answers — the agent reads the actual question card */
  async dmReply(question, recent, appName) {
    return this.compose({
      task: 'dm-reply',
      context: 'The homeroom bot asked in a DM about "' + (appName || 'a request') + '":\n'
        + String(question || '').slice(0, 300),
      instruction: 'Answer like an easygoing member, one short casual sentence that actually responds to '
        + 'what is being asked. No strong preferences, no promises about timelines.',
      maxWords: 14,
      avoid: recent,
    });
  },

  /* friendly nudge about a stalled request */
  async nudge(title, recent) {
    const t = String(title || '')
      .replace(/^create a new app( called)?:?\s*/i, '')
      .replace(/^[:\s]+/, '')
      .trim() || 'the app';
    return this.compose({
      task: 'nudge',
      context: 'A community app request titled "' + t + '" has not moved for about two days.',
      instruction: 'Write one polite one-sentence check-in a member would send to the builder. No pressure.',
      maxWords: 14,
      avoid: recent,
    });
  },

  /* green-light for a decision card when the site ships no button
     label — same rule as everywhere else: the agent says it, and if
     the composer is down the card waits for the next activation */
  async goAhead(title, recent) {
    return this.compose({
      task: 'go-ahead',
      context: 'A community app request titled "' + (title || 'a new app')
        + '" needs our green-light so the builder can start working on it.',
      instruction: 'Write one short casual sentence giving the go-ahead, the way a member would '
        + 'confirm the button. No pressure, no promises about timing.',
      maxWords: 10,
      avoid: recent,
    });
  },
};

/* ------------------------------------------------------------------- BOT */
class Bot {
  constructor(config, state, deadline) {
    this.config = config;
    this.state = state;
    this.deadline = deadline;   // epoch ms — one activation's time budget
    this.api = new Api(config, state);
    this.apps = [];
    this.summary = { tasks: 0, votes: 0, chats: 0, apps: 0, proposals: 0, feedback: 0, errors: 0 };
  }

  get outOfTime() { return Date.now() > this.deadline; }

  async save() {
    trimState(this.state);
    this.state.meta.updatedAt = nowIso();
    await saveJson('data', this.state);
  }

  /* ---- text pacing — at least one minute between text submissions,
          kept across activations through the persisted anchor.
          Voting actions are exempt (house rule). -------------------- */
  async textGap(label) {
    const gapS = Math.max(10, this.config.pacing.textGapSeconds || 60);
    const capS = Math.max(0, this.config.pacing.gapCapSeconds || 0);
    const last = this.state.lastTextAt ? new Date(this.state.lastTextAt).getTime() : 0;
    let waitS = Math.ceil((last + gapS * 1000 - Date.now()) / 1000);
    if (waitS <= 0) return true;
    if (capS > 0) waitS = Math.min(waitS, capS);
    // never wait past the run deadline (leave a 3s margin)
    const budgetLeftMs = this.deadline - Date.now() - 3000;
    if (waitS * 1000 > budgetLeftMs) {
      log(label, '- text pacing window does not fit this run, skipped (next activation continues)');
      return false;
    }
    log(label, '- text pacing, waiting', waitS + 's');
    await sleep(waitS * 1000);
    return !this.outOfTime;
  }

  rememberText(text) {
    this.state.lastTextAt = nowIso();
    const list = this.state.recentTexts || (this.state.recentTexts = []);
    list.unshift(text);
    this.state.recentTexts = list.slice(0, MAX_LIST.recentTexts);
  }

  /* --------------------------------------------------------- context sync */
  snapshotChallenges(challenges) {
    const before = this.state.challenges || [];
    this.challengeBoard = challenges;
    this.state.challenges = challenges.slice(0, 40).map((c) => ({
      id: c.id,
      goal: c.goal,
      task: c.task || '',
      current: c.progress && c.progress.current,
      target: c.progress && c.progress.target,
      done: !!(c.progress && c.progress.done) || !!c.completed,
      reward: c.reward,
      at: nowIso(),
    }));
    for (const now of this.state.challenges) {
      const was = before.find((b) => b.id === now.id);
      if (was && !was.done && now.done) {
        emit('challenge complete — ' + now.goal + ' (' + now.reward + ')');
      }
    }
  }

  printChallengeBoard() {
    const list = this.state.challenges || [];
    if (!list.length) { log('CHAL: no challenges visible right now'); return; }
    for (const c of list) {
      const cur = c.current != null ? (c.current + '/' + (c.target != null ? c.target : '')) : (c.done ? 'done' : 'open');
      emit((c.done ? 'done — ' : 'open — ') + c.goal + ' (' + cur + ') ' + (c.reward || ''));
    }
  }

  async syncContext() {
    log('SYNC: refreshing apps, challenge board and conversations');
    this.apps = await this.api.listApps();
    const challenges = await this.api.challenges().catch(() => []);
    this.snapshotChallenges(challenges);
    const convs = await this.api.conversations();
    const chan = this.config.tasks.chat.channel || 'general';
    this.generalConv = convs.find((c) => c.channelKey === chan || c.title === chan) || null;
    log('SYNC: ' + this.apps.length + ' apps, ' + challenges.length + ' challenges, '
      + (this.generalConv ? '#' + chan + ' found' : '#' + chan + ' not found'));
    this.printChallengeBoard();
  }

  /* -------------------------------------------------------------- planner */
  planFor(challenge) {
    const text = (challenge.goal + ' ' + (challenge.task || '')).toLowerCase();
    // things only a real human can do — reported honestly, never acted
    if (/invite|refer|referral|\bfriends?\b|share.*link/.test(text)) return 'manual';
    if (/connect\b.*(\bx\b|twitter|github)|\bgithub\b/.test(text)) return 'manual';
    if (/feedback|report|bug|suggest/.test(text)) return 'feedback';
    if (/build|create/.test(text) && /(community|app)/.test(text)) return 'buildApp';
    if (/try/.test(text) && /app/.test(text)) return 'tryApps';
    if (/\buse\b|spend|minutes/.test(text) && /app/.test(text)) return 'tryApps';
    if (/propose|proposal/.test(text) && /change|vote|accept|merge/.test(text)) return 'propose';
    if (/vote/.test(text)) return 'vote';
    if (/\bjoin\b/.test(text)) return 'join';
    if (/message|chat|discuss|comment|say hello|introduce/.test(text)) return 'chat';
    return null; // unknown — reported, not acted
  }

  async runCycle() {
    await this.taskChallenges();
    if (this.outOfTime) return;
    await this.answerBotQuestions();
    if (this.outOfTime) return;
    await this.taskDecisions();
    if (this.outOfTime) return;
    await this.taskVotes();
    if (this.outOfTime) return;
    await this.taskChat();
    if (this.outOfTime) return;
    await this.taskTryApps();
    if (this.outOfTime) return;
    await this.taskPropose();
  }

  /* ---- the challenge board — work everything listed there */
  async taskChallenges() {
    const cfg = this.config.tasks.challenges;
    if (!cfg || cfg.enabled === false) return;
    const open = (this.state.challenges || []).filter((c) => !c.done);
    if (!open.length) { log('CHAL: challenge board all caught up'); return; }

    for (const ch of open) {
      if (this.outOfTime) break;
      const plan = this.planFor(ch);
      const st = this.state.challengeState[ch.id]
        || (this.state.challengeState[ch.id] = { attempts: 0, lastAction: null, lastAt: null });

      if (!plan || plan === 'manual') {
        if (st.lastAction !== 'manual-hint') {
          const why = plan === 'manual'
            ? 'needs a real human (invites / external accounts) — reported, never acted'
            : 'no safe automation known — ' + (ch.task || 'no hint available');
          log('CHAL: "' + ch.goal + '" — ' + why);
          st.lastAction = 'manual-hint';
          st.lastAt = nowIso();
          await this.save();
        }
        continue;
      }

      st.attempts += 1;
      st.lastAction = plan;
      st.lastAt = nowIso();
      await this.save();

      if (plan === 'buildApp') await this.challengeBuildApp(ch);
      else if (plan === 'tryApps') await this.challengeTryApps(ch);
      else if (plan === 'propose') await this.challengePropose(ch);
      else if (plan === 'feedback') await this.challengeFeedback(ch);
      else if (plan === 'join') await this.challengeJoin(ch);
      else if (plan === 'vote') await this.taskVotes();
      else if (plan === 'chat') await this.taskChat();
      if (this.outOfTime) break;
    }

    // re-check the board so progress numbers stay honest
    const fresh = await this.api.challenges().catch(() => []);
    if (fresh.length) this.snapshotChallenges(fresh);
  }

  async joinApp(slug) {
    if (this.state.joinedApps.includes(slug)) return true;
    const r = await this.api.post('/api/apps/' + slug + '/membership', { joined: true }).catch(() => null);
    const ok = r && r.status === 200 && r.json && r.json.ok;
    if (ok) {
      this.state.joinedApps.push(slug);
      log('APP: joined ' + slug);
      await this.save();
    }
    return ok;
  }

  async challengeJoin(ch) {
    const joined = new Set(this.state.joinedApps);
    const cand = this.apps.filter((a) => a.status === 'running' && !joined.has(a.slug));
    if (!cand.length) { log('CHAL: already a member everywhere — nothing left to join'); return; }
    const app = pick(cand);
    emit('for "' + ch.goal + '" — joining ' + (app.name || app.slug));
    await this.joinApp(app.slug);
  }

  async challengeTryApps(ch) {
    const need = ch.target != null && ch.current != null ? Math.max(0, ch.target - ch.current) : 1;
    if (need === 0) return;
    const tried = new Set(this.state.triedApps);
    const candidates = this.apps.filter((a) =>
      a.status === 'running' && !tried.has(a.slug) && a.slug !== 'usernode-2d5619');
    if (!candidates.length) { log('CHAL: no fresh apps left to try for "' + ch.goal + '"'); return; }
    const n = Math.min(need, candidates.length, 2);
    for (let i = 0; i < n; i++) {
      if (this.outOfTime) break;
      const app = candidates.splice(Math.floor(Math.random() * candidates.length), 1)[0];
      await this.joinApp(app.slug);
      emit('for "' + ch.goal + '" — opening ' + (app.name || app.slug));
      const ok = await this.api.tryApp(
        app.slug,
        this.config.pacing.dwellSecondsPerApp,
        this.config.pacing.activityPingSeconds,
      ).catch(() => false);
      if (ok && !this.state.triedApps.includes(app.slug)) {
        this.state.triedApps.push(app.slug);
        this.state.stats.appsTried += 1;
        this.summary.apps += 1;
        emit('spent time in ' + app.slug + ' (' + (i + 1) + '/' + n + ' for this challenge)');
        await this.save();
      }
      if (i < n - 1) await sleep(rand(...this.config.pacing.betweenAppsPauseMs));
    }
  }

  /* feedback — short, specific notes on real apps */
  async challengeFeedback(ch) {
    const need = ch.target != null && ch.current != null ? Math.max(0, ch.target - ch.current) : 1;
    if (need === 0) return;
    const sent = this.state.feedbackSent || (this.state.feedbackSent = []);
    const candidates = this.apps.filter((a) => a.status === 'running'
      && a.slug !== 'usernode-2d5619' && !sent.some((f) => f.app === a.slug));
    if (!candidates.length) { log('CHAL: feedback already sent to every running app'); return; }
    const app = pick(candidates);
    const recentAll = [...(this.state.recentTexts || []), ...sent.map((f) => f.text)];
    let text;
    try { text = await Composer.feedback(app, recentAll); }
    catch (e) { log('CHAL: composer unavailable, feedback skipped — ' + e.message); return; }
    if (!(await this.textGap('feedback'))) return;
    const r = await this.api.sendFeedback(app.slug, text).catch(() => null);
    if (r) {
      sent.push({ app: app.slug, text, at: nowIso() });
      this.state.stats.feedbackSent += 1;
      this.summary.feedback += 1;
      this.rememberText(text);
      await this.save();
      emit('feedback noted on ' + app.slug + ' — "' + text + '"');
    } else {
      log('feedback on ' + app.slug + ' did not go through');
    }
  }

  /* "propose an app change / send it to the vote" — full pipeline,
     split across activations because the builder needs time */
  async challengePropose(ch) {
    let p = this.state.proposePipeline;
    const maxRounds = this.config.tasks.propose.maxRounds || 3;
    const perDay = this.config.tasks.propose.perDay || 1;

    if (p && p.done) {
      const replacingInvalid = !!p.invalidated;
      if ((p.round || 1) >= maxRounds && !replacingInvalid) {
        log('PROPOSE: ' + (p.round || 1) + ' proposal(s) up for the vote already — they need community yes votes');
        return;
      }
      const filedToday = this.state.proposalsFiled
        .filter((f) => String(f.at || '').slice(0, 10) === today()).length;
      const lastReplaceDay = this.state.lastInvalidReplaceDay;
      if (filedToday >= perDay && !(replacingInvalid && lastReplaceDay !== today())) {
        log('PROPOSE: next proposal comes tomorrow — keeping it human-paced');
        return;
      }
      if (replacingInvalid) this.state.lastInvalidReplaceDay = today();
      const nextRound = (p.round || 1) + (replacingInvalid ? 0 : 1);
      this.state.proposePipeline = null;
      p = null;
      this._nextPipelineRound = nextRound;
    }

    if (!p) {
      const filedTitles = this.state.proposalsFiled.map((f) => f.title);
      const usedApps = new Set(this.state.proposeAppsUsed);
      const runningApps = this.apps.filter((a) => a.status === 'running' && a.slug !== 'usernode-2d5619');
      let slug = runningApps.map((a) => a.slug).filter((s) => !usedApps.has(s))[0];
      if (!slug) slug = (runningApps[0] || {}).slug;
      if (!slug) return;
      const appCtx = this.apps.find((a) => a.slug === slug) || { slug };
      let idea;
      try { idea = await Composer.proposalIdea(appCtx, filedTitles); }
      catch (e) { log('PROPOSE: composer unavailable — ' + e.message); return; }
      p = this.state.proposePipeline = {
        app: slug, idea, step: 'issue', round: this._nextPipelineRound || 1, at: nowIso(),
      };
      this._nextPipelineRound = null;
      if (!this.state.proposeAppsUsed.includes(slug)) this.state.proposeAppsUsed.push(slug);
      await this.save();
    }

    emit('PROPOSE: working "' + ch.goal + '" on ' + p.app);

    // step 1 — the issue describing one clear change
    if (!p.issueNumber) {
      const issue = await this.api.fileIssue(p.app, p.idea.title, p.idea.body).catch(() => null);
      if (!issue) {
        p.fileFailures = (p.fileFailures || 0) + 1;
        await this.save();
        if (p.fileFailures >= 2) {
          log('PROPOSE: ' + p.app + ' keeps refusing new issues — rotating to another app next activation');
          p.done = true;
          p.invalidated = true;
          p.invalidatedAt = nowIso();
          await this.save();
        } else {
          log('could not file the proposal issue yet — retry next activation');
        }
        return;
      }
      p.issueNumber = issue.github_issue_number || issue.number || issue.id;
      p.issueId = issue.id;
      this.state.proposalsFiled.push({
        app: p.app, issueId: issue.id, issueNumber: p.issueNumber,
        title: p.idea.title, at: nowIso(),
      });
      this.state.stats.proposalsFiled += 1;
      this.summary.proposals += 1;
      await this.save();
      emit('filed issue #' + p.issueNumber + ' on ' + p.app + ' — "' + p.idea.title + '"');
      this.rememberText(p.idea.title);
      await this.api.breathe();
    }

    // step 2 — the homeroom bot reviews the issue in the DM
    const cards = await this.api.dmCards().catch(() => []);
    const mine = cards.filter((x) => x.hb && (x.hb.issueNumber === p.issueNumber
      || String(x.hb.issueTitle || '').toLowerCase() === p.idea.title.toLowerCase()));

    const person = mine.find((x) => x.hb.kind === 'person' && x.hb.status === 'open');
    if (person && person.hb.said === 'done') {
      log('PROPOSE: the bot says "' + p.idea.title + '" already exists — filing a different idea next activation');
      p.done = true;
      p.invalidated = true;
      p.invalidatedAt = nowIso();
      await this.save();
      return;
    }
    if (person && person.hb.said === 'decide') {
      log('PROPOSE: waiting on our go-ahead in the DM — the decision task answers it');
      return;
    }

    // step 3 — proposal card back from the builder: up for the vote now
    const prop = mine.find((x) => x.hb.kind === 'proposal');
    if (prop) {
      const appr = (prop.hb.actions || []).find((a) => a.id === 'approve' && a.sessionId);
      if (appr && !this.state.dmApproved.includes(appr.sessionId)) {
        const v = await this.api.vote(appr.sessionId, 'yes').catch(() => null);
        if (v) {
          this.state.dmApproved.push(appr.sessionId);
          emit('voted YES on our own change — "' + p.idea.title + '"');
        }
      }
      p.done = true;
      p.sessionId = (appr && appr.sessionId) || prop.hb.link || null;
      p.promotedAt = nowIso();
      await this.save();
      emit('the change is up for the vote — issue #' + p.issueNumber + ', round ' + (p.round || 1));
      return;
    }

    if (mine.some((x) => x.hb.kind === 'activity')) {
      log('AGENT: the builder picked it up — checks continue next activation');
      return;
    }
    log('AGENT: waiting for the homeroom bot to review issue #' + p.issueNumber);
  }

  /* "build for your community" — ask the community builder for a new app */
  async challengeBuildApp(ch) {
    let p = this.state.buildPipeline;
    if (p && p.done) { log('BUILD: new app is already up — waiting on the platform'); return; }
    const cfgB = this.config.tasks.buildApp || {};
    if (cfgB.enabled === false) return;
    const target = cfgB.target || 'usernode-2d5619';
    if (!this.apps.some((a) => a.slug === target)) {
      log('BUILD: community builder app not found — retry next activation');
      return;
    }
    if (!p) {
      const usedTitles = this.state.buildsRequested.map((b) => b.title);
      let idea;
      try { idea = await Composer.buildAppIdea(usedTitles); }
      catch (e) { log('BUILD: composer unavailable — ' + e.message); return; }
      this.state.buildsRequested.push({ title: idea.title, at: nowIso() });
      p = this.state.buildPipeline = { app: target, idea, at: nowIso() };
      await this.save();
    }
    emit('BUILD: working "' + ch.goal + '" on ' + target);

    // stale-build recovery
    const restartH = cfgB.restartAfterHours || 48;
    const anchor = p.planApprovedAt || p.at;
    const staleH = (Date.now() - new Date(anchor).getTime()) / 3600000;
    if (!p.done && staleH > restartH && (p.restartCount || 0) < 2) {
      const usedTitles = [...this.state.buildsRequested.map((b) => b.title), p.idea.title];
      let next = null;
      try { next = await Composer.buildAppIdea(usedTitles); } catch (e) { next = null; }
      if (next) {
        emit('no movement for ~2 days — filing a fresh request ("' + next.title + '") instead');
        this.state.buildsRequested.push({ title: next.title, at: nowIso() });
        this.state.buildPipeline = {
          app: target, idea: next, restartCount: (p.restartCount || 0) + 1, at: nowIso(),
        };
        await this.save();
        return;
      }
      if (!p.nudgedAt) {
        let msg = null;
        try { msg = await Composer.nudge(p.idea.title, this.state.recentTexts); } catch (e) { msg = null; }
        if (msg && (await this.textGap('build nudge'))) {
          const sentNudge = await this.api.sendDmNote(msg).catch(() => null);
          if (sentNudge) this.rememberText(msg);
        }
        p.nudgedAt = nowIso();
        await this.save();
        log('BUILD: sent a friendly nudge about the stalled request');
      }
    }

    // step 1 — the request describing the app to build
    if (!p.issueNumber) {
      const issue = await this.api.fileIssue(target, p.idea.title, p.idea.body).catch(() => null);
      if (!issue) { log('BUILD: could not file the app request yet — retry next activation'); return; }
      p.issueNumber = issue.github_issue_number || issue.number || issue.id;
      p.issueId = issue.id;
      this.state.proposalsFiled.push({
        app: target, issueId: issue.id, issueNumber: p.issueNumber,
        title: p.idea.title, at: nowIso(),
      });
      await this.save();
      emit('filed request #' + p.issueNumber + ' — "' + p.idea.title + '"');
      await this.api.breathe();
    }

    // step 2 — the homeroom bot reviews the request in the DM
    const cards = await this.api.dmCards().catch(() => []);
    const mine = cards.filter((x) => x.hb && (x.hb.issueNumber === p.issueNumber
      || String(x.hb.issueTitle || '').toLowerCase() === p.idea.title.toLowerCase()));

    const decide = mine.find((x) => x.hb.kind === 'person' && x.hb.status === 'open');
    if (decide && decide.hb.said === 'decide') {
      log('BUILD: waiting on our green-light in the DM — the decision task answers it');
      return;
    }
    const plan = mine.find((x) => x.hb.kind === 'plan' && x.hb.status === 'open' && x.hb.actionId);
    if (plan) {
      const label = await this.api.botAction(plan.hb.actionId, 'build').catch(() => null);
      if (!label) { log('BUILD: plan approval did not go through — retry next activation'); return; }
      p.planApprovedAt = nowIso();
      await this.save();
      log('AGENT: plan approved — the builder is building the new app');
      return;
    }

    // step 3 — when the first version is up, approve it like a member would
    const proposal = mine.find((x) => x.hb.kind === 'proposal');
    if (proposal) {
      const appr = (proposal.hb.actions || []).find((a) => a.id === 'approve' && a.sessionId);
      if (appr && !this.state.dmApproved.includes(appr.sessionId)) {
        const v = await this.api.vote(appr.sessionId, 'yes').catch(() => null);
        if (v) this.state.dmApproved.push(appr.sessionId);
      }
      if (appr && this.state.dmApproved.includes(appr.sessionId)) {
        p.done = true;
        p.approvedAt = nowIso();
        await this.save();
        emit('first version approved — it goes live when the group agrees');
        return;
      }
      log('BUILD: built and waiting on the group approval — nothing for us to click');
      return;
    }

    if (mine.some((x) => x.hb.kind === 'person' || x.hb.kind === 'plan' || x.hb.kind === 'activity')) {
      log('AGENT: the builder is on it — checks continue next activation');
      return;
    }
    log('BUILD: no card from the bot yet — retry next activation');
  }

  /* open questions from the homeroom bot block builds — the agent answers */
  async answerBotQuestions() {
    const cards = await this.api.dmCards().catch(() => []);
    const q = cards.find((x) => x.hb.kind === 'question' && x.hb.status === 'open'
      && !this.state.dmAnswered.includes(x.id));
    if (!q) return;
    let text = null;
    try {
      text = await Composer.dmReply(q.content || (q.hb && q.hb.issueTitle) || '',
        this.state.recentTexts, q.hb.appName);
    } catch (e) { text = null; }
    if (!text) {
      this.state.dmAnswered.push(q.id);
      log('CHAT: bot asked a question — no answer composed, needs a human');
      await this.save();
      return;
    }
    if (!(await this.textGap('dm reply'))) return;
    const ok = await this.api.sendDmNote(text).catch(() => null);
    if (ok) {
      this.state.dmAnswered.push(q.id);
      this.rememberText(text);
      await this.save();
      emit('answered the bot question on ' + (q.hb.appName || 'a request') + ' — "' + text + '"');
    } else {
      log('could not answer the bot question yet — retry next activation');
    }
  }

  /* person-decision cards + proposal approvals in the homeroom bot DM */
  async taskDecisions() {
    const cards = await this.api.dmCards().catch(() => []);
    let acted = false;
    for (const x of cards) {
      if (this.outOfTime) break;
      const hb = x.hb || {};
      if (hb.status !== 'open' || !Array.isArray(hb.actions) || !hb.actions.length) continue;
      if (this.state.dmAnswered.includes(x.id)) continue;
      const ids = hb.actions.map((a) => a.id);

      // green-light a new community app
      if (hb.said === 'decide' && ids.includes('go_ahead')) {
        const act = hb.actions.find((a) => a.id === 'go_ahead');
        let label = null;
        if (act && act.type === 'prompt') {
          const convId = await this.api.botConversationId();
          // the site normally ships the button label to send; when it
          // does not, the agent composes the go-ahead — never canned text
          let content = act.label;
          if (!content) {
            try {
              content = await Composer.goAhead(hb.requestTitle || hb.issueTitle || '', this.state.recentTexts);
            } catch (e) { content = null; }
          }
          if (!content) {
            log('BUILD: no button label and composer unavailable — the green-light waits for the next activation');
            continue;
          }
          label = await this.api.botPrompt(convId, content, x.id, hb.threadRootId || x.id).catch(() => null);
        } else {
          label = await this.api.botAction((act && act.id) || hb.actionId, 'go_ahead').catch(() => null);
        }
        if (label) {
          this.state.dmAnswered.push(x.id);
          emit('green-lit "' + (hb.requestTitle || hb.issueTitle || 'the request') + '" — the builder is on it');
          acted = true;
        } else {
          log('BUILD: could not answer the go_ahead card — retry next activation');
        }
        await this.api.breathe();
        continue;
      }

      // "this looks done already" — agree honestly so the loop closes
      if (hb.said === 'done' && ids.includes('yes') && ids.includes('missing')) {
        const label = await this.api.botAction(hb.actionId, 'yes').catch(() => null);
        if (label) {
          this.state.dmAnswered.push(x.id);
          emit('confirmed "' + (hb.issueTitle || 'the request') + '" is already shipped — proposed to close');
          acted = true;
        } else {
          log('could not answer the done-check card — retry next activation');
        }
        await this.api.breathe();
        continue;
      }

      // a finished change is ready — approve it like a happy member
      if (hb.kind === 'proposal') {
        const appr = hb.actions.find((a) => a.id === 'approve' && a.sessionId);
        if (appr && this.state.votedSessions.includes(appr.sessionId)) {
          this.state.dmApproved.push(appr.sessionId);
        } else if (appr && !this.state.dmApproved.includes(appr.sessionId)) {
          const r = await this.api.post('/api/sessions/' + appr.sessionId + '/vote', { vote: 'yes' }).catch(() => null);
          const votedOk = r && r.status === 200 && r.json && r.json.ok;
          const gone = r && r.status === 404;
          if (votedOk) {
            this.state.dmApproved.push(appr.sessionId);
            this.state.stats.votesCast += 1;
            emit('approved "' + (hb.issueTitle || 'the change') + '"');
            acted = true;
          } else if (gone) {
            this.state.dmAnswered.push(x.id);
            log('BUILD: session already gone, nothing to click');
          } else {
            log('BUILD: could not approve session #' + appr.sessionId + ' yet — retry next activation');
          }
          await this.api.breathe();
        }
      }
    }
    if (acted) await this.save();
  }

  /* votes — always yes */
  async taskVotes() {
    const cfg = this.config.tasks.vote;
    if (!cfg || cfg.enabled === false) return;
    const choice = 'yes';
    const scanAll = cfg.scanAllAppsOnStart && this.state.stats.runs <= 1;
    const joined = new Set(this.state.joinedApps);
    const toScan = this.apps.filter((a) => scanAll || joined.has(a.slug)).map((a) => a.slug);

    let cast = 0;
    for (const slug of toScan) {
      if (cast >= (cfg.maxPerRun || 8) || this.outOfTime) break;
      let items;
      try { items = await this.api.promoted(slug); } catch (e) { continue; }
      const open = items.filter((p) => p.status === 'promoted' && !p.my_vote
        && !this.state.votedSessions.includes(p.id));
      for (const p of open) {
        if (cast >= (cfg.maxPerRun || 8) || this.outOfTime) break;
        const title = String(p.pr_title || '').slice(0, 58);
        const ok = await this.api.vote(p.id, choice).catch(() => false);
        if (ok) {
          cast += 1;
          this.state.votedSessions.push(p.id);
          this.state.stats.votesCast += 1;
          this.summary.votes += 1;
          emit('voted YES on "' + title + '" (' + slug + ')');
        } else {
          const joinedNow = await this.joinApp(slug);
          if (joinedNow) {
            const ok2 = await this.api.vote(p.id, choice).catch(() => false);
            if (ok2) {
              cast += 1;
              this.state.votedSessions.push(p.id);
              this.state.stats.votesCast += 1;
              this.summary.votes += 1;
              emit('joined ' + slug + ' then voted YES on "' + title + '"');
            } else {
              this.state.votedSessions.push(p.id);
              log('VOTE: skipped "' + title + '" (not eligible)');
            }
          } else {
            this.state.votedSessions.push(p.id);
            log('VOTE: skipped "' + title + '" (needs a join we cannot do)');
          }
        }
        await this.api.breathe();
      }
    }
    if (cast > 0) await this.save();
  }

  /* chat — one short natural message, composed by the agent */
  async taskChat() {
    const cfg = this.config.tasks.chat;
    if (!cfg || cfg.enabled === false || !this.generalConv) return;
    const convId = this.generalConv.id;
    const msgs = await this.api.channelMessages(convId, 12).catch(() => []);
    if (!msgs.length) return;

    const last = msgs[msgs.length - 1];
    const mine = this.api.user && last.sender
      && last.sender.username === this.api.user.username;
    const recent = (this.state.chatLog || []).some((c) => {
      const mins = (Date.now() - new Date(c.at).getTime()) / 60000;
      return c.conversationId === convId && mins < (cfg.quietIfMineWithinMin || 10);
    });
    if (mine || recent) { log('CHAT: staying quiet — said something recently'); return; }

    const seenTexts = [...(this.state.recentTexts || []), ...this.state.chatLog.map((c) => c.content)];
    let content;
    try {
      content = await Composer.chatReply({
        messages: msgs, myUsername: this.api.user ? this.api.user.username : '', recent: seenTexts,
      });
    } catch (e) {
      log('CHAT: composer unavailable — staying quiet this activation (' + e.message + ')');
      return;
    }
    if (!(await this.textGap('chat'))) return;
    const sent = await this.api.sendMessage(convId, content);
    if (sent) {
      this.state.chatLog.unshift({ at: nowIso(), conversationId: convId, content });
      this.state.chatLog = this.state.chatLog.slice(0, MAX_LIST.chatLog);
      this.state.stats.messagesSent += 1;
      this.summary.chats += 1;
      this.rememberText(content);
      await this.save();
      emit('sent in #' + (this.config.tasks.chat.channel || 'general') + ' — "' + content + '"');
    } else {
      log('CHAT: message did not go through');
    }
  }

  /* try apps — spend a little time in the next apps */
  async taskTryApps() {
    const cfg = this.config.tasks.tryApps;
    if (!cfg || cfg.enabled === false) return;
    const tried = new Set(this.state.triedApps);
    const candidates = this.apps.filter((a) =>
      a.status === 'running' && !tried.has(a.slug) && a.slug !== 'usernode-2d5619');
    if (!candidates.length) { log('APP: every app tried at least once — nothing new this activation'); return; }
    const perCycle = Math.min(cfg.perCycle || 2, candidates.length);
    for (let i = 0; i < perCycle; i++) {
      if (this.outOfTime) break;
      const app = candidates.splice(Math.floor(Math.random() * candidates.length), 1)[0];
      if (cfg.joinBeforeTry) await this.joinApp(app.slug);
      emit('opening ' + (app.name || app.slug) + ' (' + app.slug + ')');
      const ok = await this.api.tryApp(
        app.slug,
        this.config.pacing.dwellSecondsPerApp,
        this.config.pacing.activityPingSeconds,
      ).catch(() => false);
      if (ok && !this.state.triedApps.includes(app.slug)) {
        this.state.triedApps.push(app.slug);
        this.state.stats.appsTried += 1;
        this.summary.apps += 1;
        await this.save();
      }
      if (i < perCycle - 1) await sleep(rand(...this.config.pacing.betweenAppsPauseMs));
    }
  }

  /* one free proposal when the challenge board asks for nothing specific */
  async taskPropose() {
    const cfg = this.config.tasks.propose;
    if (!cfg || cfg.enabled === false) return;
    if (cfg.once && this.state.proposalsFiled.length > 0) {
      log('PROPOSE: already proposed before — skipping (config.tasks.propose.once)');
      return;
    }
    const slug = (this.apps.find((a) => a.status === 'running' && a.slug !== 'usernode-2d5619')
      || this.apps[0] || {}).slug;
    if (!slug) return;
    const appCtx = this.apps.find((a) => a.slug === slug) || { slug };
    let idea;
    try {
      idea = await Composer.proposalIdea(appCtx, this.state.proposalsFiled.map((f) => f.title));
    } catch (e) { log('PROPOSE: composer unavailable — ' + e.message); return; }
    if (!(await this.textGap('proposal'))) return;
    const issue = await this.api.fileIssue(slug, idea.title, idea.body).catch(() => null);
    if (issue) {
      this.state.proposalsFiled.push({
        app: slug, issueId: issue.id, title: idea.title, at: nowIso(),
      });
      this.state.stats.proposalsFiled += 1;
      this.summary.proposals += 1;
      this.rememberText(idea.title);
      await this.save();
      emit('filed on ' + slug + ' — "' + idea.title + '"');
    } else {
      log('PROPOSE: could not file proposal on ' + slug);
    }
  }
}

/* ------------------------------------------------------------ commands */
/* The activation prompt (first message when the module is staged on a
   fresh chat) carries simple commands:
     setup <email> <password>   store credentials in THIS chat's storage
     status                     print the saved state summary
     reset                      wipe the runtime state (config kept)

   The setup FORM (host UI) is the primary path: the app gates this
   module's first run behind its per-chat setup form and passes the
   submitted values in as zagents.info.setup. The text command stays
   useful for RE-configuring an already set-up chat — it mirrors the new
   credentials into the same cooperative storage key ('zagentsSetup') so
   the host's setup gate stays in step.                                     */
function parseCommand(prompt) {
  const raw = String(prompt || '').trim();
  if (!raw) return { kind: null };
  const setup = raw.match(/^setup\s+(\S+)\s+(\S+)\s*$/i);
  if (setup) return { kind: 'setup', email: setup[1], password: setup[2] };
  if (/^status\b/i.test(raw)) return { kind: 'status' };
  if (/^reset\b/i.test(raw)) return { kind: 'reset' };
  return { kind: null };
}

async function printStatus(config, state) {
  const lines = [];
  lines.push('account: ' + (config.account.email || '(not set up yet)'));
  lines.push('session: ' + (state.session.cookie ? 'saved' : 'none'));
  lines.push('joined apps: ' + state.joinedApps.length
    + ' | tried: ' + state.triedApps.length + ' | votes: ' + state.stats.votesCast
    + ' | messages: ' + state.stats.messagesSent + ' | proposals: ' + state.stats.proposalsFiled);
  const open = (state.challenges || []).filter((c) => !c.done);
  lines.push('challenges open: ' + open.length + (open.length
    ? ' — next: ' + open.slice(0, 3).map((c) => c.goal).join(' | ') : ''));
  if (state.proposePipeline) {
    lines.push('proposal pipeline: round ' + (state.proposePipeline.round || 1)
      + ' on ' + state.proposePipeline.app + ' ('
      + (state.proposePipeline.done ? 'up for vote' : 'in progress') + ')');
  }
  if (state.buildPipeline) {
    lines.push('build pipeline: "' + (state.buildPipeline.idea ? state.buildPipeline.idea.title : '?')
      + '" (' + (state.buildPipeline.done ? 'approved' : 'in progress') + ')');
  }
  lines.push('runs: ' + state.stats.runs);
  for (const line of lines) await emit(line);
}

/* --------------------------------------------------------------- entry */
async function main() {
  const config = deepFill(await loadJson('config', DEFAULT_CONFIG), DEFAULT_CONFIG);
  const state = deepFill(await loadJson('data', DEFAULT_DATA), DEFAULT_DATA);
  if (!state.meta.createdAt) state.meta.createdAt = nowIso();

  // Setup-form values (app-collected): make them THIS chat's credentials.
  const hostSetup = readHostSetup() || (await readStoredSetup());
  if (hostSetup
    && typeof hostSetup.email === 'string' && hostSetup.email
    && typeof hostSetup.password === 'string' && hostSetup.password
    && !sameAccount(hostSetup, config.account)) {
    config.account.email = hostSetup.email;
    config.account.password = hostSetup.password;
    await saveJson('config', config);
    await log('setup-form credentials applied to this chat');
  }

  const cmd = parseCommand(zagents.info && zagents.info.prompt);
  if (cmd.kind === 'setup') {
    config.account.email = cmd.email;
    config.account.password = cmd.password;
    await saveJson('config', config);
    await mirrorSetup(config);
    await emit('credentials saved for this chat — starting the first cycle');
  } else if (cmd.kind === 'reset') {
    await saveJson('data', JSON.parse(JSON.stringify(DEFAULT_DATA)));
    await emit('runtime state has been reset (credentials kept) — activate again to run');
    return { ok: true, command: 'reset' };
  } else if (cmd.kind === 'status') {
    await printStatus(config, state);
    return { ok: true, command: 'status' };
  }

  if (!accountReady(config)) {
    await emit('OnHomeroom Daily needs your account for THIS chat.');
    await emit('The app shows a setup form for it — submit the form and the '
      + 'cycle starts automatically. (On an already set-up chat the text '
      + 'command still works: setup your-email your-password)');
    await log('no account configured — setup required before any cycle');
    return { ok: false, error: 'setup required' };
  }
  await mirrorSetup(config);

  // One activation = one cycle with a hard internal deadline (keeps a
  // margin under the manifest timeout so state always gets saved).
  const deadline = Date.now() + 100 * 1000;
  const bot = new Bot(config, state, deadline);
  state.stats.runs += 1;
  const runStartedAt = nowIso();

  try {
    if (!(await bot.api.ensureLoggedIn())) {
      await emit('could not sign in — check the saved credentials (send: setup email password)');
      state.runs.unshift({ startedAt: runStartedAt, endedAt: nowIso(), error: 'login' });
      await bot.save();
      return { ok: false, error: 'login failed' };
    }
    state.session.cookie = bot.api.cookie;
    state.session.savedAt = nowIso();
    state.user = bot.api.user;
    await bot.save();

    await bot.syncContext();
    await bot.runCycle();
  } catch (e) {
    bot.summary.errors += 1;
    log('ERROR: cycle crashed — ' + (e && e.message ? e.message : e));
  }

  state.runs.unshift({
    startedAt: runStartedAt, endedAt: nowIso(),
    ...bot.summary,
  });
  await bot.save();

  const s = bot.summary;
  await emit('run summary — votes: ' + s.votes + ', chats: ' + s.chats
    + ', apps tried: ' + s.apps + ', proposals: ' + s.proposals
    + ', feedback: ' + s.feedback + ', errors: ' + s.errors);
  await log('state saved in this chat storage — activate the module again for the next cycle');
  return { ok: true, summary: s };
}

module.exports = main();
