package chat

import (
	"context"
	"database/sql"
	"errors"
	"net"
	"net/http"
	"net/mail"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/bcrypt"
)

type identityKey struct{}
type identity struct{ User, Hash string }
type User struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Email  string `json:"email,omitempty"`
	Online bool   `json:"online"`
}

func currentUser(r *http.Request) string { return r.Context().Value(identityKey{}).(identity).User }
func (s *Server) session(ctx context.Context, token string) (identity, error) {
	id := identity{Hash: tokenHash(token)}
	if len(token) != 64 {
		return id, errors.New("invalid token")
	}
	err := s.db.QueryRowContext(ctx, "SELECT user_id FROM sessions WHERE token_hash=$1 AND expires_at>now()", id.Hash).Scan(&id.User)
	return id, err
}
func (s *Server) auth(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		id, err := s.session(r.Context(), token)
		if err != nil {
			fail(w, 401, "Sesi berakhir. Silakan masuk kembali.")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), identityKey{}, id)))
	})
}
func (s *Server) issueSession(w http.ResponseWriter, r *http.Request, u User, code int) {
	token := newID() + newID()
	_, err := s.db.ExecContext(r.Context(), "INSERT INTO sessions(token_hash,user_id,expires_at) VALUES($1,$2,now()+interval '30 days')", tokenHash(token), u.ID)
	if err != nil {
		internal(w, err)
		return
	}
	respond(w, code, map[string]any{"token": token, "user": u})
}
func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, r) {
		return
	}
	var in struct {
		Name     string `json:"name"`
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	in.Email = strings.ToLower(strings.TrimSpace(in.Email))
	addr, err := mail.ParseAddress(in.Email)
	if err != nil || addr.Address != in.Email || len(in.Email) > 254 || utf8.RuneCountInString(in.Name) < 2 || utf8.RuneCountInString(in.Name) > 60 || len(in.Password) < 8 || len(in.Password) > 72 {
		fail(w, 400, "Nama 2–60 karakter, email valid, dan password 8–72 byte diperlukan.")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(in.Password), bcrypt.DefaultCost)
	if err != nil {
		internal(w, err)
		return
	}
	u := User{ID: newID(), Name: in.Name, Email: in.Email}
	_, err = s.db.ExecContext(r.Context(), "INSERT INTO users(id,name,email,password_hash) VALUES($1,$2,$3,$4)", u.ID, u.Name, u.Email, hash)
	if err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "23505" {
			fail(w, 409, "Email sudah terdaftar.")
		} else {
			internal(w, err)
		}
		return
	}
	s.issueSession(w, r, u, 201)
}

var dummyHash, _ = bcrypt.GenerateFromPassword([]byte("dummy-password-for-timing"), bcrypt.DefaultCost)

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, r) {
		return
	}
	var in struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	var u User
	var hash []byte
	err := s.db.QueryRowContext(r.Context(), "SELECT id,name,email,password_hash FROM users WHERE email=$1", strings.ToLower(strings.TrimSpace(in.Email))).Scan(&u.ID, &u.Name, &u.Email, &hash)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		internal(w, err)
		return
	}
	if err != nil {
		hash = dummyHash
	}
	valid := bcrypt.CompareHashAndPassword(hash, []byte(in.Password)) == nil
	if !valid || u.ID == "" {
		fail(w, 401, "Email atau password salah.")
		return
	}
	s.issueSession(w, r, u, 200)
}
func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	var u User
	err := s.db.QueryRowContext(r.Context(), "SELECT id,name,email FROM users WHERE id=$1", currentUser(r)).Scan(&u.ID, &u.Name, &u.Email)
	if err != nil {
		internal(w, err)
		return
	}
	respond(w, 200, u)
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	id := r.Context().Value(identityKey{}).(identity)
	if _, err := s.db.ExecContext(r.Context(), "DELETE FROM sessions WHERE token_hash=$1", id.Hash); err != nil {
		internal(w, err)
		return
	}
	s.hub.revoke(id.Hash)
	w.WriteHeader(204)
}
func (s *Server) users(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if utf8.RuneCountInString(q) > 100 {
		fail(w, 400, "Pencarian terlalu panjang.")
		return
	}
	rows, err := s.db.QueryContext(r.Context(), "SELECT id,name FROM users WHERE id<>$1 AND name ILIKE $2 ORDER BY name LIMIT 30", currentUser(r), "%"+q+"%")
	if err != nil {
		internal(w, err)
		return
	}
	defer rows.Close()
	users := []User{}
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Name); err != nil {
			internal(w, err)
			return
		}
		u.Online = s.hub.online(u.ID)
		users = append(users, u)
	}
	if err := rows.Err(); err != nil {
		internal(w, err)
		return
	}
	respond(w, 200, map[string]any{"users": users})
}

