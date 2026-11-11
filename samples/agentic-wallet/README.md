# Agentic Wallet — modul contoh per-chat (permissions: `storage`, `agent`, `chat`)

Companion **kebijakan & pembukuan** untuk alur resmi **Binance Agentic
Wallet**, dijalankan penuh lewat **perintah slash `/aw`** (manifest
`commands: ["aw"]` — pesan diarahkan ke modul, bukan ke LLM, jadi
perintah kebijakan tidak menghabiskan giliran AI). Modul ini adalah
lapisan advisory yang JUJUR: ia sengaja **tidak bisa** memindahkan dana.

## Model keamanan (baca dulu)

- **Tanpa kunci, tanpa tanda tangan, tanpa jaringan.** Modul TIDAK
  menyimpan kunci privat / seed phrase, TIDAK menandatangani transaksi,
  dan TIDAK punya izin `network` (tidak ada `allowedHosts` — memang
  tidak ada panggilan jaringan sama sekali). Semua pergerakan dana
  terjadi oleh **pengguna sendiri di aplikasi resmi Binance / web wallet
  Binance**, dikendalikan di dalam browser chat yang terisolasi oleh
  agent, dengan kartu **`request_confirmation`** untuk setiap aksi yang
  memindahkan nilai.
- **Matriks kemampuan (jujur):**
  - ✅ **Bisa di perangkat (modul ini):** catatan pairing per chat, limit
    belanja harian, pilihan jaringan, tabel token + alamat EIP-55,
    validasi/checksum alamat, draf niat belanja (intent) yang lolos
    pemeriksaan kebijakan, buku catatan harian + riwayat.
  - ❌ **Tidak bisa di perangkat (bukan tugas modul ini):** menjalankan
    CLI `baw` resmi (butuh Node native — runtime JS tersemat ZAgents
    bukan terminal; sampaikan apa adanya), menandatangani transaksi,
    menyiarkan transaksi, memegang aset. Semua itu terjadi di aplikasi
    resmi Binance.
- **Dua langkah (two-step) untuk aksi sensitif.** `pair`, `unpair`, dan
  `reset` memakai gerbang dua langkah: perintah pertama hanya menampilkan
  penjelasan + memasang latch, lalu kamu kirim `... confirm` untuk
  mengeksekusi. Untuk belanja: `/aw spend` hanya membuat **DRAFT**
  (intent pending) — agent WAJIB memanggil `request_confirmation` dengan
  fakta draf (jaringan, token, jumlah, tujuan) dan menunggu persetujuan
  pengguna; baru setelah itu `/aw spend confirm <id>` mencatatnya ke buku
  — dan catatan itu pun tetap bukan eksekusi dana.
- **Isolasi per chat.** Seluruh state hidup di `zagents.storage` milik
  chat ini saja (`agenticWalletState`): chat lain tidak melihat pairing,
  limit, buku harian, maupun riwayat — dua chat berarti dua dompet catatan.
- **Limit harian = rem kebijakan.** Default `0` = semua `/aw spend`
  diblokir sampai kamu memasang limit (`/aw limit <angka>`). Cap berlaku
  per token per hari (UTC) dan dihitung dari spend yang SUDAH dicatat
  modul — bukan saldo on-chain (modul tidak membaca chain).
- **Verifikasi token.** Alamat di registri (mainnet, bentuk kanonik
  EIP-55) sudah diverifikasi round-trip dengan implementasi keccak
  modul ini, TETAP saja: verifikasi ulang ke sumber resmi sebelum
  memindahkan dana. Registri ini data pembukuan, bukan sumber kebenaran.

## Kaitan resmi

- Dompet & alur resmi: <https://www.binance.com/en/web3wallet> →
  *agentic wallet* (dan *binance-skills-hub*).
- Paket skill resmi (untuk runtime yang mendukung npm/CLI):
  `npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet`
  — **tidak bisa dijalankan di perangkat** oleh modul ini; tautan
  disediakan agar kamu tahu jalur ofisialnya.

## Perintah

