package agent

// Kill switch, redirects, and the crash-loop guards around hooks.

import (
	"bytes"
	"context"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// TestMain doubles as a helper process that holds the agent lock, standing
// in for a busy `pp-agent update` (see TestToggleStopsBusyRun).
func TestMain(m *testing.M) {
	if p := os.Getenv("PP_TEST_HOLD_LOCK"); p != "" {
		f, _ := os.OpenFile(p, os.O_RDWR|os.O_CREATE, 0o644)
		syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
		f.Truncate(0)
		f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0)
		os.WriteFile(p+".held", nil, 0o644)
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestRedirectsAreErrors(t *testing.T) {
	// Cloudflare Access without "return 401 for service auth": a refused
	// token gets a 302 to a login page that answers 200.
	var mu sync.Mutex
	var seen []string
	gate := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Method+" "+r.URL.Path)
		mu.Unlock()
		if r.URL.Path == "/login" {
			w.Write([]byte("<html>sign in</html>"))
			return
		}
		http.Redirect(w, r, "/login", http.StatusFound)
	}))
	defer gate.Close()
	h := newHarness(t)
	h.cfg.FeedURL = gate.URL + "/feed/"
	h.cfg.StatusURL = gate.URL + "/status"
	err := h.update()
	mustContain(t, err, "302 Found")
	mustContain(t, err, "not followed")
	b, _ := os.ReadFile(filepath.Join(h.cfg.Root, "state", "agent.log"))
	if !strings.Contains(string(b), "report: POST "+gate.URL+"/status: 302 Found") {
		t.Fatalf("status redirect not logged as an error:\n%s", b)
	}
	mu.Lock()
	defer mu.Unlock()
	eq(t, "requests", seen, []string{"GET /feed/latest.json", "POST /status"})
}

func TestDefaultBootIsStock(t *testing.T) {
	h := newHarness(t)
	if h.cfg.ActivateOnBoot || Defaults().ActivateOnBoot {
		t.Fatal("activate_on_boot must default to false (spec: reboot returns stock UI)")
	}
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "live after install", h.live(), "r1")
	h.hooks()
	h.reboot()
	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	eq(t, "no hooks at boot", h.hooks(), []string(nil))
	eq(t, "live after boot", h.live(), "")
	eq(t, "committed kept", h.state().Current, "r1")
	if r := h.state().LastResult; !strings.Contains(r, "activate_on_boot is off") {
		t.Fatalf("result %q", r)
	}
	// A triple-press brings the release back, through the health check.
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	eq(t, "hooks", h.hooks(), []string{"r1 activate tripletap"})
	eq(t, "live", h.live(), "r1")
}

func TestToggleOffAndOn(t *testing.T) {
	h := newHarness(t)
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	eq(t, "nothing installed", h.state().LastResult, "tripletap: no release installed, stock")
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.hooks()
	for i := 0; i < 2; i++ {
		if err := h.toggle(); err != nil {
			t.Fatal(err)
		}
		eq(t, "off", h.hooks(), []string{"r1 deactivate tripletap"})
		eq(t, "live", h.live(), "")
		if err := h.toggle(); err != nil {
			t.Fatal(err)
		}
		eq(t, "on", h.hooks(), []string{"r1 activate tripletap"})
		eq(t, "live", h.live(), "r1")
	}
	eq(t, "pointer untouched", h.current(), "releases/r1")
	s, _ := h.agent().Status()
	eq(t, "status live", s.Live, "r1")
}

func TestToggleOffWhenStartedByHand(t *testing.T) {
	// Mods on without pp-agent (xovi/start over SSH): no live marker, but
	// xochitl runs with LD_PRELOAD. A triple-press still means off.
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if err := h.toggle(); err != nil { // off
		t.Fatal(err)
	}
	h.hooks()
	environ := filepath.Join(h.dir, "proc", "100", "environ")
	write(t, environ, "MALLOC_ARENA_MAX=8\x00LD_PRELOAD=/home/root/xovi/xovi.so\x00")
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	eq(t, "hand-started mods turned off", h.hooks(), []string{"r1 deactivate tripletap"})
	write(t, environ, "MALLOC_ARENA_MAX=8\x00") // stock tatsu xochitl
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	eq(t, "then on again", h.hooks(), []string{"r1 activate tripletap"})
}

func TestToggleOnUnhealthyEndsStock(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if err := h.toggle(); err != nil { // off
		t.Fatal(err)
	}
	h.hooks()
	h.touch("break-r1") // r1 now crash-loops xochitl when turned on
	mustContain(t, h.toggle(), "unhealthy when turned on")
	eq(t, "hooks", h.hooks(), []string{"r1 activate tripletap", "r1 deactivate tripletap-failed"})
	eq(t, "live", h.live(), "")
	st := h.state()
	eq(t, "still committed", st.Current, "r1")
	eq(t, "not marked failed", len(st.Failed), 0)
}

