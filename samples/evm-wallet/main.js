/**
 * EVM Wallet — ZAgents chat module (samples/evm-wallet).
 *
 * A per-chat EVM wallet driven entirely by `/wallet` slash commands
 * (manifest `commands: ["wallet"]` — the message is routed to this
 * module instead of the LLM, so wallet operations never consume an
 * AI turn and keep working when the chat agent is unreachable).
 *
 * Design (aligned with the ZAgents Web3 security posture):
 *   - GENERATE-ONLY. `/wallet create` derives a FRESH random account
 *     for THIS chat from the sandbox RNG. There is deliberately NO
 *     import command: an existing private key pasted into a chat
 *     would land in the transcript and the LLM context. The app-wide
 *     rule stands — never ask for, accept, or repeat a seed phrase or
 *     an existing private key.
 *   - Per-chat isolation: the account, the selected network and the
 *     pending transaction live in THIS chat's `zagents.storage` only.
 *     Another chat asks again by design — two chats are two wallets.
 *   - Testnet first: the default network is Sepolia. Mainnets are a
 *     `/wallet network <name>` away, but the README (and every first
 *     report) says it out loud: SAMPLE quality, small amounts only.
 *   - Two-step transfers: `/wallet send` / `/wallet token send` only
 *     BUILD the transaction and show the full summary (from, to,
 *     value, fee, nonce, chain id, max total cost); `/wallet confirm`
 *     signs + broadcasts, `/wallet cancel` discards. Pending offers
 *     expire after 10 minutes and never survive a network switch.
 *   - Allowlisted network access: every RPC call rides
 *     `zagents.http` (permission `network`) and the manifest
 *     `allowedHosts` — only the public endpoints listed in
 *     module.json can be reached, nothing else.
 *
 * Commands:
 *   /wallet                       help
 *   /wallet create                fresh random account for THIS chat
 *   /wallet info | address        address + network + native balance
 *   /wallet balance [contract]    native or ERC-20 balance
 *   /wallet network               current network + the full list
 *   /wallet network <name>        switch network (drops pending tx)
 *   /wallet gas                   gas price (+ base fee when available)
 *   /wallet send <to> <amount>    build a native transfer -> summary
 *   /wallet token <contract>      ERC-20 symbol / decimals / balance
 *   /wallet token send <c> <t> <a>  build an ERC-20 transfer -> summary
 *   /wallet confirm               sign + broadcast the pending tx
 *   /wallet cancel                discard the pending tx
 *   /wallet tx <hash>             receipt lookup (mined or pending)
 *   /wallet export confirm        reveal THIS chat's private key
 *                                 (two-step, loud warnings)
 *   /wallet reset confirm         wipe THIS chat's wallet state
 *   /wallet faucets               testnet faucet links
 *
 * Zero npm dependencies — Keccak-256, secp256k1 (BigInt), RFC 6979
 * deterministic nonces, RLP and EIP-55 are implemented inline.
 * Requires the ZAgents module runtime (zagents.storage / http / chat).
 * ==========================================================================*/

'use strict';

/* ==========================================================================
 * Keccak-256 (original Keccak padding 0x01 — NOT NIST SHA3's 0x06).
 * BigInt lanes (25 x uint64), rate 1088 bits (136 bytes) for 256-bit output.
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
 * SHA-256 (for RFC 6979 nonces only) + HMAC-SHA256.
 * RFC 6979 is standardized over HMAC with the SHA family — using it makes
 * our signatures byte-identical to ethers.js / the canonical EIP-155
 * example for the same (key, hash) pair.
 * ========================================================================== */

const _SHA_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

function _rotr32(x, n) {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

/** sha256(Uint8Array) -> Uint8Array(32) */
function sha256(bytes) {
  const len = bytes.length;
  const padded = new Uint8Array((((len + 8) >> 6) + 1) << 6);
  padded.set(bytes);
  padded[len] = 0x80;
  const dv = new DataView(padded.buffer);
  dv.setUint32(padded.length - 8, Math.floor(len / 0x20000000));
  dv.setUint32(padded.length - 4, (len << 3) >>> 0);
  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  const w = new Uint32Array(64);
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4);
    for (let i = 16; i < 64; i++) {
      const s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a = h[0], b = h[1], c = h[2], d = h[3];
    let e = h[4], f = h[5], g = h[6], hh = h[7];
    for (let i = 0; i < 64; i++) {
      const S1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + S1 + ch + _SHA_K[i] + w[i]) >>> 0;
      const S0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  const out = new Uint8Array(32);
  const odv = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) odv.setUint32(i * 4, h[i]);
  return out;
}

function _hmacSha256(keyBytes, msgBytes) {
  const B = 64;
  const k = keyBytes.length > B ? sha256(keyBytes) : keyBytes;
  const ipad = new Uint8Array(B);
  const opad = new Uint8Array(B);
  ipad.set(k);
  opad.set(k);
  for (let i = 0; i < B; i++) {
    ipad[i] ^= 0x36;
    opad[i] ^= 0x5c;
  }
  return sha256(_concatBytes(opad, sha256(_concatBytes(ipad, msgBytes))));
}

/* ==========================================================================
 * HMAC-Keccak256 (block size = keccak rate 136) — general helper kept for
 * completeness; RFC 6979 itself uses HMAC-SHA256 above.
 * ========================================================================== */

function _hmacKeccak256(keyBytes, msgBytes) {
  const B = _KECCAK_RATE;
  let k = keyBytes.length > B ? keccak256(keyBytes) : keyBytes;
  const ipad = new Uint8Array(B);
  const opad = new Uint8Array(B);
  ipad.set(k);
  opad.set(k);
  for (let i = 0; i < B; i++) {
    ipad[i] ^= 0x36;
    opad[i] ^= 0x5c;
  }
  const inner = new Uint8Array(B + msgBytes.length);
  inner.set(ipad);
  inner.set(msgBytes, B);
  const innerHash = keccak256(inner);
  const outer = new Uint8Array(B + 32);
  outer.set(opad);
  outer.set(innerHash, B);
  return keccak256(outer);
}

function _concatBytes(...parts) {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function _u8(n) {
  return new Uint8Array([n]);
}

/* ==========================================================================
 * Hex / bytes helpers
 * ========================================================================== */

const _HEX = '0123456789abcdef';

function bytesToHex(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += _HEX[bytes[i] >> 4] + _HEX[bytes[i] & 15];
  }
  return out;
}

function hexToBytes(hex) {
  const h = hex.startsWith('0x') || hex.startsWith('0X') ? hex.slice(2) : hex;
  if (h.length % 2 !== 0) throw new Error('odd-length hex string');
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) {
    const hi = parseInt(h[i * 2], 16);
    const lo = parseInt(h[i * 2 + 1], 16);
    if (Number.isNaN(hi) || Number.isNaN(lo)) {
      throw new Error('invalid hex character');
    }
    out[i] = (hi << 4) | lo;
  }
  return out;
}

