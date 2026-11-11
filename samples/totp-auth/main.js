/**
 * Authenticator (TOTP) — RFC 6238 codes generated inside a ZAgents chat
 * (sample module).
 *
 * Demonstrates: a storage-ONLY module (no network — secrets can never
 * leave the device), pure-JS SHA-1/SHA-256/SHA-512 + HMAC (zero npm
 * deps), Base32 secret handling, and a two-step destructive action
 * (remove + confirm) like the EVM wallet's confirm pattern.
 *
 * Commands (manifest `commands: ["otp"]` routes `/otp …` here):
 *   /otp add <label> <base32secret> [digits] [period] [algo]
 *   /otp code [label]     current code(s) + validity countdown
 *   /otp list             accounts + remaining seconds
 *   /otp uri <label>      standard otpauth:// URI (pair with /qr!)
 *   /otp remove <label>   stage a removal … /otp confirm executes
 *   /otp confirm          execute the staged removal
 *   /otp cancel           drop the staged removal
 *   /otp help
 *
 * Security posture:
 * - NO network/files/device/agent permissions — codes and secrets are
 *   computed locally and stored in THIS chat's storage only.
 * - `add` refuses to echo the secret back; `uri` is opt-in.
 * - Labels are per chat: another chat starts with an empty vault.
 */
async function main() {
  const info = zagents.info;
  const raw = (info.prompt || '').trim();
  const argv = raw.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
  const vault = (await zagents.storage.get('otpVault')) || { accounts: [], pending: null };
  let out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };

  try {
    if (!argv || argv === 'help') help(say, vault);
    else if (argv === 'list') listCmd(say, vault);
    else if (argv.startsWith('add ')) await addCmd(say, vault, argv.slice(4).trim());
    else if (argv === 'code') codeCmd(say, vault, null);
    else if (argv.startsWith('code ')) codeCmd(say, vault, argv.slice(5).trim());
    else if (argv.startsWith('uri ')) uriCmd(say, vault, argv.slice(4).trim());
    else if (argv.startsWith('remove ')) await removeCmd(say, vault, argv.slice(7).trim());
    else if (argv === 'confirm') await confirmCmd(say, vault);
    else if (argv === 'cancel') await cancelCmd(say, vault);
    else say('Unknown command — /otp help shows the full list.');
  } catch (e) {
    say('❌ ' + (e && e.message ? e.message : e));
  }

  for (const line of out) await zagents.log(line);
  return { module: 'totp-auth', accounts: vault.accounts.length };
}

// ------------------------------------------------------------------ help

function help(say, vault) {
  say('🔐 Authenticator (TOTP) — ' + vault.accounts.length + ' account(s) in THIS chat. Commands:');
  say('  /otp add <label> <base32secret> [digits] [period] [algo]');
  say('      e.g. /otp add github JBSWY3DPEHPK3PXP  (defaults: 6 digits · 30s · SHA1)');
  say('  /otp code [label]   current code(s) + countdown');
  say('  /otp list           accounts overview');
  say('  /otp uri <label>    otpauth:// URI — pipe it into /qr to migrate');
  say('  /otp remove <label> → /otp confirm   two-step delete');
  say('');
  say('Secrets stay on this device (no network permission) and are scoped');
  say('to THIS chat only.');
}

// --------------------------------------------------------------- commands

async function addCmd(say, vault, arg) {
  const parts = arg.split(/\s+/);
  const label = parts[0];
  const secret = parts[1];
  if (!label || !secret) throw new Error('Usage: /otp add <label> <base32secret> [digits] [period] [algo]');
  if (vault.accounts.some(a => a.label.toLowerCase() === label.toLowerCase())) {
    throw new Error('Label "' + label + '" already exists — remove it first.');
  }
  const clean = normalizeBase32(secret);
  if (clean.length < 8) throw new Error('Secret too short — an account secret is at least 8 Base32 chars.');
  const bytes = base32Decode(clean);
  if (bytes.length < 5) throw new Error('Secret decodes to fewer than 5 bytes — check for typos.');
  const digits = clampInt(parts[2], 6, 6, 8);
  const period = clampInt(parts[3], 30, 15, 120);
  const algo = (parts[4] || 'SHA1').toUpperCase();
  if (!['SHA1', 'SHA256', 'SHA512'].includes(algo)) {
    throw new Error('Unsupported algo "' + parts[4] + '" — use SHA1, SHA256 or SHA512.');
  }
  vault.accounts.push({ label: label, secret: clean, digits: digits, period: period, algo: algo, addedAt: new Date().toISOString() });
  await save(vault);
  say('✅ Added "' + label + '" — ' + digits + ' digits · ' + period + 's · ' + algo +
      ' · ' + bytes.length + '-byte secret.');
  const acc = vault.accounts[vault.accounts.length - 1];
  const { code, remaining } = totp(acc, Math.floor(Date.now() / 1000));
  say('   Current code: ' + code + ' (valid ' + remaining + 's) — /otp code ' + label);
}

