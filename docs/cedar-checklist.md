# Cedar's checklist

The things only Cedar can do, in order. Each step says where to click or what to run, and what Claude does right after. Choices with a safe default are in [decisions.md](decisions.md); the tablet steps in full are in [runbook-bootstrap.md](runbook-bootstrap.md).

Keep every secret below in the password manager first, then wherever it goes. None goes in the repo or in a chat.

## Now

1. **Tablet: flight mode on.** Swipe down from the top-right corner, or Settings > General > Flight mode. Then Settings > General > Software must say Version 3.27.2.2 with no "Tap to restart and update". If it says that: don't restart, tell Claude.
   - Claude: nothing yet. Newer OS builds exist and nothing blocks them until runbook step 4.

## GitHub (any time; 10 min)

2. **Lock `main`.** github.com/renxida/paper-pure > Settings > Rules > Rulesets > New ruleset > New branch ruleset, named `main`:
   - Enforcement status Active; Target branches: Include default branch.
   - Restrict deletions; Block force pushes.
   - Require a pull request before merging (0 approvals is fine for now).
   - Require status checks to pass: add `rung1`, `proofs`, `rung2`.
   - Bypass list empty. Save.
   - Also: Settings > Actions > General: "Require approval for all outside collaborators" for fork PRs; Workflow permissions "Read repository contents".
   - And 2FA on the GitHub account (github.com/settings/security): it is the real lock on the signing key.
   - Claude: from then on works on branches and opens PRs; nothing goes to `main` without green checks.
3. **The signing key.** On your laptop, in this repo:
   ```bash
   make -C agent build
   agent/out/ppsign keygen -out ~/pp-keys
   ```
   Save `~/pp-keys/release.key.pem` in the password manager, then `gh secret set PP_SIGNING_KEY --env release < ~/pp-keys/release.key.pem` (the `release` environment appears after the first CI run on `main`; or create it under Settings > Environments > New environment, deployment branches `main` only). Delete `release.key.pem` from disk. Keep `release.pub.pem`: the tablet needs it (step 11).
   - Claude: the next push to `main` builds, signs and (without feed secrets yet) stops before publishing, with a notice in the run.

## Accounts (once you pick, decisions.md "Server"; about an hour)

4. **Cloudflare** (the domain must be on Cloudflare: dash.cloudflare.com > Add a site). In Zero Trust (one.dash.cloudflare.com):
   - Networks > Tunnels > Create a tunnel > Cloudflared, name `pp-server`. Copy the token (it becomes `TUNNEL_TOKEN`). Public hostname `pp.<domain>`, service HTTP `localhost:3080`.
   - Access > Service credentials > Service Tokens > Create: `pp-tablet` (duration **Non-expiring**: renewing it needs the USB cable), `pp-ci`, `pp-claude`. Save each Client ID and Secret.
   - Access > Applications > Add > Self-hosted, domain `pp.<domain>`, all paths. Policies in this order: `cedar` (Allow, your email), then `pp-tablet`, `pp-ci`, `pp-claude`, each Service Auth with that one token. In the app settings, turn on returning 401 for failed service auth.
   - Back in the main dashboard for the domain: Caching > Cache Rules > bypass cache for hostname `pp.<domain>`.
   - Claude: nothing to check yet; it needs the server.
5. **Backblaze B2** (secure.backblaze.com): Buckets > Create a bucket (private). Lifecycle settings: keep prior versions for 30 days. App Keys > Add a new key: this bucket only, Read and Write, and **no** `deleteFiles` (the B2 CLI: `b2 key create --bucket <b> pp-server listBuckets,listFiles,readFiles,writeFiles`). Save the key id and key.
6. **Secrets for the server.** On your laptop:
   ```bash
   openssl rand -base64 48   # JWT_SECRET_KEY
   openssl rand -hex 32      # PP_PUBLISH_TOKEN
   openssl rand -hex 32      # PP_READ_TOKEN
   openssl rand -hex 32      # RESTIC_PASSWORD  (lose it and the backups are noise)
   ```
