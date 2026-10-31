# Ruang Chat

Aplikasi chat Flutter untuk Android dan iOS dengan REST API + WebSocket Go, PostgreSQL, dan Docker Compose. Desain mengikuti konsep materi Pertemuan 5 dan 6: daftar percakapan, balon asimetris, input responsif, reply, media, status baca, dan tema adaptif. File presentasi hanya digunakan sebagai referensi materi.

## Menjalankan backend

Prasyarat: Docker dengan Compose. Flutter 3.47.5 / Dart 3.13+ untuk aplikasi, Go 1.25+ untuk pengembangan backend.

```bash
# Dari folder chat-app. .env opsional, nilai lokal sudah tersedia.
cp .env.example .env
docker compose up -d --build --wait
curl http://localhost:8080/health
```

API tersedia di port 8080. PostgreSQL hanya diakses dari jaringan Docker dan disimpan pada volume `ruang-chat_postgres_data`. Skema dibuat otomatis saat backend dimulai. `docker compose down` menghentikan layanan tanpa menghapus data. Mengubah password database di `.env` tidak mengubah password pada volume yang sudah diinisialisasi.

## Menjalankan aplikasi mobile

```bash
cd mobile
flutter pub get
flutter devices
flutter run
```

Alamat default Android emulator adalah `http://10.0.2.2:8080`; iOS Simulator dan web memakai `http://localhost:8080`. Pada ponsel fisik, sambungkan ke Wi-Fi yang sama dengan komputer dan gunakan IP LAN komputer:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080
```

Alamat juga dapat diubah melalui ikon pengaturan di halaman masuk dan tersimpan di perangkat. Alamat tersimpan mengungguli nilai build berikutnya; ubah kembali melalui halaman masuk bila berpindah server. Masukkan URL dasar tanpa `/api/v1`. Untuk Android melalui USB, alternatifnya `adb reverse tcp:8080 tcp:8080` lalu gunakan `http://localhost:8080` di pengaturan aplikasi.

Build APK pengujian:

```bash
cd mobile
flutter build apk --debug
# Dari root repo: mobile/build/app/outputs/flutter-apk/app-debug.apk
```

Build iOS memerlukan Xcode dan signing Anda untuk perangkat fisik. Izin kamera, galeri, jaringan lokal, dan Keychain sudah disiapkan. Konfigurasi HTTP Android/iOS ditujukan untuk server lokal; untuk distribusi gunakan HTTPS/WSS, hapus izin cleartext/ATS arbitrary loads, dan atur signing rilis. Docker menjalankan backend dan database; aplikasi mobile berjalan di emulator atau perangkat.

## Mencoba chat dua arah

Dengan `SEED_DEMO=true` (default lokal), akun dan contoh percakapan dibuat sekali:

| Nama | Email | Password |
| --- | --- | --- |
| Rina Novita | `rina@demo.local` | `ChatDemo123!` |
| Andi Pratama | `andi@demo.local` | `ChatDemo123!` |
| Sari Putri | `sari@demo.local` | `ChatDemo123!` |

1. Masuk sebagai Rina di emulator.
2. Masuk sebagai Andi pada perangkat lain atau versi web.
3. Buka percakapan Rina–Andi. Kirim pesan, geser pesan ke kanan untuk balasan, tekan lama untuk reaksi, dan unggah foto/dokumen.
4. Status online, mengetik, jumlah belum dibaca, dan centang baca mengikuti aktivitas pengguna sebenarnya. Tidak ada bot balasan otomatis.

Anda juga dapat mendaftarkan akun baru lalu memilih **Chat baru**. Pencarian kontak memakai nama, sehingga email tidak ditampilkan kepada pengguna lain. Matikan `SEED_DEMO` untuk database baru tanpa akun contoh; perubahan ini tidak menghapus data contoh yang sudah ada.

Versi web untuk pengujian tambahan:

```bash
cd mobile
flutter run -d chrome --web-port 3000
```

Origin web lokal port 3000 sudah diizinkan. Untuk origin lain, tambahkan URL lengkapnya ke `ALLOWED_ORIGINS` lalu recreate container API. Penyimpanan sesi web memerlukan localhost atau HTTPS.

## Fitur

