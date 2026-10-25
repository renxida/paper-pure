// Package agent is the on-tablet update agent: pull a signed release, flip
// one symlink, health-check, roll back by itself on failure.
package agent

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"paper-pure/agent/internal/release"
)

// Version is set at build time with -ldflags "-X ...agent.Version=...".
var Version = "dev"

// Agent does one command per process run; there is no daemon.
type Agent struct {
	cfg       Config
	st        *State
	osVersion string
	http      *http.Client
	lockFile  *os.File

	// Test seams. nil means the real thing.
	Probe func(ctx context.Context) (XochitlInfo, error)
	Now   func() time.Time
	Sleep func(ctx context.Context, d time.Duration) error
}

// New prepares the directory layout and reads the OS version.
func New(cfg Config) (*Agent, error) {
	cfg = cfg.normalize()
	for _, d := range []string{cfg.Root, cfg.releasesDir(), cfg.stateDir(), cfg.downloadsDir()} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, err
		}
	}
	hc, err := newHTTPClient(cfg)
	if err != nil {
		return nil, err
	}
	a := &Agent{cfg: cfg, http: hc, st: &State{}}
	a.osVersion, err = OSVersion(cfg.OSRelease)
	if err != nil {
		a.logf("cannot read OS version: %v", err)
	}
	return a, nil
}

func (a *Agent) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

func (a *Agent) sleep(ctx context.Context, d time.Duration) error {
	if a.Sleep != nil {
		return a.Sleep(ctx, d)
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (a *Agent) statePath() string { return filepath.Join(a.cfg.stateDir(), "state.json") }

// ErrBusy means another pp-agent run holds the lock.
var ErrBusy = errors.New("another pp-agent run is in progress")

func (a *Agent) lock(wait bool) error {
	f, err := os.OpenFile(filepath.Join(a.cfg.stateDir(), "lock"), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	how := syscall.LOCK_EX
	if !wait {
		how |= syscall.LOCK_NB
	}
	if err := syscall.Flock(int(f.Fd()), how); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return ErrBusy
		}
		return err
	}
	// The holder's PID, so a triple-press can stop a busy run (Toggle).
	f.Truncate(0)
	f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0)
	a.lockFile = f
	return nil
}

func (a *Agent) unlock() {
	if a.lockFile != nil {
		a.lockFile.Truncate(0)
		a.lockFile.Close()
		a.lockFile = nil
	}
}

// lockHolder is the PID of the run holding the lock, or 0.
func (a *Agent) lockHolder() int {
	b, _ := os.ReadFile(filepath.Join(a.cfg.stateDir(), "lock"))
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return pid
}

// begin takes the lock and loads state; end saves and reports.
func (a *Agent) begin(wait bool) error {
	if err := a.lock(wait); err != nil {
		return err
	}
	return a.load()
}

func (a *Agent) load() error {
	st, err := loadState(a.statePath())
	if err != nil {
		a.unlock()
		return fmt.Errorf("state: %w", err)
	}
	a.st = st
	return nil
}

// disabled: the kill switch file exists. Nothing turns mods on then.
func (a *Agent) disabled() bool {
	_, err := os.Stat(a.cfg.disableFile())
	return err == nil
}

// live is the release whose activate hook ran last and whose deactivate
// hook has not succeeded since ("" = stock). It lives in RunDir, a tmpfs,
// so a reboot clears it, just as a reboot clears xovi's drop-in.
func (a *Agent) live() string {
	b, _ := os.ReadFile(a.cfg.liveFile())
	return strings.TrimSpace(string(b))
}

func (a *Agent) setLive(id string) {
	if err := os.MkdirAll(a.cfg.RunDir, 0o755); err == nil {
		err = os.WriteFile(a.cfg.liveFile(), []byte(id+"\n"), 0o644)
	}
}

func (a *Agent) clearLive() { os.Remove(a.cfg.liveFile()) }

