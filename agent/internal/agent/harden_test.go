package agent

// Fixes from the review: OS pin on every path that turns mods on,
// anti-replay that survives rollbacks, a sticky triple-press off, mods
// started by hand, rechecks, and sync health in the status report.

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"paper-pure/agent/internal/release"
)

func osIs(t *testing.T, h *harness, v string) {
	write(t, filepath.Join(h.dir, "os-release"), strings.Replace(tatsuOSRelease, "3.27.2.2", v, 1))
}

// A run interrupted mid-check, a reboot onto the other slot (another OS),
// and pp-agent-boot never ran: the timer's update rolls back and turns
// nothing on, whatever the gates say.
func TestUpdateRollsBackLeftoversWithoutTurningOn(t *testing.T) {
	h := newHarness(t)
	h.publish("good", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.publish("bad", nil, nil)
	a := h.agent()
	ctx, cancel := context.WithCancel(context.Background())
	a.Probe = func(c context.Context) (XochitlInfo, error) { cancel(); return h.probe(c) }
	mustContain(t, a.Update(ctx), "the next run rolls it back")
	h.hooks()
	h.reboot()
	osIs(t, h, "3.29.0.153")
	write(t, filepath.Join(h.dir, "sys/class/net/wlan0/operstate"), "down\n")
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "hooks", h.hooks(), []string{"bad deactivate rollback"})
	eq(t, "live", h.live(), "")
	eq(t, "current", h.current(), "releases/good")
	eq(t, "failed", h.state().Failed, []string{"bad"})
}

// Same, on the same OS: still nothing turns on. After a reboot mods are
// off until a triple-press (activate_on_boot is off), so the update run's
// cleanup must not bring them back either.
func TestUpdateCleanupKeepsRebootStock(t *testing.T) {
	h := newHarness(t)
	h.publish("good", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.publish("bad", nil, nil)
	a := h.agent()
	ctx, cancel := context.WithCancel(context.Background())
	a.Probe = func(c context.Context) (XochitlInfo, error) { cancel(); return h.probe(c) }
	mustContain(t, a.Update(ctx), "the next run rolls it back")
	h.hooks()
	h.reboot()
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "hooks", h.hooks(), []string{"bad deactivate rollback"})
	eq(t, "live", h.live(), "")
}

