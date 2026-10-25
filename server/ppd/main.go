// ppd is the server's front door, behind cloudflared. It is glue, not a
// platform: one file, stdlib only.
//
//	GET  /pp/healthz                   200 if rmfakecloud answers, plus last backup
//	GET  /pp/backup                    last backup result (written by backup.sh)
//	GET  /pp/releases/<device>/<file>  the release feed, static, Range works
//	PUT  /pp/releases/<device>/<file>  publish one file (needs PP_PUBLISH_TOKEN)
//	POST /pp/status                    the tablet agent's status report
//	GET  /pp/status/<device>[?n=N]     latest report, or the last N (newest first)
//	GET  /pp/wishes/<path>             the wish inbox (needs PP_READ_TOKEN)
//	GET  /pp/logs/<file>               the container's log, server.log[.1] (needs PP_READ_TOKEN)
//	everything else                    reverse proxy to rmfakecloud
//
//	ppd logtee -file F                 the entrypoint pipes every daemon's output through this
//
// Cloudflare Access decides who reaches ppd at all. ppd adds two rules of
// its own. Publishing needs the publish token (CI's), so the tablet's
// credential can't change the feed; the feed is untrusted anyway, since the
// agent installs only releases signed with Cedar's key. Wish pages and logs
// need the read token (Claude's): wish pages are Cedar's notes, and Access
// lets the tablet's and CI's tokens in too.
package main

