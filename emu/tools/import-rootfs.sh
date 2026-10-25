#!/bin/sh
# Turn a reMarkable .swu firmware package into a linux/arm64 Docker image
# (pp-emu-rootfs:<version>). No root or privileged containers needed: the
# ext4 image is read with debugfs inside a throwaway ubuntu:24.04 container (host
# arch; debugfs only reads bytes, so no emulation).
#
# Checks before importing:
#   1. sw-description.sig verifies against the swupdate public key shipped
#      inside the image itself, and that key matches the pinned fingerprint.
#   2. the rootfs image's sha256 matches the one sw-description lists.
#
# usage: import-rootfs.sh FILE.swu
set -eu
[ $# -eq 1 ] || { echo "usage: $0 FILE.swu" >&2; exit 2; }
swu=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
version=$(basename "$swu" | sed -E 's/.*image-([0-9.]+)-.*/\1/')
tag=${PPEMU_ROOTFS_REPO:-pp-emu-rootfs}:$version
# sha256 of /usr/share/swupdate/swupdate-payload-key-pub.pem in tatsu 3.27.x
# images. A different key means a different signer: stop and look.
KEY_SHA=${PPEMU_KEY_SHA:-7f77934c86f157a887e942ee64b1916ea957dba2bc970fb1696501d3bdc2ce78}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/fw"
(cd "$work/fw" && cpio -id --quiet < "$swu")
img=$(ls "$work"/fw/*.ext4.verity.gz)
gunzip -c "$img" > "$work/fw/rootfs.ext4"

# Pull the signing key out of the image (debugfs cat, no mount needed).
docker run --rm -v "$work/fw":/fw:ro ubuntu:24.04 sh -c \
    'debugfs -R "cat /usr/share/swupdate/swupdate-payload-key-pub.pem" /fw/rootfs.ext4 2>/dev/null' \
    > "$work/key.pem"
key_sha=$(openssl dgst -sha256 -r "$work/key.pem" | cut -d' ' -f1)
if [ "$key_sha" != "$KEY_SHA" ]; then
    echo "import-rootfs: swupdate key sha256 is $key_sha, expected $KEY_SHA" >&2
    echo "import-rootfs: (set PPEMU_KEY_SHA to accept a new key on purpose)" >&2
    exit 1
fi
openssl dgst -sha256 -verify "$work/key.pem" -signature "$work/fw/sw-description.sig" "$work/fw/sw-description" >/dev/null ||
    { echo "import-rootfs: sw-description.sig does not verify" >&2; exit 1; }
want=$(grep -A4 "filename = \"$(basename "$img")\"" "$work/fw/sw-description" | sed -nE 's/.*sha256 = "([0-9a-f]{64})".*/\1/p' | head -1)
have=$(openssl dgst -sha256 -r "$img" | cut -d' ' -f1)
if [ -z "$want" ] || [ "$want" != "$have" ]; then
    echo "import-rootfs: rootfs sha256 $have does not match sw-description ($want)" >&2
    exit 1
fi
echo "import-rootfs: signature ok, rootfs sha256 ok ($version)" >&2

docker run --rm -v "$work/fw":/fw:ro ubuntu:24.04 sh -c \
    'mkdir /out && debugfs -R "rdump / /out" /fw/rootfs.ext4 >/dev/null 2>&1; tar -C /out --numeric-owner -cf - .' |
    docker import --platform linux/arm64 - "$tag" >/dev/null
echo "$tag"
