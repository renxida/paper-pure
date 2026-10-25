# test/e2e: the whole stack in the emulator

Rung 2 for everything at once. The emulator gets exactly what the tablet gets, through the same scripts, and talks to a local copy of the server. Then one script checks the things that matter: the OS stays frozen, notes sync both ways, releases arrive signed and roll back when broken, the kill switches work, and the tablet reports what it runs.

```bash
test/e2e/run.sh                 # build, reset the emulator, run every step, clean up (~45 min here under qemu)
test/e2e/run.sh --skip-build    # reuse images and mods/out
test/e2e/run.sh --keep          # leave the server, gate and emulator up at the end, to poke at
PP_BUILD_CA=/root/.ccr/ca-bundle.crt test/e2e/run.sh   # behind a TLS-intercepting proxy
```

It prints one line per step (`PASS`, `FAIL` with the reason and the log, or `SKIP` after a failed setup step) and exits 0 only if every step passed. Logs, screenshots and work files go to `${PP_E2E_OUT:-test/e2e/out}` (gitignored). It starts with `ppemu reset`, so it wipes the emulator's notebooks.

Needs: Docker with arm64 (qemu-user binfmt on x86), Node 20+, Go, python3, `ssh`, `curl`, `openssl`, the firmware (`emu/bin/ppemu setup` fetches it), and Qt's `rcc` on the host or the rung-1 image `pp-mods-host` (`apps/hello/test.sh` builds it).

## What runs where

```
host                                              emulator (pp-emu-tablet, stock 3.27.2.2)
 pp-e2e-server (server/ image) 127.0.0.1:3180       xochitl + rm-sync ── /etc/hosts ──> pp-proxy :443
   ppd ── rmfakecloud                                pp-agent (timer, boot, tripletap)
 fakeaccess (stands in for Cloudflare Access) <────  both send the tablet's service token
   on the docker bridge gateway :3181                device/: freeze, persistence, SSH
```

Installed the tablet's way: `device/install.sh --key --agent --release-pub --agent-json --proxy`, over SSH. The release key is a throwaway made per run; its public half is what `device/install.sh` puts on the device. `agent.json` holds only `feed_url`, `status_url` and the token headers; every other agent setting is the default.

## Steps

| Step | What it proves |
| --- | --- |
| `build` | Agent, pp-proxy, the gate, the server image, `mods/build.sh`, the emulator image, the wishes venv |
| `emulator` | `ppemu reset`, `start`, `skip-setup`; Wi-Fi up as xochitl sees it |
| `server` | Server up with one user; the gate refuses without the token (403), lets the token through; the device reaches it |
| `install` | `device/install.sh --agent --proxy` exits 0 with every check PASS; units active; `pp-proxy check` through the gate |
| `freeze` | `--verify` passes; update units masked; the four update hosts resolve to nothing; update-engine never started; Settings > Software shows Updates off, and switching it on fails (`UnitMasked`); no update host in the journal. Starts a DNS monitor (`resolvectl monitor`) |
| `sync` | Pair the stock UI (Settings > General > Account > Pair, code from rmfakecloud's web API, typed on the on-screen keyboard); draw in a new notebook; the page's exact bytes land in rmfakecloud; `tools/wishes` renders the server's copy with the strokes where they were drawn; a PDF uploaded on the server appears on the device; pp-proxy saw no 4xx/5xx |
| `ota` | A release built from `mods/out/release` + `apps/hello` (built with the release id), signed, published to ppd through the gate with `server/scripts/publish.sh`; `pp-agent.service` installs it and Hello shows the id (`mods/emu-smoke.sh`). Then: no `appload.so` → rolled back; signed by another key → refused; tarball changed after signing → refused; built for 3.27.3.0 → refused. Mods stay on throughout |
| `killswitch` | Three power presses (0.6 s apart) turn mods off, three more turn them back on, health-checked |
| `reboot` | `ppemu reboot` comes back stock (`activate_on_boot` is off), release still installed; `--verify` passes again; Updates still off; sync still works; no update host was looked up before the reboot |
| `disable` | With `paper-pure/disable`, three presses leave mods off and `pp-agent.service` is skipped |
| `status` | The agent's reports are in ppd, read through the gate with the token (403 without): latest release and OS, and one report each for installed, rolled back, forged, tampered, wrong OS. No update host looked up since the reboot |

Each step runs under a time limit (`timeout`, whole process group); see `STEPS` in `run.sh`. A failed setup step (`build` to `install`) skips the rest; the others carry on, so one run shows every breakage.

## Things the emulator had to learn for this

- **Wi-Fi as xochitl sees it.** xochitl's csl wifi library asks wpa_supplicant (D-Bus) and networkd's `OnlineState`. With both masked, xochitl said "Pairing with the cloud requires a Wi-Fi connection" and rm-sync never ran. `emu/daemon/rmemu-wifi.c` now answers both (one open network, `pp-emu`, connected while `wlan0` has the default route). See `emu/README.md`.
- The real wpa_supplicant's `wired` driver gets to `completed` on the veth (once `allmulti` is set), but its `SignalPoll` fails and the library reads that as disconnected; networkd can't start under qemu-user ("Could not set up manager: Protocol not supported") and lacks `CAP_NET_ADMIN`. So: a fake, not the real daemons.

## Status

Not run yet in full; see below as it fills in.
