package agent

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"paper-pure/agent/internal/release"
)

// The os-release of the real 3.27.2.2 tatsu image (facts, not their file).
const tatsuOSRelease = `ID=codex
NAME="Codex Linux"
VERSION="5.7.124 (scarthgap)"
VERSION_ID=5.7.124
VERSION_CODENAME="scarthgap"
PRETTY_NAME="Codex Linux 5.7.124 (scarthgap)"
CPE_NAME="cpe:/o:openembedded:codex:5.7.124"
BUILD_MODE_RM="public"
IMG_VERSION="3.27.2.2"
`

const routeHeader = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"
const routeWifi = routeHeader + "wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n" +
	"wlan0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0\n"

// Hooks used by every test release. They log what ran, and they drive the
// fake xochitl: activating release X "crashes" xochitl if break-X exists.
const activateSh = `#!/bin/sh
echo "$PP_RELEASE_ID activate $PP_REASON" >> "$PP_TEST_DIR/hooks.log"
if [ -f "$PP_TEST_DIR/break-$PP_RELEASE_ID" ]; then echo crash > "$PP_TEST_DIR/xochitl"; else echo ok > "$PP_TEST_DIR/xochitl"; fi
`
const deactivateSh = `#!/bin/sh
echo "$PP_RELEASE_ID deactivate $PP_REASON" >> "$PP_TEST_DIR/hooks.log"
echo ok > "$PP_TEST_DIR/xochitl"
`

type harness struct {
	t    *testing.T
	dir  string
	feed string
	srv  *httptest.Server
	priv ed25519.PrivateKey
	cfg  Config

	clock         time.Time
	created       time.Time
	pid, restarts int

	mu       sync.Mutex
	requests []string
	cutAfter map[string]int // path -> bytes to send before dropping the connection (once)
	statuses []Status
}

func write(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func newHarness(t *testing.T) *harness {
	dir := t.TempDir()
	h := &harness{
		t: t, dir: dir, feed: filepath.Join(dir, "feed"),
		clock:    time.Date(2026, 10, 25, 9, 0, 0, 0, time.UTC),
		created:  time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC),
		pid:      100,
		cutAfter: map[string]int{},
	}
	os.MkdirAll(h.feed, 0o755)
	write(t, filepath.Join(dir, "os-release"), tatsuOSRelease)
	write(t, filepath.Join(dir, "sys/class/net/wlan0/operstate"), "up\n")
	write(t, filepath.Join(dir, "proc/net/route"), routeWifi)
	write(t, filepath.Join(dir, "battery/capacity"), "80\n")
	write(t, filepath.Join(dir, "charger/online"), "0\n")
	write(t, filepath.Join(dir, "xochitl"), "ok\n")
	privPEM, pubPEM, err := release.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	h.priv, _ = release.ParsePrivateKey(privPEM)
	write(t, filepath.Join(dir, "release.pub.pem"), string(pubPEM))
	h.srv = httptest.NewServer(h)
	t.Cleanup(h.srv.Close)
	t.Setenv("PP_TEST_DIR", dir)

	c := Defaults()
	c.Root = filepath.Join(dir, "root")
	c.FeedURL = h.srv.URL + "/feed/"
	c.StatusURL = h.srv.URL + "/status"
	c.PubKey = filepath.Join(dir, "release.pub.pem")
	c.OSRelease = filepath.Join(dir, "os-release")
	c.SysClassNet = filepath.Join(dir, "sys/class/net")
	c.ProcNetRoute = filepath.Join(dir, "proc/net/route")
	c.BatteryCapacity = filepath.Join(dir, "battery/capacity")
	c.ChargerOnline = filepath.Join(dir, "charger/online")
	c.ProcDir = filepath.Join(dir, "proc")
	c.StableSeconds, c.PollMillis = 3, 500
	c.HookTimeout, c.CheckTimeout = 5, 5
	h.cfg = c
	return h
}

