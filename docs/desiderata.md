# Paper Pure: Own the Stack

Desiderata, not a plan. Oct 24, 2026 · @Cedar

## Intent

Cedar owns the tablet; reMarkable becomes a hardware vendor, not a landlord. Claude (via Claude Code) is the maintainer: Cedar files a wish, Claude builds it, proves it off-device, and ships it to the tablet over the air. Cedar never plugs in a cable for routine work, and the tablet never gets worse than it was yesterday.

Grug rule for everything below: complexity is the enemy. Every requirement must earn its place, and the 80/20 version ships first.

## Ground truth

The Pure is moddable today, but it is new: the community stack lists it as a target, and almost nothing is tested on it specifically.

| Fact | What it means for us |
| --- | --- |
| Launched May 2026, $399. Dual-core Cortex-A55 at 1.7 GHz, 10.3" Carta 1300, 1404×1872, no front light, no pogo pins ([Liliputing](https://liliputing.com/remarkables-paper-pure-is-a-399-e-ink-writing-tablet-that-replaces-the-remarkable-2/), [TechCrunch](https://techcrunch.com/2026/05/06/remarkables-new-paper-pure-tablet-goes-back-to-basics-with-a-monochrome-screen/)) | aarch64 target, same family as Paper Pro builds. No keyboard port, so input is pen and touch only |
| Root needs Developer Mode, which wipes the device; leaving it goes through reMarkable's recovery tool ([reMarkable Guide](https://remarkable.guide/tech/developer-mode.html)) | One-time wipe. Do it before there are notes worth keeping |
| The mod stack is xovi (function hooking), AppLoad (app host), and qt-resource-rebuilder (QML patches). The Vellum package feed lists the Pure as a device ([Vellum feed](https://vellum.delivery/feeds/rmpp.rss), [xovi-qmd-extensions](https://github.com/ingatellent/xovi-qmd-extensions)) | We build on this, not from scratch |
| Hooks are pinned to OS versions; an OS update can break AppLoad outright ([AppLoad issue #40](https://github.com/asivery/rm-appload/issues/40)) | Freezing the OS is not optional, it is the foundation |
| The Pure already diverges: some patches need a Pure-only variant, some apps say they don't support it ([xovi-qmd-extensions](https://github.com/ingatellent/xovi-qmd-extensions), [rmweb](https://github.com/snydersaurus/rmweb/releases)) | "Works on Paper Pro" is a hint, never a guarantee |
| xovi can be toggled off by triple-pressing power; a reboot returns stock ([remagic](https://github.com/maximerivest/remagic)) | A free, human-reachable kill switch already exists |
| rmfakecloud lists the Pure as supported, sync tested up to OS 3.27.1; its on-device proxy is wiped by official updates ([rmfakecloud](https://github.com/ddvk/rmfakecloud)) | Self-hosted sync is viable if the OS stays frozen at a tested version |
| AppLoad ships a PC emulator; existing apps keep separate host and device build scripts ([rm-appload](https://github.com/asivery/rm-appload), [reTaskable](https://github.com/jdkruzr/reTaskable)) | A real off-device loop exists for apps. For the whole OS, see rmemu under Dev loop |

## Desiderata

Ranked so the top rows ship first. If a row below the line threatens a row above it, the lower row loses.

| # | Want | Priority | Done when |
| --- | --- | --- | --- |
| 1 | Never lose a note | Must | Every notebook is backed up off-device at least daily, and a restore has been tested once |
| 2 | Never brick the tablet | Must | Any change can be undone without a cable: triple-press, reboot, or auto-rollback |
| 3 | OS frozen at a version we choose | Must | No reMarkable update can land, by setting and by network block |
| 4 | Writing feel stays stock | Must | Pen latency and ink rendering untouched; stock is good |
| 5 | Reliable, high-security sync to infra Cedar owns | Must | Notes sync to a self-hosted server behind a reputable security provider; reMarkable's cloud is unused |
| 6 | Full-OS emulator | Must | Claude can boot the Pure's stock OS plus our mods in a container and test there |
| 7 | Claude ships changes over the air | Must | A change that passes CI reaches the tablet with zero manual steps |
| 8 | Off-device proof before on-device | Must | Nothing reaches the tablet without passing host and emulator rungs |
| 9 | Feature requests from the tablet | Should | Cedar writes a wish on the tablet (a tagged page or notebook); Claude picks it up and turns it into a change |
| 10 | One boring repo holds everything | Should | Config, mods, apps, server, and docs live in one place Claude can read end to end |
| 11 | Observable | Should | The tablet reports what it's running and logs failures somewhere Claude can read |
| 12 | Replace the stock app | Nice | Not planned; revisit only if hooking hits a wall |

## Dev loop

A change climbs three rungs, cheapest first, and CI blocks it at the first failure. Most iteration happens in a full-OS emulator, so the real tablet sees only finished work.

1. **Host build and test.** Apps build for the AppLoad PC emulator and run headless, replaying scripted pen strokes and taps and comparing screenshots. Seconds per run.
2. **Full-OS emulator.** The Pure's own stock root filesystem runs in an arm64 container with our xovi hooks, AppLoad, and the sync client pointed at a test server. [rmemu](https://github.com/aetherino/rmemu) already does this for the Paper Pro on Apple Silicon, with a CLI harness built for agents; we adapt it to the Pure rather than build from zero. This rung catches broken hooks, boot loops, and sync breakage.
3. **On-device canary.** The tablet pulls the build, runs a smoke test, and reports back. Pass means it stays; fail means automatic rollback to the last good build.

Requirements for the loop itself:

- CI guardrails are mandatory: nothing merges, and nothing is released, unless rungs 1 and 2 pass
- One command runs the whole loop for Claude, end to end, with readable logs
- The emulator is fully scriptable by Claude: boot, inject pen and touch, screenshot, read logs, reset to a clean state
- The emulator runs the exact OS build frozen on the tablet, so a pass there means the same hooks resolve on the device
- A bug report from Cedar becomes a failing test before it becomes a fix
- A small set of checks kept green on the real tablet: boots, opens a notebook, pen draws, sync completes, AppLoad launches
- Known blind spots, checked only on the tablet: e-ink refresh timing, pen latency, battery, sleep and wake

## Updates and rollback

Updates are pull-based, small, and reversible. The tablet asks for work; nothing pushes into it.

- **Pull, don't push.** A tiny agent on the tablet checks for a new release on a schedule, only on Wi-Fi and above a battery floor
- **Atomic swap.** A release lands in a new directory and a single pointer flips to it. The previous release stays on disk
- **Health check, then commit.** After a swap the agent runs the smoke checks; failure flips the pointer back by itself
- **Kill switch a human can reach.** Triple-press power disables all mods. Reboot returns stock UI. Neither needs a computer
- **Signed releases.** The agent installs only builds signed by Cedar's key; a compromised server can't push code
- **Official OS updates: never.** Disabled in settings and blocked at DNS. Moving to a newer OS is a deliberate project: re-verify every hook and sync in the loop first, then move

## Infra and security

One small managed service Cedar pays for, with Cloudflare as the only front door. Comfort over cost: pick managed and boring over cheap and clever.

&#91;embedded content: system at a glance · 6 parts\]

Nothing reaches into the tablet: it calls out through Cloudflare, and installs only what Claude signed.

- **Someone else does the security.** Cloudflare at the edge, and a managed host that patches the OS, runtime, and TLS for us. Cedar never maintains a bare server
- **One service.** The sync server, release feed, and backups run as one small app. No microservices, no Kubernetes
- **No open ports.** The server is reached only through Cloudflare Tunnel; Cloudflare Access sits in front of every human-facing page
- **Machine identity for the tablet.** The tablet authenticates with its own credential (service token or client certificate), revocable without touching anything else
- **SSH is private.** Root SSH to the tablet is never exposed on public Wi-Fi; reach it over USB or a private overlay network
- **Backups leave the host.** Nightly encrypted copy to a second provider; one tested restore before trusting it
- **Secrets in one place.** Signing key and tokens live in a password manager or the host's secret store, never in the repo
- **Logs Claude can read.** Server and tablet logs land somewhere Claude can query when debugging

## Saying no

Out unless a real, specific need forces them back in. Ordinary engineering hygiene (measure before optimizing, one feature at a time) is assumed, not listed.

- **Shipping or redistributing reMarkable's code.** Community decompilations and extracted QML are fine as reference for finding hooks; nothing of theirs goes in our repo or our releases
- **Rewriting the drawing app or the display driver, for now.** reMarkable's pen pipeline is the best part of the device; revisit only if hooking hits a wall
- **Android or another OS.** Lightweight is good, generality is bad: it throws away the writing feel and multiplies everything to maintain
- **A framework of our own.** Use xovi, AppLoad, and Vellum's packages; write glue, not platforms

## Open questions and first move

First move: stand up the emulator (rung 2) and run a trivial AppLoad "hello" app in it. Nothing touches the tablet, so offline use continues untouched.

- [x] Which OS version shipped on this unit? **3.27.2.2** (Settings, General, Software; checked Oct 25, 2026). It decides which xovi, AppLoad, and rmfakecloud versions apply, and which rootfs the emulator runs. The unit is not paired with the reMarkable cloud, and that is how it stays
- [x] Is that version inside rmfakecloud's tested range (up to 3.27.1)? **No**, it is one patch release newer, and rmfakecloud says newer releases are untested. Sync is the riskiest piece: prove it in the emulator before freezing on 3.27.2.2. A downgrade to 3.27.1 is the fallback, and it needs a 3.27.1 image to exist
- [ ] Until the update block is in place, keep the tablet off Wi-Fi (flight mode on) so it can't move past 3.27.2.2 on its own. Newer Pure builds already exist (3.27.3.0, 3.28.0.172, 3.29.0.153). An online stock 3.27.2.2 is being offered 3.29.0.153 right now: the device test bed, briefly online in CI, got that offer from reMarkable's update server
- [x] Can we get the Pure's root filesystem without dev mode? **Yes.** The exact 3.27.2.2 update image (codename `tatsu`, sha256 `2c64bea8…a997d`) is on the public S3 mirror codexctl uses, and its `sw-description` signature verifies against reMarkable's update key
- [x] Which machine runs the emulator? **Both.** CI runs it natively on GitHub's free `ubuntu-24.04-arm` runners (rung 2 in ~15 min); a cloud dev container runs it on x86 through qemu-user (~45 min). See [emu/README.md](../emu/README.md)
- [x] Is sync on 3.27.2.2 safe with rmfakecloud? **Yes, in the emulator:** stock xochitl pairs and syncs both ways through `pp-proxy` (rung 2 `sync` step). Not yet on hardware
- [ ] Which managed host for the server? Recommendation: Render, with Backblaze B2 for off-host backups. Cedar's call, see [decisions.md](decisions.md) and [cedar-checklist.md](cedar-checklist.md)

## Sources

- [Liliputing: Paper Pure specs](https://liliputing.com/remarkables-paper-pure-is-a-399-e-ink-writing-tablet-that-replaces-the-remarkable-2/)
- [TechCrunch: Paper Pure launch](https://techcrunch.com/2026/05/06/remarkables-new-paper-pure-tablet-goes-back-to-basics-with-a-monochrome-screen/)
- [reMarkable Guide: Developer Mode](https://remarkable.guide/tech/developer-mode.html)
- [rm-appload](https://github.com/asivery/rm-appload) and [issue #40](https://github.com/asivery/rm-appload/issues/40)
- [xovi-qmd-extensions](https://github.com/ingatellent/xovi-qmd-extensions)
- [Vellum package feed](https://vellum.delivery/feeds/rmpp.rss)
- [remagic](https://github.com/maximerivest/remagic)
- [rmfakecloud](https://github.com/ddvk/rmfakecloud)
- [reTaskable](https://github.com/jdkruzr/reTaskable)
- [grugbrain.dev](https://grugbrain.dev)
