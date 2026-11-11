# Facebook Page Assistant (sample module)

Asisten **Fanspage Facebook per chat**: login otomatis ke halaman lewat
Page Access Token, lalu membalas **pesan Messenger** dan **komentar di
post** secara berkala. Setiap balasan dimulai dari template per intent
(sapaan, tanya harga, ongkir, komplain, dll.), placeholder diisi, lalu
**dipoles oleh agent chat** (`zagents.agent.polish`) agar terdengar
natural seperti manusia — lengkap dengan jeda acak antar balasan dan
anti-repetisi terhadap 8 balasan terakhir.

```
Facebook Page Assistant · /fb
├─ (kosong) / status   validasi token + identitas page, config, statistik, antrean
├─ check               satu pass: poll pesan + komentar baru, lalu balas
├─ auto [detik]        burst watch tiap N detik (10-60, default 20) selama budget run
├─ template            kelola 8 template: list / lihat / set / reset
├─ on|off <kanal>      auto-reply per kanal (messages | comments)
├─ speed <mode>        jeda antar balasan: fast 3-6 / normal 6-15 / slow 15-30 detik
├─ logout              hapus token + riwayat chat ini
└─ help
```

## Cara dapat Page Access Token

1. Buka **developers.facebook.com** → **My Apps** → **Create App**
   (tipe *Business* cukup).
2. Buka **Graph API Explorer** (Tools → Graph API Explorer), pilih app
   yang baru dibuat.
3. Di dropdown **User or Page**, **pilih Page** yang mau diawasi.
4. Klik **Generate Access Token**, centang permission:
   `pages_messaging`, `pages_read_engagement`,
   `pages_manage_engagement`, `pages_manage_metadata`.
5. Salin token ke field **Page Access Token** di form setup modul.

> Pakai **Page token** (bukan user token) agar token tidak gampang
> expired — atau langsung Page token long-lived. `/fb status` akan
> langsung menunjukkan bila token ditolak.

## Perintah /fb

| Perintah | Contoh | Fungsi |
|---|---|---|
| `/fb` atau `/fb status` | `/fb` | Validasi token (`GET /me`), nama + kategori page (bukti auto-login), flag config, statistik balasan, jumlah antrean. Token hanya tampil masked: `••••abcd`. |
| `/fb check` | `/fb check` | Satu pass penuh: poll Messenger + komentar post, klasifikasi intent, balas item baru dengan template + polish AI, jeda manusiawi antar balasan. |
| `/fb auto [detik]` | `/fb auto 15` | Burst watch: pass berulang tiap N detik sampai budget run (~110 detik) hampir habis. Jalankan lagi untuk lanjut memantau. |
| `/fb template` | `/fb template` | Daftar 8 key template + jumlah varian + contoh. |
| `/fb template <key>` | `/fb template price` | Lihat semua varian satu template. |
| `/fb template <key> A \| B \| C` | `/fb template thanks Makasih {name}! \| Sama-sama {name}, salam {page}.` | Set varian (1-4 varian, maks 300 karakter, dipisah `|`), langsung disimpan. |
| `/fb template reset` | `/fb template reset` | Kembalikan semua template ke bawaan. |
| `/fb on\|off <kanal>` | `/fb off comments` | Toggle auto-reply per kanal (`messages` / `comments`); tersimpan per chat dan menimpa nilai form setup. |
| `/fb speed <mode>` | `/fb speed slow` | Jeda antar balasan: `fast` 3-6 dtk, `normal` 6-15 dtk, `slow` 15-30 dtk. |
| `/fb logout` | `/fb logout` | Hapus token, identitas page, statistik, dan riwayat baca/balasan chat ini. |
| `/fb help` | `/fb help` | Daftar perintah. Argumen tak dikenal juga jatuh ke help. |

## Template & intent

