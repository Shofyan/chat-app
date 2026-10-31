package chat

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
	"time"
)

//go:embed schema.sql
var schema string

type Server struct {
	db      *sql.DB
	hub     *hub
	origins map[string]bool
	limiter *authLimiter
}

func New(ctx context.Context, db *sql.DB, origins []string, demo bool) (*Server, error) {
	if _, err := db.ExecContext(ctx, schema); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	s := &Server{db: db, hub: newHub(), origins: map[string]bool{}, limiter: newAuthLimiter()}
	for _, o := range origins {
		if o = strings.TrimSpace(o); o != "" {
			s.origins[o] = true
		}
	}
	if demo {
		if err := s.seed(ctx); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := s.db.PingContext(ctx); err != nil {
			fail(w, 503, "Database belum siap.")
			return
		}
		respond(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /api/v1/auth/register", s.register)
	mux.HandleFunc("POST /api/v1/auth/login", s.login)
	mux.HandleFunc("GET /api/v1/ws", s.socket)
	private := func(pattern string, handler http.HandlerFunc) { mux.Handle(pattern, s.auth(handler)) }
	private("GET /api/v1/me", s.me)
	private("POST /api/v1/auth/logout", s.logout)
	private("GET /api/v1/users", s.users)
	private("GET /api/v1/conversations", s.conversations)
	private("POST /api/v1/conversations", s.createConversation)
	private("GET /api/v1/conversations/{id}/messages", s.messages)
	private("POST /api/v1/conversations/{id}/messages", s.sendMessage)
	private("POST /api/v1/conversations/{id}/read", s.markRead)
	private("POST /api/v1/conversations/{id}/attachments", s.upload)
	private("GET /api/v1/attachments/{id}", s.download)
	private("PUT /api/v1/messages/{id}/reaction", s.react)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				slog.Error("request panic", "error", v)
				fail(w, 500, "Terjadi kesalahan server.")
			}
		}()
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		if origin := r.Header.Get("Origin"); origin != "" {
			if !s.origins[origin] {
				fail(w, 403, "Origin tidak diizinkan.")
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Add("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
			if r.Method == http.MethodOptions {
				w.WriteHeader(204)
				return
			}
		}
		// Streaming has its own heartbeat and deadlines; finite requests get a DB context budget.
		if r.URL.Path != "/api/v1/ws" {
			ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
			defer cancel()
			r = r.WithContext(ctx)
		}
		mux.ServeHTTP(w, r)
	})
}

func (s *Server) Close() { s.hub.shutdown() }
func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if value != nil {
		_ = json.NewEncoder(w).Encode(value)
	}
}
func fail(w http.ResponseWriter, status int, message string) {
	respond(w, status, map[string]string{"error": message})
}
func internal(w http.ResponseWriter, err error) {
	slog.Error("database operation failed", "error", err)
	fail(w, 500, "Terjadi kesalahan server.")
}
func newID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func tokenHash(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

func decode(w http.ResponseWriter, r *http.Request, target any) bool {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" || r.Header.Get("Content-Encoding") != "" {
		fail(w, 415, "Gunakan application/json tanpa kompresi.")
		return false
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 16<<10))
	if err != nil {
		var limit *http.MaxBytesError
		if errors.As(err, &limit) {
			fail(w, 413, "JSON terlalu besar.")
		} else {
			fail(w, 400, "JSON tidak valid.")
		}
		return false
	}
	if !json.Valid(data) || rejectDuplicates(data) != nil || len(bytes.TrimSpace(data)) == 0 || bytes.TrimSpace(data)[0] != '{' {
		fail(w, 400, "Kirim satu objek JSON tanpa field duplikat.")
		return false
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		fail(w, 400, "Field JSON tidak valid.")
		return false
	}
	return true
}

func rejectDuplicates(data []byte) error {
	d := json.NewDecoder(bytes.NewReader(data))
	var walk func() error
	walk = func() error {
		t, err := d.Token()
		if err != nil {
			return err
		}
		delim, ok := t.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for d.More() {
				key, err := d.Token()
				if err != nil {
					return err
				}
				k := key.(string)
				if seen[k] {
					return errors.New("duplicate key")
				}
				seen[k] = true
				if err := walk(); err != nil {
					return err
				}
			}
		case '[':
			for d.More() {
				if err := walk(); err != nil {
					return err
				}
			}
		default:
			return errors.New("unexpected delimiter")
		}
		_, err = d.Token()
		return err
	}
	return walk()
}

func (s *Server) member(ctx context.Context, conversation, user string) bool {
	var exists bool
	err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM members WHERE conversation_id=$1 AND user_id=$2)", conversation, user).Scan(&exists)
	return err == nil && exists
}
func (s *Server) authorizeConversation(w http.ResponseWriter, r *http.Request) bool {
	if !s.member(r.Context(), r.PathValue("id"), currentUser(r)) {
		fail(w, 403, "Anda bukan anggota percakapan ini.")
		return false
	}
	return true
}
func (s *Server) emit(ctx context.Context, conversation string, event map[string]any) {
	event["conversation_id"] = conversation
	rows, err := s.db.QueryContext(ctx, "SELECT user_id FROM members WHERE conversation_id=$1", conversation)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			s.hub.send(id, event)
		}
	}
}
