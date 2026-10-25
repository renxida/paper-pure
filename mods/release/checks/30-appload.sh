#!/bin/bash
# pp-agent check: AppLoad's QML hooks went into xochitl's UI and found our
# apps, and qmldiff reported no errors, in this xochitl's own log. A patch
# that no longer applies still leaves appload.so mapped (20-xovi.sh); this
# catches it. Read-only.
set -euo pipefail
pid=$(systemctl show -P MainPID xochitl.service)
[ "${pid:-0}" -gt 0 ] || { echo "check: xochitl is not running" >&2; exit 1; }
log=$(journalctl -b "_PID=$pid" -o cat --no-pager 2>/dev/null || true)
fail=0
for want in "[qmldiff]: Loaded external AppLoad hooks in main UI" "[AppLoad]: Loaded app root"; do
    if grep -qF "$want" <<<"$log"; then echo "ok: $want"; else echo "check: xochitl $pid never logged '$want'" >&2; fail=1; fi
done
# qmldiff's own failure lines (qmldiff 25681c3, src/lib.rs, hashrules.rs, common_util.rs)
bad=$(grep -E '^\[qmldiff\]: (Error|Failed|Warning)|No hash .* present in hashtab|Not a valid hash' <<<"$log" | head -n 5 || true)
if [ -n "$bad" ]; then echo "check: qmldiff complained:" >&2; echo "$bad" >&2; fail=1; fi
exit "$fail"
