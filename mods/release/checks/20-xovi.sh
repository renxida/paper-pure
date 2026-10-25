#!/bin/bash
# pp-agent check: xochitl runs with xovi, qt-resource-rebuilder and AppLoad
# mapped, and the hashtab matches this xochitl. Read-only.
set -euo pipefail
s=$(/home/root/xovi/paper-pure/status)
echo "$s"
for want in "xovi ON" "mapped xovi.so" "mapped qt-resource-rebuilder.so" "mapped appload.so" "hashtab: ok"; do
    grep -qF "$want" <<<"$s" || { echo "check: missing '$want'" >&2; exit 1; }
done
