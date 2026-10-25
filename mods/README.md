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

That is the hand path, for bring-up. Once `pp-agent` is installed, mods come as signed releases, and a triple-press (or `pp-agent toggle`) turns them off and on through the agent.

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
  - `xovi-tatsu.tar.gz`: `/home/root/xovi` laid out like upstream's release tarball (from rm-xovi-extensions' release workflow), plus `extensions.d/appload.so`, `exthome/appload/paper-pure-hello/`, our glue in `paper-pure/`, and `BUILDINFO` (pins plus sha256 of every `.so`). The tarball is packed deterministically (sorted, uid 0, mtime 0).
    - One deliberate difference from upstream: the two links in `services/xochitl.service/` are relative (`../../extensions.d`, `../../exthome`), not absolute. They point at the same place, but `ppsign` and `pp-agent` refuse links that leave the release tree. The agent end-to-end test caught this.
  - `release/`: the same tree plus `hooks/` and `checks/`, ready for `agent/out/ppsign pack` (see below).

## The hashtab

qt-resource-rebuilder can only apply AppLoad's hashed QML diff if it has a **hashtab** made from the exact xochitl binary. Upstream builds it on the device with `xovi/rebuild_hashtable`, an interactive script. It runs xochitl once with `QMLDIFF_HASHTAB_CREATE=<file>` and only qt-resource-rebuilder loaded, waits for `[qmldiff]: Hashtab saved to`, then stops xochitl.

`device/hashtab` (on the device: `xovi/paper-pure/hashtab`) does the same without prompts:

- **Cache.** The result goes in `/home/root/.cache/pp-hashtab/<key>/`. The key is the sha256 of `/usr/bin/xochitl` plus that of `qt-resource-rebuilder.so`. A later install or release with the same pair reuses it.
- **Stays stock while it runs.** It always brings stock xochitl back at the end, even when it fails.
- **Same steps in the emulator.** The emulator runs the same xochitl build. The file is not byte-reproducible, though: three emulator runs gave the same size (646221 bytes, 19609 entries) but three different sha256s, probably from hash-map ordering. So compare sizes and entry counts with the tablet's, not hashes.

The hashtab is derived from reMarkable's QML (it maps hashes to their identifier strings), so it is never committed and never shipped. Each device builds its own.

## Install procedure (`install.sh`)

The same steps for the emulator and the tablet, all over SSH. The tablet needs no curl or python; bash, tar and sha256sum are enough.

1. Copy the tarball to `/tmp` and check its sha256 on the device.
2. If xovi is running, `xovi/stock` first.
3. Unpack to `/home/root/xovi.new` and swap it in. The previous tree stays as `/home/root/xovi.prev`.
4. `xovi/paper-pure/hashtab`: from the cache, or built once.
5. `xovi/start`, then wait until xochitl really has `xovi.so` mapped, and print `status`.

`xovi/start` is upstream's own script. It bind-mounts a tmpfs on `/etc/systemd/system/xochitl.service.d`, writes `LD_PRELOAD=/home/root/xovi/xovi.so` and `XOVI_ROOT` there, and restarts xochitl. It is **tethered**: the tmpfs is gone after a reboot, so a reboot is stock.

**Same steps in the emulator.** It runs the image's own systemd, so `xovi/start`'s tmpfs drop-in reaches xochitl as on the tablet, and `ppemu reboot` (or `ppemu stop`/`start`) drops it like a reboot does. No emulator special case.

## With the update agent (`release/`)

`agent/` swaps releases atomically and runs `hooks/activate.sh`, `hooks/deactivate.sh` and `checks/*` (contract in `agent/README.md`). `mods/out/release/` is such a tree:

- **`hooks/activate.sh`**
  - Points `/home/root/xovi` at this release's `xovi/` (one `rename`). Upstream's scripts hard-code that path.
  - Gets the hashtab from the cache, or builds it with a 100 s cap.
  - `systemctl reset-failed xochitl.service`, then `xovi/start`. The hashtab build stops and starts xochitl; the reset keeps those starts from counting toward the stock start limit, so only crashes do.
  - A hand install it finds there is kept as `xovi.manual-<time>`.
