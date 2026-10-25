# server

The one small managed service: sync (rmfakecloud), the release feed for `pp-agent`, tablet status intake, nightly encrypted backups off the host, and the wish inbox and logs Claude reads. Covers desiderata rows 1 (never lose a note), 5 (sync to infra Cedar owns), 9 (wishes from the tablet), 11 (observable) and "Infra and security".

## How it fits together

```
Cedar's browser ─┐ Access: login
Claude, CI ──────┤ Access: service tokens       Cloudflare      one container, one disk at /data
tablet ──────────┘ Access: service token  ──> Tunnel ──> cloudflared ──> ppd :3080 ──> rmfakecloud :3000
  pp-agent:        /pp/releases, /pp/status                                   restic, nightly ──> Backblaze B2
  xochitl/rm-sync: /etc/hosts -> pp-proxy 127.0.0.1:443 (adds the token)     wishes.py, every 15 min
Claude: /pp/wishes, /pp/logs (+ the read token), /pp/status
```

- **One image, five jobs.** rmfakecloud (built from a pinned commit), `ppd` (our front door, one Go file), cloudflared, a nightly restic loop, and a wish scan every 15 minutes (`wishes/wishes.py`, see [tools/wishes](../tools/wishes/README.md)). If one dies, the container exits and the host restarts it.
- **One log.** Everything any of them prints goes through `ppd logtee`: unchanged to stdout (the host's log view) and, with a UTC time in front, to `/data/log/server.log`. At 4 MiB it moves to `server.log.1`, so at most 8 MiB stay on disk. Claude reads it at `/pp/logs/`.
- **No ports.** In production nothing listens outside the container. cloudflared dials out to Cloudflare.
- **Cloudflare Access is the gate for everything.** One Access app on `pp.<domain>`: Cedar logs in; the tablet, CI and Claude each have their own service token, revocable alone. Behind it, rmfakecloud's own logins still apply.
- **The feed is untrusted.** `pp-agent` installs only releases signed with Cedar's key, so a compromised server can't push code. ppd adds two rules of its own: publishing needs `PP_PUBLISH_TOKEN`, which only CI has, and wish pages and logs need `PP_READ_TOKEN`, which only Claude has. Wish pages are Cedar's notes, and Access lets the tablet's and CI's tokens in too. rmfakecloud's own logins guard everything else of the notes.
- **The tablet** sends its token from `agent.json`. `pp-agent` does it directly. Stock sync can't add headers, so `pp-proxy` on the tablet does it for them. See [tablet-proxy/README.md](tablet-proxy/README.md).
- **Host (recommended, Cedar decides):** Render, a background worker with a 5 GB disk. See [hosting.md](hosting.md).

## ppd endpoints

| | |
| --- | --- |
| `GET /pp/healthz` | 200 if rmfakecloud answers, 503 if not. Includes the last backup |
| `GET /pp/problems` | 200 and an empty list when nothing needs a human, else 503 and the list: rmfakecloud down; the last backup failed or is over 26 h old (with backups on); a tablet silent over 72 h (`PP_REPORT_MAX_AGE`); its newest report says sync is failing (pp-proxy's last error is newer than its last good sync) or its release checks fail. For a daily monitor |
| `GET /pp/backup` | last backup result (`backup.sh` writes it) |
| `GET /pp/releases/<device>/<file>` | the feed: `latest.json`, `latest.json.sig`, `<id>.tar.gz`. Range works |
| `PUT /pp/releases/<device>/<file>` | publish one file, `Authorization: Bearer $PP_PUBLISH_TOKEN` |
| `POST /pp/status` | pp-agent's status report. Kept as `status/<device>/<time>.json`, newest 500 |
| `GET /pp/status/<device>[?n=N]` | the latest report, or the last N, newest first. The tablet's log tail is in each |
| `GET /pp/wishes/index.json`, `GET /pp/wishes/<folder>/<file>` | the wish inbox, read-only. `Authorization: Bearer $PP_READ_TOKEN` |
| `GET /pp/logs/server.log`, `server.log.1` | the container's log, read-only, Range works. Same token |
| anything else | rmfakecloud (sync API and web UI) |

Everything under `/pp/` is `Cache-Control: no-store`. Wish pages, logs and feed files also get `nosniff` and `Content-Security-Policy: sandbox`, so a browser runs nothing from them; feed files other than `.json` go out as `application/octet-stream`, and a PUT may only write `latest.json`, `latest.json.sig`, `<id>.tar.gz`, `<id>.json` or `<id>.json.sig`. This origin is also rmfakecloud's web UI, whose login cookie a page here would ride. An unset `PP_READ_TOKEN` turns wishes and logs off.

`agent.json` on the tablet: `"feed_url": "https://pp.<domain>/pp/releases/tatsu/"`, `"status_url": "https://pp.<domain>/pp/status"`, and the `pp-tablet` token in `headers`.

## Files

```
Dockerfile           the image: rmfakecloud @ commit, ppd, cloudflared, restic, Python + 2 wheels; bases pinned by digest
entrypoint.sh        starts the daemons, applies a staged restore, runs the backup and wish loops, keeps the log
compose.yaml         production shape for any Docker host: no ports
compose.local.yaml   local proof only: 127.0.0.1:3080, no tunnel, local restic repo
render.yaml          the recommended host's config
ppd/                 the front door (main.go + tests)
backup/              backup.sh, restore.sh
wishes/              wishes.py (the scanner; tools/wishes has its tests) and requirements.txt (hash-pinned)
scripts/             publish.sh (CI), rmfakecloud-cli (admin CLI as the right user)
tablet-proxy/        pp-proxy for the tablet, its unit, install.sh, test-tatsu.sh
test/                local-proof.sh, fakeaccess (a stand-in for Cloudflare Access), tablet-sync.py (a stand-in for rm-sync's upload)
```

## Runbook

### First deploy (not done yet)

1. **Cloudflare** (the domain must be on Cloudflare):
   - Zero Trust > Networks > Tunnels: create tunnel `pp-server`, type cloudflared. Copy its token into `TUNNEL_TOKEN`. Public hostname `pp.<domain>`, service `HTTP`, `localhost:3080`.
   - Zero Trust > Access > Service credentials: create service tokens `pp-tablet`, `pp-ci`, `pp-claude`.
   - Zero Trust > Access > Applications: a self-hosted app for `pp.<domain>`, all paths. Policies: `cedar` (Allow, Cedar's email), then `pp-tablet`, `pp-ci`, `pp-claude` (each Service Auth, that one token). Turn on returning 401 for failed service auth, so machines get an error instead of a login page.
   - Caching > Cache Rules: bypass cache for `pp.<domain>`.
2. **Backblaze B2:** a bucket, a key for that bucket only, no `deleteFiles` (see [hosting.md](hosting.md)).
3. **Secrets:** `openssl rand -base64 48` for `JWT_SECRET_KEY`, and `openssl rand -hex 32` for `PP_PUBLISH_TOKEN`, `PP_READ_TOKEN` and `RESTIC_PASSWORD`. Put each in the password manager first.
4. **Render:** New > Blueprint, this repo, fill in the `sync: false` values, deploy.
5. The log says `NO USERS`. In the Render shell: `rmfakecloud-cli setuser -u <email> -a -s` (it prints a password; `-a` admin, `-s` the sync the tablet uses; both are needed), then restart the service. rmfakecloud reads users only at start, and until a user exists the first web login becomes admin. Access keeps everyone but Cedar away from that window.
6. Check with the `pp-claude` token: `curl -H "CF-Access-Client-Id: …" -H "CF-Access-Client-Secret: …" https://pp.<domain>/pp/healthz`.
7. **Tablet** (over USB SSH): `agent.json` as above, then `device/install.sh --proxy root@10.11.99.1` (docs/runbook-bootstrap.md, step 7). It runs `tablet-proxy/install.sh --runtime` and persists that with `pp-device.sh`; there is no other install. Pairing: Cedar opens `https://pp.<domain>/`, logs in, Code > Generate, and types the code on the tablet under Settings > General > Account.
8. **Monitor:** something hits `GET /pp/problems` daily with the `pp-claude` token and tells Cedar on a 503: a scheduled Claude task, or an uptime monitor that can send Access headers (docs/cedar-checklist.md).

### Publish a release (CI)

```sh
ppsign pack -key release.key.pem -dir tree -id 2026-10-25.1 -os 3.27.2.2 -out feed -latest
PP_SERVER=https://pp.<domain> PP_PUBLISH_TOKEN=… CF_ACCESS_CLIENT_ID=… CF_ACCESS_CLIENT_SECRET=… \
  scripts/publish.sh feed 2026-10-25.1 --latest
```

The tarball goes first and `latest.json` last. The signing key never touches the server.

### What Claude reads

Claude's environment holds three values: the `pp-claude` Access token (`$ID`, `$SECRET`) and `PP_READ_TOKEN` (`$READ`).

```sh
A=(-H "CF-Access-Client-Id: $ID" -H "CF-Access-Client-Secret: $SECRET" -H "Authorization: Bearer $READ")
curl -fsS "${A[@]}" "https://pp.<domain>/pp/status/tatsu?n=10"          # what the tablet runs, its failures and log tail
curl -fsS "${A[@]}" -r -200000 https://pp.<domain>/pp/logs/server.log   # the server log, last 200 kB
curl -fsS "${A[@]}" https://pp.<domain>/pp/wishes/index.json            # wish pages picked up so far
curl -fsS "${A[@]}" -o page.png "https://pp.<domain>/pp/wishes/<folder>/page.png"
```

- **Tablet:** each status report has the running release, OS version, failures, the last 30 agent events and the last 4 KiB of `agent.log`. ppd logs one line per report (`status tatsu: os=… release=… result=… error=…`).
- **Server:** `server.log` has every line rmfakecloud, ppd, cloudflared, the backup and the wish scan print, each with a UTC time. It holds days to weeks (8 MiB at most); the host's own log view has the same lines.
- **Wishes:** a folder per page (`page.png`, `page.svg`, `page.rm`, `wish.json`, `issue.md`). Turning one into an issue is Claude's job: see [tools/wishes](../tools/wishes/README.md).

### Backups

- Nightly at `BACKUP_AT` (default 03:17) in `TZ`: `restic backup /data`, then keep 14 daily, 8 weekly and 12 monthly snapshots. On Sundays it also runs `restic check` on 10% of the data.
- Result in `/pp/backup` and `/pp/healthz`. A failed backup logs `backup: FAILED` and retries the next night. It never stops sync.
- Run one now: `backup.sh` in the Render shell.

### Restore

1. `restore.sh` (latest) or `restore.sh <snapshot>` in the shell. It restores into `/data/.restore`, verifies the files, and shows what would change.
2. Restart the service. The entrypoint swaps the restored data in before anything starts, and keeps the old data in `/data/.pre-restore-<time>` until you delete it.

Lost host: create the service again from the Blueprint with the same secrets from the password manager, then do the two steps. Keep `JWT_SECRET_KEY` the same, or the tablet has to pair again (its notes are safe either way). `test/local-proof.sh` step 7 drills exactly this.

### Upgrade rmfakecloud or a base image

Change `RMFAKECLOUD_COMMIT` or a digest in `Dockerfile`, or a version and its hashes in `wishes/requirements.txt` (from PyPI; the Python image and the Pillow wheels must agree on 3.13), run `make proof` here and `make test proof` in `tools/wishes`, merge. Never float a tag.

### Rotate or revoke the tablet's token

Make a new token in Zero Trust, put it in `agent.json` on the tablet, restart `pp-proxy` (`pp-agent` reads the file every run), delete the old token. To lock the tablet out right away, delete the token or remove its policy.

**This needs the USB cable**: `agent.json`, `pp-agent` and `pp-proxy` are installed once over SSH and are not part of a release (a broken agent could not roll itself back). So make the tablet's token **non-expiring**: an expired token cuts sync and the release feed at once, and only a cable fixes it. Revoking still works any time. Rotate only when it may have leaked.

## Secrets (names only)

| Name | Lives in | What |
| --- | --- | --- |
| `JWT_SECRET_KEY` | host secret store | signs rmfakecloud's tokens. Changing it logs the tablet out |
| `TUNNEL_TOKEN` | host secret store | cloudflared connector |
| `PP_PUBLISH_TOKEN` | host and CI | lets CI PUT feed files |
| `PP_READ_TOKEN` | host and Claude's environment | lets Claude read wish pages and logs |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` | host secret store | where and how backups are encrypted. **Without the password the backups are noise** |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | host secret store | the B2 key, one bucket only |
| `pp-tablet` service token | tablet `agent.json` (0600) | the tablet's identity |
| `pp-ci` service token, `PP_SERVER` | CI | publishing |
| `pp-claude` service token | Claude's environment | gets Claude through Access: status and health, and with `PP_READ_TOKEN` wishes and logs |
| release signing key | password manager, CI | agent lane; never on the server |
| rmfakecloud user password | password manager | the web UI |
| `proxy/key.pem` | the tablet only | made there by `pp-proxy gencert` |

Every one of these also goes in the password manager. None goes in the repo (`secrets.env` is gitignored).

## Known limits

- **rmfakecloud is tested upstream up to OS 3.27.1, and the tablet runs 3.27.2.2.** In the emulator, the stock 3.27.2.2 xochitl and rm-sync pair and sync both ways with the pinned commit through pp-proxy and a stand-in Access gate, unmodified (`test/e2e`, step `sync`). Still unproven on the real tablet.
- **Cloudflare caps request bodies at 100 MB** on Free and Pro. A single file bigger than that (a huge PDF) can't upload through the tunnel.
- **Backups read a live directory.** The tablet uploads blobs before it moves the root pointer, so a snapshot taken mid-sync can at worst miss the newest change. 03:17 is a quiet hour, and there are 14 dailies.
- **The log keeps days to weeks, not months:** 8 MiB at most. The e2e run wrote about 40 KB in 24 minutes of syncing, updating and reporting. Older history lives in the host's log view, for as long as the host keeps it.
- **Python makes the image bigger:** about 78 MB unpacked (the Python base 45 MB, rmscene and Pillow 33 MB). `docker images` here shows 266 MB before and 369 MB after.
- **Wishes are 15 minutes behind** the sync at worst (`WISHES_EVERY`, seconds). A scan that meets a half-synced tree fails and the next one catches up.
- rmfakecloud always starts an MQTT listener on 8883 inside the container. Nothing can reach it: no port is published and the tunnel routes only to 3080.
- A disk on Render means one instance, and a deploy is a short sync outage. The tablet retries.

## Tests

```sh
make test     # go vet, go test -race (ppd, pp-proxy), shellcheck. Seconds
make proof    # test/local-proof.sh: the whole thing below, about 2 minutes, leaves nothing running
PP_BUILD_CA=/root/.ccr/ca-bundle.crt make proof   # in the dev container (TLS-intercepting proxy)
```

## Status

Review fixes (Oct 25, 2026, evening, dev container):

- `make test` passes. New ppd tests: a PUT of `x.svg`, `notes.html` or a name without an extension is refused (400) even with the publish token; `<id>.tar.gz` and `.json.sig` are served as `application/octet-stream`, `latest.json` as JSON, all three with `nosniff` and `sandbox` (before: an uploaded `.html` came back as `text/html` on rmfakecloud's origin). `/pp/problems` goes from 200 to 503 and back through each case: no backup yet, a failed backup, one older than 26 h, a tablet report older than 72 h, sync failing (last error newer than last good sync), checks failing, then all good. pp-proxy test: `sync.json` counts only `/sync/` successes, any 4xx/5xx as an error with its path.
- `PP_BUILD_CA=/root/.ccr/ca-bundle.crt make proof`: **PASS 95**, 2.5 min, nothing left running. New: pp-proxy's `sync.json` after the simulated tablet's sync (`ok > 0`, `last_ok` set, 0 errors); `/pp/problems` says nothing needs a human after the backup, and `backup: none has run yet` with a 503 on the wiped server; `tablet-proxy/install.sh` with no argument refuses and changes nothing (its persistent and `--uninstall` modes are gone: `umount -R /etc` broke SSH until a reboot, `device/install.sh --proxy` persists instead).
- `pp-proxy.service` is ordered `Before=rm-sync`, no longer `Before=xochitl`: see `tablet-proxy/README.md` and `device/README.md` (passcode scenario).
- `render.yaml`: `autoDeployTrigger: checksPass`. The field and value are from Render's API client in `render-oss/cli` (`autodeploy_gen.go`: `checksPass`, `commit`, `off`); not tried on Render.

Verified (Oct 25, 2026, in the dev container), wishes and logs:

- `make test`: `go vet` clean, `go test -race` passes, shellcheck clean. New ppd tests: wish pages and logs refused with no token, a wrong one, the publish token, `Bearer ` with nothing after it, and a token without `Bearer`; refused even for missing files, so nothing leaks by 404 vs 403; served with the token, `index.json` as JSON, the log as `text/plain` whatever is in it, `nosniff` and `sandbox` on both; `PUT`, `POST`, `DELETE` give 405 and change nothing; dot folders (a scan in progress), `..`, a third level, `/pp/logs/.hidden` give 404; a Range tail of the log; an unset token turns both off. `logtee`: stdout byte for byte, UTC times in the file, rotation keeps the newest lines in order with none missing, and an unwritable file still copies everything to stdout plus one warning.
- Mutation check on a scratch copy, 13 mutations, each one alone: no read-token check, no segment check, any depth, any log file name, the log sniffed, no CSP, writes allowed, `Bearer` optional, an empty token matching, no rotation, no time, local time instead of UTC, logtee stopping on a file error. Every one makes a test fail. The first run missed three (depth, log names, the empty token: over HTTP a trailing space is trimmed, so only a direct test of `bearer` reaches it); tests were added for each.
- `PP_BUILD_CA=/root/.ccr/ca-bundle.crt make proof`: **PASS 91**, rc 0, 1m55s to 2m10s with the image rebuilt from cache (3 runs, the last after the final edits). New steps:
  - 7: after pairing, a stand-in for rm-sync (`test/tablet-sync.py`) uploads the two test notebooks from `tools/wishes/testdata` over sync v3 through pp-proxy, the gate and ppd: 10 blobs (8 files, 2 notebook indexes), a new root index, then the root pointer. It writes indexes by the rule a real 3.27.2.2 rm-sync tree follows: rebuilt with that rule, both indexes of the tree from the e2e run come out with the same bytes and names. Within the 5 s scan interval `/pp/wishes/index.json` lists exactly the 3 wish pages; each `page.rm` is byte-identical to the tablet's page, each `page.png` is a 1404x1872 PNG, each `issue.md` carries its key. Refused: no Access token (403 at the gate); Claude's Access token without the read token, the tablet's Access token alone, with the publish token, or with its rmfakecloud token (403 from ppd); `PUT` (405); `/pp/wishes/../status/tatsu` (404). A later scan leaves `index.json` unchanged.
  - 7b: `/pp/logs/server.log` has lines from the entrypoint, rmfakecloud (`got sync completed`), ppd (the status line, the refusals), and the wish scan (`3 new`, then `0 new, 3 unchanged`); every line starts with a UTC time; `-r -2000` returns 2000 bytes. Without the read token: 403 for Claude's and the tablet's Access tokens. The tablet's log tail is at `/pp/status/tatsu`.
  - 8: the restore drill brings back the wish inbox (`index.json` identical) with the rest: 42 files, sha256 identical.
- `tools/wishes` against this image: `make test` 22 passed; `make proof` PASS 10 with `HASH_SCHEMA_VERSION=3` and `=4`.
- Hash pinning: the image build installs with `--require-hashes --only-binary=:all:`. A changed hash fails (`THESE PACKAGES DO NOT MATCH THE HASHES`), and so does dropping the `packaging` line (`all requirements must have their versions pinned`). `pip download` for linux aarch64 and macOS arm64 passes the same file, so CI's arm64 runners and a Mac venv get checked wheels too.
- The entrypoint, by hand: `docker logs` and `/data/log/server.log` carry the same lines; a bad `BACKUP_AT`, a bad `WISHES_EVERY` (`0`, `abc`) or no `JWT_SECRET_KEY` still exits 1 with its reason visible; killing rmfakecloud stops the container (exit 1) with `a daemon exited` as the last line in both; `kill -9` on logtee stops the container too (exit 141, SIGPIPE), so the host restarts it rather than run without a log. `docker stop` takes about 1.3 s, exit 0 (up to 1 s waiting for the last log lines). A scan of the 3 test pages in the image: 1.7 s, 99 MB peak. Idle, the processes add up to about 44 MB RSS without cloudflared.

Verified earlier (Oct 25, 2026, in the dev container):

- `make test`: `go vet` clean. `ppd` tests pass with `-race`: the proxy to rmfakecloud, `/pp` never leaking to it, healthz 200 and 503, publish refused without, with a wrong, or with an empty token, a Range GET answered 206 with the right bytes, path tricks (`..`, dotfiles, extra segments) refused, status kept and pruned to N, history newest first, bad JSON, bad device names and oversize bodies refused. `pp-proxy` tests pass too (see its README).
- Mutation check on a scratch copy: removing any one of the publish-token check, the empty-token guard, the file-name or device-name check, pruning, the `/pp` routing, or the status size limit makes a test fail. The first run caught a real gap: an empty token matched a missing header. Fixed and tested.
- `PP_BUILD_CA=/root/.ccr/ca-bundle.crt test/local-proof.sh`, which rebuilds the image first: **PASS 59** then (91 now, above), rc 0, 2m14s (a cold image build adds about 1m40s). Steps:
  - The image builds from pinned digests and rmfakecloud commit `3c6de006`. `compose.yaml` alone publishes no port. Locally only `127.0.0.1:3080` is published. rmfakecloud and ppd run as uid `pp`, not root.
  - A user is created with the CLI. After the restart, web login works, `/health` says `Working`, and a PDF uploaded through the web UI is listed.
  - The fake Access gate refuses requests without the token (403) and lets the tablet's token through.
  - A release signed with a throwaway key (`ppsign`, agent lane) is published with `publish.sh` through the gate. A PUT without the publish token gets 403. The served `latest.json` is byte-identical to the signed one, and `Range: bytes=10-` returns 206 with the right bytes.
  - The real `pp-agent` (host build, fake sysfs) fails with 403 and installs nothing on a wrong token. On the right token it fetches, verifies, installs and health-checks `proof1`, and POSTs its status: the server returns `release=proof1`, `os_version=3.27.2.2` and the log tail.
  - A simulated tablet pairs and syncs through `pp-proxy`: discovery, a pairing code from the web UI, device and user tokens, `/sync/v3/root`. The root index lists the uploaded PDF. A name outside the cert fails TLS.
  - `pp-proxy` on the real 3.27.2.2 tatsu userland passes 18 checks (see its README).
  - Backup drill: the entrypoint's nightly loop, scheduled two minutes out, fires on time and backs up as `pp` to a local restic repo. A manual `backup.sh` from a root shell re-runs itself as `pp`, so no repo file is root-owned. Sunday's `restic check` reported no errors. The repo holds neither the user's email nor the file name in plaintext. The data volume is deleted and a fresh server starts with no users and no status. `restore.sh latest` and a restart bring every file back identical (sha256 of all 15). Then the same password logs in, the PDF is listed, the tablet status and the feed are back, the paired tablet's old token still reads the same sync root, and the agent reports again. Restored files are owned by `pp`.
  - Teardown leaves no containers and no volumes.
- The container stops cleanly on `docker stop` in 0.2 s, exit 0 (1.3 s now, above). A bad `TUNNEL_TOKEN` stops the whole container (exit 1) instead of running half up, and a bad `BACKUP_AT` refuses to start (exit 1) instead of silently skipping backups. Idle memory was about 11 MiB without cloudflared, before Python and logtee.
- `systemd-analyze verify` on `tablet-proxy/pp-proxy.service` against the tatsu systemd tree: clean.
- `render.yaml` parses. Its field names match those in Render's own CLI source (`render-oss/cli`).

Not verified:

- A wish from the real tablet through the server's own scan. Real rm-sync into rmfakecloud, then `tools/wishes` on a copy, is proven in the emulator (`test/e2e`, step `sync`); here the upload is our stand-in, with the same tree format.
- Python, the wheels and the scan on Render, and the wheels built on an arm64 host (only `pip download` was checked for arm64).
- Log volume over weeks with a real tablet, so how many days 8 MiB really holds.
- Anything on real Cloudflare (tunnel, Access policies, service tokens, the 401 setting, websockets through the tunnel) or on Render (Blueprint, disk, BuildKit `ADD <git>` and `--mount=type=secret` in their builder, shell, log retention). No accounts were made.
- Real sync from a real tablet. (From the emulator's stock xochitl on 3.27.2.2 it works: see `test/e2e/README.md`.)
- restic against B2, and the no-`deleteFiles` key setup.
- The tablet install on hardware (`device/install.sh --proxy`; tablet-proxy's own persistent mode is gone).
- Restores of large data sets (the drill had 15 files).

Open questions for Cedar:

- **Host:** Render (recommended, about $8/mo) or Fly.io (about $4/mo)? And which region (it sets `TZ` for the backup time)?
- **Domain:** which domain is on Cloudflare, so `pp.<domain>` exists?
- **Backups:** Backblaze B2 as the second provider?
- **Server logs for Claude:** done as option (c): the container keeps its own rotated log and ppd serves it to `PP_READ_TOKEN`. Render's API key (full account access) stays with Cedar.
- **Status reads:** `/pp/status/<device>` stays open to every token that passes Access (the tablet's and CI's too), as before; it holds what the tablet runs and its agent log, not notes. Move it behind the read token as well? `test/e2e` would need to send it.
- **A tighter Access app for Claude (optional):** a second Access app on `pp.<domain>/pp/` paths only, for the `pp-claude` policy, would keep Claude's Access token off rmfakecloud's pages entirely. Not needed while rmfakecloud's login guards them.
- **Auto-deploy:** `render.yaml` deploys a main commit that touches `server/` once its CI checks pass (`autoDeployTrigger: checksPass`). OK?
- **Token lifetime:** non-expiring for `pp-tablet` (recommended: renewing it needs the cable, see "Rotate"); CI's and Claude's can expire, they are renewed without the tablet.
