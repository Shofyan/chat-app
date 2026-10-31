package chat

import (
	"bytes"
	"database/sql"
	"errors"
	"io"
	"mime"
	"net/http"
	"path/filepath"
	"strings"
)

const maxFile = 8 << 20

func (s *Server) upload(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeConversation(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxFile+(64<<10))
	if err := r.ParseMultipartForm(maxFile); err != nil {
		fail(w, 413, "Unggahan tidak valid atau lebih dari 8 MB.")
		return
	}
	defer r.MultipartForm.RemoveAll()
	file, header, err := r.FormFile("file")
	if err != nil {
		fail(w, 400, "Pilih file terlebih dahulu.")
		return
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxFile+1))
	if err != nil || len(data) > maxFile || len(data) == 0 {
		fail(w, 413, "File harus berukuran 1 byte sampai 8 MB.")
		return
	}
	media, _, _ := mime.ParseMediaType(http.DetectContentType(data))
	allowed := map[string]bool{"image/jpeg": true, "image/png": true, "image/gif": true, "image/webp": true, "application/pdf": true, "text/plain": true}
	if !allowed[media] {
		fail(w, 415, "Gunakan JPEG, PNG, GIF, WebP, PDF, atau TXT.")
		return
	}
	name := filepath.Base(strings.ReplaceAll(header.Filename, "\\", "/"))
	if len(name) > 200 {
		name = "lampiran"
	}
	id := newID()
	_, err = s.db.ExecContext(r.Context(), "INSERT INTO attachments(id,conversation_id,owner_id,name,mime,size,data) VALUES($1,$2,$3,$4,$5,$6,$7)", id, r.PathValue("id"), currentUser(r), name, media, len(data), data)
	if err != nil {
		internal(w, err)
		return
	}
	respond(w, 201, map[string]any{"id": id, "name": name, "mime": media, "size": len(data)})
}
func (s *Server) download(w http.ResponseWriter, r *http.Request) {
	var cid, owner, name, media string
	var data []byte
	err := s.db.QueryRowContext(r.Context(), "SELECT conversation_id,owner_id,name,mime,data FROM attachments WHERE id=$1", r.PathValue("id")).Scan(&cid, &owner, &name, &media, &data)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			fail(w, 404, "Lampiran tidak ditemukan.")
		} else {
			internal(w, err)
		}
		return
	}
	if currentUser(r) != owner && !s.member(r.Context(), cid, currentUser(r)) {
		fail(w, 403, "Lampiran tidak dapat diakses.")
		return
	}
	w.Header().Set("Content-Type", media)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	http.ServeContent(w, r, name, zeroTime, bytes.NewReader(data))
}