- **`hooks/deactivate.sh`**: `reset-failed`, `xovi/stock`, then makes sure: unmount the drop-in, `daemon-reload`, and restart xochitl only if it is down or still has xovi preloaded (`/proc/<MainPID>/environ`). It is idempotent.
- **`checks/20-xovi.sh`**: xochitl has `xovi.so`, `qt-resource-rebuilder.so` and `appload.so` mapped, and the hashtab matches.
- **`checks/30-appload.sh`**: in this xochitl's own journal (`_PID`), qmldiff logged `Loaded external AppLoad hooks in main UI`, AppLoad logged `Loaded app root`, and qmldiff logged no `Error`, `Failed`, `Warning` or missing hash. A QML patch that no longer applies still leaves `appload.so` mapped; this catches it.

**Rung 3, the checks on the tablet.** The desiderata want "boots, opens a notebook, pen draws, sync completes, AppLoad launches" kept green on the tablet. What runs there:

| Check | How |
| --- | --- |
| AppLoad launches | `20-xovi.sh` and `30-appload.sh` at every install, turn-on and boot, and again every update run (30 min awake) while mods are live; the result is in every status report (`checks`) and on ppd's `/pp/problems` |
| Sync completes | pp-proxy's `sync.json` (last good `/sync/` request, errors) in every status report (`sync`); `/pp/problems` flags a last error newer than the last good sync. Not a release check: sync is not a mod, and a release must not roll back because Wi-Fi was off |
| Boots | Every boot ends with a status report; the boot-loop guard and rm-sanity wait in the agent and device lanes |
| Opens a notebook, pen draws | **Hardware only.** The tablet has no way to inject pen input without a mod of its own. Off the tablet: `test/e2e` draws in a notebook and finds the strokes on the server (step `sync`, before any release), and the manual-install pass below drew with mods on |

Pack with `-expect-mapped xovi.so -expect-mapped appload.so`. Bake the release id into the apps with `RELEASE_ID=<id> mods/build.sh`.

## Kill switch: triple-press, reboot, rollback

The desiderata: "Triple-press power disables all mods. Reboot returns stock UI." Both hold in the emulator (`test/e2e`) and the device test bed; a triple-press on real hardware, across real sleep and wake, is not checked yet. All of it lives in `pp-agent` (`agent/README.md`, "Three ways back to stock"):

- **Triple-press power toggles mods.** `pp-agent-tripletap.service` reads the power key and runs `pp-agent toggle`: mods on means `deactivate.sh` (stock UI); mods off means `activate.sh` plus the health check of the committed release. One path turns mods on, so a broken release can't come back unchecked. Off sticks: no install or boot turns mods on again until the next triple-press. Mods started by hand (`mods/install.sh`) with no release installed are turned off with xovi's own `stock` script.
- **Reboot is stock.** `xovi/start`'s drop-in is on a tmpfs, and `pp-agent boot` does not activate (`activate_on_boot: false`). Mods come back by a triple-press or the next install. To keep mods across reboots instead: `"activate_on_boot": true` in `agent.json`.
- **Auto-rollback** at install, or at the next boot if the check was cut short.
- **File switch:** `touch /home/root/paper-pure/disable`. Nothing turns mods on; a triple-press only turns them off.

### Why not xovi-tripletap

We read xovi-tripletap v1.1.1 (`46c6a95`, rmitchellscott/xovi-tripletap) and kept its idea, not its code:

- **How it works.** `main.sh` pipes `evtest /dev/input/event0` through `grep "code 116.*value 1"` and counts presses with `date +%s`: three, each within 2 s of the last (whole seconds, so really 2 to 3 s). Default mode (`TRIGGER_ACTION="start"`) only ever turns xovi **on**; `toggle` decides on/off from `systemctl show xochitl.service --property=Environment`.
- **Suspend.** It does nothing special: the first press puts the tablet to sleep, the second wakes it, the third sends it to sleep again, and the action restarts xochitl. It relies on the kernel reporting the press that wakes the tablet, after resume.
- **What we do the same:** the same key (`KEY_POWER`, code 116, value 1), three presses, nothing special for suspend.
- **What we do differently:**
  - `pp-agent tripletap` reads `struct input_event` itself, finds the key by name (`44440000.bbnsm:pwrkey`) or capability rather than assuming `event0`, and uses the kernel's event times (3 s gaps). Presses queued while a toggle runs are dropped; upstream counts them late and can fire again.
  - Toggling on goes through `activate.sh` and the health check; upstream runs `xovi/start` with no check.
  - The unit is persisted by the device lane like the other agent units. Upstream's `enable.sh` remounts `/` and does `umount -R /etc`, which breaks SSH until reboot. Not used.
  - It runs after `rm-sanity` (see below), and it can't turn mods on while `paper-pure/disable` exists.

