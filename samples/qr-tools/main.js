/**
 * QR Code — real, scannable QR codes drawn as Unicode block art in the
 * ZAgents chat (sample module).
 *
 * Demonstrates: a ZERO-permission module (no storage/network/files —
 * `zagents.log` is always available) and a complete pure-JS QR encoder:
 * UTF-8 byte mode, versions 1-25, ECC levels L/M/Q/H, Reed-Solomon over
 * GF(256), block interleaving, format/version BCH bits, all 8 mask
 * patterns with spec penalty scoring, and half-block rendering sized for
 * a phone camera pointed at the screen.
 *
 * Commands (manifest `commands: ["qr"]` routes `/qr …` here):
 *   /qr <text>                     encode text/URL at ECC level M (default)
 *   /qr l <text> · m · q · h       pick the ECC level explicitly
 *   /qr wifi <ssid> | <pass> [| WPA|WEP|nopass]   WIFI: payload
 *   /qr help                       this help
 *
 * The output is deliberately plain text: each QR pixel pair becomes one
 * Unicode half-block row (▀ ▄ █  ), so a version-5 code is ~22 chat rows
 * and every modern phone camera scans it off the screen.
 */
async function main() {
  const info = zagents.info;
  const raw = (info.prompt || '').trim();
  const argv = raw.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
  let out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };

  try {
    if (!argv || argv === 'help') {
      help(say);
    } else if (/^(l|m|q|h)\s+/i.test(argv)) {
      const level = argv[0].toUpperCase();
      draw(say, argv.slice(1).trim(), level);
    } else if (/^wifi\s+/i.test(argv)) {
      draw(say, wifiPayload(argv.slice(4).trim()), 'M', 'Wi-Fi join code');
    } else if (/^(url)\s+/i.test(argv)) {
      draw(say, argv.slice(4).trim(), 'M');
    } else {
      draw(say, argv, 'M');
    }
  } catch (e) {
    say('❌ ' + (e && e.message ? e.message : e));
    say('   Try shorter text or a lower ECC level: /qr l <text>');
  }

  for (const line of out) await zagents.log(line);
  return { module: 'qr-tools', handled: argv.slice(0, 40) };
}

// ------------------------------------------------------------------ help

function help(say) {
  say('⬛ QR Code — scannable QR rendered as text in this chat. Commands:');
  say('  /qr <text>            encode any text or URL (ECC M)');
  say('  /qr l|m|q|h <text>    pick error-correction level explicitly');
  say('  /qr wifi <ssid> | <password> [| WPA|WEP|nopass]');
  say('');
  say('The code prints as ▀▄█ block art — point a phone camera at it.');
  say('Zero permissions: pure computation, nothing stored, nothing sent.');
  say('Max payload ~929 bytes (ECC L) / ~691 (M) / ~509 (Q) / ~351 (H).');
}

