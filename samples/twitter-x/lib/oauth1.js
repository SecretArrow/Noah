/**
 * OAuth 1.0a signer for the twitter-x ZAgents module — self-contained,
 * pure JS, ZERO dependencies (SHA-1 + HMAC-SHA1 implemented inline),
 * CommonJS. No node APIs, no fetch, no template literals — the host's
 * JS engine setup is sensitive to them, so string concatenation only.
 *
 * exports.sign(method, url, params, creds) -> 'OAuth k="v", ...' header
 *   method  'GET' | 'POST' (uppercased internally)
 *   url     base URL WITHOUT the query string (e.g. https://api.x.com/2/tweets)
 *   params  object with ALL query params that go into the URL (GET), or {}
 *           for POST — the JSON request body is NEVER part of an OAuth
 *           1.0a signature. The oauth_* params are added internally.
 *   creds   { consumerKey, consumerSecret, token, tokenSecret }
 *
 * exports.percentEncode(s) — RFC 3986 percent-encoding (unreserved set is
 * exactly A-Za-z0-9 - . _ ~). Use it to build query strings so the URL
 * encoding always matches the signature encoding.
 *
 * Correctness anchors:
 *   - SHA-1(utf8('abc')) = a9993e364706816aba3e25717850c26c9cd0d89d
 *     (standard 512-bit blocks, >>> unsigned ops, rol/add semantics
 *     verified against this vector)
 *   - full end-to-end signature verified against the classic OAuth 1.0a
 *     worked example from the X developer docs (POST statuses/update.json
 *     with the documented nonce/timestamp -> signature
 *     hCtSmYh+iHYCEqBWrE7C7hYmtUk=)
 */

'use strict';

/* ------------------------------------------------------------------ UTF-8 */

/** string -> array of UTF-8 bytes (surrogate pairs handled) */
function utf8Bytes(str) {
  var s = String(str == null ? '' : str);
  var out = [];
  for (var i = 0; i < s.length; i++) {
    var code = s.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      var lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        var cp = 0x10000 + ((code - 0xd800) * 0x400) + (lo - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        i++;
        continue;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return out;
}

/* -------------------------------------------------------- percent encoding */

/** RFC 3986 percent-encode: everything outside A-Za-z0-9 - . _ ~ -> %XX */
function percentEncode(s) {
  var bytes = utf8Bytes(s);
  var out = '';
  for (var i = 0; i < bytes.length; i++) {
    var b = bytes[i];
    if ((b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) ||
        b === 0x2d || b === 0x2e || b === 0x5f || b === 0x7e) {
      out += String.fromCharCode(b);
    } else {
      var h = b.toString(16).toUpperCase();
      out += '%' + (h.length < 2 ? '0' + h : h);
    }
  }
  return out;
}

/** bytes (array of 0..255) -> base64 string with '=' padding */
function bytesToBase64(bytes) {
  var T = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i];
    var b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    var b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += T[b0 >> 2];
    out += T[((b0 & 3) << 4) | (b1 >> 4)];
    out += i + 1 < bytes.length ? T[((b1 & 15) << 2) | (b2 >> 6)] : '=';
    out += i + 2 < bytes.length ? T[b2 & 63] : '=';
  }
  return out;
}

/* ------------------------------------------------------------------ SHA-1 */

/**
 * SHA-1 over an array of bytes -> [h0, h1, h2, h3, h4] as uint32 numbers.
 * Standard FIPS 180-1 block processing; all arithmetic keeps the low 32
 * bits via >>> 0 and rotations use >>> for the incoming bits.
 */
