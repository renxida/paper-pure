# remarkable-emulator

Emulator for the reMarkable Paper Pro (stock firmware in an arm64 container + hardware shim). See README.md for the architecture.

## Driving the device (agent harness)

Full guide: the `paperpro-emulator` skill (`.claude/skills/paperpro-emulator/SKILL.md`). Short version:

- `bin/rmemu start` boots everything (container + UI server on :7777); `bin/rmemu status` checks it. Use `bin/rmemu skip-setup` on a fresh device to land on My files.
- Look with `bin/rmemu screenshot /tmp/s.png --scale 0.5`, then read the PNG. Coordinates you pass back are **device pixels** (1620x2160 portrait): multiply screenshot coordinates by the printed factor.
- Input commands (`tap`, `longpress`, `swipe`, `draw`, `pinch`, `power`, `folio`, `marker`, `usb`, `battery`) block until the screen and the e-ink panel settle and print whether the screen changed. Some UIs react after a refresh finishes (seconds); if "no screen change", `bin/rmemu wait --idle 800` and look again before retrying.
- UI navigation: finger `tap` (default). Writing/drawing: `draw` (pen) or `--pen`/`--eraser` on tap/swipe.
- Device shell: `bin/rmemu ssh 'cmd'`; files: `push`/`pull`; app restart: `bin/rmemu restart`; logs: `bin/rmemu logs` (`restart --debug` adds shim tracing of every hardware access).

## Changing the emulator

- C code in `shim/` (LD_PRELOAD library + `shim/pkcs11/` soft token) and `daemon/rmemud.c` is compiled inside the Docker build (Ubuntu 24.04 arm64, glibc matches the rootfs). Rebuild + reboot: `docker build -q -t rmemu:3.27.1.0 -f docker/Dockerfile . && bin/rmemu stop && docker rm -f rmemu && bin/rmemu start`.
- Host side (`host/`, `bin/rmemu`) is dependency-free Node; restart the server with `pkill -f host/server.mjs; bin/rmemu start`.
- New hardware xochitl wants usually shows up as `FAIL` lines under `bin/rmemu restart --debug` + `bin/rmemu logs`; fake sysfs files go in `docker/root/sys/...` (device-tree values are big-endian binary).
- `firmware/` (downloaded) and `.rmemu/` (SSH key, server log) are gitignored.
