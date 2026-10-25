#!/bin/bash
# Rung 2 smoke test: in the emulator, open the side menu, tap AppLoad, launch
# hello, and check it really ran (its log line) and drew (screenshot).
#   mods/emu-smoke.sh [--install] [OUT_DIR]
# --install runs mods/install.sh emu first. Screenshots land in OUT_DIR
# (default: a temp dir, printed). Coordinates are for OS 3.27.2.2.
set -euo pipefail
mods=$(cd "$(dirname "$0")" && pwd)
ppemu=$(dirname "$mods")/emu/bin/ppemu
if [ "${1:-}" = --install ]; then shift; "$mods/install.sh" emu; fi
out=${1:-$(mktemp -d)}; mkdir -p "$out"

"$ppemu" wait --idle 5000 --timeout 300000 >/dev/null
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
container=${PPEMU_CONTAINER:-pp-emu-tablet}
"$ppemu" tap 56 60          # side menu
"$ppemu" screenshot "$out/1-sidebar.png" --scale 0.5 >/dev/null
"$ppemu" tap 152 660        # "AppLoad" (added by AppLoad's QML diff)
"$ppemu" screenshot "$out/2-appload.png" --scale 0.5 >/dev/null
"$ppemu" tap 142 204        # first app: Hello
for _ in $(seq 1 30); do
    line=$(docker logs --since "$since" "$container" 2>&1 | grep -ao 'paper-pure-hello: shown, release [A-Za-z0-9._-]*' | tail -n 1 || true)
    [ -n "$line" ] && break
    sleep 2
done
"$ppemu" screenshot "$out/3-hello.png" >/dev/null
[ -n "$line" ] || { echo "emu-smoke: FAIL, hello never logged 'shown' (screens in $out)"; exit 1; }
echo "emu-smoke: $line"
"$ppemu" tap 702 1692       # hello's Close button
"$ppemu" tap 60 54          # AppLoad's Back
"$ppemu" screenshot "$out/4-back.png" --scale 0.25 >/dev/null
echo "emu-smoke: ok, screenshots in $out"
