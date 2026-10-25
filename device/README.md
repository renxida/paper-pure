# device: the tablet's own config

What lives on the tablet outside our releases, and the one script that sets it up. Covers desiderata rows 2 (never brick), 3 (OS frozen), 4 (writing feel stays stock), "SSH is private" and "Official OS updates: never". The human steps are in [docs/runbook-bootstrap.md](../docs/runbook-bootstrap.md); where the firmware comes from is in [docs/firmware.md](../docs/firmware.md).

```bash
device/install.sh --key ~/.ssh/id_ed25519.pub root@10.11.99.1   # set up; safe to re-run
device/install.sh --verify root@10.11.99.1                      # check only; exit 1 on any FAIL
device/install.sh --agent --release-pub P --agent-json J root@10.11.99.1   # plus pp-agent
device/install.sh --proxy root@10.11.99.1                       # plus pp-proxy (self-hosted sync)
device/install.sh --uninstall root@10.11.99.1                   # root fs back to stock
device/test/run.sh <extracted 3.27.2.2 rootfs>                  # the proof, in a container
```

| Path | What |
| --- | --- |
| `install.sh` | Runs on the laptop. One SSH connection (a password is asked at most once), tar over SSH (no scp needed), then `pp-device.sh` on the tablet |
| `tablet/pp-device.sh` | Runs on the tablet: `install`, `verify`, `uninstall`, and `persist PATH` / `restore PATH` for other lanes |
| `tablet/freeze.hosts` | The `/etc/hosts` block that sends update hosts to `0.0.0.0` |
| `tablet/wait-sanity.sh`, `tablet/pp-agent-boot-wait.conf` | Mods wait for `rm-sanity` at boot (see "Never brick") |
| `shim/install` | A stand-in for `install(1)`, which the tablet lacks. `agent/install.sh` needs it |
| `test/run.sh`, `test/testbed/` | The stand-in tablet and the scenarios |

On the tablet, everything of ours is under `/home/root/paper-pure/device/`: the scripts, `managed.list` (every root fs path we changed) and `stock/` (the stock copy of each, taken before the first change).

## How updates are frozen

Everything on 3.27.2.2 that can update the OS, found in the root fs:

| Piece | What it does | How we stop it |
| --- | --- | --- |
| xochitl, Settings > General > Software > **Updates** | The switch *is* `update-engine.service`. xochitl enables, starts, stops and disables that unit over systemd's D-Bus API, and shows the switch on only when the unit is "enabled" (strings: `update-engine.service`, `update-engine status:`, `EnableUnitFiles`, `Error when enabling update engine!`). Seen in the emulator: switching it on calls out to enable the engine and does not touch `xochitl.conf` | Mask `update-engine.service`. The switch reads off and can't be turned on |
| `update-engine.service` | `fakeupdateengine_service`, D-Bus `no.remarkable.update1`. Talks to swupdate over its IPC socket (`swupdate-ipc`) | Masked |
| `swupdate.service`, `swupdate.socket` | The installer. Suricatta mode with `-d` (no polling of its own, waits for IPC) and `-x` (no TLS verification!). Socket-activated on `/tmp/sockinstctrl` | Both masked |
| `memfaultd.service` | Writes `/tmp/swupdate.cfg`, swupdate's server config, from its `base_url` `https://device.cloud.remarkable.com`; `swupdate.service` is `PartOf` it. Also telemetry | Masked, plus `memfault-attributes.service` so it doesn't fail every boot |
| `rm-apply-ota.service` | At reboot, switches slots if an update was installed (`swu_status` 1) | Left alone: inert while swupdate can't run |
| `systemd-sysupdate.timer` | Stock systemd | Not enabled on tatsu, no transfer definitions |
| `mdm-agent` | `enterprise.cloud.remarkable.com`; a policy can force updates ("Company policy enforces automatic software updates") | Host blocked |

