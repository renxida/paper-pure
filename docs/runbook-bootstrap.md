# Runbook: bootstrap the tablet

From where the tablet is today (OS 3.27.2.2, not paired, almost empty) to: OS frozen, mods and agent on, notes syncing to our server. Done once, with a USB cable. After this, changes arrive over the air.

Each step says who does it:

- **human**: Cedar, on the tablet or the laptop.
- **Claude**: Claude Code, over SSH. Run Claude Code **on the computer the tablet is plugged into**. A cloud session can't reach the USB link.

`device/install.sh` is safe to re-run at any point: it checks first and only changes what is off. `device/install.sh --verify root@10.11.99.1` changes nothing and says what is wrong.

## 0. Now: keep it off the network (human, 2 min)

1. Turn **flight mode on**: swipe down from the top-right corner, or Settings > General > Flight mode. Leave it on until step 8.
   Why: the stock updater polls every 30 minutes and newer builds exist (3.27.3.0, 3.28, 3.29). Nothing blocks them yet.
2. Open Settings > General > Software. It should say **Version 3.27.2.2**, with no "Tap to restart and update" message.
   - If there is such a message, an update is already downloaded and waits for the next restart. **Don't restart. Don't continue.** Tell Claude. Developer mode restarts the tablet, so the update would land.

## 1. Keep what matters (human)

Developer mode wipes the tablet. It is almost empty (0.25 GB used), so this is probably nothing.

To keep a notebook: plug in USB, turn on Settings > Storage > **USB web interface**, open http://10.11.99.1 on the laptop, download it as PDF. (The menu name is from the 3.27.2.2 UI text; where exactly it sits was not checked.)

## 2. Developer mode (human, about 10 min, wipes the tablet)

1. Settings > General > Software > turn on **Advanced** > **Developer mode**.
2. Confirm, then press the power button twice when asked. The tablet resets to factory state and restarts.
3. Onboarding: pick the language. **Skip Wi-Fi and skip pairing.** Don't connect.
   - If onboarding won't go on without Wi-Fi, stop and tell Claude. (Not known yet: the emulator skips onboarding, so this was never seen.)
4. **Flight mode on again.** The reset cleared it.
5. Find the root password: Settings > Help > Copyrights and licenses > General information, under "GPLv3 Compliance": "...using the username 'root' and the password '...'". Keep it for step 3. It is only needed once.

Checked in the emulator (same 3.27.2.2 UI): the Software > Advanced > Developer mode path, and the password text on that Help page. The enabling flow itself and the wipe were not seen.

## 3. First SSH over USB (human, then Claude)

1. **human**: plug the tablet into the laptop by USB-C. It shows up as a network adapter. The tablet is `10.11.99.1`, and the laptop gets an address from it.
2. **human**: make sure the laptop has an SSH key (`ls ~/.ssh/id_ed25519.pub`; if missing: `ssh-keygen -t ed25519`).
3. **Claude**: `ssh root@10.11.99.1 'cat /sys/devices/soc0/machine; . /etc/os-release; echo $IMG_VERSION'` should print `reMarkable Tatsu` and `3.27.2.2`. It asks for the password. Cedar types it, or reads it out.

## 4. Freeze the OS (Claude)

```bash
device/install.sh --key ~/.ssh/id_ed25519.pub root@10.11.99.1
```

This asks for the password once, then:

