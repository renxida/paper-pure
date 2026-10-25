package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"paper-pure/agent/internal/release"
)

// Hook names. Both are optional; a missing hook is a no-op.
const (
	HookActivate   = "activate.sh"
	HookDeactivate = "deactivate.sh"
)

// XochitlInfo is what `systemctl show` says about the UI unit.
type XochitlInfo struct {
	Active   string
	PID      int
	Restarts int
}

func (a *Agent) probeXochitl(ctx context.Context) (XochitlInfo, error) {
	if a.Probe != nil {
		return a.Probe(ctx)
	}
	out, err := exec.CommandContext(ctx, a.cfg.Systemctl, "show", a.cfg.XochitlUnit,
		"--property=ActiveState", "--property=MainPID", "--property=NRestarts").Output()
	if err != nil {
		return XochitlInfo{}, fmt.Errorf("systemctl show %s: %w", a.cfg.XochitlUnit, err)
	}
	var x XochitlInfo
	for _, ln := range strings.Split(string(out), "\n") {
		k, v, _ := strings.Cut(strings.TrimSpace(ln), "=")
		switch k {
		case "ActiveState":
			x.Active = v
		case "MainPID":
			x.PID, _ = strconv.Atoi(v)
		case "NRestarts":
			x.Restarts, _ = strconv.Atoi(v)
		}
	}
	return x, nil
}

// checkXochitl: xochitl must reach active, then stay active with the same
// PID and restart count for StableSeconds. A crash loop changes the PID.
func (a *Agent) checkXochitl(ctx context.Context, m *release.Manifest) error {
	if a.cfg.StableSeconds <= 0 && len(m.ExpectMapped) == 0 {
		return nil
	}
	poll := time.Duration(a.cfg.PollMillis) * time.Millisecond
	window := time.Duration(a.cfg.StableSeconds) * time.Second
	var base XochitlInfo
	deadline := a.now().Add(window + 30*time.Second)
	for {
		x, err := a.probeXochitl(ctx)
		if err != nil {
			return err
		}
		if x.Active == "active" && x.PID > 0 {
			base = x
			break
		}
		if a.now().After(deadline) {
			return fmt.Errorf("xochitl not active (state %q)", x.Active)
		}
		if err := a.sleep(ctx, poll); err != nil {
			return err
		}
	}
	end := a.now().Add(window)
	for a.now().Before(end) {
		if err := a.sleep(ctx, poll); err != nil {
			return err
		}
		x, err := a.probeXochitl(ctx)
		if err != nil {
			return err
		}
		if x.Active != "active" || x.PID != base.PID || x.Restarts != base.Restarts {
			return fmt.Errorf("xochitl not stable: was pid %d restarts %d, now %s pid %d restarts %d",
				base.PID, base.Restarts, x.Active, x.PID, x.Restarts)
		}
	}
	if len(m.ExpectMapped) > 0 {
		maps, err := os.ReadFile(filepath.Join(a.cfg.ProcDir, strconv.Itoa(base.PID), "maps"))
		if err != nil {
			return fmt.Errorf("read xochitl maps: %w", err)
		}
		for _, want := range m.ExpectMapped {
			if !bytes.Contains(maps, []byte(want)) {
				return fmt.Errorf("xochitl (pid %d) has not loaded %q", base.PID, want)
			}
		}
	}
	return nil
}

func (a *Agent) env(id, reason string) []string {
	return append(os.Environ(),
		"PP_ROOT="+a.cfg.Root,
		"PP_RELEASE_ID="+id,
		"PP_RELEASE_DIR="+a.cfg.releaseDir(id),
		"PP_REASON="+reason,
		"PP_OS_VERSION="+a.osVersion,
	)
}

