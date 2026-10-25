# mods: xovi, AppLoad and friends

The mod stack for Cedar's Paper Pure, built from source and pinned to OS 3.27.2.2:

- **xovi**: an `LD_PRELOAD` loader that lets extensions hook functions in xochitl.
- **qt-resource-rebuilder**: a xovi extension that patches xochitl's QML as it loads.
- **AppLoad**: a xovi extension that adds an "AppLoad" entry to the side menu and runs QML apps (ours live in `apps/`).

We don't write any of these. We pin them, build them, install them, and prove them in the emulator. No reMarkable code is in here.

## Use it

```bash
mods/build.sh                  # pinned sources -> mods/out/xovi-tatsu.tar.gz and mods/out/release/
mods/install.sh emu            # install into the emulator (emu/), start xovi, check it
mods/install.sh root@10.11.99.1   # same on the tablet over USB (developer mode)
apps/hello/test.sh             # rung 1: hello in AppLoad's PC emulator, headless, screenshot vs golden
```

On the device afterwards:

```bash
/home/root/xovi/paper-pure/status   # what's live: build, xovi on/off, mapped extensions, hashtab
/home/root/xovi/stock               # back to stock now
/home/root/xovi/start               # mods on again (xovi-setup's own script)
```

Behind a TLS-intercepting proxy (like Claude's cloud containers) add `PP_BUILD_CA=/root/.ccr/ca-bundle.crt` to `mods/build.sh` so cargo can fetch crates.

## What's pinned, and why these versions

`versions.lock` holds the exact upstream commits; `build.sh` refuses anything else.

| Source | Pin | Why |
| --- | --- | --- |
| asivery/xovi | v0.3.3 `0c8d526` | Latest release. master only adds a licence change |
| asivery/rm-xovi-extensions | v19-23052026 `7874154` | qt-resource-rebuilder 0.3.0 (AppLoad needs it) and the `start`/`stock`/`rebuild_hashtable` scripts. Released 3 days after OS 3.27.2.2 |
| asivery/qmldiff | `25681c3` | The submodule commit v19 points at (`build.sh` checks they agree) |
| asivery/rm-appload | v0.5.3 `5bb34a3` | The last release whose QML hooks target 3.27. v0.6.0 and master hook the 3.28/3.29 side menu (`40506d4` "support for 3.28") |

This is the "hooks are pinned to OS versions" problem from the desiderata, seen up close: AppLoad's `appload.qmd` names xochitl QML files and items by hash, and they move between OS releases. Moving the OS means re-picking these pins in the emulator first.

## How it's built

`build/Dockerfile`, driven by `build.sh`:

- **Native arm64 container** (`ubuntu:25.04`, pinned by digest). Under qemu on x86, the first build takes about 30 minutes, mostly apt; later builds reuse the cache and take a few minutes. On an arm64 runner it runs natively.
- **Why Ubuntu 25.04.** The tablet ships Qt 6.8.2. AppLoad needs Qt 6.7 or newer headers (`QQuickItem::setFocusPolicy`), so Ubuntu 24.04's Qt 6.4 can't build it. 25.04 has Qt 6.8.3, the same minor version, and Qt keeps patch releases binary compatible both ways. Debian trixie has exactly 6.8.2, but deb.debian.org is blocked from our build hosts.
- **GCC 13**, the same as the tablet's libstdc++. `build/check-abi.sh` then proves, against the stock rootfs in the emulator's image, that every library our `.so` files need exists and every versioned symbol they use (`GLIBC_2.x`, `GLIBCXX_3.4.x`, `Qt_6.x`) is defined there.
- **qmldiff (Rust)** is a static library, so it is cross-compiled in a `rust:1.89` stage on the build host. That needs no aarch64 linker and no cargo under qemu.
- **Upstream build files are used as-is**, with environment variables standing in for the Yocto SDK they expect. One exception: qt-resource-rebuilder is built with `-U_FORTIFY_SOURCE`, because `src/main.c` calls `open(..., O_RDWR | O_CREAT)` without a mode and Ubuntu's default fortify rejects that. This is an upstream bug.
- **Output** (`mods/out/`, gitignored):
  - `xovi-tatsu.tar.gz`: `/home/root/xovi` laid out exactly like upstream's release tarball (from rm-xovi-extensions' release workflow), plus `extensions.d/appload.so`, `exthome/appload/paper-pure-hello/`, our glue in `paper-pure/`, and `BUILDINFO` (pins plus sha256 of every `.so`). Reproducible: sorted, uid 0, mtime 0.
  - `release/`: the same tree plus `hooks/` and `checks/`, ready for `agent/out/ppsign pack` (see below).