function asciiToBytes(s) {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
  return out;
}

function bytesToBigInt(bytes) {
  let v = 0n;
  for (let i = 0; i < bytes.length; i++) v = (v << 8n) | BigInt(bytes[i]);
  return v;
}

function bigIntToBytes(v, length) {
  const out = new Uint8Array(length);
  let x = v;
  for (let i = length - 1; i >= 0; i--) {
    out[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return out;
}

/** Minimal big-endian bytes (no leading zeros; 0 -> empty). */
function bigIntToMinBytes(v) {
  if (v === 0n) return new Uint8Array(0);
  let hex = v.toString(16);
  if (hex.length % 2 !== 0) hex = '0' + hex;
  return hexToBytes(hex);
}

/** Minimal big-endian hex WITHOUT 0x prefix ('' for zero) — RLP input. */
function bigIntToMinHex(v) {
  return bytesToHex(bigIntToMinBytes(v));
}

function padHex32(hex) {
  const h = hex.startsWith('0x') ? hex.slice(2) : hex;
  if (h.length > 64) throw new Error('value wider than 32 bytes');
  return '0'.repeat(64 - h.length) + h;
}

/* ==========================================================================
 * secp256k1 (BigInt, affine coordinates)
 * ========================================================================== */

const _P = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
const _N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const _G = {
  x: 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n,
  y: 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n,
};
const _INF = null; // point at infinity

function mod(a, m) {
  const r = a % m;
  return r >= 0n ? r : r + m;
}

/** Modular inverse via the extended Euclidean algorithm. */
function inv(a, m) {
  let g0 = mod(a, m);
  let g1 = m;
  let x0 = 1n;
  let x1 = 0n;
  while (g1 !== 0n) {
    const q = g0 / g1;
    const g2 = g0 - q * g1;
    const x2 = x0 - q * x1;
    g0 = g1;
    g1 = g2;
    x0 = x1;
    x1 = x2;
  }
  if (g0 !== 1n) throw new Error('modular inverse does not exist');
  return mod(x0, m);
}

function _ptDouble(p) {
  if (!p || p.y === 0n) return _INF;
  const l = mod(3n * p.x * p.x * inv(2n * p.y, _P), _P);
  const x = mod(l * l - 2n * p.x, _P);
  const y = mod(l * (p.x - x) - p.y, _P);
  return { x, y };
}

function _ptAdd(p1, p2) {
  if (!p1) return p2;
  if (!p2) return p1;
  if (p1.x === p2.x) {
    if (mod(p1.y + p2.y, _P) === 0n) return _INF;
    return _ptDouble(p1);
  }
  const l = mod((p2.y - p1.y) * inv(mod(p2.x - p1.x, _P), _P), _P);
  const x = mod(l * l - p1.x - p2.x, _P);
  const y = mod(l * (p1.x - x) - p1.y, _P);
  return { x, y };
}

function _scalarMult(k, p) {
  let r = _INF;
  let addend = p;
  let n = k;
  while (n > 0n) {
    if (n & 1n) r = _ptAdd(r, addend);
    addend = _ptDouble(addend);
    n >>= 1n;
  }
  return r;
}

/** Private key (BigInt, 1 <= d < N) -> uncompressed public key {x, y}. */
function privToPub(d) {
  return _scalarMult(d, _G);
}

/** Public key -> 20-byte Ethereum address (last 20 bytes of keccak(x||y)). */
function pubToAddressBytes(pub) {
  const pub64 = _concatBytes(bigIntToBytes(pub.x, 32), bigIntToBytes(pub.y, 32));
  const hash = keccak256(pub64);
  return hash.slice(12);
}

/** RFC 6979 deterministic nonce (HMAC-SHA256), first valid candidate. */
function _rfc6979K(privBytes, msgHash) {
  const xOct = bigIntToBytes(bytesToBigInt(privBytes), 32);
  const hOct = bigIntToBytes(mod(bytesToBigInt(msgHash), _N), 32);
  let v = new Uint8Array(32).fill(1);
  let k = new Uint8Array(32);
  k = _hmacSha256(k, _concatBytes(v, _u8(0x00), xOct, hOct));
  v = _hmacSha256(k, v);
  k = _hmacSha256(k, _concatBytes(v, _u8(0x01), xOct, hOct));
  v = _hmacSha256(k, v);
  for (;;) {
    v = _hmacSha256(k, v);
    const candidate = bytesToBigInt(v);
    if (candidate > 0n && candidate < _N) return candidate;
    k = _hmacSha256(k, _concatBytes(v, _u8(0x00)));
    v = _hmacSha256(k, v);
  }
}

/**
 * ECDSA sign (deterministic RFC 6979 nonce, low-s normalized).
 * Returns { r, s, recid } where recid is the y-parity recovery id (0/1).
 */
function ecdsaSign(privBytes, msgHash) {
  const d = bytesToBigInt(privBytes);
  if (d === 0n || d >= _N) throw new Error('private key out of range');
  const z = bytesToBigInt(msgHash);
  const k = _rfc6979K(privBytes, msgHash);
  const R = _scalarMult(k, _G);
  if (!R) throw new Error('signing failed (degenerate R)');
  const r = mod(R.x, _N);
  if (r === 0n) throw new Error('signing failed (r = 0)');
  let s = mod(inv(k, _N) * mod(z + r * d, _N), _N);
  let recid = Number(R.y & 1n);
  if (s === 0n) throw new Error('signing failed (s = 0)');
  if (s > _N / 2n) {
    s = _N - s;
    recid ^= 1;
  }
  return { r, s, recid };
}

/* ==========================================================================
 * RLP encoding (input: hex strings without 0x for bytes / arrays of items)
 * ========================================================================== */

function _hexByte(b) {
  return _HEX[(b >> 4) & 15] + _HEX[b & 15];
}

function rlpEncodeHex(bytesHex) {
  const len = bytesHex.length / 2;
  const first = len > 0 ? parseInt(bytesHex.slice(0, 2), 16) : -1;
  if (len === 1 && first < 0x80) return bytesHex;
  if (len <= 55) return _hexByte(0x80 + len) + bytesHex;
  const lenHex = len.toString(16);
  const lenHexP = lenHex.length % 2 === 0 ? lenHex : '0' + lenHex;
  return _hexByte(0xb7 + lenHexP.length / 2) + lenHexP + bytesHex;
}

function rlpEncodeList(itemsHex) {
  const len = itemsHex.length / 2;
  if (len <= 55) return _hexByte(0xc0 + len) + itemsHex;
  const lenHex = len.toString(16);
  const lenHexP = lenHex.length % 2 === 0 ? lenHex : '0' + lenHex;
  return _hexByte(0xf7 + lenHexP.length / 2) + lenHexP + itemsHex;
}

/** item: hex string = bytes, Array = list, BigInt/Number = scalar. */
function rlpEncode(item) {
  if (Array.isArray(item)) {
    return rlpEncodeList(item.map(rlpEncode).join(''));
  }
  if (typeof item === 'bigint' || typeof item === 'number') {
    return rlpEncodeHex(bigIntToMinHex(BigInt(item)));
  }
  if (typeof item === 'string') {
    return rlpEncodeHex(item.startsWith('0x') ? item.slice(2) : item);
  }
  throw new Error('rlpEncode: unsupported item');
}

/* ==========================================================================
 * EIP-55 mixed-case checksum addresses
 * ========================================================================== */

/** 20 address bytes -> EIP-55 checksummed "0x..." string. */
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
 * Validate + normalize a user-supplied address. Accepts any casing,
 * returns the EIP-55 checksummed form; mixed-case input with a broken
 * checksum is rejected (a typo must never silently burn funds).
 */
function normalizeAddress(input) {
  const raw = String(input || '').trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
    throw new Error('invalid address "' + raw + '" (expected 0x + 40 hex chars)');
  }
  const bytes = hexToBytes(raw);
  const checksummed = toChecksumAddress(bytes);
  const hasUpper = /[A-F]/.test(raw.slice(2));
  const hasLower = /[a-f]/.test(raw.slice(2));
  if (hasUpper && hasLower && raw !== checksummed) {
    throw new Error(
      'address checksum mismatch — expected ' + checksummed +
      ' (mixed-case addresses are checksum-protected; use this exact form or all-lowercase)',
    );
  }
  return checksummed;
}

/* ==========================================================================
 * Amounts — BigInt-only parsing/formatting (no floats, ever)
 * ========================================================================== */

/** "1.5" + 18 decimals -> BigInt wei. Throws on garbage. */
function parseUnits(amountStr, decimals) {
  const s = String(amountStr || '').trim();
  if (!/^\d*(\.\d*)?$/.test(s) || s === '' || s === '.') {
    throw new Error('invalid amount "' + s + '"');
  }
  const dot = s.indexOf('.');
  let intPart = dot === -1 ? s : s.slice(0, dot);
  let fracPart = dot === -1 ? '' : s.slice(dot + 1);
  if (intPart === '') intPart = '0';
  if (fracPart.length > decimals) {
    throw new Error(
      'amount "' + s + '" has more decimals than the unit supports (' +
      decimals + ')',
    );
  }
  while (fracPart.length < decimals) fracPart += '0';
  return BigInt(intPart + fracPart);
}

/** BigInt wei + 18 decimals -> "1.5" (trailing zeros trimmed). */
function formatUnits(value, decimals) {
  const v = BigInt(value);
  if (v < 0n) throw new Error('negative amount');
  let s = v.toString();
  if (decimals === 0) return s;
  s = s.padStart(decimals + 1, '0');
  const i = s.length - decimals;
  const out = s.slice(0, i) + '.' + s.slice(i);
  return out.replace(/\.?0+$/, '');
}

function formatEth(wei) {
  return formatUnits(wei, 18);
}

function parseEth(amountStr) {
  return parseUnits(amountStr, 18);
}

function shortHex(hex, head, tail) {
  const h = String(hex || '');
  if (h.length <= head + tail + 2) return h;
  return h.slice(0, head) + '…' + h.slice(-tail);
}

/* ==========================================================================
 * Entropy — WebCrypto first, keccak-whitened entropy pool as fallback
 * ========================================================================== */

let _entropyCounter = 0;

function randomBytes32() {
  if (
    typeof crypto !== 'undefined' &&
    crypto &&
    typeof crypto.getRandomValues === 'function'
  ) {
    const out = new Uint8Array(32);
    crypto.getRandomValues(out);
    return out;
  }
  // Fallback: mix every entropy source the sandbox offers through
  // keccak-256 (4 rounds). Still logged as a warning by the caller.
  let material = '';
  for (let i = 0; i < 6; i++) {
    material += String(Math.random()) + '|' + String(Math.random()) + '|' +
      String(Date.now()) + '|' +
      String(typeof performance !== 'undefined' ? performance.now() : i) + '|' +
      String((zagents.info && zagents.info.sessionId) || '') + '|' +
      String(i * 2654435761 + _entropyCounter);
  }
  let acc = asciiToBytes(material);
  for (let round = 0; round < 4; round++) {
    acc = keccak256(
      _concatBytes(acc, asciiToBytes('|round|' + round + '|' + _entropyCounter++ + '|' + Date.now())),
    );
  }
  return acc;
}

/* ==========================================================================
 * Networks — every RPC below was verified live (eth_chainId) before
 * shipping; all hosts are covered by the manifest allowedHosts.
 * ========================================================================== */

const NETWORKS = {
  ethereum: {
    chainId: 1,
    name: 'Ethereum',
    symbol: 'ETH',
    rpc: 'https://ethereum-rpc.publicnode.com',
    explorer: 'https://etherscan.io',
  },
  sepolia: {
    chainId: 11155111,
    name: 'Sepolia',
    symbol: 'ETH',
    rpc: 'https://ethereum-sepolia-rpc.publicnode.com',
    explorer: 'https://sepolia.etherscan.io',
    testnet: true,
  },
  bsc: {
    chainId: 56,
    name: 'BNB Smart Chain',
    symbol: 'BNB',
    rpc: 'https://bsc-rpc.publicnode.com',
    explorer: 'https://bscscan.com',
  },
  'bsc-testnet': {
    chainId: 97,
    name: 'BSC Testnet',
    symbol: 'tBNB',
    rpc: 'https://bsc-testnet-rpc.publicnode.com',
    explorer: 'https://testnet.bscscan.com',
    testnet: true,
  },
  polygon: {
    chainId: 137,
    name: 'Polygon PoS',
    symbol: 'POL',
    rpc: 'https://polygon-bor-rpc.publicnode.com',
    explorer: 'https://polygonscan.com',
  },
  arbitrum: {
    chainId: 42161,
    name: 'Arbitrum One',
    symbol: 'ETH',
    rpc: 'https://arb1.arbitrum.io/rpc',
    explorer: 'https://arbiscan.io',
  },
  base: {
    chainId: 8453,
    name: 'Base',
    symbol: 'ETH',
    rpc: 'https://mainnet.base.org',
    explorer: 'https://basescan.org',
  },
  optimism: {
    chainId: 10,
    name: 'OP Mainnet',
    symbol: 'ETH',
    rpc: 'https://mainnet.optimism.io',
    explorer: 'https://optimistic.etherscan.io',
  },
  'base-sepolia': {
    chainId: 84532,
    name: 'Base Sepolia',
    symbol: 'ETH',
    rpc: 'https://base-sepolia-rpc.publicnode.com',
    explorer: 'https://sepolia.basescan.org',
    testnet: true,
  },
  'optimism-sepolia': {
    chainId: 11155420,
    name: 'OP Sepolia',
    symbol: 'ETH',
    rpc: 'https://optimism-sepolia-rpc.publicnode.com',
    explorer: 'https://sepolia-optimism.etherscan.io',
    testnet: true,
  },
};

const DEFAULT_NETWORK = 'sepolia';
const GWEI = 1000000000n;

function networkKey(chainId) {
  for (const key of Object.keys(NETWORKS)) {
    if (NETWORKS[key].chainId === chainId) return key;
  }
  return null;
}

function explorerTx(netKey, hash) {
  const net = NETWORKS[netKey];
  return net && net.explorer ? net.explorer + '/tx/' + hash : null;
}

function explorerAddress(netKey, address) {
  const net = NETWORKS[netKey];
  return net && net.explorer ? net.explorer + '/address/' + address : null;
}

/* ==========================================================================
 * JSON-RPC over zagents.http (permission `network`, manifest allowlist)
 * ========================================================================== */

async function rpc(netKey, method, params) {
  const net = NETWORKS[netKey];
  if (!net) throw new Error('unknown network "' + netKey + '"');
  const res = await zagents.http.request(net.rpc, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: method, params: params }),
    timeoutMs: 25000,
  });
  if (!res.ok) {
    throw new Error('RPC HTTP ' + res.status + ' from ' + net.rpc);
  }
  const parsed = await res.json();
  if (parsed && parsed.error) {
    const msg = (parsed.error && parsed.error.message) || 'RPC error';
    throw new Error(msg + ' (code ' + ((parsed.error && parsed.error.code) || '?') + ')');
  }
  if (!parsed || parsed.result === undefined) {
    throw new Error('malformed RPC response from ' + net.rpc);
  }
  return parsed.result;
}

