# agent

The tablet's update agent (`pp-agent`) and the release tool (`ppsign`). Covers desiderata rows 2 (never brick), 7 (ships over the air) and 11 (observable).

Both are static Go binaries, stdlib only. The tablet needs nothing installed: no curl, no python.

## How it works

The tablet pulls; nothing pushes into it. A systemd timer runs `pp-agent update` every 30 minutes while the tablet is awake:

1. **Gates.** Skip unless `wlan0` is up and holds the default route, and the battery is at or above the floor (30%) or charging.
2. **Fetch and verify.** GET `latest.json` and `latest.json.sig` from the feed. Check the ed25519 signature against Cedar's public key. Nothing else is trusted, so a compromised server can't push code.
3. **Refuse what doesn't fit.** Wrong device, an OS version the release wasn't tested on (exact match on `IMG_VERSION`, 3.27.2.2), not newer than the running release (stops replays), or a release that failed here before.
4. **Download.** GET `<id>.tar.gz` into `downloads/`. An interrupted download resumes next run with a Range request. A sha256 mismatch deletes the file.
5. **Unpack** into `releases/.staging-<id>`, then rename to `releases/<id>`. Nothing in the tarball can write outside it.
6. **Swap.** Write `pending=<id>` to state, run the old release's `deactivate.sh`, then flip `current` with one `rename(2)` of a temp symlink.
7. **Health check.** Run the new release's `activate.sh`, then the built-in checks (xochitl stays active with the same PID for 45 s; optional "these libraries are loaded in xochitl"), then the release's `checks/*`.
8. **Commit or roll back.** Pass: the release is committed, the previous one stays on disk, older ones are pruned. Fail: deactivate the new release, flip `current` back, re-activate the old release, and mark the new one failed so it is never tried again.
9. **Report.** POST a status JSON to the server.

`pp-agent boot` runs once per boot:

- A `pending` release in state means the last run died mid-check (power cut, crash reboot, kill). It rolls back first.
- **Boot-loop guard.** Every boot counts as unhealthy until the checks pass. After 3 boots in a row that never got healthy, it stays stock and does not activate mods. A new release that passes its checks clears the guard, and so does `pp-agent reset-guard`.
- If the running OS isn't one the release was tested on (e.g. the bootloader fell back to the other partition), it stays stock.
- Otherwise it runs `activate.sh` and the checks. On failure it runs `deactivate.sh`, so that boot is stock.

`pp-agent boot` is the only thing that turns mods on at boot.

## Layout on the tablet

```
/home/root/paper-pure/
  agent.json            config (0600, holds the Cloudflare Access token)
  bin/pp-agent          the agent (installed once, see below)
  keys/release.pub.pem  Cedar's release public key
  current -> releases/<id>   the one pointer; missing = stock
  releases/<id>/        unpacked release (current and previous only)
  releases/<id>.json    its signed manifest, and <id>.json.sig
  downloads/            partial downloads
  state/state.json      committed, previous, pending, failed, boot counter, events
  state/agent.log       local log (also on stderr, so in journald), rotated at 256 KiB
  disable               if this file exists, the agent units do nothing
```

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
- They run as root. The working directory is the release dir. The env has `PP_ROOT`, `PP_RELEASE_ID`, `PP_RELEASE_DIR`, `PP_REASON` and `PP_OS_VERSION`. `PP_REASON` is one of `install`, `boot`, `rollback`, `manual-rollback`, `boot-failed`.
- Exit 0 means pass. Anything else means fail: on install the agent rolls back, at boot that boot stays stock. Output goes to `agent.log`.
- Timeouts: hooks get 120 s and checks 60 s, then the whole process group is killed. That counts as a failure.
- The agent's unit is a oneshot. systemd kills anything a hook leaves running, so long-lived things go through `systemctl` or `systemd-run`.
- When `activate.sh` exits, xochitl must already be in its final state, because the built-in check starts right away. Use a blocking `systemctl restart xochitl.service`, not `--no-block`.
- `deactivate.sh` must be idempotent. It must work when activate never ran or only half ran, and it must restore stock even if xochitl hit its start limit (`StartLimitBurst=4` in 600 s). Use `systemctl reset-failed xochitl.service` before `restart`.
- Order on install: old `deactivate`, flip, new `activate`, built-in checks, `checks/*`. Order on rollback: new `deactivate`, flip back, old `activate`, its checks.
- To read the live release from elsewhere, use `/home/root/paper-pure/current/...`. If `current` is missing, the tablet is stock.

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
| `stable_seconds` | 45 | xochitl must keep one PID this long. 0 turns the check off |
| `boot_guard_max` | 3 | Unhealthy boots in a row before staying stock |
| `activate_on_boot` | true | See open questions |
| `systemctl`, `xochitl_unit`, `os_release`, `sys_class_net`, `proc_net_route`, `proc_dir` | the real paths | Overridable for the emulator and tests |

Flight mode should fail the Wi-Fi gate. `wpa_supplicant.service` has an `ExecCondition` that keeps it down when `/home/root/.config/remarkable/csl.conf` says `wifi = off`, and without it `wlan0` has no default route. Which UI action writes that line is not checked.

## What the device lane wires up

