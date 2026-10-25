# test/e2e: the whole stack in the emulator

Rung 2 for everything at once. The emulator gets exactly what the tablet gets, through the same scripts, and talks to a local copy of the server. Then one script checks the things that matter: the OS stays frozen, notes sync both ways, releases arrive signed and roll back when broken, the kill switches work, and the tablet reports what it runs.

```bash
test/e2e/run.sh                 # build, reset the emulator, run every step, clean up (~25 min here under qemu)
test/e2e/run.sh --skip-build    # reuse images and mods/out
test/e2e/run.sh --keep          # leave the server, gate and emulator up at the end, to poke at
PP_BUILD_CA=/root/.ccr/ca-bundle.crt test/e2e/run.sh   # behind a TLS-intercepting proxy
```

It prints one line per step (`PASS`, `FAIL` with the reason and the log, or `SKIP` after a failed setup step), a `....` heartbeat with the log's last line every minute while a step runs, and for a failed step its `FAIL` lines and the last 80 lines of its log. It exits 0 only if every step passed. Logs, screenshots and work files go to `${PP_E2E_OUT:-test/e2e/out}` (gitignored). It starts with `ppemu reset`, so it wipes the emulator's notebooks.

Needs: Docker with arm64 (qemu-user binfmt on x86), Node 20+, Go, python3, `ssh`, `curl`, `openssl`, the firmware (`emu/bin/ppemu setup` fetches it). Hello is rebuilt per release id with Qt's `rcc`: the host's if it has one, else the Qt stage of `mods/build/Dockerfile` (cached by `mods/build.sh`), loaded as `pp-e2e-qt`. Ports: `PP_E2E_PORT` (3180) and the next one.

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
| `ota` | Stops `pp-agent.timer` first, so every agent run is the step's own (a timer run once installed the release before the step asked, and the step saw "up to date"). A release built from `mods/out/release` + `apps/hello` (built with the release id), signed, published to ppd through the gate with `server/scripts/publish.sh`; `pp-agent.service` installs it (state and agent log, not just the command's output), its checks pass including `30-appload.sh`, and Hello shows the id (`mods/emu-smoke.sh`); a second run re-checks the live release (`checks.reason` `recheck`). Then: no `appload.so` → rolled back; signed by another key → refused; tarball changed after signing → refused; built for 3.27.3.0 → refused. Mods stay on throughout |
| `killswitch` | Three power presses (0.6 s apart) turn mods off, three more turn them back on, health-checked |
| `reboot` | `ppemu reboot` comes back stock (`activate_on_boot` is off), release still installed; `--verify` passes again; Updates still off; sync still works; no update host was looked up before the reboot |
| `disable` | With `paper-pure/disable`, three presses leave mods off and `pp-agent.service` is skipped |
| `status` | The agent's reports are in ppd, read through the gate with the token (403 without): latest release and OS, and one report each for installed, rolled back, forged, tampered, wrong OS. The latest carries pp-proxy's sync health (a last good sync, 0 errors), and `/pp/problems` is empty. No update host looked up since the reboot |

Each step runs under a time limit (`timeout`, whole process group); see `STEPS` in `run.sh`. The limits are for native arm64 and add up to 72.5 min, under `make rung2`'s 75; under qemu both are 4 times that. A failed setup step (`build` to `install`) skips the rest; the others carry on, so one run shows every breakage.

## Things the emulator had to learn for this

