# Which managed host

Cedar's open question. What we need: one container, one persistent disk, no public ingress (cloudflared dials out), a secret store, logs, and someone else patching the OS. Comfort over cost.

Nothing here was signed up for or deployed. Prices and features are from the providers' docs as of early 2026 and could not be re-checked from the dev container (their sites are blocked there). Check them before paying.

| | Render | Fly.io | Railway | Managed VPS (e.g. Hetzner, DigitalOcean) |
| --- | --- | --- | --- | --- |
| Shape | Background worker: a container with no inbound traffic at all | Machine with no `[services]`, so no public IP | Service with no generated domain | A Linux box |
| Disk | Persistent disk, $0.25/GB-mo, daily snapshots kept 7 days | Volume, $0.15/GB-mo, daily snapshots (5 days default). Lives on one physical host; not replicated | Volume, usage-priced, backups you schedule | Block storage plus provider backups |
| Price for us | Starter worker $7 + 5 GB disk, about $8/mo flat | shared-cpu-1x 256-512 MB about $2-4/mo plus disk, usage-billed | Hobby $5/mo includes $5 usage | about $5/mo |
| Deploy | From this repo with `render.yaml` (Blueprint), on push to main | `flyctl deploy` from CI with an API token | From GitHub | Ours to build |
| Secrets | Env vars and secret files in the dashboard | `fly secrets set` | Variables | Ours |
| Logs | Dashboard, log streams, API | `fly logs` (recent only), log shipping | Dashboard | Ours |
| Shell for a restore | Yes (paid plans) | `fly ssh console` | Yes | Yes |
| Who patches the OS | Render | Fly | Railway | **Cedar** |
| Catch | A service with a disk is one instance; deploys have a short outage | Volume tied to one host: if that host dies, you restore from a snapshot or from restic. You run Machines with a CLI | Usage-based bill; newest of the three | Breaks "Cedar never maintains a bare server" |

## Recommendation: Render, background worker with a 5 GB disk

- **Boring and flat.** One worker, one disk, about $8 a month, no machines to manage. The worker type has no ingress to misconfigure.
- **Deploys from this repo.** `render.yaml` is the whole host config. `buildFilter` redeploys only when `server/` changes, and CI gates merges, so Claude can ship server changes with zero manual steps (row 7).
- **Two safety nets for notes.** Render's daily disk snapshots, plus our nightly restic copy to a second provider (row 1). The tablet also keeps its own copy.
- **Secrets stay in Render's store** and the password manager, never in the repo.

Runner-up: **Fly.io.** Cheaper, and fine, but the volume lives on one physical host and you operate Machines with `flyctl`. Pick it if cost matters more than comfort; the same image runs unchanged (it needs a `fly.toml` with a `[mounts]` section and no `[services]`).

Not Railway: usage billing and less of a track record, with no gain for us. Not a VPS: someone has to patch it, and that someone would be Cedar.

## Backups go to a second provider: Backblaze B2

restic speaks S3 to B2 (`RESTIC_REPOSITORY=s3:https://s3.<region>.backblazeb2.com/<bucket>`). At notebook scale it costs cents a month. Not Cloudflare R2: Cloudflare is already the front door, and "second provider" means a different company.

Set it up so a compromised server can't destroy the history:

- A bucket for this alone, with a lifecycle rule that keeps prior versions for 30 days.
- An application key for that bucket only, with read, write and list but **no `deleteFiles`**. restic's deletes (locks, pruned packs) then only hide files, and the hidden versions stay for 30 days.

(Not verified: restic against B2 with a key that has no `deleteFiles`. The drill ran against a local repo.)

## Open questions for Cedar

- Render, or Fly.io?
- Which region, and so which `TZ` for the 03:17 backup?
- Which domain is on Cloudflare, so the hostname `pp.<domain>` exists?
