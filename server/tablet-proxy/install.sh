#!/bin/bash
# Install pp-proxy on the tablet, for this boot only. Run as root over SSH
# (USB or a private overlay, never public Wi-Fi) from a dir holding pp-proxy
# (the arm64 build) and pp-proxy.service. pp-agent's agent.json must already
# have feed_url and the Cloudflare Access headers: pp-proxy reads both.
#
#   bash install.sh --runtime   the /etc overlay (tmpfs) and /run; a reboot undoes it
#
# Persisting is device/tablet/pp-device.sh's job (device/install.sh --proxy
# runs this, then persists the unit, hosts block and CA bundle into the real
# root fs; --uninstall undoes that). There is no other mode: rmfakecloud-proxy's
# way (umount -R /etc, then write) drops the /etc/dropbear bind and breaks new
# SSH logins until a reboot.
set -euo pipefail
R=/home/root/paper-pure
MARK_START="# pp-proxy start"
MARK_END="# pp-proxy end"
[ "${1:-}" = --runtime ] || { echo "usage: install.sh --runtime   (to persist: device/install.sh --proxy)" >&2; exit 2; }

hosts_strip() { # rewrite in place (no rename), so it also works on a bind-mounted file
    sed "/^$MARK_START/,/^$MARK_END/d" "$1" > "$1.pp-tmp" && cat "$1.pp-tmp" > "$1" && rm -f "$1.pp-tmp"
}
put() { mkdir -p "$(dirname "$3")" && cp "$2" "$3.tmp" && chmod "$1" "$3.tmp" && mv "$3.tmp" "$3"; }   # mode src dst (no `install` on the tablet)

put 0755 pp-proxy "$R/bin/pp-proxy"
[ -f "$R/proxy/cert.pem" ] || "$R/bin/pp-proxy" gencert
"$R/bin/pp-proxy" check || echo "pp-proxy: WARNING: the server check failed; sync won't work until it passes"

# /usr/local is on the read-only root, so trust the CA in the overlay copy
# of the bundle directly. Gone at reboot, like everything else here.
grep -q "$(sed -n 2p "$R/proxy/ca.crt")" /etc/ssl/certs/ca-certificates.crt \
    || cat "$R/proxy/ca.crt" >> /etc/ssl/certs/ca-certificates.crt
hosts_strip /etc/hosts
"$R/bin/pp-proxy" hosts >> /etc/hosts
put 0644 pp-proxy.service /run/systemd/system/pp-proxy.service

systemctl daemon-reload
systemctl restart pp-proxy.service
# rmfakecloud's own setup marks local notes "not synced" before the first
# connection, so a sync can never treat them as deleted on the server.
systemctl stop xochitl.service
for f in /home/root/.local/share/remarkable/xochitl/*.metadata; do
    if [ -f "$f" ] && grep -q '"synced": true' "$f"; then sed -i 's/"synced": true/"synced": false/' "$f"; fi
done
systemctl reset-failed xochitl.service 2>/dev/null || true
systemctl start xochitl.service
echo "pp-proxy: installed (--runtime). Pair: Settings > General > Account, code from the web UI."
