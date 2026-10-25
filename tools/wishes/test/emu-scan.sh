#!/bin/bash
# Scan the running emulator (emu/) like the server scans rmfakecloud: copy the
# xochitl folder out with ppemu, then emit new wish pages into the inbox.
#   tools/wishes/test/emu-scan.sh [INBOX]      (default tools/wishes/.inbox-emu)
set -euo pipefail
cd "$(dirname "$0")/.."
INBOX=${1:-$PWD/.inbox-emu}
PY=${PYTHON:-.venv/bin/python}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
../../emu/bin/ppemu pull /home/root/.local/share/remarkable/xochitl "$W" >/dev/null
"$PY" -I wishes.py scan --xochitl "$W/xochitl" --inbox "$INBOX"
