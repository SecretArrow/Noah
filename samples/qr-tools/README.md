# QR Code (sample module)

Real, **scannable QR codes rendered as Unicode block art** directly in the
chat — point a phone camera at the screen and it scans. Zero special
permissions: pure computation, nothing stored, nothing sent.

```
QR Code · /qr
├─ /qr <text>            encode any text or URL (ECC level M by default)
├─ /qr l|m|q|h <text>    pick the error-correction level explicitly
├─ /qr wifi <ssid> | <password> [| WPA|WEP|nopass]
│                        WIFI: payload — phones offer to join the network
└─ /qr help
```

## The encoder

A complete pure-JS QR implementation (no npm deps, ~550 lines):

- UTF-8 **byte mode**, versions 1-25 (up to ~1273 bytes at level L)
- **Reed-Solomon** ECC over GF(256) (`x^8 + x^4 + x^3 + x^2 + 1`), block
  splitting + codeword interleaving per the spec's block structure tables
- **Format info** (BCH(15,5), mask `0x5412`) and **version info**
  (BCH(18,6), mask `0x1F25`, versions 7+) drawn in both copies
- All **8 mask patterns** scored with the spec's full penalty rules
  (runs, 2×2 blocks, finder-like patterns via run-history, dark balance)
- Finder / separator / timing / alignment / dark module placement,
  version-capacity derived from the block tables (single source of truth)

**Verified two ways** (see `scripts/test_qr_tools_harness.js` +
`decode_qr_roundtrip.py` in the repo): the generated matrices are
**cell-for-cell identical** to Nayuki's reference QR library for byte
mode across versions 1-16 and all four ECC levels, and 9/9 rendered codes
(including multi-block v14/v16/v19 and UTF-8 payloads) **decode back to
the exact input** through OpenCV's QRCodeDetector.

## The output

Each QR pixel pair becomes one text row via `▀ ▄ █` half-blocks, so a
version-5 code is ~22 chat rows and a version-16 fits the 400-line run
cap comfortably. The quiet zone is real whitespace — the chat renders it
light, exactly what scanners expect.

## Zero permissions

The manifest declares `"permissions": []` — the module only uses
`zagents.log`, which is always available. It cannot touch storage,
network, files, the device or the agent.

## Files

- `module.json` — manifest (no permissions; command `qr`)
- `main.js` — command router + full QR encoder + block-art renderer

## Try it

1. Install the ZIP: **Settings → Modules → Install module**.
2. `/qr https://github.com/SecretArrow/Noah`
3. `/qr wifi CoffeeShop | latte4life`
4. Scan the screen with any phone camera.
