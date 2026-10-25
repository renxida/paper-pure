---
name: pure-emulator
description: Drive the reMarkable Paper Pure emulator in emu/ (stock tatsu OS 3.27.2.2 in Docker): boot it, screenshot, tap/draw/swipe, press power, SSH in, push files, read logs, reset, and debug the emulator itself. Use whenever a task involves running, testing, screenshotting or interacting with the tablet, xochitl, or anything meant to run on the Paper Pure before it goes to the real device.
---

# Paper Pure emulator

`emu/bin/ppemu` drives a container (`pp-emu-tablet`) running the real Paper Pure root filesystem with a hardware shim. It is rung 2 of the dev loop: nothing goes to Cedar's tablet that hasn't worked here. Read `emu/README.md` for what it can't tell you (e-ink timing, pen feel, battery, sleep).

Run commands from the repo root. Cedar may be watching the same device at http://127.0.0.1:7777, so act deliberately.

## 1. Get to a known state

```bash
emu/bin/ppemu status        # container, UI server, images, host speed
emu/bin/ppemu start         # boot (first run fetches + verifies firmware and builds the image)
emu/bin/ppemu skip-setup    # fresh device: skip onboarding, land on My files
emu/bin/ppemu reset         # factory reset: wipes pp-emu-home/pp-emu-data (all notebooks). Ask first if someone else uses it
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
```

Don't use the in-OS Settings → Restart / Turn off; use `ppemu restart`.

## 4. Develop and deploy

The emulator behaves like a tablet in developer mode:

```bash
emu/bin/ppemu ssh 'cmd'                  # like ssh root@10.11.99.1; interactive with no cmd
emu/bin/ppemu push ./thing /home/root/thing
emu/bin/ppemu pull /home/root/.local/share/remarkable/xochitl ./out
emu/bin/ppemu restart                    # = systemctl restart xochitl (also works inside ssh)
emu/bin/ppemu logs [-f]                  # xochitl + shim + rmemud
```

- Scripts written for the real tablet: `ssh -i emu/.ppemu/id_ed25519 -p 2222 root@127.0.0.1` (swap for `root@10.11.99.1` on hardware).
- Only `/home` and `/data` persist (Docker volumes). Everything else is the read-only-in-spirit rootfs and resets when the container is recreated, like an OTA on the device.
- Notebooks: `/home/root/.local/share/remarkable/xochitl/`. Settings: `/home/root/.config/remarkable/xochitl.conf`, `/data/xochitl.conf`.
- `systemctl` only knows `xochitl`, `marker-manager`, `rmemud`. There is no systemd, no network, no cloud.
- The device shell is bash plus busybox: `head -n 3` (not `head -3`), no `od -A`, no python, no curl. Pull files out and inspect them on the host.
- Input devices for apps reading evdev directly: event0 power key, event1 pen (ABS_X 0..14040, ABS_Y 0..18720, pressure 0..4095), event2 touch (MT, 0..1403 x 0..1871), event3 hall sensor. These names and ranges are emulator guesses, not read off a Pure.

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

Keep strokes at x > 600 while the pen panel is open, x > 150 otherwise. First visits show tooltips; close them (the X in the tooltip) before drawing. A fresh notebook's first pen may be highlighter yellow; pick Black in the pen panel.

## 6. When something's off

- `ppemu status` says not connected: `ppemu logs | tail -50`. A crashed xochitl restarts on its own in about a second (then reloads for ~60 s under qemu).
- UI server down but the container runs: `ppemu start` restarts only the server.
- Missing hardware or a new crash: `ppemu restart --debug`, then `ppemu logs` shows every hardware path and ioctl; `FAIL` lines are what's missing. Read `emu/README.md` and `emu/CLAUDE.md` before changing `emu/shim/`, `emu/daemon/` or `emu/docker/`, then `ppemu rebuild` (keeps device data).
- Never copy files out of the firmware or the container into the repo. Firmware lives in `emu/firmware/` (gitignored) and nowhere else.

## Not emulated

E-ink refresh (no flash, no ghosting, instant final image), real pen latency, battery behaviour, real suspend, Wi-Fi, Bluetooth, cloud sync, OTA, NFC. Screenshots are xochitl's RGB render; the real panel is grayscale. Don't report UI behaviour in those areas as real-device behaviour.