function hexToBigInt(hex) {
  if (hex === null || hex === undefined) return 0n;
  const h = String(hex).startsWith('0x') ? String(hex).slice(2) : String(hex);
  return h === '' ? 0n : BigInt('0x' + h);
}

async function getNativeBalance(netKey, address) {
  const res = await rpc(netKey, 'eth_getBalance', [address.toLowerCase(), 'latest']);
  return hexToBigInt(res);
}

async function getNonce(netKey, address, tag) {
  const res = await rpc(netKey, 'eth_getTransactionCount', [address.toLowerCase(), tag || 'pending']);
  return hexToBigInt(res);
}

async function getGasPrice(netKey) {
  const res = await rpc(netKey, 'eth_gasPrice', []);
  return hexToBigInt(res);
}

async function estimateGas(netKey, txObject) {
  const res = await rpc(netKey, 'eth_estimateGas', [txObject]);
  return hexToBigInt(res);
}

async function chainIdOf(netKey) {
  const res = await rpc(netKey, 'eth_chainId', []);
  return hexToBigInt(res);
}

/* ==========================================================================
 * ERC-20 helpers (eth_call + minimal ABI: balanceOf / decimals / symbol /
 * transfer)
 * ========================================================================== */

const ERC20 = {
  balanceOf: '0x70a08231',
  decimals: '0x313ce567',
  symbol: '0x95d89b41',
  transfer: '0xa9059cbb',
};

