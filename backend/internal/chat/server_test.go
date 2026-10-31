package chat

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	_ "github.com/jackc/pgx/v5/stdlib"
)

func TestJSONBoundary(t *testing.T) {
	for _, tc := range []struct {
		name, body, media, encoding string
		status                      int
	}{
		{"valid", `{"name":"Rina"}`, "application/json", "", 200},
		{"empty", "", "application/json", "", 400},
		{"null", "null", "application/json", "", 400},
		{"trailing", `{"name":"Rina"} {}`, "application/json", "", 400},
		{"unknown", `{"name":"Rina","admin":true}`, "application/json", "", 400},
		{"duplicate", `{"name":"Rina","name":"Eve"}`, "application/json", "", 400},
		{"oversized", `{"name":"` + strings.Repeat("a", 16<<10) + `"}`, "application/json", "", 413},
		{"media", `{"name":"Rina"}`, "text/plain", "", 415},
		{"compressed", `{"name":"Rina"}`, "application/json", "gzip", 415},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", "/", strings.NewReader(tc.body))
			r.Header.Set("Content-Type", tc.media)
			r.Header.Set("Content-Encoding", tc.encoding)
			w := httptest.NewRecorder()
			var input struct {
				Name string `json:"name"`
			}
			if decode(w, r, &input) {
				w.WriteHeader(200)
			}
			if w.Code != tc.status {
				t.Fatalf("got %d, want %d: %s", w.Code, tc.status, w.Body.String())
			}
		})
	}
}

type fixture struct {
	*testing.T
	app  *Server
	http *httptest.Server
	db   *sql.DB
}

func setup(t *testing.T) *fixture {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_DATABASE_URL to run PostgreSQL integration tests")
	}
	admin, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	schemaName := "test_" + newID()
	if _, err = admin.Exec("CREATE SCHEMA " + schemaName); err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	q.Set("search_path", schemaName)
	u.RawQuery = q.Encode()
	db, err := sql.Open("pgx", u.String())
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(10)
	app, err := New(context.Background(), db, []string{"http://localhost:3000"}, false)
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{T: t, app: app, http: httptest.NewServer(app.Handler()), db: db}
	t.Cleanup(func() {
		app.Close()
		f.http.Close()
		db.Close()
		admin.Exec("DROP SCHEMA " + schemaName + " CASCADE")
		admin.Close()
	})
	return f
}
func (f *fixture) request(method, path, token string, body any, want int) map[string]any {
	f.Helper()
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			f.Fatal(err)
		}
		reader = bytes.NewReader(b)
	}
	r, err := http.NewRequest(method, f.http.URL+"/api/v1"+path, reader)
	if err != nil {
		f.Fatal(err)
	}
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		f.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode != want {
		f.Fatalf("%s %s got %d want %d: %s", method, path, res.StatusCode, want, data)
	}
	out := map[string]any{}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &out); err != nil {
			f.Fatal(err)
		}
	}
	return out
}
func (f *fixture) register(name string) (string, string) {
	out := f.request("POST", "/auth/register", "", map[string]any{"name": name, "email": strings.ToLower(name) + "@example.com", "password": "testing123!"}, 201)
	return out["token"].(string), out["user"].(map[string]any)["id"].(string)
}
func (f *fixture) socket(token string) *websocket.Conn {
	f.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(f.http.URL, "http")+"/api/v1/ws", nil)
	if err != nil {
		f.Fatal(err)
	}
	f.Cleanup(func() { c.CloseNow() })
	b, _ := json.Marshal(map[string]string{"type": "auth", "token": token})
	if err = c.Write(ctx, websocket.MessageText, b); err != nil {
		f.Fatal(err)
	}
	f.event(c, "ready")
	return c
}
func (f *fixture) event(c *websocket.Conn, kind string) map[string]any {
	f.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, b, err := c.Read(ctx)
		if err != nil {
			f.Fatal(err)
		}
		var event map[string]any
		if err = json.Unmarshal(b, &event); err != nil {
			f.Fatal(err)
		}
		if event["type"] == kind {
			return event
		}
	}
}