func (h *harness) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	h.requests = append(h.requests, strings.TrimSpace(r.Method+" "+r.URL.Path+" "+r.Header.Get("Range")))
	cut, isCut := h.cutAfter[r.URL.Path]
	delete(h.cutAfter, r.URL.Path)
	h.mu.Unlock()
	if r.URL.Path == "/status" {
		var s Status
		json.NewDecoder(r.Body).Decode(&s)
		h.mu.Lock()
		h.statuses = append(h.statuses, s)
		h.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
		return
	}
	p := filepath.Join(h.feed, strings.TrimPrefix(r.URL.Path, "/feed/"))
	if isCut {
		b, _ := os.ReadFile(p)
		w.Header().Set("Content-Length", itoa(len(b)))
		w.WriteHeader(http.StatusOK)
		w.Write(b[:cut])
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler) // drop the connection mid-body
	}
	http.ServeFile(w, r, p)
}

func itoa(n int) string { return strconv.Itoa(n) }

func (h *harness) reqs() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.requests
	h.requests = nil
	return r
}

// publish packs a release tree, signs it and makes it latest.
func (h *harness) publish(id string, extra map[string]string, mutate func(*release.Manifest)) *release.Manifest {
	t := h.t
	tree := t.TempDir()
	files := map[string]string{"hooks/activate.sh": activateSh, "hooks/deactivate.sh": deactivateSh}
	for k, v := range extra {
		files[k] = v
	}
	for name, body := range files {
		p := filepath.Join(tree, name)
		write(t, p, body)
		if strings.HasSuffix(name, ".sh") {
			os.Chmod(p, 0o755)
		}
	}
	h.created = h.created.Add(time.Hour)
	var buf bytes.Buffer
	if err := release.Pack(tree, &buf, h.created); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(buf.Bytes())
	m := &release.Manifest{Format: release.Format, ID: id, Device: "tatsu", Created: h.created,
		OSVersions: []string{"3.27.2.2"}, Size: int64(buf.Len()), SHA256: hex.EncodeToString(sum[:])}
	if mutate != nil {
		mutate(m)
	}
	mb, err := m.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(h.feed, m.Tarball()), buf.String())
	write(t, filepath.Join(h.feed, "latest.json"), string(mb))
	write(t, filepath.Join(h.feed, "latest.json.sig"), string(release.Sign(h.priv, mb)))
	return m
}

func (h *harness) probe(ctx context.Context) (XochitlInfo, error) {
	b, _ := os.ReadFile(filepath.Join(h.dir, "xochitl"))
	switch strings.TrimSpace(string(b)) {
	case "crash": // systemd restarted it (Restart=on-failure)
		h.pid++
		h.restarts++
	case "respawn": // something restarted it by hand
		h.pid++
	case "dead":
		return XochitlInfo{Active: "failed"}, nil
	}
	return XochitlInfo{Active: "active", PID: h.pid, Restarts: h.restarts}, nil
}

// agent builds a fresh Agent, as each systemd run would.
func (h *harness) agent() *Agent {
	a, err := New(h.cfg)
	if err != nil {
		h.t.Fatal(err)
	}
	a.Probe = h.probe
	a.Now = func() time.Time { return h.clock }
	a.Sleep = func(ctx context.Context, d time.Duration) error { h.clock = h.clock.Add(d); return ctx.Err() }
	return a
}

func (h *harness) update() error { return h.agent().Update(context.Background()) }
func (h *harness) boot() error   { return h.agent().Boot(context.Background()) }

func (h *harness) state() *State {
	s, err := loadState(filepath.Join(h.cfg.Root, "state", "state.json"))
	if err != nil {
		h.t.Fatal(err)
	}
	return s
}

func (h *harness) current() string {
	t, err := os.Readlink(filepath.Join(h.cfg.Root, "current"))
	if err != nil {
		return ""
	}
	return t
}

// hooks returns and clears the hook log.
func (h *harness) hooks() []string {
	p := filepath.Join(h.dir, "hooks.log")
	b, _ := os.ReadFile(p)
	os.Remove(p)
	s := strings.TrimSpace(string(b))
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func (h *harness) touch(name string) { write(h.t, filepath.Join(h.dir, name), "") }

func eq(t *testing.T, what string, got, want any) {
	t.Helper()
	gb, _ := json.Marshal(got)
	wb, _ := json.Marshal(want)
	if string(gb) != string(wb) {
		t.Fatalf("%s:\n got  %s\n want %s", what, gb, wb)
	}
}

func mustContain(t *testing.T, err error, sub string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), sub) {
		t.Fatalf("error %v, want it to contain %q", err, sub)
	}
}

