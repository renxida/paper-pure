#!/bin/bash
# Restore a backup. Two steps, so nothing is swapped under a running server:
#
#   1. restore.sh [SNAPSHOT]   (default: latest) restores into $PP_DATA/.restore,
#                              verifies the files, shows what would change
#   2. restart the container   the entrypoint swaps the restored data in before
#                              any daemon starts; the old data is kept in
#                              $PP_DATA/.pre-restore-<time> until you delete it
#
# Works the same on a fresh empty disk (disaster recovery) and on a live one.
# Needs the same RESTIC_* (and AWS_*) secrets as backup.sh, from the password
# manager if the old host is gone. Keep JWT_SECRET_KEY the same too, or the
# tablet has to pair again (its notes are safe either way).
set -euo pipefail
if [ "$(id -u)" = 0 ]; then exec setpriv --reuid=pp --regid=pp --init-groups "$0" "$@"; fi   # as pp, like backup.sh

D="${PP_DATA:-/data}"
SNAP="${1:-latest}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set}" "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"
STAGE="$D/.restore/staging"

restic snapshots --host pp-server --compact
rm -rf "$D/.restore"
mkdir -p "$STAGE"
echo "restore: snapshot $SNAP -> $STAGE"
restic restore "$SNAP" --host pp-server --target "$STAGE" --verify
[ -d "$STAGE$D/rmfakecloud" ] || { echo "restore: no rmfakecloud data in snapshot $SNAP" >&2; exit 1; }

echo "restore: $(find "$STAGE$D" -type f | wc -l) files restored"
echo "restore: difference from the live data (empty = identical):"
diff -rq "$D/rmfakecloud" "$STAGE$D/rmfakecloud" 2>&1 | sed 's/^/    /' | head -n 50 || true

restic snapshots "$SNAP" --host pp-server --json | head -c 300 > "$D/.restore/READY"
echo
echo "restore: staged. Restart the container to swap it in."
