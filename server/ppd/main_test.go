package main

import (
	"bytes"
	"encoding/json"
	"errors"
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
	if code, _, _ := do(t, "PUT", u, "0123456789", "Authorization", "s3cret"); code != 403 {
		t.Fatalf("token without Bearer: got %d", code)
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

// wishInbox writes a small inbox the way wishes.py does.
func wishInbox(t *testing.T, s *server) {
	t.Helper()
	dir := filepath.Join(s.data, "wishes", "2026-10-25-wishes-p1-32a1a76a")
	for _, d := range []string{dir, filepath.Join(s.data, "wishes", ".tmp-abc")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		"wishes/index.json":                               `{"x/y":{"dir":"2026-10-25-wishes-p1-32a1a76a","revision":1}}`,
		"wishes/2026-10-25-wishes-p1-32a1a76a/page.png":   "\x89PNG fake",
		"wishes/2026-10-25-wishes-p1-32a1a76a/page.svg":   `<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`,
		"wishes/2026-10-25-wishes-p1-32a1a76a/issue.md":   "# Wish: (title)",
		"wishes/.tmp-abc/page.png":                        "half-written",
		"wishes/2026-10-25-wishes-p1-32a1a76a/deep/x.png": "too deep",
		"status/tatsu/20261025T100000.000000000Z.json":    `{"device":"tatsu"}`,
	}
	for name, body := range files {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(s.data, name)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(s.data, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestReadWishesAndLogs(t *testing.T) {
	s, ts, last := setup(t, "pub")
	s.readToken, s.logs = "r3ad", t.TempDir()
	wishInbox(t, s)
	os.WriteFile(filepath.Join(s.logs, ".hidden"), []byte("not a log"), 0o644)
	os.WriteFile(filepath.Join(s.logs, "server.log"), []byte("2026-10-25T10:00:00Z <html><script>x</script>\n2026-10-25T10:00:01Z ppd: last line\n"), 0o644)
	ok := []string{"Authorization", "Bearer r3ad"}
	page := ts.URL + "/pp/wishes/2026-10-25-wishes-p1-32a1a76a/page.png"

	// Refused without the read token: no header, wrong, empty, no "Bearer ",
	// and the publish token (CI's) or a tablet-style rmfakecloud token.
	*last = ""
	for _, u := range []string{page, ts.URL + "/pp/wishes/index.json", ts.URL + "/pp/logs/server.log", ts.URL + "/pp/wishes/nope/x"} {
		for _, h := range [][]string{nil, {"Authorization", "Bearer wrong"}, {"Authorization", "Bearer "}, {"Authorization", "r3ad"}, {"Authorization", "Bearer pub"}} {
			if code, body, _ := do(t, "GET", u, "", h...); code != 403 || strings.Contains(body, "PNG") {
				t.Fatalf("GET %s %v: got %d %q, want 403", u, h, code, body)
			}
		}
	}
	if *last != "" {
		t.Fatalf("a read reached rmfakecloud: %q", *last)
	}

	// With it: the inbox, as written, read-only.
	code, body, h := do(t, "GET", ts.URL+"/pp/wishes/index.json", "", ok...)
	if code != 200 || !strings.Contains(body, `"revision":1`) || h.Get("Content-Type") != "application/json" || h.Get("Cache-Control") != "no-store" {
		t.Fatalf("index.json: %d %q %v", code, body, h)
	}
	if code, body, _ = do(t, "GET", page, "", ok...); code != 200 || body != "\x89PNG fake" {
		t.Fatalf("page.png: %d %q", code, body)
	}
	code, _, h = do(t, "GET", ts.URL+"/pp/wishes/2026-10-25-wishes-p1-32a1a76a/page.svg", "", ok...)
	if code != 200 || h.Get("Content-Security-Policy") != "sandbox" || h.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("page.svg: %d %v", code, h)
	}
	if code, _, _ = do(t, "HEAD", page, "", ok...); code != 200 {
		t.Fatalf("HEAD: %d", code)
	}
	for _, m := range []string{"PUT", "POST", "DELETE"} {
		if code, _, _ := do(t, m, page, "evil", ok...); code != 405 {
			t.Fatalf("%s: got %d, want 405", m, code)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(s.data, "wishes", "2026-10-25-wishes-p1-32a1a76a", "page.png")); string(b) != "\x89PNG fake" {
		t.Fatalf("page changed: %q", b)
	}
	// Only the inbox: no dot folders (scans in progress), no climbing out, no depth.
	for _, bad := range []string{"/pp/wishes/.tmp-abc/page.png", "/pp/wishes/../status/tatsu/20261025T100000.000000000Z.json",
		"/pp/wishes/2026-10-25-wishes-p1-32a1a76a/..", "/pp/wishes/2026-10-25-wishes-p1-32a1a76a", "/pp/wishes/", "/pp/wishes",
		"/pp/wishes/a/b/c", "/pp/wishes/2026-10-25-wishes-p1-32a1a76a/deep/x.png", "/pp/logs/.hidden", "/pp/logs/..", "/pp/wishes/2026-10-25-wishes-p1-32a1a76a/missing.rm", "/pp/logs/", "/pp/logs/../pp/x", "/pp/logs/a/b"} {
		if code, _, _ := do(t, "GET", ts.URL+bad, "", ok...); code != 404 {
			t.Fatalf("GET %s: got %d, want 404", bad, code)
		}
	}

	// The log: plain text whatever is in it, and Range gives the tail.
	code, body, h = do(t, "GET", ts.URL+"/pp/logs/server.log", "", ok...)
	if code != 200 || !strings.Contains(body, "ppd: last line") || h.Get("Content-Type") != "text/plain; charset=utf-8" || h.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("server.log: %d %q %v", code, body, h)
	}
	if code, body, _ = do(t, "GET", ts.URL+"/pp/logs/server.log", "", "Authorization", "Bearer r3ad", "Range", "bytes=-15"); code != 206 || body != "ppd: last line\n" {
		t.Fatalf("tail: %d %q", code, body)
	}
	if code, _, _ = do(t, "GET", ts.URL+"/pp/logs/server.log.1", "", ok...); code != 404 {
		t.Fatalf("no old log yet: got %d", code)
	}

	// No token configured: everything here is off, even for "Bearer ".
	s.readToken = ""
	for _, h := range [][]string{nil, {"Authorization", "Bearer "}, {"Authorization", "Bearer r3ad"}} {
		if code, body, _ := do(t, "GET", ts.URL+"/pp/wishes/index.json", "", h...); code != 403 || !strings.Contains(body, "off") {
			t.Fatalf("token unset %v: got %d %q", h, code, body)
		}
	}
}

func TestLogtee(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.log")
	clock := time.Date(2026, 10, 25, 10, 0, 0, 0, time.FixedZone("CET", 3600))
	now := func() time.Time { return clock }
	in := "rmfakecloud: one\nppd: two\nno newline at the end"
	var out bytes.Buffer
	logtee(strings.NewReader(in), &out, path, 1<<20, now)
	if out.String() != in {
		t.Fatalf("stdout changed: %q", out.String())
	}
	b, _ := os.ReadFile(path)
	want := "2026-10-25T09:00:00Z rmfakecloud: one\n2026-10-25T09:00:00Z ppd: two\n2026-10-25T09:00:00Z no newline at the end\n"
	if string(b) != want {
		t.Fatalf("file:\n%s\nwant:\n%s", b, want)
	}

	// Rotation: past max the file moves to .1 (the older .1 goes) and a new one starts.
	os.WriteFile(path+".1", []byte("oldest\n"), 0o644)
	var lines strings.Builder
	for i := 0; i < 100; i++ {
		fmt.Fprintf(&lines, "line %03d %s\n", i, strings.Repeat("x", 50))
	}
	out.Reset()
	logtee(strings.NewReader(lines.String()), &out, path, 2000, now)
	if out.String() != lines.String() {
		t.Fatal("stdout lost lines while rotating")
	}
	cur, _ := os.ReadFile(path)
	old, _ := os.ReadFile(path + ".1")
	if len(cur) >= 2000 || len(old) < 2000 || strings.Contains(string(old), "oldest") {
		t.Fatalf("rotation: cur %d bytes, old %d bytes", len(cur), len(old))
	}
	// What is kept is the newest lines, in order, none missing, ending at 099.
	kept := strings.Split(strings.TrimSuffix(string(old)+string(cur), "\n"), "\n")
	first := 100 - len(kept)
	for i, l := range kept {
		if want := fmt.Sprintf("2026-10-25T09:00:00Z line %03d ", first+i); !strings.HasPrefix(l, want) {
			t.Fatalf("kept line %d = %q, want prefix %q", i, l, want)
		}
	}
	// A file that can't be written: stdout still gets everything, plus one warning.
	out.Reset()
	logtee(strings.NewReader("a\nb\n"), &out, filepath.Join(dir, "missing", "server.log"), 1<<20, now)
	if !strings.HasPrefix(out.String(), "a\nppd logtee: ") || !strings.HasSuffix(out.String(), "stdout only until the file works again\nb\n") {
		t.Fatalf("stdout: %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "missing")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("logtee made a dir: %v", err)
	}
}

func TestBearer(t *testing.T) {
	for _, c := range []struct {
		header, token string
		want          bool
	}{
		{"Bearer s3cret", "s3cret", true},
		{"Bearer s3cret", "other", false},
		{"s3cret", "s3cret", false},         // the scheme is required
		{"bearer s3cret", "s3cret", false},  // exactly as publish.sh and Claude send it
		{"Bearer s3cret ", "s3cret", false}, // no trimming here
		{"Bearer s3cretX", "s3cret", false},
		{"Bearer ", "", false}, // an unset token never matches. (Over HTTP the
		{"", "", false},        // trailing space is trimmed, so only this test reaches it.)
	} {
		r := httptest.NewRequest("GET", "/pp/wishes/index.json", nil)
		r.Header.Set("Authorization", c.header)
		if got := bearer(r, c.token); got != c.want {
			t.Errorf("bearer(%q, token %q) = %v, want %v", c.header, c.token, got, c.want)
		}
	}
}

// Feed files are served as data: this origin is also rmfakecloud's web UI,
// so an HTML or SVG file here must never run in Cedar's browser.
func TestFeedIsNeverActiveContent(t *testing.T) {
	_, ts, _ := setup(t, "s3cret")
	auth := []string{"Authorization", "Bearer s3cret"}
	for _, bad := range []string{"x.svg", "notes.html", "noext"} {
		if code, _, _ := do(t, "PUT", ts.URL+"/pp/releases/tatsu/"+bad, "<html><script>1</script>", auth...); code != 400 {
			t.Fatalf("PUT %s: got %d, want 400", bad, code)
		}
	}
	for name, want := range map[string]string{"r1.tar.gz": "application/octet-stream", "r1.json.sig": "application/octet-stream", "latest.json": "application/json"} {
		if code, _, _ := do(t, "PUT", ts.URL+"/pp/releases/tatsu/"+name, "<html><script>alert(1)</script></html>", auth...); code != 204 {
			t.Fatalf("PUT %s: %d", name, code)
		}
		_, _, h := do(t, "GET", ts.URL+"/pp/releases/tatsu/"+name, "")
		if h.Get("Content-Type") != want || h.Get("X-Content-Type-Options") != "nosniff" || h.Get("Content-Security-Policy") != "sandbox" {
			t.Fatalf("%s: %v", name, h)
		}
	}
}

func TestProblems(t *testing.T) {
	s, ts, _ := setup(t, "")
	get := func() (int, []string) {
		t.Helper()
		code, body, _ := do(t, "GET", ts.URL+"/pp/problems", "")
		var out struct {
			Problems []string `json:"problems"`
		}
		if err := json.Unmarshal([]byte(body), &out); err != nil {
			t.Fatalf("%v: %s", err, body)
		}
		return code, out.Problems
	}
	if code, p := get(); code != 200 || len(p) != 0 {
		t.Fatalf("fresh server, backups off: %d %v", code, p)
	}
	s.backupMaxAge, s.reportMaxAge = 26*time.Hour, 72*time.Hour
	want := func(sub string) {
		t.Helper()
		code, p := get()
		if code != 503 || !strings.Contains(strings.Join(p, "\n"), sub) {
			t.Fatalf("want 503 with %q, got %d %v", sub, code, p)
		}
	}
	want("backup: none has run yet")
	last := filepath.Join(s.data, "backup", "last.json")
	os.WriteFile(last, []byte(`{"ok":false,"finished":"2026-10-25T03:20:00Z","error":"restic backup failed"}`), 0o644)
	want("backup: the last one failed (2026-10-25T03:20:00Z): restic backup failed")
	os.WriteFile(last, []byte(`{"ok":true,"finished":"2026-10-23T03:20:00Z"}`), 0o644)
	want("more than 26h0m0s ago")
	os.WriteFile(last, []byte(`{"ok":true,"finished":"2026-10-25T03:20:00Z"}`), 0o644)
	if code, p := get(); code != 200 {
		t.Fatalf("good backup: %d %v", code, p)
	}
	// Tablets: the newest report decides. The clock is 2026-10-25 10:00.
	dir := filepath.Join(s.data, "status", "tatsu")
	os.MkdirAll(dir, 0o755)
	report := func(name, body string) { os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644) }
	report("20261021T100000.000000000Z.json", `{"device":"tatsu"}`)
	want("tablet tatsu: last report 2026-10-21T10:00:00Z")
	report("20261025T095000.000000000Z.json", `{"device":"tatsu","sync":{"last_ok":"2026-10-25T08:00:00Z","errors":3,"last_error":{"time":"2026-10-25T09:40:00Z","code":403,"path":"eu.tectonic.remarkable.com/sync/v4/root"}}}`)
	want("tablet tatsu: sync failing since a 403 on eu.tectonic.remarkable.com/sync/v4/root")
	report("20261025T095500.000000000Z.json", `{"device":"tatsu","sync":{"last_ok":"2026-10-25T09:50:00Z","errors":3,"last_error":{"time":"2026-10-25T09:40:00Z","code":403,"path":"x"}},"checks":{"release":"r7","ok":false,"error":"appload hooks missing"}}`)
	want("tablet tatsu: checks of r7 failed")
	report("20261025T095800.000000000Z.json", `{"device":"tatsu","sync":{"last_ok":"2026-10-25T09:50:00Z"},"checks":{"release":"r7","ok":true}}`)
	if code, p := get(); code != 200 {
		t.Fatalf("all good again: %d %v", code, p)
	}
}
