#!/bin/sh
# ExecStartPre of pp-agent-boot.service (via the pp-device drop-in).
#
# The boot ROM counts boot attempts per root slot and switches to the other
# slot when the count gets too high ("ABINFO: A in error state, switch to B"
# in the SPL). rm-sanity.service clears the count 60 s after boot. If mods
# came on before that and crashed xochitl into a reboot loop, the count would
# climb and the tablet would fall back to the other slot: a different OS
# with none of our freeze on it. So mods wait until the count is cleared.
#
# Exit 0: rm-sanity has run this boot and the count is 0, go ahead.
# Exit 1: it hasn't after 5 minutes; mods stay off this boot (stock UI).
L=/sys/devices/platform/lpgpr
[ -r "$L/root_part" ] || exit 0   # not a real tablet (emulator): nothing to wait for
part=$(cat "$L/root_part")
waited=0
while [ "$waited" -lt 300 ]; do
    ran=$(systemctl show -P ExecMainExitTimestampMonotonic rm-sanity.service 2>/dev/null)
    cnt=$(cat "$L/root${part}_errcnt" 2>/dev/null)
    if [ -n "$ran" ] && [ "$ran" != 0 ] && [ "$cnt" = 0 ]; then
        echo "pp-device: rm-sanity done, root${part}_errcnt=0 after ${waited}s"
        exit 0
    fi
    sleep 2
    waited=$((waited + 2))
done
echo "pp-device: root${part}_errcnt=${cnt:-?} and rm-sanity not done after ${waited}s; mods stay off this boot" >&2
exit 1
