# Noah Module SDK (v1.31.0)

Panduan resmi untuk membuat **modul chat**: paket JavaScript yang berjalan
secara native di dalam sesi chat Noah, terisolasi per chat seperti
jendela privat browser.

Lokasi berkas di repositori ini:

| Path | Isi |
|---|---|
| `sdk/` | SDK resmi — shim `zagents-sdk.js`, definisi TypeScript `index.d.ts`, `package.json` |
| `samples/` | Contoh modul siap pasang (counter, network-fetcher, file-notes, chat-streamer, onhomeroom-daily) |
| `docs/modules/` | Referensi ini (Inggris + Bahasa Indonesia) — juga dikirim in-app |

## 1. Struktur paket

Modul adalah arsip ZIP:

```
modul-saya.zip
├── module.json        (manifest — disarankan)
├── main.js            (entry point, bawaan)
├── lib/util.js        (file tambahan, di-require secara relatif)
└── node_modules/…     (opsional; atau gunakan paket dari alat npm)
```

### Manifest — `module.json`

```json
{
  "name": "modul-saya",
  "version": "1.0.0",
  "title": "Modul Saya",
  "description": "Apa yang dilakukan modul ini untuk pengguna.",
  "entry": "main.js",
  "permissions": ["storage", "network", "files", "chat"],
  "allowedHosts": ["api.contoh.com"],
  "timeoutSeconds": 30,
  "setup": {
    "title": "Akun Modul Saya",
    "description": "Diminta sekali per chat sebelum run pertama.",
    "fields": [
      { "key": "username", "label": "Username", "type": "text", "required": true },
      { "key": "password", "label": "Password", "type": "password", "required": true },
      { "key": "retries", "label": "Maks percobaan", "type": "number" },
      { "key": "verbose", "label": "Log detail", "type": "boolean" }
    ]
  }
}
```

| Kolom | Wajib | Keterangan |
|---|---|---|
| `name` | ya | Huruf kecil `[a-z0-9._-]`, maks 40 karakter. Sekaligus nama direktori instalasi. |
| `version` | — | Ditampilkan di layar Modules. |
| `title` | — | Nama tampilan (bawaan: `name`). |
| `description` | — | Ditampilkan ke pengguna dan disuntikkan ke konteks chat. |
| `entry` | — | Entry point, bawaan `main.js`. |
| `permissions` | — | `storage`, `network`, `files`, `chat`, `agent`, `device` — pengguna menyetujui setiap aktivasi. |
| `allowedHosts` | — | Membatasi `zagents.http` ke host tersebut (`*.contoh.com` mengizinkan subdomain). Kosongkan untuk semua host. |
| `timeoutSeconds` | — | Anggaran eksekusi per run (30 bawaan, maks 120). |
| `setup` | — | Formulir setup per chat — lihat di bawah. |
| `commands` | — | Kata kunci slash yang ditangani modul (v1.31.0) — lihat di bawah. |

Tanpa `module.json`, `package.json` (`name`, `version`, `main`) tetap
dihormati; tanpa keduanya, nama file ZIP menjadi nama modul.

### Formulir setup — `setup` di module.json

Deklarasikan input yang dibutuhkan modul Anda dan aplikasi mengumpulkannya
dengan **formulir per chat SEBELUM run pertama modul di chat itu** — tanpa
siklus pertama yang gagal, tanpa parsing `setup <…>` sendiri:

* `title`, `description` — judul formulir dan baris bantuan (opsional).
* `fields` — maksimal 12 entri. Tiap field: `key` (nama mesin,
  `[a-z0-9_]`, maks 40), `label`, `type` (`text`, `password`, `number`,
  `boolean`), `required`, `placeholder`, `description`.
* Selama ada field **wajib** yang belum terisi untuk chat ini, host menahan
  eksekusi modul dan menampilkan formulirnya; setelah dikirim, nilai
  disimpan dan modul otomatis dijalankan.
