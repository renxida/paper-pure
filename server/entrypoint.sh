#!/bin/bash
# pp-server entrypoint: one container, three daemons and a backup loop.
#   rmfakecloud  127.0.0.1-only in practice (no port is published), :3000
#   ppd          :3080, the front door; cloudflared points here
#   cloudflared  dials out to Cloudflare; only if TUNNEL_TOKEN is set
#   backup loop  restic once a day at BACKUP_AT (TZ); only if RESTIC_REPOSITORY is set
# If any daemon exits, everything stops and the host restarts the container.
set -euo pipefail

D="${PP_DATA:-/data}"
export DATADIR="$D/rmfakecloud" PORT=3000
: "${JWT_SECRET_KEY:?JWT_SECRET_KEY must be set (openssl rand -base64 48), or every restart logs the tablet out}"
export STORAGE_URL="${STORAGE_URL:-https://local.appspot.com}" RM_HTTPS_COOKIE="${RM_HTTPS_COOKIE:-true}"

# A restore staged by restore.sh is swapped in here, before anything runs.
if [ -f "$D/.restore/READY" ]; then
    old="$D/.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "entrypoint: applying staged restore; old data kept in $old"
    mkdir -p "$old"
    for d in rmfakecloud pp; do
        if [ -e "$D/$d" ]; then mv "$D/$d" "$old/"; fi
        if [ -e "$D/.restore/staging$D/$d" ]; then mv "$D/.restore/staging$D/$d" "$D/$d"; fi
    done
    rm -rf "$D/.restore"
fi

mkdir -p "$DATADIR" "$D/pp"
chown -R pp:pp "$D"   # files a root shell or a restore left behind
case "${RESTIC_REPOSITORY:-}" in   # a local repo (the restore drill) must be ours too
    /*) mkdir -p "$RESTIC_REPOSITORY" && chown pp:pp "$RESTIC_REPOSITORY" ;;
esac
as_pp() { setpriv --reuid=pp --regid=pp --init-groups --inh-caps=-all "$@"; }

as_pp rmfakecloud &
as_pp ppd -addr :3080 -data "$D/pp" -upstream http://127.0.0.1:3000 &

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    as_pp cloudflared tunnel --no-autoupdate run &   # reads TUNNEL_TOKEN
else
    echo "entrypoint: TUNNEL_TOKEN not set, no tunnel (local mode)"
fi

backup_loop() {
    while :; do
        now=$(date +%s)
        next=$(date -d "today $BACKUP_AT" +%s)
        [ "$next" -gt "$now" ] || next=$(date -d "tomorrow $BACKUP_AT" +%s)
        echo "backup: next run $(date -d "@$next" '+%F %T %Z')"
        sleep $((next - now))
        as_pp backup.sh || echo "backup: FAILED (see above); retrying tomorrow"
    done
}
if [ -n "${RESTIC_REPOSITORY:-}" ]; then
    backup_loop &
else
    echo "entrypoint: RESTIC_REPOSITORY not set, no backups"
fi

stop() { jobs -p | xargs -r kill -TERM 2>/dev/null || true; wait; }
trap 'stop; exit 0' TERM INT
wait -n
echo "entrypoint: a daemon exited; stopping the container" >&2
stop
exit 1