function wifiPayload(arg) {
  const parts = arg.split('|').map(s => s.trim());
  const ssid = parts[0] || '';
  const pass = parts[1] || '';
  const type = (parts[2] || (pass ? 'WPA' : 'nopass')).toUpperCase();
  if (!ssid) throw new Error('Wi-Fi QR needs an SSID: /qr wifi MyNetwork | MyPassword');
  if ((type === 'WPA' || type === 'WEP') && !pass) {
    throw new Error(type + ' needs a password: /qr wifi <ssid> | <password> | ' + type);
  }
  const esc = (s) => s.replace(/([\\;,:"])/g, '\\$1');
  let s = 'WIFI:T:' + type + ';S:' + esc(ssid) + ';';
  if (type !== 'NOPASS' && pass) s += 'P:' + esc(pass) + ';';
  s += ';';
  return s;
}

// =============================================================== encoder

const ECC_LEVELS = { L: 0, M: 1, Q: 2, H: 3 };
const ECL_FORMAT_BITS = { 0: 1, 1: 0, 2: 3, 3: 2 }; // L M Q H → format bits
const MAX_VERSION = 25;

// ECC codewords per block, [level][version-1]
const ECC_CODEWORDS_PER_BLOCK = [
  [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
  [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
];

// number of error-correction blocks, [level][version-1]
const NUM_ECC_BLOCKS = [
  [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
  [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
  [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
  [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
];

function utf8Bytes(s) {
  const out = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.codePointAt(i);
    if (c > 0xffff) i++; // consume surrogate pair
    if (c < 0x80) out.push(c);
    else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    } else if (c < 0x10000) {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    } else {
      out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
  }
  return out;
}

function byteCapacity(ver, lvl) {
  // data codewords × 8 bits minus mode (4) + char count (8 or 16) bits
  const cw = dataCodewords(ver, lvl);
  return Math.floor((cw * 8 - (ver <= 9 ? 12 : 20)) / 8);
}

function pickVersion(text, levelName) {
  const lvl = ECC_LEVELS[levelName];
  const n = utf8Bytes(text).length;
  for (let v = 1; v <= MAX_VERSION; v++) {
    if (n <= byteCapacity(v, lvl)) return v;
  }
  throw new Error('Text too long for one QR (' + n + ' bytes at level ' + levelName +
    ' — max ' + byteCapacity(MAX_VERSION, lvl) + '). Split it or use /qr l.');
}

// total codewords available in a version (raw modules / 8)
function totalCodewords(ver) {
  let result = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const numAlign = Math.floor(ver / 7) + 2;
    result -= (25 * numAlign - 10) * numAlign - 55;
  }
  if (ver >= 7) result -= 36;
  return Math.floor(result / 8);
}

function alignmentPositions(ver) {
  if (ver === 1) return [];
  const size = ver * 4 + 17;
  const numAlign = Math.floor(ver / 7) + 2;
  const step = ver === 32
    ? 26
    : Math.floor((ver * 4 + numAlign * 2 + 1) / (numAlign * 2 - 2)) * 2;
  const positions = [];
  for (let i = 0, pos = size - 7; i < numAlign - 1; i++, pos -= step) positions.push(pos);
  positions.push(6);
  positions.sort((a, b) => a - b);
  return positions;
}

// ------------------------------------------------------------- GF(256)

const EXP = new Array(512);
const LOG = new Array(256);
(function initTables() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

const gmul = (a, b) => (a && b) ? EXP[(LOG[a] + LOG[b]) % 255] : 0;

function rsRemainder(data, degree) {
  // Build the generator polynomial g(x) = ∏(x - α^i), i = 0..degree-1,
  // as coefficients highest-degree-first: gen[0] = x^degree coeff (always 1).
  let gen = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(gen.length + 1).fill(0);
    for (let j = 0; j < gen.length; j++) {
      next[j] ^= gen[j];                    // multiply by x
      next[j + 1] ^= gmul(gen[j], EXP[i]);  // multiply by the constant α^i
    }
    gen = next;
  }
  // Classic shift-register division: gen[1..degree] are exactly the
  // divisor coefficients (x^(degree-1) … x^0) — the implicit leading term
  // is the `factor = b ^ res.shift()` step.
  const res = new Array(degree).fill(0);
  for (const b of data) {
    const factor = b ^ res.shift();
    res.push(0);
    for (let i = 0; i < degree; i++) res[i] ^= gmul(gen[i + 1], factor);
  }
  return res;
}

// ---------------------------------------------------------- bit buffer

function makeBitBuffer() {
  return { bits: [], push(val, len) { for (let i = len - 1; i >= 0; i--) this.bits.push((val >>> i) & 1); } };
}

function encodeData(text, ver, levelName) {
  const lvl = ECC_LEVELS[levelName];
  const bytes = utf8Bytes(text);
  const bb = makeBitBuffer();
  bb.push(4, 4);                                   // byte mode
  bb.push(bytes.length, ver <= 9 ? 8 : 16);        // char count
  for (const b of bytes) bb.push(b, 8);
  const totalData = dataCodewords(ver, lvl);
  const capBits = totalData * 8;
  // terminator (up to 4 zero bits)
  bb.push(0, Math.min(4, capBits - bb.bits.length));
  if (bb.bits.length % 8 !== 0) bb.push(0, 8 - (bb.bits.length % 8));
  // pad bytes 0xEC 0x11 alternating
  const pads = [0xec, 0x11];
  let p = 0;
  while (bb.bits.length < capBits) { bb.push(pads[p % 2], 8); p++; }
  const data = [];
  for (let i = 0; i < bb.bits.length; i += 8) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bb.bits[i + j];
    data.push(b);
  }
  return data;
}

function dataCodewords(ver, lvl) {
  // tables carry a -1 padding at index 0 → version v lives at index v
  const ecc = ECC_CODEWORDS_PER_BLOCK[lvl][ver];
  const blocks = NUM_ECC_BLOCKS[lvl][ver];
  return totalCodewords(ver) - ecc * blocks;
}

function interleave(text, ver, levelName) {
  const lvl = ECC_LEVELS[levelName];
  const data = encodeData(text, ver, levelName);
  const eccPerBlock = ECC_CODEWORDS_PER_BLOCK[lvl][ver];   // index 0 = padding
  const numBlocks = NUM_ECC_BLOCKS[lvl][ver];
  const shortBlock = Math.floor(data.length / numBlocks);
  const numShort = numBlocks - (data.length % numBlocks);
  const blocks = [];
  const eccs = [];
  let off = 0;
  for (let i = 0; i < numBlocks; i++) {
    const len = shortBlock + (i < numShort ? 0 : 1);
    const block = data.slice(off, off + len);
    off += len;
    blocks.push(block);
    eccs.push(rsRemainder(block, eccPerBlock));
  }
  const result = [];
  const maxLen = shortBlock + 1;
  for (let i = 0; i < maxLen; i++) {
    for (let b = 0; b < numBlocks; b++) {
      if (i < blocks[b].length) result.push(blocks[b][i]);
    }
  }
  for (let i = 0; i < eccPerBlock; i++) {
    for (let b = 0; b < numBlocks; b++) result.push(eccs[b][i]);
  }
  // remainder bits (0-7) are left as zero in the matrix filler
  return result;
}

// --------------------------------------------------------------- matrix

function makeMatrix(ver, levelName, codewords, mask) {
  const size = ver * 4 + 17;
  const m = Array.from({ length: size }, () => new Array(size).fill(false));
  const fixed = Array.from({ length: size }, () => new Array(size).fill(false));

  const setFn = (r, c, dark) => { m[r][c] = dark; fixed[r][c] = true; };

  // timing patterns
  for (let i = 0; i < size; i++) {
    setFn(6, i, i % 2 === 0);
    setFn(i, 6, i % 2 === 0);
  }
  // finder patterns + separators
  const drawFinder = (r, c) => {
    for (let dr = -4; dr <= 4; dr++) {
      for (let dc = -4; dc <= 4; dc++) {
        const rr = r + dr, cc = c + dc;
        if (rr < 0 || rr >= size || cc < 0 || cc >= size) continue;
        const dist = Math.max(Math.abs(dr), Math.abs(dc));
        setFn(rr, cc, dist !== 2 && dist !== 4);
      }
    }
  };
  drawFinder(3, 3);
  drawFinder(3, size - 4);
  drawFinder(size - 4, 3);
  // alignment patterns — only the THREE FINDER CORNERS are excluded
  // (Nayuki-verbatim); a center landing mid-timing (e.g. (6,22) at v7)
  // is still drawn, overwriting the timing row/col there.
  const pos = alignmentPositions(ver);
  const last = pos.length - 1;
  for (let pi = 0; pi < pos.length; pi++) {
    for (let pj = 0; pj < pos.length; pj++) {
      if ((pi === 0 && pj === 0) || (pi === 0 && pj === last) ||
          (pi === last && pj === 0)) continue;
      const r = pos[pi], c = pos[pj];
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          setFn(r + dr, c + dc, Math.max(Math.abs(dr), Math.abs(dc)) !== 1);
        }
      }
    }
  }
  // reserve format info areas
  drawFormatBits(m, fixed, size, 0);
  // reserve version info areas (ver >= 7) — values are overwritten after
  // data placement; reserving the CELLS is what keeps codewords out of them
  if (ver >= 7) drawVersionBits(m, fixed, size, ver);
  // dark module + reserved area handled via format rows below

  // place data zigzag
  let i = 0; // bit index over codewords
  const totalBits = codewords.length * 8;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? size - 1 - vert : vert;
        if (fixed[y][x]) continue;
        let dark = false;
        const idx = i >> 3;
        if (idx < codewords.length) {
          dark = ((codewords[idx] >>> (7 - (i & 7))) & 1) !== 0;
        }
        if (maskBit(mask, x, y)) dark = !dark;
        m[y][x] = dark;
        i++;
      }
    }
  }
  void totalBits;

  drawFormatBits(m, fixed, size, mask);
  if (ver >= 7) drawVersionBits(m, fixed, size, ver);
  return m;
}

function maskBit(mask, x, y) {
  switch (mask) {
    case 0: return (x + y) % 2 === 0;
    case 1: return y % 2 === 0;
    case 2: return x % 3 === 0;
    case 3: return (x + y) % 3 === 0;
    case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
    case 5: return ((x * y) % 2) + ((x * y) % 3) === 0;
    case 6: return (((x * y) % 2) + ((x * y) % 3)) % 2 === 0;
    default: return (((x + y) % 2) + ((x * y) % 3)) % 2 === 0;
  }
}

function formatBits(levelName, mask) {
  const data = (ECL_FORMAT_BITS[ECC_LEVELS[levelName]] << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}

function drawFormatBits(m, fixed, size, mask) {
  const levelName = drawFormatBits.levelName || 'M';
  const bits = formatBits(levelName, mask);
  // First copy — around the top-left finder. Coordinates are (row, col):
  // bit 0..5 run down column 8 (right of the top-left finder), bit 6..8
  // cross the center, bits 9..14 run right along row 8. The two gaps on
  // the crossing (6,8) and (8,6) belong to the timing patterns.
  for (let i = 0; i <= 5; i++) set(m, fixed, i, 8, getBit(bits, i));
  set(m, fixed, 7, 8, getBit(bits, 6));
  set(m, fixed, 8, 8, getBit(bits, 7));
  set(m, fixed, 8, 7, getBit(bits, 8));
  for (let i = 9; i < 15; i++) set(m, fixed, 8, 14 - i, getBit(bits, i));
  // Second copy — split around the top-right (row 8) and bottom-left
  // (column 8) areas, plus the ever-dark module at (row 8, col size-8).
  for (let i = 0; i < 8; i++) set(m, fixed, 8, size - 1 - i, getBit(bits, i));
  for (let i = 8; i < 15; i++) set(m, fixed, size - 15 + i, 8, getBit(bits, i));
  set(m, fixed, size - 8, 8, true); // dark module — always dark, never masked
}

function drawVersionBits(m, fixed, size, ver) {
  if (!ver) return;
  let rem = ver;
  for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
  const bits = (ver << 12) | rem;
  for (let i = 0; i < 18; i++) {
    const bit = getBit(bits, i);
    const a = size - 11 + (i % 3);
    const b = Math.floor(i / 3);
    set(m, fixed, a, b, bit);
    set(m, fixed, b, a, bit);
  }
}

function set(m, fixed, r, c, dark) {
  m[r][c] = dark;
  fixed[r][c] = true;
}

function getBit(x, i) { return ((x >>> i) & 1) !== 0; }

// Penalty scoring per ISO/IEC 18004 (N1=3, N2=3, N3=40, N4=10) —
// run-history formulation (same as Nayuki) so mask selection matches
// reference-grade encoders exactly.
const PENALTY_N1 = 3, PENALTY_N2 = 3, PENALTY_N3 = 40, PENALTY_N4 = 10;

function penalty(m) {
  const size = m.length;
  let result = 0;
  // N1 + N3 along rows
  for (let y = 0; y < size; y++) {
    let runColor = false, runLen = 0;
    const runHistory = [0, 0, 0, 0, 0, 0, 0];
    for (let x = 0; x < size; x++) {
      if (m[y][x] === runColor) {
        runLen++;
        if (runLen === 5) result += PENALTY_N1;
        else if (runLen > 5) result++;
      } else {
        fpAdd(runLen, runHistory, size);
        if (!runColor) result += fpCountPatterns(runHistory) * PENALTY_N3;
        runColor = m[y][x];
        runLen = 1;
      }
    }
    result += fpTerminate(runColor, runLen, runHistory, size) * PENALTY_N3;
  }
  // N1 + N3 along columns
  for (let x = 0; x < size; x++) {
    let runColor = false, runLen = 0;
    const runHistory = [0, 0, 0, 0, 0, 0, 0];
    for (let y = 0; y < size; y++) {
      if (m[y][x] === runColor) {
        runLen++;
        if (runLen === 5) result += PENALTY_N1;
        else if (runLen > 5) result++;
      } else {
        fpAdd(runLen, runHistory, size);
        if (!runColor) result += fpCountPatterns(runHistory) * PENALTY_N3;
        runColor = m[y][x];
        runLen = 1;
      }
    }
    result += fpTerminate(runColor, runLen, runHistory, size) * PENALTY_N3;
  }
  // N2: 2x2 same-color blocks
  for (let y = 0; y < size - 1; y++) {
    for (let x = 0; x < size - 1; x++) {
      const c = m[y][x];
      if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1]) result += PENALTY_N2;
    }
  }
  // N4: dark-module balance
  let dark = 0;
  for (const row of m) for (const v of row) if (v) dark++;
  const total = size * size;
  const k = Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1;
  result += k * PENALTY_N4;
  return result;
}