func (a *Agent) end(ctx context.Context, result string, err error) error {
	a.st.LastRun = a.now().UTC()
	a.st.LastResult = result
	a.st.LastError = errOr(err, "")
	if serr := a.save(); serr != nil && err == nil {
		err = serr
	}
	if err != nil {
		a.logf("result: %s: %v", result, err)
	} else {
		a.logf("result: %s", result)
	}
	a.report(ctx)
	a.unlock()
	return err
}

func (a *Agent) save() error { return a.st.save(a.statePath()) }

// ---- the pointer ------------------------------------------------------------

// linkTarget returns the release id `current` points at ("" = stock).
func (a *Agent) linkTarget() string {
	t, err := os.Readlink(a.cfg.currentLink())
	if err != nil {
		return ""
	}
	return filepath.Base(t)
}

// flip points `current` at releases/<id> with one rename(2); id "" removes
// it (stock). The target is relative so the tree can be moved or mounted.
func (a *Agent) flip(id string) error {
	link := a.cfg.currentLink()
	if id == "" {
		if err := os.Remove(link); err != nil && !os.IsNotExist(err) {
			return err
		}
		return syncDir(a.cfg.Root)
	}
	tmp := link + ".tmp"
	os.Remove(tmp)
	if err := os.Symlink(filepath.Join("releases", id), tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, link); err != nil {
		return err
	}
	a.logf("current -> releases/%s", id)
	return syncDir(a.cfg.Root)
}

func (a *Agent) loadManifest(id string) (*release.Manifest, error) {
	b, err := os.ReadFile(filepath.Join(a.cfg.releasesDir(), id+".json"))
	if err != nil {
		return nil, err
	}
	return release.ParseManifest(b)
}

// ---- install, commit, roll back ---------------------------------------------

// activate runs the activate hook then all checks.
func (a *Agent) activate(ctx context.Context, id, reason string, m *release.Manifest) error {
	if err := a.runHook(ctx, id, HookActivate, reason); err != nil {
		return err
	}
	return a.runChecks(ctx, id, reason, m)
}

// install flips to m (already unpacked in releases/) and keeps it only if
// it is healthy. On failure it rolls back to the committed release.
func (a *Agent) install(ctx context.Context, m *release.Manifest, reason string) error {
	old := a.st.Current
	a.st.Pending = m.ID
	if err := a.save(); err != nil {
		return err
	}
	if err := a.runHook(ctx, old, HookDeactivate, reason); err != nil {
		a.logf("deactivate %s failed (continuing): %v", old, err)
	}
	if err := a.flip(m.ID); err != nil {
		a.rollback(ctx, m.ID, "flip: "+err.Error(), true)
		return err
	}
	if err := a.activate(ctx, m.ID, reason, m); err != nil {
		if ctx.Err() != nil {
			// Stopped mid-check (shutdown, e.g. the OS's emergency reboot,
			// or a triple-press). Don't run hooks against a stopping system:
			// Pending stays set and the next run rolls back, as after a
			// power cut.
			return fmt.Errorf("release %s interrupted before its health check passed; the next run rolls it back: %w", m.ID, err)
		}
		a.rollback(ctx, m.ID, err.Error(), true)
		return fmt.Errorf("release %s unhealthy, rolled back to %s: %w", m.ID, orStock(old), err)
	}
	if old != "" && old != m.ID {
		a.st.Previous = old
	}
	a.st.Current, a.st.Pending = m.ID, ""
	a.st.UnhealthyBoots, a.st.GuardTripped = 0, false
	a.st.event(a.now(), reason, m.ID, true, "healthy, committed")
	if err := a.save(); err != nil {
		return err
	}
	a.prune()
	return nil
}

