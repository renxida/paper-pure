#!/bin/bash
# Install the mod stack (xovi + qt-resource-rebuilder + AppLoad + our apps)
# onto a Paper Pure over SSH, the same way for the emulator and the tablet.
#   mods/install.sh TARGET [--tarball FILE] [--no-start]
# TARGET: "emu" (the emulator in emu/) or an ssh destination such as
# root@10.11.99.1 (USB) for a tablet in developer mode.
# Steps on the device:
#   1. back to stock if xovi is running (xovi/stock)
#   2. unpack the tarball to /home/root/xovi.new, carry the hashtab over,
#      swap it in; the old tree stays as /home/root/xovi.prev
#   3. build the hashtab if this xochitl/qt-resource-rebuilder pair has none
#   4. xovi/start (tethered: a reboot returns stock), then check that
#      xochitl really mapped xovi.so
set -euo pipefail
mods=$(cd "$(dirname "$0")" && pwd)
target=${1:?usage: install.sh TARGET [--tarball FILE] [--no-start]}; shift
tarball=$mods/out/xovi-tatsu.tar.gz start=1
while [ $# -gt 0 ]; do
    case $1 in
    --tarball) tarball=$2; shift ;;
    --no-start) start=0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
[ -f "$tarball" ] || { echo "install.sh: $tarball missing, run mods/build.sh" >&2; exit 1; }

if [ "$target" = emu ]; then
    key=$(dirname "$mods")/emu/.ppemu/id_ed25519
    ssh_cmd=(ssh -i "$key" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
else
    ssh_cmd=(ssh -o ConnectTimeout=10 "$target")
fi

echo "install.sh: copying $(basename "$tarball") ($(wc -c < "$tarball") bytes) to $target"
"${ssh_cmd[@]}" 'cat > /tmp/pp-xovi.tar.gz' < "$tarball"

"${ssh_cmd[@]}" START="$start" SHA="$(sha256sum "$tarball" | cut -d' ' -f1)" bash -s <<'DEVICE'
set -euo pipefail
cd /home/root
echo "device: $(cat /sys/devices/soc0/machine 2>/dev/null), OS $(sed -n 's/^IMG_VERSION=//p' /etc/os-release | tr -d '"')"
[ "$(sha256sum /tmp/pp-xovi.tar.gz | cut -d' ' -f1)" = "$SHA" ] || { echo "device: tarball sha256 mismatch" >&2; exit 1; }

pid=$(pidof xochitl || true)
if [ -n "$pid" ] && grep -q /home/root/xovi/xovi.so "/proc/${pid%% *}/maps" && [ -x xovi/stock ]; then
    echo "device: xovi is running, going back to stock first"
    xovi/stock
fi

rm -rf xovi.new && mkdir xovi.new
tar -xzf /tmp/pp-xovi.tar.gz -C xovi.new --strip-components=1
rm -f /tmp/pp-xovi.tar.gz
old=xovi/exthome/qt-resource-rebuilder
if [ -s "$old/hashtab" ]; then cp -p "$old/hashtab" "$old/hashtab.key" xovi.new/exthome/qt-resource-rebuilder/ 2>/dev/null || true; fi
rm -rf xovi.prev
[ -d xovi ] && mv xovi xovi.prev
mv xovi.new xovi
echo "device: installed $(sed -n 2p xovi/BUILDINFO) to /home/root/xovi"

xovi/paper-pure/hashtab

if [ "$START" = 1 ]; then
    xovi/start
    if [ -d /opt/rmemu ]; then xovi/paper-pure/emu-start; fi
    for _ in $(seq 1 120); do
        pid=$(pidof xochitl || true)
        if [ -n "$pid" ] && grep -q /home/root/xovi/xovi.so "/proc/${pid%% *}/maps" 2>/dev/null; then break; fi
        sleep 1
    done
    xovi/paper-pure/status
    grep -q "xovi ON" < <(xovi/paper-pure/status) || { echo "device: xovi did not come up" >&2; exit 1; }
fi
DEVICE
echo "install.sh: done. Stock again: reboot, or ssh $target /home/root/xovi/stock"
