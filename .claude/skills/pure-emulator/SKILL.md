---
name: pure-emulator
description: Drive the reMarkable Paper Pure emulator in emu/ (stock tatsu OS 3.27.2.2 in Docker): boot it, screenshot, tap/draw/swipe, press power, SSH in, push files, read logs, reset, and debug the emulator itself. Use whenever a task involves running, testing, screenshotting or interacting with the tablet, xochitl, or anything meant to run on the Paper Pure before it goes to the real device.
---

# Paper Pure emulator

`emu/bin/ppemu` drives a container (`pp-emu-tablet`) running the real Paper Pure root filesystem, booted by its own systemd and laid out like the tablet, with a hardware shim. It is rung 2 of the dev loop: nothing goes to Cedar's tablet that hasn't worked here. Read `emu/README.md` for what it can't tell you (e-ink timing, pen feel, battery, sleep).

Run commands from the repo root. Cedar may be watching the same device at http://127.0.0.1:7777, so act deliberately.

## 1. Get to a known state

```bash
emu/bin/ppemu status        # container, UI server, images, host speed
emu/bin/ppemu start         # boot (first run fetches + verifies firmware and builds the image)
emu/bin/ppemu skip-setup    # fresh device: skip onboarding, land on My files
emu/bin/ppemu reboot        # reboot the device (runtime drop-ins, /etc edits, /run, /tmp gone), wait for the UI
emu/bin/ppemu reset         # factory reset: wipes pp-emu-home/pp-emu-data (all notebooks), leaves it stopped; `start` then boots onboarding. Ask first if someone else uses it
```

On an x86 host the device runs under qemu-user: boot is ~100 s, `start` and `skip-setup` wait for it. `status` says `slow` when this applies.

## 2. Look, act, look

```bash
emu/bin/ppemu screenshot /tmp/s.png --scale 0.5    # prints "702x936; multiply by 2 for device coordinates"
```

Then Read the PNG. `--scale 0.5` is the default choice; `0.25` to see which screen you're on; `1` for fine detail.

**Coordinates are device pixels: portrait 1404x1872, origin top-left.** Multiply what you measure on a scaled screenshot by the printed factor.

```bash
emu/bin/ppemu tap X Y                     # finger: buttons, menus, navigation
emu/bin/ppemu tap X Y --pen               # pen tap
emu/bin/ppemu longpress X Y [--ms 900]    # file actions ("press and hold")
emu/bin/ppemu swipe X0 Y0 X1 Y1 [--ms 300] [--pen]
emu/bin/ppemu draw 700,900 900,800 1200,950 [--pressure 0.6] [--eraser]   # pen stroke through points
emu/bin/ppemu pinch CX CY R0 R1
emu/bin/ppemu wait --idle 3000            # until the screen stops changing
```

Each input command waits for the screen to settle, then prints `ok (screen changed)` or `ok (no screen change)`.

- "no screen change" usually means you missed: re-screenshot and re-measure.
- **Under qemu everything is slow** (a tap 4 to 5 s, Settings 11 s, boot about 100 s). Input commands already wait while xochitl's main thread is busy building a page, so trust "screen changed". If you get "no screen change" where you expected a change, `ppemu wait --idle 5000 --timeout 30000` and look again before acting. Don't stack blind taps: each one lands on whatever screen is current, which may be one you haven't seen yet.

## 3. Hardware

```bash
emu/bin/ppemu power                  # sleep screen / wake
emu/bin/ppemu usb connect|disconnect # charger (status bar shows the bolt)
emu/bin/ppemu battery 15             # battery percent
emu/bin/ppemu marker dock|undock     # Marker attach (marker-manager reacts; no NFC)
emu/bin/ppemu folio close|open       # hall sensor
emu/bin/ppemu wifi off|on            # flight mode: wlan0 gone (cuts SSH and the screen too; use docker exec meanwhile)
```

Don't use the in-OS Settings → Restart / Turn off; use `ppemu restart`.

## 4. Develop and deploy

The emulator behaves like a tablet in developer mode, systemd included:

```bash
emu/bin/ppemu ssh 'cmd'                  # like ssh root@10.11.99.1; interactive with no cmd
emu/bin/ppemu push ./thing /home/root/thing   # file or directory, any path (/tmp too)
emu/bin/ppemu pull /home/root/.local/share/remarkable/xochitl ./out
emu/bin/ppemu restart                    # reset-failed + restart xochitl, wait for its UI (~60 s under qemu); plain `systemctl restart xochitl` over ssh doesn't wait
emu/bin/ppemu logs [-f]                  # console: the journal (xochitl, shim, rmemud, every unit). Full: ppemu ssh journalctl -b [-u UNIT]
```