// rollback undoes a pending release: deactivate it, mark it failed, point
// back at the committed release and (if wanted and allowed) re-activate it.
// Every step is safe to repeat, and Pending is only cleared at the end, so a
// power cut in here just means the next run does it again.
func (a *Agent) rollback(ctx context.Context, bad, why string, reactivate bool) {
	// Finish even if our context was cancelled (SIGTERM); hooks and checks
	// keep their own timeouts. If we get SIGKILLed, Pending is still set and
	// the next run starts over.
	ctx = context.WithoutCancel(ctx)
	good := a.st.Current
	a.logf("rolling back %s -> %s: %s", bad, orStock(good), why)
	if err := a.runHook(ctx, bad, HookDeactivate, "rollback"); err != nil {
		a.logf("deactivate %s failed (continuing): %v", bad, err)
	}
	a.st.markFailed(bad)
	if err := a.flip(good); err != nil {
		a.logf("flip back failed: %v", err)
	}
	msg := "rolled back to " + orStock(good) + ": " + why
	if reactivate && good != "" && !a.st.GuardTripped && !a.disabled() {
		m, err := a.loadManifest(good)
		if err == nil {
			err = a.activate(ctx, good, "rollback", m)
		}
		if err != nil {
			a.runHook(ctx, good, HookDeactivate, "rollback")
			msg += "; " + good + " also unhealthy (" + err.Error() + "), running stock"
		}
	}
	a.st.Pending = ""
	a.st.event(a.now(), "rollback", bad, false, msg)
	if err := a.save(); err != nil {
		a.logf("save: %v", err)
	}
}

// recover finishes whatever a killed or rebooted run left behind.
func (a *Agent) recover(ctx context.Context, reactivate bool) {
	if a.st.Pending != "" {
		a.rollback(ctx, a.st.Pending, "interrupted before health check passed (reboot or kill)", reactivate)
	}
	if t := a.linkTarget(); t != a.st.Current {
		a.logf("current points at %q but committed is %q: fixing pointer", t, a.st.Current)
		if err := a.flip(a.st.Current); err != nil {
			a.logf("fix pointer: %v", err)
		}
	}
}

// prune keeps the committed and previous releases and drops the rest.
func (a *Agent) prune() {
	keep := map[string]bool{}
	for _, id := range []string{a.st.Current, a.st.Previous} {
		if id != "" {
			keep[id], keep[id+".json"], keep[id+".json.sig"] = true, true, true
		}
	}
	ents, _ := os.ReadDir(a.cfg.releasesDir())
	for _, e := range ents {
		if !keep[e.Name()] {
			os.RemoveAll(filepath.Join(a.cfg.releasesDir(), e.Name()))
		}
	}
	os.RemoveAll(a.cfg.downloadsDir())
	os.MkdirAll(a.cfg.downloadsDir(), 0o755)
}

func orStock(id string) string {
	if id == "" {
		return "stock"
	}
	return id
}

// note records an outcome as an event unless it repeats the last error,
// so an hourly "rejected" does not flood the history.
func (a *Agent) note(kind, id string, ok bool, msg string) {
	if !ok && msg == a.st.LastError {
		return
	}
	a.st.event(a.now(), kind, id, ok, msg)
}

// ---- commands ---------------------------------------------------------------

// Update is the timer job: gates, fetch, verify, unpack, install, report.
func (a *Agent) Update(ctx context.Context) error {
	if err := a.begin(false); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(a.cfg.HTTPTimeout)*time.Second+10*time.Minute)
	defer cancel()
	a.recover(ctx, true)
	res, err := a.update(ctx)
	return a.end(ctx, res, err)
}

