package agent

// The human kill switch: triple-press power toggles mods. Mods on means
// "turn them off" (deactivate, stock UI). Mods off means "turn the current
// release on" through the same activate + health check as everything else.

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Linux input events (linux/input-event-codes.h). struct input_event on a
// 64-bit kernel: struct timeval (2 x 8 bytes), u16 type, u16 code, s32 value.
const (
	evKey          = 1
	keyPower       = 116
	inputEventSize = 24
	tapPresses     = 3
)

// Toggle is one triple-press (also `pp-agent toggle` over SSH).
//
//   - Off when mods are live (pp-agent turned them on, or xochitl runs with
//     LD_PRELOAD, e.g. xovi started by hand), when the kill switch file
//     exists, or when another pp-agent run is busy (it is turning mods on:
//     we stop it).
//   - On otherwise: activate the committed release and health-check it.
//     A failure deactivates it again, so the end state is stock.
func (a *Agent) Toggle(ctx context.Context) error {
	busy := false
	if err := a.lock(false); errors.Is(err, ErrBusy) {
		busy = true
		if pid := a.lockHolder(); pid > 0 && pid != os.Getpid() {
			a.logf("toggle: pp-agent pid %d is busy, stopping it", pid)
			syscall.Kill(pid, syscall.SIGTERM)
		}
		if err := a.lock(true); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	if err := a.load(); err != nil {
		return err
	}
	off := busy || a.live() != "" || a.disabled() || a.preloaded(ctx)
	// A stopped install is rolled back without turning the old release on
	// again. It is marked failed, so it is not retried by itself.
	a.recover(ctx, false)
	// A human said off or on. Off sticks: no install and no boot turns
	// mods on until the next triple-press.
	a.st.ModsOff = off
	if off {
		res, err := a.modsOff(ctx)
		return a.end(ctx, res, err)
	}
	res, err := a.modsOn(ctx)
	return a.end(ctx, res, err)
}

func (a *Agent) modsOff(ctx context.Context) (string, error) {
	id := a.live()
	if id == "" && a.preloaded(ctx) {
		id = a.st.Current // on, but not by us: any release's deactivate is stock
		if id == "" {
			// Started by hand (mods/install.sh) before any release: xovi's own stock script.
			a.resetFailed(ctx)
			if err := a.runScript(ctx, a.cfg.HandStock, "", "tripletap", time.Duration(a.cfg.HookTimeout)*time.Second); err != nil {
				a.st.event(a.now(), "tripletap", "", false, "hand-started mods: "+err.Error())
				return "tripletap: could not turn hand-started mods off", err
			}
			a.clearLive()
			a.st.event(a.now(), "tripletap", "", true, "mods off (started by hand, no release)")
			return "tripletap: mods off (started by hand)", nil
		}
	}
	if id == "" {
		a.st.event(a.now(), "tripletap", "", true, "mods already off")
		return "tripletap: mods already off", nil
	}
	if _, err := os.Stat(a.cfg.releaseDir(id)); err != nil {
		id = a.st.Current // the live one was pruned; any release's deactivate is stock
	}
	if err := a.runHook(ctx, id, HookDeactivate, "tripletap"); err != nil {
		a.st.event(a.now(), "tripletap", id, false, "deactivate failed: "+err.Error())
		return "tripletap: deactivate failed", err
	}
	a.clearLive() // even if id was "" (no release left at all)
	a.st.event(a.now(), "tripletap", id, true, "mods off")
	return "tripletap: mods off (" + id + ")", nil
}

func (a *Agent) modsOn(ctx context.Context) (string, error) {
	id := a.st.Current
	if id == "" {
		return "tripletap: no release installed, stock", nil
	}
	m, err := a.loadManifest(id)
	if err != nil {
		return "tripletap: cannot read manifest, stock", err
	}
	if !m.SupportsOS(a.osVersion) {
		return "tripletap: OS changed, stock", fmt.Errorf("OS is %q but %s was tested on %v", a.osVersion, id, m.OSVersions)
	}
	if err := a.activate(ctx, id, "tripletap", m); err != nil {
		if ctx.Err() != nil { // stopping: the live marker stays, the next press turns it off
			return "tripletap: interrupted", err
		}
		a.runHook(ctx, id, HookDeactivate, "tripletap-failed")
		msg := fmt.Sprintf("%s unhealthy when turned on: %v; stock", id, err)
		a.st.event(a.now(), "tripletap", id, false, msg)
		return "tripletap: unhealthy, stock", errors.New(msg)
	}
	a.st.event(a.now(), "tripletap", id, true, "mods on")
	return "tripletap: mods on (" + id + ")", nil
}

// preloaded: xochitl runs with LD_PRELOAD set. Stock tatsu units set none;
// xovi's drop-in sets it. So this means mods are on, whoever turned them on.
func (a *Agent) preloaded(ctx context.Context) bool {
	x, err := a.probeXochitl(ctx)
	if err != nil || x.PID <= 0 {
		return false
	}
	b, err := os.ReadFile(filepath.Join(a.cfg.ProcDir, strconv.Itoa(x.PID), "environ"))
	if err != nil {
		return false
	}
	for _, kv := range strings.Split(string(b), "\x00") {
		if v, ok := strings.CutPrefix(kv, "LD_PRELOAD="); ok && v != "" {
			return true
		}
	}
	return false
}

// TripleTap watches the power key and runs Toggle on three presses, each
// within TapGapMillis of the one before. pp-agent-tripletap.service runs it.
// Presses that happen while a toggle runs are ignored.
func (a *Agent) TripleTap(ctx context.Context) error {
	dev := a.cfg.PowerKeyDevice
	if dev == "" {
		var err error
		if dev, err = FindPowerKey(a.cfg.SysClassInput); err != nil {
			return err
		}
	}
	f, err := openInput(dev)
	if err != nil {
		return err
	}
	defer f.Close()
	stop := context.AfterFunc(ctx, func() { f.Close() }) // unblocks Read
	defer stop()
	gap := time.Duration(a.cfg.TapGapMillis) * time.Millisecond
	a.logf("tripletap: watching %s for %d presses, each within %s", dev, tapPresses, gap)
	t := tapper{c: tapCounter{need: tapPresses, gap: gap}, now: a.now}
	err = readPresses(f, func(at time.Time) {
		t.press(at, func() {
			a.logf("tripletap: %d presses", tapPresses)
			if err := a.Toggle(ctx); err != nil {
				a.logf("tripletap: %v", err)
			}
		})
	})
	if ctx.Err() != nil || errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// tapper runs toggle on every completed triple-press and ignores presses
// made while a toggle was running (they queue up in the kernel meanwhile).
type tapper struct {
	c          tapCounter
	now        func() time.Time
	quietUntil time.Time
}

func (t *tapper) press(at time.Time, toggle func()) {
	if at.Before(t.quietUntil) || !t.c.press(at) {
		return
	}
	toggle()
	t.quietUntil = t.now()
}

// openInput opens the key device read-only. A FIFO (tests) is opened
// read-write, so open does not wait for a writer and EOF never comes.
func openInput(path string) (*os.File, error) {
	if fi, err := os.Stat(path); err == nil && fi.Mode()&os.ModeNamedPipe != 0 {
		return os.OpenFile(path, os.O_RDWR, 0)
	}
	return os.Open(path)
}

// tapCounter counts presses that follow each other closely enough.
type tapCounter struct {
	need int
	gap  time.Duration
	n    int
	last time.Time
}

func (c *tapCounter) press(t time.Time) bool {
	if c.n > 0 && !t.Before(c.last) && t.Sub(c.last) <= c.gap {
		c.n++
	} else {
		c.n = 1
	}
	c.last = t
	if c.n >= c.need {
		c.n = 0
		return true
	}
	return false
}

// readPresses calls fn with the kernel timestamp of every KEY_POWER press
// (value 1; releases and autorepeat are ignored) until r fails.
func readPresses(r io.Reader, fn func(time.Time)) error {
	br := bufio.NewReaderSize(r, inputEventSize*64)
	var ev [inputEventSize]byte
	for {
		if _, err := io.ReadFull(br, ev[:]); err != nil {
			if errors.Is(err, io.ErrUnexpectedEOF) {
				err = io.EOF
			}
			return err
		}
		sec := int64(binary.LittleEndian.Uint64(ev[0:8]))
		usec := int64(binary.LittleEndian.Uint64(ev[8:16]))
		typ := binary.LittleEndian.Uint16(ev[16:18])
		code := binary.LittleEndian.Uint16(ev[18:20])
		val := int32(binary.LittleEndian.Uint32(ev[20:24]))
		if typ == evKey && code == keyPower && val == 1 {
			fn(time.Unix(sec, usec*1000))
		}
	}
}

// FindPowerKey returns /dev/input/eventN for the power key. By name first:
// on tatsu the key is the i.MX93 BBNSM (DT nxp,imx93-bbnsm-pwrkey), named
// "44440000.bbnsm:pwrkey" as in /etc/pm/sleep.wakesrc. Then any device
// whose key capabilities include KEY_POWER.
func FindPowerKey(sysClassInput string) (string, error) {
	evs, _ := filepath.Glob(filepath.Join(sysClassInput, "event*"))
	sort.Slice(evs, func(i, j int) bool { return evNum(evs[i]) < evNum(evs[j]) })
	byCap := ""
	for _, e := range evs {
		name, _ := readTrim(filepath.Join(e, "device", "name"))
		n := strings.ToLower(name)
		if strings.Contains(n, "pwrkey") || strings.Contains(n, "powerkey") {
			return "/dev/input/" + filepath.Base(e), nil
		}
		if byCap == "" && hasKey(filepath.Join(e, "device", "capabilities", "key"), keyPower) {
			byCap = "/dev/input/" + filepath.Base(e)
		}
	}
	if byCap != "" {
		return byCap, nil
	}
	return "", fmt.Errorf("no power key under %s (set power_key_device)", sysClassInput)
}

func evNum(p string) int {
	n, _ := strconv.Atoi(strings.TrimPrefix(filepath.Base(p), "event"))
	return n
}

// hasKey reads a sysfs key bitmap: hex words of 64 bits, highest first.
func hasKey(path string, code int) bool {
	s, err := readTrim(path)
	if err != nil {
		return false
	}
	words := strings.Fields(s)
	i := len(words) - 1 - code/64
	if i < 0 {
		return false
	}
	w, err := strconv.ParseUint(words[i], 16, 64)
	return err == nil && w&(1<<(code%64)) != 0
}