// ---- tests ------------------------------------------------------------------

func TestInstallHappyPath(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "current", h.current(), "releases/r1")
	eq(t, "hooks", h.hooks(), []string{"r1 activate install"})
	st := h.state()
	eq(t, "committed", st.Current, "r1")
	eq(t, "pending", st.Pending, "")
	if _, err := os.Stat(filepath.Join(h.cfg.Root, "releases", "r1", "hooks", "activate.sh")); err != nil {
		t.Fatal("release not unpacked")
	}
	// Status went to the server.
	h.mu.Lock()
	last := h.statuses[len(h.statuses)-1]
	h.mu.Unlock()
	eq(t, "reported release", last.Release, "r1")
	eq(t, "reported os", last.OSVersion, "3.27.2.2")
	eq(t, "reported result", last.LastResult, "installed r1")

	// Second run: nothing to do, no download.
	h.reqs()
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	for _, r := range h.reqs() {
		if strings.Contains(r, ".tar.gz") {
			t.Fatalf("re-downloaded: %s", r)
		}
	}
	eq(t, "result", h.state().LastResult, "up to date (r1)")
}

func TestRejectsBadSignature(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	// Signed by someone else.
	otherPEM, _, _ := release.GenerateKey()
	other, _ := release.ParsePrivateKey(otherPEM)
	mb, _ := os.ReadFile(filepath.Join(h.feed, "latest.json"))
	write(t, filepath.Join(h.feed, "latest.json.sig"), string(release.Sign(other, mb)))
	mustContain(t, h.update(), "bad signature")

	// Signed by us, then edited (e.g. a server swapping the sha256).
	h.publish("r2", nil, nil)
	mb, _ = os.ReadFile(filepath.Join(h.feed, "latest.json"))
	write(t, filepath.Join(h.feed, "latest.json"), strings.Replace(string(mb), `"r2"`, `"r3"`, 1))
	mustContain(t, h.update(), "bad signature")

	eq(t, "current", h.current(), "")
	eq(t, "hooks", h.hooks(), []string(nil))
	for _, r := range h.reqs() {
		if strings.Contains(r, ".tar.gz") {
			t.Fatalf("downloaded a tarball for an unverified manifest: %s", r)
		}
	}
	if ents, _ := os.ReadDir(filepath.Join(h.cfg.Root, "releases")); len(ents) != 0 {
		t.Fatalf("something landed in releases/: %v", ents)
	}
}

func TestRejectsOSAndDeviceMismatch(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, func(m *release.Manifest) { m.OSVersions = []string{"3.27.1.0"} })
	mustContain(t, h.update(), `this tablet runs "3.27.2.2"`)
	eq(t, "current", h.current(), "")

	h.publish("r2", nil, func(m *release.Manifest) { m.Device = "ferrari" })
	mustContain(t, h.update(), `built for device "ferrari"`)
	eq(t, "current", h.current(), "")

	// A release tested on both the old and the frozen OS is fine.
	h.publish("r3", nil, func(m *release.Manifest) { m.OSVersions = []string{"3.27.1.0", "3.27.2.2"} })
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "current", h.current(), "releases/r3")

	// An unreadable os-release refuses everything.
	os.Remove(filepath.Join(h.dir, "os-release"))
	h.publish("r4", nil, nil)
	mustContain(t, h.update(), `this tablet runs ""`)
	eq(t, "current", h.current(), "releases/r3")
}

func TestOSVersionParse(t *testing.T) {
	p := filepath.Join(t.TempDir(), "os-release")
	write(t, p, tatsuOSRelease)
	v, err := OSVersion(p)
	if err != nil || v != "3.27.2.2" {
		t.Fatalf("got %q %v", v, err)
	}
}

