# Kontrak API Ruang Chat v1

Base URL lokal: `http://localhost:8080/api/v1`. Semua respons JSON, kecuali unduhan lampiran dan WebSocket. Error berbentuk `{"error":"pesan"}`. Semua ID dikirim sebagai string, waktu RFC3339 UTC. Autentikasi menggunakan `Authorization: Bearer <token>` dengan sesi 30 hari. Logout mencabut token di server.

| Method | Path | Input / hasil |
| --- | --- | --- |
| GET | `/health` (di luar `/api/v1`) | Kesiapan koneksi PostgreSQL |
| POST | `/auth/register` | `{name,email,password}` → 201 `{token,user}` |
| POST | `/auth/login` | `{email,password}` → `{token,user}` |
| POST | `/auth/logout` | Cabut sesi saat ini → 204 |
| GET | `/me` | Profil pengguna aktif |
| GET | `/users?q=...` | `{users:[]}`, maksimal 30, tanpa pengguna sendiri |
| GET | `/conversations` | `{conversations:[]}`, maksimal 200, terbaru dahulu |
| POST | `/conversations` | `{user_id}` → percakapan pribadi, pembuatan idempoten |
| GET | `/conversations/{id}/messages?before=ID` | `{messages:[],has_more:bool}`, 50 pesan, urutan lama ke baru; cursor ID eksklusif |
| POST | `/conversations/{id}/messages` | `{client_id,text,attachment_id?,reply_to_id?}` → 201 pesan. `client_id` unik per pengirim membuat pengiriman ulang idempoten |
| POST | `/conversations/{id}/read` | `{message_id}` → 204, majukan tanda baca sampai pesan tersebut |
| POST | `/conversations/{id}/attachments` | Multipart `file`, maksimum 8 MiB; JPEG/PNG/GIF/WebP/PDF/plain text → metadata lampiran |
| GET | `/attachments/{id}` | Bytes file, hanya anggota percakapan atau pemilik unggahan |
| PUT | `/messages/{id}/reaction` | `{emoji}`: 👍 ❤️ 😂 😮 😢 🙏 atau string kosong untuk hapus; satu reaksi per pengguna → 204 |
| GET | `/ws` | WebSocket, frame pertama `{"type":"auth","token":"..."}` dalam 5 detik |

JSON dibatasi 16 KiB, hanya `application/json` tanpa kompresi, satu objek lengkap, field asing dan duplikat ditolak. Nama 2–60 karakter, password 8–72 byte, teks maksimum 4.000 karakter; teks atau lampiran wajib ada. Lampiran dan kutipan harus berasal dari percakapan yang sama. Error: 400 input, 401 sesi, 403 anggota, 404 data, 409 email/client_id konflik, 413 ukuran, 415 media, 429 pembatasan autentikasi, 500 internal.

WebSocket hanya mengirim event; pesan persisten dikirim melalui HTTP. Setelah autentikasi server mengirim `ready`. Client mengirim `{"type":"typing","conversation_id":"...","typing":true}`. Server mengirim `message`, `read`, `reaction`, `typing`, `presence`, `conversation` dengan `conversation_id` dan payload terkait. Event terbatas pada anggota. Client mengambil ulang percakapan dan pesan setelah reconnect; event bukan antrean persisten. Status mengetik kedaluwarsa di client setelah 4 detik.

Pesan mencakup `id`, `conversation_id`, `sender_id`, `client_id`, `text`, `created_at`, `is_read`, `attachment` opsional (`id,name,mime,size`), `reply` opsional (`id,text,sender_name`), dan `reactions:[{user_id,emoji}]`. Percakapan mencakup `id`, `peer`, `last_message`, `updated_at`, `unread_count`. Profil publik hanya `id,name,online`; email hanya pada `/me` dan hasil autentikasi.

Koneksi WebSocket dibatasi per pengguna, frame maksimum 16 KiB, ping berkala dan pemeriksaan masa sesi. Saat shutdown, server menutup stream lalu menghentikan HTTP dan koneksi database. Implementasi satu instance backend; fanout multi-instance memerlukan broker tambahan.