function stripZerosHex(hex) {
  const h = String(hex || '').replace(/^0x/, '');
  const trimmed = h.replace(/^0+/, '');
  return trimmed === '' ? '0' : trimmed;
}

/** Decode an ABI-encoded dynamic `string` return value. */
function decodeAbiString(hex) {
  const h = String(hex || '').replace(/^0x/, '');
  if (h.length < 128) throw new Error('short ABI string payload');
  const len = BigInt('0x' + h.slice(64, 128));
  if (len > 512n) throw new Error('ABI string too long');
  const data = h.slice(128, 128 + Number(len) * 2);
  let out = '';
  for (let i = 0; i < data.length; i += 2) {
    out += String.fromCharCode(parseInt(data.slice(i, i + 2), 16));
  }
  return out;
}

async function erc20Call(netKey, contract, data) {
  const res = await rpc(netKey, 'eth_call', [
    { to: contract.toLowerCase(), data: data },
    'latest',
  ]);
  return String(res || '');
}

async function erc20Balance(netKey, contract, address) {
  const res = await erc20Call(netKey, contract, ERC20.balanceOf + padHex32(address.toLowerCase().slice(2)));
  const h = String(res || '').replace(/^0x/, '');
  if (h === '' || h.replace(/0/g, '') === '') return 0n;
  return hexToBigInt(h);
}

async function erc20Decimals(netKey, contract) {
  const res = await erc20Call(netKey, contract, ERC20.decimals);
  if (String(res || '') === '' || String(res) === '0x') return 18;
  return Number(hexToBigInt(res));
}

async function erc20Symbol(netKey, contract) {
  try {
    const res = await erc20Call(netKey, contract, ERC20.symbol);
    if (String(res || '') === '' || String(res) === '0x') return 'TOKEN';
    return decodeAbiString(res);
  } catch (_) {
    return 'TOKEN';
  }
}

/* ==========================================================================
 * Per-chat state (zagents.storage — private-window isolation)
 * ========================================================================== */

const K_STATE = 'walletState';
const PENDING_TTL_MS = 10 * 60 * 1000; // unconfirmed offers expire after 10 min
const HISTORY_MAX = 25;

async function loadState() {
  const s = await zagents.storage.get(K_STATE);
  return s && typeof s === 'object' ? s : { net: DEFAULT_NETWORK, account: null, pending: null, history: [] };
}

async function saveState(state) {
  if (state.history && state.history.length > HISTORY_MAX) {
    state.history = state.history.slice(-HISTORY_MAX);
  }
  await zagents.storage.set(K_STATE, state);
}

function requireAccount(state) {
  if (!state.account || !state.account.address || !state.account.privateKey) {
    throw new Error(
      'no wallet in THIS chat yet — run /wallet create first (every chat gets its own account; nothing is shared)',
    );
  }
  return state.account;
}

function isHex64(h) {
  return /^0x[0-9a-fA-F]{64}$/.test(String(h || ''));
}

/* ==========================================================================
 * Wallet creation / transaction signing (EIP-155 legacy transfers)
 * ========================================================================== */

/** Fresh random account for THIS chat (WebCrypto RNG, range-checked). */
function generateAccount() {
  let priv = randomBytes32();
  let d = bytesToBigInt(priv);
  let guard = 0;
  while (d === 0n || d >= _N) {
    if (++guard > 16) throw new Error('entropy failure while generating a key');
    priv = randomBytes32();
    d = bytesToBigInt(priv);
  }
  const addrBytes = pubToAddressBytes(privToPub(d));
  return {
    address: toChecksumAddress(addrBytes),
    privateKey: '0x' + bytesToHex(priv),
    createdAt: new Date().toISOString(),
    rng:
      typeof crypto !== 'undefined' && crypto && typeof crypto.getRandomValues === 'function'
        ? 'webcrypto'
        : 'entropy-fallback',
  };
}