func TestInterruptedDownloadResumes(t *testing.T) {
	h := newHarness(t)
	m := h.publish("r1", map[string]string{"blob.bin": strings.Repeat("paper-pure ", 20000)}, nil)
	half := int(m.Size / 2)
	h.cutAfter["/feed/r1.tar.gz"] = half

	err := h.update()
	mustContain(t, err, "kept for resume")
	eq(t, "current after cut", h.current(), "")
	part := filepath.Join(h.cfg.Root, "downloads", "r1.tar.gz.part")
	fi, serr := os.Stat(part)
	if serr != nil || fi.Size() != int64(half) {
		t.Fatalf("partial file: %v size %v, want %d", serr, fi, half)
	}
	h.reqs()
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(h.reqs(), "GET /feed/r1.tar.gz bytes="+itoa(half)+"-") {
		t.Fatal("second run did not resume with a Range request")
	}
	eq(t, "current", h.current(), "releases/r1")
	if _, err := os.Stat(part); !os.IsNotExist(err) {
		t.Fatal("part file left behind")
	}
}

func TestCorruptDownloadRejected(t *testing.T) {
	h := newHarness(t)
	m := h.publish("r1", nil, nil)
	// The server serves a different tarball of the same size.
	tb := filepath.Join(h.feed, m.Tarball())
	b, _ := os.ReadFile(tb)
	b[len(b)/2] ^= 0xff
	os.WriteFile(tb, b, 0o644)
	mustContain(t, h.update(), "sha256 mismatch")
	eq(t, "current", h.current(), "")
	if _, err := os.Stat(filepath.Join(h.cfg.Root, "downloads", "r1.tar.gz.part")); !os.IsNotExist(err) {
		t.Fatal("bad download kept")
	}
	eq(t, "hooks", h.hooks(), []string(nil))
}

func TestHealthFailureRollsBack(t *testing.T) {
	h := newHarness(t)
	h.publish("good", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.hooks()

	// "bad" crash-loops xochitl once activated.
	h.touch("break-bad")
	h.publish("bad", nil, nil)
	err := h.update()
	mustContain(t, err, "xochitl not stable")
	mustContain(t, err, "rolled back to good")
	eq(t, "current", h.current(), "releases/good")
	eq(t, "hooks", h.hooks(), []string{
		"good deactivate install",
		"bad activate install",
		"bad deactivate rollback",
		"good activate rollback",
	})
	st := h.state()
	eq(t, "committed", st.Current, "good")
	eq(t, "failed", st.Failed, []string{"bad"})

	// The same bad release is never tried again.
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "hooks", h.hooks(), []string(nil))
	eq(t, "result", h.state().LastResult, "latest bad failed before; staying on good")
}

func TestFailingCheckScriptRollsBackToStock(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", map[string]string{
		"checks/10-ok.sh":   "#!/bin/sh\necho fine\n",
		"checks/20-fail.sh": "#!/bin/sh\necho 'appload did not launch' >&2\nexit 3\n",
	}, nil)
	err := h.update()
	mustContain(t, err, "checks/20-fail.sh")
	mustContain(t, err, "appload did not launch")
	mustContain(t, err, "rolled back to stock")
	eq(t, "current", h.current(), "") // first install failed: back to stock
	eq(t, "hooks", h.hooks(), []string{"r1 activate install", "r1 deactivate rollback"})
}

func TestHookTimeoutRollsBack(t *testing.T) {
	h := newHarness(t)
	h.cfg.HookTimeout = 1
	h.publish("slow", map[string]string{"hooks/activate.sh": "#!/bin/sh\nsleep 30\n"}, nil)
	start := time.Now()
	mustContain(t, h.update(), "timed out")
	if time.Since(start) > 15*time.Second {
		t.Fatal("timeout did not kill the hook")
	}
	eq(t, "current", h.current(), "")
}

func TestExpectMapped(t *testing.T) {
	h := newHarness(t)
	write(t, filepath.Join(h.dir, "proc", "100", "maps"),
		"ffff8000-ffff9000 r-xp 00000000 b3:02 1234 /home/root/xovi/xovi.so\n")
	h.publish("r1", nil, func(m *release.Manifest) { m.ExpectMapped = []string{"xovi.so"} })
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.publish("r2", nil, func(m *release.Manifest) { m.ExpectMapped = []string{"xovi.so", "appload.so"} })
	mustContain(t, h.update(), `has not loaded "appload.so"`)
	eq(t, "current", h.current(), "releases/r1")
}

