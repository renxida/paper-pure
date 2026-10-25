# agent

The tablet's update agent (`pp-agent`) and the release tool (`ppsign`). Covers desiderata rows 2 (never brick), 7 (ships over the air) and 11 (observable).

Both are static Go binaries, stdlib only. The tablet needs nothing installed: no curl, no python.

## How it works

The tablet pulls; nothing pushes into it. A systemd timer runs `pp-agent update` every 30 minutes while the tablet is awake:

1. **Gates.** Skip unless `wlan0` is up and holds the default route, and the battery is at or above the floor (30%) or charging.
2. **Fetch and verify.** GET `latest.json` and `latest.json.sig` from the feed. Check the ed25519 signature against Cedar's public key. Nothing else is trusted, so a compromised server can't push code. Redirects are never followed: a 3xx is an error (see "What the server lane serves").
3. **Refuse what doesn't fit.** Wrong device, an OS version the release wasn't tested on (exact match on `IMG_VERSION`, 3.27.2.2), not newer than the running release (stops replays), or a release that failed here before.
4. **Download.** GET `<id>.tar.gz` into `downloads/`. An interrupted download resumes next run with a Range request. A sha256 mismatch deletes the file.
5. **Unpack** into `releases/.staging-<id>`, then rename to `releases/<id>`. Nothing in the tarball can write outside it.
6. **Swap.** Write `pending=<id>` to state, run the old release's `deactivate.sh`, then flip `current` with one `rename(2)` of a temp symlink.
7. **Health check.** Run the new release's `activate.sh`, then the built-in checks (xochitl stays active with the same PID for 70 s, longer than its 60 s watchdog; optional "these libraries are loaded in xochitl"), then the release's `checks/*`.
8. **Commit or roll back.** Pass: the release is committed, the previous one stays on disk, older ones are pruned. Fail: deactivate the new release, flip `current` back, re-activate the old release, and mark the new one failed so it is never tried again. Stopped mid-check (SIGTERM: a shutdown, or a triple-press): no hooks run, `pending` stays, and the next run rolls back.
9. **Report.** POST a status JSON to the server.

`pp-agent boot` runs once per boot:

- A `pending` release in state means the last run died mid-check (power cut, crash reboot, kill). It rolls back first.
- **Default: stay stock.** `activate_on_boot` is false, so after a reboot the tablet runs the stock UI. Mods come back by a triple-press or by the next release install.
- With `activate_on_boot: true`, it runs `activate.sh` and the checks; on failure it runs `deactivate.sh`, so that boot is stock. **Boot-loop guard:** every boot counts as unhealthy until the checks pass. After 3 boots in a row that never got healthy, it stays stock. A new release that passes its checks clears the guard, and so does `pp-agent reset-guard`.
- If the running OS isn't one the release was tested on (e.g. the bootloader fell back to the other partition), it stays stock.

`pp-agent tripletap` (its own service) watches the power key. Three presses, each within 3 s of the last, run `pp-agent toggle`. Turning mods on always goes through the same `activate.sh` and health check.

## Three ways back to stock

The desiderata: "Triple-press power disables all mods. Reboot returns stock UI." Plus the agent's own rollback.

| Way | What happens | Mods come back |
| --- | --- | --- |
| **Triple-press power** | Mods on (pp-agent turned them on, or xochitl runs with `LD_PRELOAD`, e.g. xovi started by hand): `deactivate.sh`, stock UI. Mods off: turn the committed release on, health-checked; unhealthy means `deactivate.sh` again. Pressed while pp-agent is busy (installing, booting): it stops that run (SIGTERM) and turns mods off; a stopped install is rolled back and not retried | Next triple-press, or next install |
| **Reboot** | xovi's drop-in lives on a tmpfs, and pp-agent boot does not activate (`activate_on_boot: false`) | Triple-press, or next install |
| **Auto-rollback** | A release that fails its health check is rolled back at install, or at the next boot if the check was cut short | A newer release |

Plus the file switch, for SSH: `touch /home/root/paper-pure/disable`. Then boot and update units skip, nothing turns mods on (not even a triple-press, which can then only turn them off), and `pp-agent rollback` refuses. Remove the file to undo.

