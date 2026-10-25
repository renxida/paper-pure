#!/bin/bash
# Back up everything under $PP_DATA (notes, users, feed, status) with restic,
# then thin old snapshots. The entrypoint runs this once a day; you can run
# it by hand any time. Result: $PP_DATA/pp/backup/last.json, served at
# /pp/backup and folded into /pp/healthz.
#
# Needs: RESTIC_REPOSITORY, RESTIC_PASSWORD, and for s3: repos
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.
set -euo pipefail
# Always as pp, like the nightly run, so a root shell can't leave root-owned
# repo or status files behind.
if [ "$(id -u)" = 0 ]; then exec setpriv --reuid=pp --regid=pp --init-groups "$0" "$@"; fi

D="${PP_DATA:-/data}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set}" "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"
STATUS="$D/pp/backup/last.json"
mkdir -p "$(dirname "$STATUS")"
started=$(date -u +%FT%TZ)
out=$(mktemp)
trap 'rm -f "$out"' EXIT

report() { # ok error summary-json
    local err=${2//\\/\\\\}; err=${err//\"/\\\"}; err=${err//$'\n'/ }
    printf '{"ok":%s,"started":"%s","finished":"%s","repository":"%s","error":"%s","summary":%s}\n' \
        "$1" "$started" "$(date -u +%FT%TZ)" "${RESTIC_REPOSITORY%%\?*}" "$err" "${3:-null}" > "$STATUS.tmp"
    mv "$STATUS.tmp" "$STATUS"
}
fail() { echo "backup: $1" >&2; report false "$1"; exit 1; }

if ! restic cat config >/dev/null 2>"$out"; then
    if grep -qiE 'does not exist|unable to open config|no such file' "$out"; then
        echo "backup: no repository yet, creating one"
        restic init || fail "restic init failed"
    else
        fail "cannot open repository: $(tail -n 3 "$out")"
    fi
fi

echo "backup: $D -> ${RESTIC_REPOSITORY%%\?*}"
restic backup --host pp-server --tag nightly --json \
    --exclude "$D/pp/backup" --exclude "$D/.restore" --exclude "$D/.pre-restore-*" \
    "$D" > "$out" || fail "restic backup failed: $(grep -v '"message_type":"status"' "$out" | tail -n 3)"
summary=$(grep '"message_type":"summary"' "$out" | tail -n 1)
echo "backup: $summary"

# 14 daily, 8 weekly, 12 monthly. Deleted notes stay recoverable for months.
restic forget --host pp-server --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune --quiet \
    || fail "restic forget/prune failed"
# Sundays: re-read a sample of the stored data, so rot shows up before a restore needs it.
if [ "$(date +%u)" = 7 ] || [ "${BACKUP_CHECK:-}" = 1 ]; then
    restic check --read-data-subset=10% || fail "restic check failed"
fi
report true "" "${summary:-null}"
echo "backup: ok"
