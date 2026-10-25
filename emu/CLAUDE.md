# emu: Paper Pure emulator

Stock Paper Pure (tatsu) OS 3.27.2.2 in an arm64 container, booted by its own systemd, plus a hardware shim. Forked from rmemu (MIT, upstream commit 3483a43, see LICENSE.rmemu). README.md has the how and the why.

- Drive it with `bin/ppemu` (see `/.claude/skills/pure-emulator/SKILL.md` at the repo root). Coordinates are device pixels, portrait 1404x1872.
- C code in `shim/` and `daemon/` compiles inside the Docker build. After changing it, or `docker/`: `bin/ppemu rebuild` (keeps `/home` and `/data`, fresh root fs).
- `docker/boot.sh` is PID 1 for a second: tablet mounts, fake sysfs bind mounts, `/run` units and masks, then `exec` systemd. Emulator-only units go in `docker/units/` (copied to `/run/systemd/system`), never into the image's `/etc` or `/usr/lib`, so `/etc` stays stock.
- The shim must leave PID 1, `systemd-*` and rmemud alone (`rmemu_off` in `hooks.c`).
- Host side (`host/`, `bin/ppemu`) is dependency-free Node. Restart the UI server: `kill $(cat .ppemu/server.pid); bin/ppemu start`.
- Missing hardware shows up as `FAIL` lines under `bin/ppemu restart --debug` then `bin/ppemu logs`. Fake sysfs files go in `docker/root/sys/...` (device-tree values are big-endian binary; `docker/root/proc/device-tree` links to them). Take device-tree values from the image's own `/boot/freescale/tatsu-rev-*.dtb` (`fdtget`), don't guess.
- `firmware/` (downloaded .swu) and `.ppemu/` (SSH key, server log) are gitignored. Never commit firmware or anything unpacked from it.