They compose: a triple-press during an install wins (mods off, that release marked failed); the guard only gates boot activation; the file beats everything that would turn mods on.

**Prefer mods back after every reboot?** One line in `agent.json`: `"activate_on_boot": true`. Then reboot is not a kill switch any more; triple-press and the boot-loop guard still are.

## Why a crash loop can't brick it

Stock tatsu xochitl (`xochitl.service` plus `/usr/lib/systemd/system/xochitl.service.d/xochitl-service-override.conf`): `Restart=on-failure`, `RestartMode=direct`, `WatchdogSec=60`, `StartLimitBurst=4` in 600 s, and `OnFailure=emergency.target` (OnFailure adds to the unit's own `remarkable-fail.service`, which is missing from the image). On tatsu `emergency.target` requires `rm-emergency.service`, and `rm-emergency.sh` **reboots**. It also swaps the A/B root slot, but only when `swu_applied=1`, i.e. right after an OS update. So after 4 starts in 10 minutes xochitl does not stay failed: the tablet reboots.

What keeps that safe:

- **Our restarts don't count.** The agent runs `systemctl reset-failed xochitl.service` before every hook, and the mods hooks do it again right before their own restart. The 4 starts are left for real crashes.
- **Crash loops slower than about a second each** (a broken hook that dies a few seconds in): the health check sees the first new PID and rolls back before the 4th crash. Shown in the test bed: no reboot, `rm-emergency` never ran.
- **Faster ones** (a library that won't load, dead at once): the OS reboots mid-check. The agent gets SIGTERM, leaves `pending` set and runs no hooks. The reboot drops xovi's tmpfs drop-in, so xochitl comes up stock, and `pp-agent boot` rolls `pending` back. The release is marked failed.
- **Never an A/B swap.** OS updates never run here (device lane), and `rm-sanity` writes `swu_applied=0` 60 s after every boot.
- **Never the bootloader's error count.** The SPL counts boots per slot and falls back to the other slot (an unfrozen OS) past a limit; `rm-sanity` clears the count 60 s after boot. Nothing of ours turns mods on before that: `pp-agent-boot` and `pp-agent-tripletap` wait for rm-sanity (device lane drop-in), the update timer starts at 3 minutes. So every crash reboot happens with the count at 0, and the next boot counts 1.
- **A hang, not a crash:** the watchdog kills xochitl at 60 s, and the 70 s stability window sees it.
- **At boot** (`activate_on_boot: true` only): the guard ends a crash-reboot loop after 3 boots.

## Layout on the tablet

```
/home/root/paper-pure/
  agent.json            config (0600, holds the Cloudflare Access token)
  bin/pp-agent          the agent (installed once, see below)
  keys/release.pub.pem  Cedar's release public key
  current -> releases/<id>   the one pointer; missing = no release
  releases/<id>/        unpacked release (current and previous only)
  releases/<id>.json    its signed manifest, and <id>.json.sig
  downloads/            partial downloads
  state/state.json      committed, previous, pending, failed, boot counter, events
  state/agent.log       local log (also on stderr, so in journald), rotated at 256 KiB
  state/lock            flock; holds the PID of the run that has it
  systemd/              the four units, as installed
  disable               kill switch file: nothing turns mods on
/run/paper-pure/live    release whose mods may be live now (tmpfs: gone at reboot)
```

`current` says which release is installed; `live` says whether its mods are on right now. `live` is written before `activate.sh` runs and removed once `deactivate.sh` succeeds, so when in doubt it says "on", and a triple-press turns mods off.

## Release format

A release is three files in the feed directory, plus `latest.json` and `latest.json.sig` (copies of the newest manifest and its signature):

| File | What |
| --- | --- |
| `<id>.tar.gz` | The release tree. Reproducible: sorted, uid 0, one mtime. Only files, dirs, and relative symlinks that stay inside the tree |
| `<id>.json` | Manifest, the exact bytes that were signed |
| `<id>.json.sig` | base64 ed25519 signature over `<id>.json` |

```json
{
  "format": 1,
  "id": "good4",
  "device": "tatsu",
  "created": "2026-10-25T10:04:00Z",
  "os_versions": ["3.27.2.2"],
  "size": 342,
  "sha256": "19fe730c...",
  "expect_mapped": ["xovi.so"],
  "notes": "optional"
}
```

- `os_versions` lists exact `IMG_VERSION` strings the release was tested on. There are no ranges, because the versions in between were never tested. During an OS move, list both versions.
- `created` must be newer than the running release. To roll back on purpose, re-sign the old tree under a new id.
- `expect_mapped` (optional): substrings that must appear in `/proc/<xochitl pid>/maps` after activation, e.g. `xovi.so`, `appload.so`.
- Unknown fields are rejected. The tarball's name is always `<id>.tar.gz`.

Keys are standard PEM: PKCS#8 private, PKIX public. You can check a release by hand with the tablet's own OpenSSL 3.2.6. The tablet has no `base64` binary, so decode with openssl:

```sh
openssl base64 -d -A -in latest.json.sig -out /tmp/sig
openssl pkeyutl -verify -pubin -inkey release.pub.pem -rawin -in latest.json -sigfile /tmp/sig
sha256sum <id>.tar.gz    # compare with "sha256" in latest.json
```

## Making a release

```sh
make build                                     # out/pp-agent-arm64, out/ppsign-arm64, out/ppsign
out/ppsign keygen -out ~/pp-keys               # once; private key goes in the password manager
out/ppsign pack -key ~/pp-keys/release.key.pem -dir path/to/release-tree \
    -id 2026-10-25.1 -os 3.27.2.2 -expect-mapped xovi.so -out feed/ -latest
out/ppsign verify -pub ~/pp-keys/release.pub.pem -manifest feed/2026-10-25.1.json
out/ppsign serve -dir feed/ -addr 127.0.0.1:3090   # dev only: static feed plus POST /status
```

`pack` writes the tarball first and `latest.json` last, so a reader never sees a manifest whose tarball isn't there yet. Publishing means copying the feed directory to the server. The private key never goes on the server.

## Hooks and checks (the contract with the mods lane)

A release tree looks like this. Everything else in it belongs to the mods lane.

```
hooks/activate.sh     make this release's mods live (e.g. restart xochitl with xovi)
hooks/deactivate.sh   back to stock UI, no mods
checks/NN-name.sh     smoke checks, run in name order after activate
```

- All three are optional. A missing hook is a no-op.
- They run as root. The working directory is the release dir. The env has `PP_ROOT`, `PP_RELEASE_ID`, `PP_RELEASE_DIR`, `PP_REASON` and `PP_OS_VERSION`. `PP_REASON` is one of `install`, `boot`, `rollback`, `manual-rollback`, `boot-failed`, `tripletap`, `tripletap-failed`.
- Exit 0 means pass. Anything else means fail: on install the agent rolls back, at boot or on a triple-press it runs `deactivate.sh` and stays stock. Output goes to `agent.log`.
- Timeouts: hooks get 120 s and checks 60 s, then the whole process group is killed. That counts as a failure.
- The agent's units are a oneshot (timer, boot) and a simple service (tripletap). systemd kills anything a hook leaves running, so long-lived things go through `systemctl` or `systemd-run`.
- When `activate.sh` exits, xochitl must already be in its final state, because the built-in check starts right away. Use a blocking `systemctl restart xochitl.service`, not `--no-block`.
- `deactivate.sh` must be idempotent. It must work when activate never ran or only half ran, and it must restore stock even if xochitl hit its start limit.
- **Start limit.** The agent runs `systemctl reset-failed xochitl.service` before every hook. A hook that restarts xochitl more than once (stop, start, restart) should reset it again right before the last restart, so only crashes count toward `StartLimitBurst=4` (see "Why a crash loop can't brick it").
- Order on install: old `deactivate`, flip, new `activate`, built-in checks, `checks/*`. Order on rollback: new `deactivate`, flip back, old `activate`, its checks. A triple-press runs only `deactivate`, or `activate` and the checks.
- To read the installed release from elsewhere, use `/home/root/paper-pure/current/...` (missing = no release). Whether its mods are on right now is `/run/paper-pure/live`.

`example/release/` has stub hooks and a check that follow the contract.

## Config (`agent.json`)

Every field has a default for the Pure on 3.27.2.2. A config file only overrides fields. See `config.example.json`.

| Field | Default | Why |
| --- | --- | --- |
| `feed_url` | (none: no updates) | Feed directory URL, ends in `/` |
| `status_url` | (none: no reports) | Status POST endpoint |
| `headers` | `{}` | Sent on every request, e.g. `CF-Access-Client-Id` and `CF-Access-Client-Secret` |
| `pubkey` | `<root>/keys/release.pub.pem` | |
| `ca_file` | system roots | Pin a CA. The tablet has `/etc/ssl/certs/ca-certificates.crt` |
| `wifi_iface` | `wlan0` | wpa_supplicant runs with `-i wlan0`; networkd's `25-wlan0.network` does DHCP |
| `battery_capacity` | `/sys/class/power_supply/max77818_battery/capacity` | The path `libcslpower.so` reads (tatsu has a max77818 MFD) |
| `charger_online` | `/sys/class/power_supply/max77818-charger/online` | Same library |
| `battery_floor` | 30 | Percent. 0 turns the check off |
| `require_charging` | false | Set true to update only while plugged in |
| `stable_seconds` | 70 | xochitl must keep one PID this long; longer than its `WatchdogSec=60`, so a hang shows too. 0 turns the check off |
| `boot_guard_max` | 3 | Unhealthy boots in a row before staying stock |
| `activate_on_boot` | false | The spec: reboot returns stock UI. `true` brings mods back at every boot |
| `power_key_device` | found by name, then by `KEY_POWER` capability under `sys_class_input` | tatsu: the i.MX93 BBNSM key, `44440000.bbnsm:pwrkey` (the name in `/etc/pm/sleep.wakesrc`) |
| `tripletap_gap_ms` | 3000 | Longest gap between the three presses. Uses the kernel's event times |
| `run_dir` | `/run/paper-pure` | Holds `live`; must be a tmpfs |
| `systemctl`, `xochitl_unit`, `os_release`, `sys_class_net`, `sys_class_input`, `proc_net_route`, `proc_dir` | the real paths | Overridable for the emulator and tests |

Flight mode should fail the Wi-Fi gate. `wpa_supplicant.service` has an `ExecCondition` that keeps it down when `/home/root/.config/remarkable/csl.conf` says `wifi = off`, and without it `wlan0` has no default route. Which UI action writes that line is not checked.

## What the device lane wires up

1. **Install files** over SSH: copy `out/pp-agent-arm64` (as `pp-agent`), `release.pub.pem`, `agent.json`, `systemd/` and `install.sh` to the tablet, then run `sh install.sh` (only `cp`, `chmod`, `mv`: the tablet has no `install(1)`). With `--runtime`, it also starts the timer and the triple-press service from `/run/systemd/system`. That is gone at reboot, so it is a safe first try.
2. **Persist the units.** On tatsu, `/etc` is an overlay with a tmpfs upper layer (`var-volatile-etc.service` runs `mount-copybind /var/volatile/etc /etc`), so writes there vanish at reboot. `device/tablet/pp-device.sh` writes them into the real rootfs `/etc/systemd/system/`:
   - `pp-agent-boot.service`, `pp-agent.service`, `pp-agent.timer`, `pp-agent-tripletap.service`
   - `multi-user.target.wants/pp-agent-boot.service`, `multi-user.target.wants/pp-agent-tripletap.service`, `timers.target.wants/pp-agent.timer`
   - a drop-in on `pp-agent-boot` and `pp-agent-tripletap` that waits for `rm-sanity` (see "Why a crash loop can't brick it")

   The units only point at `/home/root/paper-pure/...`, so they never need to change again. Everything else updates over the air.
3. **Nothing else enables mods.** No xovi autostart unit and no xovi-tripletap: `pp-agent` (boot, update, toggle) is the one path, so the health check and the guard always apply.
4. **Escape hatches over SSH:**
   - `pp-agent toggle`: what a triple-press does
   - `touch /home/root/paper-pure/disable`: nothing turns mods on
   - `pp-agent status`, `pp-agent rollback`, `pp-agent reset-guard`

## What the server lane serves

- A static directory per device, `feed_url`: `latest.json`, `latest.json.sig`, `<id>.tar.gz`. It must support Range requests (any static file server does) so downloads can resume.
- `POST status_url` with `Content-Type: application/json`, any 2xx. Body: `device`, `agent_version`, `time`, `os_version`, `release` (what `current` points at), `live` (release with mods on now, `""` = stock UI), `disabled`, `committed`, `previous`, `pending`, `failed[]`, `unhealthy_boots`, `guard_tripped`, `last_run`, `last_result`, `last_error`, `battery_percent`, `events[]` (the last 30), and `log_tail` (the last 4 KiB of `agent.log`). Keep the last N per device somewhere Claude can read.
- Both go through Cloudflare Access with the tablet's service token, carried in `headers`.
- **The agent never follows redirects.** Behind Access, a refused token gets a 302 to a login page. Followed, a status POST would turn into a GET of that page and look like success. So any 3xx is an error that names its `Location`. Access's "return 401 for service auth" setting is still worth turning on, so the error says 401.

## Tests

```sh
make test          # go vet + go test -race ./...   (seconds)
make integration   # arm64 binary in an arm64 container (qemu), about 60 s
PP_IMAGE=pp-agent-tatsu-rootfs:3.27.2.2 make integration   # on the real tatsu userland
test/import-rootfs.sh <extracted-rootfs>   # builds that image locally; never push it
device/test/run.sh <extracted-rootfs>      # the agent under real systemd 255, with the real mods hooks (scenario 9)
```

## Status

Verified (Oct 25, 2026, in the dev container):

- `make test`: all pass, with `-race`. They cover:
  - signature rejects (wrong key, tampered manifest, junk signature)
  - OS-version and device mismatch, unreadable os-release, and parsing the real tatsu os-release
  - interrupted download resuming via `Range: bytes=N-`, and a corrupt download deleted
  - crash-looping xochitl leading to rollback, with the hook order asserted
  - a failing check script on first install leading to rollback to stock
  - a hook timeout killing the process group
  - `expect_mapped`
  - a replayed older release refused
  - the Wi-Fi, route, battery and charging gates
  - the boot-loop guard: trips after 3 boots, stays stock, cleared by a new release
  - the boot counter on disk before activate runs
  - the OS changing under us at boot
  - a reboot mid health check rolled back at boot
  - manual rollback and prune
  - pointer repair
  - Cloudflare-style headers sent, and `ca_file` pinning
  - **redirects:** a feed and a status endpoint that 302 to a login page: the update fails with `302 Found ... not followed`, the status POST is logged as an error, and the login page is never fetched
  - **kill switch:** boot stays stock by default and a toggle brings the release back; toggle off and on twice; mods started by hand (no live marker, `LD_PRELOAD` in xochitl's environ) still toggle off; toggle on with a crash-looping release ends stock without marking it failed; the `disable` file (toggle only turns off, boot, update and rollback refuse); a SIGTERM mid health check leaves `pending` and runs no hooks, then a toggle rolls it back; a toggle while another run holds the lock stops it with SIGTERM and means "off"; `reset-failed` before every hook
  - **power key:** input_event parsing (presses only; releases, autorepeat, other keys, switches and a torn event ignored), the 3-press counter (gaps, 6 presses = 2 toggles, single sleep/wake presses never fire, presses during a toggle ignored), finding the key by name (`44440000.bbnsm:pwrkey`) and by `KEY_POWER` capability, and `pp-agent tripletap` end to end on recorded events
  - pack reproducibility, tar escapes refused (`..`, absolute paths, absolute or climbing symlinks, hardlinks, devices, a symlink under a symlink), and openssl interop
- Mutation check: disabling any one of these makes a test fail: signature verification, the OS check, the created-time check, the failed-list skip, Range resume, the flip back, the guard, the boot-counter save, the pending recovery, the PID-stability check, the symlink-under-symlink guard, the Wi-Fi operstate gate, and (new) refusing redirects, `activate_on_boot` defaulting to false, "busy means off", "disable means off", stopping the busy run, `reset-failed` before hooks, keeping `pending` on SIGTERM, ignoring presses during a toggle, the live marker before activate, the `LD_PRELOAD` check, and the `disable` check at boot.
- `make integration` passes 60 checks on `busybox:1.36.1` (arm64) and 61 on `pp-agent-tatsu-rootfs:3.27.2.2` (the real 3.27.2.2 userland, real `/etc/os-release`). New since the first phase: `install.sh` runs there with no `install(1)` (the tatsu image has none), and `pp-agent tripletap` reads `struct input_event` records from a FIFO: 3 presses turn mods off, 2 do nothing, 3 more turn them on, with `reset-failed` logged before the hooks. Older checks: install, crash loop and rollback, `kill -9` mid check then boot rollback, the guard over 4 boots, OS mismatch, a foreign signature, the status POST.
- Under real systemd 255 in the device lane's test bed (`device/test/run.sh`, scenario 9), with the real mods hooks and upstream's `xovi/start` and `xovi/stock`: see `device/README.md` Status.
- `systemd-analyze verify --root=<copy of the tatsu systemd tree>` on the units: clean (first phase, three units).
- Inside the tatsu container, the tablet's OpenSSL 3.2.6 verifies a `ppsign` signature (`openssl pkeyutl -verify -rawin`) and rejects a tampered manifest.
- Device facts come from the 3.27.2.2 tatsu rootfs:
  - power paths from `libcslpower.so` strings, and the `max77818-charger.ko` / `max77818_battery` kernel modules
  - `wpa_supplicant -i wlan0`
  - the `/etc` overlay from `var-volatile-etc.service`
  - the crash path: `xochitl-service-override.conf` adds `OnFailure=emergency.target` and `RestartMode=direct`; `emergency.target` requires `rm-emergency.service`, which reboots (and swaps slots only if `swu_applied=1`); `rm-sanity.sh` zeroes `swu_applied` and the slot's error count. (The first phase wrote here that xochitl "just stays failed" after 4 crashes. Wrong: it reboots.)
  - the power key: DT `nxp,imx93-bbnsm-pwrkey`, `KEY_POWER`; `/etc/pm/sleep.wakesrc` names it `44440000.bbnsm:pwrkey`
  - no `base64` and no `install` binary on the tablet

Not verified:

- Anything on the real tablet: real sysfs values, real `systemctl show xochitl.service` output, Wi-Fi and sleep behavior, timer behavior across suspend.
- **Triple-press on hardware.** That the BBNSM key's input name contains `pwrkey` (the name match; the `KEY_POWER` capability fallback covers it if not); that xochitl does not grab the key (xovi-tripletap reads it with `evtest`, which suggests not); that the press that wakes the tablet is reported to userspace (the first press sends it to sleep, the second wakes it); and that 3 s between presses is enough with a sleep and a wake in between. Try it by hand first: `journalctl -fu pp-agent-tripletap` and press.
- HTTPS through Cloudflare (the code path is the same as `ca_file` pinning, which is tested).
- The emulator rung for the triple-press: the emulator's input devices exist only through its `LD_PRELOAD` shim, and `pp-agent` is static, so it can't open them there. `cat /dev/input/event0 | pp-agent -config ... tripletap` with `power_key_device: /dev/stdin` would work (busybox `cat` gets the shim), not tried.

Open questions for Cedar:

- **Installs restart xochitl.** That can happen mid-writing. Install only while charging (`require_charging: true`)? Or only at boot?
- **Agent self-update.** v1 installs `pp-agent` once over SSH and never replaces it, because a broken agent can't roll itself back. Fine for now, or should a release be able to carry a new agent?
- **A triple-press during an install marks that release failed** (it was stopped, so it is not retried by itself). Re-sign it under a new id to try again. OK?
- **Is `/` writable after `mount -o remount,rw /` in developer mode on the Pure?** The device lane reads yes from u-boot's environment; not tried on hardware.