* Nilai tersimpan di storage (chat, modul) di bawah kunci kooperatif
  `zagentsSetup` — ditulis host saat formulir dikirim, dan di-mirror oleh
  modul sendiri ketika konfigurasinya berubah lewat jalur lain (mis.
  setup perintah teks), supaya gate selalu mencerminkan kenyataan. Chat
  lain akan bertanya lagi: setup memang per chat.
* Baca nilainya di modul lewat `zagents.info.setup` (lihat di bawah) atau
  `await zagents.storage.get('zagentsSetup')`.
* Manifest tanpa blok `setup` (atau tanpa field wajib) tidak pernah
  memunculkan formulir — perilaku modul lama tidak berubah.

### Perintah slash — `commands` di module.json (v1.31.0)

Deklarasikan kata kunci yang ditangani modul Anda dan pengguna bisa
menjalankannya dengan mengetik `/<kata-kunci> …` langsung di chat — dari
pesan PERTAMA chat baru maupun di TENGAH chat:

```json
{ "name": "airplane-mode", "commands": ["airplane"], "permissions": ["device"] }
```

* Mengetik **`/airplane on`** di chat yang memiliki modul tersebut aktif
  menjalankan kembali entry point modul — pesan mentahnya tiba sebagai
  `zagents.info.prompt` — dan LLM TIDAK dipanggil untuk giliran itu.
* Bila belum ada modul aktif, modul terpasang yang mendeklarasikan kata
  kunci itu diaktifkan OTOMATIS oleh perintah (mengetiknya memang itu
  niatnya); persetujuan izin tetap berlaku seperti biasa.
* Saat modul ter-stage mendeklarasikan kata kunci yang diketik, pesan
  pertama dikonsumsi aktivasi staged — kontrak `info.prompt` yang sama.
* Disanitasi ketat: huruf kecil `[a-z0-9_-]`, maksimal 4 kata kunci, maks
  24 karakter masing-masing; bawaan `plugins`, `make_plugins` dan
  `doctor` dicadangkan dan ditolak.
* Run perintah memakai sandbox penuh (state per chat, izin, timeout) dan
  masuk transkrip sebagai pesan modul.

## 2. Memasang dan menjalankan

1. **Layar Modules** → *Pasang modul* → pilih file ZIP.
2. Jalankan di dalam chat:
   * Ketik **`/plugins`** → pilih modul dari menu interaktif, atau
   * Ketik **`/plugins modul-saya`**, atau
   * Pilih chip modul di layar chat baru, atau
   * Layar Modules → modul → *Mulai di chat baru*.
### Membuat modul DARI chat — `/make_plugins`

Sejak v1.27.0 agen chat bisa MEMBUATKAN modul untukmu dari dalam chat
yang sedang berjalan: ketik **`/make_plugins <deskripsi>`** (alias
`/make_plugin`, `/make_module`). Agen menulis folder modul, melakukan
self-check, mengemas zip lalu memanggil `module_stage_repair`; kamu
yang memutuskan instalasinya lewat kartu konfirmasi. Sebut data sesi
(unggahan, file workspace, pesan sebelumnya) di deskripsimu dan data
itu DISALIN KE DALAM modul — modul tidak bisa membaca workspace chat
saat runtime, jadi zip-nya selalu self-contained.

3. Entry point dieksekusi sekali per aktivasi. Output console dan nilai
   kembaliannya dikirim ke percakapan sebagai pesan modul; agen dapat
   membaca dan membahasnya.
   **Ramah-shebang:** baris `#!...` di paling atas (gaya Node) dan BOM
   UTF-8 dihapus otomatis sebelum source dijalankan, jadi skrip yang
   disalin langsung dari proyek Node tetap jalan apa adanya.
   **Setup dulu:** saat manifest mendeklarasikan field setup wajib,
   aplikasi menampilkan formulir setup per chat alih-alih menjalankan
   modul; run terjadi tepat setelah formulir dikirim (lihat di atas).
   **Tips setup:** saat modul dipilih di chat BARU (staged), pesan pertama
   yang Anda kirim diekspos ke modul sebagai `zagents.info.prompt` —
   modul tetap bisa menyediakan perintah seperti `setup <kredensial>`,
   `status` atau `reset` pada pesan itu untuk konfigurasi ulang chat yang
   sudah terisi.