type attempt struct {
	Count int
	Until time.Time
}
type authLimiter struct {
	mu      sync.Mutex
	clients map[string]attempt
}

func newAuthLimiter() *authLimiter { return &authLimiter{clients: map[string]attempt{}} }
func (s *Server) allowAuth(w http.ResponseWriter, r *http.Request) bool {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	l := s.limiter
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	for k, v := range l.clients {
		if now.After(v.Until) {
			delete(l.clients, k)
		}
	}
	v := l.clients[ip]
	if v.Until.IsZero() {
		v.Until = now.Add(time.Minute)
	}
	v.Count++
	l.clients[ip] = v
	if v.Count > 20 || len(l.clients) > 10000 {
		w.Header().Set("Retry-After", "60")
		fail(w, 429, "Terlalu banyak percobaan. Coba lagi satu menit.")
		return false
	}
	return true
}

func (s *Server) seed(ctx context.Context) error {
	// All seed data is inserted atomically once. Restarting never recreates old messages.
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SELECT pg_advisory_xact_lock(8283771)"); err != nil {
		return err
	}
	var exists bool
	if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM users WHERE email='rina@demo.local')").Scan(&exists); err != nil {
		return err
	}
	if exists {
		return tx.Commit()
	}
	hash, err := bcrypt.GenerateFromPassword([]byte("ChatDemo123!"), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	for _, u := range []User{{ID: "demo-rina", Name: "Rina Novita", Email: "rina@demo.local"}, {ID: "demo-andi", Name: "Andi Pratama", Email: "andi@demo.local"}, {ID: "demo-sari", Name: "Sari Putri", Email: "sari@demo.local"}} {
		if _, err = tx.ExecContext(ctx, "INSERT INTO users(id,name,email,password_hash) VALUES($1,$2,$3,$4) ON CONFLICT(email) DO NOTHING", u.ID, u.Name, u.Email, hash); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO conversations(id,direct_key) VALUES('demo-flutter','demo-andi:demo-rina'),('demo-belajar','demo-rina:demo-sari') ON CONFLICT DO NOTHING"); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO members(conversation_id,user_id) VALUES('demo-flutter','demo-rina'),('demo-flutter','demo-andi'),('demo-belajar','demo-rina'),('demo-belajar','demo-sari') ON CONFLICT DO NOTHING"); err != nil {
		return err
	}
	texts := []string{"Hai Rina, sudah mulai tugas chat Flutter? 👋", "Sudah! Aku sedang merapikan tampilan ruang chat.", "Bagaimana kalau kita tambahkan fitur balas pesan?", "Setuju. Geser pesannya ke kanan untuk membalas ya ✨", "Siap! Nanti kita uji kirim pesan dari dua perangkat."}
	for i, text := range texts {
		sender := "demo-andi"
		if i%2 == 1 {
			sender = "demo-rina"
		}
		if _, err = tx.ExecContext(ctx, "INSERT INTO messages(conversation_id,sender_id,client_id,text,created_at) VALUES('demo-flutter',$1,$2,$3,now()-interval '10 minutes'+$4*interval '1 minute')", sender, "seed-"+string(rune('a'+i)), text, i); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO messages(conversation_id,sender_id,client_id,text) VALUES('demo-belajar','demo-sari','seed-sari','Besok belajar Flutter bareng, yuk! 📚')"); err != nil {
		return err
	}
	return tx.Commit()
}
