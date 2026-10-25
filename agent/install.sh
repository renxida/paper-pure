#!/bin/bash
# Install the paper-pure agent on the tablet. Run ON the tablet, as root,
# from a directory holding:
#   pp-agent          (out/pp-agent-arm64)
#   release.pub.pem   (Cedar's release public key)
#   agent.json        (optional; kept if one is already installed)
#   systemd/          (pp-agent-boot.service, pp-agent.service, pp-agent.timer)
#
#   bash install.sh             copy files into /home/root/paper-pure
#   bash install.sh --runtime   ...and start the units from /run (gone at
#                               reboot; a safe first try, no rootfs change)
#
# Making the units survive reboot means writing them under the real /etc
# (the /etc overlay's upper layer is tmpfs). That step belongs to the
# device setup; see agent/README.md "What the device lane wires up".
set -euo pipefail

ROOT=/home/root/paper-pure
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! grep -qi tatsu /proc/device-tree/model 2>/dev/null; then
    echo "warning: this does not look like a Paper Pure (tatsu)" >&2
fi

install -d -m 0755 "$ROOT" "$ROOT/bin" "$ROOT/keys" "$ROOT/systemd"
install -m 0755 "$HERE/pp-agent" "$ROOT/bin/pp-agent.new"
mv -f "$ROOT/bin/pp-agent.new" "$ROOT/bin/pp-agent"
install -m 0644 "$HERE/release.pub.pem" "$ROOT/keys/release.pub.pem"
if [ -f "$HERE/agent.json" ] && [ ! -f "$ROOT/agent.json" ]; then
    install -m 0600 "$HERE/agent.json" "$ROOT/agent.json"
fi
install -m 0644 "$HERE"/systemd/pp-agent* "$ROOT/systemd/"
"$ROOT/bin/pp-agent" version

if [ "${1:-}" = "--runtime" ]; then
    install -m 0644 "$ROOT"/systemd/pp-agent* /run/systemd/system/
    systemctl daemon-reload
    systemctl start pp-agent.timer
    echo "units started from /run/systemd/system (until reboot)"
    systemctl list-timers pp-agent.timer --no-pager || true
fi