function codeCmd(say, vault, label) {
  const now = Math.floor(Date.now() / 1000);
  const accounts = label
    ? vault.accounts.filter(a => a.label.toLowerCase() === label.toLowerCase())
    : vault.accounts;
  if (!accounts.length) {
    say(label ? '❌ No account labeled "' + label + '" — /otp list.' : 'Vault is empty — /otp add <label> <secret> first.');
    return;
  }
  for (const acc of accounts) {
    const { code, remaining } = totp(acc, now);
    say('🔑 ' + acc.label + ': ' + code + '   (' + remaining + 's left · ' + acc.algo + ' · ' + acc.digits + 'd)');
  }
}

function listCmd(say, vault) {
  if (!vault.accounts.length) {
    say('🔐 No accounts in this chat yet — /otp add <label> <base32secret>');
    say('   (Get the secret from the service\'s 2FA setup page — "can\'t scan?")');
    return;
  }
  const now = Math.floor(Date.now() / 1000);
  say('🔐 Accounts in THIS chat:');
  for (const acc of vault.accounts) {
    const { remaining } = totp(acc, now);
    say('   • ' + acc.label + ' — ' + acc.digits + ' digits · ' + acc.period + 's · ' + acc.algo +
        ' · next code in ' + remaining + 's');
  }
  if (vault.pending) say('   ⚠️ Removal of "' + vault.pending.label + '" is staged — /otp confirm / /otp cancel');
}

function uriCmd(say, vault, label) {
  const acc = vault.accounts.find(a => a.label.toLowerCase() === (label || '').toLowerCase());
  if (!acc) { say('❌ No account labeled "' + label + '" — /otp list.'); return; }
  const params = new URLSearchParams({
    secret: acc.secret,
    issuer: 'ZAgents',
    algorithm: acc.algo,
    digits: String(acc.digits),
    period: String(acc.period),
  });
  say('📤 otpauth://totp/' + encodeURIComponent(acc.label) + '?' + params.toString());
  say('   Pipe into the QR module to migrate: /qr ' +
      'otpauth://totp/' + encodeURIComponent(acc.label) + '?' + params.toString());
}

async function removeCmd(say, vault, label) {
  const acc = vault.accounts.find(a => a.label.toLowerCase() === (label || '').toLowerCase());
  if (!acc) { say('❌ No account labeled "' + label + '" — /otp list.'); return; }
  vault.pending = { label: acc.label, at: Date.now() };
  await save(vault);
  say('⚠️ Remove "' + acc.label + '" from this chat\'s vault?');
  say('   Type /otp confirm within 10 minutes to delete it, or /otp cancel.');
}

async function confirmCmd(say, vault) {
  const p = vault.pending;
  if (!p || Date.now() - p.at > 10 * 60 * 1000) {
    vault.pending = null;
    await save(vault);
    say('Nothing pending (or expired) — /otp remove <label> first.');
    return;
  }
  const before = vault.accounts.length;
  vault.accounts = vault.accounts.filter(a => a.label !== p.label);
  vault.pending = null;
  await save(vault);
  say('🗑️ Removed "' + p.label + '" (' + (before - vault.accounts.length) + ' account, ' + vault.accounts.length + ' left).');
}

async function cancelCmd(say, vault) {
  if (!vault.pending) { say('Nothing staged.'); return; }
  say('↩️ Cancelled — "' + vault.pending.label + '" stays.');
  vault.pending = null;
  await save(vault);
}

// --------------------------------------------------------- RFC 6238 core

function totp(acc, unixTime) {
  const counter = Math.floor(unixTime / acc.period);
  // RFC 4226/6238: the moving factor is an 8-BYTE big-endian counter
  const ctr = [
    (counter / 2 ** 56) & 255, (counter / 2 ** 48) & 255,
    (counter / 2 ** 40) & 255, (counter / 2 ** 32) & 255,
    (counter >>> 24) & 255, (counter >>> 16) & 255,
    (counter >>> 8) & 255, counter & 255,
  ];
  const hmac = hmacSha(acc.algo, ctr, base32Decode(acc.secret));
  const offset = hmac[hmac.length - 1] & 0x0f;
  const bin =
    ((hmac[offset] & 0x7f) << 24) |
    (hmac[offset + 1] << 16) |
    (hmac[offset + 2] << 8) |
    hmac[offset + 3];
  const code = String(bin % (10 ** acc.digits)).padStart(acc.digits, '0');
  const remaining = acc.period - (unixTime % acc.period);
  return { code: code, remaining: remaining };
}

