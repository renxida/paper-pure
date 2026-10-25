#!/bin/bash
# pp-agent hook: back to stock UI, no mods. Idempotent; works when activate
# never ran or only half ran, and when xochitl hit its start limit.
set -uo pipefail
# Our restarts must not use up xochitl's StartLimitBurst=4 (past it the OS
# reboots through OnFailure=emergency.target). pp-agent resets it too.
systemctl reset-failed xochitl.service 2>/dev/null
if [ -x /home/root/xovi/stock ]; then /home/root/xovi/stock; fi   # upstream: drop the drop-in, restart
# Make sure, even if xovi/stock was missing or half failed: no drop-in, and
# a running xochitl without xovi preloaded.
umount -q /etc/systemd/system/xochitl.service.d 2>/dev/null
systemctl daemon-reload
pid=$(systemctl show -P MainPID xochitl.service 2>/dev/null)
case $pid in '' | 0 | *[!0-9]*) pid=$(pidof xochitl); pid=${pid%% *} ;; esac
if [ -z "$pid" ] || tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^LD_PRELOAD=.*xovi'; then
    systemctl reset-failed xochitl.service 2>/dev/null
    systemctl restart xochitl.service || { echo "deactivate: xochitl did not restart" >&2; exit 1; }
fi
echo "deactivate: ${PP_RELEASE_ID:-?} stock ($PP_REASON)"
