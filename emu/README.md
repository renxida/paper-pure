# rmemu: an unofficial reMarkable Paper Pro emulator

Runs the **stock reMarkable Paper Pro OS** on an Apple Silicon Mac so you can test software before putting it on a tablet in developer mode. Both are arm64, so the device's own root filesystem runs natively in Docker. A preload shim fakes the hardware: e-ink controller, pen, touch, buttons, sensors and the secure key store. You drive it from a browser simulator UI or from the `bin/rmemu` CLI, which works for scripts and AI agents.

![The simulator UI: a Paper Pro frame with the live screen, tool picker and hardware buttons](docs/screenshots/simulator.jpg)

| Pen + eraser | Settings |
|---|---|
| ![Notebook with a pen stroke and a partly erased line](docs/screenshots/drawing.png) | ![General settings showing version 3.27.1.0](docs/screenshots/settings.png) |

> **Disclaimer.** This is an independent, unofficial project. It is not affiliated with or endorsed by reMarkable AS. "reMarkable", "Paper Pro" and "Marker" are trademarks of reMarkable AS, used only to identify the hardware. This repo contains no reMarkable software. You download the firmware yourself (see below), and it stays subject to reMarkable's terms. Screenshots show their UI (© reMarkable AS). Cloud sync is intentionally not supported.

## Quick start

You need Docker Desktop and Node 20 or newer, on Apple Silicon (or any arm64 Linux machine).

```bash
bin/rmemu start        # first run fetches the firmware (~200 MB) and builds the image
bin/rmemu open         # simulator UI at http://127.0.0.1:7777
bin/rmemu skip-setup   # optional: skip first-boot onboarding
```

Device data persists in the `rmemu-home` and `rmemu-data` Docker volumes. `bin/rmemu reset` factory-resets the device.

## Getting the firmware

The emulator needs a Paper Pro firmware update package, a `.swu` file named like `remarkable-production-image-3.27.1.0-ferrari-public.swu`. Use the version your tablet runs (Settings → General → Software). There are two ways to get it:

**1. Let rmemu fetch it (easiest).**

```bash
bin/rmemu versions          # versions available for the Paper Pro
bin/rmemu setup 3.27.1.0    # download, verify the sha256, build rmemu:3.27.1.0
bin/rmemu start 3.27.1.0
```

It downloads reMarkable's own update package from the public mirrors listed in [codexctl](https://github.com/Jayy001/codexctl)'s version index into `firmware/`, and checks it against the index's sha256.

