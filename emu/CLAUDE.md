# emu: Paper Pure emulator

Stock Paper Pure (tatsu) OS 3.27.2.2 in an arm64 container plus a hardware shim. Forked from rmemu (MIT, upstream commit 3483a43, see LICENSE.rmemu). README.md has the how and the why.

- Drive it with `bin/ppemu` (see `/.claude/skills/pure-emulator/SKILL.md` at the repo root). Coordinates are device pixels, portrait 1404x1872.
- C code in `shim/` and `daemon/` compiles inside the Docker build. After changing it, or `docker/`: `bin/ppemu rebuild` (keeps device data).
- Host side (`host/`, `bin/ppemu`) is dependency-free Node. Restart the UI server: `kill $(cat .ppemu/server.pid); bin/ppemu start`.
- Missing hardware shows up as `FAIL` lines under `bin/ppemu restart --debug` then `bin/ppemu logs`. Fake sysfs files go in `docker/root/sys/...` (device-tree values are big-endian binary; `docker/root/proc/device-tree` links to them). Take device-tree values from the image's own `/boot/freescale/tatsu-rev-*.dtb` (`fdtget`), don't guess.
- `firmware/` (downloaded .swu) and `.ppemu/` (SSH key, server log) are gitignored. Never commit firmware or anything unpacked from it.
