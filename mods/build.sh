#!/bin/bash
# Build the mod stack for the Paper Pure from pinned upstream sources.
#   mods/build.sh   -> mods/out/xovi-tatsu.tar.gz (for install.sh), mods/out/release/
#                      (a pp-agent release tree), BUILDINFO, elf-info.txt
#   RELEASE_ID=2026-10-25.1 mods/build.sh   (baked into apps; default dev-<git sha>)
# Needs git and docker with buildx. On x86 also qemu-user binfmt for arm64.
# Behind a TLS-intercepting proxy: PP_BUILD_CA=/path/to/ca.pem (for cargo).
# First run ~15 min under qemu (apt layer); cached runs are a few minutes.
set -euo pipefail
mods=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$mods")
cache=${PP_MODS_CACHE:-$mods/.cache}
out=$mods/out
id=${RELEASE_ID:-dev-$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)}

ctx=$cache/ctx
mkdir -p "$cache/git" "$ctx/src"

# 1. Fetch every pinned source and prove we have exactly that commit.
while read -r name url commit _; do
    case $name in ''|'#'*) continue ;; esac
    g=$cache/git/$name
    if [ ! -d "$g/.git" ]; then git clone -q "$url" "$g"; fi
    if ! git -C "$g" cat-file -e "$commit^{commit}" 2>/dev/null; then git -C "$g" fetch -q origin; fi
    rm -rf "$ctx/src/$name"
    git -C "$g" worktree prune
    git -C "$g" archive --format=tar --prefix="$name/" "$commit" | tar -x -C "$ctx/src"
    got=$(git -C "$g" rev-parse "$commit^{commit}")
    [ "$got" = "$commit" ] || { echo "build.sh: $name is $got, want $commit" >&2; exit 1; }
    echo "$name $commit" 
done < "$mods/versions.lock" > "$ctx/src/BUILDINFO.tmp"

# qmldiff is a git submodule of rm-xovi-extensions: check the pin matches it.
sub=$(git -C "$cache/git/rm-xovi-extensions" ls-tree "$(awk '$1=="rm-xovi-extensions"{print $3}' "$mods/versions.lock")" qt-resource-rebuilder/qmldiff | awk '{print $3}')
want=$(awk '$1=="qmldiff"{print $3}' "$mods/versions.lock")
[ "$sub" = "$want" ] || { echo "build.sh: rm-xovi-extensions wants qmldiff $sub, versions.lock says $want" >&2; exit 1; }
rmdir "$ctx/src/rm-xovi-extensions/qt-resource-rebuilder/qmldiff" 2>/dev/null || true
cp -r "$ctx/src/qmldiff" "$ctx/src/rm-xovi-extensions/qt-resource-rebuilder/qmldiff"

# BUILDINFO goes into the tarball (no timestamp, so builds are reproducible).
{ echo "paper-pure mods build"; echo "release $id"; echo "device tatsu, OS 3.27.2.2"; echo "sources:"; sed 's/^/  /' "$ctx/src/BUILDINFO.tmp"; echo "sha256:"; } > "$ctx/BUILDINFO"
rm "$ctx/src/BUILDINFO.tmp"

# 2. Our apps.
rm -rf "$ctx/apps"; mkdir -p "$ctx/apps"
cp -r "$repo/apps/hello" "$ctx/apps/hello"; rm -rf "$ctx/apps/hello/out"

rm -rf "$ctx/device"; cp -r "$mods/device" "$ctx/device"

# 3. Build in an arm64 container; results land in mods/out.
rm -rf "$out"
secret=()
[ -n "${PP_BUILD_CA:-}" ] && secret=(--secret "id=ca,src=$PP_BUILD_CA")
docker buildx build --platform linux/arm64 --build-arg RELEASE_ID="$id" "${secret[@]}" \
    -f "$mods/build/Dockerfile" --output "type=local,dest=$out" "$ctx"
"$mods/build/check-abi.sh" "$out/xovi-tatsu.tar.gz"

# 4. A pp-agent release tree: the xovi tree plus our hooks and checks.
#    agent/out/ppsign pack -dir mods/out/release -id "$id" -os 3.27.2.2 \
#        -expect-mapped xovi.so -expect-mapped appload.so ...
mkdir -p "$out/release"
tar -xzf "$out/xovi-tatsu.tar.gz" -C "$out/release"
cp -r "$mods/release/hooks" "$mods/release/checks" "$out/release/"
echo "mods/build.sh: $out/xovi-tatsu.tar.gz and $out/release/ (release $id)"
