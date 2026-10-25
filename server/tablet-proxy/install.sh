#!/bin/bash
# Install pp-proxy on the tablet. Run as root over SSH (USB or a private
# overlay, never public Wi-Fi) from a dir holding pp-proxy (the arm64 build)
# and pp-proxy.service. pp-agent's agent.json must already have feed_url and
# the Cloudflare Access headers: pp-proxy reads both from there.
#
#   bash install.sh --runtime   this boot only: /etc overlay (tmpfs) and /run.
#                               A safe first try; a reboot undoes it.
#   bash install.sh             persist into the real rootfs under the /etc
#                               overlay (what rmfakecloud-proxy's installer
#                               does on Ferrari/Chiappa/Tatsu). Survives
#                               reboots, not an OS update or an A/B switch.
#   bash install.sh --uninstall undo the persistent install
#
# Not verified on a real tablet (see README.md, Status).
set -euo pipefail
R=/home/root/paper-pure
MODE="${1:-persist}"
CERTNAME=pp-proxy.crt
MARK_START="# pp-proxy start"
MARK_END="# pp-proxy end"

hosts_strip() { # rewrite in place (no rename), so it also works on a bind-mounted file
    sed "/^$MARK_START/,/^$MARK_END/d" "$1" > "$1.pp-tmp" && cat "$1.pp-tmp" > "$1" && rm -f "$1.pp-tmp"
}
put() { mkdir -p "$(dirname "$3")" && cp "$2" "$3.tmp" && chmod "$1" "$3.tmp" && mv "$3.tmp" "$3"; }   # mode src dst (no `install` on the tablet)

if [ "$MODE" = --uninstall ]; then
    systemctl disable --now pp-proxy.service 2>/dev/null || true
    mount -o remount,rw /
    umount -R /etc 2>/dev/null || true
    rm -f /etc/systemd/system/pp-proxy.service /etc/systemd/system/multi-user.target.wants/pp-proxy.service
    rm -f "/usr/local/share/ca-certificates/$CERTNAME"
    update-ca-certificates --fresh >/dev/null
    hosts_strip /etc/hosts
    sync
    mount -o remount,ro / || true
    echo "pp-proxy: uninstalled. Reboot to bring the /etc overlay back."
    exit 0
fi

put 0755 pp-proxy "$R/bin/pp-proxy"
[ -f "$R/proxy/cert.pem" ] || "$R/bin/pp-proxy" gencert
"$R/bin/pp-proxy" check || echo "pp-proxy: WARNING: the server check failed; sync won't work until it passes"

case "$MODE" in
--runtime)
    # /usr/local is on the read-only root, so trust the CA in the overlay copy
    # of the bundle directly. Gone at reboot, like everything else here.
    grep -q "$(sed -n 2p "$R/proxy/ca.crt")" /etc/ssl/certs/ca-certificates.crt \
        || cat "$R/proxy/ca.crt" >> /etc/ssl/certs/ca-certificates.crt
    hosts_strip /etc/hosts
    "$R/bin/pp-proxy" hosts >> /etc/hosts
    put 0644 pp-proxy.service /run/systemd/system/pp-proxy.service
    ;;
persist)
    # /etc is an overlay with a tmpfs upper (var-volatile-etc.service), so
    # writes must go to the real /etc underneath, with / remounted rw.
    mount -o remount,rw /
    if grep -q ' /etc ' /proc/mounts; then umount -R /etc; fi
    if grep -q ' /etc ' /proc/mounts; then echo "pp-proxy: /etc is still an overlay; refusing to write into tmpfs" >&2; exit 1; fi
    put 0644 "$R/proxy/ca.crt" "/usr/local/share/ca-certificates/$CERTNAME"
    update-ca-certificates
    hosts_strip /etc/hosts
    "$R/bin/pp-proxy" hosts >> /etc/hosts
    put 0644 pp-proxy.service /etc/systemd/system/pp-proxy.service
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf ../pp-proxy.service /etc/systemd/system/multi-user.target.wants/pp-proxy.service
    sync
    ;;
*)
    echo "usage: install.sh [--runtime|--uninstall]" >&2
    exit 2
    ;;
esac

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
echo "pp-proxy: installed ($MODE). Pair: Settings > General > Account, code from the web UI."
if [ "$MODE" = persist ]; then
    echo "pp-proxy: / is still rw and /etc's overlay is off until reboot. Reboot now."
fi