### If a mod crashes xochitl

Read from the 3.27.2.2 rootfs, then run under real systemd 255 in the device lane's test bed:

- systemd restarts xochitl (`Restart=on-failure`, `RestartMode=direct`, `WatchdogSec=60`) with the same drop-in.
- After 4 starts in 600 s (`StartLimitBurst=4`), `xochitl-service-override.conf`'s `OnFailure=emergency.target` fires. On tatsu that requires `rm-emergency.service`: `rm-emergency.sh` **reboots**, and right after an OS update (`swu_applied=1`) it also switches root partition. It never stays failed.
- The reboot clears the tmpfs drop-in, so the tablet comes back stock.
- Safe because: our restarts don't count (reset-failed), the health check rolls back slower crash loops before the limit, faster ones reboot and `pp-agent boot` rolls back, `swu_applied` is 0 (no OS updates; `rm-sanity` zeroes it), and nothing of ours turns mods on before `rm-sanity` clears the bootloader's error count. Details in `agent/README.md`, "Why a crash loop can't brick it".

## Files

| Path | What |
| --- | --- |
| `versions.lock` | Pinned upstream commits |
| `build.sh`, `build/Dockerfile`, `build/check-abi.sh` | Build, and the ABI proof against the stock rootfs |
| `install.sh` | SSH installer for the emulator or the tablet |
| `emu-smoke.sh` | Rung 2 smoke test: side menu, AppLoad, Hello, check it logged and drew (27 s under qemu) |
| `device/hashtab`, `device/status` | Our glue, shipped as `/home/root/xovi/paper-pure/` |
| `release/hooks/*`, `release/checks/*` | pp-agent hooks |
| `host/` | Rung 1: AppLoad's PC emulator, headless (Qt offscreen), with a screenshot extension (`shot.cpp`), a Pure-sized `start.qml`, and `pngdiff.py` |

## Status

Run on Oct 25 2026: x86_64 dev container, 4 vCPU, arm64 through qemu-user, emulator `pp-emu-tablet` on 3.27.2.2.

### Verified

**Build**