/**
 * Build the EIP-155 signing hash for a legacy transaction.
 * fields: { nonce, gasPrice, gas, to, value, data(hex), chainId } — all BigInt
 * except data (hex string, '' when empty) and to (lowercase hex, '' allowed).
 */
function eip155SigningHash(fields) {
  const toHex = fields.to ? fields.to.replace(/^0x/, '').toLowerCase() : '';
  const dataHex = (fields.data || '').replace(/^0x/, '').toLowerCase();
  const unsigned = rlpEncode([
    bigIntToMinHex(fields.nonce),
    bigIntToMinHex(fields.gasPrice),
    bigIntToMinHex(fields.gas),
    toHex,
    bigIntToMinHex(fields.value),
    dataHex,
    bigIntToMinHex(fields.chainId),
    bigIntToMinHex(0n),
    bigIntToMinHex(0n),
  ]);
  return { signingHash: keccak256(hexToBytes(unsigned)), unsignedRlp: unsigned };
}

/** Sign + serialize. Returns the raw transaction hex (0x...). */
function signEip155Transaction(privHex, fields) {
  const { signingHash } = eip155SigningHash(fields);
  const privBytes = hexToBytes(privHex);
  const { r, s, recid } = ecdsaSign(privBytes, signingHash);
  const v = BigInt(fields.chainId) * 2n + 35n + BigInt(recid);
  const toHex = fields.to ? fields.to.replace(/^0x/, '').toLowerCase() : '';
  const dataHex = (fields.data || '').replace(/^0x/, '').toLowerCase();
  const raw = rlpEncode([
    bigIntToMinHex(fields.nonce),
    bigIntToMinHex(fields.gasPrice),
    bigIntToMinHex(fields.gas),
    toHex,
    bigIntToMinHex(fields.value),
    dataHex,
    bigIntToMinHex(v),
    bigIntToMinHex(r),
    bigIntToMinHex(s),
  ]);
  return '0x' + raw;
}

/* ==========================================================================
 * Output helpers — progressive lines via zagents.chat.emit, details via
 * zagents.log, machine-readable summary as the return value.
 * ========================================================================== */

async function out(lines) {
  for (const line of lines) {
    try {
      await zagents.chat.emit(line);
    } catch (_) {
      /* keep going — emit must never kill a run */
    }
  }
}

async function logLine(text) {
  try {
    await zagents.log(text);
  } catch (_) {
    /* keep going */
  }
}

function netBadge(netKey) {
  const net = NETWORKS[netKey] || {};
  return net.testnet ? netKey + ' (TESTNET)' : netKey + ' (MAINNET — real funds!)';
}

function pushHistory(state, entry) {
  if (!Array.isArray(state.history)) state.history = [];
  state.history.push(Object.assign({ ts: new Date().toISOString() }, entry));
}

function gweiLabel(wei) {
  return formatUnits(wei, 9) + ' gwei';
}

/* ==========================================================================
 * Command handlers
 * ========================================================================== */

const HELP_LINES = [
  'EVM Wallet — commands (per-chat wallet, testnet by default):',
  '• /wallet create — generate a FRESH random account for THIS chat',
  '• /wallet info — address, network, native balance',
  '• /wallet balance [tokenContract] — native or ERC-20 balance',
  '• /wallet network — show the network list',
  '• /wallet network <name> — switch (ethereum | sepolia | bsc | bsc-testnet | polygon | arbitrum | base | optimism | base-sepolia | optimism-sepolia)',
  '• /wallet gas — current gas price',
  '• /wallet send <to> <amount> — build a native transfer (shows a full summary; nothing is signed yet)',
  '• /wallet confirm — sign + broadcast the pending transaction',
  '• /wallet cancel — discard the pending transaction',
  '• /wallet token <contract> — token symbol / decimals / balance',
  '• /wallet token send <contract> <to> <amount> — build an ERC-20 transfer',
  '• /wallet tx <hash> — transaction receipt lookup',
  '• /wallet export confirm — reveal THIS chat private key (two-step, read the warning first)',
  '• /wallet reset confirm — wipe THIS chat wallet state',
  '• /wallet faucets — testnet faucet links',
  'Safety: sample module — use testnets and small amounts. This chat transcript is stored by the app; never paste an existing seed phrase or private key anywhere in a chat.',
];

async function cmdCreate(state) {
  if (state.account) {
    await out([
      'This chat already has a wallet: ' + state.account.address,
      'Network: ' + netBadge(state.net),
      'Tip: /wallet info for details, /wallet reset confirm to wipe it first.',
    ]);
    return { ok: true, command: 'create', existed: true, address: state.account.address };
  }
  const account = generateAccount();
  state.account = account;
  pushHistory(state, { kind: 'create', address: account.address, rng: account.rng });
  await saveState(state);
  if (account.rng !== 'webcrypto') {
    await logLine('WARNING: WebCrypto unavailable — key generated from the keccak-whitened entropy fallback.');
  }
  await out([
    'New wallet created for THIS chat (per-chat isolation: no other chat can see or use it).',
    'Address: ' + account.address,
    'Network: ' + netBadge(state.net) + ' — default is the Sepolia testnet, fund it from a faucet (see /wallet faucets).',
    'Store nothing here: the key lives in THIS chat sandbox storage; export it only if you must (/wallet export confirm — the revealed key lands in the chat transcript).',
    'Reminder: sample wallet, demo quality — testnets and small amounts only.',
  ]);
  return { ok: true, command: 'create', address: account.address, network: state.net, rng: account.rng };
}

async function cmdInfo(state) {
  const account = requireAccount(state);
  const net = NETWORKS[state.net] || NETWORKS[DEFAULT_NETWORK];
  await out(['Reading balance from ' + net.rpc + ' …']);
  let balanceLine = '(RPC unreachable — try again later)';
  let balanceWei = null;
  try {
    balanceWei = await getNativeBalance(state.net, account.address);
    balanceLine = formatEth(balanceWei) + ' ' + net.symbol;
  } catch (e) {
    await logLine('balance fetch failed: ' + ((e && e.message) || e));
  }
  const lines = [
    'Wallet (THIS chat only):',
    '• Address: ' + account.address,
    '• Network: ' + netBadge(state.net) + ' — ' + net.name + ' (chain id ' + net.chainId + ')',
    '• Native balance: ' + balanceLine,
    '• Created: ' + account.createdAt + ' (RNG: ' + account.rng + ')',
  ];
  const explorer = explorerAddress(state.net, account.address);
  if (explorer) lines.push('• Explorer: ' + explorer);
  if (state.pending) {
    lines.push('• PENDING transaction waiting for /wallet confirm (or /wallet cancel).');
  }
  await out(lines);
  return {
    ok: true,
    command: 'info',
    address: account.address,
    network: state.net,
    chainId: net.chainId,
    balanceWei: balanceWei === null ? null : balanceWei.toString(),
  };
}

