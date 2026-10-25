package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func setup(t *testing.T, token string) (*server, *httptest.Server, *string) {
	t.Helper()
	lastUp := new(string)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*lastUp = r.Method + " " + r.URL.RequestURI()
		if r.URL.Path == "/health" {
			fmt.Fprint(w, "Working, 0 clients")
			return
		}
		w.Header().Set("X-Upstream", "rmfakecloud")
		fmt.Fprint(w, "from upstream")
	}))
	t.Cleanup(up.Close)
	s, err := newServer(t.TempDir(), up.URL, token, 3)
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	s.now = func() time.Time { clock = clock.Add(time.Second); return clock }
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return s, ts, lastUp
}

func do(t *testing.T, method, url, body string, hdr ...string) (int, string, http.Header) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), resp.Header
}

func TestProxyToRmfakecloud(t *testing.T) {
	_, ts, last := setup(t, "")
	code, body, h := do(t, "PUT", ts.URL+"/sync/v3/root?x=1", "{}")
	if code != 200 || body != "from upstream" || h.Get("X-Upstream") != "rmfakecloud" {
		t.Fatalf("got %d %q", code, body)
	}
	if *last != "PUT /sync/v3/root?x=1" {
		t.Fatalf("upstream saw %q", *last)
	}
	// /pp is ours and never reaches rmfakecloud, even for unknown paths.
	*last = ""
	if code, _, _ := do(t, "GET", ts.URL+"/pp/nope", ""); code != 404 || *last != "" {
		t.Fatalf("got %d, upstream saw %q", code, *last)
	}
}

func TestHealthz(t *testing.T) {
	s, ts, _ := setup(t, "")
	code, body, _ := do(t, "GET", ts.URL+"/pp/healthz", "")
	if code != 200 || !strings.Contains(body, `"ok":true`) || !strings.Contains(body, "Working") {
		t.Fatalf("got %d %s", code, body)
	}
	os.WriteFile(filepath.Join(s.data, "backup", "last.json"), []byte(`{"ok":true,"snapshot":"abc"}`), 0o644)
	if _, body, _ = do(t, "GET", ts.URL+"/pp/healthz", ""); !strings.Contains(body, `"snapshot":"abc"`) {
		t.Fatalf("no backup in %s", body)
	}
	s.healthURL = "http://127.0.0.1:1/health"
	if code, _, _ = do(t, "GET", ts.URL+"/pp/healthz", ""); code != 503 {
		t.Fatalf("rmfakecloud down: got %d, want 503", code)
	}
}

func TestPublishAndRange(t *testing.T) {
	_, ts, _ := setup(t, "s3cret")
	u := ts.URL + "/pp/releases/tatsu/r1.tar.gz"
	if code, _, _ := do(t, "PUT", u, "0123456789"); code != 403 {
		t.Fatalf("no token: got %d", code)
	}
	if code, _, _ := do(t, "PUT", u, "0123456789", "Authorization", "Bearer wrong"); code != 403 {
		t.Fatalf("wrong token: got %d", code)
	}
	if code, _, _ := do(t, "PUT", u, "0123456789", "Authorization", "Bearer s3cret"); code != 204 {
		t.Fatalf("publish: got %d", code)
	}
	code, body, h := do(t, "GET", u, "", "Range", "bytes=4-")
	if code != 206 || body != "456789" || h.Get("Cache-Control") != "no-store" {
		t.Fatalf("range: %d %q %v", code, body, h)
	}
	if code, body, _ = do(t, "GET", u, ""); code != 200 || body != "0123456789" {
		t.Fatalf("get: %d %q", code, body)
	}
	if code, _, _ = do(t, "DELETE", u, ""); code != 405 {
		t.Fatalf("delete: got %d", code)
	}
	for _, bad := range []string{"/pp/releases/tatsu/.put-1", "/pp/releases/tatsu/..", "/pp/releases/../x", "/pp/releases/tatsu/a/b", "/pp/releases/tatsu/"} {
		if code, _, _ := do(t, "PUT", ts.URL+bad, "x", "Authorization", "Bearer s3cret"); code != 404 {
			t.Fatalf("PUT %s: got %d, want 404", bad, code)
		}
	}
	if code, _, _ := do(t, "GET", ts.URL+"/pp/releases/tatsu/missing.json", ""); code != 404 {
		t.Fatalf("missing: got %d", code)
	}
}

func TestPublishOffWithoutToken(t *testing.T) {
	_, ts, _ := setup(t, "")
	// An empty token must never match an empty Authorization header.
	for _, h := range [][]string{nil, {"Authorization", "Bearer "}, {"Authorization", ""}} {
		if code, _, _ := do(t, "PUT", ts.URL+"/pp/releases/tatsu/x", "x", h...); code != 403 {
			t.Fatalf("%v: got %d", h, code)
		}
	}
}

func TestStatus(t *testing.T) {
	s, ts, _ := setup(t, "")
	for i := 1; i <= 5; i++ {
		b := fmt.Sprintf(`{"device":"tatsu","release":"r%d","log_tail":"x"}`, i)
		if code, _, _ := do(t, "POST", ts.URL+"/pp/status", b, "Content-Type", "application/json"); code != 204 {
			t.Fatalf("post %d: got %d", i, code)
		}
	}
	files, _ := filepath.Glob(filepath.Join(s.data, "status", "tatsu", "*"))
	if len(files) != 3 { // keep = 3
		t.Fatalf("kept %d files: %v", len(files), files)
	}
	code, body, h := do(t, "GET", ts.URL+"/pp/status/tatsu", "")
	if code != 200 || !strings.Contains(body, `"release":"r5"`) || h.Get("Content-Type") != "application/json" {
		t.Fatalf("latest: %d %s", code, body)
	}
	_, body, _ = do(t, "GET", ts.URL+"/pp/status/tatsu?n=10", "")
	var got []struct{ Release string }
	if err := json.Unmarshal([]byte(body), &got); err != nil || len(got) != 3 || got[0].Release != "r5" || got[2].Release != "r3" {
		t.Fatalf("history: %v %s", err, body)
	}
	for _, bad := range []string{`not json`, `{"device":"../etc"}`, `{"release":"x"}`, `[]`} {
		if code, _, _ := do(t, "POST", ts.URL+"/pp/status", bad); code != 400 {
			t.Fatalf("POST %q: got %d, want 400", bad, code)
		}
	}
	if code, _, _ := do(t, "POST", ts.URL+"/pp/status", `{"device":"tatsu","x":"`+strings.Repeat("a", maxStatus)+`"}`); code != 413 {
		t.Fatalf("huge: got %d", code)
	}
	if code, _, _ := do(t, "GET", ts.URL+"/pp/status/ferrari", ""); code != 404 {
		t.Fatalf("unknown device: got %d", code)
	}
	if code, _, _ := do(t, "GET", ts.URL+"/pp/status/tatsu?n=0", ""); code != 400 {
		t.Fatalf("n=0: got %d", code)
	}
}