## The hashtab

qt-resource-rebuilder can only apply AppLoad's hashed QML diff if it has a **hashtab** made from the exact xochitl binary. Upstream builds it on the device with `xovi/rebuild_hashtable`, an interactive script. It runs xochitl once with `QMLDIFF_HASHTAB_CREATE=<file>` and only qt-resource-rebuilder loaded, waits for `[qmldiff]: Hashtab saved to`, then stops xochitl.

`device/hashtab` (on the device: `xovi/paper-pure/hashtab`) does the same without prompts:

- **Cache.** The result goes in `/home/root/.cache/pp-hashtab/<key>/`. The key is the sha256 of `/usr/bin/xochitl` plus that of `qt-resource-rebuilder.so`. A later install or release with the same pair reuses it.
- **Stays stock while it runs.** It always brings stock xochitl back at the end, even when it fails.
- **Same in the emulator.** The emulator runs the same xochitl build, so the hashtab it produces should be byte-identical to the tablet's. Compare the sha256 that `hashtab` prints on both to check.

The hashtab is derived from reMarkable's QML (it maps hashes to their identifier strings), so it is never committed and never shipped. Each device builds its own.

## Install procedure (`install.sh`)

The same steps for the emulator and the tablet, all over SSH. The tablet needs no curl or python; bash, tar and sha256sum are enough.

1. Copy the tarball to `/tmp` and check its sha256 on the device.
2. If xovi is running, `xovi/stock` first.
3. Unpack to `/home/root/xovi.new` and swap it in. The previous tree stays as `/home/root/xovi.prev`.
4. `xovi/paper-pure/hashtab`: from the cache, or built once.
5. `xovi/start`, then wait until xochitl really has `xovi.so` mapped, and print `status`.

`xovi/start` is upstream's own script. It bind-mounts a tmpfs on `/etc/systemd/system/xochitl.service.d`, writes `LD_PRELOAD=/home/root/xovi/xovi.so` and `XOVI_ROOT` there, and restarts xochitl. It is **tethered**: the tmpfs is gone after a reboot, so a reboot is stock.

**The emulator has no systemd.** Its `systemctl` is a stub and a shell loop runs xochitl, so the drop-in never reaches xochitl. On the emulator, `install.sh` also runs `xovi/paper-pure/emu-start`. That script reads the drop-in's `Environment=` lines, parks the supervised xochitl, and starts one with that environment, logging to the container's stdout so `ppemu logs` shows it. `ppemu restart` brings stock back, much like a reboot does on the tablet. An `emu/` change that would remove this special case is proposed in the Status section.

## With the update agent (`release/`)

`agent/` swaps releases atomically and runs `hooks/activate.sh`, `hooks/deactivate.sh` and `checks/*` (contract in `agent/README.md`). `mods/out/release/` is such a tree:

- **`hooks/activate.sh`**
  - Points `/home/root/xovi` at this release's `xovi/` (one `rename`). Upstream's scripts and xovi-tripletap hard-code that path.
  - Gets the hashtab from the cache, or builds it with a 100 s cap.
  - Runs `xovi/start`.
  - A hand install it finds there is kept as `xovi.manual-<time>`.
- **`hooks/deactivate.sh`**: runs `xovi/stock`, then makes sure: unmount the drop-in, `daemon-reload`, `reset-failed`, `restart`. It is idempotent.
- **`checks/20-xovi.sh`**: xochitl has `xovi.so`, `qt-resource-rebuilder.so` and `appload.so` mapped, and the hashtab matches.