function fpAdd(runLen, runHistory, size) {
  if (runHistory[0] === 0) runLen += size; // light border before the first run
  runHistory.pop();
  runHistory.unshift(runLen);
}

function fpCountPatterns(runHistory) {
  const n = runHistory[1];
  const core = n > 0 && runHistory[2] === n && runHistory[3] === n * 3 &&
               runHistory[4] === n && runHistory[5] === n;
  return (core && runHistory[0] >= n * 4 && runHistory[6] >= n ? 1 : 0) +
         (core && runHistory[6] >= n * 4 && runHistory[0] >= n ? 1 : 0);
}

function fpTerminate(runColor, runLen, runHistory, size) {
  if (runColor) {
    fpAdd(runLen, runHistory, size);
    runLen = 0;
  }
  runLen += size; // light border after the final run
  fpAdd(runLen, runHistory, size);
  return fpCountPatterns(runHistory);
}

function encode(text, levelName, forceMask) {
  const ver = pickVersion(text, levelName);
  const codewords = interleave(text, ver, levelName);
  let best = null, bestMask = 0, bestScore = Infinity;
  for (let mask = 0; mask < 8; mask++) {
    if (forceMask !== undefined && mask !== forceMask) continue;
    drawFormatBits.levelName = levelName;
    const m = makeMatrix(ver, levelName, codewords, mask);
    const s = penalty(m);
    if (s < bestScore) { bestScore = s; best = m; bestMask = mask; }
  }
  drawFormatBits.levelName = undefined;
  return { matrix: best, version: ver, mask: bestMask, size: best.length, score: bestScore };
}

// -------------------------------------------------------------- drawing

function draw(say, text, levelName, note) {
  if (!text) { help(say); return; }
  const { matrix, version, mask } = encode(text, levelName.toUpperCase());
  const quiet = 4;
  const size = matrix.length + quiet * 2;
  const at = (r, c) => {
    const rr = r - quiet, cc = c - quiet;
    if (rr < 0 || cc < 0 || rr >= matrix.length || cc >= matrix.length) return false;
    return matrix[rr][cc];
  };
  const lines = [];
  lines.push('⬛ QR v' + version + ' · ECC ' + levelName.toUpperCase() + ' · mask ' + mask +
    ' · ' + matrix.length + '×' + matrix.length + (note ? ' · ' + note : ''));
  for (let r = 0; r < size; r += 2) {
    let row = '';
    for (let c = 0; c < size; c++) {
      const top = at(r, c), bottom = r + 1 < size ? at(r + 1, c) : false;
      row += top && bottom ? '█' : top ? '▀' : bottom ? '▄' : ' ';
    }
    lines.push(row);
  }
  lines.push('Pixel-dense? Rotate the phone to landscape or zoom the chat.');
  for (const l of lines) say(l);
}

module.exports = main();
