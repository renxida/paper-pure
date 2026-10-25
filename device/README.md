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
| `tablet/wait-sanity.sh`, `tablet/wait-sanity.conf` | Mods wait for `rm-sanity` at boot: the drop-in goes on `pp-agent-boot`, `pp-agent-tripletap` and `pp-agent` (see "Never brick") |
| `test/run.sh`, `test/testbed/` | The stand-in tablet and the scenarios |

On the tablet, everything of ours is under `/home/root/paper-pure/device/`: the scripts, `managed.list` (every root fs path we changed) and `stock/` (the stock copy of each, taken before the first change).

## How updates are frozen

Everything on 3.27.2.2 that can update the OS, found in the root fs:

| Piece | What it does | How we stop it |
| --- | --- | --- |
| xochitl, Settings > General > Software > **Updates** | The switch *is* `update-engine.service`. xochitl enables, starts, stops and disables that unit over systemd's D-Bus API, and shows the switch on only when the unit is "enabled" (strings: `update-engine.service`, `update-engine status:`, `EnableUnitFiles`, `Error when enabling update engine!`). Seen in the emulator: switching it on calls out to enable the engine and does not touch `xochitl.conf` | Mask `update-engine.service`. The switch reads off; switching it on fails (`UnitMasked`), though it shows on until xochitl restarts |
| `update-engine.service` | `fakeupdateengine_service`, D-Bus `no.remarkable.update1`. Talks to swupdate over its IPC socket (`swupdate-ipc`) | Masked |
| `swupdate.service`, `swupdate.socket` | The installer. Suricatta mode with `-d` (no polling of its own, waits for IPC) and `-x` (no TLS verification!). Socket-activated on `/tmp/sockinstctrl` | Both masked |
| `memfaultd.service` | Writes `/tmp/swupdate.cfg`, swupdate's server config, from its `base_url` `https://device.cloud.remarkable.com`; `swupdate.service` is `PartOf` it. Also telemetry | Masked, plus `memfault-attributes.service` so it doesn't fail every boot |
| `rm-apply-ota.service` | At reboot, switches slots if an update was installed (`swu_status` 1) | Left alone: inert while swupdate can't run |
| `systemd-sysupdate.timer` | Stock systemd | Not enabled on tatsu, no transfer definitions |
| `mdm-agent` | `enterprise.cloud.remarkable.com`; a policy can force updates ("Company policy enforces automatic software updates") | Host blocked |

