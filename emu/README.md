# emu: Paper Pure emulator

Rung 2 of the dev loop. Boots the **stock Paper Pure OS (tatsu, 3.27.2.2, the version on Cedar's tablet)** in a Docker container and lets Claude drive it from a CLI: look, tap, write, SSH in, deploy, restart.

The device's own root filesystem runs unmodified in an arm64 container. A preload shim fakes the hardware xochitl talks to: the e-ink controller (SWTCON over a fake DRM device), pen, touch, buttons, battery, charger, temperature, secure key store. Native on arm64 (Apple Silicon, arm64 Linux); under qemu-user on x86_64, which works but is slow.

Forked from [rmemu](https://github.com/aetherino/rmemu) (Paper Pro emulator, MIT, upstream commit `3483a43`, license kept in [LICENSE.rmemu](LICENSE.rmemu)). We adapt it, we don't rewrite it.

> No reMarkable code lives here. `ppemu setup` downloads reMarkable's public update package into `emu/firmware/` (gitignored) for local use. Never commit or redistribute it, or anything unpacked from it.

## Run it

Needs Docker, Node 20+, `curl`, `openssl`, `ssh`/`ssh-keygen`. On x86_64 also qemu-user binfmt for arm64 (`docker run --privileged --rm tonistiigi/binfmt --install arm64`, or the `qemu-user-static` package).

```bash
emu/bin/ppemu start          # first run: fetch + verify firmware (~140 MB), build image, boot
emu/bin/ppemu skip-setup     # fresh device: skip onboarding, land on My files
emu/bin/ppemu screenshot /tmp/s.png --scale 0.5
emu/bin/ppemu tap 700 1716   # device pixels, portrait 1404x1872
emu/bin/ppemu draw 700,900 1250,900
emu/bin/ppemu ssh 'cat /etc/os-release'
emu/bin/ppemu logs | tail
emu/bin/ppemu reset          # factory reset (wipes the pp-emu-home / pp-emu-data volumes)
emu/bin/ppemu help           # everything else
```

Simulator UI for humans: http://127.0.0.1:7777 (pen, eraser, finger, power key, Marker). Agents: [the `pure-emulator` skill](../.claude/skills/pure-emulator/SKILL.md).

Names: container `pp-emu-tablet`, images `pp-emu-tatsu:<version>` (emulator) and `pp-emu-rootfs:<version>` (plain rootfs), volumes `pp-emu-home` and `pp-emu-data`. Ports on 127.0.0.1: 7777 UI + HTTP API, 8888 device hub, 2222 SSH.

On an arm64 host nothing changes: same commands, no qemu, and the CLI drops its long waits on its own (it checks `process.arch`).

How slow is x86_64? Measured here (4 vCPU, qemu 8.2): `start` on a factory-fresh device 117 s to the Welcome screen; `skip-setup` 66 s to My files; `rebuild` (set-up device) 131 s back to My files; a tap 5 s round trip; Settings 11 s; a pen stroke 5 s. The CLI waits longer on non-arm64 hosts (`PPEMU_SLOW=1|0` overrides).

## How it works

```
 host                                 container pp-emu-tablet (stock tatsu rootfs, linux/arm64)
┌──────────────────────┐   :8888    ┌───────────────────────────────────────────────┐
│ host/server.mjs      │◀──────────▶│ rmemud   input hub · display relay · uevents  │
│  · simulator UI (WS) │            │ xochitl ── rmemu-shim.so (via ld.so.preload)  │
│  · HTTP API          │   :2222    │   fake DRM for SWTCON · framebuffer capture   │
│ bin/ppemu (CLI)      │◀── ssh ───▶│   evdev · udev · sd_device · libiio · sysfs   │
└──────────────────────┘            │   PKCS#11 soft token · marker-manager · dbus  │
                                    └───────────────────────────────────────────────┘
```

xochitl renders the UI into a 1404x1872 RGB32 image that SWTCON turns into waveform frames for the panel. The shim grabs that image when it is created and streams changed tiles to the host; that is the screenshot. Input goes the other way as fake evdev events. Everything else xochitl asks the hardware for comes from `docker/root/sys/` or a stub in `shim/`.

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
| SWTCON scanout mode | 405x1084 | 260x1408 | xochitl logs `DRM error: size mismatch ... (expected 1408x260)` |
| Battery / charger sysfs | `max1726x_battery`, `max77963-charger` | `max77818_battery`, `max77818-charger` (marker-manager still reads `max77963-charger/online`, mirrored) | strings in `libcslpower.so`, `marker-manager` |
| Temperature hwmon | `rm_hwmon_temp` | `ertj0eg103fa` | `temperature_hwmon: found temperature path` in log |
| Device tree `display-info` | absent | 1404 / 1872 / 228 dpi (big-endian), same as libepaper's built-in fallback | disassembly of `EpaperIntegration::readDisplayInfo` |
| Front light, keyboard light, Folio keyboard | yes | none on the Pure, nothing to fake | `libcsllight.so` absent |
| x86 hosts | not supported | works under qemu-user, with shim fixes (below) | boots here |
| Firmware source | codexctl index | pinned table + reMarkable's bucket; codexctl only lists 3.27.1.0 for the Pure | `data/version-ids.json` |
| Names | `rmemu`, `bin/rmemu` | `pp-emu-*`, `bin/ppemu` (same commands, plus `rebuild`) | |

Three additions in `shim/hooks.c`, the first two for qemu-user:

- **Alarm clocks.** `clock_gettime(CLOCK_BOOTTIME_ALARM)` fails on hosts without a wake-capable RTC, so sd-event refuses alarm timers and marker-manager aborts (`Failed to add timer: Operation not supported`). The shim falls back to the plain clock, as upstream already did for `timerfd_create`.
- **Top realtime signals.** qemu-user can't map guest signals 62 to 64 onto host signals, so blocking them silently does nothing and `sd_event_add_signal` returns EBUSY; xochitl aborts (`Failed to add SIGNO_PRE_AUTOSLEEP handler`). The shim listens on a spare signal instead. Those signals come from the suspend-event driver, which doesn't exist here.
- **Busy main thread counts as activity.** Under qemu xochitl can compute for 10 to 60 s before it draws a new page (boot, Settings). The shim times how long xochitl's main thread has been out of `poll`/`ppoll` and the display scanner reports that as activity, so "wait until the screen settles" doesn't return halfway. Natively this just makes waits a little more honest.

Internal names (`/opt/rmemu`, `/run/rmemu`, `RMEMU_*`, `rmemud`) stay as upstream so their fixes still apply cleanly.

## Blind spots

What the emulator can't tell you. Test these on the tablet.

- **E-ink timing.** No waveforms reach a panel. The screenshot is the image xochitl renders, shown instantly; no flashing, ghosting, or partial-refresh artifacts. SWTCON runs against a fake DRM device paced at a guessed 85 Hz, so refresh durations mean nothing. Waveform selection also fails (`wf_search: unable to read epd serial`, no devconfig), which is harmless here and untested.
- **Pen latency and feel.** Pen events are synthetic evdev at 1/10 px with made-up Elan device names and ranges (copied from the Paper Pro, not read off a Pure). Under qemu-user everything is 10x to 50x slower. Desiderata #4 (writing feel) can only be judged on hardware.
- **Battery.** Fake sysfs numbers; `ppemu battery N` and `ppemu usb connect` change them. No discharge curve, no fuel-gauge behaviour.
- **Sleep.** The power key shows the sleep screen and wakes again, but nothing suspends: writes to `/sys/power/state` land in a fake file, alarm timers run on plain clocks, and xochitl logs `Missing resume event, triggering fallback wakeup`.
- **Colour.** xochitl renders an RGB32 image; the real panel is grayscale. Highlighter/colour ink shows in colour in screenshots. A second 1404x1872 Grayscale8 buffer exists but stays empty here.
- **Storage.** Settings shows the Docker host's disk (e.g. 228 GB of 252 GB), not a 32 GB tablet.
- **Not running at all:** Wi-Fi, Bluetooth, cloud sync, swupdate/update-engine (OTA), memfaultd, tee-supplicant (a software PKCS#11 token stands in for OP-TEE), real orientation sensor, NFC (marker-manager talks to fake sysfs).

## Change the emulator

- C in `shim/` (preload library, `shim/pkcs11/` soft token) and `daemon/rmemud.c` compiles inside the Docker build (Ubuntu 24.04 arm64; glibc 2.39 matches the rootfs). After editing: `emu/bin/ppemu rebuild` (keeps device data).
- Missing hardware: `ppemu restart --debug`, then `ppemu logs` shows every hardware path and ioctl; `FAIL` lines are what's missing. Fake sysfs goes in `docker/root/sys/...`.
- Host side (`host/`, `bin/ppemu`) is plain Node with no dependencies.

## Status

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

Not verified:

- arm64 hosts (Apple Silicon, arm64 Linux). Nothing x86-specific was added, and upstream runs natively there, but it was not run.
- That the fake input device names and ranges match a real Pure; that 228 dpi is the panel's real device-tree value.
- The simulator UI in a browser (the HTTP API behind it was used for every test above).

Open questions for Cedar:

- When you enable developer mode, can we read a few real values off the tablet (`cat /proc/device-tree/display-info/*`, `ls /sys/class/power_supply /sys/class/input/*/device/name`)? That would turn the guesses above into facts.
- The first stroke in a fresh notebook came out in highlighter yellow (tool Pencil, colour 9 "highlight") until Black was picked. Does a fresh notebook on your tablet do the same?
- Which machine runs the emulator day to day? x86 works but costs ~100 s per boot and seconds per tap; an arm64 box would make it interactive.
