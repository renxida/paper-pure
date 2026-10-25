# CI

The guardrail from the desiderata: nothing merges, and nothing is released, unless the rungs pass. CI runs the same `make` targets you run on a laptop, so a red check means the same thing in both places.

## What runs where

`.github/workflows/ci.yml`, on every push to any branch, every pull request, and by hand (Actions, ci, Run workflow). A new push to a PR cancels that PR's older run.

| Job | Runner | Command | What it proves |
| --- | --- | --- | --- |
| `rung1` | `ubuntu-latest` (x86) | `make rung1` | agent and server: `go vet` and `go test -race`; wishes: pytest; arm64 cross-builds; shellcheck on every shell script; actionlint on this workflow; `node --check` on the emulator CLI; hello in AppLoad's PC emulator, pixel-exact against the golden |
| `proofs` | `ubuntu-24.04-arm` | `make proofs` | agent on the real tatsu userland; the server's local proof (publish, agent install through a fake Access gate, pp-proxy, backup, wipe, restore); wishes against a real rmfakecloud; the device test bed (OS freeze, persistence, kill switch, crash loops under the image's own systemd) |
| `rung2` | `ubuntu-24.04-arm` | `make rung2` | `test/e2e/run.sh`: the Pure's stock 3.27.2.2 in the emulator with our whole stack |
| `release` | `ubuntu-24.04-arm` | `make release`, `make publish` | only on a push to `main`, after all three passed: build, sign, publish |

Cheapest first: `proofs` and `rung2` start only once `rung1` is green. The arm64 runners are free because the repo is public, and they run the device's arm64 code natively, without qemu.

Every action is pinned to a full commit SHA, with the tag in a comment. To move one, look the tag up with `git ls-remote https://github.com/actions/checkout refs/tags/v7.0.1`, then run `make actionlint`. The token is read-only (`contents: read`). There is no `pull_request_target`, so code from a fork never runs with secrets.

## On a laptop

```bash
make rung1      # ~1 min once images are built
make proofs     # arm64 containers; slow under qemu on x86
make rung2      # the emulator; E2E_ARGS="--skip-build --keep" passes through
make loop       # rung1, then proofs, then rung2; stops at the first failure
```

Each step logs to `out/logs/<target>/<step>.log` and prints one PASS or FAIL line. A FAIL also prints the log's last 40 lines. `out/` ignores itself.

The host needs docker (with arm64 binfmt on x86), go, node 22, python3, shellcheck, ssh, ssh-keygen, curl, openssl, cpio and Qt's `rcc` (apt `qt6-base-dev-tools`). Behind a TLS-intercepting proxy, add `PP_BUILD_CA=/path/to/ca.pem`.

## Firmware

- **First run:** `make firmware` fetches the .swu from reMarkable's public mirror and checks it against the sha256 pinned in `emu/bin/ppemu`.
- **Cache:** after that it lives in the actions cache under `tatsu-swu-<sha256>`. Every job checks the sha256 again, so a bad cache entry fails the job.
- **Never redistributed:** it is never uploaded as an artifact and never goes in a release.
  - Only workflow runs can read the cache. A fork's PR can too, but that is the same file anyone can download from reMarkable.
  - GitHub evicts a cache entry nobody has used for 7 days. The next run fetches it again.
- **Docker layers are not cached.** Images are built inside our scripts with the default docker driver. Caching them would mean changing how every script builds. Native arm64 builds take minutes. Revisit if CI gets slow.

## Artifacts

- **rung2:** logs on every run (`rung2-logs`). Logs plus screenshots only when a run fails (`rung2-logs-and-screenshots`). The screenshots show reMarkable's UI, and on a public repo anyone signed in to GitHub can download artifacts, so they are kept 7 days.
- **rung1, proofs:** logs, only when the job fails. Kept 7 days.
- **release:** nothing is uploaded. The signed release goes to the feed, and its manifest goes in the job summary.

## What Cedar switches on

Agents can't change these settings. Until they are on, CI is advice, not a gate.

1. **Settings, Rules, Rulesets, New branch ruleset** named `main`:
   - Enforcement Active, target the default branch.
   - Restrict deletions and block force pushes.
   - Require a pull request before merging. Zero approvals is fine while it's just Cedar and Claude.
   - Require status checks to pass, and add `rung1`, `proofs` and `rung2`. They can be picked once they have run once.
   - Leave the bypass list empty.
2. **Settings, Environments, `release`.** The first run on `main` creates it.
   - Deployment branches: `main` only.
   - The secrets below go here, not in repo secrets, so only this job on `main` ever sees them.
   - Required reviewer: Cedar. Optional; see the trade-off below.
3. **Settings, Actions, General:**
   - Require approval for fork PR workflows from all outside contributors.
   - Workflow permissions: read repository contents.

## Secrets

All of them live in the `release` environment.

| Name | What |
| --- | --- |
| `PP_SIGNING_KEY` | the text of `release.key.pem` |
| `PP_FEED_URL` | the tablet's `feed_url`: `https://pp.<domain>/pp/releases/tatsu/` |
| `PP_PUBLISH_TOKEN` | ppd's publish token (server/README.md, setup step 3) |
| `PP_CF_ACCESS_CLIENT_ID`, `PP_CF_ACCESS_CLIENT_SECRET` | the `pp-ci` Cloudflare Access service token |

