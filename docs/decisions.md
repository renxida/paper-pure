# Open decisions

Everything still Cedar's call, from every lane and the review. Each row says what the repo does today, the other way, and the one change that switches it. Nothing here blocks the next step; the defaults are safe. What only Cedar can *do* (accounts, keys, clicks) is in [cedar-checklist.md](cedar-checklist.md).

## Tablet

| Decision | Today | Alternative | To switch |
| --- | --- | --- | --- |
| Reboot is a kill switch | `activate_on_boot: false`: a reboot is stock until a triple-press or the next release | Mods come back at every boot; the boot-loop guard (3 unhealthy boots) still ends a loop | `"activate_on_boot": true` in the tablet's `agent.json` |
| Triple-press off sticks | Off holds through reboots and new releases (updates wait) until the next triple-press. A reboot alone does not hold mods off | Off lasts until the next install | drop the `a.st.ModsOff` check in `update()` (agent/internal/agent/agent.go) |
| When installs may restart xochitl | Any time Wi-Fi is up and the battery is at 30% or more. An install restarts xochitl twice | Only while charging | `"require_charging": true` in `agent.json` |
| Rechecks while mods are live | Every update run (30 min awake) re-runs the release's checks and **reports** the result; it changes nothing | Turn mods off when a recheck fails | in `recheck()` (agent/internal/agent/health.go), call `modsOff` on failure |
| Agent and proxy updates | Installed once over USB, never by a release (a broken agent can't roll itself back) | A signed release may carry a new `pp-agent`/`pp-proxy`, health-checked | new code: a `bin/` step in `install()`; not built |
| Rolling back on purpose | Re-sign the old tree under a new id: the tablet takes only releases newer than any it ever had | Allow older releases | not offered: it is the anti-replay rule |
| A triple-press during an install | That release is marked failed and never retried by itself | Retry it later | re-publish it under a new id |
| Mods wait for rm-sanity | Mods come on 60 to 80 s after boot, after the boot counter is cleared | Sooner, with a risk of a slot switch on a crash loop | remove `WAIT_UNITS` drop-ins in `device/tablet/pp-device.sh` (not advised) |
| SSH | USB only. Tailscale userspace (no TUN in the kernel) would be the overlay | Tailscale userspace, one binary under `/home` | `pp-device.sh persist` a `tailscaled --tun=userspace-networking` unit |
| SSH password | Stock: developer-mode password works over USB too (`-B`) | Key only (`-s`); a lost key then means the recovery tool | `DROPBEAR_EXTRA_ARGS=' -s'` in `/etc/default/dropbear`, persisted with `pp-device.sh persist` |
| Blocked hosts | Update hosts, the `.swu` bucket, and reMarkable's account, error, store and web hosts go to `0.0.0.0`. dev/qa/stage names are not blocked (dead in public builds) | Fewer, or more | edit `device/tablet/freeze.hosts`, `device/install.sh` |
| AppLoad version | v0.5.3, the last for 3.27 (newer needs OS 3.28+) | Move the OS and AppLoad together | a project: new firmware pin, `mods/versions.lock`, full rung 2 |
| Fallback OS | Stay on 3.27.2.2 (sync proven in the emulator) | 3.27.1.0, inside rmfakecloud's tested range | `emu/bin/ppemu` version pin, then rungs 1 and 2 |

## Server

| Decision | Today | Alternative | To switch |
| --- | --- | --- | --- |
| Host | Render background worker, 5 GB disk, about $8/mo (`server/render.yaml`) | Fly.io, about $4/mo, volume on one host | a `fly.toml` with `[mounts]` and no `[services]` |
| Region | `frankfurt` (sets `TZ` for the 03:17 backup) | nearer Cedar | `region:` and `TZ` in `server/render.yaml` |
| Backups | restic to Backblaze B2, nightly, key without `deleteFiles`, 30-day prior versions | another S3 provider (not R2: Cloudflare is the front door) | `RESTIC_REPOSITORY` |
| Deploys | A main commit that touches `server/` deploys once its CI checks pass | Deploy by hand | `autoDeployTrigger: off` in `server/render.yaml` |
| rmfakecloud pin | master `3c6de006` (v0.0.31 plus the sync v3 412 fix) | the v0.0.31 tag | `RMFAKECLOUD_COMMIT` in `server/Dockerfile`, then `make proof` and rung 2 |
| Tablet token lifetime | Non-expiring `pp-tablet` (renewing needs the cable); CI's and Claude's may expire | One year with a reminder, and a cable each year | set the duration in Zero Trust |
| Tablet auth | Access service token in `agent.json`, injected by pp-proxy | mTLS client cert plus a WAF rule | not built |
| Status reads | `/pp/status/<device>` open to every token past Access | Behind the read token too | add `bearer(r, s.readToken)` to the status case in `server/ppd/main.go`, and send it in `test/e2e` |
| Claude's Access scope | One Access app for `pp.<domain>`, all paths | A second app for `/pp/` only, for `pp-claude` | Zero Trust, Applications |
| Monitoring | `/pp/problems` exists; nothing polls it yet | A daily scheduled Claude task, or an uptime monitor with Access headers | create one (cedar-checklist step 8) |
| Problem thresholds | Backup older than 26 h, tablet silent over 72 h | other values | `PP_BACKUP_MAX_AGE`, `PP_REPORT_MAX_AGE` env on the host |
| `"synced": false` at proxy install | Marks local notes unsynced before the first pairing, as rmfakecloud advises | Leave them | drop the loop in `server/tablet-proxy/install.sh` |

## Releases and CI

| Decision | Today | Alternative | To switch |
| --- | --- | --- | --- |
| Who can ship | CI signs whatever lands on `main`; zero approvals on PRs | A required reviewer on the `release` environment: one click per release | Settings, Environments, `release`, Required reviewers. Turn on before wishes go live |
| What ships | Only main's tip; skipped when not newer than the live release or built from the same `mods/` and `apps/` | Every main push | remove the tip check in `.github/workflows/ci.yml` and `publish-check.py` |
| Patching the image | Dependabot PRs: base images weekly, wheels and actions monthly; Claude merges once CI is green | A scheduled rebuild | `.github/dependabot.yml` |
| Emulator host | x86 dev container under qemu (slow: 2 min boots, 5 s taps); CI on free arm64 runners | An arm64 box: interactive, no code changes | run `ppemu` there |
| Hello golden | Pixel-exact (`--max-diff 0`) | A tolerance, if Qt or font updates make it flaky | `--max-diff N --tol T` in `apps/hello/test.sh` |
| Test harness overlap | Both the device test bed (boot counter, slot switch, passcode, uninstall, memfaultd loop) and `test/e2e` (real xochitl) run; they overlap on install, reboot and the kill switch | Fold the test bed's unique cases into rung 2, drop `server/test/tablet-sync.py` | a refactor, about a day; not started |
| Internal emulator names | rmemu's (`/opt/rmemu`, `RMEMU_*`), so upstream fixes merge cleanly | Ours everywhere | rename in `emu/` |

## Wishes

| Decision | Today | Alternative | To switch |
| --- | --- | --- | --- |
| Pick-up | When Cedar says "new wish"; no scheduled task | A daily scheduled Claude task | create it (cedar-checklist step 8) |
| Approval | An issue is filed; work starts only after Cedar adds `approved` | Claude starts right away | not advised: the page comes from the server |
| Where issues go | This public repo, transcription only, never `page.png` | A private tracker or private repo | `gh issue create --repo <private>` in `tools/wishes/README.md` |
| Markers | The Wishes notebook or folder, a `wish` page tag, a `wish` notebook tag | One of them | `wishes.py` selection, about 3 lines each |
| Revisions | More writing on a picked-up page is `-r2`; the same issue is updated | Freeze a page once picked up | `wishes.py` revision logic |
| Handwriting | Claude reads `page.png`; no MyScript | MyScript, for on-tablet Convert to text | rmfakecloud's MyScript env vars (2 secrets, a new vendor) |
| Test fixtures | Notebooks drawn in the emulator live in `tools/wishes/testdata` (our strokes, no reMarkable code) | Generate them in tests | `tools/wishes/testdata` |