Hosts in `tablet/freeze.hosts` (`0.0.0.0`): `device.cloud.remarkable.com` (memfaultd, so suricatta), `device.memfault.com` (memfaultd's built-in default), `enterprise.cloud.remarkable.com` (MDM), and `remarkable-software.s3.us-east-2.amazonaws.com` (where the `.swu` files live; not on the tablet, blocked in case an update server hands out its URLs). The tablet resolves names through systemd-resolved, which reads `/etc/hosts` (`ReadEtcHosts` is not turned off in `resolved.conf.d`). There is no `iptables` binary on the tablet (the netfilter modules are there), so no firewall layer.

Other reMarkable names in the binaries (`auth.remarkable.com`, `errors.cloud.remarkable.com`, `retail.cloud.remarkable.com`, `tectonic.remarkable.com`, `www.remarkable.com`) are sync or analytics, not updates. They belong to the server lane's `pp-proxy` list or a later "nothing goes to reMarkable" pass.

Not used: an `AutoUpdate` key exists in xochitl's settings code, but the Updates switch does not write it (checked in the emulator), so we don't touch `xochitl.conf`.

## How it persists

- In developer mode `/` is plain ext4: u-boot's environment boots `root=/dev/mmcblk0pN` when `unlocked=yes`, and `/dev/dm-0` through dm-verity otherwise (read from `u-boot.itb`). It is mounted read-only and can be remounted read-write.
- `/etc` is an overlay with a tmpfs upper (`var-volatile-etc.service`). A plain write to `/etc` is gone at reboot.
- `pp-device.sh` writes both views. Live, through the overlay, so it works now. And in the real root fs, through a non-recursive bind mount of `/` (`mount --bind / /run/pp-device/root` shows the ext4 under the overlay), with `/` remounted read-write for the write and read-only right after. This is remagic's `persist_local_to_rootfs` trick. It does not `umount -R /etc` (rmfakecloud-proxy's and xovi-tripletap's way), which also drops the bind mount holding dropbear's host key and breaks new SSH connections until a reboot.
- **Files in the root fs are rewritten in place, never replaced.** Replacing (`mv`, `sed -i`) unlinks the old inode while the `/etc` overlay still holds it, and then `mount -o remount,ro /` fails with EBUSY until the next reboot. Found in the test bed, and reproduced on purpose with `sed -i`.
- It survives reboots. It does not survive a slot switch: an OTA or the boot ROM's fallback boots the *other* root partition, which has none of this. `verify` prints which OS that slot holds.

## Never brick

- **Mods wait for rm-sanity.** The boot ROM counts boot attempts per slot and switches slot past a limit (SPL strings: `ABINFO: A (ecnt = %u)`, `A in error state, switch to B`, and with both slots bad, recovery mode, which needs a cable). `rm-sanity.service` clears the count 60 s after boot. If a mod crashes xochitl before that, the stock units (`StartLimitBurst=4`, `OnFailure=emergency.target`, `rm-emergency.sh` reboots) loop the tablet, and the count climbs to a slot switch onto an unfrozen OS. So `pp-agent-boot.service` gets a drop-in: `ExecStartPre=wait-sanity.sh` waits until `rm-sanity` has run this boot and `root<slot>_errcnt` is 0, up to 5 minutes, else mods stay off this boot. A mod crash loop then costs one reboot per try with the count at 1, and pp-agent's own boot guard (3 unhealthy boots, then stock) ends it.
- The wait has a cost: `pp-agent-boot` is a oneshot wanted by `multi-user.target`, so `multi-user.target` is reached about 60 s after boot instead of about 20 s. Nothing of reMarkable's is ordered after it (only stock `graphical.target` and `systemd-boot-check-no-failures`, neither used). xochitl starts as before.
- **Kill switches.** `touch /home/root/paper-pure/disable` (pp-agent's switch, then reboot). Reboot is stock unless pp-agent activates a release. Triple-press needs xovi-tripletap in toggle mode, not installed yet (see `mods/README.md`); its unit should go in with `pp-device.sh persist`.
- **Undo.** `--uninstall` restores every path in `managed.list` from `stock/`.

## SSH is private

- Over USB only, as stock: `dropbear-usb0.socket` binds to `usb0` (10.11.99.1).
- Over Wi-Fi: stock already keeps it off unless `/data/internal/rm_enable_ssh_wifi_marker` exists (`rm-ssh-over-wlan on` creates it). We remove the marker and mask `dropbear-wlan.socket`, so even `rm-ssh-over-wlan on` can't turn it on.
- Login: key from `--key`. The developer-mode password stays as the fallback. It is shown on the tablet's screen and only works over the cable. dropbear runs with `-B` (blank passwords allowed) from `/etc/default/dropbear`; root has a password in developer mode (xochitl sets it from `DeveloperPassword` with `usermod`), so we leave that as stock.
- **Private overlay: not now.** The tablet kernel has no TUN driver and no WireGuard (neither in `modules.builtin` nor as a module), so kernel WireGuard and kernel-mode Tailscale are out. Tailscale in userspace mode needs neither: `tailscaled --tun=userspace-networking` (a static arm64 build, 24 MB) starts on the 3.27.2.2 userland with no `/dev/net/tun` and waits for login. Developer mode also drops module signature enforcement, so a WireGuard module built from reMarkable's kernel sources would load; that is more to maintain.
- **Recommendation:** USB only. Routine changes go over the air through pp-agent, which only calls out. If a remote shell is ever needed, add Tailscale in userspace mode (one binary under `/home`, one unit persisted with `pp-device.sh persist`, ACLs to Cedar's devices). Cedar decides.

## Writing feel stays stock

Nothing here touches xochitl, its unit, the pen or display stack. We stop update and telemetry daemons and edit `/etc/hosts`. `memfaultd` also collected process metrics every 10 s; that's gone.

## For other lanes

- `pp-device.sh persist PATH...` copies PATH as it is live into the real root fs (backing up stock first). `pp-device.sh restore PATH...` puts it back. Use these instead of `umount -R /etc`.
- **agent**: `agent/install.sh` calls `install`, which the tablet does not have (no coreutils; its busybox has no `install` applet). `device/install.sh` lends it `shim/install` on `PATH`. Better: use `cp` and `chmod` there.
- **server**: `device/install.sh --proxy` runs `tablet-proxy/install.sh --runtime`, then persists the unit, its `multi-user.target.wants` link, the `# pp-proxy` hosts block (from `pp-proxy hosts`) and the CA bundle with `pp-device.sh`. Its own persistent mode (`umount -R /etc`) is not used.
- **mods**: tripletap's unit should go in with `pp-device.sh persist`. Its `enable.sh` does `umount -R /etc`.

## Status

### Verified (Oct 25, 2026, x86_64 dev container, qemu-user for arm64)

The test bed (`test/testbed/`) is the real 3.27.2.2 root fs running its own systemd 255 as PID 1 in a container, laid out like the tablet: `/` read-only, `/etc` overlaid by the image's own `var-volatile-etc.service`, `/etc/dropbear` bound from `/home` by the stock `etc-dropbear.mount`, the stock dropbear behind the stock developer-mode check, persistent `/home` and `/data` volumes, and a fake boot ROM counter (`lpgpr`) that survives reboots. A reboot is the container stopping and starting. Differences from the tablet: xochitl is a stand-in that pets the watchdog; memfaultd and systemd-resolved can't run there; hardware units are masked in `/run` only.

`PP_SLOW=1 device/test/run.sh <extracted 3.27.2.2 rootfs>`: **48 passed, 0 failed**, about 25 minutes (the fast part, scenarios 1 to 7, about 6 minutes). What it shows:

1. On a stock test bed, `--verify` exits 1, flags the unmasked units and the missing hosts block, and changes nothing. Stock memfaultd starts.
2. `install` exits 0 and ends with every check PASS; a fresh key-only SSH connection works; `/` is read-only again; no bind mount is left; `/etc/dropbear` is still mounted; `device.cloud.remarkable.com` resolves to `0.0.0.0` (busybox `wget` prints the address); the stock hosts lines are kept.
3. A second `install` changes nothing (0 `CHANGE` lines).
4. After a reboot, `--verify` passes. The overlay's tmpfs upper holds none of our files, so it all comes from the root fs. `swupdate`, `update-engine` and `memfaultd` never left "inactive" that boot. rm-sanity clears the counter.
5. Drift: a live-only unmask is caught (and reported as live vs root fs drift); a root-fs-only edit of `/etc/hosts` is caught; the Wi-Fi SSH marker is caught. `install` repairs all three.
6. `--agent --proxy`: exits 0 and `/` goes back to read-only. After a reboot, `--verify` passes with the agent and proxy checks; `pp-proxy.service` runs from the persisted unit; `my.remarkable.com` resolves to `127.0.0.1`; the proxy's CA is in the live bundle; `pp-agent.timer` is active; `wait-sanity.sh` logs "rm-sanity done, roota_errcnt=0 after 34s"; `pp-agent boot` started 3 s after `rm-sanity` exited (monotonic timestamps), and logged "boot: stock (no release installed)".
7. `--uninstall`, then reboot: verify fails again (stock), `swupdate.service` is enabled, no freeze block, stock hosts lines intact, `pp-agent-boot` not enabled. `install` brings it all back.
8. (`PP_SLOW=1`) A stand-in "mod" that breaks xochitl at every boot. Started as soon as xochitl is up (a naive autostart), the stock units reboot the tablet after 34 to 37 s (console: `xochitl.service: Start request repeated too quickly`, `Triggering OnFailure= dependencies`, `rm-emergency.service`, `Rebooting.`), before rm-sanity, and the counter goes 1, 2, 3, then over the limit: a slot switch. The same "mod" behind our wait (an `ExecStartPost` on `pp-agent-boot`): it reboots after 82 to 83 s, the counter is 1 at every boot, no slot switch. After that, `--verify` still passes.

Also checked:

- `systemd-analyze verify --root=<copy of the tatsu systemd tree + agent units + our drop-in>` on `pp-agent-boot.service`, `pp-agent.service`, `pp-agent.timer`: no output, exit 0. A drop-in with a bogus key is reported. `systemctl --root=... is-enabled` gives `masked` for swupdate, update-engine, memfaultd and dropbear-wlan.socket.
- Against a private emulator instance (`pp-emu-tatsu:3.27.2.2` as `pp-device-emu`, SSH on 3097): `device/install.sh` installs, verifies all PASS, and leaves SSH working. That covers the no-overlay path (`/etc/hosts` is a docker bind mount there, written in place) and the emulator's fake `systemctl`.
- In the emulator's 3.27.2.2 UI: Settings > General > Software has **Updates** and **Advanced** switches. Advanced shows "reMarkable beta program", "Retail mode", "Developer mode: Enabled". Switching Updates on shows "Install new software versions as they are released." and "Check for updates", logs `rm.upgrades Error when enabling update engine!` (no systemd there), and writes nothing to `xochitl.conf`, even after a restart. With no systemd, it reads off again after the restart. Settings > Help > Copyrights and licenses > General information shows "...username 'root' and the password '<DeveloperPassword from xochitl.conf>'".
- `tailscaled` v1.80.3, `GOARCH=arm64 CGO_ENABLED=0`, `--tun=userspace-networking`, in a `pp-device-rootfs` container with `--network none`: starts, "Engine created", state `NeedsLogin`; `/dev/net/tun` absent.
- 3.27.1.0's `sw-description.sig` verifies with the key from 3.27.2.2 (`Verified OK`), and its sha256 matches codexctl's index.
- `shellcheck` on every script here: clean.

### Not verified

- Anything on the real tablet. In particular: that `mount -o remount,rw /` works in developer mode on the Pure (u-boot env says no verity; remagic reports it on the Paper Pro family); the `drop_caches` retry when `remount,ro` hits EBUSY (never needed in the test bed after the in-place fix, and the container can't write `/proc/sys` anyway); `rootdev --active` vs `--next-boot` and the other slot's version; `/proc/cmdline`; the real boot ROM limit (the test bed uses 3).
- The Updates switch with update-engine masked on real systemd (expected: off, and switching on fails).
- An AAAA (IPv6) lookup of a blocked name. systemd-resolved can't run in the test bed, so name lookups there went to `/etc/hosts` directly.
- Tailscale login, reachability, battery cost.
- The developer mode flow itself and onboarding without Wi-Fi.

### Open questions for Cedar

- Private overlay for SSH: USB only (recommended), or Tailscale userspace?
- dropbear's stock `-B` and password login over USB: leave as stock (recommended), or key-only (`-s`)? Key-only means a lost key needs the recovery tool.
- `--uninstall` leaves update units unmasked: after it, keep flight mode on unless you want updates.