## 3. SDK `zagents`

Tersedia sebagai global — atau `const zagents = require('zagents-sdk')`.

### `zagents.info`
Metadata: `name`, `version`, `title`, `sessionId`, `entry` — ditambah
`prompt` (pesan pengguna yang mengaktivasi) saat run dipicu pesan pertama
modul yang di-stage di draft baru, `userAgent` — identitas yang dipilih
pengguna di Setelan → User Agent — dan `setup`: nilai formulir setup per
chat yang sudah dikirim untuk chat ini (objek kosong bila belum setup).

**Kebijakan User-Agent:** modul selalu memakai identitas yang dikonfigurasi
di Setelan → User Agent. `zagents.http` mengirimkannya di setiap request,
dan header `User-Agent` dari modul dibuang oleh bridge — setelan SELALU
menang. Baca identitas aktif lewat `zagents.info.userAgent` (hanya untuk
tampilan atau debugging).

### `zagents.log(...)` — selalu tersedia
Output console, ditangkap ke dalam pesan modul.

### `zagents.storage` — izin `storage`
Penyimpanan kunci/nilai per chat. Chat berbeda TIDAK PERNAH berbagi.

```js
await zagents.storage.set('kunjungan', 1);
const kunjungan = await zagents.storage.get('kunjungan'); // 1
const kunci = await zagents.storage.keys();               // ['kunjungan']
await zagents.storage.remove('kunjungan');
```

Batas: 64 KB per nilai, 1 MB per (chat, modul).

### `zagents.fs` — izin `files`
Akses file terbatas pada direktori `state/` modul untuk chat ini.

```js
await zagents.fs.writeFile('catatan.txt', 'halo');
const teks = await zagents.fs.readFile('catatan.txt');
await zagents.fs.appendFile('catatan.txt', '\nlagi');
const daftar = await zagents.fs.readdir('.');
await zagents.fs.mkdir('sub');
await zagents.fs.unlink('catatan.txt');
const info = await zagents.fs.stat('sub'); // { isDirectory, size, modified }
```

Path di luar direktori `state/` ditolak. Penulisan ditegakkan ketat di
sisi Dart (v1.43.1): setiap aksi yang mengubah isi
(`writeFile` / `appendFile` / `mkdir` / `unlink`) wajib berada di bawah
direktori `state/` per chat tempat run berjalan — direktori program
modul yang global dan root npm tetap read-only, sehingga apa pun yang
disimpan modul tidak pernah bisa menjangkau chat lain. Pembacaan kode
modul (untuk `require`) tetap berjalan seperti biasa.

### `zagents.http` — izin `network`
HTTP melalui aplikasi (status + body + header respons), opsional dibatasi
host oleh `allowedHosts` di manifest.

```js
const res = await zagents.http.request('https://api.contoh.com/data', {
  method: 'POST',
  body: JSON.stringify({ q: 'hai' }),
  headers: { 'Content-Type': 'application/json' },
});
if (res.ok) {
  const data = await res.json();
  const cookie = res.headers['set-cookie']; // header respons (huruf kecil)
}
```

Opsi: `method`, `body`, `headers` (field hop-by-hop seperti `Host` dan
`Connection` dibuang; `User-Agent` juga dibuang — request selalu membawa
identitas Setelan → User Agent, lihat `zagents.info.userAgent`),
`timeoutMs` (batas seluruh request, maks 60000)
dan `headOnly: true` — kembali begitu status line + header tiba, tanpa
membaca body (memulai stream SSE tanpa menunggu stream itu selesai).

### `zagents.agent` — izin `agent`
Minta AGEN CHAT SENDIRI (provider/model yang dipakai chat ini) menyusun
SATU kalimat santai berbahasa Inggris dari konteks live yang modul
suplai. Tidak ada template: setiap kalimat digenerate saat dibutuhkan,
dan host menegakkan kontrak composer sebelum modul melihat teksnya:

* tepat satu kalimat, santai, terdengar seperti manusia, bahasa Inggris;
* tidak pernah memuat `!` `:` `;` `—` `–` `?` dan tanpa emoji;
* paling banyak `maxWords` kata (bawaan 24, rentang 1–40);
* tidak pernah mengulang teks yang diberikan lewat `avoid`;
* satu percobaan perbaikan otomatis, lalu satu pass sanitize
  deterministik — output yang masih melanggar melempar error sehingga
  modul bisa melewati aksi teks itu dengan anggun.

```js
const { text } = await zagents.agent.compose({
  task: 'chat-reply',
  context: barisChatTerakhir.join('\n'),
  instruction: 'reaksi atas pesan terakhir',
  maxWords: 16,
  avoid: teksTerakhirTerkirim,
});
```

Kegagalan (API key kosong, provider down, pelanggaran berulang) melempar
error — bungkus dengan try/catch dan lewati aksi teks tersebut bila
komposisi tidak memungkinkan.

#### `zagents.agent.polish({ template, context, ... })` — izin `agent` (v1.45.0)

Menulis ulang TEMPLATE balasan menjadi SATU balasan sosial yang natural
dan terdengar seperti manusia, menjawab pesan yang masuk — dibangun
untuk auto-reply komentar/Messenger Facebook dan auto-reply mention
X/Twitter (lihat [`samples/facebook-page/`](../../samples/facebook-page/)
dan [`samples/twitter-x/`](../../samples/twitter-x/)). Lebih bebas dari
`compose`: 1–3 kalimat, tanda baca normal (titik, koma, tanda tanya),
dan bahasa balasan mengikuti bahasa pengirim:

* modul mengisi semua slot template sendiri sebelum memanggil — output
  yang masih memuat `{slot}` yang belum terisi akan ditolak;
* tanpa markdown, tanpa list, tanpa link rekaan (URL hanya diizinkan
  bila template atau pesan masuk memang memuat URL), tanpa frasa gaya
  asisten ("as an AI", "hope this helps", …);
* anggaran karakter via `maxChars` (bawaan 280, rentang 20–500)
  menggantikan anggaran kata; emoji mati secara bawaan
  (`allowEmoji: true` mengizinkan satu);
* setiap janji/fakta pada template harus bertahan — agen tidak boleh
  mengarang harga, tanggal, nama atau fitur;
* pipeline yang sama: validate → satu percobaan perbaikan → sanitize →
  re-validate; kegagalan melempar error sehingga modul bisa jatuh kembali
  ke template-nya.

```js
const { text } = await zagents.agent.polish({
  template: 'Halo {name}, makasih sudah menghubungi kami...'.replace('{name}', namaDepan),
  context: teksKomenMasuk,
  language: 'auto',   // atau 'id', 'en', ...
  tone: 'friendly',   // atau 'professional', 'casual'
  maxChars: 300,
  allowEmoji: false,
  avoid: balasanTerakhirTerkirim,
});
```

### `zagents.chat` — izin `chat`
Kirim output bertahap ke percakapan selama modul berjalan:

```js
await zagents.chat.emit('Langkah 1 selesai…');
```

### `zagents.device` — izin `device` (v1.31.0)
Jalankan SATU perintah shell di perangkat — otomasi ponsel root seperti
mode pesawat, VPN, atau perubahan profil:

```js
const r = await zagents.device.shell('settings get global airplane_mode_on', {
  root: true,     // dijalankan via `su -c` — butuh ponsel root
  timeoutMs: 20000,
});
// r.ok, r.exitCode, r.stdout, r.stderr, r.timedOut, r.error
```

* `root: true` menjalankan perintah lewat `su -c`; tanpa itu perintah
  berjalan dengan uid aplikasi sendiri via `sh -c`.
* Tiga lapis gerbang: izin `device` di manifest (disetujui saat
  aktivasi) DAN sakelar utama **"Perintah perangkat (root)" di Setelan →
  Modul (mati secara bawaan)** DAN bridge native. Panggilan tanpa izin
  melempar `Permission denied: device` / menjelaskan sakelarnya.