Item yang masuk diklasifikasi dari kata kunci (Indonesia + Inggris):
`harga/buy/price/beli` → **price**, `kirim/ongkir/shipping/delivery` →
**shipping**, `terima kasih/thanks/makasih` → **thanks**,
`rusak/kecewa/komplain/complain/bad` → **complaint**,
`halo/hai/min/sis/kak` → **greeting**, `kapan/bagaimana/bisa/apakah/how/
when` → **question**, sisanya **generic**. Key `away` tersedia sebagai
template lepas (tidak dipakai klasifikasi).

Satu varian dipilih acak, `{name}` diisi nama depan pengirim (fallback
`kak` untuk bahasa Indonesia, kosong untuk Inggris) dan `{page}` diisi
nama halaman, lalu `zagents.agent.polish` memoles teksnya (konteks =
pesan/komentar asli, bahasa `auto` mengikuti pengirim, maks 300
karakter, tanpa emoji, menghindari 8 balasan terakhir). Bila polish
gagal (API key tidak ada / provider down), balasan jatuh kembali ke
template yang sudah diisi — pass tidak pernah gagal karenanya.

## Privasi

- Token, config, template, statistik, dan daftar pesan/komentar yang
  sudah diproses hidup di **storage per chat** — chat lain tidak bisa
  melihatnya.
- Token **hanya** dikirim ke `graph.facebook.com` (manifest
  `allowedHosts` mengunci host lain) dan tidak pernah ditampilkan
  utuh: `/fb status` hanya menampilkan `••••` + 4 karakter terakhir.
- `/fb logout` menghapus semua state chat ini, termasuk mirror form
  setup, sehingga form diminta lagi pada aktivasi berikutnya.

## Limitasi

- **Jendela 24 jam Messenger**: Graph API hanya mengizinkan balasan
  untuk pesan yang datang dalam 24 jam terakhir (error subcode
  `2018278` / code `10`). Pesan di luar jendela ditandai sudah dibaca
  tanpa bisa dibalas — dicatat satu baris di output.
- **Rate limit Graph API**: balasan diberi jeda acak (fast/normal/slow)
  dan diproses satu per satu; jangan set `fast` terus-menerus pada page
  dengan traffic tinggi.
- **Burst = selama run**: modul berjalan selama chat aktif saja;
  `/fb auto` memantau maksimal ~110 detik per run (budget modul), lalu
  berhenti dengan ajakan menjalankan `/fb auto` lagi.
- Token bisa expired (kecuali long-lived) — perbarui lewat form setup;
  token baru memicu validasi ulang dan nama page di-emit otomatis.

## Penggunaan wajar

Modul ini untuk **membantu** mengelola page milik sendiri atau page
yang Anda otorisasi — bukan alat spam. Ia hanya membalas item yang
belum pernah diproses (dedupe per ID), tidak mengirim pesan masuk
(khusus membalas), dan tidak pernah mengulang balasan yang sama ke
orang yang sama. Patuhi Facebook Platform Terms dan kebijakan page:
jangan digunakan untuk membalas berlebihan, mengirim promosi massal,
atau menyesatkan penerima seolah manusia sungguhan.

## Files

- `module.json` — manifest (`storage`, `network`, `agent`, `chat`;
  host terkunci ke `graph.facebook.com`; command `fb`; form setup
  `pageToken` + flag auto-reply + bahasa)
- `main.js` — command router, poller Messenger/komentar, klasifikasi
  intent, template manager, mesin pass dengan polish + jeda manusiawi

## Try it

1. Install ZIP: **Settings → Modules → Install module**, lalu isi form
   setup (Page Access Token).
2. `/fb` → cek nama page + kategori muncul (auto-login OK).
3. `/fb check` → balas semua pesan/komentar baru dengan jeda manusiawi.
4. `/fb auto 20` → pantau beruntun ±110 detik.
5. `/fb template price Halo {name}, harganya 25rb ya. | Bisa cek katalog {page} kak.` → sesuaikan gaya balasan.