What the release job does with them:

- **None set:** it builds, packs with a throwaway key to check the tree, and succeeds with a notice.
- **No signing key:** nothing is signed and nothing is published.
- **Some feed secrets but not all:** it fails, because that is a mistake, not a choice.
- **All set:** `make publish` uploads tarball first and `latest.json` last. Then it reads `latest.json` back through Access and compares bytes, which catches an Access login page posing as success.

## The signing key

```bash
make -C agent build
agent/out/ppsign keygen -out ~/pp-keys
```

- **`release.key.pem` is the private half.** Put it in the password manager first, then in GitHub: `gh secret set PP_SIGNING_KEY --env release < ~/pp-keys/release.key.pem`. Then delete the file. Never in the repo.
- **`release.pub.pem` is the public half.** It goes on the tablet: `device/install.sh --agent --release-pub release.pub.pem ...`.
- **Rotating:** make a new pair, put the new public key on the tablet over USB, then replace the secret. The tablet then refuses anything signed with the old key.

## The trade-off, honestly

A signing key in CI means whoever controls this GitHub repo can ship code to the tablet: Cedar's account, a stolen token that can edit workflows or secrets, or a merged change that leaks the key. The tablet trusts the signature, and GitHub holds the key. We accept that because the desiderata want zero manual steps (row 7). Signing on Cedar's laptop would put a human on every release.

What limits the damage:

- **The merge gate.** A workflow change that leaks the key has to pass the ruleset and land on `main` first. PR runs get no secrets, and the environment only serves `main`.
- **Environment reviewer.** With a required reviewer on `release`, the key isn't handed out until Cedar clicks. That is one click per release; turn it on once the tablet holds notes that matter. An owner account can remove the reviewer, so 2FA on Cedar's GitHub account is the real lock.
- **Signed and OS-pinned releases.** The agent installs only releases signed with Cedar's key, newer than the one running, and listing the exact OS version on the tablet. Releases carry mods, never the OS.
- **Auto-rollback.** A release that breaks xochitl fails the health check and is rolled back. The boot guard catches boot loops.
- **Kill switch.** Triple-press power, or `touch /home/root/paper-pure/disable`. A reboot is stock.
- **Revocation.** Rotate the key over USB. Until then, flight mode stops all pulls.

The gap: a malicious release that stays healthy (say, a mod that copies notes out) passes every check. Only review and the account lock stop that.

One more honest note: the release job rebuilds from the same commit rather than shipping the bytes rung2 tested. The id is baked into the apps, and the sources are pinned by commit, so the input is the same; the build is not proven bit-for-bit reproducible.

## Status

Oct 25 2026, x86_64 dev container (no arm64 machine, no GitHub runs yet).

Verified:

- **`make rung1` passes:** 8 of 8 steps, 52 s warm.
  - Negative check: a fake `shellcheck` that always fails on PATH gives FAIL for server, wishes, shellcheck and actionlint, `4 passed, 4 failed`, and exit 1.
- **actionlint v1.7.12 passes on `ci.yml`.** Planted errors are caught: an unknown runner label, and an unquoted `[ -n $X ]` that shellcheck flags inside a `run:` block. The composite action's `run:` lines were shellchecked by hand.
- **`make firmware`:** the fetch from the mirror took 7 s and the sha256 matched. A second run re-checks the file. A copy with one byte changed is refused and deleted, exit 1.
- **`make release` without a key** (in a scratch copy, since it rewrites `mods/out`):
  - mods build 22 s cached, and `check-abi: ok against pp-emu-rootfs:3.27.2.2`.
  - It packed and verified with a throwaway key, printed `NOT SIGNED`, created no `out/feed/`, and exited 0.
- **`make release` with a throwaway key:**
  - `out/feed/` holds the tarball, manifest, sig, `latest.json` and `release-id`.
  - `ppsign verify` with that key's `release.pub.pem` gives `ok`.
  - The app inside shows the release id, and the tarball holds no reMarkable files.
- **`make publish` against the real ppd behind the server lane's fake Access gate:**
  - Missing env, a bad URL shape, no Access token (403) and a wrong publish token (403) all fail.
  - With everything right, all five files are published and the served `latest.json` is byte-identical.
  - Against a server that answers every request with a 302 to a login page, `publish.sh` alone prints success for every file, and our readback says FAIL.
- **One rootfs import serves three names:** `pp-emu-rootfs` (debugfs import) and `pp-device-rootfs` (tar of the extracted tree) have the same 12178 entries with the same modes, owners and sizes. They also have the same sha256 for every file under `/etc` and `/usr/lib/systemd`, apart from docker's injected `/etc/hosts` and `/etc/hostname`.

Not verified:

- **Any real GitHub Actions run:** the arm64 runners, the cache, artifacts, the environment, or the notice and summary output.
- **`make rung2`:** `test/e2e/run.sh` didn't exist when this was written.
- **`make proofs` on arm64:** see below for the x86 run.
- **The `rootfs` target's import path on a fresh machine:** the images already existed here. `emu/tools/import-rootfs.sh` itself was proven by the emu lane.
- **Publishing through real Cloudflare Access.**