* Batas: perintah ≤ 2000 karakter, timeout 1–120 detik (bawaan 30 dtk),
  stdout dan stderr masing-masing dibatasi 32 KB.
* Kegagalan (biner `su` hilang, error spawn) mengembalikan hasil dengan
  `error` terisi alih-alih melempar — cabang berdasarkan `r.ok`.
* Lihat [`samples/airplane-mode/`](../../samples/airplane-mode/) untuk
  modul otomasi root lengkap yang memakai perintah slash.

### `zagents.device.airplane()` — izin `device` (v1.32.0)
Baca **state mode pesawat TANPA root** dari setelan world-readable
`Settings.Global.AIRPLANE_MODE_ON`:

```js
const p = await zagents.device.airplane();
// p.available — true bila platform ini bisa membaca state asli
// p.on        — keadaan mode pesawat sebenarnya
```

* TANPA root dan TIDAK digerbangi sakelar "Perintah perangkat" — probe
  tidak bisa mengubah apa pun, hanya membaca satu setelan tak berbahaya.
* Bekerja **offline** (tanpa jaringan), sehingga modul mode pesawat
  manual bisa memverifikasi state asli selagi radio mati dan chat AI tak
  terjangkau.
* `available: false` (non-Android, sisi native hilang) berarti "tidak
  diketahui" — pakai instruksi manual, jangan mengklaim state yang tak
  pernah dilihat.

```js
// Pola manual (tanpa root) — verifikasi, jangan percaya "yes" buta:
const p = await zagents.device.airplane();
if (p.available && p.on) {
  await zagents.log('Mode pesawat AKTIF (terverifikasi).');
} else {
  await zagents.log('Masih OFF — nyalakan dari Quick Settings, lalu jalankan ulang.');
}
```

### `zagents.device.airplaneCycle(options?)` — izin `device` (v1.34.0)
Rotasi IP carrier dengan SATU perintah — seluruh siklus mode pesawat
dalam satu panggilan terverifikasi:

```js
const r = await zagents.device.airplaneCycle({ holdMs: 2500, settleMs: 8000 });
// r.wasOn — state mode pesawat terverifikasi sebelum siklus
// r.finalOn — selalu false: siklus SELALU berakhir OFF (online lagi)
// r.heldMs, r.settleMs — durasi tunggu yang diterapkan
// r.verified — true bila state OFF akhir dibaca ulang dari perangkat
```

Fisikanya: IP data ponsel berubah saat radio MENDAFTAR ULANG — yaitu
saat mode pesawat kembali OFF. Karena itu host menjalankan, berurutan:

1. baca state saat ini secara terverifikasi (`settings get`, fallback
   probe world-readable) — jangan pernah siklus secara buta;
2. pastikan mode pesawat ON — `settings put global airplane_mode_on 1` +
   broadcast legacy `AIRPLANE_MODE` (satu perintah gabungan), diverifikasi
   dengan membaca ulang; satu kali retry bila tak cocok;
3. TAHAN ON (`holdMs`, bawaan 2500 ms, dijepit 500–15000) — radio
   melepas registrasi;
4. mode pesawat OFF — put + broadcast, diverifikasi dengan membaca ulang
   (satu retry) — radio mendaftar ulang dan carrier memberi IP BARU;
5. settle (`settleMs`, bawaan 8000 ms, dijepit 0–30000).

* Siklus SELALU berakhir dengan mode pesawat OFF (online kembali).
  Verifikasi yang tetap gagal memicu pemulihan best-effort ke OFF —
  ponsel tak pernah dibiarkan diam-diam dalam mode pesawat.
* Gerbangnya persis seperti `device.shell`: izin `device`, sakelar utama
  **"Perintah perangkat (root)" di Setelan → Modul** dan ponsel root
  (perintah shell sungguhan). Tanpa root panggilan gagal dengan pesan
  actionable — pakai mode manual terpandu.
* Run yang dibatalkan di tengah siklus tetap memulihkan mode pesawat ke
  OFF, lalu selesai dengan `verified: false`.