// ---------------------------------------------------------------- Base32

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function normalizeBase32(s) {
  return String(s || '').toUpperCase().replace(/[\s\-=]/g, '');
}

function base32Decode(s) {
  let bits = 0, value = 0;
  const out = [];
  for (const ch of s) {
    const idx = B32.indexOf(ch);
    if (idx < 0) throw new Error('Invalid Base32 character: "' + ch + '"');
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return out;
}

// ------------------------------------- SHA-1/256/512 + HMAC (pure JS)

function hmacSha(algo, message, key) {
  const blockSize = algo === 'SHA512' ? 128 : 64;
  let k = key.slice();
  if (k.length > blockSize) k = sha(algo, k);
  while (k.length < blockSize) k.push(0);
  const oKey = k.map(b => b ^ 0x5c);
  const iKey = k.map(b => b ^ 0x36);
  const inner = sha(algo, iKey.concat(message));
  return sha(algo, oKey.concat(inner));
}

function sha(algo, bytes) {
  if (algo === 'SHA1') return sha1(bytes);
  if (algo === 'SHA256') return sha256(bytes);
  if (algo === 'SHA512') return sha512(bytes);
  throw new Error('Unknown algorithm ' + algo);
}

function u32(a, i) { return (a[i] << 24) | (a[i + 1] << 16) | (a[i + 2] << 8) | a[i + 3]; }
function rotr32(x, n) { return ((x >>> n) | (x << (32 - n))) >>> 0; }

function sha1(msg) {
  const h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
  const ml = msg.length * 8;
  const data = msg.slice();
  data.push(0x80);
  while (data.length % 64 !== 56) data.push(0);
  for (let i = 7; i >= 0; i--) data.push((ml / 2 ** (i * 8)) & 255); // 64-bit big-endian length (fits: HMAC msgs are tiny)
  const w = new Array(80);
  for (let off = 0; off < data.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = u32(data, off + i * 4);
    for (let i = 16; i < 80; i++) {
      w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]);
      w[i] = (w[i] << 1) | (w[i] >>> 31);
    }
    let [a, b, c, d, e] = h;
    for (let i = 0; i < 80; i++) {
      let f, k;
      if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
      else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
      else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
      else { f = b ^ c ^ d; k = 0xca62c1d6; }
      f = (f + e + k + w[i] + ((a << 5) | (a >>> 27))) | 0;
      e = d; d = c; c = (b << 30) | (b >>> 2); b = a; a = f;
    }
    h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0;
    h[3] = (h[3] + d) | 0; h[4] = (h[4] + e) | 0;
  }
  return h.flatMap(x => [(x >>> 24) & 255, (x >>> 16) & 255, (x >>> 8) & 255, x & 255]);
}

const K256 = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function sha256(msg) {
  const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const ml = msg.length * 8;
  const data = msg.slice();
  data.push(0x80);
  while (data.length % 64 !== 56) data.push(0);
  for (let i = 7; i >= 0; i--) data.push((ml / 2 ** (i * 8)) & 255);
  const w = new Array(64);
  for (let off = 0; off < data.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = u32(data, off + i * 4);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i++) {
      const S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + S1 + ch + K256[i] + w[i]) | 0;
      const S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) | 0;
      hh = g; g = f; f = e; e = (d + t1) | 0;
      d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0; h[3] = (h[3] + d) | 0;
    h[4] = (h[4] + e) | 0; h[5] = (h[5] + f) | 0; h[6] = (h[6] + g) | 0; h[7] = (h[7] + hh) | 0;
  }
  return h.flatMap(x => [(x >>> 24) & 255, (x >>> 16) & 255, (x >>> 8) & 255, x & 255]);
}

function sha512(msg) {
  // 64-bit SHA-512 via 32-bit pairs (hi/lo) — only used for short HMAC
  // messages in TOTP, so the straightforward implementation is fine.
  const K = K512;
  const H = [0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
             0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n];
  const ml = BigInt(msg.length * 8);
  const data = msg.slice();
  data.push(0x80);
  while (data.length % 128 !== 112) data.push(0);
  for (let i = 15; i >= 0; i--) data.push(Number((ml >> BigInt(i * 8)) & 255n));
  const W = new Array(80);
  for (let off = 0; off < data.length; off += 128) {
    for (let i = 0; i < 16; i++) {
      let v = 0n;
      for (let j = 0; j < 8; j++) v = (v << 8n) | BigInt(data[off + i * 8 + j]);
      W[i] = v;
    }
    for (let i = 16; i < 80; i++) {
      const s0 = rotr64(W[i - 15], 1) ^ rotr64(W[i - 15], 8) ^ shr64(W[i - 15], 7);
      const s1 = rotr64(W[i - 2], 19) ^ rotr64(W[i - 2], 61) ^ shr64(W[i - 2], 6);
      W[i] = (W[i - 16] + s0 + W[i - 7] + s1) & 0xffffffffffffffffn;
    }
    let [a, b, c, d, e, f, g, h] = H;
    for (let i = 0; i < 80; i++) {
      const S1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[i] + W[i]) & 0xffffffffffffffffn;
      const S0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) & 0xffffffffffffffffn;
      h = g; g = f; f = e; e = (d + t1) & 0xffffffffffffffffn;
      d = c; c = b; b = a; a = (t1 + t2) & 0xffffffffffffffffn;
    }
    const next = [a, b, c, d, e, f, g, h];
    for (let i = 0; i < 8; i++) H[i] = (H[i] + next[i]) & 0xffffffffffffffffn;
  }
  const out = [];
  for (const x of H) for (let i = 7; i >= 0; i--) out.push(Number((x >> BigInt(i * 8)) & 255n));
  return out;
}

