package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Status is what the agent POSTs to status_url and prints for `status`.
type Status struct {
	Device         string    `json:"device"`
	AgentVersion   string    `json:"agent_version"`
	Time           time.Time `json:"time"`
	OSVersion      string    `json:"os_version"`
	Release        string    `json:"release"`   // what `current` points at
	Live           string    `json:"live"`      // release with mods on now ("" = stock UI)
	Disabled       bool      `json:"disabled"`  // kill switch file present
	Committed      string    `json:"committed"` // last healthy release
	Previous       string    `json:"previous"`
	Pending        string    `json:"pending,omitempty"`
	Failed         []string  `json:"failed"`
	UnhealthyBoots int       `json:"unhealthy_boots"`
	GuardTripped   bool      `json:"guard_tripped"`
	LastRun        time.Time `json:"last_run"`
	LastResult     string    `json:"last_result"`
	LastError      string    `json:"last_error,omitempty"`
	BatteryPercent int       `json:"battery_percent"`
	// ModsOff: a triple-press turned mods off; no install or boot turns
	// them on until the next one.
	ModsOff bool `json:"mods_off"`
	// Checks: the last run of a release's checks (install, turn-on, boot,
	// or the recheck each update run does while mods are live).
	Checks *CheckResult `json:"checks,omitempty"`
	// Sync: what pp-proxy says about stock sync (server/tablet-proxy).
	Sync    json.RawMessage `json:"sync,omitempty"`
	Events  []Event         `json:"events"`
	LogTail string          `json:"log_tail"`
}

func (a *Agent) status() Status {
	s := a.st
	failed := s.Failed
	if failed == nil {
		failed = []string{}
	}
	return Status{
		Device:         a.cfg.Device,
		AgentVersion:   Version,
		Time:           a.now().UTC(),
		OSVersion:      a.osVersion,
		Release:        a.linkTarget(),
		Live:           a.live(),
		Disabled:       a.disabled(),
		Committed:      s.Current,
		Previous:       s.Previous,
		Pending:        s.Pending,
		Failed:         failed,
		UnhealthyBoots: s.UnhealthyBoots,
		GuardTripped:   s.GuardTripped,
		LastRun:        s.LastRun,
		LastResult:     s.LastResult,
		LastError:      s.LastError,
		BatteryPercent: batteryPercent(a.cfg),
		ModsOff:        s.ModsOff,
		Checks:         s.Checks,
		Sync:           a.syncStatus(),
		Events:         s.Events,
		LogTail:        a.logTail(4 << 10),
	}
}

// syncStatus is pp-proxy's sync.json as it is, if it is valid JSON.
func (a *Agent) syncStatus() json.RawMessage {
	b, err := os.ReadFile(a.cfg.syncFile())
	if err != nil || len(b) > 4<<10 || !json.Valid(b) {
		return nil
	}
	return json.RawMessage(bytes.TrimSpace(b))
}

// report POSTs status. Failure is logged, never fatal.
func (a *Agent) report(ctx context.Context) {
	if a.cfg.StatusURL == "" {
		return
	}
	b, _ := json.Marshal(a.status())
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := a.newRequest(ctx, http.MethodPost, a.cfg.StatusURL, bytes.NewReader(b))
	if err != nil {
		a.logf("report: %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.http.Do(req)
	if err != nil {
		a.logf("report: %v", err)
		return
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		a.logf("report: %v", httpError("POST", a.cfg.StatusURL, resp))
	}
}

// ---- log ------------------------------------------------------------------

const maxLog = 256 << 10

func (a *Agent) logPath() string { return filepath.Join(a.cfg.stateDir(), "agent.log") }

// logf writes to stderr (journald on the tablet) and to state/agent.log,
// rotated once at 256 KiB.
func (a *Agent) logf(format string, args ...any) {
	line := fmt.Sprintf("%s %s\n", a.now().UTC().Format(time.RFC3339), fmt.Sprintf(format, args...))
	os.Stderr.WriteString(line)
	p := a.logPath()
	if fi, err := os.Stat(p); err == nil && fi.Size() > maxLog {
		os.Rename(p, p+".1")
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	f.WriteString(line)
	f.Close()
}

func (a *Agent) logTail(n int64) string {
	f, err := os.Open(a.logPath())
	if err != nil {
		return ""
	}
	defer f.Close()
	fi, _ := f.Stat()
	if fi.Size() > n {
		f.Seek(fi.Size()-n, io.SeekStart)
	}
	b, _ := io.ReadAll(f)
	if fi.Size() > n {
		if i := bytes.IndexByte(b, '\n'); i >= 0 {
			b = b[i+1:]
		}
	}
	return string(b)
}
