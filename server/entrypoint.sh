#!/bin/bash
# pp-server entrypoint: one container, three daemons and two loops.
#   rmfakecloud  127.0.0.1-only in practice (no port is published), :3000
#   ppd          :3080, the front door; cloudflared points here
#   cloudflared  dials out to Cloudflare; only if TUNNEL_TOKEN is set
#   backup loop  restic once a day at BACKUP_AT (TZ); only if RESTIC_REPOSITORY is set
#   wishes loop  wishes.py every WISHES_EVERY seconds (default 900): new wish
#                pages -> $PP_DATA/pp/wishes, which ppd serves at /pp/wishes/
# Everything any of them prints goes through `ppd logtee`: to stdout for the
# host's log view, and to $PP_DATA/log/server.log, which ppd serves at /pp/logs/.
# If any daemon or loop exits, everything stops and the host restarts the container.
set -euo pipefail

D="${PP_DATA:-/data}"
AS_PP=(setpriv --reuid=pp --regid=pp --init-groups --inh-caps=-all)   # drop root; each daemon is its own job
mkdir -p "$D/log"
chown pp:pp "$D/log"
exec > >("${AS_PP[@]}" ppd logtee -file "$D/log/server.log") 2>&1
LOGTEE=$!
# shellcheck disable=SC2317  # run by the EXIT trap
drain() { # however we exit: let logtee write the last lines before the kernel kills it with PID 1
    exec >&- 2>&-
    for _ in $(seq 10); do kill -0 "$LOGTEE" 2>/dev/null || break; sleep 0.1; done
}
trap drain EXIT

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

date -d "today ${BACKUP_AT:=03:17}" >/dev/null 2>&1 || { echo "entrypoint: bad BACKUP_AT '$BACKUP_AT' (want HH:MM)" >&2; exit 1; }
case "${WISHES_EVERY:=900}" in
    '' | *[!0-9]* | 0) echo "entrypoint: bad WISHES_EVERY '$WISHES_EVERY' (want seconds)" >&2; exit 1 ;;
esac

mkdir -p "$DATADIR" "$D/pp"
chown -R pp:pp "$D"   # files a root shell or a restore left behind
case "${RESTIC_REPOSITORY:-}" in   # a local repo (the restore drill) must be ours too
    /*) mkdir -p "$RESTIC_REPOSITORY" && chown pp:pp "$RESTIC_REPOSITORY" ;;
esac

if ! "${AS_PP[@]}" rmfakecloud listusers 2>/dev/null | grep -q .; then
    # rmfakecloud makes the first web login an admin, and a user created with
    # the CLI while it runs isn't seen until restart (first login then fails).
    echo "entrypoint: NO USERS. Run: rmfakecloud-cli setuser -u EMAIL -a -s   then restart the container"
fi
PIDS=()
"${AS_PP[@]}" rmfakecloud &
PIDS+=($!)
# /pp/problems: a tablet silent for PP_REPORT_MAX_AGE, and with backups on, a
# last good backup older than PP_BACKUP_MAX_AGE, are problems.
PPD=(ppd -addr :3080 -data "$D/pp" -logs "$D/log" -upstream http://127.0.0.1:3000 -report-max-age "${PP_REPORT_MAX_AGE:-72h}")
[ -z "${RESTIC_REPOSITORY:-}" ] || PPD+=(-backup-max-age "${PP_BACKUP_MAX_AGE:-26h}")
"${AS_PP[@]}" "${PPD[@]}" &
PIDS+=($!)

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    "${AS_PP[@]}" cloudflared tunnel --no-autoupdate run &   # reads TUNNEL_TOKEN
    PIDS+=($!)
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
        backup.sh || echo "backup: FAILED (see above); retrying tomorrow"
    done
}
if [ -n "${RESTIC_REPOSITORY:-}" ]; then
    backup_loop &
    PIDS+=($!)
else
    echo "entrypoint: RESTIC_REPOSITORY not set, no backups"
fi

wishes_loop() {   # a half-synced tree fails the scan; the next run picks it up
    while :; do
        if [ -d "$DATADIR/users" ]; then
            "${AS_PP[@]}" python3 -I /usr/local/bin/wishes.py scan --rmfakecloud "$DATADIR" --inbox "$D/pp/wishes" \
                || echo "wishes: scan failed (above); next try in ${WISHES_EVERY}s"
        fi
        sleep "$WISHES_EVERY"
    done
}
wishes_loop &
PIDS+=($!)

stop() { kill -TERM "${PIDS[@]}" 2>/dev/null || true; wait "${PIDS[@]}" 2>/dev/null || true; }
trap 'stop; exit 0' TERM INT
wait -n "${PIDS[@]}" || true
echo "entrypoint: a daemon exited; stopping the container" >&2
stop
exit 1