**2. Bring your own `.swu`.** Use this for a file from [codexctl](https://github.com/Jayy001/codexctl) (`codexctl download 3.27.1.0 --hardware rmpp -o firmware/`) or any other copy:

```bash
tools/import-rootfs.sh firmware/<file>      # prints rmpp-rootfs:<version>
docker build --build-arg ROOTFS=rmpp-rootfs:<version> -t rmemu:<version> -f docker/Dockerfile .
bin/rmemu start <version>
```

`import-rootfs.sh` unpacks the `.swu` (a cpio archive containing an ext4 image) with `debugfs` in a throwaway container. It needs no root access or privileged mode. Firmware files are gitignored. Don't commit or redistribute them.

## Simulator UI

- **Pen / Eraser / Finger** (P / E / F): drive the digitizer or the touchscreen. Pressure and tilt come through if you use a real stylus. Hold ⌥ in Finger mode to pinch.
- **Toolbar**: power, Folio cover, screenshot (⌘S), restart xochitl, and "paper tone" (an approximation of the e-ink look).
- **Marker** beside the device: click it to attach the Marker (docks and charges it) or detach it.
- **Status bar**: shows the cursor position in device pixels, ready to paste into `rmemu tap`.

## CLI

Coordinates are device pixels: portrait, 1620×2160, origin at top-left. Input commands wait until the screen and the e-ink panel settle, then report whether anything changed.

```bash
bin/rmemu screenshot shot.png --scale 0.5    # multiply by 2 for device coordinates
bin/rmemu tap 810 1916 [--pen|--eraser]
bin/rmemu longpress X Y · swipe X0 Y0 X1 Y1 · pinch CX CY R0 R1
bin/rmemu draw 300,700 500,600 700,800 --pressure 0.7
bin/rmemu power · folio close · marker dock · usb connect · battery 15
bin/rmemu wait --idle 500
bin/rmemu ssh 'cmd' · push LOCAL REMOTE · pull REMOTE LOCAL
bin/rmemu restart [--debug] · logs -f
```

Run `bin/rmemu help` for everything. An HTTP API (screenshot, gesture, wait, status, logs) sits behind the UI; see [host/server.mjs](host/server.mjs). Agents: see the [`paperpro-emulator` skill](.claude/skills/paperpro-emulator/SKILL.md).

## Developing for the tablet

The emulator behaves like a tablet in developer mode:

- `bin/rmemu ssh` gives the device's own root login, the equivalent of `ssh root@10.11.99.1`.
- `systemctl restart xochitl` works.
- Every process sees the same fake `/sys` and `/dev/input` nodes, so apps reading pen and touch events directly get live input.
- The binaries are byte-for-byte the shipped ones, so hooks and extensions built for a firmware version run against the same code.

## How it works

```
 Mac                                  container (stock Paper Pro rootfs, linux/arm64)
┌──────────────────────┐   :8888    ┌───────────────────────────────────────────────┐
│ host/server.mjs      │◀──────────▶│ rmemud   input hub · display relay · uevents  │
│  · simulator UI (WS) │            │ xochitl ── rmemu-shim.so (via ld.so.preload)  │
│  · HTTP API          │   :2222    │   fake DRM for SWTCON · framebuffer capture   │
│ bin/rmemu (CLI)      │◀── ssh ───▶│   evdev · udev · sd_device · libiio · sysfs   │
└──────────────────────┘            │   PKCS#11 soft token · marker-manager · dbus  │
                                    └───────────────────────────────────────────────┘
```

- **Display** ([shim/drm.c](shim/drm.c), [shim/fb.c](shim/fb.c)): xochitl drives the panel through SWTCON over atomic KMS. The shim provides that KMS device with the panel's real 405×1084 scanout mode, paces flips at 85 Hz, and streams the 1620×2160 image xochitl renders.
- **Input** ([shim/input.c](shim/input.c), [daemon/rmemud.c](daemon/rmemud.c)): fake evdev devices for the Elan pen and touchscreen, the power key and the hall sensors, fanned out to every reader. Fake udev and `sd_device` support lets Qt find the devices and carries charger and Marker-docking events.
- **The rest** ([shim/](shim/), [docker/root/](docker/root/)): a software PKCS#11 token in place of OP-TEE, the orientation sensor, a sysfs tree (battery, charger, temperature, display info, secure boot reported as unlocked), and faked realtime thread priority.

**Not emulated yet:**

- E-ink refresh visuals (no flash or ghosting)
- Wi-Fi and cloud sync
- Auto-rotation
- Type Folio keyboard and Bluetooth
- Intel Macs

## Reference

- **The device:** `ferrari` (Paper Pro Move is `chiappa`), an NXP i.MX 8M Mini (4× Cortex-A53) with an 11.8" 1620×2160 color e-ink display. It runs reMarkable OS (Yocto scarthgap) with xochitl on Qt 6.8.
- **Developer mode:** Settings → General → Paper Tablet → Software → Advanced → Developer Mode. Turning it on **factory resets** the tablet, so sync first. The root password is in Settings → General → Help → About → Copyrights and Licenses.
- **Links:** [developer mode](https://developer.remarkable.com/documentation/developer-mode) · [SDK](https://developer.remarkable.com/documentation/sdk) · [kernel](https://github.com/reMarkable/linux-imx-rm) · [codexctl](https://github.com/Jayy001/codexctl) (GPL-3.0; its version index is fetched at a pinned commit).

## License

MIT ([LICENSE](LICENSE)). It covers this repository's code only and grants no rights in reMarkable's software.