// A manual rollback over SSH turns mods on, so it clears a triple-press off.
func TestManualRollbackClearsModsOff(t *testing.T) {
	h := newHarness(t)
	for _, id := range []string{"r1", "r2"} {
		h.publish(id, nil, nil)
		if err := h.update(); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	eq(t, "off", h.state().ModsOff, true)
	if err := h.agent().Rollback(context.Background()); err != nil {
		t.Fatal(err)
	}
	eq(t, "on again", []any{h.state().ModsOff, h.live()}, []any{false, "r1"})
}

// A release tested on both OSes installs on the new one, fails, and the
// rollback must not turn on the old release, which only knows the old OS.
func TestRollbackDoesNotTurnOnReleaseForOtherOS(t *testing.T) {
	h := newHarness(t)
	h.publish("good", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	h.hooks()
	osIs(t, h, "3.29.0.153")
	h.touch("break-both")
	h.publish("both", nil, func(m *release.Manifest) { m.OSVersions = []string{"3.27.2.2", "3.29.0.153"} })
	mustContain(t, h.update(), "rolled back to good")
	eq(t, "hooks", h.hooks(), []string{"good deactivate install", "both activate install", "both deactivate rollback"})
	eq(t, "live", h.live(), "")
	ev := h.state().Events
	mustContain(t, errorsNew(ev[len(ev)-1].Msg), "good not turned on: OS is \"3.29.0.153\"")
}

func TestManualRollbackRefusedOnOtherOS(t *testing.T) {
	h := newHarness(t)
	for _, id := range []string{"r1", "r2"} {
		h.publish(id, nil, nil)
		if err := h.update(); err != nil {
			t.Fatal(err)
		}
	}
	h.hooks()
	osIs(t, h, "3.29.0.153")
	mustContain(t, h.agent().Rollback(context.Background()), `OS is "3.29.0.153" but r1 was tested on [3.27.2.2]`)
	eq(t, "no hooks", h.hooks(), []string(nil))
	eq(t, "current", h.current(), "releases/r2")
}

// After a manual rollback to r1, a release older than r2 (the newest ever
// committed) is still a replay.
func TestReplayRefusedAfterRollback(t *testing.T) {
	h := newHarness(t)
	r1 := h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if h.state().NewestCreated.IsZero() {
		t.Fatal("newest_created not kept")
	}
	h.publish("r2", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if err := h.agent().Rollback(context.Background()); err != nil {
		t.Fatal(err)
	}
	eq(t, "rolled back", h.current(), "releases/r1")
	h.publish("between", nil, func(m *release.Manifest) { m.Created = r1.Created.Add(30 * time.Minute) })
	mustContain(t, h.update(), "not newer than current")
	eq(t, "current", h.current(), "releases/r1")
	h.publish("r3", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "a newer release installs", h.current(), "releases/r3")
}

func TestReplayRefusedWhenManifestUnreadable(t *testing.T) {
	h := newHarness(t)
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(h.cfg.Root, "releases", "r1.json"))
	old := func(m *release.Manifest) { m.Created = m.Created.Add(-48 * time.Hour) }
	h.publish("old", nil, old)
	mustContain(t, h.update(), "not newer than current")
	// State from before newest_created existed: refuse rather than guess.
	st := h.state()
	st.NewestCreated = time.Time{}
	st.save(filepath.Join(h.cfg.Root, "state", "state.json"))
	h.publish("old2", nil, old)
	mustContain(t, h.update(), "cannot read the running release's manifest")
	eq(t, "current", h.current(), "releases/r1")
}

// Triple-press off sticks: no install and no boot turns mods back on
// until a triple-press does.
func TestTripleTapOffSticks(t *testing.T) {
	h := newHarness(t)
	h.cfg.ActivateOnBoot = true
	h.publish("r1", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	if err := h.toggle(); err != nil { // off
		t.Fatal(err)
	}
	h.hooks()
	h.publish("r2", nil, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "no install while off", h.current(), "releases/r1")
	mustContain(t, errorsNew(h.state().LastResult), "turned off by triple-press")
	h.reboot()
	if err := h.boot(); err != nil {
		t.Fatal(err)
	}
	eq(t, "boot stays stock", h.hooks(), []string(nil))
	if s, _ := h.agent().Status(); !s.ModsOff {
		t.Fatal("status does not say mods_off")
	}
	if err := h.toggle(); err != nil { // on
		t.Fatal(err)
	}
	eq(t, "on", h.hooks(), []string{"r1 activate tripletap"})
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "then r2 installs", h.current(), "releases/r2")
	eq(t, "mods_off cleared", h.state().ModsOff, false)
}

// Mods started by hand (mods/install.sh at bring-up), no release yet: a
// triple-press runs xovi's own stock script.
func TestHandStartedModsOffWithoutRelease(t *testing.T) {
	h := newHarness(t)
	h.cfg.HandStock = filepath.Join(h.dir, "xovi-stock")
	write(t, h.cfg.HandStock, "#!/bin/sh\necho \"xovi stock\" >> \"$PP_TEST_DIR/hooks.log\"\n")
	os.Chmod(h.cfg.HandStock, 0o755)
	write(t, filepath.Join(h.dir, "proc", "100", "environ"), "LD_PRELOAD=/home/root/xovi/xovi.so\x00")
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	eq(t, "hooks", h.hooks(), []string{"xovi stock"})
	eq(t, "result", h.state().LastResult, "tripletap: mods off (started by hand)")
}

// While mods are live, every update run re-runs the release's checks and
// reports the outcome; a failure changes nothing on the tablet.
func TestRecheckWhileLive(t *testing.T) {
	h := newHarness(t)
	check := "#!/bin/sh\n[ ! -e \"$PP_TEST_DIR/check-fails\" ] || { echo 'appload hooks missing' >&2; exit 1; }\n"
	h.publish("r1", map[string]string{"checks/10-smoke.sh": check}, nil)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "install checks", h.state().Checks.Reason, "install")
	h.hooks()
	h.clock = h.clock.Add(time.Hour)
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	c := h.state().Checks
	eq(t, "recheck", []any{c.Reason, c.OK, c.Time.Equal(h.clock)}, []any{"recheck", true, true})
	h.touch("check-fails")
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	s, _ := h.agent().Status()
	if s.Checks == nil || s.Checks.OK || !strings.Contains(s.Checks.Error, "appload hooks missing") {
		t.Fatalf("status checks: %+v", s.Checks)
	}
	eq(t, "nothing ran but the check", h.hooks(), []string(nil))
	eq(t, "still live", h.live(), "r1")
	// Mods off: nothing to recheck.
	if err := h.toggle(); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(h.dir, "check-fails"))
	before := h.state().Checks
	if err := h.update(); err != nil {
		t.Fatal(err)
	}
	eq(t, "no recheck while off", h.state().Checks, before)
}

func TestStatusCarriesSync(t *testing.T) {
	h := newHarness(t)
	sync := `{"since":"2026-10-25T08:00:00Z","last_ok":"2026-10-25T08:59:00Z","errors":0}`
	write(t, filepath.Join(h.cfg.RunDir, "sync.json"), sync+"\n")
	s, err := h.agent().Status()
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "sync", string(s.Sync), sync)
	b, _ := json.Marshal(s)
	if !strings.Contains(string(b), `"sync":{"since"`) {
		t.Fatalf("sync not in the JSON: %s", b)
	}
	write(t, filepath.Join(h.cfg.RunDir, "sync.json"), "{half")
	s, _ = h.agent().Status()
	if s.Sync != nil {
		t.Fatalf("broken sync.json reported: %s", s.Sync)
	}
}

type strErr string

func (e strErr) Error() string { return string(e) }

func errorsNew(s string) error { return strErr(s) }