async function cmdBalance(state, args) {
  const account = requireAccount(state);
  const net = NETWORKS[state.net];
  if (args.length === 0) {
    const wei = await getNativeBalance(state.net, account.address);
    await out(['Native balance: ' + formatEth(wei) + ' ' + net.symbol + ' on ' + netBadge(state.net)]);
    return { ok: true, command: 'balance', wei: wei.toString(), symbol: net.symbol };
  }
  const contract = normalizeAddress(args[0]);
  const [decimals, symbol, raw] = await Promise.all([
    erc20Decimals(state.net, contract),
    erc20Symbol(state.net, contract),
    erc20Balance(state.net, contract, account.address),
  ]);
  await out([
    'ERC-20 balance (' + (symbol || 'TOKEN') + ', ' + decimals + ' decimals):',
    '• ' + formatUnits(raw, decimals) + ' ' + (symbol || 'TOKEN'),
    '• Contract: ' + contract,
    '• Network: ' + netBadge(state.net),
  ]);
  return {
    ok: true,
    command: 'balance',
    token: true,
    contract: contract,
    symbol: symbol,
    decimals: decimals,
    raw: raw.toString(),
  };
}

async function cmdNetwork(state, args) {
  if (args.length === 0) {
    const lines = ['Current network: ' + netBadge(state.net) + ' — ' + NETWORKS[state.net].name + ' (chain id ' + NETWORKS[state.net].chainId + ')', 'Available networks:'];
    for (const key of Object.keys(NETWORKS)) {
      const n = NETWORKS[key];
      lines.push('• ' + key + ' — ' + n.name + ' (' + n.chainId + (n.testnet ? ', testnet' : ', MAINNET') + ')');
    }
    lines.push('Switch with /wallet network <name>. A switch drops any pending (unconfirmed) transaction.');
    await out(lines);
    return { ok: true, command: 'network', current: state.net };
  }
  const want = String(args[0] || '').toLowerCase();
  if (!NETWORKS[want]) {
    throw new Error('unknown network "' + want + '" — run /wallet network to list them');
  }
  const dropped = state.pending ? true : false;
  state.net = want;
  state.pending = null; // a pending offer never survives a network switch
  pushHistory(state, { kind: 'network', to: want });
  await saveState(state);
  const net = NETWORKS[want];
  await out([
    'Network switched to ' + netBadge(want) + ' — ' + net.name + ' (chain id ' + net.chainId + ').',
    dropped ? 'The pending transaction on the previous network was dropped — build it again with /wallet send.' : '',
    net.testnet ? 'Testnet — free faucet funds, safe to learn.' : 'MAINNET — every confirmed transfer moves REAL funds. Double-check addresses.',
  ].filter(Boolean));
  return { ok: true, command: 'network', current: want, droppedPending: dropped };
}

async function cmdGas(state) {
  const price = await getGasPrice(state.net);
  const lines = [
    'Gas price on ' + netBadge(state.net) + ': ' + gweiLabel(price) + ' (' + price.toString() + ' wei)',
  ];
  try {
    const block = await rpc(state.net, 'eth_getBlockByNumber', ['latest', false]);
    if (block && block.baseFeePerGas !== undefined) {
      lines.push('Latest block ' + Number(hexToBigInt(block.number)) + ', base fee: ' + gweiLabel(hexToBigInt(block.baseFeePerGas)));
    }
  } catch (_) {
    /* base fee is best-effort */
  }
  await out(lines);
  return { ok: true, command: 'gas', wei: price.toString() };
}

/**
 * Build (never sign) a transfer. kind: 'native' | 'erc20'.
 * Shared by /wallet send and /wallet token send.
 */
async function buildTransfer(state, kind, contract, toInput, amountInput) {
  const account = requireAccount(state);
  const net = NETWORKS[state.net];
  const to = normalizeAddress(toInput);
  let value;
  let data = '';
  let decimals = 18;
  let symbol = net.symbol;

  if (kind === 'erc20') {
    const cDecimals = await erc20Decimals(state.net, contract);
    const cSymbol = await erc20Symbol(state.net, contract);
    decimals = cDecimals;
    symbol = cSymbol;
    value = parseUnits(amountInput, cDecimals);
    if (value === 0n) throw new Error('amount must be greater than zero');
    data = ERC20.transfer + padHex32(to.toLowerCase().slice(2)) + padHex32(value.toString(16));
  } else {
    value = parseEth(amountInput);
    if (value === 0n) throw new Error('amount must be greater than zero');
  }

  await out(['Preparing the transaction (nothing is signed yet) …']);
  const [balance, nonce, gasPrice] = await Promise.all([
    getNativeBalance(state.net, account.address),
    getNonce(state.net, account.address, 'pending'),
    getGasPrice(state.net),
  ]);
  const price = gasPrice + gasPrice / 10n; // +10% headroom
  const nativeValue = kind === 'erc20' ? 0n : value;
  // Pre-check before estimation: real nodes reject eth_estimateGas with
  // "out of funds" when the sender cannot pay — fail with a clear message
  // instead of a cryptic EVM error.
  if (balance < nativeValue || (balance === 0n && kind === 'erc20')) {
    throw new Error(
      'insufficient native balance: the wallet holds ' + formatEth(balance) + ' ' +
      net.symbol + (net.testnet ? ' — fund it from a faucet first (see /wallet faucets)' : ' — fund it first'),
    );
  }
  const txObject = { from: account.address.toLowerCase(), to: (kind === 'erc20' ? contract : to).toLowerCase() };
  if (kind === 'erc20') txObject.data = data;
  else txObject.value = '0x' + value.toString(16);
  let gas;
  try {
    gas = await estimateGas(state.net, txObject);
    gas = gas + gas / 10n; // +10% headroom
  } catch (e) {
    throw new Error('gas estimation failed — ' + ((e && e.message) || e) + ' (reverted transfer? wrong token? insufficient balance?)');
  }
  const fee = gas * price;
  const totalCost = kind === 'erc20' ? fee : value + fee;
  if (balance < totalCost) {
    throw new Error(
      'insufficient native balance: need ' + formatEth(totalCost) + ' ' + net.symbol +
      ' (amount + fee ' + formatEth(fee) + '), have ' + formatEth(balance) + ' ' + net.symbol,
    );
  }

  const pending = {
    kind: kind,
    net: state.net,
    chainId: net.chainId,
    from: account.address,
    to: kind === 'erc20' ? to : to,
    contract: contract || null,
    value: value.toString(),
    valueFormatted: formatUnits(value, decimals),
    symbol: symbol,
    data: data,
    nonce: nonce.toString(),
    gasPrice: price.toString(),
    gas: gas.toString(),
    feeWei: fee.toString(),
    totalCostWei: totalCost.toString(),
    createdAt: Date.now(),
  };
  state.pending = pending;
  await saveState(state);

  const lines = [
    'TRANSACTION SUMMARY — REVIEW BEFORE CONFIRMING',
    '• Network: ' + netBadge(pending.net) + ' (chain id ' + pending.chainId + ')',
    '• From: ' + pending.from,
    '• To: ' + pending.to,
    kind === 'erc20' ? '• Token transfer: ' + pending.valueFormatted + ' ' + pending.symbol + ' (contract ' + pending.contract + ')' : '• Amount: ' + pending.valueFormatted + ' ' + pending.symbol,
    '• Fee cap: ' + formatEth(fee) + ' ' + net.symbol + ' (' + pending.gas + ' gas × ' + gweiLabel(BigInt(pending.gasPrice)) + ')',
    '• Max total cost: ' + formatEth(totalCost) + ' ' + net.symbol,
    '• Nonce: ' + pending.nonce,
    '',
    'Nothing is signed or sent yet. Reply:',
    '• /wallet confirm — sign with THIS chat key and broadcast',
    '• /wallet cancel — discard (the offer also expires in 10 minutes)',
  ];
  await out(lines);
  return { ok: true, command: kind === 'erc20' ? 'token-send' : 'send', pending: pending, needsConfirm: true };
}