func (a *Agent) update(ctx context.Context) (string, error) {
	if a.disabled() {
		return "skipped: kill switch " + a.cfg.disableFile() + " exists", nil
	}
	if a.cfg.FeedURL == "" {
		return "no feed_url, nothing to do", nil
	}
	if ok, why := wifiOK(a.cfg); !ok {
		return "skipped: " + why, nil
	}
	if ok, why := batteryOK(a.cfg); !ok {
		return "skipped: " + why, nil
	}
	pub, err := release.LoadPublicKey(a.cfg.PubKey)
	if err != nil {
		return "no release key", err
	}
	hctx, cancel := context.WithTimeout(ctx, time.Duration(a.cfg.HTTPTimeout)*time.Second)
	defer cancel()
	mb, err := a.getSmall(hctx, a.cfg.FeedURL+"latest.json")
	if err != nil {
		return "feed unreachable", err
	}
	sb, err := a.getSmall(hctx, a.cfg.FeedURL+"latest.json.sig")
	if err != nil {
		return "feed unreachable", err
	}
	m, err := release.Verify(pub, mb, sb)
	if err != nil {
		err = fmt.Errorf("latest.json rejected: %w", err)
		a.note("reject", "", false, err.Error())
		return "rejected", err
	}
	if m.ID == a.st.Current {
		return "up to date (" + m.ID + ")", nil
	}
	if slices.Contains(a.st.Failed, m.ID) {
		return fmt.Sprintf("latest %s failed before; staying on %s", m.ID, orStock(a.st.Current)), nil
	}
	if reason := a.refuse(m); reason != "" {
		err := fmt.Errorf("release %s refused: %s", m.ID, reason)
		a.note("reject", m.ID, false, err.Error())
		return "rejected", err
	}
	part := filepath.Join(a.cfg.downloadsDir(), m.Tarball()+".part")
	if err := a.download(hctx, a.cfg.FeedURL+m.Tarball(), part, m.Size, m.SHA256); err != nil {
		return "download failed", err
	}
	if err := a.unpack(m, part, mb, sb); err != nil {
		a.note("unpack", m.ID, false, err.Error())
		return "unpack failed", err
	}
	if err := a.install(ctx, m, "install"); err != nil {
		return "rolled back " + m.ID, err
	}
	return "installed " + m.ID, nil
}

// refuse returns why m must not be installed here, or "".
func (a *Agent) refuse(m *release.Manifest) string {
	if m.Device != a.cfg.Device {
		return fmt.Sprintf("built for device %q, this is %q", m.Device, a.cfg.Device)
	}
	if !m.SupportsOS(a.osVersion) {
		return fmt.Sprintf("tested on OS %v, this tablet runs %q", m.OSVersions, a.osVersion)
	}
	if a.st.Current != "" {
		if cur, err := a.loadManifest(a.st.Current); err == nil && !m.Created.After(cur.Created) {
			return fmt.Sprintf("created %s, not newer than current %s (%s); re-sign to roll back on purpose",
				m.Created.Format(time.RFC3339), cur.ID, cur.Created.Format(time.RFC3339))
		}
	}
	return ""
}

// unpack extracts a verified tarball into releases/<id> via a staging dir,
// and stores the signed manifest next to it.
func (a *Agent) unpack(m *release.Manifest, part string, mb, sb []byte) error {
	staging := filepath.Join(a.cfg.releasesDir(), ".staging-"+m.ID)
	os.RemoveAll(staging)
	f, err := os.Open(part)
	if err != nil {
		return err
	}
	err = release.Extract(f, staging)
	f.Close()
	if err != nil {
		os.RemoveAll(staging)
		return err
	}
	dst := a.cfg.releaseDir(m.ID)
	if err := os.RemoveAll(dst); err != nil {
		return err
	}
	if err := os.Rename(staging, dst); err != nil {
		return err
	}
	if err := writeFileAtomic(dst+".json", mb, 0o644); err != nil {
		return err
	}
	if err := writeFileAtomic(dst+".json.sig", sb, 0o644); err != nil {
		return err
	}
	os.Remove(part)
	return syncDir(a.cfg.releasesDir())
}

// Boot runs once per boot, before anything enables mods. It is the only
// thing that turns mods on at boot, and it refuses after BootGuardMax boots
// in a row that never reached healthy.
func (a *Agent) Boot(ctx context.Context) error {
	if err := a.begin(true); err != nil {
		return err
	}
	a.recover(ctx, false)
	res, err := a.boot(ctx)
	return a.end(ctx, res, err)
}

