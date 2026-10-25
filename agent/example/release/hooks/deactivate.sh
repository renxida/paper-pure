#!/bin/sh
# Example deactivate hook. The mods lane owns the real one.
#
# Contract: return the tablet to stock UI (no mods loaded). Called before
# switching away from this release, on rollback, and after a failed boot.
# Must be idempotent and must work even if activate never ran or half ran.
# Stock xochitl may have hit its start limit (StartLimitBurst=4 in 600s;
# past it OnFailure=emergency.target reboots the tablet). pp-agent runs
# `systemctl reset-failed xochitl.service` before every hook; a hook that
# restarts xochitl more than once should reset it again before the last one.
set -eu
echo "deactivate $PP_RELEASE_ID ($PP_REASON)"
