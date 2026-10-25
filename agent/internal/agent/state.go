package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"time"
)

// State is state/state.json. The `current` symlink says what is live; this
// file says what was committed and what is in flight.
type State struct {
	// Current is the last release that passed health checks ("" = stock).
	Current string `json:"current"`
	// Previous is the release before Current, kept on disk for `rollback`.
	Previous string `json:"previous"`
	// Pending is set while a new release is flipped in but not yet healthy.
	// Finding it set at startup means we died mid-check: roll back.
	Pending string `json:"pending"`
	// Failed releases are never installed again automatically.
	Failed []string `json:"failed"`

	UnhealthyBoots int  `json:"unhealthy_boots"`
	GuardTripped   bool `json:"guard_tripped"`

	LastRun    time.Time `json:"last_run"`
	LastResult string    `json:"last_result"`
	LastError  string    `json:"last_error"`
	Events     []Event   `json:"events"`
}

// Event is one notable thing, kept for the status report.
type Event struct {
	Time time.Time `json:"time"`
	Kind string    `json:"kind"`
	ID   string    `json:"id,omitempty"`
	OK   bool      `json:"ok"`
	Msg  string    `json:"msg,omitempty"`
}

const (
	maxEvents = 30
	maxFailed = 50
)

func loadState(path string) (*State, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return &State{}, nil
	}
	if err != nil {
		return nil, err
	}
	var s State
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

func (s *State) markFailed(id string) {
	if id == "" || slices.Contains(s.Failed, id) {
		return
	}
	s.Failed = append(s.Failed, id)
	if len(s.Failed) > maxFailed {
		s.Failed = s.Failed[len(s.Failed)-maxFailed:]
	}
}

func (s *State) event(now time.Time, kind, id string, ok bool, msg string) {
	s.Events = append(s.Events, Event{Time: now.UTC(), Kind: kind, ID: id, OK: ok, Msg: msg})
	if len(s.Events) > maxEvents {
		s.Events = s.Events[len(s.Events)-maxEvents:]
	}
}

// writeFileAtomic writes via temp file + fsync + rename + dir fsync, so a
// power cut leaves either the old file or the new one.
func writeFileAtomic(path string, b []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, ".tmp-"+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return syncDir(dir)
}

func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (s *State) save(path string) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, append(b, '\n'), 0o644)
}
