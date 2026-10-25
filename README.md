# paper-pure

Own the stack on a reMarkable Paper Pure (codename tatsu, OS 3.27.2.2). The OS stays frozen, notes sync to a server Cedar owns, and mods are proven off-device before they reach the tablet over the air. Claude maintains it; Cedar files wishes. One repo: config, mods, apps, server, docs.

- [Desiderata](docs/desiderata.md): what we want, ranked, and what we say no to.
- [Cedar's checklist](docs/cedar-checklist.md): what only Cedar can do (accounts, keys, the tablet's one cable afternoon), in order.
- [Open decisions](docs/decisions.md): every call still open, with today's default and the one change to switch.
- [Bootstrap runbook](docs/runbook-bootstrap.md), [firmware](docs/firmware.md), [CI](docs/ci.md).

| Dir | What |
| --- | --- |
| [emu/](emu/README.md) | Full-OS emulator: the Pure's stock 3.27.2.2 root fs under its own systemd, in a container |
| [device/](device/README.md) | The tablet's own config: OS freeze, SSH, persistence, and the test bed that proves it |
| [agent/](agent/README.md) | `pp-agent` (pull, verify, install, health-check, roll back, kill switch) and `ppsign` |
| [mods/](mods/README.md), [apps/](apps/hello/README.md) | xovi, qt-resource-rebuilder and AppLoad from pinned source; the hello app |
| [server/](server/README.md) | The one service: rmfakecloud, `ppd` (feed, status, problems, wishes, logs), backups; `pp-proxy` for the tablet |
| [tools/wishes/](tools/wishes/README.md) | Wish pages from the tablet to Claude |
| [test/e2e/](test/e2e/README.md) | Rung 2: the whole stack in the emulator |

## Status

Oct 25 2026. Nothing has run on the real tablet, Cloudflare, Render or B2 yet: those wait on [Cedar's checklist](docs/cedar-checklist.md). "Proven" below means in the emulator, the device test bed (the real root fs under its own systemd), or local proofs, by a command that passes today.

| # | Want | State | Where it's proven |
| --- | --- | --- | --- |
| 1 | Never lose a note | Done, proven locally. Not deployed | Nightly restic, wipe and restore drill (`make -C server proof`). `/pp/problems` flags a failed or late backup, a silent tablet, failing sync. Nobody polls it yet (checklist step 8) |
| 2 | Never brick the tablet | Done, proven off-device | Triple-press, reboot-is-stock, auto-rollback, crash loops, a passcode-locked `/home` at boot (`device/test/run.sh`, `test/e2e`). Hardware: not yet |
| 3 | OS frozen | Done, proven off-device | Update units masked, update hosts blocked, the Updates switch can't turn on (`test/e2e` freeze, test bed) |
| 4 | Writing feel stays stock | By design | Nothing touches the pen or display path. Only the tablet can tell; installs restart xochitl (decisions.md) |
| 5 | Sync to infra Cedar owns | Done, proven in the emulator | Stock xochitl and rm-sync pair and sync both ways through `pp-proxy` and a stand-in Access gate (`test/e2e` sync). reMarkable's other hosts blocked |
| 6 | Full-OS emulator | Done | `emu/bin/ppemu`; rung 2 runs on it |
| 7 | Claude ships over the air | Done, proven in the emulator | Signed releases install, roll back, refuse forged, tampered, old and wrong-OS ones (`test/e2e` ota). CI's release job has never published (no feed yet) |
| 8 | Off-device proof first | Done; the merge gate needs Cedar's ruleset | rung 1 and rung 2 green on GitHub (x86 and arm64 runners). Rung 3: the release's checks run at install and every 30 min while live, reported to the server. Notebook and pen checks: hardware only |
| 9 | Wishes from the tablet | Done, proven locally. Pick-up is by hand | Server scans, `/pp/wishes` serves Claude only; work starts after Cedar's `approved` label |
| 10 | One boring repo | Done | This one |
| 11 | Observable | Done, proven locally | Status reports (release, failures, checks, sync health, log tail), the server log, `/pp/problems` |
| 12 | Replace the stock app | Not planned | |

## The loop

```bash
make rung1     # host: go tests, pytest, shellcheck, actionlint, hello in AppLoad's PC emulator with a tap. ~1 min
make proofs    # arm64 containers: agent, server (backup drill), wishes, device test bed. ~10 min native, ~45 under qemu
make rung2     # test/e2e/run.sh: the whole stack in the emulator. ~15 min native, ~45 under qemu
make loop      # all three, stops at the first failure; what CI gates on
make release   # build and sign (PP_SIGNING_KEY); CI does this on main
```

Each step logs to `out/logs/<target>/`. Behind a TLS-intercepting proxy add `PP_BUILD_CA=/path/to/ca.pem`. Needs docker (with arm64 binfmt on x86), go, node 22, python3, shellcheck, Qt's `rcc`; see [docs/ci.md](docs/ci.md).
