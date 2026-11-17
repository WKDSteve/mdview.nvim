package main

// handleKeys tests: an auth + size-cap + broadcast wrapper around Registry. What
// is pinned here is the part that is this handler's: who may post, how much,
// that the batch reaches every tab tagged with keysMessagePrefix, and that it is
// not kept for a tab that joins later (keys are a passing event).

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/WKDSteve/mdview.nvim/native/server/internal/relay"
)

func keysRequest(method, token, body string) *http.Request {
	target := "/keys"
	if token != "" {
		target += "?token=" + token
	}
	return httptest.NewRequest(method, target, strings.NewReader(body))
}

func TestHandleKeys_BroadcastsTaggedBatchToEveryRoom(t *testing.T) {
	registry := relay.NewRegistry()
	a, b := &recordingConn{}, &recordingConn{}
	registry.Join("/doc/a.md", a)
	registry.Join("/doc/b.md", b)

	w := httptest.NewRecorder()
	handleKeys(registry, testToken).ServeHTTP(w, keysRequest(http.MethodPost, testToken, `{"text":":w<CR>"}`))

	if w.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", w.Code, w.Body.String())
	}
	want := keysMessagePrefix + `{"text":":w<CR>"}`
	for name, c := range map[string]*recordingConn{"a": a, "b": b} {
		if len(c.received) != 1 || c.received[0] != want {
			t.Fatalf("room %s: expected %q, got %q", name, want, c.received)
		}
	}
}

func TestHandleKeys_IsNotKeptForATabThatJoinsLater(t *testing.T) {
	registry := relay.NewRegistry()
	registry.Join("/doc/a.md", &recordingConn{})
	w := httptest.NewRecorder()
	handleKeys(registry, testToken).ServeHTTP(w, keysRequest(http.MethodPost, testToken, `{"text":"secret?"}`))
	if w.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", w.Code)
	}

	late := &recordingConn{}
	if err := registry.JoinAndSeed("/doc/a.md", late); err != nil {
		t.Fatalf("JoinAndSeed: %v", err)
	}
	for _, got := range late.received {
		if strings.HasPrefix(got, keysMessagePrefix) {
			t.Fatalf("a late tab must not be seeded with keys, got %q", got)
		}
	}
	if p, ok := registry.LastPayload("/doc/a.md"); ok {
		t.Fatalf("keys must not become the room's content, got %q", p)
	}
}

func TestHandleKeys_RejectsWrongAndMissingToken(t *testing.T) {
	registry := relay.NewRegistry()
	c := &recordingConn{}
	registry.Join("/doc/a.md", c)
	for _, token := range []string{"wrong", ""} {
		w := httptest.NewRecorder()
		handleKeys(registry, testToken).ServeHTTP(w, keysRequest(http.MethodPost, token, "{}"))
		if w.Code != http.StatusForbidden {
			t.Fatalf("token %q: expected 403, got %d", token, w.Code)
		}
	}
	if len(c.received) != 0 {
		t.Fatalf("a rejected request must not reach a tab, got %q", c.received)
	}
}

func TestHandleKeys_RejectsNonPost(t *testing.T) {
	w := httptest.NewRecorder()
	handleKeys(relay.NewRegistry(), testToken).ServeHTTP(w, keysRequest(http.MethodGet, testToken, ""))
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", w.Code)
	}
}

func TestHandleKeys_RejectsAnOversizedBodyAndAcceptsOneAtTheCap(t *testing.T) {
	registry := relay.NewRegistry()
	c := &recordingConn{}
	registry.Join("/doc/a.md", c)

	w := httptest.NewRecorder()
	handleKeys(registry, testToken).ServeHTTP(w, keysRequest(http.MethodPost, testToken, strings.Repeat("x", maxKeysBodyBytes+1)))
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", w.Code)
	}
	if len(c.received) != 0 {
		t.Fatalf("an oversized batch must not reach a tab")
	}

	w = httptest.NewRecorder()
	handleKeys(registry, testToken).ServeHTTP(w, keysRequest(http.MethodPost, testToken, strings.Repeat("x", maxKeysBodyBytes)))
	if w.Code != http.StatusNoContent {
		t.Fatalf("expected 204 at the cap, got %d", w.Code)
	}
}