Pack with `-expect-mapped xovi.so -expect-mapped appload.so`. Bake the release id into the apps with `RELEASE_ID=<id> mods/build.sh`.

## Kill switch: what triple-press and reboot really do

Checked against the source of xovi v0.3.3, xovi-setup v19, and xovi-tripletap v1.1.1 (`46c6a95`), plus what could be run in the emulator (see Status).

- **xovi has no kill switch of its own.** It loads whatever is in `extensions.d` into any process started with `LD_PRELOAD=xovi.so`.
- **Reboot.** `xovi/start` puts the drop-in on a tmpfs, so after a reboot xochitl starts stock. That is upstream's "tethered" design, and upstream warns hard against making xovi start at boot.
  - **But with our agent installed, a reboot is not stock.** `pp-agent boot` runs `activate.sh` on every boot (`activate_on_boot: true` by default), so mods come back.
  - The agent's boot-loop guard catches mods that break the UI: a failed check means that boot stays stock, and after 3 unhealthy boots it stays stock for good.
  - It does not catch mods that are merely unwanted. For "reboot = stock" to keep holding, set `activate_on_boot: false`; mods then come on only through an install or a triple-press. Cedar decides.
- **Triple-press is not xovi. It is xovi-tripletap**, a separate service, not installed by us yet.
  - **Default mode.** `main.sh` watches `/dev/input/event0` with `evtest` for three `KEY_POWER` presses, each within 2 s of the last. Then it runs `/home/root/xovi/start`. In this default mode (`TRIGGER_ACTION="start"`), **triple-press turns mods ON (or restarts them), never off.**
  - **Toggle mode.** Only with `TRIGGER_ACTION="toggle"` in `/home/root/xovi-tripletap/config` does it run `xovi/stock` when xovi is on. It decides that by checking `systemctl show xochitl.service --property=Environment` for `LD_PRELOAD=/home/root/xovi/xovi.so`. remagic's README says "toggle on or off", but it installs upstream's defaults.
  - **For the desiderata's kill switch** ("triple-press disables all mods") we need toggle mode.
  - **Each press also reaches xochitl.** Three presses mean sleep, wake, sleep, and then xochitl restarts.
- **Installing tripletap on a Pure** (`enable.sh`):
  - It does `mount -o remount,rw /` and `umount -R /etc` (it detects "Tatsu"), copies its unit into the real `/etc/systemd/system`, and enables it.
  - remagic documents that this `umount -R /etc` also drops the bind mount holding dropbear's host key, so SSH dies until a reboot. remagic repairs it in `scripts/lib.sh` (`repair_ssh_keystore`).
  - An OS update wipes the unit.
  - The Pure's rootfs already ships `/usr/bin/evtest`, so tripletap's bundled `evtest` binary isn't needed.
- **If a mod crashes xochitl**: systemd restarts it (`Restart=on-failure`) with the same drop-in. After 4 failures in 600 s (`StartLimitBurst=4`), the stock override's `OnFailure=emergency.target` fires. A forced reboot (hold power) clears the tmpfs drop-in, so the tablet is stock again unless the agent re-activates. If it does, the boot guard applies.

## Files

| Path | What |
| --- | --- |
| `versions.lock` | Pinned upstream commits |
| `build.sh`, `build/Dockerfile`, `build/check-abi.sh` | Build, and the ABI proof against the stock rootfs |
| `install.sh` | SSH installer for the emulator or the tablet |
| `device/hashtab`, `device/status`, `device/emu-start` | Our glue, shipped as `/home/root/xovi/paper-pure/` |
| `release/hooks/*`, `release/checks/*` | pp-agent hooks |
| `host/` | Rung 1: AppLoad's PC emulator, headless (Qt offscreen), with a screenshot extension (`shot.cpp`), a Pure-sized `start.qml`, and `pngdiff.py` |

## Status

Filled in below with what was run on Oct 25 2026 (x86_64 host, 4 vCPU, qemu-user for arm64).