func TestChatIntegration(t *testing.T) {
	f := setup(t)
	alice, aliceID := f.register("Alice")
	bob, bobID := f.register("Bob")
	eve, _ := f.register("Eve")
	f.request("GET", "/me", "", nil, 401)
	f.request("POST", "/auth/login", "", map[string]string{"email": "alice@example.com", "password": "bad"}, 401)
	f.request("POST", "/auth/register", "", map[string]string{"name": "Alice", "email": "alice@example.com", "password": "testing123!"}, 409)
	conversation := f.request("POST", "/conversations", alice, map[string]string{"user_id": bobID}, 200)
	cid := conversation["id"].(string)
	again := f.request("POST", "/conversations", bob, map[string]string{"user_id": aliceID}, 200)
	if again["id"] != cid {
		t.Fatal("direct chat duplicated")
	}
	f.request("GET", "/conversations/"+cid+"/messages", eve, nil, 403)
	f.request("POST", "/conversations/"+cid+"/messages", eve, map[string]string{"client_id": "unauthorized", "text": "secret"}, 403)
	f.request("POST", "/conversations/"+cid+"/messages", alice, map[string]string{"client_id": "empty-message", "text": "   "}, 400)
	wsAlice := f.socket(alice)
	wsBob := f.socket(bob)
	message := f.request("POST", "/conversations/"+cid+"/messages", alice, map[string]string{"client_id": "unique-first-message", "text": "Halo Bob 👋"}, 201)
	mid := message["id"].(string)
	if f.event(wsBob, "message")["message"].(map[string]any)["id"] != mid {
		t.Fatal("websocket missed persisted message")
	}
	f.event(wsAlice, "message")
	duplicate := f.request("POST", "/conversations/"+cid+"/messages", alice, map[string]string{"client_id": "unique-first-message", "text": "Halo Bob 👋"}, 201)
	if duplicate["id"] != mid {
		t.Fatal("retry duplicated message")
	}
	f.request("POST", "/conversations/"+cid+"/messages", alice, map[string]string{"client_id": "unique-first-message", "text": "changed"}, 409)
	f.request("POST", "/conversations/"+cid+"/read", bob, map[string]string{"message_id": mid}, 204)
	event := f.event(wsAlice, "read")
	if event["user_id"] != bobID {
		t.Fatal("wrong receipt user")
	}
	loaded := f.request("GET", "/conversations/"+cid+"/messages", bob, nil, 200)
	items := loaded["messages"].([]any)
	if len(items) != 1 || !items[0].(map[string]any)["is_read"].(bool) {
		t.Fatal("read receipt not persisted")
	}
	f.request("PUT", "/messages/"+mid+"/reaction", bob, map[string]string{"emoji": "❤️"}, 204)
	if f.event(wsAlice, "reaction")["emoji"] != "❤️" {
		t.Fatal("reaction not emitted")
	}
	f.request("PUT", "/messages/"+mid+"/reaction", eve, map[string]string{"emoji": "👍"}, 403)
	f.request("PUT", "/messages/"+mid+"/reaction", bob, map[string]string{"emoji": "invalid"}, 400)
	f.request("POST", "/conversations/"+cid+"/messages", bob, map[string]string{"client_id": "unique-reply-message", "text": "Hai Alice", "reply_to_id": mid}, 201)
	other := f.request("POST", "/conversations", alice, map[string]string{"user_id": f.request("GET", "/me", eve, nil, 200)["id"].(string)}, 200)["id"].(string)
	f.request("POST", "/conversations/"+other+"/messages", alice, map[string]string{"client_id": "invalid-cross-reply", "text": "leak", "reply_to_id": mid}, 400)
	f.request("POST", "/conversations/"+other+"/read", alice, map[string]string{"message_id": mid}, 404)
	// Upload and verify both member access and outsider rejection.
	var buffer bytes.Buffer
	writer := multipart.NewWriter(&buffer)
	part, _ := writer.CreateFormFile("file", "notes.txt")
	part.Write([]byte("catatan Flutter"))
	writer.Close()
	req, _ := http.NewRequest("POST", f.http.URL+"/api/v1/conversations/"+cid+"/attachments", &buffer)
	req.Header.Set("Authorization", "Bearer "+alice)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var attachment map[string]any
	json.NewDecoder(res.Body).Decode(&attachment)
	res.Body.Close()
	if res.StatusCode != 201 {
		t.Fatalf("upload: %d %v", res.StatusCode, attachment)
	}
	aid := attachment["id"].(string)
	f.request("GET", "/attachments/"+aid, eve, nil, 403)
	req, _ = http.NewRequest("GET", f.http.URL+"/api/v1/attachments/"+aid, nil)
	req.Header.Set("Authorization", "Bearer "+bob)
	res, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	content, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || string(content) != "catatan Flutter" {
		t.Fatal("attachment bytes differ")
	}
	f.request("POST", "/conversations/"+other+"/messages", alice, map[string]string{"client_id": "invalid-attachment", "attachment_id": aid}, 400)
	f.request("POST", "/conversations/"+cid+"/messages", bob, map[string]string{"client_id": "invalid-ownership", "attachment_id": aid}, 400)
	f.request("POST", "/conversations/"+cid+"/messages", alice, map[string]string{"client_id": "valid-attachment", "attachment_id": aid}, 201)
	// Exercise more than one history page and prove cursors neither omit nor duplicate IDs.
	for i := 0; i < 52; i++ {
		f.request("POST", "/conversations/"+cid+"/messages", alice, map[string]string{"client_id": fmt.Sprintf("pagination-%d", i), "text": fmt.Sprintf("Pesan %d", i)}, 201)
	}
	page := f.request("GET", "/conversations/"+cid+"/messages", alice, nil, 200)
	first := page["messages"].([]any)
	if len(first) != 50 || page["has_more"] != true {
		t.Fatal("first page boundary")
	}
	before := first[0].(map[string]any)["id"].(string)
	next := f.request("GET", "/conversations/"+cid+"/messages?before="+before, alice, nil, 200)
	second := next["messages"].([]any)
	if len(second) != 5 || next["has_more"] != false {
		t.Fatalf("second page: %d", len(second))
	}
	seen := map[string]bool{}
	for _, m := range append(first, second...) {
		id := m.(map[string]any)["id"].(string)
		if seen[id] {
			t.Fatal("duplicate cursor item")
		}
		seen[id] = true
	}
	f.request("POST", "/auth/logout", bob, nil, 204)
	f.request("GET", "/me", bob, nil, 401)
}
