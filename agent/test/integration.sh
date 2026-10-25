#!/bin/bash
# Integration test: the real arm64 pp-agent binary inside an arm64
# container (qemu), a fake /home/root/paper-pure, fake sysfs, a fake
# systemctl, and a local feed served by `ppsign serve` on 127.0.0.1:3090
# inside the container.
#
#   test/integration.sh                         busybox userland
#   PP_IMAGE=pp-agent-tatsu-rootfs:3.27.2.2 \
#     test/integration.sh                       real tatsu userland, real
#                                               /etc/os-release (see
#                                               test/import-rootfs.sh)
#
# Scenarios: install.sh with no install(1), install->pass,
# install->fail->rollback, kill -9 mid health check -> rollback at boot,
# boot-loop guard, OS mismatch, bad signature, status report, triple-press
# toggle (pp-agent tripletap reading KEY_POWER events from a FIFO).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$(dirname "$HERE")"
OUT="$AGENT/out"
IMAGE="${PP_IMAGE:-busybox:1.36.1}"
NAME="pp-agent-it-$$"
W="${PP_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/pp-agent-it.XXXXXX")}"
PORT=3090
PPSIGN="$OUT/ppsign"
OS=3.27.2.2

if [ ! -x "$OUT/pp-agent-arm64" ] || [ ! -x "$OUT/ppsign-arm64" ] || [ ! -x "$PPSIGN" ]; then
    make -C "$AGENT" build
fi

PASS=0
step() { printf '\n== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); echo "  ok: $*"; }
die()  { echo "  FAIL: $*" >&2; echo "  workdir kept: $W" >&2; exit 1; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

P="$W/home/paper-pure"   # host view of /home/root/paper-pure
dx()     { docker exec "$NAME" "$@"; }
agent()  { docker exec "$NAME" /home/root/paper-pure/bin/pp-agent "$@"; }
current() { readlink "$P/current" || true; }
jget()   { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])); [v:=v[k] for k in sys.argv[2:]]; print(json.dumps(v) if not isinstance(v,str) else v)' "$@"; }
st()     { jget "$P/state/state.json" "$@"; }
hooks()  { cat "$W/fake/hooks.log" 2>/dev/null || true; : > "$W/fake/hooks.log"; }
eq()     { if [ "$2" = "$3" ]; then ok "$1 = $3"; else die "$1: got '$2', want '$3'"; fi; }
has()    { case "$2" in *"$3"*) ok "$1 has: $3" ;; *) die "$1: missing '$3' in: $2" ;; esac; }
run()    { set +e; OUTPUT="$(agent "$@" 2>&1)"; RC=$?; set -e; printf '%s\n' "$OUTPUT" | sed 's/^/    | /' | tail -n 12; }

