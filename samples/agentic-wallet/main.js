/**
 * Agentic Wallet — ZAgents chat module (samples/agentic-wallet).
 *
 * A per-chat POLICY and BOOKKEEPING companion for the official Binance
 * Agentic Wallet workflows, driven by /aw slash commands (manifest
 * commands: ["aw"] — the message routes to this module instead of the
 * LLM, so policy commands never consume an AI turn).
 *
 * What this module IS (honest by design):
 *   - An advisory / bookkeeping layer that runs fully on-device with
 *     NO network permission: pairing notes, daily spend limits, a token
 *     registry, EIP-55 address validation, spend INTENTS and history.
 *   - It holds NO keys, does NO signing, makes NO network calls and
 *     never moves funds itself. Every value-moving action is executed
 *     by the USER in the official Binance App / Binance web wallet,
 *     driven inside the chat's isolated browser by the agent with an
 *     explicit request_confirmation card.
 *
 * Flow for a value-moving action:
 *   /aw spend <token> <amount> <to>   builds a PENDING intent + DRAFT
 *                                     summary (validated against the
 *                                     daily limit) -> the AGENT must
 *                                     call request_confirmation with
 *                                     these facts and wait for the
 *                                     user's explicit approval
 *   /aw spend confirm <id>            records the APPROVED intent into
 *                                     history and the daily book
 *                                     (still no funds moved — the
 *                                     transfer itself happens in the
 *                                     Binance App / web wallet)
 *   /aw spend cancel <id>             drops the pending intent
 *
 * Commands:
 *   /aw                        status (pairing, network, limit, book)
 *   /aw status                 same
 *   /aw pair                   two-step pairing note -> /aw pair confirm
 *   /aw unpair confirm         clear the pairing note (keeps history)
 *   /aw limit                  show the daily limit + today's book
 *   /aw limit <amount>         set the daily spend limit (0 blocks all)
 *   /aw network                list networks + the active one
 *   /aw network <name>         switch (bsc | eth | arbitrum | base,
 *                              aliases bnb, ethereum)
 *   /aw tokens                 registry for the active network
 *   /aw checksum <addr> [net]  validate shape + EIP-55 checksum
 *   /aw spend <t> <a> <to>     draft a spend intent (policy-checked)
 *   /aw spend confirm <id>     record an APPROVED intent (bookkeeping)
 *   /aw spend cancel <id>      drop the pending intent
 *   /aw history                last 20 recorded spends
 *   /aw reset confirm          wipe this chat's state (two-step)
 *   /aw help                   command list
 *
 * Zero dependencies: pure JS, no require, no fetch, no timers. The only
 * crypto is Keccak-256 for EIP-55 checksumming, copied from
 * samples/evm-wallet/main.js (BigInt lanes, original Keccak padding).
 * Requires the ZAgents module runtime (zagents.storage / log / chat).
 * ==========================================================================*/

'use strict';

/* ==========================================================================
 * Keccak-256 — copied verbatim from samples/evm-wallet/main.js (which
 * implements it inline, zero deps): BigInt lanes (25 x uint64), rate
 * 1088 bits (136 bytes) for 256-bit output, ORIGINAL Keccak padding
 * 0x01 — NOT NIST SHA3's 0x06.
 * ========================================================================== */

const _KECCAK_RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an,
  0x8000000080008000n, 0x000000000000808bn, 0x0000000080000001n,
  0x8000000080008081n, 0x8000000000008009n, 0x000000000000008an,
  0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n,
  0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n,
  0x000000000000800an, 0x800000008000000an, 0x8000000080008081n,
  0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

/* rho rotation offsets, indexed [x][y] */
const _KECCAK_ROT = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];

const _U64 = 0xffffffffffffffffn;

function _rotl64(v, n) {
  const b = BigInt(n);
  return ((v << b) | (v >> (64n - b))) & _U64;
}

function _keccakF(st) {
  for (let round = 0; round < 24; round++) {
    // theta
    const c = new Array(5);
    for (let x = 0; x < 5; x++) {
      c[x] = st[x] ^ st[x + 5] ^ st[x + 10] ^ st[x + 15] ^ st[x + 20];
    }
    const d = new Array(5);
    for (let x = 0; x < 5; x++) {
      d[x] = c[(x + 4) % 5] ^ _rotl64(c[(x + 1) % 5], 1);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) st[x + 5 * y] ^= d[x];
    }
    // rho + pi
    const b = new Array(25).fill(0n);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl64(st[x + 5 * y], _KECCAK_ROT[x][y]);
      }
    }
    // chi
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        const notB = ~b[((x + 1) % 5) + 5 * y] & _U64;
        st[x + 5 * y] = b[x + 5 * y] ^ (notB & b[((x + 2) % 5) + 5 * y]);
      }
    }
    // iota
    st[0] ^= _KECCAK_RC[round];
  }
}