1. **Install files** over SSH: copy `out/pp-agent-arm64` (as `pp-agent`), `release.pub.pem`, `agent.json`, `systemd/` and `install.sh` to the tablet, then run `bash install.sh`. With `--runtime`, it also starts the timer from `/run/systemd/system`. That is gone at reboot, so it is a safe first try.
2. **Persist the units.** On tatsu, `/etc` is an overlay with a tmpfs upper layer (`var-volatile-etc.service` runs `mount-copybind /var/volatile/etc /etc`), so writes there vanish at reboot. The units must be written under the overlay, into the real rootfs `/etc/systemd/system/` (remount `/` rw, bind-mount `/`, write, remount ro, as remagic's `persist_local_to_rootfs` does):
   - `pp-agent-boot.service`, `pp-agent.service`, `pp-agent.timer`
   - `multi-user.target.wants/pp-agent-boot.service -> ../pp-agent-boot.service`
   - `timers.target.wants/pp-agent.timer -> ../pp-agent.timer`

   The units only point at `/home/root/paper-pure/...`, so they never need to change again. Everything else updates over the air.
3. **Nothing else enables mods at boot.** No xovi autostart unit: `pp-agent boot` is the one path, so the boot-loop guard can work. Triple-press stays as the human kill switch.
4. **Escape hatches over SSH:**
   - `touch /home/root/paper-pure/disable`: both units skip
   - `pp-agent status`
   - `pp-agent rollback`
   - `pp-agent reset-guard`

## What the server lane serves

- A static directory per device, `feed_url`: `latest.json`, `latest.json.sig`, `<id>.tar.gz`. It must support Range requests (any static file server does) so downloads can resume.
- `POST status_url` with `Content-Type: application/json`, any 2xx. Body: `device`, `agent_version`, `time`, `os_version`, `release` (what `current` points at), `committed`, `previous`, `pending`, `failed[]`, `unhealthy_boots`, `guard_tripped`, `last_run`, `last_result`, `last_error`, `battery_percent`, `events[]` (the last 30), and `log_tail` (the last 4 KiB of `agent.log`). Keep the last N per device somewhere Claude can read.
- Both go through Cloudflare Access with the tablet's service token, carried in `headers`.

## Tests

```sh
make test          # go vet + go test -race ./...   (seconds)
make integration   # arm64 binary in an arm64 container (qemu), about 40 s
PP_IMAGE=pp-agent-tatsu-rootfs:3.27.2.2 make integration   # on the real tatsu userland
test/import-rootfs.sh <extracted-rootfs>   # builds that image locally; never push it
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
  - pack reproducibility, tar escapes refused (`..`, absolute paths, absolute or climbing symlinks, hardlinks, devices, a symlink under a symlink), and openssl interop
- Mutation check: disabling any one of these makes a test fail: signature verification, the OS check, the created-time check, the failed-list skip, Range resume, the flip back, the guard, the boot-counter save, the pending recovery, the PID-stability check, the symlink-under-symlink guard, or the Wi-Fi operstate gate.
- `PP_WORK=... test/integration.sh` passes 47 checks on `busybox:1.36.1` (arm64) and on `pp-agent-tatsu-rootfs:3.27.2.2`. The second is the real 3.27.2.2 userland, with its real `/etc/os-release` parsed. The checks cover:
  - install leading to pass
  - install leading to a crash loop, then rollback
  - a real `kill -9` of `pp-agent` mid health check, then `pp-agent boot` rolling back
  - the boot-loop guard over 4 boots
  - an OS mismatch refused
  - a foreign signature refused, and its tarball never unpacked
  - a status POST received by the feed server
- `systemd-analyze verify --root=<copy of the tatsu systemd tree>` on the three units: clean. Host systemd is 255, the same major as the tablet. A typo'd copy was flagged, so the verifier does check.
- Inside the tatsu container, the tablet's OpenSSL 3.2.6 verifies a `ppsign` signature (`openssl pkeyutl -verify -rawin`) and rejects a tampered manifest.
- Device facts come from the 3.27.2.2 tatsu rootfs:
  - power paths from `libcslpower.so` strings, and the `max77818-charger.ko` / `max77818_battery` kernel modules
  - `wpa_supplicant -i wlan0`
  - the `/etc` overlay from `var-volatile-etc.service`
  - `xochitl.service`'s `OnFailure=remarkable-fail.service` points at a unit that does not exist in this image. After 4 failures in 10 minutes, xochitl just stays failed.
  - no `base64` binary on the tablet

Not verified:

- Anything on the real tablet: real sysfs values, real `systemctl show xochitl.service` output (the format is standard systemd 255; tests use a fake), Wi-Fi and sleep behavior, timer behavior across suspend.
- `install.sh` (shellcheck only). Persisting the units into the real `/etc`.
- HTTPS through Cloudflare (the code path is the same as `ca_file` pinning, which is tested).
- The emulator rung. The emulator's fake `systemctl` has no `show` yet, so there either set `stable_seconds: 0` or add `show` to the shim.

Open questions for Cedar:

- **`activate_on_boot`.** The desiderata say "Reboot returns stock UI". With the default `true`, a reboot re-enables mods, protected by the boot-loop guard. With `false`, a reboot is stock until Cedar triple-presses or the next install. Which one?
- **Installs restart xochitl.** That can happen mid-writing. Install only while charging (`require_charging: true`)? Or only at boot?
- **Agent self-update.** v1 installs `pp-agent` once over SSH and never replaces it, because a broken agent can't roll itself back. Fine for now, or should a release be able to carry a new agent?
- **Is `/` writable after `mount -o remount,rw /` in developer mode on the Pure (dm-verity)?** If not, there is no place to persist boot units, and the device lane needs another start path.
