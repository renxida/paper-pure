#!/bin/sh
# PID 1 of the test bed. Lays out the tablet's mounts, fakes the boot ROM's
# A/B error counter, then hands over to the image's own systemd.
#
#   /                 read-only (the tablet's root partition, dev mode: no verity)
#   /etc              overlay with a tmpfs upper (done by the image's own
#                     var-volatile-etc.service, not by us)
#   /home, /data      docker volumes (persistent, like the eMMC partitions)
#   lpgpr             /sys/devices/platform/lpgpr, backed by /pp-state so the
#                     error counter survives "reboots" (docker restart)
#
# "SPL" below does what the tablet's boot ROM log says it does
# ("ABINFO: A (ecnt = %u)", "A in error state, switch to B"): count a boot
# attempt, and switch slots past a limit. The real limit is unknown; 3 here.
set -e
STATE=/pp-state
SPL_MAX=${PP_SPL_MAX:-3}

mount -t tmpfs -o mode=0755 tmpfs /run
mkdir -p /run/systemd/system /run/pp-sys

# /sys is read-only in the container. Put a tmpfs over /sys/devices and
# bind the real virtual/ and system/ back, so we can add soc0 and lpgpr.
mount --bind /sys/devices /run/pp-sys
mount -t tmpfs -o mode=0755 tmpfs /sys/devices
for d in virtual system; do mkdir -p /sys/devices/$d; mount --bind /run/pp-sys/$d /sys/devices/$d; done
mkdir -p /sys/devices/soc0 /sys/devices/platform/lpgpr
echo "reMarkable Tatsu" > /sys/devices/soc0/machine
[ -s $STATE/serial ] || dd if=/dev/urandom bs=16 count=1 2>/dev/null | md5sum | cut -c1-32 > $STATE/serial
cp $STATE/serial /sys/devices/soc0/serial_number
mount -t tmpfs -o mode=0755 tmpfs /sys/firmware
mkdir -p /sys/firmware/devicetree/base
printf 'reMarkable Tatsu\0' > /sys/firmware/devicetree/base/model

[ -d $STATE/lpgpr ] || {
    mkdir -p $STATE/lpgpr
    echo a > $STATE/lpgpr/root_part
    for f in roota_errcnt rootb_errcnt swu_status swu_applied; do echo 0 > $STATE/lpgpr/$f; done
    echo unlocked > $STATE/lpgpr/secboot
    echo off > $STATE/lpgpr/facmode
}
part=$(cat $STATE/lpgpr/root_part)
n=$(( $(cat "$STATE/lpgpr/root${part}_errcnt") + 1 ))
echo $n > "$STATE/lpgpr/root${part}_errcnt"
echo "pp-testbed SPL: root $part (ecnt = $n)" > /dev/console 2>/dev/null || true
echo "$(date +%s) boot part=$part ecnt=$n" >> $STATE/boots.log
if [ "$n" -gt "$SPL_MAX" ]; then
    echo "$(date +%s) SPL: $part in error state, would switch slot" >> $STATE/boots.log
    touch $STATE/spl-switched
fi
mount --bind $STATE/lpgpr /sys/devices/platform/lpgpr

# Test-bed-only masks, in /run so the "real" /etc stays stock: hardware and
# host-touching units that cannot or must not run in a container.
for u in systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
         systemd-udev-trigger.service systemd-udev-settle.service systemd-modules-load.service \
         systemd-sysctl.service systemd-hwdb-update.service systemd-firstboot.service \
         systemd-random-seed.service systemd-remount-fs.service \
         tee-supplicant.service keystore.service homecryptor.service swapcryptor.service \
         growfs-home.service growpart-home.service dm-persist-create.service dm-early-uevent.service \
         remarkable-fs-check.service remarkable-wakesrc-init.service usb-ether-once.service \
         dev-zram0.swap zram-swap.service chronyd.service marker-manager.service \
         bluetooth.service var-lib-bluetooth.mount wpa_supplicant.service prepare_wifi.service \
         systemd-networkd.service systemd-networkd.socket systemd-network-generator.service \
         hostname-from-devconfig.service dhcp-role-from-devconfig.service \
         getty@tty1.service serial-getty@ttyLP1.service console-getty.service \
         dropbear-usb0.socket dropbear-usb1.socket pcscd.socket mdm-agent.service \
         slumber-metrics.service remarkable-counter-metrics.service battery-status-metrics.timer \
         remarkable-enable-slumber.timer run-postinsts.service systemd-journald-audit.socket \
         sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount \
         sys-fs-fuse-connections.mount dev-hugepages.mount boot-reason-check.service \
         boot-reason-check-shutdown.service; do
    ln -sf /dev/null /run/systemd/system/$u
done

# xochitl needs the e-ink panel. Keep the stock unit and the stock drop-in's
# settings (RestartMode=direct, OnFailure=emergency.target, start limit),
# minus the DRM device it waits for, and run a stand-in that pets the watchdog.
mkdir -p /run/systemd/system/xochitl.service.d
grep -v 'dev-dri-card0' /usr/lib/systemd/system/xochitl.service.d/xochitl-service-override.conf \
    > /run/systemd/system/xochitl.service.d/xochitl-service-override.conf
printf '[Unit]\nAfter=tee-supplicant.service\n[Service]\nExecStart=\nExecStart=/pp-testbed/fake-xochitl\n' \
    > /run/systemd/system/xochitl.service.d/zz-pptest.conf
# SSH on the container's eth0 instead of the tablet's usb0, with the stock
# per-connection service (same host key, same dev-mode gate).
cat > /run/systemd/system/dropbear-pptest.socket <<'UNIT'
[Socket]
ListenStream=22
Accept=yes
[Install]
WantedBy=sockets.target
UNIT
sed 's/^Description=.*/Description=SSH (test bed)/' /usr/lib/systemd/system/dropbear-usb0@.service > /run/systemd/system/dropbear-pptest@.service
mkdir -p /run/systemd/system/dropbear-pptest@.service.d /run/systemd/system/sockets.target.wants
cp /usr/lib/systemd/system/dropbear@.service.d/override.conf /run/systemd/system/dropbear-pptest@.service.d/
ln -sf ../dropbear-pptest.socket /run/systemd/system/sockets.target.wants/dropbear-pptest.socket

# Docker bind-mounts its own hosts, hostname and resolv.conf over /etc, and
# leaves empty placeholder files in the container layer underneath. The
# tablet has real ones there; put back stand-ins (ours, not the stock files).
mount -o remount,rw /
for f in hosts hostname resolv.conf; do umount "/etc/$f" 2>/dev/null || true; done
[ -s /etc/hosts ] || printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\timx93-tatsu\n' > /etc/hosts
[ -s /etc/hostname ] || echo imx93-tatsu > /etc/hostname
[ -L /etc/resolv.conf ] || { rm -f /etc/resolv.conf; ln -s /etc/resolv-conf.systemd /etc/resolv.conf; }

mount -o remount,ro /
export container=docker
exec /lib/systemd/systemd --log-target=console --show-status=0 "$@"
