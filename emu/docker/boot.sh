#!/bin/sh
# PID 1 of the emulated Paper Pure, for its first second: lay out the
# tablet's mounts and the fake hardware, then hand over to the image's own
# systemd, which boots the stock units the way the tablet does.
#
#   /            read-only, like the tablet's root partition. The container
#                layer under it is the "real root fs": it survives
#                `ppemu stop`/`start` (a reboot) and is gone after
#                `ppemu rebuild`/`reset` (a reflash).
#   /etc         overlay with a tmpfs upper, mounted by the image's own
#                var-volatile-etc.service. Plain writes are gone at reboot.
#   /run, /tmp   tmpfs, fresh every boot.
#   /home, /data docker volumes (the eMMC partitions).
#   /sys/...     the fake hardware tree (docker/root/sys), bind-mounted at the
#                tablet's paths, so static binaries see it too, not just
#                programs that load the shim.
#
# Emulator-only units and masks go in /run/systemd/system, rebuilt every
# boot, so the root fs and /etc stay stock. The masks are hardware the
# container doesn't have, and reMarkable's phone-home daemons.
set -e
F=/opt/rmemu
# The shim (in every process via ld.so.preload) would send mount's /sys and
# /dev paths to its fake tree. Not for this script: nothing to redirect.
export RMEMU_FAKEROOT=/run/rmemu/none

mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run
mkdir -p /run/systemd/system /run/rmemu

# Docker bind-mounts its own hosts, hostname and resolv.conf over /etc and
# leaves empty placeholders in the container layer. The tablet has the stock
# files there; put them back once (later edits in the real root fs persist).
# Docker's DNS servers go to resolved, as DHCP would on the tablet's Wi-Fi.
dns=$(sed -n 's/^nameserver //p' /etc/resolv.conf | tr '\n' ' ')
mount -o remount,rw /
for f in hosts hostname resolv.conf; do umount "/etc/$f" 2>/dev/null || true; done
for f in hosts hostname; do [ -s "/etc/$f" ] || cat "$F/stock/$f" > "/etc/$f"; done
[ -L /etc/resolv.conf ] || { rm -f /etc/resolv.conf; ln -s resolv-conf.systemd /etc/resolv.conf; }
# soc0/serial_number is the tablet's machine-id (/etc/machine-id links to it).
mkdir -p $F/state
[ -s $F/state/serial_number ] || dd if=/dev/urandom bs=16 count=1 2>/dev/null | md5sum | cut -c1-32 > $F/state/serial_number
mount -o remount,ro /

