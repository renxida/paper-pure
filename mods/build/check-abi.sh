#!/bin/bash
# Prove our binaries only need what the tablet's OS provides: every NEEDED
# library exists in the rootfs, and every versioned symbol reference
# (GLIBC_2.x, GLIBCXX_3.4.x, Qt_6.x, ...) is defined by that library there.
#   mods/build/check-abi.sh mods/out/xovi-tatsu.tar.gz
# Reads the stock rootfs from the emulator's image (PP_ROOTFS_IMAGE, default
# pp-emu-rootfs:3.27.2.2, made by emu/tools/import-rootfs.sh). Needs readelf.
set -euo pipefail
tarball=${1:?usage: check-abi.sh xovi-tatsu.tar.gz}
image=${PP_ROOTFS_IMAGE:-pp-emu-rootfs:3.27.2.2}
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "check-abi: SKIPPED, no $image (run emu/bin/ppemu setup first)" >&2
    exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"; docker rm -f "pp-mods-abi-$$" >/dev/null 2>&1 || true' EXIT
tar -xzf "$tarball" -C "$tmp"
mapfile -t sos < <(find "$tmp/xovi" -name '*.so' -type f | sort)

# NEEDED libs of all our .so files, then copy those out of the rootfs.
needed=$(for f in "${sos[@]}"; do readelf -d -W "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; done | sort -u)
docker create --platform linux/arm64 --name "pp-mods-abi-$$" "$image" /bin/true >/dev/null
mkdir -p "$tmp/rootfs"
fail=0
for lib in $needed; do
    if ! docker cp -L "pp-mods-abi-$$:/usr/lib/$lib" "$tmp/rootfs/$lib" >/dev/null 2>&1; then
        echo "check-abi: FAIL $lib is not in the rootfs"; fail=1
    fi
done

# Version definitions per library, as "lib name" lines.
for lib in "$tmp"/rootfs/*; do
    readelf -V -W "$lib" | awk -v l="$(basename "$lib")" '/Version definition section/{d=1;next} /Version needs section/{d=0} d && /Name:/{for(i=1;i<=NF;i++) if($i=="Name:") print l, $(i+1)}'
done | sort -u > "$tmp/defs"

for f in "${sos[@]}"; do
    readelf -V -W "$f" | awk '/Version needs section/{n=1;next} /Version definition section/{n=0} n && /File:/{for(i=1;i<=NF;i++) if($i=="File:") file=$(i+1)} n && /Name:/{for(i=1;i<=NF;i++) if($i=="Name:") print file, $(i+1)}' | sort -u > "$tmp/needs"
    while read -r lib ver; do
        grep -qx "$lib $ver" "$tmp/defs" || { echo "check-abi: FAIL ${f#"$tmp"/} needs $ver from $lib"; fail=1; }
    done < "$tmp/needs"
    echo "check-abi: ${f#"$tmp"/}: $(wc -l < "$tmp/needs") version refs, highest: $(awk '{print $2}' "$tmp/needs" | sort -V | grep -E '^GLIBC_' | tail -n 1) $(awk '{print $2}' "$tmp/needs" | sort -V | grep -E '^GLIBCXX_' | tail -n 1) $(awk '{print $2}' "$tmp/needs" | sort -V | grep -E '^Qt_' | tail -n 1)"
done
if [ "$fail" != 0 ]; then echo "check-abi: FAILED against $image"; exit 1; fi
echo "check-abi: ok against $image"