func TestOlderReleaseRefused(t *testing.T) {
	h := newHarness(t)
	h.publish("new", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.publish("replayed", nil, func(m *release.Manifest) { m.Created = m.Created.Add(-48 * time.Hour) })
	mustContain(t, h.update(), "not newer than current")
	eq(t, "current", h.current(), "releases/new")
}

func TestGates(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)

	write(t, filepath.Join(h.dir, "sys/class/net/wlan0/operstate"), "down\n")
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "wifi down", h.state().LastResult, "skipped: wlan0 is down")

	write(t, filepath.Join(h.dir, "sys/class/net/wlan0/operstate"), "up\n")
	write(t, filepath.Join(h.dir, "proc/net/route"), routeHeader+"usb0\t00000000\t01630B0A\t0003\t0\t0\t0\t00000000\t0\t0\t0\n")
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "no route", h.state().LastResult, "skipped: wlan0 up but no default route")

	write(t, filepath.Join(h.dir, "proc/net/route"), routeWifi)
	write(t, filepath.Join(h.dir, "battery/capacity"), "12\n")
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "low battery", h.state().LastResult, "skipped: battery 12% < floor 30%")
	for _, r := range h.reqs() {
		if strings.HasPrefix(r, "GET") {
			t.Fatalf("fetched while gated: %s", r)
		}
	}

	write(t, filepath.Join(h.dir, "charger/online"), "1\n")
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "charging", h.state().LastResult, "installed r1")
}

func TestBootGuard(t *testing.T) {
	h := newHarness(t)
	h.cfg.BootGuardMax = 3
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	h.hooks()
	eq(t, "healthy boot", h.state().UnhealthyBoots, 0)

	// Something on the tablet now makes r1 crash at boot.
	h.touch("break-r1")
	for i := 1; i <= 3; i++ {
		mustContain(t, h.boot(), "unhealthy at boot")
		eq(t, "unhealthy boots", h.state().UnhealthyBoots, i)
		eq(t, "hooks", h.hooks(), []string{"r1 activate boot", "r1 deactivate boot-failed"})
	}
	// Fourth boot: three in a row never got healthy, stay stock.
	mustContain(t, h.boot(), "never got healthy")
	eq(t, "no hooks once tripped", h.hooks(), []string(nil))
	if !h.state().GuardTripped {
		t.Fatal("guard not tripped")
	}
	os.Remove(filepath.Join(h.dir, "break-r1"))
	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	eq(t, "still stock", h.hooks(), []string(nil))

	// A new good release clears it.
	h.publish("r2", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	st := h.state()
	eq(t, "guard", st.GuardTripped, false)
	eq(t, "count", st.UnhealthyBoots, 0)
	h.hooks()
	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	eq(t, "boot activates r2", h.hooks(), []string{"r2 activate boot"})
}

func TestBootCountIsOnDiskBeforeActivate(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	// The activate hook copies state.json as it sees it mid-boot, like a
	// power cut would leave it.
	act := filepath.Join(h.cfg.Root, "releases", "r1", "hooks", "activate.sh")
	write(t, act, `#!/bin/sh
cp "$PP_ROOT/state/state.json" "$PP_TEST_DIR/snapshot.json"
`)
	os.Chmod(act, 0o755)
	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(h.dir, "snapshot.json"))
	var s State
	json.Unmarshal(b, &s)
	eq(t, "count during activate", s.UnhealthyBoots, 1)
	eq(t, "count after healthy", h.state().UnhealthyBoots, 0)
}

func TestBootRefusesWhenOSChanged(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.hooks()
	// e.g. the bootloader fell back to the other root partition.
	write(t, filepath.Join(h.dir, "os-release"), strings.Replace(tatsuOSRelease, "3.27.2.2", "3.29.0.153", 1))
	mustContain(t, h.boot(), "OS is \"3.29.0.153\"")
	eq(t, "hooks", h.hooks(), []string(nil))
}

