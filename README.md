# Lyricsbar

Lirik lagu yang sedang kamu putar di **Spotify** atau **Apple Music**, tampil sinkron di **Touch Bar** MacBook Pro.

> *English summary: Lyricsbar shows time-synced lyrics for the song playing in Spotify or Apple Music on the MacBook Pro Touch Bar, with a mini control strip (brightness, volume, mute, previous/play/next) and an emoji shortcut.*

## Fitur

- Lirik bersinkron per baris, dengan animasi **geser ke atas** (seperti lirik Spotify), **pudar**, atau tanpa animasi
- Perataan lirik **kiri / tengah / kanan**, di Touch Bar maupun di menu bar
- Control Strip mini: kecerahan, volume, mute, ⏮ ⏯ ⏭, dan tombol 😀 untuk pemilih emoji bawaan macOS
- **Offset per lagu** kalau liriknya terasa terlalu cepat atau lambat
- Mendukung **Spotify** dan **Apple Music**; pemutar yang sedang memutar lagu dipakai otomatis
- Otomatis kembali ke Touch Bar bawaan saat musik dijeda, dan "tidur" saat Spotify/Music ditutup
- Bisa dibuka otomatis saat login
- Tanpa akun, tanpa API key, tanpa mengumpulkan data

## Kebutuhan

- MacBook Pro **dengan Touch Bar** (2016–2022, Intel maupun Apple Silicon)
- **macOS 13 Ventura** atau lebih baru
- **Spotify** (app desktop) atau **Music** (Apple Music)

## Instalasi

1. Buka halaman [**Releases**](../../releases) dan unduh `Lyricsbar-<versi>.zip` terbaru.
2. Klik dua kali file zip-nya, lalu seret **Lyricsbar.app** ke folder **Applications**.
3. Buka Lyricsbar dari folder Applications. Lihat [Membuka app pertama kali](#membuka-app-pertama-kali) di bawah.
4. Saat diminta, klik **OK** supaya Lyricsbar boleh membaca Spotify/Music.
5. Putar lagu. Lirik muncul di Touch Bar, dan ikon ♪ muncul di menu bar.

### Membuka app pertama kali

Lyricsbar belum ditandatangani dengan sertifikat Apple Developer, jadi macOS akan menolak membukanya pertama kali ("Apple tidak dapat memeriksa…"). Ini normal untuk app gratis dari GitHub. Cara membukanya:

1. Coba buka Lyricsbar sekali, lalu tutup pesan peringatannya.
2. Buka **System Settings › Privacy & Security**.
3. Gulir ke bawah sampai bagian **Security**, lalu klik **Open Anyway** di sebelah tulisan tentang Lyricsbar.
4. Masukkan password Mac kamu, lalu klik **Open Anyway** sekali lagi.

Cukup sekali. Setelah itu Lyricsbar bisa dibuka seperti app biasa.

<details>
<summary>Alternatif lewat Terminal</summary>

```bash
xattr -dr com.apple.quarantine /Applications/Lyricsbar.app
```
</details>

## Cara pakai

Semua pengaturan ada di ikon **♪** di menu bar:

| Menu | Fungsi |
|---|---|
| Offset −0,5 / +0,5 / Reset | Menggeser waktu lirik lagu ini. **+** = lirik lebih awal, **−** = lebih lambat |
| Cari ulang lirik | Mencari lirik lagu ini lagi |
| Buka folder lirik sendiri… | Tempat menaruh file `.lrc` buatanmu |
| Animasi lirik | Geser ke atas, pudar, atau tanpa animasi |
| Perataan lirik | Rata kiri, tengah, atau kanan |
| Lirik juga di menu bar | Menampilkan baris lirik di menu bar |
| Buka saat login | Menjalankan Lyricsbar otomatis setiap login |

Di Touch Bar:

- **Logo pemutar** (kiri): membuka Spotify/Music
- **😀**: menampilkan Touch Bar app yang sedang kamu pakai (berisi pemilih emoji dan saran kata). Lirik kembali sendiri setelah 8 detik tanpa mengetik.
- **☀︎ / 🔊**: slider kecerahan / volume. Kembali ke lirik setelah 4 detik, atau ketuk **Selesai**.
- **🔇, ⏮, ⏯, ⏭**: mute, lagu sebelumnya, putar/jeda, lagu berikutnya

## Dari mana liriknya?

Lyricsbar mencari lirik bersinkron berurutan dari:

1. **File lokal** di `~/Music/Lyricsbar/` (dan `~/Music/LyricsX/` kalau sebelumnya kamu memakai LyricsX). Nama file: `Judul - Artis.lrc`
2. [**LRCLIB**](https://lrclib.net), database lirik terbuka dan gratis
3. **NetEase Cloud Music**, sebagai cadangan (banyak lagu Indonesia ada di sini)

Lirik resmi Spotify dan Apple Music **tidak** dipakai, karena tidak ada cara resmi untuk mengaksesnya.

Lagu kamu tidak ketemu? Buat file `.lrc` sendiri (misalnya dengan [LRCGET](https://github.com/tranxuanthang/lrcget)), simpan di folder lirik lewat menu ♪, lalu klik **Cari ulang lirik**. Lebih baik lagi, unggah ke LRCLIB supaya orang lain ikut terbantu.

## Privasi

- Lyricsbar tidak punya server, tidak memakai analytics, dan tidak mengumpulkan data.
- Untuk mencari lirik, **judul, artis, album, dan durasi** lagu dikirim ke LRCLIB dan NetEase. Lirik yang ketemu disimpan di `~/Library/Caches/local.touchbarlyrics/`.
- Izin yang diminta hanya **Automation** (membaca lagu dan posisi pemutaran dari Spotify/Music). Kecerahan dan volume diatur tanpa izin tambahan.

## Batasan

- Tampilan Touch Bar memakai API privat Apple (sama seperti LyricsX, Pock, dan MTMR). Update macOS berikutnya bisa merusaknya.
- Saat lirik tampil, Control Strip bawaan disembunyikan dan diganti versi mini milik Lyricsbar.
- Volume tidak bisa diatur saat suara keluar lewat HDMI. Ini batasan macOS; tombolnya akan tampil abu-abu.
- Ketepatan lirik bergantung pada sumbernya. Gunakan offset untuk merapikan.

## Build dari source

Butuh Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/<username>/Lyricsbar.git
cd Lyricsbar
./build.sh install    # build universal lalu pasang ke /Applications
```

| Perintah | Hasil |
|---|---|
| `./build.sh` | `build/Lyricsbar.app` |
| `./build.sh install` | Build lalu pasang ke `/Applications` |
| `./build.sh release` | `dist/Lyricsbar-<versi>.zip` untuk diunggah ke GitHub Releases |

Versi diambil dari `CFBundleShortVersionString` di `Info.plist`.

Untuk menguji pencarian lirik tanpa memutar lagu:

```bash
build/Lyricsbar.app/Contents/MacOS/Lyricsbar --lookup "Judul" "Artis" 240
```

## Kredit

- Lirik: [LRCLIB](https://lrclib.net) dan NetEase Cloud Music
- Ikon app: <!-- TODO: isi nama pembuat dan link sumber ikon (misalnya Flaticon), sesuai syarat lisensinya -->

Lyricsbar tidak berafiliasi dengan Spotify maupun Apple. Spotify, Apple Music, dan Touch Bar adalah merek dagang milik pemiliknya masing-masing.

## Lisensi

[MIT](LICENSE) © 2026 kintarous

Lisensi MIT berlaku untuk kode Lyricsbar. Ikon app punya lisensinya sendiri dari pembuatnya (lihat [Kredit](#kredit)).