async function cmdConfirm(state) {
  requireAccount(state);
  const pending = state.pending;
  if (!pending) {
    throw new Error('no pending transaction — build one with /wallet send <to> <amount>');
  }
  if (pending.net !== state.net) {
    state.pending = null;
    await saveState(state);
    throw new Error('the pending transaction was built on "' + pending.net + '" but the chat switched to "' + state.net + '" — it was dropped, run /wallet send again');
  }
  if (Date.now() - Number(pending.createdAt) > PENDING_TTL_MS) {
    state.pending = null;
    await saveState(state);
    throw new Error('the pending transaction expired (10 minutes) — run /wallet send again');
  }
  const net = NETWORKS[pending.net];
  const [currentNonce, balance] = await Promise.all([
    getNonce(pending.net, pending.from, 'pending'),
    getNativeBalance(pending.net, pending.from),
  ]);
  if (currentNonce !== BigInt(pending.nonce)) {
    state.pending = null;
    await saveState(state);
    throw new Error('account nonce moved (' + pending.nonce + ' → ' + currentNonce + ') — the offer is stale, run /wallet send again');
  }
  const totalCost = BigInt(pending.totalCostWei);
  if (balance < totalCost) {
    state.pending = null;
    await saveState(state);
    throw new Error('balance no longer covers the total cost (' + formatEth(totalCost) + ' ' + net.symbol + ') — offer dropped, fund first or send less');
  }

  await out(['Signing with THIS chat key (RFC 6979 + EIP-155, chain id ' + pending.chainId + ') …']);
  const raw = signEip155Transaction(state.account.privateKey, {
    nonce: BigInt(pending.nonce),
    gasPrice: BigInt(pending.gasPrice),
    gas: BigInt(pending.gas),
    to: pending.to,
    value: BigInt(pending.value),
    data: pending.data || '',
    chainId: BigInt(pending.chainId),
  });
  let hash;
  try {
    hash = await rpc(pending.net, 'eth_sendRawTransaction', [raw]);
  } catch (e) {
    state.pending = null;
    await saveState(state);
    throw new Error('broadcast rejected by the node — ' + ((e && e.message) || e) + ' (the offer was dropped; nothing leaked, funds untouched)');
  }
  state.pending = null;
  pushHistory(state, {
    kind: pending.kind === 'erc20' ? 'token-send' : 'send',
    network: pending.net,
    to: pending.to,
    amount: pending.valueFormatted + ' ' + pending.symbol,
    hash: hash,
  });
  await saveState(state);
  const explorer = explorerTx(pending.net, hash);
  const lines = [
    'Transaction BROADCAST ✅ (see note: sample module — verify on the explorer)',
    '• Hash: ' + hash,
    explorer ? '• Explorer: ' + explorer : '',
    '• ' + pending.valueFormatted + ' ' + pending.symbol + ' → ' + pending.to + ' on ' + netBadge(pending.net),
    '• Wait for 1+ confirmations before relying on it (/wallet tx ' + shortHex(hash, 14, 8) + ' — full hash above).',
  ].filter(Boolean);
  await out(lines);
  return { ok: true, command: 'confirm', hash: hash, network: pending.net, explorer: explorer };
}

async function cmdCancel(state) {
  if (!state.pending) {
    await out(['No pending transaction to cancel.']);
    return { ok: true, command: 'cancel', hadPending: false };
  }
  state.pending = null;
  await saveState(state);
  await out(['Pending transaction discarded. Nothing was signed, nothing left the wallet.']);
  return { ok: true, command: 'cancel', hadPending: true };
}

async function cmdTx(state, args) {
  const hash = String(args[0] || '').trim().toLowerCase();
  if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) {
    throw new Error('expected a transaction hash (0x + 64 hex chars)');
  }
  const receipt = await rpc(state.net, 'eth_getTransactionReceipt', [hash]);
  if (!receipt) {
    let extra = '';
    try {
      const mempool = await rpc(state.net, 'eth_getTransactionByHash', [hash]);
      if (mempool && !mempool.blockNumber) extra = ' It is known to the node (pending in the mempool, nonce ' + Number(hexToBigInt(mempool.nonce)) + ').';
    } catch (_) {
      /* best-effort */
    }
    await out(['Not mined yet for ' + netBadge(state.net) + '.' + extra + ' Check again later or watch the explorer' + (explorerTx(state.net, hash) ? ': ' + explorerTx(state.net, hash) : '.')]);
    return { ok: true, command: 'tx', mined: false, hash: hash };
  }
  const ok = Number(hexToBigInt(receipt.status)) === 1;
  const lines = [
    'Receipt (' + netBadge(state.net) + '):',
    '• Status: ' + (ok ? 'SUCCESS' : 'FAILED / reverted'),
    '• Block: ' + Number(hexToBigInt(receipt.blockNumber)),
    '• Gas used: ' + Number(hexToBigInt(receipt.gasUsed)),
  ];
  if (receipt.effectiveGasPrice !== undefined) {
    lines.push('• Effective gas price: ' + gweiLabel(hexToBigInt(receipt.effectiveGasPrice)));
  }
  if (receipt.from) lines.push('• From: ' + toChecksumAddress(hexToBytes(receipt.from)));
  if (receipt.to) lines.push('• To: ' + toChecksumAddress(hexToBytes(receipt.to)));
  const explorer = explorerTx(state.net, hash);
  if (explorer) lines.push('• Explorer: ' + explorer);
  await out(lines);
  return { ok: true, command: 'tx', mined: true, status: ok ? 1 : 0, block: Number(hexToBigInt(receipt.blockNumber)) };
}

