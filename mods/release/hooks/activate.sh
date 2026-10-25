#!/bin/bash
# pp-agent hook: make this release's mods live (contract: agent/README.md).
# /home/root/xovi becomes a link to this release's xovi tree (upstream's
# scripts and xovi-tripletap expect that path), the hashtab comes from the
# cache (or is built once), then xovi/start restarts xochitl with xovi.
# Tethered like upstream: the drop-in xovi/start writes lives on a tmpfs, so
# a reboot is stock until pp-agent boot (or a triple-press) activates again.
set -euo pipefail
rel=${PP_RELEASE_DIR:?}
cd /home/root
if [ -d xovi ] && [ ! -L xovi ]; then mv xovi "xovi.manual-$(date +%s)"; fi   # keep a hand install
ln -sfn "$rel/xovi" xovi.tmp && mv -T xovi.tmp xovi
xovi/paper-pure/hashtab --timeout 100
xovi/start
if [ -d /opt/rmemu ]; then xovi/paper-pure/emu-start; fi   # emulator: no systemd
echo "activate: $PP_RELEASE_ID live ($PP_REASON)"