- **Wi-Fi as xochitl sees it.** xochitl's csl wifi library asks wpa_supplicant (D-Bus) and networkd's `OnlineState`. With both masked, xochitl said "Pairing with the cloud requires a Wi-Fi connection" and rm-sync never ran. `emu/daemon/rmemu-wifi.c` now answers both (one open network, `pp-emu`, connected while `wlan0` has the default route). See `emu/README.md`.
- The real wpa_supplicant's `wired` driver gets to `completed` on the veth (once `allmulti` is set), but its `SignalPoll` fails and the library reads that as disconnected; networkd can't start under qemu-user ("Could not set up manager: Protocol not supported") and lacks `CAP_NET_ADMIN`. So: a fake, not the real daemons.
- **PDFs crashed xochitl.** Once the PDF from the server had synced down, xochitl segfaulted in the shim every time it rendered the page (5 times in 15 minutes, then the stock start limit rebooted the "tablet", and every boot after that crash-looped the same way). The shim took the PDF page's pdfium bitmap, wrapped as a full-screen QImage, for the screen, then read it after it was freed. Screenshots went blank first. Fixed in `emu/shim/fb.c`: only a full-screen image with no cleanup function, in xochitl itself, is the screen.
- On the way, `device/tablet/pp-device.sh --verify` learned that systemd-resolved answers a `0.0.0.0` hosts line with "no address" (see `device/README.md`).

## What 3.27.2.2 does with rmfakecloud

The riskiest piece, so in detail. rmfakecloud is the server image's pinned commit `3c6de006`, unmodified; upstream tests it only to 3.27.1. Everything below went through pp-proxy on the device and the fake Access gate, all 2xx, nothing to a name outside pp-proxy's list (`pp-proxy refused nothing`, and the DNS monitor saw only `internal.cloud.remarkable.com`, `local.appspot.com`, `eu.tectonic.remarkable.com`, `ping.remarkable.com`).

| Works | How it looked |
| --- | --- |
| Pairing from the stock UI | 8-letter code from `/ui/api/newcode`; `GET /discovery/v1/endpoints` (internal.cloud), `POST /token/json/2/device/new` and `/user/new` (local.appspot.com, from discovery); Account page then says "cedar@example.invalid (via https://local.appspot.com)" |
| Upload | `GET /sync/v4/root`, `PUT /sync/v3/files/<sha256>`, `PUT /sync/v3/root` on eu.tectonic, 6 to 20 s after closing the notebook. rm-sync runs schema `hashOfHashesV3`. The page's `.rm` is in rmfakecloud byte for byte, and `tools/wishes` renders it from there with the strokes where they were drawn |
| Download | A PDF uploaded in the web UI is on the device 1 to 3 s later: the `/notifications/ws/json/1` websocket tells rm-sync, which GETs the root and files |
| After a reboot | Still paired, pp-proxy back from the persisted unit, a new server document arrives |
| Side traffic | `/integrations/v2/instances`, `/report/v1`, `/sync/reports/v1` (first one: `syncinfo:MissingTreeFile`, "Previous tree does not exist", expected on a first sync), `/analytics/v2/events` on ping.remarkable.com (rmfakecloud swallows them) |

Nothing broke on the rmfakecloud side, so no patch. Two oddities, both from the emulator: the device registers as `fallback-<hash>` (no devconfig serial here; the tablet has one), and a fresh notebook sometimes starts on highlighter yellow (the script picks Black). Not covered: conflicts (both sides editing one page), deletes, folders, big files, screenshare, handwriting conversion, and real Cloudflare in front.

## Status

**Review fixes, Oct 25 2026 evening: all 11 steps pass**, `PP_BUILD_CA=/root/.ccr/ca-bundle.crt make rung2` (no `--skip-build`) in this x86_64 dev container, exit 0, 26.6 min, half of it next to the device test bed:

```
PASS  build        30s      PASS  ota         521s
PASS  emulator    250s      PASS  killswitch  200s
PASS  server       15s      PASS  reboot      200s
PASS  install     110s      PASS  disable      45s
PASS  freeze       85s      PASS  status        5s
PASS  sync        130s
```