7. **Render** (dashboard.render.com): New > Blueprint > connect GitHub, pick this repo. It reads `server/render.yaml`. Fill each `sync: false` value: `JWT_SECRET_KEY`, `TUNNEL_TOKEN`, `PP_PUBLISH_TOKEN`, `PP_READ_TOKEN`, `RESTIC_REPOSITORY` (`s3:https://s3.<region>.backblazeb2.com/<bucket>`), `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. Apply. When the log says `NO USERS`: the service's Shell tab, `rmfakecloud-cli setuser -u <your email> -a -s`, keep the printed password, then Manual Deploy > Restart service.
   - Claude, with the `pp-claude` token (step 8): `GET /pp/healthz` (200), `GET /pp/problems` (only "backup: none has run yet" until the first night), then the next morning `/pp/backup` says ok.

## Give Claude its keys (5 min)

8. **Claude's environment.** Where Claude Code runs for this repo (its environment secrets, not the repo): `PP_CLAUDE_ID` and `PP_CLAUDE_SECRET` (the `pp-claude` token) and `PP_READ_TOKEN`. In GitHub > Settings > Environments > `release` > Environment secrets: `PP_FEED_URL` = `https://pp.<domain>/pp/releases/tatsu/`, `PP_PUBLISH_TOKEN`, `PP_CF_ACCESS_CLIENT_ID` and `PP_CF_ACCESS_CLIENT_SECRET` (the `pp-ci` token).
   - Say whether you want a **daily check**: a scheduled Claude task that reads `/pp/problems` and `/pp/status/tatsu` and tells you on a problem, and picks up new wishes (decisions.md, "Monitoring" and "Pick-up"). Claude creates it when you say so.
   - Claude: the next release run on `main` publishes and reads `latest.json` back through Access.

## The tablet (one afternoon, USB cable; runbook-bootstrap.md has every detail)

9. **Keep what matters, then developer mode** (runbook steps 1 and 2; **wipes the tablet**). Settings > General > Software > Advanced > Developer mode, confirm, double-press power. Skip Wi-Fi and pairing in onboarding, flight mode on again. Find the root password: Settings > Help > Copyrights and licenses > General information.
10. **USB and the first SSH** (step 3): plug in, make sure `~/.ssh/id_ed25519.pub` exists, run Claude Code on that laptop, read Claude the password once.
    - Claude: freezes the OS and keys SSH (`device/install.sh --key ...`), reboots, `--verify`; also reads the real input names, ABS ranges and power-supply names off the tablet so the emulator's guesses become facts.
    - You: Settings > General > Software: Updates is off, and stays off when tapped. Tell Claude what you see.
11. **Agent, mods, sync** (steps 6 and 7). Hand Claude `release.pub.pem` and an `agent.json` built from `agent/config.example.json` with the `pp-tablet` token (keep that file in the password manager).
    - Claude: `device/install.sh --agent --release-pub ... --agent-json ...`, the mods by hand, `--proxy`, then a reboot and `--verify`.
    - You: triple-press power: AppLoad leaves the side menu; again: it's back. After a reboot the tablet must come up normally, and if you use a passcode, show the passcode screen.
12. **Wi-Fi on and pair** (step 8). Flight mode off, join Wi-Fi. Open `https://pp.<domain>/`, log in, Code > Generate, and type the code under Settings > General > Account.
    - Claude: checks the tablet's status report (`release`, `os_version 3.27.2.2`, `sync.last_ok`), `/pp/problems`, and that a page you write shows up in rmfakecloud.
13. **A day later:** Settings > General > Software still says 3.27.2.2. Tell Claude. From here on, changes arrive over the air.

## Later, when wishes go live

14. Settings > Environments > `release` > Required reviewers: add yourself (one click per release). Then label wish issues `approved` when you want them built (tools/wishes/README.md).
