#!/bin/bash
# Rung 1: run one AppLoad app in AppLoad's PC emulator, headless, and save a
# screenshot of the Pure-sized screen (1404x1872).
#   mods/host/run.sh APP_DIR OUT.png [DELAY_MS]
#   PP_EVENTS="tap X Y; wait MS; shot /out/NAME.png"   then taps and more
#   screenshots (shot.cpp); /out is OUT.png's directory
# APP_DIR is a built app (manifest.json + resources.rcc), e.g.
# apps/hello/out/paper-pure-hello. Builds the image pp-mods-host on first use.
set -euo pipefail
mods=$(cd "$(dirname "$0")/.." && pwd)
app=$(cd "${1:?usage: run.sh APP_DIR OUT.png [DELAY_MS]}" && pwd)
out=${2:?usage: run.sh APP_DIR OUT.png [DELAY_MS]}
delay=${3:-3000}
image=pp-mods-host:latest
id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$app/manifest.json")
[ -n "$id" ] || { echo "run.sh: no id in $app/manifest.json" >&2; exit 1; }

if ! docker image inspect "$image" >/dev/null 2>&1 || [ "${PP_HOST_REBUILD:-0}" = 1 ]; then
    commit=$(awk '$1=="rm-appload"{print $3}' "$mods/versions.lock")
    ctx=$(mktemp -d); trap 'rm -rf "$ctx"' EXIT
    git_dir=${PP_MODS_CACHE:-$mods/.cache}/git/rm-appload
    [ -d "$git_dir/.git" ] || git clone -q https://github.com/asivery/rm-appload "$git_dir"
    mkdir -p "$ctx/src"
    git -C "$git_dir" archive --format=tar --prefix=rm-appload/ "$commit" | tar -x -C "$ctx/src"
    cp -r "$mods/host" "$ctx/host"
    docker build -q -t "$image" -f "$mods/host/Dockerfile" "$ctx" >/dev/null
fi

outdir=$(cd "$(dirname "$out")" && pwd)
docker run --rm --name "pp-mods-host-$$" \
    -v "$app:/opt/appload/applications_root/$id:ro" -v "$outdir:/out" \
    -e PP_SHOT="/out/$(basename "$out")" -e PP_SHOT_DELAY_MS="$delay" -e PP_EVENTS="${PP_EVENTS:-}" \
    "$image" "$id"
