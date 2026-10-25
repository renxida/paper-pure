#!/bin/bash
# Build the hello app into an AppLoad app directory.
#   apps/hello/build.sh [OUT_DIR]        (default: apps/hello/out/paper-pure-hello)
# RELEASE_ID (env) is baked into the app; default "dev-<git short sha>".
# Needs Qt's rcc (apt: qt6-base-dev-tools). The .rcc is plain data, so one
# build serves the device and the host emulator.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/out/paper-pure-hello}
rcc=${RCC:-$(command -v rcc || echo /usr/lib/qt6/libexec/rcc)}
[ -x "$rcc" ] || { echo "build.sh: rcc not found (apt install qt6-base-dev-tools, or set RCC)" >&2; exit 1; }
id=${RELEASE_ID:-dev-$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)}
case $id in *[!A-Za-z0-9._-]*) echo "build.sh: bad RELEASE_ID '$id'" >&2; exit 1 ;; esac

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp -r "$here/ui" "$here/application.qrc" "$tmp/"
printf '.pragma library\nvar id = "%s";\n' "$id" > "$tmp/ui/release.js"

rm -rf "$out"; mkdir -p "$out"
cp "$here/manifest.json" "$out/"
"$rcc" --binary -o "$out/resources.rcc" "$tmp/application.qrc"
echo "$id" > "$out/release-id"
echo "built $out (release $id)"
