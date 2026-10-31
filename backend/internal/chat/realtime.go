package chat

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

var zeroTime time.Time

type client struct {
	user, hash string
	conn       *websocket.Conn
	send       chan []byte
	cancel     context.CancelFunc
}
type hub struct {
	mu      sync.RWMutex
	clients map[string]map[*client]bool
	closed  bool
}

func newHub() *hub { return &hub{clients: map[string]map[*client]bool{}} }
func (h *hub) online(user string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients[user]) > 0
}
func (h *hub) add(c *client) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed || len(h.clients[c.user]) >= 5 {
		return false
	}
	if h.clients[c.user] == nil {
		h.clients[c.user] = map[*client]bool{}
	}
	h.clients[c.user][c] = true
	return true
}
func (h *hub) remove(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients[c.user], c)
	if len(h.clients[c.user]) == 0 {
		delete(h.clients, c.user)
	}
}
func (h *hub) send(user string, event map[string]any) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.clients[user] {
		select {
		case c.send <- data:
		default:
			c.cancel()
		}
	}
}
func (h *hub) revoke(hash string) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, cs := range h.clients {
		for c := range cs {
			if c.hash == hash {
				c.cancel()
			}
		}
	}
}
func (h *hub) shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for _, cs := range h.clients {
		for c := range cs {
			c.cancel()
		}
	}
}
func (s *Server) presence(user string) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT other.user_id FROM members mine JOIN members other ON mine.conversation_id=other.conversation_id WHERE mine.user_id=$1 AND other.user_id<>$1`, user)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var peer string
		if rows.Scan(&peer) == nil {
			s.hub.send(peer, map[string]any{"type": "presence", "user_id": user, "online": s.hub.online(user)})
		}
	}
}
func (s *Server) socket(w http.ResponseWriter, r *http.Request) {
	// Origin is checked by the outer HTTP handler before this upgrade.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(16 << 10)
	// The HTTP server's finite-body timeout must not cap this long-lived stream.
	_ = http.NewResponseController(w).SetReadDeadline(time.Time{})
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	authCtx, authCancel := context.WithTimeout(ctx, 5*time.Second)
	_, data, err := conn.Read(authCtx)
	authCancel()
	if err != nil {
		return
	}
	var auth struct {
		Type  string `json:"type"`
		Token string `json:"token"`
	}
	if json.Unmarshal(data, &auth) != nil || auth.Type != "auth" {
		_ = conn.Close(websocket.StatusPolicyViolation, "Autentikasi diperlukan")
		return
	}
	checkCtx, checkCancel := context.WithTimeout(ctx, 5*time.Second)
	id, err := s.session(checkCtx, auth.Token)
	checkCancel()
	if err != nil {
		_ = conn.Close(websocket.StatusPolicyViolation, "Sesi berakhir")
		return
	}
	c := &client{user: id.User, hash: id.Hash, conn: conn, send: make(chan []byte, 64), cancel: cancel}
	if !s.hub.add(c) {
		_ = conn.Close(websocket.StatusTryAgainLater, "Batas koneksi")
		return
	}
	defer func() { s.hub.remove(c); s.presence(c.user) }()
	s.hub.send(c.user, map[string]any{"type": "ready"})
	s.presence(c.user)
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		defer cancel()
		ticker := time.NewTicker(25 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case data := <-c.send:
				writeCtx, done := context.WithTimeout(ctx, 5*time.Second)
				err := conn.Write(writeCtx, websocket.MessageText, data)
				done()
				if err != nil {
					return
				}
			case <-ticker.C:
				pingCtx, done := context.WithTimeout(ctx, 8*time.Second)
				_, err := s.session(pingCtx, auth.Token)
				if err == nil {
					err = conn.Ping(pingCtx)
				}
				done()
				if err != nil {
					return
				}
			}
		}
	}()
	defer func() { cancel(); conn.CloseNow(); <-writerDone }()
	var lastTyping time.Time
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var event struct {
			Type           string `json:"type"`
			ConversationID string `json:"conversation_id"`
			Typing         bool   `json:"typing"`
		}
		if json.Unmarshal(data, &event) != nil {
			continue
		}
		if event.Type != "typing" || (event.Typing && time.Since(lastTyping) < time.Second) {
			continue
		}
		lastTyping = time.Now()
		queryCtx, done := context.WithTimeout(ctx, 3*time.Second)
		if s.member(queryCtx, event.ConversationID, c.user) {
			s.emit(queryCtx, event.ConversationID, map[string]any{"type": "typing", "user_id": c.user, "typing": event.Typing})
		}
		done()
	}
}
