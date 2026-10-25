#!/bin/bash
# pp-agent hook: back to stock UI, no mods. Idempotent; works when activate
# never ran or only half ran, and when xochitl hit its start limit.
set -uo pipefail
if [ -x /home/root/xovi/stock ]; then /home/root/xovi/stock; fi
umount -q /etc/systemd/system/xochitl.service.d 2>/dev/null
systemctl daemon-reload
systemctl reset-failed xochitl.service 2>/dev/null
systemctl restart xochitl.service
echo "deactivate: ${PP_RELEASE_ID:-?} stock ($PP_REASON)"
