package agent

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// readTrim reads a small sysfs-style file.
func readTrim(path string) (string, error) {
	b, err := os.ReadFile(path)
	return strings.TrimSpace(string(b)), err
}

// OSVersion returns IMG_VERSION from an os-release file (3.27.2.2 on
// Cedar's tablet). It is the reMarkable build, not the Yocto VERSION_ID.
func OSVersion(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), "=")
		if ok && k == "IMG_VERSION" {
			return strings.Trim(v, `"'`), nil
		}
	}
	if err := sc.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("%s: no IMG_VERSION", path)
}

// wifiOK: the Wi-Fi interface is up and holds the default route. That
// rules out USB networking (usb0 has no route) and flight mode.
func wifiOK(c Config) (bool, string) {
	if !c.RequireWifi {
		return true, "wifi not required"
	}
	st, err := readTrim(filepath.Join(c.SysClassNet, c.WifiIface, "operstate"))
	if err != nil {
		return false, fmt.Sprintf("no %s: %v", c.WifiIface, err)
	}
	if st != "up" {
		return false, fmt.Sprintf("%s is %s", c.WifiIface, st)
	}
	f, err := os.Open(c.ProcNetRoute)
	if err != nil {
		return false, err.Error()
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fl := strings.Fields(sc.Text())
		// Iface Destination Gateway Flags ...
		if len(fl) >= 2 && fl[0] == c.WifiIface && fl[1] == "00000000" {
			return true, c.WifiIface + " up with default route"
		}
	}
	return false, c.WifiIface + " up but no default route"
}

// batteryOK: charging, or capacity at or above the floor. Unknown battery
// counts as not OK unless the floor is 0.
func batteryOK(c Config) (bool, string) {
	charging := false
	if s, err := readTrim(c.ChargerOnline); err == nil && s == "1" {
		charging = true
	}
	if c.RequireCharging && !charging {
		return false, "not charging"
	}
	if charging {
		return true, "charging"
	}
	if c.BatteryFloor <= 0 {
		return true, "battery floor off"
	}
	s, err := readTrim(c.BatteryCapacity)
	if err != nil {
		return false, "battery unknown: " + err.Error()
	}
	pct, err := strconv.Atoi(s)
	if err != nil {
		return false, "battery unknown: " + s
	}
	if pct < c.BatteryFloor {
		return false, fmt.Sprintf("battery %d%% < floor %d%%", pct, c.BatteryFloor)
	}
	return true, fmt.Sprintf("battery %d%%", pct)
}

func batteryPercent(c Config) int {
	s, err := readTrim(c.BatteryCapacity)
	if err != nil {
		return -1
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return -1
	}
	return n
}
