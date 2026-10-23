<div align="center">

<img src="docs/icon.png" width="128" alt="Ikon Lyricsbar">

# Lyricsbar

**Lirik lagu yang sedang kamu putar, tampil sinkron di Touch Bar.**
<br>
Untuk Spotify dan Apple Music di MacBook Pro.

[![Rilis terbaru](https://img.shields.io/github/v/release/kintarous/lyricsbar?style=flat-square&label=rilis&color=2ecc71)](https://github.com/kintarous/lyricsbar/releases/latest)
[![Unduhan](https://img.shields.io/github/downloads/kintarous/lyricsbar/total?style=flat-square&label=unduhan&color=2ecc71)](https://github.com/kintarous/lyricsbar/releases)
[![Lisensi MIT](https://img.shields.io/github/license/kintarous/lyricsbar?style=flat-square&label=lisensi)](LICENSE)
<br>
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white)](#kebutuhan)
[![Universal](https://img.shields.io/badge/Intel%20%2B%20Apple%20Silicon-universal-555555?style=flat-square)](#kebutuhan)
[![Touch Bar](https://img.shields.io/badge/Touch%20Bar-wajib-555555?style=flat-square)](#kebutuhan)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?style=flat-square&logo=swift&logoColor=white)](Sources/main.swift)
<br>
[![Spotify](https://img.shields.io/badge/Spotify-didukung-1DB954?style=flat-square&logo=spotify&logoColor=white)](#fitur)
[![Apple Music](https://img.shields.io/badge/Apple%20Music-didukung-FA243C?style=flat-square&logo=applemusic&logoColor=white)](#fitur)

<br>

<a href="https://github.com/kintarous/lyricsbar/releases/latest">
  <img src="https://img.shields.io/badge/⬇%20Unduh%20Lyricsbar-.dmg-2ecc71?style=for-the-badge" alt="Unduh Lyricsbar">
</a>

<br><br>

<img src="docs/preview-lyrics.png" alt="Pratinjau Lyricsbar: lirik di Touch Bar dengan tombol kontrol" width="100%">

<sub><i>Ilustrasi tampilan. Teks liriknya hanya contoh.</i></sub>

</div>

<br>

> 🇬🇧 *Lyricsbar shows time-synced lyrics for the song playing in Spotify or Apple Music on the MacBook Pro Touch Bar, with a mini control strip (brightness, volume, mute, previous/play/next) and an emoji shortcut. Free, open source, no account needed.*

## Fitur

|  |  |
|---|---|
| 🎤 **Lirik sinkron** | Berganti baris tepat waktu, dengan animasi geser ke atas ala Spotify, pudar, atau tanpa animasi |
| 🎛️ **Control Strip mini** | Kecerahan, volume, mute, ⏮ ⏯ ⏭, langsung dari Touch Bar |
| 😀 **Emoji** | Satu ketukan untuk memunculkan pemilih emoji dan saran kata bawaan macOS |
| ↔️ **Perataan** | Rata kiri, tengah, atau kanan, di Touch Bar maupun menu bar |
| ⏱️ **Offset per lagu** | Lirik terlalu cepat atau lambat? Geser ±0,5 detik, tersimpan per lagu |
| 🎧 **Spotify & Apple Music** | Pemutar yang sedang memutar lagu dipakai otomatis |
| 💤 **Tahu diri** | Kembali ke Touch Bar bawaan saat musik dijeda, dan "tidur" saat pemutar ditutup |
| 🔒 **Privat** | Tanpa akun, tanpa API key, tanpa analytics |

<div align="center">
<img src="docs/preview-slider.png" alt="Pratinjau slider kecerahan bergaya glass" width="100%">
<br>
<sub><i>Ketuk ☀︎ atau 🔊: slider lebar bergaya glass, kembali ke lirik sendiri setelah 4 detik.</i></sub>
</div>

## Kebutuhan

- 💻 MacBook Pro **dengan Touch Bar** (2016–2022, Intel maupun Apple Silicon)
- 🍎 **macOS 13 Ventura** atau lebih baru
- 🎵 App desktop **Spotify** atau **Music** (Apple Music)

## Instalasi

1. **Unduh** `Lyricsbar-<versi>.dmg` dari halaman [Releases](https://github.com/kintarous/lyricsbar/releases/latest).
2. **Buka** file DMG-nya, lalu **seret Lyricsbar** ke ikon **Applications**.
3. **Jalankan** Lyricsbar, izinkan akses ke Spotify/Music, lalu putar lagu. 🎶

> [!IMPORTANT]
> **Pertama kali dibuka, macOS akan menolak Lyricsbar** ("Apple tidak dapat memeriksa…"). Ini normal untuk app gratis yang belum ditandatangani dengan sertifikat Apple Developer. Caranya:
>
> 1. Buka Lyricsbar sekali, lalu tutup pesan peringatannya.
> 2. Buka **System Settings › Privacy & Security**, gulir ke bagian **Security**.
> 3. Klik **Open Anyway** di sebelah tulisan tentang Lyricsbar, masukkan password Mac, lalu klik **Open Anyway** lagi.
>
> Cukup sekali. Setelah itu Lyricsbar bisa dibuka seperti app biasa.

<details>
<summary>Alternatif: lewat Terminal</summary>

```bash
xattr -dr com.apple.quarantine /Applications/Lyricsbar.app
```
</details>

## Cara pakai

Semua pengaturan ada di ikon **♪** di menu bar.

<details>
<summary><b>Menu ♪</b></summary>

| Menu | Fungsi |
|---|---|
| Offset −0,5 / +0,5 / Reset | Menggeser waktu lirik lagu ini. **+** = lebih awal, **−** = lebih lambat |
| Cari ulang lirik | Mencari lirik lagu ini lagi |
| Buka folder lirik sendiri… | Tempat menaruh file `.lrc` buatanmu |
| Animasi lirik | Geser ke atas, pudar, atau tanpa animasi |
| Perataan lirik | Rata kiri, tengah, atau kanan |
| Lirik juga di menu bar | Menampilkan baris lirik di menu bar |
| Buka saat login | Menjalankan Lyricsbar otomatis setiap login |
</details>

<details>
<summary><b>Tombol di Touch Bar</b></summary>

| Tombol | Fungsi |
|---|---|
| Logo pemutar | Membuka Spotify/Music |
| 😀 | Menampilkan Touch Bar app yang sedang kamu pakai (pemilih emoji dan saran kata). Lirik kembali sendiri setelah 8 detik tanpa mengetik |
| ☀︎ / 🔊 | Slider kecerahan / volume. Kembali ke lirik setelah 4 detik, atau ketuk **Selesai** |
| 🔇 | Mute |
| ⏮ ⏯ ⏭ | Lagu sebelumnya, putar/jeda, lagu berikutnya |
</details>

## Dari mana liriknya?

Lyricsbar mencari lirik bersinkron berurutan dari:

1. 📁 **File lokal**: `~/Music/Lyricsbar/` (dan `~/Music/LyricsX/` kalau sebelumnya kamu memakai LyricsX), dengan nama file `Judul - Artis.lrc`
2. 🌐 [**LRCLIB**](https://lrclib.net): database lirik terbuka dan gratis
3. 🌏 **NetEase Cloud Music**: cadangan, dan banyak lagu Indonesia ada di sini

Lirik resmi Spotify dan Apple Music **tidak** dipakai, karena tidak ada cara resmi untuk mengaksesnya.

> [!TIP]
> Lagu kamu tidak ketemu? Buat file `.lrc` sendiri (misalnya dengan [LRCGET](https://github.com/tranxuanthang/lrcget)), simpan lewat menu ♪ › **Buka folder lirik sendiri…**, lalu klik **Cari ulang lirik**. Lebih baik lagi, unggah ke LRCLIB supaya orang lain ikut terbantu.

## Privasi

- Tidak ada server, analytics, atau pengumpulan data.
- Untuk mencari lirik, **judul, artis, album, dan durasi** lagu dikirim ke LRCLIB dan NetEase. Lirik yang ketemu disimpan di `~/Library/Caches/local.touchbarlyrics/`.
- Satu-satunya izin yang diminta adalah **Automation**, untuk membaca lagu dan posisi pemutaran dari Spotify/Music. Kecerahan dan volume diatur tanpa izin tambahan.

## Batasan

- Tampilan Touch Bar memakai API privat Apple (sama seperti LyricsX, Pock, dan MTMR). Update macOS berikutnya bisa merusaknya.
- Saat lirik tampil, Control Strip bawaan disembunyikan dan diganti versi mini milik Lyricsbar.
- Volume tidak bisa diatur saat suara keluar lewat HDMI. Ini batasan macOS; tombolnya akan tampil abu-abu.
- Ketepatan lirik bergantung pada sumbernya. Gunakan offset untuk merapikan.

## Build dari source

Butuh Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/kintarous/lyricsbar.git
cd lyricsbar
./build.sh install
```

<details>
<summary>Perintah lainnya</summary>

| Perintah | Hasil |
|---|---|
| `./build.sh` | `build/Lyricsbar.app` (universal) |
| `./build.sh install` | Build lalu pasang ke `/Applications` |
| `./build.sh release` | `dist/Lyricsbar-<versi>.dmg` dan `.zip` untuk GitHub Releases |

Versi diambil dari `CFBundleShortVersionString` di `Info.plist`.

Untuk menguji pencarian lirik tanpa memutar lagu:

```bash
build/Lyricsbar.app/Contents/MacOS/Lyricsbar --lookup "Judul" "Artis" 240
```
</details>

## Kredit

- Lirik: [LRCLIB](https://lrclib.net) dan NetEase Cloud Music
- Ikon app: <a href="https://www.flaticon.com/free-icon/music-book_4675527" title="music book icons">Music book icons created by Magnific - Flaticon</a> (Flaticon License, gratis dengan atribusi)

Lyricsbar tidak berafiliasi dengan Spotify maupun Apple. Spotify, Apple Music, dan Touch Bar adalah merek dagang milik pemiliknya masing-masing.

## Lisensi

[MIT](LICENSE) © 2026 kintarous

Lisensi MIT berlaku untuk kode Lyricsbar. Ikon app punya lisensinya sendiri dari pembuatnya (lihat [Kredit](#kredit)).

<div align="center">
<br>
<sub>Dibuat dengan ♪ untuk Touch Bar yang terlalu sering diabaikan.</sub>
</div>