import (
	"bufio"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var (
	deviceRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	fileRe   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
)

const (
	maxStatus  = 1 << 20 // the agent sends ~10 KiB
	maxRelease = 1 << 30
)

type server struct {
	data         string // holds releases/, status/, backup/, and wishes/ (written by wishes.py)
	logs         string // holds server.log and server.log.1 (written by ppd logtee)
	upstream     http.Handler
	healthURL    string
	publishToken string
	readToken    string
	keep         int
	now          func() time.Time
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "logtee" {
		fs := flag.NewFlagSet("logtee", flag.ExitOnError)
		file := fs.String("file", "/data/log/server.log", "log file; the old one is file.1")
		max := fs.Int64("max", 4<<20, "start a new file at this many bytes")
		fs.Parse(os.Args[2:])
		signal.Ignore(syscall.SIGPIPE) // a gone stdout must not stop the file copy
		logtee(os.Stdin, os.Stdout, *file, *max, time.Now)
		return
	}
	addr := flag.String("addr", ":3080", "listen address")
	data := flag.String("data", "/data/pp", "ppd data dir")
	logs := flag.String("logs", "/data/log", "log dir (ppd logtee writes it)")
	up := flag.String("upstream", "http://127.0.0.1:3000", "rmfakecloud")
	keep := flag.Int("keep", 500, "status reports kept per device")
	flag.Parse()
	log.SetFlags(0)
	log.SetPrefix("ppd: ")

	s, err := newServer(*data, *up, os.Getenv("PP_PUBLISH_TOKEN"), *keep)
	if err != nil {
		log.Fatal(err)
	}
	s.logs, s.readToken = *logs, os.Getenv("PP_READ_TOKEN")
	if s.publishToken == "" {
		log.Print("PP_PUBLISH_TOKEN not set: publishing is off")
	}
	if s.readToken == "" {
		log.Print("PP_READ_TOKEN not set: /pp/wishes and /pp/logs are off")
	}
	srv := &http.Server{Addr: *addr, Handler: s, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("listening on %s, upstream %s, data %s", *addr, *up, *data)
	log.Fatal(srv.ListenAndServe())
}

func newServer(data, upstream, token string, keep int) (*server, error) {
	u, err := url.Parse(upstream)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("bad upstream %q", upstream)
	}
	for _, d := range []string{"releases", "status", "backup"} {
		if err := os.MkdirAll(filepath.Join(data, d), 0o755); err != nil {
			return nil, err
		}
	}
	rp := httputil.NewSingleHostReverseProxy(u)
	rp.ErrorLog = log.Default()
	return &server{
		data: data, upstream: rp, healthURL: u.JoinPath("health").String(),
		publishToken: token, keep: keep, now: time.Now,
	}, nil
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	if p != "/pp" && !strings.HasPrefix(p, "/pp/") {
		s.upstream.ServeHTTP(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	parts := strings.Split(strings.TrimPrefix(p, "/pp/"), "/")
	switch {
	case p == "/pp/healthz" && isRead(r):
		s.healthz(w, r)
	case p == "/pp/backup" && isRead(r):
		s.serveFile(w, r, filepath.Join(s.data, "backup", "last.json"))
	case len(parts) == 3 && parts[0] == "releases" && deviceRe.MatchString(parts[1]) && fileRe.MatchString(parts[2]):
		f := filepath.Join(s.data, "releases", parts[1], parts[2])
		switch {
		case isRead(r):
			s.serveFile(w, r, f)
		case r.Method == http.MethodPut:
			s.publish(w, r, f)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	case p == "/pp/status" && r.Method == http.MethodPost:
		s.postStatus(w, r)
	case len(parts) == 2 && parts[0] == "status" && deviceRe.MatchString(parts[1]) && isRead(r):
		s.getStatus(w, r, parts[1])
	case parts[0] == "wishes" || parts[0] == "logs":
		s.read(w, r, parts)
	default:
		http.NotFound(w, r)
	}
}

func isRead(r *http.Request) bool { return r.Method == http.MethodGet || r.Method == http.MethodHead }

// bearer reports whether r carries "Authorization: Bearer <token>". An
// empty token never matches, so an unset token turns its feature off.
func bearer(r *http.Request, token string) bool {
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && token != "" && subtle.ConstantTimeCompare([]byte(got), []byte(token)) == 1
}

// read serves the wish inbox and the logs, read-only, to the read token:
//
//	/pp/wishes/index.json, /pp/wishes/<folder>/<file>   (see tools/wishes)
//	/pp/logs/server.log, /pp/logs/server.log.1          (Range works: curl -r -100000)
func (s *server) read(w http.ResponseWriter, r *http.Request, parts []string) {
	if !isRead(r) {
		http.Error(w, "read only", http.StatusMethodNotAllowed)
		return
	}
	if !bearer(r, s.readToken) {
		msg := "bad read token"
		if s.readToken == "" {
			msg = "reading is off (PP_READ_TOKEN not set)"
		}
		log.Printf("read refused: %s %s: %s", r.Method, r.URL.Path, msg)
		http.Error(w, msg, http.StatusForbidden)
		return
	}
	var path string
	switch {
	case parts[0] == "wishes" && (len(parts) == 2 || len(parts) == 3) && allMatch(fileRe, parts[1:]):
		path = filepath.Join(append([]string{s.data}, parts...)...)
	case parts[0] == "logs" && len(parts) == 2 && fileRe.MatchString(parts[1]):
		path = filepath.Join(s.logs, parts[1])
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	default:
		http.NotFound(w, r)
		return
	}
	// Never let a browser run anything from here (page.svg, a log line).
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "sandbox")
	s.serveFile(w, r, path)
}

func allMatch(re *regexp.Regexp, ss []string) bool {
	for _, x := range ss {
		if !re.MatchString(x) {
			return false
		}
	}
	return true
}

// serveFile serves one regular file. http.ServeContent does Range and HEAD.
func (s *server) serveFile(w http.ResponseWriter, r *http.Request, path string) {
	f, err := os.Open(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	if strings.HasSuffix(path, ".json") {
		w.Header().Set("Content-Type", "application/json")
	}
	http.ServeContent(w, r, fi.Name(), fi.ModTime(), f)
}

func (s *server) healthz(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"ok": false}
	c := http.Client{Timeout: 5 * time.Second}
	if resp, err := c.Get(s.healthURL); err != nil {
		out["rmfakecloud"] = err.Error()
	} else {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		out["rmfakecloud"] = strings.TrimSpace(string(b))
		out["ok"] = resp.StatusCode == http.StatusOK
	}
	if b, err := os.ReadFile(filepath.Join(s.data, "backup", "last.json")); err == nil {
		out["backup"] = json.RawMessage(b)
	}
	code := http.StatusOK
	if out["ok"] != true {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, out)
}

// publish writes one feed file atomically. Order is the publisher's job:
// tarball first, latest.json last (scripts/publish.sh does that).
func (s *server) publish(w http.ResponseWriter, r *http.Request, path string) {
	if s.publishToken == "" {
		http.Error(w, "publishing is off", http.StatusForbidden)
		return
	}
	if !bearer(r, s.publishToken) {
		http.Error(w, "bad publish token", http.StatusForbidden)
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		httpErr(w, err)
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".put-*")
	if err != nil {
		httpErr(w, err)
		return
	}
	defer os.Remove(tmp.Name())
	n, err := io.Copy(tmp, http.MaxBytesReader(w, r.Body, maxRelease))
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(tmp.Name(), 0o644)
	}
	if err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		httpErr(w, err)
		return
	}
	log.Printf("published %s (%d bytes)", strings.TrimPrefix(path, s.data+"/"), n)
	w.WriteHeader(http.StatusNoContent)
}

// postStatus keeps the agent's report as status/<device>/<server time>.json
// plus the newest `keep` of them. The body is stored as sent.
func (s *server) postStatus(w http.ResponseWriter, r *http.Request) {
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxStatus))
	if err != nil {
		http.Error(w, "too big", http.StatusRequestEntityTooLarge)
		return
	}
	var st struct {
		Device     string `json:"device"`
		OSVersion  string `json:"os_version"`
		Release    string `json:"release"`
		LastResult string `json:"last_result"`
		LastError  string `json:"last_error"`
	}
	if err := json.Unmarshal(b, &st); err != nil || !deviceRe.MatchString(st.Device) {
		http.Error(w, "want a JSON object with a device name", http.StatusBadRequest)
		return
	}
	dir := filepath.Join(s.data, "status", st.Device)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		httpErr(w, err)
		return
	}
	name := s.now().UTC().Format("20060102T150405.000000000Z") + ".json"
	if err := writeAtomic(filepath.Join(dir, name), b); err != nil {
		httpErr(w, err)
		return
	}
	s.prune(dir)
	log.Printf("status %s: os=%s release=%q result=%q error=%q", st.Device, st.OSVersion, st.Release, st.LastResult, st.LastError)
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) reports(dir string) []string {
	names, _ := filepath.Glob(filepath.Join(dir, "2*.json"))
	sort.Strings(names) // the names are UTC timestamps, so this is oldest first
	return names
}

