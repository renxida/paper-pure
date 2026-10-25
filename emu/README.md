# emu: Paper Pure emulator

Rung 2 of the dev loop. Boots the **stock Paper Pure OS (tatsu, 3.27.2.2, the version on Cedar's tablet)** in a Docker container and lets Claude drive it from a CLI: look, tap, write, SSH in, deploy, restart.

The device's own root filesystem runs unmodified in an arm64 container, booted by its own systemd, laid out like the tablet (read-only `/`, `/etc` overlay with a tmpfs upper, `wlan0` up). A preload shim fakes the hardware xochitl talks to: the e-ink controller (SWTCON over a fake DRM device), pen, touch, buttons, battery, charger, temperature, secure key store. Native on arm64 (Apple Silicon, arm64 Linux); under qemu-user on x86_64, which works but is slow.

Forked from [rmemu](https://github.com/aetherino/rmemu) (Paper Pro emulator, MIT, upstream commit `3483a43`, license kept in [LICENSE.rmemu](LICENSE.rmemu)). We adapt it, we don't rewrite it.

> No reMarkable code lives here. `ppemu setup` downloads reMarkable's public update package into `emu/firmware/` (gitignored) for local use. Never commit or redistribute it, or anything unpacked from it.

## Run it

Needs Docker, Node 20+, `curl`, `openssl`, `cpio`, `ssh`/`ssh-keygen`. On x86_64 also qemu-user binfmt for arm64 (`docker run --privileged --rm tonistiigi/binfmt --install arm64`, or the `qemu-user-static` package).

```bash
emu/bin/ppemu start          # first run: fetch + verify firmware (~140 MB), build image, boot
emu/bin/ppemu skip-setup     # fresh device: skip onboarding, land on My files
emu/bin/ppemu screenshot /tmp/s.png --scale 0.5
emu/bin/ppemu tap 700 1716   # device pixels, portrait 1404x1872 (this is "+": then Notebook 644,1324, Create 1326,56)
emu/bin/ppemu draw 700,900 1250,900
emu/bin/ppemu ssh 'cat /etc/version /sys/devices/soc0/machine'   # 20260520084102, reMarkable Tatsu
emu/bin/ppemu logs | tail    # the device's journal, as its console prints it
emu/bin/ppemu reboot         # like rebooting the tablet: runtime drop-ins and /etc edits are gone
emu/bin/ppemu wifi off       # flight mode (wlan0 gone); `wifi on` brings it back
emu/bin/ppemu reset          # factory reset: removes the container and the pp-emu-home / pp-emu-data volumes; then `start`
emu/bin/ppemu help           # everything else
```

Every command returns once the screen has settled: `start`, `skip-setup` and `restart` wait for xochitl's UI, input commands wait for the redraw. `reset` leaves the emulator stopped; the next `start` boots the onboarding screen.

Simulator UI for humans: http://127.0.0.1:7777 (pen, eraser, finger, power key, Marker). Agents: [the `pure-emulator` skill](../.claude/skills/pure-emulator/SKILL.md).

Names: container `pp-emu-tablet`, images `pp-emu-tatsu:<version>` (emulator) and `pp-emu-rootfs:<version>` (plain rootfs), volumes `pp-emu-home` and `pp-emu-data`. Ports on 127.0.0.1: 7777 UI + HTTP API, 8888 device hub, 2222 SSH. The device itself is on docker's default bridge as `wlan0`; it reaches this host at the bridge gateway (`ppemu status` prints both, usually 172.17.0.1).

On an arm64 host nothing changes: same commands, no qemu, and the CLI drops its long waits on its own (it checks `process.arch`).

How slow is x86_64? Measured here (4 vCPU, qemu 8.2): `start` on a factory-fresh device 100 to 117 s to the Welcome screen; `skip-setup` 66 s to My files; `start` of a stopped device 65 s; `restart` 62 s; `rebuild` 2 to 2.2 min back to My files; a tap 4 to 6 s round trip; Settings 11 s; a pen stroke 5 s. The very first `start` also imports the rootfs (about 1 min) and builds the image, whose apt step takes about 6.5 min under qemu once (cached after). The CLI waits longer on non-arm64 hosts (`PPEMU_SLOW=1|0` overrides).

## How it works

```
 host                                 container pp-emu-tablet (stock tatsu rootfs, linux/arm64)
┌──────────────────────┐   :8888    ┌───────────────────────────────────────────────┐
│ host/server.mjs      │◀──────────▶│ systemd (the image's own, PID 1)              │
│  · simulator UI (WS) │            │ ├ rmemud   input hub · display relay · uevents│
│  · HTTP API          │   :2222    │ ├ xochitl ── rmemu-shim.so (ld.so.preload)    │
│ bin/ppemu (CLI)      │◀── ssh ───▶│ │  fake DRM for SWTCON · framebuffer capture  │
└──────────────────────┘            │ │  evdev · udev · sd_device · libiio · sysfs  │
                                    │ ├ dbus, logind, resolved, marker-manager,     │
                                    │ │  rm-sync, dropbear, rm-sanity, …  (stock)   │
                                    │ └ whatever you install (pp-agent, pp-proxy …) │
                                    └───────────────────────────────────────────────┘
```

xochitl renders the UI into a 1404x1872 RGB32 image that SWTCON turns into waveform frames for the panel. The shim grabs that image when it is created and streams changed tiles to the host; that is the screenshot. Input goes the other way as fake evdev events. Everything else xochitl asks the hardware for comes from `docker/root/sys/` or a stub in `shim/`.

## Like the tablet: systemd, /etc, reboot

So the rest of the stack runs here unmodified. `docker/boot.sh` lays out the mounts, then hands PID 1 to the image's own systemd 255, which boots the stock units.

- **`/` is read-only.** The container layer under it is the tablet's root partition: `mount -o remount,rw /` works, and what you write there survives `ppemu reboot` / `stop` / `start`. `ppemu rebuild` and `reset` start from a fresh layer, like reflashing.
- **`/etc` is an overlay with a tmpfs upper**, mounted by the stock `var-volatile-etc.service`. Plain writes (a runtime drop-in, an `/etc/hosts` line, `systemctl enable`) are gone after a reboot. Writing through `mount --bind / X` lands in the real root fs and stays: the device lane's `pp-device.sh persist`, remagic's trick.
- **`/run` and `/tmp` are tmpfs**, fresh every boot.
- **systemd is real**: drop-ins, `Environment=`, `systemctl show` (`ActiveState`, `MainPID`, `NRestarts`, timestamps), `stop` of a stopped unit, `reset-failed`, `is-active`, enable/disable/mask, timers (`rm-sanity.timer` at 60 s, `pp-agent.timer`), `OnFailure=`, start limits. `xovi/start`'s tmpfs drop-in reaches xochitl as on the tablet.
- **xochitl's stock unit and drop-in apply**, including `Restart=on-failure`, the start limit (4 in 10 min) and `OnFailure=emergency.target`, whose `rm-emergency.sh` reboots. Here that reboot stops the container; `ppemu start` boots it again. `ppemu restart` and `skip-setup` call `reset-failed` first, so a dev loop doesn't trip the start limit.
- **Emulator-only units live in `/run/systemd/system`** (rebuilt each boot, so the root fs and `/etc` stay stock):
  - `rmemud.service`, the hardware hub; `dropbear.socket`, SSH on the container network through the stock `dropbear@.service` (the tablet listens on `usb0`).
  - Masks: hardware the container doesn't have (udev, tee-supplicant, keystore and home crypto, zram, Wi-Fi and Bluetooth daemons, networkd, chronyd, getty, USB gadget) and reMarkable's phone-home daemons (`memfaultd`, `memfault-attributes`, `crashuploader`, `mdm-agent`). `swupdate` is left alone; it fails at start here (no memfaultd config).
  - xochitl's stock drop-in minus `Requires=dev-dri-card0.device` (only udev would announce it).
  - Unit credentials reset (the container can't mount the credentials fs, and none are passed on the tablet either).
  - Under qemu-user only: xochitl's `WatchdogSec` 10 min instead of 60 s; its main thread can be busy for over a minute building a page.
- **Fake hardware at the real paths.** `docker/root/sys` is bind-mounted over `/sys/class/{power_supply,hwmon,input}`, `/sys/devices/{platform/lpgpr,platform/suspend-event,soc0}`, `/sys/firmware/devicetree` and `/sys/power`, so static binaries (pp-agent) see it too. Only `/proc/device-tree` and `/sys/nfc` still need the shim.
  - `lpgpr`: slot `a`, `roota_errcnt` 1 at boot, which the stock `rm-sanity` zeroes 60 s in (no slot switching). `soc0/serial_number` is the machine-id, random per container.
  - `/dev/input/event0..3` are FIFOs fed by rmemud, for programs without the shim. The power key is `event0`, named `44440000.bbnsm:pwrkey` as in the image's `/etc/pm/sleep.wakesrc`.
- **The shim leaves systemd alone**: PID 1, the `systemd-*` daemons and rmemud get no fakes (PID 1 aborted on them, logind crashed on a fake device monitor).
- **Shutdown and reboot go through systemd.** `ppemu stop` is `systemctl poweroff`, `ppemu reboot` is `systemctl reboot` plus `start`. (docker stop's `SIGRTMIN+3` doesn't reach systemd under qemu-user.)
- **Container flags this needs**: `--cap-add SYS_ADMIN`, seccomp and AppArmor unconfined, `--cgroupns host -v /sys/fs/cgroup:/sys/fs/cgroup:rw`, `--read-only`, `-t`. No `--privileged`, no `NET_ADMIN`. `bin/ppemu` passes them.

## Network

- **`wlan0`** is the container's only interface, on docker's default bridge, up, with the default route: what pp-agent's Wi-Fi gate wants, with default config. `ppemu wifi off` disconnects it (flight mode: pp-agent says `no wlan0`). While it is off, the host can't reach the device either (no SSH, no screen); use `docker exec pp-emu-tablet ...`.
- **The host** is the bridge gateway, usually `172.17.0.1` (`ppemu status` says). A server on the host must listen there or on `0.0.0.0`. Example: `ppsign serve -dir FEED -addr 172.17.0.1:3191`, then `"feed_url": "http://172.17.0.1:3191/"` in the device's `agent.json`. `host.docker.internal` does not exist inside (docker's `/etc/hosts` is replaced by the tablet's).
- **Names** resolve like on the tablet: glibc asks `systemd-resolved` (running), which reads `/etc/hosts`; docker's DNS servers stand in for DHCP's. Edits to `/etc/hosts` work at once and are gone at reboot unless persisted (`pp-device.sh persist /etc/hosts`). Note: resolved answers a `0.0.0.0` line with "no address" (NODATA), not with `0.0.0.0`. Static Go programs read `/etc/hosts` themselves.
- To route the device's cloud traffic to a test server: point names at it in `/etc/hosts` (pp-proxy's `hosts` block does this for reMarkable's sync names, at `127.0.0.1`), and give pp-proxy/pp-agent the host address.

## Firmware

`ppemu setup [version]` defaults to 3.27.2.2 from reMarkable's public update bucket (`remarkable-software.s3.us-east-2.amazonaws.com`, listable; `ppemu versions` shows what is there). Checks, in order:

1. sha256 of the `.swu` against a pinned table in `bin/ppemu` (3.27.2.2 and 3.27.1.0 are pinned; other versions warn and skip this step).
2. `sw-description.sig` verifies against the swupdate public key shipped inside the image (`/usr/share/swupdate/swupdate-payload-key-pub.pem`), and that key's sha256 matches the fingerprint pinned in `tools/import-rootfs.sh`.
3. The rootfs image's sha256 matches the one `sw-description` lists.

Already have the file? `ppemu setup --swu FILE`, drop it in `emu/firmware/`, or point `PPEMU_FIRMWARE_DIR` at its folder.

## How it differs from upstream rmemu

| Area | rmemu (Paper Pro, ferrari) | here (Paper Pure, tatsu) | How we know |
| --- | --- | --- | --- |
| Screen | 1620x2160 RGB32 | 1404x1872 RGB32 (`EPFramebufferCarta1300`) | `fb:` log line, screenshots |
| SWTCON scanout mode | 405x1084 | 260x1408, htotal 263, vtotal 1557, 34.8 MHz = 85 Hz; DRM driver `imx-drm` | xochitl logs `DRM error: size mismatch ... (expected 1408x260)`; timings from the `epd-panel` node of the tatsu device trees; the tatsu kernel builds in `imx/imxdrm.ko` + `lcdifv3`, no mxsfb (`modules.builtin`) |
| Model string | absent | `/proc/device-tree/model` and `/sys/devices/soc0/machine` = `reMarkable Tatsu` (AppLoad, codexctl and remagic read these to detect the device) | `model` in every `/boot/freescale/tatsu-rev-*.dtb` of the image |
| Battery / charger sysfs | `max1726x_battery`, `max77963-charger` | `max77818_battery`, `max77818-charger` (marker-manager still reads `max77963-charger/online`, mirrored) | strings in `libcslpower.so`, `marker-manager` |
| Temperature hwmon | `rm_hwmon_temp` | `ertj0eg103fa` | `temperature_hwmon: found temperature path` in log |
| Device tree `display-info` | absent | width 1404, height 1872, dpi 226, bpp 24 (big-endian u32). libepaper reads width/height/dpi; its built-in fallback is 228 dpi | `fdtget` on the image's `tatsu-rev-c` to `-i` dtbs (all agree); the reads show up under `restart --debug` |
| Front light, keyboard light, Folio keyboard | yes | none on the Pure, nothing to fake | `libcsllight.so` absent |
| x86 hosts | not supported | works under qemu-user, with shim fixes (below) | boots here |
| Firmware source | codexctl index | pinned table + reMarkable's bucket; codexctl only lists 3.27.1.0 for the Pure | `data/version-ids.json` |
| Init | a shell loop runs xochitl; stub `systemctl` | the image's own systemd, tablet mounts (see above) | |
| Names | `rmemu`, `bin/rmemu` | `pp-emu-*`, `bin/ppemu` (same commands, plus `rebuild`, `reboot`, `wifi`) | |

Additions in `shim/`, the first two for qemu-user:

- **Alarm clocks.** `clock_gettime(CLOCK_BOOTTIME_ALARM)` fails on hosts without a wake-capable RTC, so sd-event refuses alarm timers and marker-manager aborts (`Failed to add timer: Operation not supported`). The shim falls back to the plain clock, as upstream already did for `timerfd_create`.
- **Top realtime signals.** qemu-user can't map guest signals 62 to 64 onto host signals, so blocking them silently does nothing and `sd_event_add_signal` returns EBUSY; xochitl aborts (`Failed to add SIGNO_PRE_AUTOSLEEP handler`). The shim listens on a spare signal instead. Those signals come from the suspend-event driver, which doesn't exist here.
- **Busy main thread counts as activity.** Under qemu xochitl can compute for 10 to 60 s before it draws a new page (boot, Settings). The shim times how long xochitl's main thread has been out of `poll`/`ppoll` and the display scanner reports that as activity, so "wait until the screen settles" doesn't return halfway. Natively this just makes waits a little more honest.
- **freopen.** busybox `hexdump` opens files with `freopen`, which upstream didn't hook, so `hexdump /proc/device-tree/...` saw nothing. Now the device shell sees the same fake tree as xochitl.
- **Hands off systemd** (`hooks.c`): no fakes in PID 1, `systemd-*` and rmemud.
- **Screen capture lets go before the free** (`fb.c`): the scanner thread kept reading SWTCON's screen buffer after xochitl freed it on exit, and xochitl segfaulted on many stops (3 of 4 pp-agent install/rollback restarts here). Upstream has the same race; with a shell loop nobody saw it. Under systemd each one is a failure, and `OnFailure=emergency.target` rebooted the "tablet". The shim now hooks `free()` for that one buffer.
- **Crashes say where** (`hooks.c`): a SIGSEGV/SIGBUS in a shimmed process logs the faulting code and its caller as `library(symbol+offset)` before the default action. That is how the race above was found.

Internal names (`/opt/rmemu`, `/run/rmemu`, `RMEMU_*`, `rmemud`) stay as upstream so their fixes still apply cleanly.

## Blind spots

What the emulator can't tell you. Test these on the tablet.

- **E-ink timing.** No waveforms reach a panel. The screenshot is the image xochitl renders, shown instantly; no flashing, ghosting, or partial-refresh artifacts. SWTCON runs against a fake DRM device paced at 85 Hz (the panel's device-tree timing), but nothing is scanned out, so refresh durations mean nothing. Waveform selection also fails (`wf_search: unable to read epd serial`, no devconfig), which is harmless here and untested.
- **Pen latency and feel.** Pen events are synthetic evdev. Device names come from rmemu's Paper Pro fakes (`Elan marker input`, `Elan touchscreen`, and the i.MX8 power key `30370000.snvs:snvs-powerkey`; the Pure's is an i.MX93 `bbnsm` power key). Ranges are an rmemu convention: pen 1/10 px (0..14040 x 0..18720), touch in px. The Pure's device tree says the `elants_spi` digitizer has marker 13000x9620 and touch 2400x1776 with `swap-axes` and `flip-pos-y`; what the driver reports through evdev is unknown. xochitl finds devices by udev properties and scales by the reported ranges, so strokes land where you draw; apps that hard-code real ranges won't. Under qemu-user everything is 10x to 50x slower. Desiderata #4 (writing feel) can only be judged on hardware.
- **Battery.** Fake sysfs numbers; `ppemu battery N` and `ppemu usb connect` change them. No discharge curve, no fuel-gauge behaviour.
- **Sleep.** The power key shows the sleep screen and wakes again, but nothing suspends: writes to `/sys/power/state` land in a fake file, alarm timers run on plain clocks, and xochitl logs `Missing resume event, triggering fallback wakeup`.
- **Colour.** xochitl renders an RGB32 image; the real panel is grayscale. Highlighter/colour ink shows in colour in screenshots. A second 1404x1872 Grayscale8 buffer exists but stays empty here.
- **Storage.** Settings shows the Docker host's disk (e.g. 228 GB of 252 GB), not a 32 GB tablet.
- **Kernel.** `uname -r` shows the Docker host's kernel, not the tablet's `6.12.49+git-imx93-tatsu`; no kernel modules or drivers run.
- **Not running at all:** the Wi-Fi radio (`wlan0` is a docker veth; wpa_supplicant and networkd are masked), Bluetooth, memfaultd, crashuploader, mdm-agent (masked: the emulator doesn't phone home), swupdate (fails at start), tee-supplicant (a software PKCS#11 token stands in for OP-TEE), chronyd, real orientation sensor, NFC (marker-manager talks to fake sysfs). rm-sync runs; it syncs nothing until pointed at a server.
- **Boot ROM.** No A/B slots: `lpgpr` is fake, the error count is 1 at each boot and rm-sanity clears it, nothing ever switches slot.

## Change the emulator

- C in `shim/` (preload library, `shim/pkcs11/` soft token) and `daemon/rmemud.c` compiles inside the Docker build (Ubuntu 24.04 arm64; glibc 2.39 matches the rootfs). After editing: `emu/bin/ppemu rebuild` (keeps `/home` and `/data`; the root fs starts fresh).
- The boot: `docker/boot.sh` (mounts, masks) and `docker/units/` (emulator-only units). Same `rebuild`.
- Missing hardware: `ppemu restart --debug`, then `ppemu logs` shows every hardware path and ioctl; `FAIL` lines are what's missing. Fake sysfs goes in `docker/root/sys/...`; `docker/root/proc/device-tree` is a symlink to the fake device tree, as on the device.
- Host side (`host/`, `bin/ppemu`) is plain Node with no dependencies.

## Status

### Independent re-check (second agent, README only, same host), Oct 25 2026

Started from the running emulator, followed "Run it" as a newcomer, then fixed what was off and ran the whole flow again on a wiped device:

- `ppemu reset` → `device data wiped`, no `pp-emu-*` container or volume left (`docker volume ls`). `ppemu start` → 100 to 112 s, onboarding "Welcome to your reMarkable Paper Pure". `ppemu skip-setup` → 64 s, My files "Make your mark".
- `ppemu tap 700 1716`, `tap 644 1324`, `tap 1326 56` → each `ok (screen changed)` in 4 to 6 s; ends in an open notebook with the pen panel and tooltip.
- `ppemu draw 650,1500 800,1400 950,1550 1100,1400 1250,1550` → `ok (screen changed)` in 5 s. In full-size screenshots every one of those points is white before and pure black (0,0,0) after. The README's own `draw 700,900 1250,900` drew a black line too; a fresh notebook started on black Pencil both times (no highlighter yellow).
- Closing the notebook shows the strokes in the My files thumbnail. `ppemu pull` of the xochitl folder → the `.rm` parses with rmscene: 4 strokes, tool 14, colour 0 (black), at the drawn coordinates.
- `ppemu ssh 'cat /etc/version /sys/devices/soc0/machine'` → `20260520084102`, `reMarkable Tatsu`; `/etc/os-release` `IMG_VERSION="3.27.2.2"`; hostname `imx93-tatsu`. Plain `ssh -i emu/.ppemu/id_ed25519 -p 2222 root@127.0.0.1` works too. `ppemu push` then `cat` on the device round-trips a file.
- `ppemu stop` then `ppemu start` → 65 s, notebook still there. `ppemu power` twice → sleep screen, then back to My files.
- `tools/import-rootfs.sh` re-run into a scratch tag → `signature ok, rootfs sha256 ok (3.27.2.2)` in 54 s. `PPEMU_KEY_SHA=0000` → refused, exit 1. Re-packed `.swu` with `3.27.2.2` changed to `3.27.2.3` in `sw-description` → `sw-description.sig does not verify`, exit 1. `ppemu versions` → the five tatsu builds.
- Simulator UI in headless Chromium (Playwright): page connects (green dot, `3.27.2.2`), the canvas shows the device, a finger click on the "+" menu's X closes it, a pen drag through 700,1400 900,1300 1100,1450 1250,1350 draws exactly there (checked with `ppemu screenshot`). No console errors after the favicon fix.

Fixed in this pass:

- **No model string.** `/proc/device-tree/model` and `/sys/devices/soc0/machine` were missing, so AppLoad's shim, codexctl and remagic couldn't tell this is a Pure. Both now say `reMarkable Tatsu`, the `model` in the image's own device trees.
- **Wrong dpi.** The fake `display-info/display-dpi` said 228 (libepaper's fallback). Every tatsu device tree in the image says 226; also added `display-bpp` 24. The DRM mode now uses the device tree's real panel timings and the connector reports 158x210 mm. Screens look the same; libepaper's reads show in `restart --debug`.
- **`restart` returned before xochitl was back.** A screenshot right after showed the old frame and a tap went nowhere (`no screen change`). It now waits for the UI (about 62 s here) and a tap right after works.
- **`reset` could claim a wipe that didn't happen.** With another container holding `pp-emu-home`, it printed `device data wiped` anyway. Now it exits 1 naming the volume (tested with a holder container), and succeeds once the holder is gone.
- **busybox `hexdump` couldn't see fake files** (`No such file or directory` on `/proc/device-tree/...` and `/sys/class/power_supply/...`): it uses `freopen`, which the shim didn't hook. Now it does.
- README: `cpio` was missing from the requirements; timings updated; "228 dpi" and "ranges copied from the Paper Pro" corrected; DRM driver name changed from the i.MX8 `mxsfb-drm` to `imx-drm`, which is what the tatsu kernel builds in.

### First pass (the agent that built it)

Verified in this container (x86_64, 4 vCPU, Docker 29, qemu-aarch64 8.2.2), Oct 25 2026:

- `tools/import-rootfs.sh .../remarkable-production-image-3.27.2.2-tatsu-public.swu` → `import-rootfs: signature ok, rootfs sha256 ok (3.27.2.2)`, image `pp-emu-rootfs:3.27.2.2` in 65 to 68 s.
- Negative checks: the same `.swu` with one edit in `sw-description` → `sw-description.sig does not verify`, exit 1; `PPEMU_KEY_SHA=0000` → `swupdate key sha256 is 7f77934c..., expected 0000`, exit 1.
- `ppemu versions` → lists 3.27.1.0, 3.27.2.2 (pinned, default), 3.27.3.0, 3.28.0.172, 3.29.0.153 from the bucket.
- `ppemu setup` with an empty `emu/firmware/` → downloaded 3.27.2.2 from the bucket, pinned sha256 matched, built `pp-emu-tatsu:3.27.2.2`.
- `ppemu reset && ppemu start` → returns after 117 s with "Welcome to your reMarkable Paper Pure / Choose your language to begin" on screen, 1404x1872. Then `ppemu skip-setup` → returns after 66 s on My files ("Make your mark").
- `ppemu tap 700 880` on the language list → UI switches to German (`Activated translation: de` in the log); tapping English switches back.
- `ppemu tap 700 1716` (+) → Create new menu; Notebook → New notebook dialog; Create → open notebook with the writing-tools tooltip.
- `ppemu draw 650,1100 800,1000 950,1150 1100,1000 1250,1150` (Black pencil) → an "M" exactly at those points; saved (`rm.scenefile Scene written to ...`) and shown in the My files thumbnail.
- `ppemu power` → "Paper tablet is sleeping" screen; `ppemu power` again → back to the notebook.
- `ppemu battery 15` → xochitl logs `battery level=15`, status bar battery icon drops. `ppemu usb connect` → charging bolt in the status bar.
- `ppemu marker dock` → marker-manager and xochitl react (`Starting marker mcu firmware update timer`); NFC driver missing, as expected.
- `ppemu ssh 'ls /home/root/.local/share/remarkable/xochitl/'` → lists the notebook; `ppemu pull` copies it out; the `.rm` parses with rmscene.
- Side menu → Settings → General settings shows `Software  Version 3.27.2.2`; the tap waits ~11 s for the page and reports "screen changed".
- `ppemu rebuild` → rebuilds the image, recreates the container, keeps the notebook, returns on My files (131 s).
- `ppemu logs`, `ppemu status`, `ppemu restart`, `ppemu restart --debug` work.
- Proof screenshots (not in the repo): `proof-1-welcome.png`, `proof-2-myfiles.png`, `proof-3-drawing.png`, `proof-4-settings.png`, `proof-5-final-drawing.png` in the pp-emu lane's scratch folder.

Not verified (either pass):

- arm64 hosts (Apple Silicon, arm64 Linux). Nothing x86-specific was added, and upstream runs natively there, but it was not run.
- Input device names and ranges against a real Pure (see Blind spots: the device tree gives the digitizer's resolution, not what evdev reports).
- `ppemu open` (needs a desktop), and the simulator UI in a headed browser with a real mouse or pen.
- The first-run image build from an empty Docker cache (the apt step was cached in both passes).

Open questions for Cedar:

- When you enable developer mode, can we read a few real values off the tablet: `cat /sys/class/input/*/device/name`, the pen and touch ABS ranges (`evtest`, or EVIOCGABS), and `ls /sys/class/power_supply`? Model and display values are now taken from the image's device trees; these are the guesses left.
- Which machine runs the emulator day to day? x86 works but costs ~100 s per boot and seconds per tap; an arm64 box would make it interactive.
