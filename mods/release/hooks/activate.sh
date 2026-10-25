#!/bin/bash
# pp-agent hook: make this release's mods live (contract: agent/README.md).
# /home/root/xovi becomes a link to this release's xovi tree (upstream's
# scripts expect that path), the hashtab comes from the cache (or is built
# once), then xovi/start restarts xochitl with xovi.
# Tethered like upstream: the drop-in xovi/start writes lives on a tmpfs, so
# a reboot is stock until a triple-press (pp-agent toggle) turns mods on.
set -euo pipefail
rel=${PP_RELEASE_DIR:?}
cd /home/root
if [ -d xovi ] && [ ! -L xovi ]; then mv xovi "xovi.manual-$(date +%s)"; fi   # keep a hand install
ln -sfn "$rel/xovi" xovi.tmp && mv -T xovi.tmp xovi
xovi/paper-pure/hashtab --timeout 100
# The hashtab build stops and starts xochitl. Zero the start-limit counter
# (StartLimitBurst=4, then OnFailure=emergency.target reboots) so only
# crashes after our restart count, and pp-agent's check sees them first.
systemctl reset-failed xochitl.service
xovi/start
if [ -d /opt/rmemu ] && [ -x xovi/paper-pure/emu-start ]; then xovi/paper-pure/emu-start; fi   # old emulator: no systemd
echo "activate: $PP_RELEASE_ID live ($PP_REASON)"
