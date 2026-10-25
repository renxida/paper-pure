#!/bin/bash
# Turn an extracted tatsu rootfs into a LOCAL docker image, so the
# integration test can run on the real device userland (bash, busybox,
# /etc/os-release). Never push this image: it is reMarkable's code.
#
#   test/import-rootfs.sh /path/to/rootfs-3.27.2.2 [pp-agent-tatsu-rootfs:3.27.2.2]
set -euo pipefail
ROOTFS="${1:?usage: import-rootfs.sh ROOTFS_DIR [TAG]}"
TAG="${2:-pp-agent-tatsu-rootfs:3.27.2.2}"
grep -q '^IMG_VERSION=' "$ROOTFS/etc/os-release" || { echo "$ROOTFS has no IMG_VERSION" >&2; exit 1; }
tar -C "$ROOTFS" --exclude=./proc/* --exclude=./sys/* --exclude=./dev/* -c . |
    docker import --platform linux/arm64 - "$TAG"
# shellcheck disable=SC2016 # expands inside the container
echo "$TAG: $(docker run --rm --platform linux/arm64 "$TAG" sh -c '. /etc/os-release; echo "IMG_VERSION=$IMG_VERSION $(uname -m)"')"