// runScript runs one hook or check with a timeout. The whole process group
// dies on timeout. Output goes to the log.
func (a *Agent) runScript(ctx context.Context, path, id, reason string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var cmd *exec.Cmd
	if fi, err := os.Stat(path); err == nil && fi.Mode()&0o111 != 0 {
		cmd = exec.CommandContext(ctx, path)
	} else {
		cmd = exec.CommandContext(ctx, "/bin/sh", path)
	}
	cmd.Dir = a.cfg.releaseDir(id)
	cmd.Env = a.env(id, reason)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	var out bytes.Buffer
	lw := &limitWriter{w: &out, n: 16 << 10} // one writer = one pipe, no race
	cmd.Stdout, cmd.Stderr = lw, lw
	start := a.now()
	err := cmd.Run()
	if errors.Is(err, exec.ErrWaitDelay) {
		err = nil // it exited 0 but left a child holding stdout
	}
	rel, _ := filepath.Rel(a.cfg.Root, path)
	a.logf("ran %s (%s, %s): %v", rel, reason, a.now().Sub(start).Round(time.Millisecond), errOr(err, "ok"))
	if s := strings.TrimSpace(out.String()); s != "" {
		for _, ln := range strings.Split(s, "\n") {
			a.logf("  | %s", ln)
		}
	}
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("%s: timed out after %s", rel, timeout)
	}
	if err != nil {
		return fmt.Errorf("%s: %w: %s", rel, err, tail(out.String(), 300))
	}
	return nil
}

// runHook runs one hook and keeps the live marker: set before activate
// (from then on mods may be live), cleared once deactivate succeeds.
func (a *Agent) runHook(ctx context.Context, id, hook, reason string) error {
	if id == "" {
		return nil
	}
	if hook == HookActivate {
		a.setLive(id)
	}
	p := filepath.Join(a.cfg.releaseDir(id), "hooks", hook)
	var err error
	if _, serr := os.Stat(p); serr == nil {
		a.resetFailed(ctx)
		err = a.runScript(ctx, p, id, reason, time.Duration(a.cfg.HookTimeout)*time.Second)
	}
	if hook == HookDeactivate && err == nil {
		a.clearLive()
	}
	return err
}

// resetFailed zeroes xochitl's start-limit counter before every hook.
// Stock xochitl has StartLimitBurst=4 in 600 s and OnFailure=emergency.target
// (rm-emergency.sh reboots). Our own deliberate restarts must not use up
// that budget, so the 4 starts are left for crashes and the health check
// gets to roll back first.
func (a *Agent) resetFailed(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, a.cfg.Systemctl, "reset-failed", a.cfg.XochitlUnit).CombinedOutput(); err != nil {
		a.logf("systemctl reset-failed %s: %v %s", a.cfg.XochitlUnit, err, strings.TrimSpace(string(out)))
	}
}

// runChecks runs the built-in checks, then the release's checks/* in
// order, and keeps the outcome for the status report.
func (a *Agent) runChecks(ctx context.Context, id, reason string, m *release.Manifest) error {
	err := a.checkXochitl(ctx, m)
	if err == nil {
		err = a.runReleaseChecks(ctx, id, reason)
	}
	a.noteChecks(id, reason, err)
	return err
}

// recheck re-runs the live release's checks/* (not the 70 s xochitl
// window), so the status report says whether they still pass while mods
// are on. It changes nothing: a failure is reported, not acted on.
func (a *Agent) recheck(ctx context.Context) {
	id := a.live()
	if id == "" || id != a.st.Current || a.disabled() {
		return
	}
	err := a.runReleaseChecks(ctx, id, "recheck")
	a.noteChecks(id, "recheck", err)
	if err != nil {
		a.logf("recheck %s: %v", id, err)
	}
}

func (a *Agent) noteChecks(id, reason string, err error) {
	a.checksRan = true
	a.st.Checks = &CheckResult{Time: a.now().UTC(), Release: id, Reason: reason, OK: err == nil, Error: errOr(err, "")}
}

func (a *Agent) runReleaseChecks(ctx context.Context, id, reason string) error {
	dir := filepath.Join(a.cfg.releaseDir(id), "checks")
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil // no checks dir
	}
	var names []string
	for _, e := range ents {
		if e.Type().IsRegular() && !strings.HasPrefix(e.Name(), ".") && !strings.HasSuffix(e.Name(), "~") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for _, n := range names {
		if err := a.runScript(ctx, filepath.Join(dir, n), id, reason, time.Duration(a.cfg.CheckTimeout)*time.Second); err != nil {
			return err
		}
	}
	return nil
}

type limitWriter struct {
	w *bytes.Buffer
	n int
}

func (l *limitWriter) Write(p []byte) (int, error) {
	if room := l.n - l.w.Len(); room > 0 {
		if len(p) > room {
			l.w.Write(p[:room])
		} else {
			l.w.Write(p)
		}
	}
	return len(p), nil
}

func tail(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return "..." + s[len(s)-n:]
	}
	return s
}

func errOr(err error, ok string) string {
	if err != nil {
		return err.Error()
	}
	return ok
}