func TestRebootDuringHealthCheckRollsBackAtBoot(t *testing.T) {
	h := newHarness(t)
	h.publish("good", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	// "bad"'s check reboots the tablet: here, the check script records it
	// was reached and then the run is cancelled, as SIGKILL/power loss would.
	// We fake the power cut by doing what install does up to the check and
	// then dropping the agent on the floor.
	h.publish("bad", nil, nil)
	a := h.agent()
	if err := a.begin(true); err != nil {
		t.Fatal(err)
	}
	mb, _ := os.ReadFile(filepath.Join(h.feed, "latest.json"))
	sb, _ := os.ReadFile(filepath.Join(h.feed, "latest.json.sig"))
	m, _ := release.ParseManifest(mb)
	part := filepath.Join(h.cfg.Root, "downloads", "bad.tar.gz.part")
	if err := a.download(context.Background(), h.cfg.FeedURL+m.Tarball(), part, m.Size, m.SHA256); err != nil {
		t.Fatal(err)
	}
	if err := a.unpack(m, part, mb, sb); err != nil {
		t.Fatal(err)
	}
	a.st.Pending = "bad"
	a.save()
	a.runHook(context.Background(), "good", HookDeactivate, "install")
	a.flip("bad")
	a.runHook(context.Background(), "bad", HookActivate, "install")
	a.unlock() // power cut
	h.hooks()

	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	eq(t, "current", h.current(), "releases/good")
	eq(t, "hooks", h.hooks(), []string{"bad deactivate rollback", "good activate boot"})
	st := h.state()
	eq(t, "failed", st.Failed, []string{"bad"})
	eq(t, "pending", st.Pending, "")
}

func TestManualRollbackAndPrune(t *testing.T) {
	h := newHarness(t)
	for _, id := range []string{"r1", "r2", "r3"} {
		h.publish(id, nil, nil)
		if err := h.update(); err != nil {
			t.Fatal(err)
		}
	}
	ents, _ := os.ReadDir(filepath.Join(h.cfg.Root, "releases"))
	var names []string
	for _, e := range ents {
		names = append(names, e.Name())
	}
	eq(t, "kept releases", names, []string{"r2", "r2.json", "r2.json.sig", "r3", "r3.json", "r3.json.sig"})
	h.hooks()

	if err := h.agent().Rollback(context.Background()); err != nil {
		t.Fatal(err)
	}
	eq(t, "current", h.current(), "releases/r2")
	eq(t, "hooks", h.hooks(), []string{"r3 deactivate manual-rollback", "r2 activate manual-rollback"})
	st := h.state()
	eq(t, "committed", st.Current, "r2")
	eq(t, "previous", st.Previous, "r3")
	eq(t, "failed", st.Failed, []string{"r3"})
	// r3 is still latest on the server, and is not reinstalled.
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "current", h.current(), "releases/r2")
}

func TestPointerRepair(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(h.cfg.Root, "current"))
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "current", h.current(), "releases/r1")
}

func TestStatusShape(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	s, err := h.agent().Status()
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "release", s.Release, "r1")
	eq(t, "battery", s.BatteryPercent, 80)
	if !strings.Contains(s.LogTail, "result: installed r1") {
		t.Fatalf("log tail missing result: %q", s.LogTail)
	}
}

func TestXochitlCheckModes(t *testing.T) {
	for mode, want := range map[string]string{"ok": "", "crash": "not stable", "respawn": "not stable", "dead": "not active"} {
		h := newHarness(t)
		write(t, filepath.Join(h.dir, "xochitl"), mode)
		err := h.agent().checkXochitl(context.Background(), &release.Manifest{})
		if want == "" && err != nil {
			t.Fatalf("%s: %v", mode, err)
		}
		if want != "" {
			mustContain(t, err, want)
		}
	}
	// stable_seconds 0 and nothing expected: check is off.
	h := newHarness(t)
	h.cfg.StableSeconds = 0
	write(t, filepath.Join(h.dir, "xochitl"), "dead")
	if err := h.agent().checkXochitl(context.Background(), &release.Manifest{}); err != nil {
		t.Fatal(err)
	}
}