func (s *server) prune(dir string) {
	names := s.reports(dir)
	for len(names) > s.keep {
		os.Remove(names[0])
		names = names[1:]
	}
}

func (s *server) getStatus(w http.ResponseWriter, r *http.Request, device string) {
	names := s.reports(filepath.Join(s.data, "status", device))
	if len(names) == 0 {
		http.NotFound(w, r)
		return
	}
	nq := r.URL.Query().Get("n")
	if nq == "" {
		s.serveFile(w, r, names[len(names)-1])
		return
	}
	n, err := strconv.Atoi(nq)
	if err != nil || n < 1 {
		http.Error(w, "n must be a positive number", http.StatusBadRequest)
		return
	}
	out := []json.RawMessage{}
	for i := len(names) - 1; i >= 0 && len(out) < n; i-- {
		if b, err := os.ReadFile(names[i]); err == nil && json.Valid(b) {
			out = append(out, b)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func writeAtomic(path string, b []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, err error) {
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		http.Error(w, "too big", http.StatusRequestEntityTooLarge)
		return
	}
	log.Print(err)
	http.Error(w, "internal error", http.StatusInternalServerError)
}

// logtee keeps the container's log. The entrypoint sends everything every
// daemon prints through it. Each line goes to out unchanged (the host's log
// view) and, with the UTC time in front, to path, which ppd serves at
// /pp/logs/. At max bytes path moves to path.1, replacing the old one, so
// the disk holds at most 2*max. A failing file never stops the copy to out:
// the log must not take the server down. It returns when in closes.
func logtee(in io.Reader, out io.Writer, path string, max int64, now func() time.Time) {
	var f *os.File
	var size int64
	warned := false
	fail := func(err error) {
		if f != nil {
			f.Close()
			f = nil
		}
		if !warned {
			fmt.Fprintf(out, "ppd logtee: %v; this goes to stdout only until the file works again\n", err)
			warned = true
		}
	}
	br := bufio.NewReader(in)
	for {
		line, rerr := br.ReadString('\n')
		if line != "" {
			io.WriteString(out, line)
			if f == nil {
				var err error
				if f, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644); err != nil {
					f = nil
					fail(err)
				} else if fi, err := f.Stat(); err != nil {
					fail(err)
				} else {
					size, warned = fi.Size(), false
				}
			}
			if f != nil {
				if !strings.HasSuffix(line, "\n") {
					line += "\n"
				}
				n, err := fmt.Fprintf(f, "%s %s", now().UTC().Format(time.RFC3339), line)
				size += int64(n)
				if err != nil {
					fail(err)
				} else if size >= max {
					f.Close()
					f = nil
					if err := os.Rename(path, path+".1"); err != nil {
						fail(err)
					}
				}
			}
		}
		if rerr != nil {
			break
		}
	}
	if f != nil {
		f.Close()
	}
}