func TestKillSwitchFileComposes(t *testing.T) {
	h := newHarness(t)
	h.cfg.ActivateOnBoot = true
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.hooks()
	h.touch("root/disable")
	// With the file, a triple-press only ever turns mods off.
	for _, want := range [][]string{{"r1 deactivate tripletap"}, nil} {
		if err := h.toggle(); err != nil {
			t.Fatal(err)
		}
		eq(t, "toggle with disable", h.hooks(), want)
		eq(t, "live", h.live(), "")
	}
	// Boot and update leave mods off too (the units also skip on it).
	h.reboot()
	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	h.publish("r2", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "no hooks", h.hooks(), []string(nil))
	mustContain(t, h.agent().Rollback(context.Background()), "kill switch")
	if s, _ := h.agent().Status(); !s.Disabled {
		t.Fatal("status does not say disabled")
	}
	os.Remove(filepath.Join(h.dir, "root/disable"))
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "r2 installs once the file is gone", h.current(), "releases/r2")
}

func TestInterruptedInstallLeftForNextRun(t *testing.T) {
	// SIGTERM mid health check (the OS's emergency reboot shutting us down,
	// or a triple-press stopping us): no hooks run, Pending stays.
	h := newHarness(t)
	h.publish("good", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.hooks()
	h.publish("bad", nil, nil)
	a := h.agent()
	ctx, cancel := context.WithCancel(context.Background())
	a.Probe = func(c context.Context) (XochitlInfo, error) { cancel(); return h.probe(c) }
	mustContain(t, a.Update(ctx), "the next run rolls it back")
	eq(t, "hooks", h.hooks(), []string{"good deactivate install", "bad activate install"})
	eq(t, "pending", h.state().Pending, "bad")
	eq(t, "live", h.live(), "bad")
	// The triple-press that stopped it: roll back, mods off, bad not retried.
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	eq(t, "hooks", h.hooks(), []string{"bad deactivate rollback"})
	st := h.state()
	eq(t, "current", h.current(), "releases/good")
	eq(t, "pending", st.Pending, "")
	eq(t, "failed", st.Failed, []string{"bad"})
	eq(t, "live", h.live(), "")
}

func TestToggleStopsBusyRun(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if err := h.toggle(); err != nil { // mods off; a plain press would now turn them on
		t.Fatal(err)
	}
	h.hooks()
	lock := filepath.Join(h.cfg.Root, "state", "lock")
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), "PP_TEST_HOLD_LOCK="+lock)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	for i := 0; ; i++ {
		if _, err := os.Stat(lock + ".held"); err == nil {
			break
		}
		if i > 200 {
			t.Fatal("helper never took the lock")
		}
		time.Sleep(20 * time.Millisecond)
	}
	start := time.Now()
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 20*time.Second {
		t.Fatal("toggle waited for the busy run instead of stopping it")
	}
	err := cmd.Wait()
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); !ok || !ws.Signaled() || ws.Signal() != syscall.SIGTERM {
		t.Fatalf("busy run not stopped with SIGTERM: %v", err)
	}
	eq(t, "busy means off, never on", h.hooks(), []string(nil))
	eq(t, "result", h.state().LastResult, "tripletap: mods already off")
	eq(t, "live", h.live(), "")
}