const M64 = 0xffffffffffffffffn;
function rotr64(x, n) { return ((x >> BigInt(n)) | (x << BigInt(64 - n))) & M64; }
function shr64(x, n) { return (x >> BigInt(n)) & M64; }

const K512 = [
  0x428a2f98d728ae22n, 0x7137449123ef65cdn, 0xb5c0fbcfec4d3b2fn, 0xe9b5dba58189dbbcn,
  0x3956c25bf348b538n, 0x59f111f1b605d019n, 0x923f82a4af194f9bn, 0xab1c5ed5da6d8118n,
  0xd807aa98a3030242n, 0x12835b0145706fben, 0x243185be4ee4b28cn, 0x550c7dc3d5ffb4e2n,
  0x72be5d74f27b896fn, 0x80deb1fe3b1696b1n, 0x9bdc06a725c71235n, 0xc19bf174cf692694n,
  0xe49b69c19ef14ad2n, 0xefbe4786384f25e3n, 0x0fc19dc68b8cd5b5n, 0x240ca1cc77ac9c65n,
  0x2de92c6f592b0275n, 0x4a7484aa6ea6e483n, 0x5cb0a9dcbd41fbd4n, 0x76f988da831153b5n,
  0x983e5152ee66dfabn, 0xa831c66d2db43210n, 0xb00327c898fb213fn, 0xbf597fc7beef0ee4n,
  0xc6e00bf33da88fc2n, 0xd5a79147930aa725n, 0x06ca6351e003826fn, 0x142929670a0e6e70n,
  0x27b70a8546d22ffcn, 0x2e1b21385c26c926n, 0x4d2c6dfc5ac42aedn, 0x53380d139d95b3dfn,
  0x650a73548baf63den, 0x766a0abb3c77b2a8n, 0x81c2c92e47edaee6n, 0x92722c851482353bn,
  0xa2bfe8a14cf10364n, 0xa81a664bbc423001n, 0xc24b8b70d0f89791n, 0xc76c51a30654be30n,
  0xd192e819d6ef5218n, 0xd69906245565a910n, 0xf40e35855771202an, 0x106aa07032bbd1b8n,
  0x19a4c116b8d2d0c8n, 0x1e376c085141ab53n, 0x2748774cdf8eeb99n, 0x34b0bcb5e19b48a8n,
  0x391c0cb3c5c95a63n, 0x4ed8aa4ae3418acbn, 0x5b9cca4f7763e373n, 0x682e6ff3d6b2b8a3n,
  0x748f82ee5defb2fcn, 0x78a5636f43172f60n, 0x84c87814a1f0ab72n, 0x8cc702081a6439ecn,
  0x90befffa23631e28n, 0xa4506cebde82bde9n, 0xbef9a3f7b2c67915n, 0xc67178f2e372532bn,
  0xca273eceea26619cn, 0xd186b8c721c0c207n, 0xeada7dd6cde0eb1en, 0xf57d4f7fee6ed178n,
  0x06f067aa72176fban, 0x0a637dc5a2c898a6n, 0x113f9804bef90daen, 0x1b710b35131c471bn,
  0x28db77f523047d84n, 0x32caab7b40c72493n, 0x3c9ebe0a15c9bebcn, 0x431d67c49c100d4cn,
  0x4cc5d4becb3e42b6n, 0x597f299cfc657e2an, 0x5fcb6fab3ad6faecn, 0x6c44198c4a475817n,
];

// ---------------------------------------------------------------- helpers

async function save(vault) {
  await zagents.storage.set('otpVault', vault);
}

function clampInt(v, dflt, min, max) {
  const n = parseInt(v, 10);
  if (isNaN(n)) return dflt;
  return Math.min(max, Math.max(min, n));
}

module.exports = main();