- adds the key, so later connections need no password;
- masks the update units: `swupdate`, `swupdate.socket`, `update-engine` (the unit behind the Settings > Software > **Updates** switch), `memfaultd` (it writes swupdate's server address) and `memfault-attributes`;
- sends the update hosts to `0.0.0.0` in `/etc/hosts`;
- keeps SSH off Wi-Fi (masks `dropbear-wlan.socket`, removes the Wi-Fi SSH marker);
- writes all of that to the real root file system under the `/etc` overlay, so it survives reboots;
- ends with `pp-device verify`: every line PASS.

Then prove it survives a reboot:

```bash
ssh root@10.11.99.1 systemctl reboot
# wait about a minute; the USB link comes back
device/install.sh --verify root@10.11.99.1
```

**human**: Settings > General > Software. **Updates** should be off. Try switching it on: it should stay off (or snap back). Tell Claude what you see.

If verify FAILs on "next boot goes to ..." or "swu_status": an update is staged. Stop, and decide with Claude (the fix it prints touches the bootloader).

## 5. The server (Cedar and Claude)

The tablet needs the server for two things: the release feed (agent) and sync (pp-proxy). Follow `server/README.md` and `server/hosting.md`: pick the host, put Cloudflare Tunnel and Access in front, make the tablet's service token.

Then make the tablet's `agent.json` (from `agent/config.example.json`): `feed_url`, `status_url`, and the token in `headers`. It holds a secret: keep it in the password manager, never in the repo.

## 6. Agent and mods (Claude)

```bash
make -C agent build
device/install.sh --agent --release-pub release.pub.pem --agent-json agent.json root@10.11.99.1
```

This installs `pp-agent` under `/home/root/paper-pure` and persists its units, including `pp-agent-tripletap`, the triple-press kill switch. One addition from the device side: `pp-agent-boot` and `pp-agent-tripletap` wait until `rm-sanity` has cleared the boot ROM's error count (about 60 s after boot) before anything can turn mods on. A mod that crashes xochitl then can never make the bootloader switch to the other root slot (see `device/README.md`).

Mods (xovi, AppLoad), from `mods/README.md`:

```bash
mods/build.sh
mods/install.sh root@10.11.99.1     # by hand, for bring-up; tethered: a reboot is stock
```

From then on mods arrive as signed releases through `pp-agent`. Until the first release lands, a triple-press turns these hand-installed mods off with xovi's own `stock` script; turning them on again needs a release (or the command above).

**human**, once a release is on: press the power button three times, each within 3 s of the last. The tablet sleeps and wakes in between, that's fine. A few seconds later the UI restarts without mods (no AppLoad in the side menu). Three more presses bring them back. Tell Claude if it didn't: `ssh root@10.11.99.1 journalctl -u pp-agent-tripletap` shows what the agent saw. (Never checked on hardware yet: whether the press that wakes the tablet is seen.)

## 7. Sync to our server (Claude, then human)

```bash
make -C server tablet-proxy
device/install.sh --proxy root@10.11.99.1     # needs agent.json from step 6
```

This puts `pp-proxy` in front of stock sync: the reMarkable cloud names point at `127.0.0.1`, and the proxy forwards to our server with the tablet's token. It is persisted the same way as the freeze.

Then reboot and verify, as after step 4. A unit that boots wrong shows up here, next to the change, and not weeks later:

```bash
ssh root@10.11.99.1 systemctl reboot
# wait about a minute
device/install.sh --verify root@10.11.99.1    # includes "xochitl waits for nothing of ours"
```

**human**: if a passcode is set (now or ever), the tablet must still show the passcode screen after a reboot. That is the case `--verify` guards: nothing of ours may run before xochitl, because `/home` (where all of ours lives) unlocks only once the passcode is typed into xochitl. See `docs/firmware.md`.

**human**, after step 8 (it needs Wi-Fi): Settings > General > Account > pair, with the one-time code from the rmfakecloud web UI on our server.

## 8. Wi-Fi on (human)

Only after `device/install.sh --verify root@10.11.99.1` passes, including after a reboot (step 4).

Turn flight mode off and join Wi-Fi. SSH stays on USB only.

## 9. Check it end to end (Claude, human for the eyes)

- `device/install.sh --verify root@10.11.99.1`: all PASS.
- `ssh root@10.11.99.1 /home/root/paper-pure/bin/pp-agent status`: the release it runs, and its last check-in.
- The server's tablet status page shows `os_version=3.27.2.2`.
- **human**: write a page in a new notebook. It shows up in the rmfakecloud web UI.
- **human**: AppLoad is in the side menu. Triple-press power: it goes away. Triple-press again: it's back.
- A day later: Settings > General > Software still says 3.27.2.2.

## Getting back to stock

From lightest to heaviest:

| What | How | Cable? |
| --- | --- | --- |
| Mods off now | **Triple-press power.** They stay off, through reboots and new releases, until the next triple-press (updates wait too) | no |
| Mods off, stock UI | **Reboot.** The tablet starts stock; mods come back with a triple-press or the next release | no |
| A bad release | Nothing to do: `pp-agent` rolls back by itself when the health check fails, at install or at the next boot | no |
| Mods off for good | `ssh root@10.11.99.1 touch /home/root/paper-pure/disable`: nothing turns mods on any more (a triple-press only turns them off). Remove the file to undo | USB for SSH |
| Our root fs changes undone | `device/install.sh --uninstall root@10.11.99.1`, then reboot. Updates work again, so keep flight mode on if that's not what you want | USB for SSH |
| Out of developer mode | reMarkable's recovery tool, per support.remarkable.com ("For instructions on how to exit developer mode, visit support.remarkable.com" in Settings). Wipes the tablet again | yes |
| Tablet won't boot at all | Both slots failing puts it in recovery (fastboot) mode: reMarkable's recovery tool over USB | yes |

Prefer mods back after every reboot? One line in `/home/root/paper-pure/agent.json`: `"activate_on_boot": true`. Then a reboot keeps mods; triple-press and the boot-loop guard (3 unhealthy boots, then stock) still work.

## Open questions for Cedar

- Does onboarding after the developer mode reset let you skip Wi-Fi? (Step 2.3.)
- After step 4, what does the Updates switch show, and what happens when you tap it?
- After step 4, `device/install.sh --verify` prints which OS is on the *other* root slot. Worth knowing: a fallback would boot that one.