* Lihat [`samples/airplane-mode/`](../../samples/airplane-mode/) —
  `/airplane cycle` (alias: `ip`, `rotate`).

## 4. Model isolasi (jendela privat per chat)

* **Proses** — setiap eksekusi memulai konteks JS baru; tidak ada yang
  bertahan antar run.
* **State & storage** — `<sesi>/modules/<nama>/` dibuat per chat;
  `storage.json` dan `state/` tidak terlihat oleh chat lain maupun modul
  lain.
* **Izin** — dideklarasikan di manifest, disetujui pengguna saat
  aktivasi, ditegakkan dua lapis (SDK + bridge Dart).
* **Jaringan** — butuh `network`; `allowedHosts` mempersempit lagi.
* **Agen** — butuh `agent`; generasi lewat LLM chat sendiri plus gerbang
  composer di sisi host, sehingga output modul selalu di dalam kontrak
  yang diatur.
* **Perangkat** — butuh `device`; `device.shell` dan `device.airplaneCycle`
  tambahan butuh sakelar utama Setelan (mati bawaan) dan memang untuk
  ponsel root (siklusnya adalah rotasi IP ON → tahan → OFF yang
  terverifikasi); `device.airplane` adalah probe baca-saja world-readable
  (tanpa sakelar utama, tanpa root). Setiap panggilan dicek ulang di host.
* **Sumber daya** — timeout, batas output, batas storage.
* **Penghentian** — menonaktifkan modul atau menghentikan chat membatalkan
  run yang berjalan dengan aman: pengiriman berhenti, state tersimpan.

## 5. Contoh minimal

Contoh yang sama, siap dipasang, ada di [`samples/counter/`](../../samples/counter/)
— bersama contoh lengkap lainnya yang mencakup semua izin:

| Contoh | Mendemonstrasikan |
|---|---|
| [`samples/counter/`](../../samples/counter/) | `storage` — penghitung aktivasi per chat |
| [`samples/network-fetcher/`](../../samples/network-fetcher/) | `network` — `zagents.http` + `allowedHosts` |
| [`samples/file-notes/`](../../samples/file-notes/) | `files` — catatan tersandbox di `state/` |
| [`samples/chat-streamer/`](../../samples/chat-streamer/) | `chat` — output bertahap `chat.emit` |
| [`samples/onhomeroom-daily/`](../../samples/onhomeroom-daily/) | `agent` — bot harian dunia nyata yang setiap kalimatnya disusun agen chat; formulir setup per chat untuk akunnya |
| [`samples/airplane-mode/`](../../samples/airplane-mode/) | `device` — pengalih mode pesawat + rotasi IP carrier satu perintah: AUTO (root) + mode MANUAL terverifikasi tanpa root, perintah slash `/airplane cycle \| on \| off \| status` (v1.32.0, siklus v1.34.0) |
| [`samples/facebook-page/`](../../samples/facebook-page/) | `agent` (`polish`) + `network` — asisten fanspage: auto-reply komentar + Messenger dengan template yang dipoles agen chat secara live, token Page per-chat via formulir setup (`/fb` v1.45.0) |
| [`samples/twitter-x/`](../../samples/twitter-x/) | `agent` (`polish`) + `network` — auto-reply mention X/Twitter dengan penanda tangan OAuth 1.0a JS murni, kunci user per-chat via formulir setup (`/tw` v1.45.0) |

`module.json`

```json
{
  "name": "penghitung-halo",
  "version": "1.0.0",
  "title": "Penghitung Halo",
  "description": "Menghitung aktivasi per chat.",
  "permissions": ["storage"]
}
```

`main.js`

```js
async function main() {
  const sebelumnya = (await zagents.storage.get('jumlah')) || 0;
  await zagents.storage.set('jumlah', sebelumnya + 1);
  zagents.log('Halo dari modul! Jumlah di chat INI: ' + (sebelumnya + 1));
  return { jumlah: sebelumnya + 1 };
}
module.exports = main();
```