func TestResetFailedBeforeEveryHook(t *testing.T) {
	// Our own restarts must not use up xochitl's StartLimitBurst=4.
	h := newHarness(t)
	h.publish("good", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.touch("break-bad")
	h.publish("bad", nil, nil)
	h.update()
	hooks := 1 + 4 // good activate; then old deactivate, bad activate, bad deactivate, good activate
	b, _ := os.ReadFile(filepath.Join(h.dir, "systemctl.log"))
	eq(t, "reset-failed calls", strings.Count(string(b), "reset-failed xochitl.service\n"), hooks)
}

// ---- the power key -----------------------------------------------------------

func inputEvent(at time.Time, typ, code uint16, val int32) []byte {
	b := make([]byte, inputEventSize)
	binary.LittleEndian.PutUint64(b[0:], uint64(at.Unix()))
	binary.LittleEndian.PutUint64(b[8:], uint64(at.Nanosecond()/1000))
	binary.LittleEndian.PutUint16(b[16:], typ)
	binary.LittleEndian.PutUint16(b[18:], code)
	binary.LittleEndian.PutUint32(b[20:], uint32(val))
	return b
}

// presses writes a press, release and SYN for each offset, as the kernel does.
func presses(t0 time.Time, offsets ...time.Duration) []byte {
	var b []byte
	for _, o := range offsets {
		at := t0.Add(o)
		b = append(b, inputEvent(at, evKey, keyPower, 1)...)
		b = append(b, inputEvent(at, 0, 0, 0)...)
		b = append(b, inputEvent(at.Add(120*time.Millisecond), evKey, keyPower, 0)...)
		b = append(b, inputEvent(at.Add(120*time.Millisecond), 0, 0, 0)...)
	}
	return b
}

var t0 = time.Date(2026, 10, 25, 9, 0, 0, 0, time.UTC)

func ms(n int) time.Duration { return time.Duration(n) * time.Millisecond }

func TestReadPresses(t *testing.T) {
	var b []byte
	b = append(b, presses(t0, 0)...)
	b = append(b, inputEvent(t0.Add(ms(500)), evKey, keyPower, 2)...) // autorepeat
	b = append(b, inputEvent(t0.Add(ms(600)), evKey, 102, 1)...)      // KEY_HOME
	b = append(b, inputEvent(t0.Add(ms(700)), 5, 0, 1)...)            // EV_SW (folio)
	b = append(b, presses(t0, ms(1250))...)
	b = append(b, 1, 2, 3) // a torn last event
	var got []time.Time
	err := readPresses(bytes.NewReader(b), func(at time.Time) { got = append(got, at) })
	if err == nil {
		t.Fatal("want EOF")
	}
	eq(t, "presses", got, []time.Time{t0, t0.Add(ms(1250))})
}

func TestTapCounting(t *testing.T) {
	run := func(offsets ...int) (fired []int) {
		tp := tapper{c: tapCounter{need: 3, gap: ms(3000)}, now: func() time.Time { return t0 }}
		for _, o := range offsets {
			tp.press(t0.Add(ms(o)), func() { fired = append(fired, o) })
		}
		return fired
	}
	eq(t, "three quick", run(0, 900, 1800), []int{1800})
	eq(t, "two", run(0, 900), []int(nil))
	eq(t, "a gap too long restarts the count", run(0, 900, 4000, 5000, 6000), []int{6000})
	eq(t, "six quick = two toggles", run(0, 100, 200, 300, 400, 500), []int{200, 500})
	eq(t, "single presses (sleep, wake) never fire", run(0, 60000, 120000, 180000), []int(nil))

	// Presses made while a toggle ran are ignored, even three of them.
	clock := t0.Add(ms(1800))
	tp := tapper{c: tapCounter{need: 3, gap: ms(3000)}, now: func() time.Time { return clock }}
	var fired []int
	for _, o := range []int{0, 900, 1800, 5000, 5100, 5200, 30000, 30500, 31000} {
		tp.press(t0.Add(ms(o)), func() { fired = append(fired, o); clock = t0.Add(ms(20000)) })
	}
	eq(t, "presses during the toggle ignored", fired, []int{1800, 31000})
}

func TestFindPowerKey(t *testing.T) {
	d := t.TempDir()
	dev := func(n, name, keys string) {
		write(t, filepath.Join(d, "event"+n, "device", "name"), name+"\n")
		write(t, filepath.Join(d, "event"+n, "device", "capabilities", "key"), keys+"\n")
	}
	// The tatsu layout (DT): Elan marker + touch, hall sensors, BBNSM power key.
	dev("0", "Elan marker input", "c03 0 0 0 0 0")
	dev("1", "Elan touchscreen", "400 0 0 0 0 0")
	dev("2", "gpio-hall-sensors", "0")
	dev("10", "44440000.bbnsm:pwrkey", "10000000000000 0")
	got, err := FindPowerKey(d)
	if err != nil || got != "/dev/input/event10" {
		t.Fatalf("by name: %q %v", got, err)
	}
	os.RemoveAll(filepath.Join(d, "event10"))
	dev("3", "unnamed", "10000000000000 0") // KEY_POWER = bit 116 = word 1, bit 52
	got, err = FindPowerKey(d)
	if err != nil || got != "/dev/input/event3" {
		t.Fatalf("by capability: %q %v", got, err)
	}
	os.RemoveAll(filepath.Join(d, "event3"))
	if _, err := FindPowerKey(d); err == nil {
		t.Fatal("found a power key that is not there")
	}
}

func TestTripleTapEndToEnd(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.hooks()
	// Recorded presses: a triple (off), two stray presses, a triple (on).
	evs := filepath.Join(h.dir, "power-key")
	b := presses(h.clock.Add(time.Minute), 0, ms(700), ms(1400))
	b = append(b, presses(h.clock.Add(2*time.Minute), 0, ms(500))...)
	b = append(b, presses(h.clock.Add(3*time.Minute), 0, ms(800), ms(1600))...)
	write(t, evs, string(b))
	h.cfg.PowerKeyDevice = evs
	if err := h.agent().TripleTap(context.Background()); err != nil { // returns at EOF
		t.Fatal(err)
	}
	eq(t, "hooks", h.hooks(), []string{"r1 deactivate tripletap", "r1 activate tripletap"})
	eq(t, "live", h.live(), "r1")
}