- Registrasi, login, sesi 30 hari di secure storage, logout yang mencabut sesi server.
- Chat pribadi dua pengguna, pencarian kontak dan daftar chat, filter belum dibaca.
- WebSocket, reconnect otomatis, pengambilan ulang riwayat setelah tersambung.
- Riwayat persisten, pagination 50 pesan, waktu lokal, pemisah hari, pengiriman ulang idempoten.
- Balas lewat swipe atau tekan lama, kutipan dan pratinjau balasan.
- Foto galeri/kamera, preview dan zoom, unggah serta simpan PDF/TXT. Batas 8 MB; JPEG/PNG/GIF/WebP juga didukung.
- Reaksi emoji tersimpan, indikator mengetik, status online, centang baca, auto-scroll.
- Profil, transisi avatar Hero, tema sistem/terang/gelap yang tersimpan.
- Validasi input, pembatasan percobaan autentikasi, otorisasi anggota, unduhan lampiran dengan autentikasi.

Pencarian ruang chat menyaring riwayat yang sudah dimuat; gunakan **Muat pesan sebelumnya** untuk memperluasnya. Pesan dikirim ketika API tersedia dan draft tetap ada bila pengiriman gagal. Belum tersedia antrean offline, push notification, pesan suara, panggilan, grup, enkripsi end-to-end, atau pemulihan password. Tombol kosong di input membuka media, lalu beranimasi menjadi kirim ketika ada konten. Pesan ditandai dibaca saat ruang chat aktif dan daftar berada dekat pesan terbaru.

## Struktur

```text
backend/
  cmd/server/            HTTP, koneksi DB, graceful shutdown
  internal/chat/        Autentikasi, handler, skema, media, WebSocket, tes
  Dockerfile            Build multi-stage, proses non-root
mobile/
  lib/core/             Model, HTTP, sesi, reconnect WebSocket
  lib/screens/          Login, percakapan, chat, profil
  lib/widgets/          Tema, avatar, pesan, lampiran
docs/api.md             Kontrak REST dan event WebSocket
docs/openapi.json       Kontrak HTTP yang dapat diimpor ke Postman
scripts/test-backend.sh Tes dengan PostgreSQL sementara terisolasi
compose.yaml            API + PostgreSQL dengan healthcheck dan volume
```

REST menyimpan perubahan dahulu lalu WebSocket menyebarkan event kepada anggota. Token disimpan sebagai SHA-256 di server, password memakai bcrypt. Bytes lampiran disimpan dalam PostgreSQL sehingga backup database mencakup media. Skema awal idempoten; perubahan skema berikutnya memerlukan migrasi berversi. Hub WebSocket untuk satu instance API; replica tambahan memerlukan broker event.

## Pemeriksaan

```bash
make test
(cd backend && go vet ./...)
(cd mobile && flutter build web)
(cd mobile && flutter build apk --debug)
```

Untuk tes Android end-to-end, nyalakan emulator lalu jalankan dari root:

```bash
./scripts/test-mobile.sh emulator-5554
```

Script ini memakai backend dan volume sementara terpisah pada port 18081, lalu menghapusnya setelah tes. Screenshot tema terang/gelap disimpan di `.artifacts/screenshots`. Setelah tes, pasang kembali aplikasi normal dengan `cd mobile && flutter run -d emulator-5554` karena APK tes memakai entrypoint dan alamat server pengujian.

`scripts/test-backend.sh` membuat database sementara pada port acak localhost dan menghapus containernya setelah tes. Database aplikasi tidak diubah. Tes mencakup autentikasi, idempotensi, WebSocket, baca, reaksi, lampiran, penolakan akses pihak ketiga, kutipan lintas percakapan, serta cursor pagination. Tanpa `TEST_DATABASE_URL`, `go test ./...` melewati tes integrasi. CI menjalankan tes Go dengan race detector dan pemeriksaan Flutter.

Referensi: [Flutter deployment](https://docs.flutter.dev/deployment/android), [WebSocket Go](https://github.com/coder/websocket), [pgx](https://github.com/jackc/pgx), [file_picker](https://pub.dev/packages/file_picker), [secure storage](https://pub.dev/packages/flutter_secure_storage).