Hosts in `tablet/freeze.hosts` (`0.0.0.0`): `device.cloud.remarkable.com` (memfaultd, so suricatta), `device.memfault.com` (memfaultd's built-in default), `enterprise.cloud.remarkable.com` (MDM), and `remarkable-software.s3.us-east-2.amazonaws.com` (where the `.swu` files live; not on the tablet, blocked in case an update server hands out its URLs). The tablet resolves names through systemd-resolved, which reads `/etc/hosts` (`ReadEtcHosts` is not turned off in `resolved.conf.d`). There is no `iptables` binary on the tablet (the netfilter modules are there), so no firewall layer.

reMarkable's cloud is unused (desiderata row 5): sync goes through `pp-proxy` (its 13 names point at `127.0.0.1`), and the other reMarkable names in `xochitl`, `rm-sync` and `user-authenticator-cli` go to `0.0.0.0` too, in the same block: `auth.remarkable.com` (accounts), `errors.cloud.remarkable.com`, `retail.cloud.remarkable.com` (the store) and `www.remarkable.com`. Their dev, qa and stage twins are not blocked; public builds (`BUILD_MODE_RM="public"`) don't use them.

Not used: an `AutoUpdate` key exists in xochitl's settings code, but the Updates switch does not write it (checked in the emulator), so we don't touch `xochitl.conf`.

## How it persists

- In developer mode `/` is plain ext4: u-boot's environment boots `root=/dev/mmcblk0pN` when `unlocked=yes`, and `/dev/dm-0` through dm-verity otherwise (read from `u-boot.itb`). It is mounted read-only and can be remounted read-write.
- `/etc` is an overlay with a tmpfs upper (`var-volatile-etc.service`). A plain write to `/etc` is gone at reboot.
- `pp-device.sh` writes both views. Live, through the overlay, so it works now. And in the real root fs, through a non-recursive bind mount of `/` (`mount --bind / /run/pp-device/root` shows the ext4 under the overlay), with `/` remounted read-write for the write and read-only right after. This is remagic's `persist_local_to_rootfs` trick. It does not `umount -R /etc` (rmfakecloud-proxy's and xovi-tripletap's way), which also drops the bind mount holding dropbear's host key and breaks new SSH connections until a reboot.
- **Files in the root fs are rewritten in place, never replaced.** Replacing (`mv`, `sed -i`) unlinks the old inode while the `/etc` overlay still holds it, and then `mount -o remount,ro /` fails with EBUSY until the next reboot. Found in the test bed, and reproduced on purpose with `sed -i`.
- **Not during early boot.** `pp-device.sh` waits until systemd is past `initializing` (basic.target). Before that the `/etc` overlay and the `/etc/dropbear` bind may not be up yet, a write lands in the wrong layer, and SSH can die until the next reboot. Seen once in the test bed (below).
- It survives reboots. It does not survive a slot switch: an OTA or the boot ROM's fallback boots the *other* root partition, which has none of this. `verify` prints which OS that slot holds.

## Never brick

- **Mods wait for rm-sanity.** The boot ROM counts boot attempts per slot and switches slot past a limit (SPL strings: `ABINFO: A (ecnt = %u)`, `A in error state, switch to B`, and with both slots bad, recovery mode, which needs a cable). `rm-sanity.service` clears the count 60 s after boot. If a mod crashes xochitl before that, the stock units (`StartLimitBurst=4`, `OnFailure=emergency.target`, `rm-emergency.sh` reboots) loop the tablet, and the count climbs to a slot switch onto an unfrozen OS. So the three units that can turn mods on, `pp-agent-boot.service`, `pp-agent-tripletap.service` and `pp-agent.service` (an install), get a drop-in: `ExecStartPre=wait-sanity.sh` waits until `rm-sanity` has run this boot and `root<slot>_errcnt` is 0, up to 5 minutes, else that unit fails (the triple-press service retries, the timer tries again in 30 minutes). A mod crash loop then costs at most one reboot per try with the count at 1, and the agent rolls the release back (`agent/README.md`, "Why a crash loop can't brick it").
- The wait has a cost: `pp-agent-boot` is a oneshot wanted by `multi-user.target`, so `multi-user.target` is reached about 60 s after boot instead of about 20 s. Nothing of reMarkable's is ordered after it (only stock `graphical.target` and `systemd-boot-check-no-failures`, neither used). xochitl starts as before.
- **Nothing of ours before xochitl.** With a passcode set, `/home` unlocks only once the passcode is typed into xochitl, and every unit of ours lives on `/home`. A unit ordered `Before=xochitl` (pp-proxy had one) makes xochitl wait for `/home`; its 60 s `JobTimeoutSec` runs out, `OnFailure=emergency.target` reboots, every boot, and no UI ever appears to type the passcode into. Only the recovery tool gets out. `verify` fails if any `pp-*` unit is in xochitl's ordering (`systemctl list-dependencies --after`), and the test bed boots with a passcode stand-in (scenario 10). See `docs/firmware.md`.
- **Kill switches, no cable needed.** Triple-press power toggles mods (`pp-agent-tripletap.service`, persisted here like the other agent units). Reboot is stock (`activate_on_boot` is false by default). A failing release rolls back by itself. Over SSH: `touch /home/root/paper-pure/disable`, and nothing turns mods on.
- **Undo.** `--uninstall` restores every path in `managed.list` from `stock/`.
- **Never half-way.** `install` checks everything it needs before it changes anything: model, OS, developer mode, no OS update staged or running (`swu_status` 0), its own files, and the agent's and proxy's units, CA and hosts. If any check fails, it prints `preflight failed; nothing changed`. Each `swu_status` value prints what it means and what to do. Then it stops the update services and reads `swu_status` again. An update that started in between stops it there, with the root fs untouched. It ignores SIGHUP and SIGPIPE and logs to `/home/root/paper-pure/device/install.log`, so an SSH session that drops (cable out, laptop asleep) doesn't stop it half-way. Before, it died of SIGPIPE at its next line of output; cut during the writes, that left one unit masked and no message. If it still stops mid-write (an I/O error), it prints `INCOMPLETE: ...`, and `/` goes back to read-only as on every exit. The freeze comes first and our units after it, and each change it made is safe on its own. Run install again to finish. It does not roll back: going back to stock is `--uninstall`.

## SSH is private

- Over USB only, as stock: `dropbear-usb0.socket` binds to `usb0` (10.11.99.1).
- Over Wi-Fi: stock already keeps it off unless `/data/internal/rm_enable_ssh_wifi_marker` exists (`rm-ssh-over-wlan on` creates it). We remove the marker and mask `dropbear-wlan.socket`, so even `rm-ssh-over-wlan on` can't turn it on.
- Login: key from `--key`. The developer-mode password stays as the fallback. It is shown on the tablet's screen and only works over the cable. dropbear runs with `-B` (blank passwords allowed) from `/etc/default/dropbear`; root has a password in developer mode (xochitl sets it from `DeveloperPassword` with `usermod`), so we leave that as stock.
- **Private overlay: not now.** The tablet kernel has no TUN driver and no WireGuard (neither in `modules.builtin` nor as a module), so kernel WireGuard and kernel-mode Tailscale are out. Tailscale in userspace mode needs neither: `tailscaled --tun=userspace-networking` (a static arm64 build, 24 MB) starts on the 3.27.2.2 userland with no `/dev/net/tun` and waits for login. Developer mode also drops module signature enforcement, so a WireGuard module built from reMarkable's kernel sources would load; that is more to maintain.
- **Recommendation:** USB only. Routine changes go over the air through pp-agent, which only calls out. If a remote shell is ever needed, add Tailscale in userspace mode (one binary under `/home`, one unit persisted with `pp-device.sh persist`, ACLs to Cedar's devices). Cedar decides.

## Writing feel stays stock

Nothing here touches xochitl, its unit, the pen or display stack. We stop update and telemetry daemons and edit `/etc/hosts`. `memfaultd` also collected process metrics every 10 s; that's gone.

## For other lanes

- `pp-device.sh persist PATH...` copies PATH as it is live into the real root fs (backing up stock first). `pp-device.sh restore PATH...` puts it back, and refuses a path it never persisted (it has no stock copy of it, and deleting it could delete a stock file). Use these instead of `umount -R /etc`.
- **agent**: `agent/install.sh` uses only `cp`, `chmod` and `mv` (the tablet has no `install(1)`), and `install.sh --agent` copies every unit in `agent/systemd/`. `pp-device.sh` persists the four units, their wants links and the rm-sanity drop-ins (`AGENT_UNITS`, `WAIT_UNITS`).
- **server**: `device/install.sh --proxy` runs `tablet-proxy/install.sh --runtime`, then persists the unit, its `multi-user.target.wants` link, the `# pp-proxy` hosts block (from `pp-proxy hosts`) and the CA bundle with `pp-device.sh`. `tablet-proxy/install.sh` has no persistent mode any more.
- **mods**: the triple-press is `pp-agent tripletap`, not xovi-tripletap (whose `enable.sh` does `umount -R /etc`).

## Status

### CI: the test bed was online and got a real OS update (Oct 25, 2026, night)

On GitHub's arm64 runners the test bed failed in 4 of 6 runs (13, 14, 16, 18). `install` exited 1 and nothing persisted. Run 18 printed why, because `run.sh` now shows a failed install's own lines and the test bed's update journal:

- The install printed `FAIL swu_status=3` and `ERROR preflight failed; nothing changed`.
- Just before that, the journal had:
  - `fakeupdateengine_service: DOWNLOAD ... 161766400 ... "3.29.0.153"`
  - `swupdate: RUN Installation in progress`
  - `realpath: /dev/disk/by-partlabel/root_a: No such file or directory`
  - `Installation failed !`

What happened and what changed:

- **Cause: a test bed artifact.** On the runner the test bed had a network. Stock memfaultd writes swupdate's server config (`https://device.cloud.remarkable.com/api/v0/hawkbit`) before it dies, and update-engine asks swupdate to check. reMarkable's production server offered 3.29.0.153 to the fresh random device id in some runs and not in others. Its install failed in the container (no eMMC) and left `swu_status=3`. Under qemu in the dev container the test bed has no DNS, so this never happened there.
- **The product did the right thing.** `install` refused before touching anything: `/` stayed read-only, no bind was left, and no mask or hosts block was written. It was not a half-way install. A real tablet left online would refuse the same way, and rightly: with `swu_status=1` the next boot runs the new slot, which has no freeze.
- **Test bed fix:** `--network none`, like the tablet in flight mode until it is frozen (runbook step 0). SSH goes in through `docker exec ... nc 127.0.0.1 22`. Step 1 checks that the test bed is offline and that preflight passes. CI no longer registers a new device with reMarkable or downloads 160 MB per run.
- **Product fixes in `pp-device.sh`** (see Never brick, "Never half-way"):
  - Each `swu_status` value says what it means and what to do.
  - It reads `swu_status` again after stopping the update services.
  - It outlives a dropped SSH session and logs to `device/install.log`.
  - The agent's and proxy's inputs are checked in preflight.
  - `real_open` marks itself open before the remount, so a failed bind can't leave `/` read-write.
  - `device/install.sh` says so when the link drops (ssh exit 255).
- **New scenarios:**
  - 1b: `swu_status=3`. Install refuses, says what to do, and nothing changes live or in the root fs.
  - 1c: a stand-in update is cut off when install stops swupdate and leaves 7. Install stops with the root fs untouched.
  - 1d: a reboot, and the stock updater clears the flag.
  - 7: the reinstall's output is cut after two lines. It still runs to the end, and its log says all checks passed.

Results:

- On GitHub, run 19 (`440bb5a`, the fix) passed end to end, as user `runner` on native arm64. The device test bed took 687 s.
- In the dev container (root, qemu, cgroup v1), scenarios 1 to 7 and 9a to 9c gave 73 checks, 0 failed. A tool time limit cut that run off in 9c.
- The mechanism of the dropped session, shown in a plain tatsu container (`pp-device.sh install | head -n 2`):
  - The old script ends at its third line with `pipeline rc=141`.
  - The new one runs to the end: 6 masks, the hosts block, 10 managed paths, and its log ends with the verdict.

### Review fixes (Oct 25, 2026, evening)

`PP_NAME=pp-harden-tb PP_PORT=3194 device/test/run.sh`: **97 passed, 0 failed**, 45 minutes under qemu, half of it next to a rung 2 run, no container or volume left. New since the 84 of the second pass:

- **10. A passcode.** `boot.sh` moves the `/home` volume aside; `home.mount` (a bind, `nofail` like the tablet's fstab) waits for a stand-in that runs the same `systemd-ask-password --accept-cached --keyname=userpin --id=homekey --timeout=0` homekey does. With every unit of ours installed: xochitl active 18 s after boot with `/home` locked, still the same boot at 100 s, the console never says its start job timed out; `pp-proxy`, `pp-agent-boot` and `pp-agent-tripletap` wait for `home.mount`. "Typing the passcode" (ending systemd-ask-password): `/home` mounts, SSH is back, pp-proxy runs, `pp-agent boot` runs after rm-sanity, `--verify` passes.
  - The same stand-in with the old unit (`Before=xochitl`, from git) reproduces the review's finding: xochitl's job waits, then `xochitl.service: Job xochitl.service/start timed out`, `Rebooting.` after 77 s. With the new unit, xochitl is up at 22 s and stays (`scratch work-harden/pc/run.sh`, both variants).
  - `verify` now fails if any `pp-*` unit is in xochitl's ordering (`systemctl list-dependencies --after --all`). In the emulator: the old pp-proxy unit, enabled, shows up there; the new one doesn't. It passes in every verify of this run and of rung 2.
- **7. Reinstall over a crash-looping memfaultd.** `boot.sh` makes memfaultd restart every second with no start limit (`$STATE/memfaultd-loop`). It restarted 66 times, then 69 ten seconds later; `install` exited 0, the test bed stayed up, and memfaultd ended `inactive, masked` (stopped before masking). The old order (mask, reload, then stop; `git show 1f13ecc^`) leaves it `failed, masked` in 2 of 2 tries by hand; PID 1 survived those too, so the abort the CI lane saw is a race this does not force.
- `pp-agent.service` (an install) now waits for rm-sanity too: its drop-in is persisted and checked by `verify` (scenario 6).
- The four extra blocked names resolve to nowhere (`verify` in rung 2: `resolves to no address (systemd-resolved, A and AAAA): auth.remarkable.com`, and the other three).
- `restore` refuses a path it never persisted. In a plain container: `pp-device.sh restore /etc/issue` gives `ERROR /etc/issue: not managed by pp-device`, exit 1, and the file is untouched (before: deleted, `CHANGE /etc/issue (stock)`). The test bed checks it too (scenario 5): `make proofs` afterwards gave **98 passed, 0 failed** in 43 min under qemu, alone.

### Fixed by the e2e lane (Oct 25, 2026)

`--verify` failed on the systemd emulator, and would on the tablet, with `device.cloud.remarkable.com resolves to '?', not 0.0.0.0` for all four blocked names. The tablet resolves through systemd-resolved (`hosts: resolve [!UNAVAIL=return] files` in `nsswitch.conf`), and resolved answers a `0.0.0.0` hosts line with "no address" (NODATA), not with `0.0.0.0`; the test bed has no resolved, so it never showed there. The check now also passes when `resolvectl query -t A` and `-t AAAA` both say `does not have any RR of the requested type`.

- In the emulator after `install`: `PASS    resolves to no address (systemd-resolved, A and AAAA): device.cloud.remarkable.com` (and the other three), `pp-device: all checks passed`.
- Negative: with the `device.memfault.com` line removed from the live `/etc/hosts`, `--verify` exits 1 with `device.memfault.com resolves to '?', not 0.0.0.0` (plus the stale-block and drift FAILs). An unblocked name gets `Name ... not found`, not NODATA, so it can't pass by accident.
- AAAA lookups of the blocked names (unverified before) also return NODATA through resolved.
- `test/e2e/run.sh` runs `--verify` after install and after a reboot.

### Verified: kill switch and crash loops (Oct 25, 2026, second pass)

`PP_NAME=pp-killswitch-it PP_PORT=3194 device/test/run.sh <extracted 3.27.2.2 rootfs>`: **84 passed, 0 failed**, 27 minutes, on the final files (scenarios 1 to 7 as below, plus 9; it leaves no container or volume behind). Scenario 9 is the real arm64 `pp-agent` under the test bed's systemd 255, with `mods/release/hooks/*.sh` as shipped and upstream's `xovi/start` and `xovi/stock` at the pinned commit (stub hashtab, no `xovi.so`; the stand-in xochitl crashes when it runs with xovi preloaded and the live tree says so). The power key is a FIFO the agent reads; the test writes `struct input_event` records into it.

- **6.** `pp-agent-tripletap` runs from the persisted unit and started after `rm-sanity` exited (monotonic timestamps: 5 s after). `--verify` reports it, and the two `wait-sanity` drop-ins.
- **7.** After `--uninstall`, `pp-agent-tripletap` is no longer enabled.
- **9a. Install** of release `tb1` through the real `pp-agent.service`: upstream's tmpfs drop-in on `/etc/systemd/system/xochitl.service.d` works on top of the `/etc` overlay and reaches xochitl (`LD_PRELOAD=/home/root/xovi/xovi.so` and the release's own variable in `/proc/<MainPID>/environ`), and `/run/paper-pure/live` says `tb1`.
- **9b, 9c. Triple-press.** 3 presses: "tripletap: mods off (tb1)", xochitl runs stock, the drop-in is unmounted, `live` is gone. 2 presses: nothing. 3 more: "mods on (tb1)", through `activate.sh` and the health check.
- **9d. Reboot returns stock.** `pp-agent boot` logs "activate_on_boot is off", xochitl runs stock; the triple-press service started after `rm-sanity`; 3 presses bring `tb1` back.
- **9e. Install-time crash loop, 5 s per crash:** the health check saw the first new PID 6 s after `activate.sh` and rolled back to `tb1` (2 crashes in all). `tb2` marked failed, `tb1` live again, same boot, `rm-emergency` never started.
- **9f. Install-time crash loop, instant:** the start limit came first. Console: `xochitl.service: Start request repeated too quickly`, `Triggering OnFailure= dependencies`, `rm-emergency.service`, `Rebooting.` The agent got SIGTERM 5 s into its check, logged "interrupted before its health check passed; the next run rolls it back" and ran no hooks. After the reboot `pp-agent boot` rolled `tb3` back: `tb1` committed, `tb3` failed, nothing pending. The boot counter was 1 at that boot; no slot switch.
- **9g. Boot-time crash loop** (`activate_on_boot: true`, `tb1` broken on purpose): `pp-agent boot` activated it, saw the loop, logged "tb1 unhealthy at boot (1/3)" and ran stock; no emergency reboot, counter 1.
- **9h. The `disable` file:** with it, 3 presses turn mods off, 3 more say "mods already off"; `pp-agent.service` is skipped (`ConditionResult=no`).
- `systemd-analyze verify --root=<copy of the tatsu systemd tree>` on the four agent units with both `wait-sanity.conf` drop-ins: no output, exit 0 (host systemd 255). A typo'd copy is reported.
- `device/install.sh --agent` runs `agent/install.sh` with plain `sh` and no `install(1)` shim (`shim/` is gone).
- A race seen once (run 3 of 4): the test bed answered SSH while systemd was still `initializing`, `install` ran before the stock `/etc` overlay and `/etc/dropbear` bind were up, and SSH stayed dead until a forced reboot (scenarios 2 and 3 failed, the rest passed). Fixed in `pp-device.sh` (waits out early boot) and in `run.sh`'s `boot` (waits for it too). The same race is possible on the tablet right after a reboot.
- Flake seen once: under qemu load dropbear missed ssh's 10 s banner timeout (`Connection timed out during banner exchange`), which killed a run with exit 255. `run.sh`'s `dev` and `install.sh`'s fresh-connection check now retry that.
- Logs of the final run: scratch `work-pp-killswitch/tb4/` (not in the repo).

### Verified (Oct 25, 2026, x86_64 dev container, qemu-user for arm64)

The test bed (`test/testbed/`) is the real 3.27.2.2 root fs running its own systemd 255 as PID 1 in a container, laid out like the tablet: `/` read-only, `/etc` overlaid by the image's own `var-volatile-etc.service`, `/etc/dropbear` bound from `/home` by the stock `etc-dropbear.mount`, the stock dropbear behind the stock developer-mode check, persistent `/home` and `/data` volumes, and a fake boot ROM counter (`lpgpr`) that survives reboots. A reboot is the container stopping and starting. Differences from the tablet: xochitl is a stand-in that pets the watchdog; memfaultd and systemd-resolved can't run there; hardware units are masked in `/run` only.

`PP_SLOW=1 device/test/run.sh <extracted 3.27.2.2 rootfs>`: **48 passed, 0 failed**, about 25 minutes. Re-run without `PP_SLOW` on the final files: **44 passed, 0 failed**, about 7 minutes, and it leaves no container or volume behind. What it shows:

1. On a stock test bed, `--verify` exits 1, flags the unmasked units and the missing hosts block, and changes nothing. Stock memfaultd starts.
2. `install` exits 0 and ends with every check PASS; a fresh key-only SSH connection works; `/` is read-only again; no bind mount is left; `/etc/dropbear` is still mounted; `device.cloud.remarkable.com` resolves to `0.0.0.0` (busybox `wget` prints the address); the stock hosts lines are kept.
3. A second `install` changes nothing (0 `CHANGE` lines).
4. After a reboot, `--verify` passes. The overlay's tmpfs upper holds none of our files, so it all comes from the root fs. `swupdate`, `update-engine` and `memfaultd` never left "inactive" that boot. rm-sanity clears the counter.
5. Drift: a live-only unmask is caught (and reported as live vs root fs drift); a root-fs-only edit of `/etc/hosts` is caught; the Wi-Fi SSH marker is caught. `install` repairs all three.
6. `--agent --proxy`: exits 0 and `/` goes back to read-only. After a reboot, `--verify` passes with the agent and proxy checks; `pp-proxy.service` runs from the persisted unit; `my.remarkable.com` resolves to `127.0.0.1`; the proxy's CA is in the live bundle; `pp-agent.timer` is active; `wait-sanity.sh` logs "rm-sanity done, roota_errcnt=0 after 34s"; `pp-agent boot` started 3 s after `rm-sanity` exited (monotonic timestamps), and logged "boot: stock (no release installed)".
7. `--uninstall`, then reboot: verify fails again (stock), `swupdate.service` is enabled, no freeze block, stock hosts lines intact, `pp-agent-boot` not enabled. `install` brings it all back.
8. (`PP_SLOW=1`, first pass only) A stand-in "mod" that breaks xochitl at every boot. Started as soon as xochitl is up (a naive autostart), the stock units reboot the tablet after 34 to 37 s (console: `xochitl.service: Start request repeated too quickly`, `Triggering OnFailure= dependencies`, `rm-emergency.service`, `Rebooting.`), before rm-sanity, and the counter goes 1, 2, 3, then over the limit: a slot switch. The same "mod" behind our wait (an `ExecStartPost` on `pp-agent-boot`): it reboots after 82 to 83 s, the counter is 1 at every boot, no slot switch. After that, `--verify` still passes.
9. Kill switch and crash loops: see the second-pass section above.

Also checked:

- `systemd-analyze verify --root=<copy of the tatsu systemd tree + agent units + our drop-in>` on `pp-agent-boot.service`, `pp-agent.service`, `pp-agent.timer`: no output, exit 0. A drop-in with a bogus key is reported. `systemctl --root=... is-enabled` gives `masked` for swupdate, update-engine, memfaultd and dropbear-wlan.socket.
- Against a private emulator instance (`pp-emu-tatsu:3.27.2.2` as `pp-device-emu`, SSH on 3097): `device/install.sh` installs, verifies all PASS, and leaves SSH working. That covers the no-overlay path (`/etc/hosts` is a docker bind mount there, written in place) and the emulator's fake `systemctl`.
- In the emulator's 3.27.2.2 UI: Settings > General > Software has **Updates** and **Advanced** switches. Advanced shows "reMarkable beta program", "Retail mode", "Developer mode: Enabled". Switching Updates on shows "Install new software versions as they are released." and "Check for updates", logs `rm.upgrades Error when enabling update engine!` (no systemd there), and writes nothing to `xochitl.conf`, even after a restart. With no systemd, it reads off again after the restart. Settings > Help > Copyrights and licenses > General information shows "...username 'root' and the password '<DeveloperPassword from xochitl.conf>'".
- `tailscaled` v1.80.3, `GOARCH=arm64 CGO_ENABLED=0`, `--tun=userspace-networking`, in a `pp-device-rootfs` container with `--network none`: starts, "Engine created", state `NeedsLogin`; `/dev/net/tun` absent.
- 3.27.1.0's `sw-description.sig` verifies with the key from 3.27.2.2 (`Verified OK`), and its sha256 matches codexctl's index.
- `shellcheck` on every script here: clean.

### Not verified

- Anything on the real tablet. In particular: that `mount -o remount,rw /` works in developer mode on the Pure (u-boot env says no verity; remagic reports it on the Paper Pro family); the `drop_caches` retry when `remount,ro` hits EBUSY (never needed in the test bed after the in-place fix, and the container can't write `/proc/sys` anyway); `rootdev --active` vs `--next-boot` and the other slot's version; `/proc/cmdline`; the real boot ROM limit (the test bed uses 3).
- The Updates switch with update-engine masked on the real tablet. In the emulator (real systemd 255): it reads off; switching it on logs `Error when enabling update engine! "org.freedesktop.systemd1.UnitMasked"` and the unit stays masked and inactive, but the switch then shows on (and "Check for updates" spins, reaching nothing) until xochitl restarts; after a reboot it reads off again. `test/e2e` checks this.
- An AAAA (IPv6) lookup of a blocked name in the test bed (systemd-resolved can't run there). In the emulator it returns no address (see above).
- Tailscale login, reachability, battery cost.
- The developer mode flow itself and onboarding without Wi-Fi.
- Scenario 9 with the real `xovi.so` and real xochitl (the test bed has a stand-in), and `PP_SLOW=1` (scenario 8) on this pass's files.
- A real power key: the test writes events into a FIFO. See `agent/README.md` for what is unknown on hardware.

### Open questions for Cedar

- Private overlay for SSH: USB only (recommended), or Tailscale userspace?
- dropbear's stock `-B` and password login over USB: leave as stock (recommended), or key-only (`-s`)? Key-only means a lost key needs the recovery tool.
- `--uninstall` leaves update units unmasked: after it, keep flight mode on unless you want updates.
