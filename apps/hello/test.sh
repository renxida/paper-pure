#!/bin/bash
# Rung 1 for hello: build it with a fixed release id, run it headless in
# AppLoad's PC emulator (mods/host), and compare with the golden screenshot.
#   apps/hello/test.sh            pass/fail
#   apps/hello/test.sh --update   accept the current screenshot as golden
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
golden=$here/test/host-golden.png
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

RELEASE_ID="test" "$here/build.sh" "$tmp/paper-pure-hello" >/dev/null
# The screen as it opens, then a finger on Close (the button's centre).
PP_EVENTS="tap 702 1692; wait 1500; shot /out/closed.png" \
    "$repo/mods/host/run.sh" "$tmp/paper-pure-hello" "$tmp/shot.png" 4000 > "$tmp/log" 2>&1 || true
grep -E 'paper-pure-hello|pp-shot' "$tmp/log" || true
[ -s "$tmp/shot.png" ] || { echo "test: no screenshot" >&2; cat "$tmp/log" >&2; exit 1; }
if [ "${1:-}" = --update ]; then cp "$tmp/shot.png" "$golden"; echo "test: golden updated"; exit 0; fi
cp "$tmp/shot.png" "${PP_TEST_OUT:-$tmp}/hello-host.png" 2>/dev/null || true
python3 -I "$repo/mods/host/pngdiff.py" "$golden" "$tmp/shot.png" --max-diff 0
grep -q 'paper-pure-hello: unloading' "$tmp/log" || { echo "test: FAIL tapping Close did not close the app (no unloading())" >&2; exit 1; }
[ -s "$tmp/closed.png" ] || { echo "test: FAIL no screenshot after Close" >&2; exit 1; }
if python3 -I "$repo/mods/host/pngdiff.py" "$golden" "$tmp/closed.png" --max-diff 0 > /dev/null; then
    echo "test: FAIL the screen after Close still shows the app" >&2; exit 1
fi
echo "test: Close closed the app (unloading() ran, the screen changed)"