async function cmdToken(state, args) {
  if (args.length === 0) {
    throw new Error('usage: /wallet token <contract> — or /wallet token send <contract> <to> <amount>');
  }
  if (String(args[0]).toLowerCase() === 'send') {
    if (args.length < 4) {
      throw new Error('usage: /wallet token send <contract> <to> <amount>');
    }
    const contract = normalizeAddress(args[1]);
    return buildTransfer(state, 'erc20', contract, args[2], args[3]);
  }
  const contract = normalizeAddress(args[0]);
  requireAccount(state);
  const [decimals, symbol, raw] = await Promise.all([
    erc20Decimals(state.net, contract),
    erc20Symbol(state.net, contract),
    erc20Balance(state.net, contract, state.account.address),
  ]);
  await out([
    'Token on ' + netBadge(state.net) + ':',
    '• Contract: ' + contract,
    '• Symbol: ' + symbol,
    '• Decimals: ' + decimals,
    '• Balance (THIS chat wallet): ' + formatUnits(raw, decimals) + ' ' + symbol,
  ]);
  return { ok: true, command: 'token', contract: contract, symbol: symbol, decimals: decimals, raw: raw.toString() };
}

async function cmdExport(state, args) {
  const account = requireAccount(state);
  if (String(args[0] || '').toLowerCase() !== 'confirm') {
    await out([
      '⚠️ EXPORT WARNING — READ FIRST',
      'This reveals the PRIVATE KEY of THIS chat wallet: ' + account.address,
      'Whoever holds that key owns the funds, forever, on every network — no password, no undo.',
      'The revealed key will be stored in THIS chat transcript by the app (it is how you asked for it).',
      'If you still want it, type exactly: /wallet export confirm',
      'Safer: keep using the wallet inside this chat and fund only small, disposable amounts.',
    ]);
    return { ok: true, command: 'export', revealed: false };
  }
  await out([
    '⚠️ PRIVATE KEY BELOW — ANYONE WHO SEES THIS CHAT OWNS THIS WALLET ⚠️',
    'Address: ' + account.address,
    'Private key: ' + account.privateKey,
    'Move at your own risk. This is a demo wallet; treat the key as burned after use.',
  ]);
  pushHistory(state, { kind: 'export', address: account.address });
  await saveState(state);
  return { ok: true, command: 'export', revealed: true };
}

async function cmdReset(state, args) {
  if (String(args[0] || '').toLowerCase() !== 'confirm') {
    await out([
      'This wipes THIS chat wallet: account, key, pending offer and history.',
      'Funds already sent elsewhere are NOT recoverable from here; the key is destroyed with it.',
      'Type exactly: /wallet reset confirm',
    ]);
    return { ok: true, command: 'reset', wiped: false };
  }
  const had = state.account ? state.account.address : null;
  await zagents.storage.remove(K_STATE);
  await out([
    'Wallet state for THIS chat wiped' + (had ? ' (was ' + had + ')' : '') + '.',
    '/wallet create starts a brand-new account. Nothing was recoverable from this chat even before the wipe — the key is gone for good.',
  ]);
  return { ok: true, command: 'reset', wiped: true, previous: had };
}

const FAUCETS = [
  'Sepolia ETH: https://sepoliafaucet.com · https://faucets.chain.link/sepolia · https://faucet.quicknode.com/sepolia',
  'BSC testnet tBNB: https://testnet.bnbchain.org/faucet-smart',
  'Base Sepolia ETH: https://faucet.quicknode.com/base/sepolia',
  'OP Sepolia ETH: https://faucets.chain.link/optimism-sepolia',
  'Fund THIS chat wallet address first: /wallet info',
];

async function cmdFaucets(state) {
  const lines = ['Testnet faucets (current network: ' + netBadge(state.net) + '):'].concat(FAUCETS);
  await out(lines);
  return { ok: true, command: 'faucets', network: state.net };
}

/* ==========================================================================
 * Dispatch
 * ========================================================================== */

const SUBCOMMANDS = new Set([
  'help', 'create', 'info', 'address', 'balance', 'network', 'gas',
  'send', 'token', 'confirm', 'cancel', 'tx', 'export', 'reset', 'faucets',
]);

async function dispatch(state, cmd, args) {
  switch (cmd) {
    case 'help':
      await out(HELP_LINES);
      return { ok: true, command: 'help' };
    case 'create':
      return cmdCreate(state);
    case 'info':
    case 'address':
      return cmdInfo(state);
    case 'balance':
      return cmdBalance(state, args);
    case 'network':
      return cmdNetwork(state, args);
    case 'gas':
      return cmdGas(state);
    case 'send':
      if (args.length < 2) throw new Error('usage: /wallet send <to> <amount> — e.g. /wallet send 0xabc… 0.01');
      return buildTransfer(state, 'native', null, args[0], args[1]);
    case 'token':
      return cmdToken(state, args);
    case 'confirm':
      return cmdConfirm(state);
    case 'cancel':
      return cmdCancel(state);
    case 'tx':
      if (args.length < 1) throw new Error('usage: /wallet tx <hash>');
      return cmdTx(state, args);
    case 'export':
      return cmdExport(state, args);
    case 'reset':
      return cmdReset(state, args);
    case 'faucets':
      return cmdFaucets(state);
    default:
      await out(['Unknown subcommand "' + cmd + '".'].concat(HELP_LINES));
      return { ok: false, command: cmd, error: 'unknown-subcommand' };
  }
}

/* ==========================================================================
 * Entry point
 * ========================================================================== */

async function main() {
  const info = zagents.info || {};
  const prompt = String(info.prompt || '').trim();
  const tokens = prompt.split(/\s+/).filter(Boolean);

  // "/wallet balance 0x…" -> drop the leading /wallet keyword; the
  // staged-chip path may deliver the message with or without it.
  if (tokens.length > 0 && tokens[0].toLowerCase() === '/wallet') {
    tokens.shift();
  }
  let cmd = tokens.length > 0 ? tokens[0].toLowerCase().replace(/^\//, '') : 'help';
  const args = tokens.slice(1);
  if (!SUBCOMMANDS.has(cmd)) {
    // First message activation: whatever the user typed is not a wallet
    // subcommand — greet with help instead of failing.
    if (cmd !== '') {
      await logLine('prompt did not start with a wallet subcommand — showing help');
      cmd = 'help';
    }
    args.length = 0;
  }

  const state = await loadState();
  if (!NETWORKS[state.net]) state.net = DEFAULT_NETWORK;
  if (!state.history) state.history = [];

  try {
    return await dispatch(state, cmd, args);
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    await out(['Wallet error: ' + msg]);
    await logLine('wallet command failed: ' + cmd + ' — ' + msg);
    return { ok: false, command: cmd, error: msg };
  }
}

module.exports = main();