New in it: `pp-agent.timer stopped; no agent run in flight` before `ota`; the install's result read from state and the agent log; `30-appload.sh` ran at install, rollback, every recheck and the triple-press (1.3 to 1.7 s each, all ok), and the status said `install true` then `recheck true`; `--verify` passed `xochitl waits for nothing of ours` after install and after the reboot, and found the four extra reMarkable names blocked; the latest report carried pp-proxy's sync health (`errors` 0, a `last_ok`), and `/pp/problems` was `{"ok":true,"problems":[]}`. The heartbeat printed a `....` line a minute during the slow steps. The fail path (FAIL lines and log tail) was not triggered here. The no-`rcc` fallback for hello (CI's runners have `rcc`, so it never runs there) now runs its container as the calling user: as user `runner`, its output is owned by `runner` and `rm -rf` works; the old way left root-owned files that `runner` could not remove (`Permission denied`). Negative check for the new AppLoad check, by hand on the stock emulator: `never logged '[qmldiff]: Loaded external AppLoad hooks in main UI'`, exit 1.

**All 11 steps pass** from `ppemu reset`, Oct 25 2026, this x86_64 dev container (4 vCPU, arm64 under qemu-user), `PP_BUILD_CA=/root/.ccr/ca-bundle.crt test/e2e/run.sh --skip-build`, exit 0, 24 min:

```
PASS  build         4s      PASS  ota         495s
PASS  emulator    202s      PASS  killswitch  190s
PASS  server        9s      PASS  reboot      204s
PASS  install      82s      PASS  disable      48s
PASS  freeze       71s      PASS  status        5s
PASS  sync        127s
```

The same run without `--skip-build` passed `build` in 37 s with everything cached (a cold `mods/build.sh` is ~30 min under qemu, see `mods/README.md`). From that run:

- **OTA.** `e2e-…-good` installed in 178 s (`pp-agent.service`, default gates, through the gate; first hashtab build included), Hello showed `release e2e-…-good` (`shots/ota-hello/3-hello.png`). Broken: `rolled back ... xochitl (pid 5984) has not loaded "appload.so"`, 240 s, mods back on. Forged: `latest.json rejected: bad signature`, nothing downloaded. Tampered: `sha256 mismatch ... (deleted)`, nothing unpacked. Wrong OS: `refused: tested on OS [3.27.3.0], this tablet runs "3.27.2.2"`. Each refusal took 3 s.
- **Kill switches.** Triple-press: `tripletap: mods off (…)`, then `tripletap: mods on (…)` after the health check (2 min 15 s). Reboot: `activate_on_boot is off`, stock, release still installed. With `paper-pure/disable`: `tripletap: mods already off`, `pp-agent.service` `ConditionResult=no`.
- **Freeze.** `--verify` all PASS before and after the reboot; update-engine never active; the Updates switch reads off, switching it on logs `UnitMasked` (the switch then shows on until xochitl restarts; after the reboot it reads off). 0 journal lines and 0 DNS lookups naming an update host over the whole run (22 lookups in all, to 4 sync names).
- **Status.** 10 reports in ppd, read through the gate (403 without the token): installed, rolled back, signature, sha256, wrong OS, the toggles, boot.
- **No xochitl crash** in the whole run (0 `status=11/SEGV`; 12 screen captures, one per xochitl start), with a PDF on the device.
- Logs and screenshots of this run are in the lane's scratch (`work-pp-e2e/run4-out`), not in the repo. Afterwards: no `pp-e2e-*` container or volume, no gate process, emulator reset.

Earlier runs, and what they caught (all fixed): the PDF crash and the Wi-Fi gap above; a stale throwaway key from the previous run (`keys-forged`, now removed first); the runner dying when a failed step logged no `FAIL` line; checks that took the agent's early `live` marker for a finished health check (now they wait for `last_result`); a tamper test that appended a byte, which the agent never reads (it stops at the signed `size`; now a byte in the middle is flipped). One run failed at `reboot` because the host's `docker0` bridge vanished mid-run (`adding interface ... to bridge docker0 failed: Device does not exist`), not by our doing; recreated by hand.

Not verified:

- An arm64 host (CI's `ubuntu-24.04-arm`): never run there. The no-host-`rcc` path (Qt stage of `mods/build/Dockerfile`, loaded as `pp-e2e-qt`) was checked by hand only.
- The cold path: `build` from an empty Docker cache and no `emu/firmware`.
- Real Cloudflare Access, real Wi-Fi, the real tablet. The gate is `server/test/fakeaccess`; Wi-Fi is `rmemu-wifi`.
- Sync beyond one page and one PDF each way (see above).