function sha1Words(bytes) {
  var h0 = 0x67452301;
  var h1 = 0xefcdab89;
  var h2 = 0x98badcfe;
  var h3 = 0x10325476;
  var h4 = 0xc3d2e1f0;
  var bitLen = bytes.length * 8;
  var hiLen = Math.floor(bitLen / 4294967296);
  var loLen = bitLen - hiLen * 4294967296;
  var data = bytes.slice();
  data.push(0x80);
  while (data.length % 64 !== 56) data.push(0x00);
  data.push((hiLen >>> 24) & 0xff, (hiLen >>> 16) & 0xff, (hiLen >>> 8) & 0xff, hiLen & 0xff);
  data.push((loLen >>> 24) & 0xff, (loLen >>> 16) & 0xff, (loLen >>> 8) & 0xff, loLen & 0xff);
  var w = new Array(80);
  for (var off = 0; off < data.length; off += 64) {
    var i, t;
    for (i = 0; i < 16; i++) {
      var j = off + i * 4;
      w[i] = ((data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | data[j + 3]) >>> 0;
    }
    for (t = 16; t < 80; t++) {
      var x = (w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]) >>> 0;
      w[t] = ((x << 1) | (x >>> 31)) >>> 0;
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (t = 0; t < 80; t++) {
      var f, k;
      if (t < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
      else if (t < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
      else if (t < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
      else { f = b ^ c ^ d; k = 0xca62c1d6; }
      var tmp = ((((a << 5) | (a >>> 27)) >>> 0) + (f >>> 0) + e + k + w[t]) >>> 0;
      e = d;
      d = c;
      c = ((b << 30) | (b >>> 2)) >>> 0;
      b = a;
      a = tmp;
    }
    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }
  return [h0, h1, h2, h3, h4];
}

/** uint32 words -> byte array (big-endian) */
function wordsToBytes(words) {
  var out = [];
  for (var i = 0; i < words.length; i++) {
    out.push((words[i] >>> 24) & 0xff, (words[i] >>> 16) & 0xff, (words[i] >>> 8) & 0xff, words[i] & 0xff);
  }
  return out;
}

/* -------------------------------------------------------------- HMAC-SHA1 */

/** HMAC-SHA1(keyBytes, msgBytes) -> 20 bytes */
function hmacSha1(keyBytes, msgBytes) {
  var key = keyBytes.length > 64 ? wordsToBytes(sha1Words(keyBytes)) : keyBytes.slice();
  var ipad = [];
  var opad = [];
  for (var i = 0; i < 64; i++) {
    var b = i < key.length ? key[i] : 0x00;
    ipad.push(b ^ 0x36);
    opad.push(b ^ 0x5c);
  }
  var inner = wordsToBytes(sha1Words(ipad.concat(msgBytes)));
  return wordsToBytes(sha1Words(opad.concat(inner)));
}

/* ------------------------------------------------------------------ OAuth */

/** random alphanumeric nonce (Math.random-based is fine for OAuth nonces) */
function randomNonce(len) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  var out = '';
  for (var i = 0; i < len; i++) out += chars[Math.floor(Math.random() * chars.length)];
  return out;
}

/**
 * Build the OAuth 1.0a Authorization header for one request.
 * See the file header for the exact argument contract.
 */
function sign(method, url, params, creds) {
  var c = creds || {};
  var m = String(method || 'GET').toUpperCase();
  var baseUrl = String(url == null ? '' : url);

  var oauth = {
    oauth_consumer_key: String(c.consumerKey == null ? '' : c.consumerKey),
    oauth_nonce: randomNonce(32),
    oauth_signature_method: 'HMAC-SHA1',
    oauth_timestamp: String(Math.floor(Date.now() / 1000)),
    oauth_token: String(c.token == null ? '' : c.token),
    oauth_version: '1.0'
  };

  // ALL parameters that take part in the signature: the query params given
  // in "params" + the oauth_* params above. The POST JSON body is NOT here.
  var all = [];
  var p = params || {};
  var keys = Object.keys(p);
  for (var i = 0; i < keys.length; i++) {
    all.push([keys[i], p[keys[i]] == null ? '' : String(p[keys[i]])]);
  }
  var okeys = Object.keys(oauth);
  for (var j = 0; j < okeys.length; j++) {
    all.push([okeys[j], oauth[okeys[j]]]);
  }

  // sort by encoded key, then encoded value
  all.sort(function (a, b) {
    var ka = percentEncode(a[0]);
    var kb = percentEncode(b[0]);
    if (ka !== kb) return ka < kb ? -1 : 1;
    var va = percentEncode(a[1]);
    var vb = percentEncode(b[1]);
    return va === vb ? 0 : (va < vb ? -1 : 1);
  });

  var pairs = [];
  for (var n = 0; n < all.length; n++) {
    pairs.push(percentEncode(all[n][0]) + '=' + percentEncode(all[n][1]));
  }
  var paramStr = pairs.join('&');

  // base string: METHOD & percentEncode(url) & percentEncode(paramString)
  var baseStr = m + '&' + percentEncode(baseUrl) + '&' + percentEncode(paramStr);

  // signing key: percentEncode(consumerSecret) & percentEncode(tokenSecret)
  var signKey = percentEncode(c.consumerSecret == null ? '' : c.consumerSecret) +
    '&' + percentEncode(c.tokenSecret == null ? '' : c.tokenSecret);

  var mac = bytesToBase64(hmacSha1(utf8Bytes(signKey), utf8Bytes(baseStr)));

  var head = [];
  for (var q = 0; q < okeys.length; q++) {
    head.push(percentEncode(okeys[q]) + '="' + percentEncode(oauth[okeys[q]]) + '"');
  }
  head.push('oauth_signature="' + percentEncode(mac) + '"');
  return 'OAuth ' + head.join(', ');
}

module.exports = { sign: sign, percentEncode: percentEncode };