- `PP_BUILD_CA=/root/.ccr/ca-bundle.crt mods/build.sh` works from an empty cache. It took 28 min the first time (23 min of it Ubuntu's Qt apt layer under qemu), 8 min after a Dockerfile change, and 21 s fully cached.
- `build.sh` checks every pin with `git rev-parse` and that the qmldiff pin matches the rm-xovi-extensions submodule.
- `build/check-abi.sh` against `pp-emu-rootfs:3.27.2.2` prints `ok`:
  - `appload.so` needs at most GLIBC_2.34, GLIBCXX_3.4.32 and Qt_6.8.
  - `qt-resource-rebuilder.so` needs at most GLIBC_2.39.
  - `xovi.so` needs at most GLIBC_2.34.
  - Negative check: dropping an x86 Qt library into the tarball gives `FAIL ... needs GLIBC_2.2.5`, exit 1.
- Two builds produced the same sha256 for all three `.so` files, but the second reused cached compile layers. A from-scratch rebuild was not compared.

**Rung 1**

- `apps/hello/test.sh` passes, `0 of 2628288 pixels differ`. See `apps/hello/README.md`.

**Rung 2, manual install**

- **Clean slate, twice** (the second time with the final artifact, `mods/emu-smoke.sh --install`, all green). `ppemu reset` and `ppemu start`, then: `/home/root/xovi`, `/etc/systemd/system/xochitl.service.d` and `/home/root/.cache/pp-hashtab` don't exist, and xochitl maps no xovi. Then `ppemu skip-setup`.
- **Install.** `mods/install.sh emu` takes 92 to 96 s. That includes `hashtab: saved ... (646221 bytes ...)` in 72 to 74 s. `status` then says `xovi ON`, mapped `appload.so`, `qt-resource-rebuilder.so`, `xovi.so`, `hashtab: ok`.
- **Logs.** `[qmldiff]: Hashtab loaded! Cached 19609 entries` and `Loaded external AppLoad hooks in main UI`. qmldiff processes `MainView.qml`, `Navigator.qml`, `Sidebar.qml` and `GesturesWindow.qml` with no errors.
- **The app.** The side menu shows **AppLoad**, AppLoad lists **Hello**, and the app shows `hello from paper-pure / release ... / OS 3.27.2.2`. Close works, Back returns to My files. `mods/emu-smoke.sh` does all of this in 27 s.
- **Writing is untouched with mods on.** In an open notebook, `ppemu draw 600,700 800,600 1000,750 1200,600` turned all 4 points from (255,255,255) to (0,0,0).
- **Stock.** `xovi/stock` gives `status` `stock (no xovi)`, and the side menu has no AppLoad entry.
- **Proof screenshots** (scratch, not in the repo):
  - `.../work-pp-mods/emu-2-sidebar.png`, `emu-3-appload.png`, `emu-4-hello.png`, `emu-9-stock-sidebar.png`
  - `smoke-clean/`, `smoke-final/` (final artifact) and `smoke-agent/` (agent-installed `e2e-1`)

The emulator was left running the final artifact through the manual install (xovi ON, AppLoad in the side menu). `ppemu restart` brings stock back, and `ppemu reset` wipes everything back to a factory-fresh stock device.

**Superseded (first phase, Oct 25 morning): rung 2 through the update agent, and the xovi-tripletap rig below.** The emulator then had a fake `systemctl` with no `show`, `activate_on_boot` defaulted to true, and `device/emu-start` existed. All three are gone. `test/e2e` now does install, rollback, triple-press and reboot on the emulator's real systemd (steps `ota`, `killswitch`, `reboot`); see `test/e2e/README.md`. Kept for the record:

`agent/out/ppsign` and `pp-agent-arm64`, throwaway keys in scratch, feed served on 172.17.0.1:3091.

- **Install.** Release `e2e-1` (`mods/out/release`, `-expect-mapped xovi.so -expect-mapped appload.so`): `pp-agent update` verified it, unpacked it and flipped `current`. `activate.sh` took 3.2 s (hashtab from cache). The 20 s stability check and `checks/20-xovi.sh` passed: `result: installed e2e-1`. Hello then showed `release e2e-1`.
- **Rollback.** Release `e2e-2-broken` (no `appload.so`) gave `rolling back e2e-2-broken -> e2e-1: xochitl (pid 3965) has not loaded "appload.so"`. It ran `deactivate`, flipped back, ran `activate` and the checks on e2e-1: `rolled back`, 59 s in total.
- **Boot.** `ppemu stop`/`start` came up stock. `pp-agent boot` then re-activated e2e-1: `boot: e2e-1 healthy`, 29 s.
- **Test-only shims.** The emulator's `systemctl` has no `show`, so the agent pointed at a test-only shim (`systemctl` config field). Its config also had `require_wifi: false` and `battery_floor: 0`, because Go binaries don't see the emulator's LD_PRELOAD fake sysfs.

**Kill switch, in the emulator**

The rig: xovi-tripletap v1.1.1 `main.sh` unmodified, run by hand (no systemd), with `/usr/bin/evtest` from the rootfs on `/dev/input/event0`. Three `power` presses 0.6 s apart through `POST /api/gesture`.

- `evtest` on event0 sees `KEY_POWER` value 1 then 0 from `ppemu power`.
- **`TRIGGER_ACTION="toggle"`**:
  - Stock plus a triple-press gives `xovi is not running - starting it`, then `xovi ON`. The UI came back awake on My files.
  - A second triple-press gives `xovi is currently running - disabling it`, then `stock (no xovi)`.
- **`TRIGGER_ACTION="start"` (upstream default)**: two triple-presses gave `xovi ON` both times (xochitl restarted, new PID). The default never turns mods off.
- **Emulator glue for the rig.** `POST_START_COMMANDS=(emu-start)`, plus a test-only `systemctl show` shim that reads the live xochitl's environment.
- **Reboot.** `ppemu stop` then `ppemu start` gave `stock (no xovi)`, with the drop-in files still on disk (see emulator gaps).

**Hooks under real systemd, through pp-agent** (Oct 25, second pass; `device/test/run.sh` scenario 9, see `device/README.md`)

`release/hooks/activate.sh` and `deactivate.sh` as shipped, with upstream's `xovi/start` and `xovi/stock` at the pinned commit, in the device lane's test bed (the 3.27.2.2 root fs running its own systemd 255; stand-in xochitl, stub hashtab, no `xovi.so`):

- `xovi/start`'s tmpfs drop-in on `/etc/systemd/system/xochitl.service.d` works on top of the `/etc` overlay, and its `Environment=` lines reach xochitl's `/proc/<MainPID>/environ`.
- Triple-press off and on through `pp-agent toggle`; reboot is stock; install-time crash loops roll back (slow: before the start limit, no reboot; instant: the OS reboots and `pp-agent boot` rolls back); a boot-time crash loop ends that boot stock.
- `deactivate.sh` brings stock back with one xochitl restart (by `xovi/stock`); its own restart only runs if xochitl is down or still has xovi preloaded.

**Hooks run by hand**

- `activate.sh` gave rc 0 and `checks/20-xovi.sh` passed.
- `deactivate.sh` gave rc 0, then the check failed `missing 'xovi ON'` (rc 1). A second `deactivate.sh` also gave rc 0.

`shellcheck` is clean on every script in `mods/` and `apps/hello/`.

### Not verified

- **Anything on the real tablet**, in particular:
  - `xovi/start`'s tmpfs mount and systemd picking up the drop-in.
  - Triple-press on hardware: that the press which wakes the tablet reaches userspace, and the key's input name (see `agent/README.md`).
  - The hashtab build time on the real CPU.
- **xovi-tripletap's `enable.sh`.** Not used (see "Why not xovi-tripletap").
- **This pass's hooks in the emulator.** The `reset-failed` lines and the conditional restart in `deactivate.sh` ran in the device test bed only, not in the (now systemd) emulator with real xovi and AppLoad. `mods/emu-smoke.sh --install` there is the next check.
- **The real xovi.so under systemd.** The device lane's test bed runs the real hooks and upstream's `xovi/start`/`xovi/stock` under systemd 255, but with a stand-in xochitl and no `xovi.so`.
- **AppLoad's `qtfb` shims and external apps.** Not built.
- **A from-scratch reproducibility comparison** of the `.so` files.

### Re-run on the systemd emulator (pp-emu-fidelity lane), Oct 25 2026

- `ppemu reset`, `start`, `skip-setup`, then `mods/install.sh emu` with no emulator special case: `xovi ON`, all three `.so` mapped, 107 s. The drop-in is a real tmpfs mount and `systemctl show -P Environment xochitl` shows `LD_PRELOAD`. `ppemu stop`/`start` → `stock (no xovi)`, drop-in dir gone.
- `mods/emu-smoke.sh`: ok (83 to 95 s).
- Through pp-agent with default config: `e2e-1` installed, `e2e-2-broken` rolled back by the agent's own check. Details in `emu/README.md` Status.
- Not re-run: rung 1, the build from an empty cache.

### Emulator gaps found (all fixed since in `emu/`: it now runs the image's own systemd; `device/emu-start` is gone)

- **No systemd drop-ins.** `xovi/start` writes `Environment=` into `/etc/systemd/system/xochitl.service.d/` and restarts xochitl. The emulator's supervisor ignores that, and the container can't `mount` (tmpfs), so the files also survive a container restart. Workaround here: `device/emu-start`.
  - A small patch would remove the workaround. It is in this lane's scratch, `work-pp-mods/emu-proposal/`: a `run-unit` wrapper in the entrypoint, `mount`/`umount` wrappers with tmpfs semantics for those dirs, wiping them at boot, and `systemctl show`.
- **`systemctl stop` returns 1 when xochitl isn't running.** Real systemd returns 0. This broke `emu-start` once (fixed with `|| true`).
- **No `systemctl show`.** pp-agent and xovi-tripletap's toggle mode need it.
- **`ppemu logs` only returns the last 300 lines.** Scripts that need a time window should use `docker logs --since`.

### Open questions for Cedar

1. **Kill switch: decided per the spec.** Triple-press toggles through `pp-agent`, reboot is stock (`activate_on_boot: false`). Flip that one line in `agent.json` if mods should survive reboots.
2. **AppLoad on 3.27.2.2 is pinned to v0.5.3** (May 2026). Newer AppLoad features (multitouch fixes, rotation) need 3.28+ hooks. Fine to stay there while the OS is frozen?
3. **Moving off qemu: done for CI.** `proofs`, `rung2` and `release` run on GitHub's `ubuntu-24.04-arm` runners (a cold mods build there takes about 3 min). The dev container is still x86 under qemu (`docs/decisions.md`, "Emulator host").
