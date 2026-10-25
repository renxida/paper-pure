#!/bin/sh
# PID 1 of the emulated Paper Pro: brings up the bits of the userland xochitl
# needs and supervises services the way systemd's Restart= would.
export LANG=C.UTF-8

# Restart a command whenever it exits (until the container stops).
supervise() {
    name=$1; shift
    while [ ! -e /run/rmemu-stopping ]; do
        if [ -e "/run/rmemu-$name-stopped" ]; then sleep 1; continue; fi
        "$@"
        status=$?
        [ -e /run/rmemu-stopping ] && break
        echo "[rmemu] $name exited with status $status, restarting"
        sleep 1
    done
}

rm -f /run/rmemu-stopping /run/rmemu-*-stopped
mkdir -p /run/dbus /etc/dropbear
rm -f /run/dbus/pid

# Hardware hub: input devices, display relay, host connection.
supervise rmemud /opt/rmemu/rmemud &
while [ ! -S /run/rmemu/input.sock ]; do sleep 0.05; done

dbus-daemon --system --fork

# SSH like a device in developer mode (blank root password inside the
# container; the port is only published on the host's loopback).
dropbear -R -B -E -p 22 2>/dev/null

supervise marker-manager /usr/bin/marker-manager 60 80 300 0 1800 0 3 &

trap 'touch /run/rmemu-stopping; killall xochitl marker-manager rmemud 2>/dev/null' TERM INT
supervise xochitl /usr/bin/xochitl --system "$@" &
wait $!
