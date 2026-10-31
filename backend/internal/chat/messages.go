package chat

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// A single query produces the same message representation for REST and real-time events.
const messageJSON = `jsonb_build_object(
 'id',m.id::text,'conversation_id',m.conversation_id,'sender_id',m.sender_id,
 'client_id',m.client_id,'text',m.text,'created_at',m.created_at,
 'is_read',EXISTS(SELECT 1 FROM members rd WHERE rd.conversation_id=m.conversation_id AND rd.user_id<>m.sender_id AND rd.last_read_at>=m.created_at),
 'attachment',(SELECT jsonb_build_object('id',a.id,'name',a.name,'mime',a.mime,'size',a.size) FROM attachments a WHERE a.id=m.attachment_id),
 'reply',(SELECT jsonb_build_object('id',q.id::text,'text',CASE WHEN q.text='' THEN 'Lampiran' ELSE q.text END,'sender_name',u.name) FROM messages q JOIN users u ON u.id=q.sender_id WHERE q.id=m.reply_to_id),
 'reactions',COALESCE((SELECT jsonb_agg(jsonb_build_object('user_id',rx.user_id,'emoji',rx.emoji) ORDER BY rx.user_id) FROM reactions rx WHERE rx.message_id=m.id),'[]'::jsonb))`

func (s *Server) conversations(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `SELECT c.id,u.id,u.name,
 COALESCE(last.text,CASE WHEN last.attachment_id IS NOT NULL THEN 'Lampiran' ELSE 'Mulai percakapan' END),
 COALESCE(last.created_at,c.created_at),
 (SELECT count(*) FROM messages unread WHERE unread.conversation_id=c.id AND unread.sender_id<>$1 AND unread.created_at>mine.last_read_at)
 FROM conversations c JOIN members mine ON mine.conversation_id=c.id AND mine.user_id=$1
 JOIN members peer ON peer.conversation_id=c.id AND peer.user_id<>$1 JOIN users u ON u.id=peer.user_id
 LEFT JOIN LATERAL (SELECT text,attachment_id,created_at FROM messages WHERE conversation_id=c.id ORDER BY id DESC LIMIT 1) last ON true
 ORDER BY COALESCE(last.created_at,c.created_at) DESC,c.id LIMIT 200`, currentUser(r))
	if err != nil {
		internal(w, err)
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, peer, name, last string
		var updated any
		var unread int
		// Decode timestamps as time.Time through database/sql's native representation.
		if err := rows.Scan(&id, &peer, &name, &last, &updated, &unread); err != nil {
			internal(w, err)
			return
		}
		out = append(out, map[string]any{"id": id, "peer": User{ID: peer, Name: name, Online: s.hub.online(peer)}, "last_message": last, "updated_at": updated, "unread_count": unread})
	}
	if err := rows.Err(); err != nil {
		internal(w, err)
		return
	}
	respond(w, 200, map[string]any{"conversations": out})
}
func (s *Server) createConversation(w http.ResponseWriter, r *http.Request) {
	var in struct {
		UserID string `json:"user_id"`
	}
	if !decode(w, r, &in) {
		return
	}
	uid := currentUser(r)
	if in.UserID == uid || in.UserID == "" {
		fail(w, 400, "Pilih pengguna lain.")
		return
	}
	var peer User
	if err := s.db.QueryRowContext(r.Context(), "SELECT id,name FROM users WHERE id=$1", in.UserID).Scan(&peer.ID, &peer.Name); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			fail(w, 404, "Pengguna tidak ditemukan.")
		} else {
			internal(w, err)
		}
		return
	}
	ids := []string{uid, in.UserID}
	sort.Strings(ids)
	directKey := strings.Join(ids, ":")
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		internal(w, err)
		return
	}
	defer tx.Rollback()
	var id string
	err = tx.QueryRowContext(r.Context(), "INSERT INTO conversations(id,direct_key) VALUES($1,$2) ON CONFLICT(direct_key) DO UPDATE SET direct_key=excluded.direct_key RETURNING id", newID(), directKey).Scan(&id)
	if err == nil {
		_, err = tx.ExecContext(r.Context(), "INSERT INTO members(conversation_id,user_id) VALUES($1,$2),($1,$3) ON CONFLICT DO NOTHING", id, uid, in.UserID)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		internal(w, err)
		return
	}
	peer.Online = s.hub.online(peer.ID)
	s.emit(r.Context(), id, map[string]any{"type": "conversation"})
	respond(w, 200, map[string]any{"id": id, "peer": peer, "last_message": "Mulai percakapan", "unread_count": 0})
}
func (s *Server) messages(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeConversation(w, r) {
		return
	}
	before := int64(9223372036854775807)
	if v := r.URL.Query().Get("before"); v != "" {
		var err error
		before, err = strconv.ParseInt(v, 10, 64)
		if err != nil || before < 1 {
			fail(w, 400, "Cursor tidak valid.")
			return
		}
	}
	rows, err := s.db.QueryContext(r.Context(), "SELECT "+messageJSON+" FROM messages m WHERE m.conversation_id=$1 AND m.id<$2 ORDER BY m.id DESC LIMIT 51", r.PathValue("id"), before)
	if err != nil {
		internal(w, err)
		return
	}
	defer rows.Close()
	out := []json.RawMessage{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			internal(w, err)
			return
		}
		out = append(out, json.RawMessage(raw))
	}
	if err := rows.Err(); err != nil {
		internal(w, err)
		return
	}
	more := len(out) > 50
	if more {
		out = out[:50]
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	respond(w, 200, map[string]any{"messages": out, "has_more": more})
}
func optionalID(id string) any {
	if id == "" {
		return nil
	}
	return id
}
func (s *Server) sendMessage(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeConversation(w, r) {
		return
	}
	var in struct {
		ClientID     string `json:"client_id"`
		Text         string `json:"text"`
		AttachmentID string `json:"attachment_id"`
		ReplyToID    string `json:"reply_to_id"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Text = strings.TrimSpace(in.Text)
	cid, uid := r.PathValue("id"), currentUser(r)
	if len(in.ClientID) < 8 || len(in.ClientID) > 100 || !utf8.ValidString(in.Text) || utf8.RuneCountInString(in.Text) > 4000 || (in.Text == "" && in.AttachmentID == "") {
		fail(w, 400, "Isi pesan atau lampiran diperlukan; maksimal 4.000 karakter.")
		return
	}
	if in.ReplyToID != "" {
		id, err := strconv.ParseInt(in.ReplyToID, 10, 64)
		if err != nil || id <= 0 {
			fail(w, 400, "ID balasan tidak valid.")
			return
		}
		var ok bool
		err = s.db.QueryRowContext(r.Context(), "SELECT EXISTS(SELECT 1 FROM messages WHERE id=$1 AND conversation_id=$2)", id, cid).Scan(&ok)
		if err != nil {
			internal(w, err)
			return
		}
		if !ok {
			fail(w, 400, "Balasan harus berasal dari percakapan ini.")
			return
		}
	}
	if in.AttachmentID != "" {
		var ok bool
		err := s.db.QueryRowContext(r.Context(), "SELECT EXISTS(SELECT 1 FROM attachments WHERE id=$1 AND conversation_id=$2 AND owner_id=$3)", in.AttachmentID, cid, uid).Scan(&ok)
		if err != nil {
			internal(w, err)
			return
		}
		if !ok {
			fail(w, 400, "Lampiran tidak valid.")
			return
		}
	}
	var id int64
	err := s.db.QueryRowContext(r.Context(), `INSERT INTO messages(conversation_id,sender_id,client_id,text,attachment_id,reply_to_id) VALUES($1,$2,$3,$4,$5,$6)
 ON CONFLICT(sender_id,client_id) DO UPDATE SET client_id=excluded.client_id
 WHERE messages.conversation_id=excluded.conversation_id AND messages.text=excluded.text
 AND messages.attachment_id IS NOT DISTINCT FROM excluded.attachment_id AND messages.reply_to_id IS NOT DISTINCT FROM excluded.reply_to_id RETURNING id`, cid, uid, in.ClientID, in.Text, optionalID(in.AttachmentID), optionalID(in.ReplyToID)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		fail(w, 409, "client_id sudah dipakai untuk pesan berbeda.")
		return
	}
	if err != nil {
		internal(w, err)
		return
	}
	var raw []byte
	if err = s.db.QueryRowContext(r.Context(), "SELECT "+messageJSON+" FROM messages m WHERE m.id=$1", id).Scan(&raw); err != nil {
		internal(w, err)
		return
	}
	s.emit(r.Context(), cid, map[string]any{"type": "message", "message": json.RawMessage(raw)})
	respond(w, 201, json.RawMessage(raw))
}
func (s *Server) markRead(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeConversation(w, r) {
		return
	}
	var in struct {
		MessageID string `json:"message_id"`
	}
	if !decode(w, r, &in) {
		return
	}
	id, err := strconv.ParseInt(in.MessageID, 10, 64)
	if err != nil || id < 1 {
		fail(w, 400, "ID pesan tidak valid.")
		return
	}
	result, err := s.db.ExecContext(r.Context(), `UPDATE members SET last_read_at=GREATEST(last_read_at,(SELECT created_at FROM messages WHERE id=$1 AND conversation_id=$2))
 WHERE conversation_id=$2 AND user_id=$3 AND EXISTS(SELECT 1 FROM messages WHERE id=$1 AND conversation_id=$2)`, id, r.PathValue("id"), currentUser(r))
	if err != nil {
		internal(w, err)
		return
	}
	count, _ := result.RowsAffected()
	if count == 0 {
		fail(w, 404, "Pesan tidak ditemukan.")
		return
	}
	s.emit(r.Context(), r.PathValue("id"), map[string]any{"type": "read", "user_id": currentUser(r), "message_id": in.MessageID})
	w.WriteHeader(204)
}

var allowedEmoji = map[string]bool{"👍": true, "❤️": true, "😂": true, "😮": true, "😢": true, "🙏": true, "": true}

func (s *Server) react(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		fail(w, 400, "ID pesan tidak valid.")
		return
	}
	var cid string
	if err = s.db.QueryRowContext(r.Context(), "SELECT conversation_id FROM messages WHERE id=$1", id).Scan(&cid); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			fail(w, 404, "Pesan tidak ditemukan.")
		} else {
			internal(w, err)
		}
		return
	}
	if !s.member(r.Context(), cid, currentUser(r)) {
		fail(w, 403, "Anda bukan anggota percakapan ini.")
		return
	}
	var in struct {
		Emoji string `json:"emoji"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !allowedEmoji[in.Emoji] {
		fail(w, 400, "Reaksi tidak didukung.")
		return
	}
	if in.Emoji == "" {
		_, err = s.db.ExecContext(r.Context(), "DELETE FROM reactions WHERE message_id=$1 AND user_id=$2", id, currentUser(r))
	} else {
		_, err = s.db.ExecContext(r.Context(), "INSERT INTO reactions(message_id,user_id,emoji) VALUES($1,$2,$3) ON CONFLICT(message_id,user_id) DO UPDATE SET emoji=excluded.emoji", id, currentUser(r), in.Emoji)
	}
	if err != nil {
		internal(w, err)
		return
	}
	s.emit(r.Context(), cid, map[string]any{"type": "reaction", "message_id": r.PathValue("id"), "user_id": currentUser(r), "emoji": in.Emoji})
	w.WriteHeader(204)
}