func (a *Agent) boot(ctx context.Context) (string, error) {
	id := a.st.Current
	switch {
	case id == "":
		a.st.UnhealthyBoots = 0
		return "boot: stock (no release installed)", nil
	case a.disabled():
		return "boot: kill switch " + a.cfg.disableFile() + " exists, staying stock", nil
	case !a.cfg.ActivateOnBoot:
		return "boot: stock (activate_on_boot is off; triple-press turns " + id + " on)", nil
	case a.st.GuardTripped:
		return fmt.Sprintf("boot: guard tripped, staying stock until a new release passes (%s not activated)", id), nil
	}
	m, err := a.loadManifest(id)
	if err != nil {
		return "boot: cannot read manifest, staying stock", err
	}
	if !m.SupportsOS(a.osVersion) {
		err := fmt.Errorf("OS is %q but %s was tested on %v", a.osVersion, id, m.OSVersions)
		a.note("boot", id, false, err.Error())
		return "boot: OS changed under us, staying stock", err
	}
	if a.st.UnhealthyBoots >= a.cfg.BootGuardMax {
		a.st.GuardTripped = true
		msg := fmt.Sprintf("%d boots in a row never got healthy; staying stock until a new release passes", a.st.UnhealthyBoots)
		a.st.event(a.now(), "guard", id, false, msg)
		return "boot: guard tripped", errors.New(msg)
	}
	// Count this boot as unhealthy until proven otherwise, and make sure
	// that is on disk before we touch anything.
	a.st.UnhealthyBoots++
	if err := a.save(); err != nil {
		return "boot: cannot save state", err
	}
	if err := a.activate(ctx, id, "boot", m); err != nil {
		a.runHook(ctx, id, HookDeactivate, "boot-failed")
		msg := fmt.Sprintf("%s unhealthy at boot (%d/%d): %v; running stock this boot", id, a.st.UnhealthyBoots, a.cfg.BootGuardMax, err)
		a.st.event(a.now(), "boot", id, false, msg)
		return "boot: unhealthy, stock", errors.New(msg)
	}
	a.st.UnhealthyBoots = 0
	return "boot: " + id + " healthy", nil
}

// Rollback is the manual undo: reinstall the previous release (with the
// usual checks) and never auto-install the current one again.
func (a *Agent) Rollback(ctx context.Context) error {
	if err := a.begin(true); err != nil {
		return err
	}
	a.recover(ctx, true)
	bad, prev := a.st.Current, a.st.Previous
	if a.disabled() {
		return a.end(ctx, "rollback: refused", fmt.Errorf("kill switch %s exists; remove it first", a.cfg.disableFile()))
	}
	if prev == "" {
		return a.end(ctx, "rollback: no previous release", errors.New("no previous release on disk"))
	}
	m, err := a.loadManifest(prev)
	if err != nil {
		return a.end(ctx, "rollback: previous release unreadable", err)
	}
	if err := a.install(ctx, m, "manual-rollback"); err != nil {
		return a.end(ctx, "rollback failed", err)
	}
	a.st.markFailed(bad)
	return a.end(ctx, "rolled back to "+prev, nil)
}

// ResetGuard clears the boot-loop guard by hand (over SSH).
func (a *Agent) ResetGuard(ctx context.Context) error {
	if err := a.begin(true); err != nil {
		return err
	}
	a.st.UnhealthyBoots, a.st.GuardTripped = 0, false
	a.st.event(a.now(), "guard", a.st.Current, true, "reset by hand")
	return a.end(ctx, "guard reset", nil)
}

// Status reads state without the lock (read-only, for humans and scripts).
func (a *Agent) Status() (Status, error) {
	st, err := loadState(a.statePath())
	if err != nil {
		return Status{}, err
	}
	a.st = st
	return a.status(), nil
}

// Report sends status now (e.g. from `pp-agent report`).
func (a *Agent) Report(ctx context.Context) error {
	if _, err := a.Status(); err != nil {
		return err
	}
	a.report(ctx)
	return nil
}