| Perintah | Fungsi |
|---|---|
| `/aw` | status: pairing, jaringan, limit, buku hari ini, pending, catatan terakhir |
| `/aw status` | sama dengan di atas |
| `/aw pair` | mulai pasang catatan pairing (two-step → `/aw pair confirm`) |
| `/aw pair confirm` | selesaikan pairing (pembukuan saja, tanpa rahasia) |
| `/aw unpair confirm` | hapus catatan pairing (riwayat dipertahankan) |
| `/aw limit` | tampilkan limit harian + buku hari ini |
| `/aw limit <angka>` | pasang cap harian per token (dot desimal; `0` = blokir semua) |
| `/aw network` | daftar jaringan + yang aktif |
| `/aw network <nama>` | ganti: `bsc` \| `eth` \| `arbitrum` \| `base` (alias `bnb`, `ethereum`); intent pending ikut dibuang |
| `/aw tokens` | tabel token jaringan aktif (simbol + alamat EIP-55 + desimals) |
| `/aw checksum <alamat> [jaringan]` | validasi bentuk + checksum EIP-55 (jaringan tak dikenal → bentuk saja) |
| `/aw spend <token> <jumlah> <ke>` | draf intent (dicek kebijakan) → ringkasan DRAFT + instruksi `request_confirmation` |
| `/aw spend confirm <id>` | catat intent yang SUDAH disetujui ke buku (bukan eksekusi dana) |
| `/aw spend cancel <id>` | buang intent pending |
| `/aw history` | 20 catatan terakhir (waktu, jaringan, token, jumlah, tujuan) |
| `/aw reset confirm` | hapus seluruh state chat ini (two-step) |
| `/aw help` | daftar perintah |

## Jaringan & token (mainnet, EIP-55 kanonik)

| Kunci | Jaringan | Token |
|---|---|---|
| `bsc` | BNB Smart Chain (56) | BNB (native), USDT, USDC, ETH, CAKE |
| `eth` | Ethereum (1) | ETH (native), USDT, USDC, WBTC |
| `arbitrum` | Arbitrum One (42161) | ETH (native), USDT, USDC |
| `base` | Base (8453) | ETH (native), USDC |

⚠️ Periksa ulang setiap alamat di UI resmi Binance / block explorer
sebelum memindahkan dana.

## Contoh sesi

```text
/aw
  → 🧭 status: unpaired · bsc · limit belum dipasang · mode policy/advisory

/aw pair
  → 📋 pairing = pembukuan saja; pasangkan dompet ASLI di aplikasi Binance
  → kirim /aw pair confirm
/aw pair confirm
  → ✅ paired (manual-bookkeeping)

/aw limit 100
  → ✅ limit 100 per token per hari (UTC)

/aw spend usdt 5 0x55d398326f99059fF775485246999027B3197955
  → 📝 SPEND DRAFT — sp-1 (PENDING, belum ada eksekusi)
  → network bsc · token USDT · 5 USDT → 0x55d3…7955 · sisa kuota 95
  → AGENT: panggil request_confirmation dengan fakta ini dulu;
    eksekusi tetap di aplikasi/web resmi Binance oleh pengguna
/aw spend confirm sp-1
  → 📒 Recorded — sp-1 … ⚠️ modul tidak memindahkan dana — jalankan di
    aplikasi Binance
/aw history
  → 📒 catatan terakhir (maks 20)
```

## Batasan (jujur)

- Tidak ada izin `network` — modul tidak membaca saldo on-chain, harga,
  maupun status transaksi; "sisa kuota" murni dari pembukuan modul.
- CLI resmi `baw` / paket skill Binance tidak bisa dijalankan di runtime
  JS tersemat (bukan Node penuh, tanpa binary) — modul ini bukan
  penggantinya, hanya lapisan kebijakan + pencatatan.
- Limit & history bisa dihapus oleh siapa pun yang memegang chat
  (`/aw reset confirm`) — ini catatan disiplin, bukan kontrol keamanan
  yang mengikat wallet aslimu. Keamanan yang sebenarnya tetap dari:
  persetujuan kartu `request_confirmation` + 2FA/verifikasi di aplikasi
  resmi Binance.
- Satu intent pending pada satu waktu (draft baru menggantikan yang
  lama, dengan pemberitahuan). Ganti jaringan → intent pending dibuang.
- Alamat `checksum` untuk jaringan yang tidak dikenal hanya dicek
  bentuknya (checksum-agnostic), sesuai rancangan.

## File

- `module.json` — manifest: permissions `storage`, `agent`, `chat`
  (TANPA `network`/`allowedHosts`), `timeoutSeconds: 60`, commands `["aw"]`.
- `main.js` — router perintah + mesin state + keccak256/EIP-55 murni-JS
  (disalin dari `samples/evm-wallet/main.js`), tanpa dependensi.

## Coba

1. ZAgents → **Settings → Modules → Install module** → pilih
   `agentic-wallet.zip` (di samping folder ini), setujui permission.
2. Di sebuah chat, ketik `/aw` lalu ikuti alur: `pair` → `limit` →
   `spend` → `request_confirmation` → `spend confirm` → `history`.
3. Lihat `../README.md` untuk alur instalasi/packaging umum.
