package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Config is agent.json. Every field has a default that is right for a
// Paper Pure (tatsu) on OS 3.27.2.2; a config file only overrides.
type Config struct {
	// Root holds bin/, releases/, current, state/, keys/.
	Root string `json:"root"`
	// FeedURL is the release feed directory: FeedURL/latest.json,
	// FeedURL/latest.json.sig and FeedURL/<id>.tar.gz. Empty = no updates.
	FeedURL string `json:"feed_url"`
	// StatusURL receives a JSON status POST after every run. Empty = off.
	StatusURL string `json:"status_url"`
	// Headers go on every request (e.g. Cloudflare Access service token:
	// CF-Access-Client-Id / CF-Access-Client-Secret). Keep this file 0600.
	Headers map[string]string `json:"headers"`
	// PubKey is the release public key (PEM). Default <root>/keys/release.pub.pem.
	PubKey string `json:"pubkey"`
	// CAFile, if set, replaces the system CA roots (e.g. to pin one CA).
	CAFile string `json:"ca_file"`

	Device    string `json:"device"`     // must equal manifest.device
	OSRelease string `json:"os_release"` // file with IMG_VERSION=

	// Gates for update (not for boot).
	RequireWifi     bool   `json:"require_wifi"`
	WifiIface       string `json:"wifi_iface"`
	SysClassNet     string `json:"sys_class_net"`
	ProcNetRoute    string `json:"proc_net_route"`
	BatteryFloor    int    `json:"battery_floor"` // percent; 0 = ignore battery
	BatteryCapacity string `json:"battery_capacity"`
	ChargerOnline   string `json:"charger_online"`
	RequireCharging bool   `json:"require_charging"`

	// Health.
	Systemctl     string `json:"systemctl"`
	XochitlUnit   string `json:"xochitl_unit"`
	StableSeconds int    `json:"stable_seconds"` // 0 = skip the xochitl check
	PollMillis    int    `json:"poll_millis"`
	HookTimeout   int    `json:"hook_timeout_seconds"`
	CheckTimeout  int    `json:"check_timeout_seconds"`
	ProcDir       string `json:"proc_dir"`

	// Boot. ActivateOnBoot false (default) = a reboot is stock; mods come
	// back by a triple-press or the next install.
	ActivateOnBoot bool `json:"activate_on_boot"`
	BootGuardMax   int  `json:"boot_guard_max"` // unhealthy boots before staying stock

	// Kill switch. RunDir holds the "live" marker (tmpfs: gone at reboot,
	// like xovi's drop-in). PowerKeyDevice "" = find it under SysClassInput.
	RunDir         string `json:"run_dir"`
	PowerKeyDevice string `json:"power_key_device"`
	SysClassInput  string `json:"sys_class_input"`
	TapGapMillis   int    `json:"tripletap_gap_ms"` // max time between presses

	HTTPTimeout int `json:"http_timeout_seconds"` // per run, all requests
}

// Defaults are the tatsu values found in the 3.27.2.2 rootfs:
// libcslpower.so reads /sys/class/power_supply/max77818_battery/capacity and
// /sys/class/power_supply/max77818-charger/online; Wi-Fi is wlan0 under
// wpa_supplicant + systemd-networkd (/etc/systemd/network/25-wlan0.network).
func Defaults() Config {
	return Config{
		Root:            "/home/root/paper-pure",
		Device:          "tatsu",
		OSRelease:       "/etc/os-release",
		RequireWifi:     true,
		WifiIface:       "wlan0",
		SysClassNet:     "/sys/class/net",
		ProcNetRoute:    "/proc/net/route",
		BatteryFloor:    30,
		BatteryCapacity: "/sys/class/power_supply/max77818_battery/capacity",
		ChargerOnline:   "/sys/class/power_supply/max77818-charger/online",
		Systemctl:       "systemctl",
		XochitlUnit:     "xochitl.service",
		StableSeconds:   70, // > xochitl's WatchdogSec=60, so a hung UI is caught
		PollMillis:      1000,
		HookTimeout:     120,
		CheckTimeout:    60,
		ProcDir:         "/proc",
		ActivateOnBoot:  false,
		BootGuardMax:    3,
		RunDir:          "/run/paper-pure",
		SysClassInput:   "/sys/class/input",
		TapGapMillis:    3000,
		HTTPTimeout:     900,
	}
}

// LoadConfig reads path over the defaults. A missing file means defaults.
func LoadConfig(path string) (Config, error) {
	c := Defaults()
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return c, err
	}
	if err == nil {
		dec := json.NewDecoder(strings.NewReader(string(b)))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&c); err != nil {
			return c, fmt.Errorf("%s: %w", path, err)
		}
	}
	return c.normalize(), nil
}

func (c Config) normalize() Config {
	if c.PubKey == "" {
		c.PubKey = filepath.Join(c.Root, "keys", "release.pub.pem")
	}
	if c.FeedURL != "" && !strings.HasSuffix(c.FeedURL, "/") {
		c.FeedURL += "/"
	}
	if c.PollMillis <= 0 {
		c.PollMillis = 1000
	}
	if c.TapGapMillis <= 0 {
		c.TapGapMillis = 3000
	}
	return c
}

func (c Config) releasesDir() string         { return filepath.Join(c.Root, "releases") }
func (c Config) releaseDir(id string) string { return filepath.Join(c.Root, "releases", id) }
func (c Config) currentLink() string         { return filepath.Join(c.Root, "current") }
func (c Config) stateDir() string            { return filepath.Join(c.Root, "state") }
func (c Config) downloadsDir() string        { return filepath.Join(c.Root, "downloads") }
func (c Config) disableFile() string         { return filepath.Join(c.Root, "disable") }
func (c Config) liveFile() string            { return filepath.Join(c.RunDir, "live") }