# ---- setup ------------------------------------------------------------------
step "setup in $W (image $IMAGE)"
rm -rf "$W"; mkdir -p "$P" "$W/fake/net/wlan0" "$W/feed" "$W/keys" "$W/evil" "$W/trees" "$W/stage/systemd"
cp "$OUT/ppsign-arm64" "$W/fake/ppsign"
"$PPSIGN" keygen -out "$W/keys" >/dev/null
"$PPSIGN" keygen -out "$W/evil" >/dev/null
# What device/install.sh copies to the tablet; install.sh runs in the container.
cp "$OUT/pp-agent-arm64" "$W/stage/pp-agent"
cp "$W/keys/release.pub.pem" "$AGENT/install.sh" "$W/stage/"
cp "$AGENT"/systemd/* "$W/stage/systemd/"

echo up > "$W/fake/net/wlan0/operstate"
printf 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\nwlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n' > "$W/fake/route"
echo 77 > "$W/fake/battery"
echo 0 > "$W/fake/charger"
echo ok > "$W/fake/xochitl"
printf 'IMG_VERSION="%s"\n' "$OS" > "$W/fake/os-release"
: > "$W/fake/hooks.log"

# Fake `systemctl show xochitl.service ...`: "crash" makes every look see a
# new PID and one more restart, like Restart=on-failure in a crash loop.
cat > "$W/fake/systemctl" <<'EOF'
#!/bin/sh
if [ "$1" = reset-failed ]; then echo "$*" >> /fake/systemctl.log; exit 0; fi
n=$(cat /fake/restarts 2>/dev/null || echo 0)
if [ "$(cat /fake/xochitl)" = crash ]; then n=$((n + 1)); echo "$n" > /fake/restarts; fi
echo "ActiveState=active"
echo "MainPID=$((1000 + n))"
echo "NRestarts=$n"
EOF
chmod +x "$W/fake/systemctl"

# Use the image's own os-release if it is a real reMarkable rootfs.
if docker run --rm --platform linux/arm64 "$IMAGE" grep -q '^IMG_VERSION=' /etc/os-release 2>/dev/null; then
    OSREL=/etc/os-release
else
    OSREL=/fake/os-release
fi
echo "  os-release: $OSREL"

cat > "$P/agent.json" <<EOF
{
  "feed_url": "http://127.0.0.1:$PORT/",
  "status_url": "http://127.0.0.1:$PORT/status",
  "os_release": "$OSREL",
  "sys_class_net": "/fake/net",
  "proc_net_route": "/fake/route",
  "battery_capacity": "/fake/battery",
  "charger_online": "/fake/charger",
  "systemctl": "/fake/systemctl",
  "stable_seconds": 3,
  "poll_millis": 500,
  "hook_timeout_seconds": 60,
  "check_timeout_seconds": 600,
  "activate_on_boot": true,
  "run_dir": "/fake/run",
  "power_key_device": "/fake/pwrkey"
}
EOF

# Release trees. activate "crashes" xochitl when /fake/break-<id> exists.
mktree() {
    local t="$W/trees/$1"; rm -rf "$t"; mkdir -p "$t/hooks" "$t/checks"
    cat > "$t/hooks/activate.sh" <<'EOF'
#!/bin/sh
echo "$PP_RELEASE_ID activate $PP_REASON" >> /fake/hooks.log
if [ -f "/fake/break-$PP_RELEASE_ID" ]; then echo crash > /fake/xochitl; else echo ok > /fake/xochitl; fi
EOF
    cat > "$t/hooks/deactivate.sh" <<'EOF'
#!/bin/sh
echo "$PP_RELEASE_ID deactivate $PP_REASON" >> /fake/hooks.log
echo ok > /fake/xochitl
EOF
    # shellcheck disable=SC2016 # $PP_OS_VERSION expands in the check, not here
    printf '#!/bin/sh\ntest "$PP_OS_VERSION" = %s\n' "$OS" > "$t/checks/10-os.sh"
    chmod +x "$t"/hooks/*.sh "$t"/checks/*.sh
    echo "$t"
}
N=0
publish() { # id tree [key] [os]
    N=$((N + 1))
    "$PPSIGN" pack -key "${3:-$W/keys/release.key.pem}" -dir "$2" -id "$1" -os "${4:-$OS}" \
        -created "2026-10-25T10:$(printf %02d "$N"):00Z" -out "$W/feed" -latest | sed 's/^/    /'
}

docker run -d --name "$NAME" --platform linux/arm64 \
    -v "$W/home:/home/root" -v "$W/fake:/fake" -v "$W/feed:/feed" -v "$W/stage:/stage:ro" \
    "$IMAGE" sleep 100000 >/dev/null
docker exec -d "$NAME" /fake/ppsign serve -dir /feed -addr "127.0.0.1:$PORT"
for _ in $(seq 60); do dx wget -q -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break; sleep 0.5; done
eq "arch" "$(dx uname -m)" aarch64

step "0. install.sh on the target userland"
if dx sh -c 'command -v install' >/dev/null 2>&1; then echo "  (this image has install(1); the tatsu image does not)"; else ok "no install(1) here, like the tablet"; fi
set +e; OUTPUT="$(dx sh /stage/install.sh 2>&1)"; RC=$?; set -e
printf '%s\n' "$OUTPUT" | sed 's/^/    | /'
eq "install.sh exit" "$RC" 0
V="$(agent version)"
if [ -n "$V" ]; then ok "pp-agent version $V runs"; else die "pp-agent did not run"; fi
has "agent.json kept" "$(cat "$P/agent.json")" "127.0.0.1:$PORT"
eq "units installed" "$(find "$P/systemd" -type f -printf '%f\n' | sort | tr '\n' ' ')" "pp-agent-boot.service pp-agent-tripletap.service pp-agent.service pp-agent.timer "
eq "key installed" "$(cmp "$P/keys/release.pub.pem" "$W/keys/release.pub.pem" && echo same)" same

# ---- 1. install -> pass ----------------------------------------------------------
step "1. install good1 -> healthy"
publish good1 "$(mktree good1)"
run update
eq "exit" "$RC" 0
eq "current" "$(current)" releases/good1
eq "hooks" "$(hooks)" "good1 activate install"
eq "committed" "$(st current)" good1
eq "server saw release" "$(jget "$W/feed/last-status.json" release)" good1
eq "server saw os" "$(jget "$W/feed/last-status.json" os_version)" "$OS"

# ---- 2. install -> fail -> rollback --------------------------------------------
step "2. install bad2 (crash-loops xochitl) -> rolled back to good1"
touch "$W/fake/break-bad2"
publish bad2 "$(mktree bad2)"
run update
eq "exit" "$RC" 1
has "output" "$OUTPUT" "xochitl not stable"
has "output" "$OUTPUT" "rolled back to good1"
eq "current" "$(current)" releases/good1
eq "hooks" "$(hooks | tr '\n' ';')" "good1 deactivate install;bad2 activate install;bad2 deactivate rollback;good1 activate rollback;"
eq "failed" "$(st failed)" '["bad2"]'
run update
eq "bad2 not retried" "$(st last_result)" "latest bad2 failed before; staying on good1"
eq "server saw rollback" "$(jget "$W/feed/last-status.json" failed)" '["bad2"]'

# ---- 3. power cut mid health check -> rollback at boot ----------------------------
step "3. kill -9 during slow3's health check, then boot -> rolled back"
T="$(mktree slow3)"
printf '#!/bin/sh\necho $$ > /fake/slow.pid\nexec sleep 600\n' > "$T/checks/20-slow.sh"; chmod +x "$T/checks/20-slow.sh"
publish slow3 "$T"
rm -f "$W/fake/slow.pid"
docker exec -d "$NAME" /home/root/paper-pure/bin/pp-agent update
for _ in $(seq 240); do [ -s "$W/fake/slow.pid" ] && break; sleep 0.5; done
[ -s "$W/fake/slow.pid" ] || die "slow check never started"
# shellcheck disable=SC2016 # expands inside the container
dx sh -c 'kill -9 $(pidof pp-agent) $(cat /fake/slow.pid)'
sleep 1
eq "pending after kill" "$(st pending)" slow3
eq "current after kill" "$(current)" releases/slow3
hooks >/dev/null
run boot
eq "exit" "$RC" 0
eq "current" "$(current)" releases/good1
eq "hooks" "$(hooks | tr '\n' ';')" "slow3 deactivate rollback;good1 activate boot;"
eq "failed" "$(st failed)" '["bad2", "slow3"]'
eq "pending" "$(st pending)" ""

# ---- 4. boot-loop guard ---------------------------------------------------------
step "4. good1 crashes at every boot -> stock after 3, new release clears it"
touch "$W/fake/break-good1"
for i in 1 2 3; do
    run boot
    eq "boot $i exit" "$RC" 1
    eq "unhealthy boots" "$(st unhealthy_boots)" "$i"
done
hooks >/dev/null
run boot
has "boot 4" "$OUTPUT" "never got healthy"
eq "guard" "$(st guard_tripped)" true
eq "no activate once tripped" "$(hooks)" ""
rm -f "$W/fake/break-good1"
run boot
eq "still stock" "$(hooks)" ""
publish good4 "$(mktree good4)"
run update
eq "exit" "$RC" 0
eq "current" "$(current)" releases/good4
eq "guard cleared" "$(st guard_tripped)" false
eq "count cleared" "$(st unhealthy_boots)" 0
hooks >/dev/null
run boot
eq "boot activates good4" "$(hooks)" "good4 activate boot"

# ---- 5. OS mismatch -------------------------------------------------------------
step "5. release tested on 3.27.1.0 only -> refused"
publish old5 "$(mktree old5)" "$W/keys/release.key.pem" 3.27.1.0
run update
eq "exit" "$RC" 1
has "output" "$OUTPUT" "this tablet runs \"$OS\""
eq "current" "$(current)" releases/good4

# ---- 6. bad signature -----------------------------------------------------------
step "6. release signed by another key -> refused, never downloaded"
publish evil6 "$(mktree evil6)" "$W/evil/release.key.pem"
run update
eq "exit" "$RC" 1
has "output" "$OUTPUT" "bad signature"
eq "current" "$(current)" releases/good4
if [ ! -e "$P/releases/evil6" ]; then ok "evil6 not unpacked"; else die "evil6 unpacked"; fi

# ---- 7. status ------------------------------------------------------------------
step "7. status"
eq "status release" "$(agent status | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["release"])')" good4
eq "releases kept" "$(find "$P/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tr '\n' ' ')" "good1 good4 "

# ---- 8. triple-press ------------------------------------------------------------
step "8. pp-agent tripletap: three KEY_POWER presses toggle mods off, then on"
# A FIFO stands in for /dev/input/eventN; we write struct input_event records.
mkfifo "$W/fake/pwrkey"
docker exec -d "$NAME" sh -c '/home/root/paper-pure/bin/pp-agent tripletap > /fake/tripletap.log 2>&1'
for _ in $(seq 60); do grep -q 'tripletap: watching' "$W/fake/tripletap.log" 2>/dev/null && break; sleep 0.5; done
has "daemon" "$(cat "$W/fake/tripletap.log")" "watching /fake/pwrkey for 3 presses"
press() { # N presses, GAP seconds apart, as the kernel reports them (press, SYN, release, SYN)
    python3 -I -c '
import struct, sys, time
n, gap = int(sys.argv[1]), float(sys.argv[2])
with open(sys.argv[3], "wb", buffering=0) as f:
    for i in range(n):
        t = time.time(); s, us = int(t), int((t % 1) * 1e6)
        for typ, code, val in ((1, 116, 1), (0, 0, 0), (1, 116, 0), (0, 0, 0)):
            f.write(struct.pack("<qqHHi", s, us, typ, code, val))
        time.sleep(gap)
' "$1" "$2" "$W/fake/pwrkey"
}
waitlog() { for _ in $(seq 120); do grep -q "$1" "$W/fake/hooks.log" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
eq "live before" "$(cat "$W/fake/run/live")" good4
hooks >/dev/null
press 3 0.4
waitlog "good4 deactivate tripletap" || die "no deactivate after a triple-press"
sleep 2
eq "off: hooks" "$(hooks)" "good4 deactivate tripletap"
if [ ! -e "$W/fake/run/live" ]; then ok "live marker gone"; else die "live marker still there"; fi
press 2 0.4
sleep 3
eq "two presses do nothing" "$(hooks)" ""
press 3 0.4
waitlog "good4 activate tripletap" || die "no activate after a triple-press"
for _ in $(seq 60); do [ -e "$W/fake/run/live" ] && grep -q 'tripletap: mods on' "$P/state/agent.log" && break; sleep 0.5; done
eq "on: hooks" "$(hooks)" "good4 activate tripletap"
eq "live after" "$(cat "$W/fake/run/live")" good4
has "agent log" "$(cat "$P/state/agent.log")" "tripletap: mods on (good4)"
has "reset-failed before hooks" "$(cat "$W/fake/systemctl.log")" "reset-failed xochitl.service"

printf '\nPASS: %d checks (image %s)\n' "$PASS" "$IMAGE"
[ -n "${PP_WORK:-}" ] || rm -rf "$W"
