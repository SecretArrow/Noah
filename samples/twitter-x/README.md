# Twitter/X Assistant (sample module)

Sebuah **asisten X/Twitter per-chat** di dalam percakapan: memantau mention
lewat X API v2, mengklasifikasi intent-nya (komplain, pujian, pertanyaan,
umum), lalu membalas dengan template bahasa Indonesia kasual yang dipoles
agent AI agar terdengar natural — bukan bot yang jawabannya kaku dan selalu
sama.

```
Twitter/X Assistant · /tw
├─ status                login, kredensial (ter-mask), metrics, statistik
├─ check                 satu pass: mention baru → (auto-)balasan
├─ auto [detik]          burst watch tiap N detik (min 10, ±110 detik/run)
├─ on | off              toggle auto-reply mentions untuk chat ini
├─ template [key] [A|B]  kelola template (support/praise/question/generic/away)
├─ tweet <teks>          posting tweet baru apa adanya
├─ tweet polish <teks>   posting dengan polish AI (maks 280 karakter)
├─ reply <url|id> [key]  balas manual satu tweet
├─ logout                hapus kredensial + riwayat mention chat ini
└─ help
```

## Cara mendapat keys

1. Buka **developer.x.com** → login dengan akun Xmu → masuk ke
   **Projects & Products** → buat **Project + App** (atau pakai yang ada).
2. Di App → **User authentication settings** → set **App permissions:
   Read and write** (tanpa ini, posting/balasan akan ditolak 403).
3. Tab **Keys and tokens** → generate **API Key & Secret** (Consumer Keys)
   dan **Access Token & Secret** — token akses WAJIB digenerate *setelah*
   permissions diubah ke Read and write.
4. Isi setup form modul (muncul otomatis sebelum run pertama di setiap
   chat). Semua field kredensial bertipe password; handle ditulis tanpa `@`.

## Tier X API — baca dulu, dengan jujur

- **Free**: bisa **posting** (500 tweet/bulan) tapi **TIDAK punya akses
  baca mentions**. `/tw check` dan `/tw auto` akan menampilkan 403
  `client-not-enrolled` dan menjelaskan persis ini — auto-reply butuh
  paket **Basic/Premium**.
- Tetap berguna di Free: `/tw tweet`, `/tw tweet polish`, dan `/tw reply`
  (balasan manual ke URL tweet mana pun) jalan penuh.
- HTTP 429 = rate limit tercapai; modul menampilkan waktu reset dari
  header `x-rate-limit-reset` (epoch → waktu lokal).
- HTTP 401 = token invalid/expired → regenerate Access Token di portal.

## Template & AI polish

Lima kunci template (`support`, `praise`, `question`, `generic`, `away`)
dengan 2–4 varian bahasa Indonesia kasual, placeholder `{name}` = @pengirim
dan `{me}` = @akunmu. Setiap balasan: varian diacak → slot diisi → dipoles
`zagents.agent.polish` (maks 280 karakter, tone casual, menghindari 8
balasan terakhir, emoji nonaktif). Kalau AI gagal, run otomatis fallback ke
varian template yang sudah diisi slot — tidak pernah crash.

Perintah: `/tw template` lihat semua · `/tw template praise Teks A | Teks B`
set 1–4 varian (maks 240 karakter/varian) · `/tw template reset` kembalikan
bawaan.

Untuk membatasi spam, satu pass maksimal memproses 25 mention dengan jeda
human-like 6–15 detik antar balasan, dan mention yang gagal dibalas 3×
ditandai selesai agar tidak terjadi loop.

## Privasi & keamanan

- Kredensial disimpan di **storage per-chat** — chat lain tidak pernah
  melihatnya (isolasi private-window ZAgents).
- Kredensial **hanya dikirim ke `api.x.com`** (fallback `api.twitter.com`)
  sebagai header OAuth 1.0a — tidak ke host lain, tidak ke LLM.
- Output modul selalu mem-mask secret: `••••` + 4 karakter terakhir saja.
- `/tw logout` menghapus kredensial, cache akun, dan riwayat mention chat
  ini.

## Penggunaan wajar

Modul ini memposting **sebagai akunmu** — kamu bertanggung jawab atas isi
balasannya. Jangan spam: hormati rate limit X, jangan auto-reply akun yang
melarang bot, dan patuhi X Developer Agreement serta aturan automation X.
Fitur auto-reply hanya membalas mention yang belum pernah diproses di chat
ini (riwayat maks 300 id).

## Files

- `module.json` — manifest (`storage`, `network`, `agent`, `chat`; command `tw`; setup form 6 field)
- `main.js` — router `/tw` + poll mentions + template manager + polish flow
- `lib/oauth1.js` — signer OAuth 1.0a murni JS (SHA-1 + HMAC-SHA1 inline, tanpa dependensi)

## Try it

1. Install ZIP: **Settings → Modules → Install module**.
2. Isi setup form (keys dari developer.x.com, Read and write).
3. `/tw status` → verifikasi login + metrics akun.
4. `/tw check` → proses mention baru sekali (butuh Basic/Premium untuk baca mentions).
5. `/tw auto 15` → burst watch ±110 detik; jalankan lagi untuk lanjut.
6. `/tw tweet polish Halo, kami baru saja rilis fitur baru!` → posting dengan polish AI.
