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
"$repo/mods/host/run.sh" "$tmp/paper-pure-hello" "$tmp/shot.png" 4000 2>&1 | grep -E 'paper-pure-hello|pp-shot' || true
[ -s "$tmp/shot.png" ] || { echo "test: no screenshot" >&2; exit 1; }
if [ "${1:-}" = --update ]; then cp "$tmp/shot.png" "$golden"; echo "test: golden updated"; exit 0; fi
cp "$tmp/shot.png" "${PP_TEST_OUT:-$tmp}/hello-host.png" 2>/dev/null || true
python3 -I "$repo/mods/host/pngdiff.py" "$golden" "$tmp/shot.png" --max-diff 0