function _keccakXorBlock(st, bytes, off) {
  for (let i = 0; i < 17; i++) {
    // 136 bytes = 17 lanes
    let lane = 0n;
    const base = off + i * 8;
    for (let j = 7; j >= 0; j--) lane = (lane << 8n) | BigInt(bytes[base + j]);
    st[i] ^= lane;
  }
}

const _KECCAK_RATE = 136;

/** keccak256(Uint8Array) -> Uint8Array(32) */
function keccak256(bytes) {
  const st = new Array(25).fill(0n);
  let off = 0;
  const len = bytes.length;
  while (len - off >= _KECCAK_RATE) {
    _keccakXorBlock(st, bytes, off);
    _keccakF(st);
    off += _KECCAK_RATE;
  }
  const pad = new Uint8Array(_KECCAK_RATE);
  pad.set(bytes.subarray(off), 0);
  pad[len - off] ^= 0x01; // Keccak domain byte
  pad[_KECCAK_RATE - 1] ^= 0x80; // multi-rate padding tail
  _keccakXorBlock(st, pad, 0);
  _keccakF(st);
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = st[i];
    for (let j = 0; j < 8; j++) {
      out[i * 8 + j] = Number(lane & 0xffn);
      lane >>= 8n;
    }
  }
  return out;
}

/* ==========================================================================
 * Hex helpers (from samples/evm-wallet/main.js) + EIP-55 mixed-case
 * checksum addresses.
 * ========================================================================== */

const _HEX = '0123456789abcdef';

function bytesToHex(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += _HEX[bytes[i] >> 4] + _HEX[bytes[i] & 15];
  }
  return out;
}

function asciiToBytes(s) {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
  return out;
}

/** lowercase-hex address (0x + 40 hex chars) -> EIP-55 checksummed form. */
function toChecksumAddress(addrBytes) {
  const lower = bytesToHex(addrBytes).toLowerCase();
  const hash = bytesToHex(keccak256(asciiToBytes(lower)));
  let out = '0x';
  for (let i = 0; i < 40; i++) {
    const c = lower[i];
    if (c >= 'a' && c <= 'f') {
      const nibble = parseInt(hash[i], 16);
      out += nibble >= 8 ? c.toUpperCase() : c;
    } else {
      out += c;
    }
  }
  return out;
}

/**
 * Validate an address WITHOUT throwing. Returns
 * { ok, canonical, reason } — mixed-case input must carry the correct
 * EIP-55 checksum (a typo must never be silently accepted); plain
 * lowercase is accepted and canonicalized.
 */
function checkAddress(input) {
  const raw = String(input || '').trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
    return {
      ok: false,
      reason: 'expected 0x followed by exactly 40 hex characters (got ' +
        (raw.length - (raw.startsWith('0x') ? 2 : 0)) + ' hex chars)',
    };
  }
  const body = raw.slice(2);
  const canonical = toChecksumAddress(new Uint8Array(
    body.match(/.{2}/g).map((b) => parseInt(b, 16)),
  ));
  const hasUpper = /[A-F]/.test(body);
  const hasLower = /[a-f]/.test(body);
  if (hasUpper && hasLower && raw !== canonical) {
    return {
      ok: false,
      reason: 'EIP-55 checksum mismatch — canonical form is ' + canonical,
    };
  }
  return { ok: true, canonical: canonical };
}

/* ==========================================================================
 * Token registry — mainnet addresses in EIP-55 canonical form. The
 * addresses below were verified by round-tripping every one through
 * the keccak-based toChecksumAddress above (see samples/agentic-wallet
 * README: ALWAYS re-verify against an official source before moving
 * funds — this module is bookkeeping, not a source of truth).
 * ========================================================================== */

