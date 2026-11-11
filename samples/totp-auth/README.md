# Authenticator (TOTP) (sample module)

A per-chat **RFC 6238 TOTP authenticator**: store 2FA secrets per chat and
generate current codes on demand — like an authenticator app that lives
inside a conversation.

```
Authenticator · /otp
├─ add <label> <base32secret> [digits] [period] [algo]
│        defaults: 6 digits · 30 s · SHA-1  (SHA-256 / SHA-512 supported)
├─ code [label]     current code(s) + "Xs left" countdown
├─ list             accounts overview + staged removal warning
├─ uri <label>      standard otpauth:// URI (pairs with /qr!)
├─ remove <label> → confirm / cancel    two-step delete, 10-min window
└─ help
```

## Crypto, from scratch

Zero npm dependencies — the module carries its own pure-JS **SHA-1**,
**SHA-256** and **SHA-512** (BigInt 64-bit lanes), **HMAC** (FIPS 198),
**Base32** (RFC 4648) decode, and the RFC 4226 **dynamic truncation** with
the full 8-byte big-endian counter. Correctness is locked by the harness
(`scripts/test_totp_harness.js`): all 18 official **RFC 6238 test vectors**
(3 algorithms × 6 timestamps) pass, plus the whole command flow.

## Security posture

- **No network permission** — the manifest asks only for `storage`, so
  secrets physically cannot leave the device through the module.
- Per-chat vault: another chat starts empty (the module-isolation
  guarantee), and nothing is written to the shared transcript.
- `add` never echoes the secret back; `uri` is opt-in and prints the
  standard `otpauth://` URI — deliberately compatible with the
  `qr-tools` sample (`/qr <uri>`) for authenticator migration.
- Removal is two-step (`remove` → `confirm` within 10 minutes,
  `cancel` to abort) so a typo can never wipe an account.
- Input validation: Base32 charset enforced, minimum secret length,
  duplicate labels rejected case-insensitively, digits 6-8, period
  15-120 s, algo whitelist.

## Files

- `module.json` — manifest (`storage` only; command `otp`)
- `main.js` — command router + SHA family + HMAC + TOTP core

## Try it

1. Install the ZIP: **Settings → Modules → Install module**.
2. Grab a Base32 secret from any service's 2FA setup page
   ("can't scan?" shows it).
3. `/otp add github JBSWY3DPEHPK3PXP`
4. `/otp code` → `🔑 github: 123456   (18s left · SHA1 · 6d)`