- Identity, as on the tablet: `cat /etc/version` → `20260520084102`; `/sys/devices/soc0/machine` and `/proc/device-tree/model` → `reMarkable Tatsu`; `IMG_VERSION="3.27.2.2"` in `/etc/os-release`.
- Scripts written for the real tablet run unmodified: `ssh -i emu/.ppemu/id_ed25519 -p 2222 root@127.0.0.1` (swap for `root@10.11.99.1` on hardware). `mods/install.sh emu`, `device/install.sh -p 2222 -i emu/.ppemu/id_ed25519 root@127.0.0.1` and pp-agent with default config all work here.
- **systemd is real** (the image's own, PID 1): units, drop-ins, `systemctl show`, timers, enable/mask, `OnFailure=`. xochitl's stock start limit applies: 4 starts in 10 min, then `emergency.target` reboots, which stops the container (`ppemu start` boots it again). `ppemu restart` and `skip-setup` reset the counter; your own scripts should `systemctl reset-failed xochitl` too, as on the tablet.
- **Persistence, as on the tablet:** `/` is read-only (`mount -o remount,rw /` works); `/etc` is an overlay with a tmpfs upper, so a plain write there is gone at `ppemu reboot`. Write through `mount --bind / X` (or `device/tablet/pp-device.sh persist`) to keep it. `/home` and `/data` are volumes. `ppemu rebuild` and `reset` give a fresh root fs (like reflashing).
- **Network:** the device's `wlan0` is up with the default route (pp-agent's Wi-Fi gate passes with default config). The host is the bridge gateway, usually `172.17.0.1` (`ppemu status` prints it); serve test servers there or on `0.0.0.0`. No `host.docker.internal` inside. `/etc/hosts` edits work at once (systemd-resolved reads it; it answers `0.0.0.0` lines with "no address").
- **Fake hardware at the real paths:** battery and charger (`/sys/class/power_supply/max77818_battery`, `max77818-charger`), `/sys/class/net/wlan0`, input names in `/sys/class/input`, `lpgpr`, `soc0`. Static binaries see them too. `/dev/input/event0..3` are FIFOs for programs without the shim; event0 is the power key (`44440000.bbnsm:pwrkey`).
- Notebooks: `/home/root/.local/share/remarkable/xochitl/`. Settings: `/home/root/.config/remarkable/xochitl.conf`, `/data/xochitl.conf`.
- Masked here (no hardware, or phone-home): udev, tee-supplicant, Wi-Fi/Bluetooth daemons, networkd, chronyd, memfaultd, crashuploader, mdm-agent. swupdate fails at start. `ppemu ssh systemctl --failed` shows only swupdate on a fresh device.
- The device shell is bash plus busybox: `head -n 3` (not `head -3`), no `od -A`, no python, no curl, no findmnt. Pull files out and inspect them on the host.
- Input devices for apps reading evdev directly: event0 power key, event1 pen (ABS_X 0..14040, ABS_Y 0..18720, pressure 0..4095), event2 touch (MT, 0..1403 x 0..1871), event3 hall sensor. Pen/touch names and ranges are emulator guesses, not read off a Pure.

## 5. UI map (3.27.2.2; verify with a screenshot)

| Where | Target | Device coords |
| --- | --- | --- |
| Onboarding | English / Deutsch, Next | 690,768 / 700,880, 700,1656 |
| My files | side menu, search, + new, calendar | 56,60; 588,1716; 700,1716; 812,1716 |
| + menu | Notebook, Folder, Quick sheet | 644,1324; 622,1426; 660,1542 |
| New notebook | Cancel, Create | 76,56; 1326,56 |
| Side menu | My files, Favorites, Tags, Trash, Guides, Settings | 146,60; 156,300; 126,420; 132,1570; 140,1692; 150,1812 |
| Settings page | Back | 56,56 |
| Open notebook | close document, toolbar column x=56 | 1348,56 |
| Notebook toolbar (x=56) | pen, 2nd pen, text, eraser, select, layers, undo, redo | y = 168, 280, 392, 504, 616, 728, 840, 952 |
| Pen panel | Black, Gray, White, Blue, Red | 200,856; 312,856; 424,856; 200,968; 312,968 |

Keep strokes at x > 600 while the pen panel is open, x > 150 otherwise. First visits show tooltips; close them (the X in the tooltip) before drawing. Check the colour in the pen panel before drawing: fresh notebooks started on black Pencil in our runs, but one early run drew highlighter yellow.

## 6. When something's off

- `ppemu status` says not connected: `ppemu logs | tail -50`. A crashed xochitl restarts on its own (systemd, `Restart=on-failure`), then reloads for ~60 s under qemu. Container stopped by itself? It rebooted (`systemctl reboot`, or `rm-emergency` after xochitl failures): `ppemu start`.
- UI server down but the container runs: `ppemu start` restarts only the server.
- Missing hardware or a new crash: `ppemu restart --debug`, then `ppemu logs` shows every hardware path and ioctl; `FAIL` lines are what's missing. Read `emu/README.md` and `emu/CLAUDE.md` before changing `emu/shim/`, `emu/daemon/` or `emu/docker/`, then `ppemu rebuild` (keeps device data).
- Never copy files out of the firmware or the container into the repo. Firmware lives in `emu/firmware/` (gitignored) and nowhere else.

## Not emulated

E-ink refresh (no flash, no ghosting, instant final image), real pen latency, battery behaviour, real suspend, the Wi-Fi radio, Bluetooth, OTA, NFC, A/B slot switching. Sync runs (rm-sync) but needs a server you point it at. Screenshots are xochitl's RGB render; the real panel is grayscale. Don't report UI behaviour in those areas as real-device behaviour.