const NETWORKS = {
  bsc: {
    label: 'BNB Smart Chain (chain id 56)',
    tokens: {
      BNB: { address: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', decimals: 18, native: true },
      USDT: { address: '0x55d398326f99059fF775485246999027B3197955', decimals: 18 },
      USDC: { address: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d', decimals: 18 },
      ETH: { address: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8', decimals: 18 },
      CAKE: { address: '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82', decimals: 18 },
    },
  },
  eth: {
    label: 'Ethereum (chain id 1)',
    tokens: {
      ETH: { address: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', decimals: 18, native: true },
      USDT: { address: '0xdAC17F958D2ee523a2206206994597C13D831ec7', decimals: 6 },
      USDC: { address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
      WBTC: { address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', decimals: 8 },
    },
  },
  arbitrum: {
    label: 'Arbitrum One (chain id 42161)',
    tokens: {
      ETH: { address: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', decimals: 18, native: true },
      USDT: { address: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', decimals: 6 },
      USDC: { address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', decimals: 6 },
    },
  },
  base: {
    label: 'Base (chain id 8453)',
    tokens: {
      ETH: { address: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', decimals: 18, native: true },
      USDC: { address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', decimals: 6 },
    },
  },
};

const NETWORK_ALIASES = { bnb: 'bsc', ethereum: 'eth' };

/* ==========================================================================
 * State — ONE storage key (per-chat KV; other chats never see it).
 * { v:1, paired, pairedAt, network, dailyLimit, todaySpend:{date,amounts},
 *   pending, gate, history, seq }
 * gate is the two-step confirmation latch for pair/unpair/reset
 * (pending alone is reserved for spend intents).
 * ========================================================================== */

const STATE_KEY = 'agenticWalletState';
const HISTORY_CAP = 200;
const HISTORY_SHOW = 20;

function todayUtc() {
  return new Date().toISOString().slice(0, 10);
}

function defaultState() {
  return {
    v: 1,
    paired: false,
    pairedAt: null,
    network: 'bsc',
    dailyLimit: 0,
    todaySpend: { date: todayUtc(), amounts: {} },
    pending: null,
    gate: null,
    history: [],
    seq: 0,
  };
}

function _num(x) {
  return typeof x === 'number' && isFinite(x) ? x : null;
}

function _str(x) {
  return typeof x === 'string' ? x : null;
}

/** Defensive read: accept anything, fall back to defaults piecewise. */
function coerceState(raw) {
  let v = raw;
  if (typeof v === 'string') {
    try { v = JSON.parse(v); } catch (e) { return defaultState(); }
  }
  if (!v || typeof v !== 'object') return defaultState();
  const st = defaultState();
  if (typeof v.paired === 'boolean') st.paired = v.paired;
  st.pairedAt = _str(v.pairedAt);
  if (v.network && NETWORKS[v.network]) st.network = v.network;
  const dl = _num(v.dailyLimit);
  if (dl !== null && dl >= 0) st.dailyLimit = dl;
  if (v.todaySpend && typeof v.todaySpend === 'object') {
    const d = _str(v.todaySpend.date);
    if (d) st.todaySpend.date = d;
    if (v.todaySpend.amounts && typeof v.todaySpend.amounts === 'object') {
      for (const k of Object.keys(v.todaySpend.amounts)) {
        const n = _num(v.todaySpend.amounts[k]);
        if (n !== null && n >= 0) st.todaySpend.amounts[k] = n;
      }
    }
  }
  if (v.pending && typeof v.pending === 'object') {
    const p = v.pending;
    if (_str(p.id) && _str(p.token) && _num(p.amount) !== null &&
        _str(p.to) && _str(p.network) && _str(p.createdAt)) {
      st.pending = {
        id: p.id,
        token: p.token,
        amount: p.amount,
        to: p.to,
        network: p.network,
        createdAt: p.createdAt,
      };
    }
  }
  if (v.gate && typeof v.gate === 'object' &&
      (v.gate.action === 'pair' || v.gate.action === 'unpair' ||
        v.gate.action === 'reset')) {
    st.gate = { action: v.gate.action, createdAt: _str(v.gate.createdAt) };
  }
  if (Array.isArray(v.history)) {
    for (const h of v.history.slice(-HISTORY_CAP)) {
      if (h && typeof h === 'object' && _str(h.id) && _str(h.token) &&
          _num(h.amount) !== null && _str(h.to)) {
        st.history.push({
          id: h.id,
          network: _str(h.network) || st.network,
          token: h.token,
          amount: h.amount,
          to: h.to,
          createdAt: _str(h.createdAt) || '',
          approvedAt: _str(h.approvedAt) || '',
        });
      }
    }
  }
  const seq = _num(v.seq);
  if (seq !== null && seq >= 0) st.seq = Math.floor(seq);
  return st;
}

/** Daily rollover is a mutation too — persisted right after. */
async function loadState() {
  const raw = await zagents.storage.get(STATE_KEY);
  const st = coerceState(raw);
  const today = todayUtc();
  if (st.todaySpend.date !== today) {
    st.todaySpend = { date: today, amounts: {} };
    await zagents.storage.set(STATE_KEY, st);
  }
  return st;
}

async function saveState(st) {
  await zagents.storage.set(STATE_KEY, st);
}

/* ==========================================================================
 * Formatting + small helpers
 * ========================================================================== */

function fmtAmount(n) {
  return String(Math.round(n * 1e12) / 1e12);
}

function spentToday(st, sym) {
  const n = st.todaySpend.amounts[sym];
  return typeof n === 'number' && isFinite(n) ? n : 0;
}

function remainingAllowance(st, sym) {
  const left = st.dailyLimit - spentToday(st, sym);
  return Math.round(left * 1e12) / 1e12;
}

function parseAmount(s) {
  if (!/^\d+(\.\d+)?$/.test(s)) return null;
  const n = Number(s);
  return isFinite(n) ? n : null;
}

function networkName(key) {
  return NETWORKS[key] ? NETWORKS[key].label : key;
}

function resolveNetwork(name) {
  const k = String(name || '').trim().toLowerCase();
  if (NETWORKS[k]) return k;
  if (NETWORK_ALIASES[k]) return NETWORK_ALIASES[k];
  return null;
}

function findToken(netKey, sym) {
  const tokens = NETWORKS[netKey].tokens;
  const want = String(sym || '').trim().toUpperCase();
  if (Object.prototype.hasOwnProperty.call(tokens, want)) return want;
  return null;
}

const ADVICE_LINE =
  'Mode: policy/advisory — no keys, no signing, no network. ' +
  'Funds only ever move in the official Binance App / web wallet.';

const SPEND_USAGE =
  'Usage: /aw spend <token> <amount> <to>  (then /aw spend confirm <id> ' +
  'after the user approves, or /aw spend cancel <id>)';

/* ==========================================================================
 * Command bodies
 * ========================================================================== */

function cmdStatus(say, st) {
  say('🧭 Agentic Wallet — per-chat policy and bookkeeping hub for the');
  say('   official Binance Agentic Wallet workflows.');
  say(ADVICE_LINE);
  say('');
  say('Pairing : ' + (st.paired
    ? 'paired (manual-bookkeeping, ' + (st.pairedAt || '?') + ')'
    : 'unpaired — /aw pair to attach a wallet note to THIS chat'));
  say('Network : ' + st.network + ' — ' + networkName(st.network));
  say('Limit   : ' + (st.dailyLimit > 0
    ? fmtAmount(st.dailyLimit) + ' / day (per token)'
    : 'not set — spending blocked until /aw limit <amount>'));
  const syms = Object.keys(st.todaySpend.amounts).sort();
  if (!syms.length) {
    say('Today   : no recorded spend (' + st.todaySpend.date + ' UTC)');
  } else {
    say('Today   : ' + st.todaySpend.date + ' UTC — recorded spend:');
    for (const s of syms) {
      say('  - ' + s + ': ' + fmtAmount(st.todaySpend.amounts[s]) +
        ' (left ' + fmtAmount(remainingAllowance(st, s)) + ')');
    }
  }
  say('Pending : ' + (st.pending
    ? '1 intent (' + st.pending.id + ' — ' + fmtAmount(st.pending.amount) +
      ' ' + st.pending.token + ' on ' + st.pending.network + ')'
    : '0'));
  if (st.history.length) {
    const h = st.history[st.history.length - 1];
    say('Last    : ' + h.id + ' — ' + fmtAmount(h.amount) + ' ' + h.token +
      ' to ' + h.to + ' (' + (h.approvedAt || h.createdAt) + ')');
  } else {
    say('Last    : no history yet');
  }
  say('');
  say('/aw help for commands.');
}

async function cmdPair(say, st, rest, save) {
  if (st.paired) {
    say('✅ This chat already has a pairing note (' + (st.pairedAt || '?') + ').');
    say('   /aw unpair confirm to clear it. Nothing else changes.');
    return;
  }
  if (rest === 'confirm') {
    if (!st.gate || st.gate.action !== 'pair') {
      say('Two-step safety: send /aw pair first, then /aw pair confirm.');
      return;
    }
    st.paired = true;
    st.pairedAt = new Date().toISOString();
    st.gate = null;
    await save();
    say('✅ Paired (bookkeeping only): THIS chat now records a wallet.');
    say('   method: manual-bookkeeping · at ' + st.pairedAt);
    say('');
    say('What this means — and what it does NOT mean:');
    say('- You pair the REAL wallet in the official Binance App / web');
    say('  wallet. This module only records that a wallet is attached');
    say('  to THIS chat for limits and spend bookkeeping.');
    say('- No key, seed phrase or credential is collected or stored —');
    say('  never paste any of those into a chat.');
    return;
  }
  if (rest) {
    say('Unknown /aw pair argument. Usage:');
    say('  /aw pair           start pairing (bookkeeping note)');
    say('  /aw pair confirm   complete the two-step');
    return;
  }
  st.gate = { action: 'pair', createdAt: new Date().toISOString() };
  await save();
  say('📋 Pairing = bookkeeping only, two steps:');
  say('   1. You pair the REAL wallet in the official Binance App /');
  say('      Binance web wallet (login happens ONLY on Binance pages).');
  say('   2. Send /aw pair confirm — this module then records that a');
  say('      wallet is attached to THIS chat (no secrets involved).');
  say('');
  say('Nothing is signed or connected by this module: no keys, no');
  say('signing, no network. Send /aw pair confirm to finish.');
}

async function cmdUnpair(say, st, rest, save) {
  if (!st.paired) {
    say('This chat has no pairing note — nothing to unpair.');
    return;
  }
  if (rest === 'confirm') {
    if (!st.gate || st.gate.action !== 'unpair') {
      say('Two-step safety: send /aw unpair first, then /aw unpair confirm.');
      return;
    }
    st.paired = false;
    st.pairedAt = null;
    st.gate = null;
    await save();
    say('✅ Unpaired. The pairing note is cleared; history is kept.');
    return;
  }
  if (rest) {
    say('Unknown /aw unpair argument. Usage: /aw unpair confirm');
    return;
  }
  st.gate = { action: 'unpair', createdAt: new Date().toISOString() };
  await save();
  say('📋 Unpair clears the pairing note for THIS chat (history stays).');
  say('   Two-step safety: send /aw unpair confirm to proceed.');
}

async function cmdLimit(say, st, rest, save) {
  if (!rest) {
    say('Daily limit : ' + (st.dailyLimit > 0
      ? fmtAmount(st.dailyLimit) + ' per token per day'
      : 'not set (0 — all /aw spend blocked)'));
    say('Today       : ' + st.todaySpend.date + ' UTC');
    const syms = Object.keys(st.todaySpend.amounts).sort();
    for (const s of syms) {
      say('  - ' + s + ': spent ' + fmtAmount(st.todaySpend.amounts[s]) +
        ', left ' + fmtAmount(remainingAllowance(st, s)));
    }
    say('Set with: /aw limit <amount>  (dot decimal, 0 blocks everything,');
    say('the cap applies per token — e.g. limit 100 allows 100 USDT AND');
    say('100 BNB in the same day).');
    return;
  }
  const n = parseAmount(rest);
  if (n === null) {
    say('❌ Invalid amount: "' + rest + '". Use a plain dot-decimal number,');
    say('   e.g. /aw limit 25 or /aw limit 25.5');
    return;
  }
  st.dailyLimit = n;
  await save();
  say('✅ Daily limit set: ' + fmtAmount(n) + ' per token per day (UTC).');
  if (n === 0) say('   0 blocks every /aw spend — a deliberate pause switch.');
  say(ADVICE_LINE);
}

async function cmdNetwork(say, st, rest, save) {
  if (!rest) {
    say('🌐 Networks (registry keys):');
    for (const key of Object.keys(NETWORKS)) {
      const mark = key === st.network ? ' ← active' : '';
      say('  - ' + key + ' — ' + NETWORKS[key].label + mark);
    }
    say('Aliases: bnb → bsc, ethereum → eth. Switch: /aw network <name>');
    return;
  }
  const key = resolveNetwork(rest);
  if (!key) {
    say('❌ Unknown network "' + rest + '". Available:');
    say('   ' + Object.keys(NETWORKS).join(', ') + ' (aliases bnb, ethereum)');
    return;
  }
  if (key === st.network) {
    say('Already on ' + key + ' — ' + networkName(key));
    return;
  }
  const dropped = st.pending
    ? ' Pending intent ' + st.pending.id + ' was dropped (network switch).'
    : '';
  st.network = key;
  if (st.pending) st.pending = null;
  await save();
  say('✅ Active network: ' + key + ' — ' + networkName(key) + '.' + dropped);
  say('   /aw tokens lists the registered tokens here.');
}

function cmdTokens(say, st) {
  const net = NETWORKS[st.network];
  say('🪙 Registered tokens on ' + st.network + ' — ' + net.label + ':');
  for (const sym of Object.keys(net.tokens)) {
    const t = net.tokens[sym];
    say('  ' + sym.padEnd(5) + ' ' + t.address +
      '  (' + t.decimals + (t.native ? ', native gas token)' : ' decimals)'));
  }
  say('');
  say('⚠️ Verify each address against an official source (Binance wallet');
  say('   UI or the chain explorer) BEFORE moving funds — this registry');
  say('   is bookkeeping data, not a source of truth.');
}

function cmdChecksum(say, st, rest) {
  const parts = rest.split(/\s+/).filter(Boolean);
  if (!parts.length) {
    say('Usage: /aw checksum <address> [network]');
    say('  e.g. /aw checksum 0x55d398326f99059fF775485246999027B3197955 bsc');
    return;
  }
  const addr = parts[0];
  let netKey = st.network;
  if (parts[1]) {
    const resolved = resolveNetwork(parts[1]);
    if (!resolved) {
      netKey = null; // unknown network: shape + checksum-agnostic mode
      say('ℹ️ Unknown network "' + parts[1] + '" — checking shape only');
      say('   (no checksum verdict without a known chain).');
    }
  }
  const raw = addr.trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
    say('❌ INVALID — ' + raw);
    say('   expected 0x followed by exactly 40 hex characters (got ' +
      (raw.length - (raw.toLowerCase().startsWith('0x') ? 2 : 0)) + ').');
    return;
  }
  if (netKey === null) {
    // Unknown network: shape + checksum-agnostic — never judge the case.
    const lower = raw.toLowerCase();
    const allLower = raw.slice(2) === lower.slice(2);
    const allUpper = raw.slice(2) === raw.slice(2).toUpperCase();
    say('✅ VALID (shape only — network unknown, checksum not judged): ' + raw);
    if (!allLower && !allUpper) {
      say('   Mixed-case input cannot be verified without a known chain —');
      say('   re-check the source you copied it from.');
    }
    return;
  }
  const res = checkAddress(raw);
  if (!res.ok) {
    say('❌ INVALID for ' + netKey + ' — ' + raw);
    say('   ' + res.reason);
    return;
  }
  let extra = '';
  for (const sym of Object.keys(NETWORKS[netKey].tokens)) {
    if (NETWORKS[netKey].tokens[sym].address.toLowerCase() ===
        res.canonical.toLowerCase()) {
      extra = ' (registered ' + sym + ' on ' + netKey + ')';
      break;
    }
  }
  say('✅ VALID — canonical EIP-55 form: ' + res.canonical + extra);
  if (res.canonical !== raw) {
    say('   Use the canonical form exactly when moving funds.');
  }
}

async function cmdSpend(say, st, rest, save) {
  const parts = rest.split(/\s+/).filter(Boolean);
  const op = parts[0] ? parts[0].toLowerCase() : '';
  if (op === 'confirm') return cmdSpendConfirm(say, st, parts[1] || '', save);
  if (op === 'cancel') return cmdSpendCancel(say, st, parts[1] || '', save);

  if (!op) {
    say(SPEND_USAGE);
    say('The draft is policy-checked; NOTHING is executed by this module.');
    return;
  }
  if (parts.length < 3) {
    say(SPEND_USAGE);
    return;
  }
  if (!st.paired) {
    say('❌ Not paired. Pair first (two steps): /aw pair, then /aw pair confirm.');
    say('   Pairing is bookkeeping only — no keys, no signing.');
    return;
  }
  if (!(st.dailyLimit > 0)) {
    say('❌ No daily limit set — spending is blocked. /aw limit <amount>');
    return;
  }
  const sym = findToken(st.network, parts[0]);
  if (!sym) {
    say('❌ Token "' + parts[0] + '" is not registered on ' + st.network +
      '. /aw tokens');
    return;
  }
  const amount = parseAmount(parts[1]);
  if (amount === null || amount <= 0) {
    say('❌ Invalid amount: "' + parts[1] + '" — use a positive dot-decimal.');
    return;
  }
  const res = checkAddress(parts[2]);
  if (!res.ok) {
    say('❌ INVALID destination — ' + parts[2]);
    say('   ' + res.reason);
    return;
  }
  const remaining = remainingAllowance(st, sym);
  if (amount > remaining) {
    say('❌ Over the daily policy: ' + fmtAmount(amount) + ' ' + sym +
      ' requested, ' + fmtAmount(remaining) + ' ' + sym + ' left today');
    say('   (limit ' + fmtAmount(st.dailyLimit) + ' − recorded ' +
      fmtAmount(spentToday(st, sym)) + '). Raise it with /aw limit or wait');
    say('   for the UTC rollover.');
    return;
  }
  const replaced = st.pending ? st.pending.id : null;
  st.seq += 1;
  st.pending = {
    id: 'sp-' + st.seq,
    token: sym,
    amount: amount,
    to: res.canonical,
    network: st.network,
    createdAt: new Date().toISOString(),
  };
  const left = Math.round((remaining - amount) * 1e12) / 1e12;
  await save();
  if (replaced) {
    say('ℹ️ Replaced the previous pending intent ' + replaced + '.');
  }
  say('📝 SPEND DRAFT — ' + st.pending.id + ' (PENDING, nothing executed)');
  say('- Network : ' + st.pending.network + ' — ' + networkName(st.pending.network));
  say('- Token   : ' + sym + ' (' + NETWORKS[st.network].tokens[sym].decimals +
    ' decimals)');
  say('- Amount  : ' + fmtAmount(amount) + ' ' + sym);
  say('- To      : ' + res.canonical);
  say('- Allowance left after this: ' + fmtAmount(left) + ' ' + sym +
    ' (today, UTC)');
  say('- Created : ' + st.pending.createdAt);
  say('');
  say('AGENT, STOP HERE AND FOLLOW THE POLICY:');
  say('1. Call request_confirmation with EXACTLY these facts (network,');
  say('   token, amount, destination) and wait for the user to approve');
  say('   the card. No action of any kind before that approval.');
  say('2. Even after approval, THIS MODULE DOES NOT MOVE FUNDS. The');
  say('   transfer itself is executed by the USER in the official');
  say('   Binance App / Binance web wallet, on Binance pages only.');
  say('3. Only after the user approves AND completes the transfer in');
  say('   the Binance App, record the bookkeeping with:');
  say('     /aw spend confirm ' + st.pending.id);
  say('   or drop it with: /aw spend cancel ' + st.pending.id);
}

async function cmdSpendConfirm(say, st, id, save) {
  if (!st.pending) {
    say('No pending intent to confirm. Draft one: /aw spend <token> <amount> <to>');
    return;
  }
  if (!id) {
    say('Usage: /aw spend confirm ' + st.pending.id);
    return;
  }
  if (id.toLowerCase() !== st.pending.id.toLowerCase()) {
    say('❌ Id mismatch: pending intent is ' + st.pending.id + ', not "' + id + '".');
    say('   /aw spend cancel ' + st.pending.id + ' to drop it instead.');
    return;
  }
  if (st.pending.network !== st.network) {
    say('❌ Network changed since this intent was drafted (' +
      st.pending.network + ' → ' + st.network + ').');
    say('   Cancel it and draft again on the right network.');
    return;
  }
  if (st.pending.amount > remainingAllowance(st, st.pending.token)) {
    say('❌ The daily allowance no longer covers this intent (limit or');
    say('   recorded spend changed). Raise the limit or draft a smaller one.');
    return;
  }
  const p = st.pending;
  const approvedAt = new Date().toISOString();
  st.history.push({
    id: p.id,
    network: p.network,
    token: p.token,
    amount: p.amount,
    to: p.to,
    createdAt: p.createdAt,
    approvedAt: approvedAt,
  });
  if (st.history.length > HISTORY_CAP) {
    st.history = st.history.slice(-HISTORY_CAP);
  }
  st.todaySpend.amounts[p.token] =
    Math.round((spentToday(st, p.token) + p.amount) * 1e12) / 1e12;
  st.pending = null;
  await save();
  say('📒 Recorded — ' + p.id + ': ' + fmtAmount(p.amount) + ' ' + p.token +
    ' to ' + p.to + ' on ' + p.network + ' (approved ' + approvedAt + ').');
  say('');
  say('⚠️ This module did not move funds — execute in the Binance App /');
  say('   Binance web wallet. The entry above is BOOKKEEPING of a spend');
  say('   the user approved via request_confirmation and performed on');
  say('   Binance pages. Today: ' + fmtAmount(st.todaySpend.amounts[p.token]) +
    ' ' + p.token + ' recorded, ' +
    fmtAmount(remainingAllowance(st, p.token)) + ' ' + p.token + ' left.');
}

async function cmdSpendCancel(say, st, id, save) {
  if (!st.pending) {
    say('No pending intent to cancel.');
    return;
  }
  if (!id) {
    say('Usage: /aw spend cancel ' + st.pending.id);
    return;
  }
  if (id.toLowerCase() !== st.pending.id.toLowerCase()) {
    say('❌ Id mismatch: pending intent is ' + st.pending.id + ', not "' + id + '".');
    return;
  }
  const dropped = st.pending.id;
  st.pending = null;
  await save();
  say('🗑️ Dropped pending intent ' + dropped + '. Nothing was recorded,');
  say('   nothing was ever executed by this module.');
}

function cmdHistory(say, st) {
  if (!st.history.length) {
    say('📒 No recorded spends in THIS chat yet. Approved intents land');
    say('   here via /aw spend confirm <id>.');
    return;
  }
  const last = st.history.slice(-HISTORY_SHOW);
  say('📒 Last ' + last.length + ' of ' + st.history.length +
    ' recorded spends (newest last, THIS chat only):');
  for (const h of last) {
    say('  ' + h.id + '  ' + (h.approvedAt || h.createdAt) + '  ' +
      h.network.padEnd(8) + ' ' + fmtAmount(h.amount) + ' ' +
      h.token.padEnd(5) + ' → ' + h.to);
  }
  say('');
  say('Bookkeeping only — every real transfer happened in the official');
  say('Binance App / web wallet, after a request_confirmation approval.');
}

async function cmdReset(say, st, rest, save) {
  if (rest === 'confirm') {
    if (!st.gate || st.gate.action !== 'reset') {
      say('Two-step safety: send /aw reset first, then /aw reset confirm.');
      return;
    }
    const fresh = defaultState();
    for (const k of Object.keys(fresh)) st[k] = fresh[k];
    await save();
    say('🧹 State wiped for THIS chat: pairing, limit, today book,');
    say('   pending intent, gate and history are gone. Fresh start.');
    return;
  }
  if (rest) {
    say('Unknown /aw reset argument. Usage: /aw reset confirm');
    return;
  }
  st.gate = { action: 'reset', createdAt: new Date().toISOString() };
  await save();
  say('⚠️ This wipes the WHOLE state of THIS chat: pairing note, daily');
  say('   limit, today\u2019s book, pending intent and history.');
  say('   Two-step safety: send /aw reset confirm to proceed.');
}

function cmdHelp(say) {
  say('🧭 Agentic Wallet — per-chat policy/bookkeeping for the official');
  say('   Binance Agentic Wallet workflows. ' + ADVICE_LINE);
  say('');
  say('  /aw                        status (pairing, limit, book, pending)');
  say('  /aw status                 same as above');
  say('  /aw pair                   pairing note, two steps → /aw pair confirm');
  say('  /aw unpair confirm         clear the pairing note (history kept)');
  say('  /aw limit                  show the daily limit + today\u2019s book');
  say('  /aw limit <amount>         set the daily per-token cap (0 = block)');
  say('  /aw network                list networks + active');
  say('  /aw network <name>         switch: bsc | eth | arbitrum | base');
  say('  /aw tokens                 registry for the active network');
  say('  /aw checksum <addr> [net]  validate shape + EIP-55 checksum');
  say('  /aw spend <t> <a> <to>     policy-checked spend DRAFT (pending)');
  say('  /aw spend confirm <id>     record an APPROVED spend (bookkeeping)');
  say('  /aw spend cancel <id>      drop the pending draft');
  say('  /aw history                last 20 recorded spends');
  say('  /aw reset confirm          wipe this chat\u2019s state (two steps)');
  say('  /aw help                   this list');
  say('');
  say('Every value-moving action: the agent calls request_confirmation,');
  say('the user approves, and the transfer happens in the official');
  say('Binance App / web wallet — never inside this module.');
}

/* ==========================================================================
 * Router — parse zagents.info.prompt, /aw <sub> <args…>
 * (sub lowercased, args keep their case — addresses are case-significant)
 * ========================================================================== */

async function main() {
  const info = zagents.info || {};
  const raw = String(info.prompt || '').trim();
  const argv = raw.replace(/^\/aw\b\s*/i, '').trim();
  const sp = argv.search(/\s/);
  const sub = (sp === -1 ? argv : argv.slice(0, sp)).toLowerCase();
  const rest = sp === -1 ? '' : argv.slice(sp + 1).trim();

  const out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };

  const st = await loadState();
  const save = () => saveState(st); // awaited by every mutating body

  if (!sub || sub === 'status') {
    cmdStatus(say, st);
  } else if (sub === 'pair') {
    await cmdPair(say, st, rest, save);
  } else if (sub === 'unpair') {
    await cmdUnpair(say, st, rest, save);
  } else if (sub === 'limit') {
    await cmdLimit(say, st, rest, save);
  } else if (sub === 'network') {
    await cmdNetwork(say, st, rest, save);
  } else if (sub === 'tokens') {
    cmdTokens(say, st);
  } else if (sub === 'checksum') {
    cmdChecksum(say, st, rest);
  } else if (sub === 'spend') {
    await cmdSpend(say, st, rest, save);
  } else if (sub === 'history') {
    cmdHistory(say, st);
  } else if (sub === 'reset') {
    await cmdReset(say, st, rest, save);
  } else {
    // help + every unknown subcommand
    if (sub !== 'help') {
      say('Unknown /aw subcommand: "' + sub + '"');
      say('');
    }
    cmdHelp(say);
  }

  for (const line of out) {
    await zagents.chat.emit(line);
  }
  return { module: 'agentic-wallet', cmd: sub || 'status' };
}

module.exports = main();