# Fake hardware: a writable copy (rmemud flips battery and charger files),
# seen at the shim's path and at the tablet's paths. /sys is read-only here,
# so each top directory we add to gets a tmpfs with the container's own
# parts bound back (net devices, cpus). Docker's masks come along (--rbind).
mkdir -p /run/rmemu/hw /run/rmemu/sys
cp -a $F/root/sys /run/rmemu/hw/
cat $F/state/serial_number > /run/rmemu/hw/sys/devices/soc0/serial_number
mount --bind /run/rmemu/hw/sys $F/root/sys
H=$F/root/sys
mount --rbind /sys /run/rmemu/sys
mount -t tmpfs -o mode=0755 tmpfs /sys/class
mkdir /sys/class/net && mount --rbind /run/rmemu/sys/class/net /sys/class/net
for d in "$H"/class/*; do mkdir "/sys/class/${d##*/}" && mount --bind "$d" "/sys/class/${d##*/}"; done
mount -t tmpfs -o mode=0755 tmpfs /sys/devices
for d in virtual system; do mkdir /sys/devices/$d && mount --rbind /run/rmemu/sys/devices/$d /sys/devices/$d; done
mkdir -p /sys/devices/platform
for d in "$H"/devices/platform/* "$H"/devices/soc0; do
    t=/sys/devices/${d#"$H"/devices/}
    mkdir -p "$t" && mount --bind "$d" "$t"
done
mount -t tmpfs -o mode=0755 tmpfs /sys/firmware
mkdir /sys/firmware/devicetree && mount --bind "$H"/firmware/devicetree /sys/firmware/devicetree
mount --bind "$H"/power /sys/power
umount -l /run/rmemu/sys

# Units: the emulator's own (hardware hub, SSH on the container network),
# then masks for what can't or mustn't run here.
cp -a $F/units/. /run/systemd/system/
for u in systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
         systemd-udev-trigger.service systemd-udev-settle.service systemd-modules-load.service \
         systemd-sysctl.service systemd-hwdb-update.service systemd-firstboot.service \
         systemd-random-seed.service systemd-remount-fs.service systemd-journald-audit.socket \
         sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount \
         sys-fs-fuse-connections.mount dev-hugepages.mount \
         tee-supplicant.service keystore.service homecryptor.service swapcryptor.service \
         growfs-home.service growpart-home.service dm-persist-create.service dm-early-uevent.service \
         remarkable-fs-check.service remarkable-wakesrc-init.service usb-ether-once.service \
         dev-zram0.swap zram-swap.service chronyd.service bluetooth.service var-lib-bluetooth.mount \
         wpa_supplicant.service prepare_wifi.service \
         systemd-networkd.service systemd-networkd.socket systemd-network-generator.service \
         systemd-networkd-wait-online.service \
         hostname-from-devconfig.service dhcp-role-from-devconfig.service \
         getty@tty1.service serial-getty@ttyLP1.service console-getty.service \
         dropbear-usb0.socket dropbear-usb1.socket pcscd.socket run-postinsts.service \
         slumber-metrics.service remarkable-counter-metrics.service battery-status-metrics.timer \
         remarkable-enable-slumber.timer boot-reason-check.service boot-reason-check-shutdown.service \
         memfaultd.service memfault-attributes.service crashuploader.service mdm-agent.service; do
    ln -sf /dev/null "/run/systemd/system/$u"
done
# xochitl: the stock unit and the stock drop-in (OnFailure=emergency.target,
# RestartMode=direct, the start limit), minus the DRM device it waits for,
# which only udev would announce. The same file name here hides the stock one.
mkdir -p /run/systemd/system/xochitl.service.d
grep -v 'dev-dri-card0' /usr/lib/systemd/system/xochitl.service.d/xochitl-service-override.conf \
    > /run/systemd/system/xochitl.service.d/xochitl-service-override.conf
# Under qemu-user (x86 hosts) xochitl's main thread can be busy for over a
# minute building a page, past the stock 60 s watchdog, and the start limit
# then reboots the "tablet". 10 minutes there; natively it stays stock.
if tr '\0' ' ' < /proc/1/cmdline | grep -q qemu; then
    printf '[Service]\nWatchdogSec=10min\n' > /run/systemd/system/xochitl.service.d/zz-rmemu-qemu.conf
fi
# Unit credentials need a mount this container can't make ("Failed to set up
# credentials: Invalid argument"); none are passed on the tablet either.
for f in $(grep -lE '^(Import|Load)Credential=' /usr/lib/systemd/system/*.service); do
    d=/run/systemd/system/${f##*/}.d
    mkdir -p "$d" && printf '[Service]\nImportCredential=\nLoadCredential=\n' > "$d/rmemu-credentials.conf"
done
mkdir -p /run/systemd/resolved.conf.d /run/systemd/journald.conf.d
printf '[Resolve]\nDNS=%s\n' "$dns" > /run/systemd/resolved.conf.d/rmemu.conf
# The journal also goes to the console, which is `docker logs` (ppemu logs).
printf '[Journal]\nForwardToConsole=yes\nMaxLevelConsole=info\n' > /run/systemd/journald.conf.d/rmemu.conf

unset RMEMU_FAKEROOT
export container=docker
exec /lib/systemd/systemd --show-status=0 "$@"
