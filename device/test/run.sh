#!/bin/bash
# Prove device/install.sh against a stand-in tablet: the real 3.27.2.2 tatsu
# root fs running its own systemd 255 in an arm64 container (qemu-user on
# x86_64), laid out like the tablet in developer mode: / read-only ext4-like,
# /etc an overlay with a tmpfs upper (the image's own var-volatile-etc.service),
# /home and /data persistent volumes, the stock dropbear behind the stock
# dev-mode check, and a fake boot ROM error counter (lpgpr) that survives
# "reboots". A reboot is the container stopping and starting again.
#
#   device/test/run.sh ROOTFS_DIR      ROOTFS_DIR: the extracted 3.27.2.2 root fs
#                                      (never in the repo), used once for `docker import`
#   PP_SLOW=1 device/test/run.sh ...   also the boot-loop scenarios (about 15 min)
#   PP_KEEP=1                          leave the container running at the end
#
# Needs docker with arm64 emulation (binfmt), ssh, ssh-keygen, go (for pp-proxy).
# Commands for the test bed are single-quoted on purpose: they expand there.
# shellcheck disable=SC2016
set -euo pipefail
{ # parse the whole file before running, so editing it mid-run is safe
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTFS=${1:-}
TAG=3.27.2.2
C=pp-device-it
PORT=${PP_PORT:-3094}
WORK=${PP_WORK:-$(mktemp -d)}
mkdir -p "$WORK"
PASS=0 FAILN=0

ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAILN=$((FAILN + 1)); echo "  FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
t() { printf '\n== %s\n' "$*"; }

# ------------------------------------------------------------- images
if ! docker image inspect "pp-device-rootfs:$TAG" > /dev/null 2>&1; then
    [ -d "$ROOTFS/etc" ] || { echo "usage: $0 EXTRACTED_ROOTFS_DIR (needed once to build pp-device-rootfs:$TAG)" >&2; exit 2; }
    grep -q "IMG_VERSION=\"$TAG\"" "$ROOTFS/etc/os-release" || { echo "$ROOTFS is not $TAG" >&2; exit 2; }
    t "import $ROOTFS as pp-device-rootfs:$TAG (local only)"
    sudo tar --numeric-owner -C "$ROOTFS" -c . | docker import --platform linux/arm64 - "pp-device-rootfs:$TAG"
fi
docker build -q --platform linux/arm64 -t "pp-device-testbed:$TAG" "$HERE/testbed" > /dev/null

# ------------------------------------------------------------- keys, bins
[ -f "$WORK/id" ] || ssh-keygen -q -t ed25519 -N '' -C pp-device-test -f "$WORK/id"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
export PP_SSH_OPTS="${SSHO[*]}"
dev() { ssh "${SSHO[@]}" -i "$WORK/id" -p "$PORT" root@127.0.0.1 "$@"; }
inst() { "$REPO/device/install.sh" -p "$PORT" -i "$WORK/id" --key "$WORK/id.pub" "$@" root@127.0.0.1; }

# ------------------------------------------------------------- container
cleanup() {
    docker rm -f "$C" > /dev/null 2>&1 || true
    docker volume rm "$C-home" "$C-data" "$C-state" > /dev/null 2>&1 || true
}
# shellcheck disable=SC2317  # run by the EXIT trap
on_exit() {
    if [ "${PP_KEEP:-0}" = 1 ]; then echo "kept: container $C (ssh -p $PORT root@127.0.0.1, key $WORK/id)"; else cleanup; fi
}
trap on_exit EXIT
cleanup
running() { [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = true ]; }
# shellcheck disable=SC2317  # called through check()
alive() { # for checks that need the tablet up: say so if it went down on its own
    running && return 0
    echo "  (test bed stopped by itself: $(docker inspect -f 'exit {{.State.ExitCode}} at {{.State.FinishedAt}}' "$C"))"
    return 1
}
boot() { # start the container and wait for systemd to settle and SSH to answer
    docker start "$C" > /dev/null
    local start st
    start=$(date +%s)
    # Ready = xochitl is up. (On a stock test bed systemd stays "starting":
    # memfaultd can't run in a container and keeps restarting, and swupdate
    # waits for it. On the tablet memfaultd runs.)
    until st=$(docker exec "$C" systemctl is-system-running 2> /dev/null; true); [ "$(docker exec "$C" systemctl is-active xochitl.service 2> /dev/null)" = active ]; do
        [ $(($(date +%s) - start)) -lt 400 ] || { echo "  boot: xochitl not up after 400 s (systemd: $st)"; return 1; }
        running || { echo "  boot: container stopped"; return 1; }
        sleep 3
    done
    until dev true 2> /dev/null; do sleep 2; done
    echo "  booted in $(($(date +%s) - start)) s ($st)"
}
reboot() { # clean reboot, the way `systemctl reboot` on the tablet does it
    dev 'systemctl reboot' 2> /dev/null || true
    local start; start=$(date +%s)
    while running; do [ $(($(date +%s) - start)) -lt 120 ] || docker stop -t 5 "$C" > /dev/null; sleep 2; done
    boot
}
docker create --name "$C" --platform linux/arm64 --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
    --read-only -t -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$C-home:/home" -v "$C-data:/data" -v "$C-state:/pp-state" \
    -p "127.0.0.1:$PORT:22" --stop-signal SIGRTMIN+3 "pp-device-testbed:$TAG" > /dev/null
docker start "$C" > /dev/null
until docker exec "$C" test -d /home/root/.ssh 2> /dev/null; do sleep 1; done
docker exec -i "$C" sh -c 'cat > /home/root/.ssh/authorized_keys; chmod 600 /home/root/.ssh/authorized_keys' < "$WORK/id.pub"
docker stop -t 5 "$C" > /dev/null 2>&1 || true
boot

# ------------------------------------------------------------- scenarios
t "1. stock tablet: verify fails, and says why"
out=$(inst --verify 2>&1) && rc=0 || rc=$?
echo "$out" > "$WORK/1-verify-stock.log"
check "verify exits 1 on a stock tablet" [ "$rc" = 1 ]
check "it flags swupdate as not masked" grep -q 'FAIL    masked: swupdate.service' <<< "$out"
check "it flags the hosts block" grep -q "FAIL    /etc/hosts block 'paper-pure freeze'" <<< "$out"
check "stock memfaultd was started this boot" dev '[ "$(systemctl show -P InactiveExitTimestampMonotonic memfaultd.service)" != 0 ]'
check "verify changed nothing on the tablet" dev '! test -e /home/root/paper-pure/device/managed.list'

t "2. install"
inst > "$WORK/2-install.log" 2>&1 && rc=0 || rc=$?
check "install exits 0" [ "$rc" = 0 ]
check "the test bed stayed up" alive
check "install ends with all checks passed" grep -q 'pp-device: all checks passed' "$WORK/2-install.log"
check "fresh SSH connection works after install" grep -q 'PASS    fresh SSH connection' "$WORK/2-install.log"
check "/ is read-only again" dev 'awk '\''$2=="/"{o=$4} END{exit !(o ~ /^ro/)}'\'' /proc/mounts'
check "no bind mount left behind" dev '! grep -q /run/pp-device/root /proc/mounts'
check "the /etc/dropbear host-key mount is still there" dev 'grep -q " /etc/dropbear " /proc/mounts'
check "device.cloud.remarkable.com resolves to 0.0.0.0" dev 'wget -T 2 -O /dev/null http://device.cloud.remarkable.com:9/ 2>&1 | grep -q "(0.0.0.0:9)"'
check "stock hosts lines kept" dev 'grep -q "^127.0.0.1.*localhost" /etc/hosts'

t "3. install again: nothing to change"
inst > "$WORK/3-install-again.log" 2>&1 && rc=0 || rc=$?
check "second install exits 0" [ "$rc" = 0 ]
check "second install changes nothing" [ "$(grep -c '^CHANGE' "$WORK/3-install-again.log" || true)" = 0 ]

t "4. reboot: the freeze comes from the root fs, not the tmpfs overlay"
reboot
check "verify passes after reboot" inst --verify > "$WORK/4-verify-after-reboot.log" 2>&1
check "the /etc overlay's tmpfs upper holds none of our files" dev '! find /var/volatile/etc -name "*.service" -o -name hosts -o -name "*.socket" | grep -q .'
for u in swupdate.service update-engine.service memfaultd.service; do
    check "$u never started this boot" dev "[ \"\$(systemctl show -P InactiveExitTimestampMonotonic $u)\" = 0 ]"
done
check "dropbear-wlan.socket masked" dev '[ "$(systemctl is-enabled dropbear-wlan.socket)" = masked ]'
check "rm-sanity clears the boot ROM counter" dev '
    echo "  counter after boot: $(cat /sys/devices/platform/lpgpr/roota_errcnt)"
    for i in $(seq 1 60); do [ "$(systemctl show -P ExecMainExitTimestampMonotonic rm-sanity.service)" != 0 ] && break; sleep 3; done
    [ "$(cat /sys/devices/platform/lpgpr/roota_errcnt)" = 0 ]'

t "5. drift: someone unmasks a unit live, or edits the root fs; verify sees it, install repairs it"
dev 'rm /etc/systemd/system/swupdate.service'
out=$(inst --verify 2>&1) && rc=0 || rc=$?
check "verify catches a live-only unmask" grep -q 'FAIL    masked: swupdate.service' <<< "$out"
check "verify reports the drift" grep -q 'FAIL    drift: /etc/systemd/system/swupdate.service' <<< "$out"
# (in place, not sed -i: replacing the file would leave an inode the overlay
# still holds, and / could not go back to read-only until reboot)
dev 'mount -o remount,rw / && mkdir -p /run/x && mount --bind / /run/x && sed "/paper-pure freeze start/,/paper-pure freeze end/d" /run/x/etc/hosts > /run/h && cat /run/h > /run/x/etc/hosts && umount /run/x && mount -o remount,ro /'
out=$(inst --verify 2>&1) && rc=0 || rc=$?
check "verify catches a root-fs-only edit of /etc/hosts" grep -q "FAIL    /etc/hosts block 'paper-pure freeze'" <<< "$out"
inst > "$WORK/5-repair.log" 2>&1
check "install repairs both" inst --verify > /dev/null 2>&1
dev 'touch /data/internal/rm_enable_ssh_wifi_marker 2>/dev/null || { mkdir -p /data/internal; touch /data/internal/rm_enable_ssh_wifi_marker; }'
check "verify catches the SSH-over-Wi-Fi marker" bash -c "! $(printf '%q ' "$REPO/device/install.sh" -p "$PORT" -i "$WORK/id" --verify root@127.0.0.1) > /dev/null 2>&1"
inst > /dev/null 2>&1
check "install removes it" dev '! test -e /data/internal/rm_enable_ssh_wifi_marker'

t "6. pp-agent and pp-proxy: installed, persisted, and pp-agent-boot waits for rm-sanity"
KEYS="$WORK/agentkeys"
[ -f "$KEYS/release.pub.pem" ] || { mkdir -p "$KEYS"; "$REPO/agent/out/ppsign" keygen -out "$KEYS" > /dev/null; }
cat > "$WORK/agent.json" << 'EOF'
{"feed_url": "http://127.0.0.1:3098/releases/tatsu/", "status_url": "http://127.0.0.1:3098/pp/status/tatsu",
 "headers": {"CF-Access-Client-Id": "test.access", "CF-Access-Client-Secret": "test"},
 "battery_floor": 30, "stable_seconds": 45, "boot_guard_max": 3, "activate_on_boot": true}
EOF
[ -f "$WORK/pp-proxy-arm64" ] || (cd "$REPO/server" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$WORK/pp-proxy-arm64" ./tablet-proxy)
PP_PROXY_BIN="$WORK/pp-proxy-arm64" inst --agent --release-pub "$KEYS/release.pub.pem" --agent-json "$WORK/agent.json" --proxy > "$WORK/6-agent-proxy.log" 2>&1 && rc=0 || rc=$?
check "install with --agent --proxy exits 0" [ "$rc" = 0 ]
check "/ went back to read-only (no EBUSY)" bash -c "! grep -q 'stays read-write' '$WORK/6-agent-proxy.log'"
reboot
check "verify passes after reboot (agent and proxy included)" inst --verify > "$WORK/6-verify.log" 2>&1
check "pp-proxy.service runs from the persisted unit" dev 'systemctl is-active -q pp-proxy.service'
check "my.remarkable.com resolves to 127.0.0.1 (pp-proxy)" dev 'wget -T 2 -O /dev/null http://my.remarkable.com:9/ 2>&1 | grep -q "(127.0.0.1:9)"'
check "pp-proxy CA in the live bundle after reboot" dev 'grep -qF "$(sed -n 2p /home/root/paper-pure/proxy/ca.crt)" /etc/ssl/certs/ca-certificates.crt'
check "pp-agent.timer is active" dev 'systemctl is-active -q pp-agent.timer'
# pp-agent-boot (oneshot) may still be waiting; give it the minute rm-sanity needs.
dev 'for i in $(seq 1 60); do s=$(systemctl show -P ActiveState pp-agent-boot.service); [ "$s" = activating ] || break; sleep 3; done'
check "wait-sanity logged that rm-sanity was done first" dev 'journalctl -b -u pp-agent-boot.service --no-pager | grep -q "rm-sanity done, roota_errcnt=0"'
check "pp-agent boot ran only after rm-sanity exited" dev '
    s=$(systemctl show -P ExecMainExitTimestampMonotonic rm-sanity.service)
    b=$(systemctl show -P ExecMainStartTimestampMonotonic pp-agent-boot.service)
    echo "rm-sanity exited at $s us, pp-agent boot started at $b us"; [ "$s" -gt 0 ] && [ "$b" -gt "$s" ]'

t "7. uninstall puts the root fs back to stock"
"$REPO/device/install.sh" -p "$PORT" -i "$WORK/id" --uninstall root@127.0.0.1 > "$WORK/7-uninstall.log" 2>&1
reboot
out=$(inst --verify 2>&1) && rc=0 || rc=$?
check "verify fails again (stock)" [ "$rc" = 1 ]
check "swupdate.service is enabled again (stock)" dev '[ "$(systemctl is-enabled swupdate.service)" = enabled ]'
check "no freeze block in /etc/hosts" dev '! grep -q "paper-pure freeze" /etc/hosts'
check "stock /etc/hosts lines still there" dev 'grep -q "^127.0.0.1.*localhost" /etc/hosts'
check "pp-agent-boot no longer enabled" dev '! test -e /etc/systemd/system/multi-user.target.wants/pp-agent-boot.service'
inst > /dev/null 2>&1
check "and install brings it all back" inst --verify > /dev/null 2>&1

if [ "${PP_SLOW:-0}" = 1 ]; then
    t "8. a mod that crashes xochitl at every boot (slow): early vs after rm-sanity"
    # Two test-only stand-ins for a broken mod, persisted into the root fs and
    # switched on by flag files in the state volume:
    #   crash-early: a unit that breaks xochitl as soon as it is up (what a
    #                naive boot autostart would do)
    #   crash-mod:   an ExecStartPost on pp-agent-boot, i.e. after our wait
    # Breaking xochitl = the fake xochitl exits 1 after 2 s, every start, so
    # the stock unit hits its start limit, OnFailure=emergency.target runs
    # rm-emergency.sh, and that reboots.
    dev 'set -e; mount -o remount,rw /; mkdir -p /run/x; mount --bind / /run/x
        mkdir -p /run/x/etc/systemd/system/multi-user.target.wants /run/x/etc/systemd/system/pp-agent-boot.service.d
        printf "[Unit]\nAfter=xochitl.service\n[Service]\nType=oneshot\nExecStart=/bin/sh -c \"if [ -e /pp-state/crash-early ]; then touch /run/pp-testbed-crash; systemctl restart --no-block xochitl.service; fi\"\n" > /run/x/etc/systemd/system/pp-test-early-mod.service
        ln -sf ../pp-test-early-mod.service /run/x/etc/systemd/system/multi-user.target.wants/pp-test-early-mod.service
        printf "[Service]\nExecStartPost=/bin/sh -c \"if [ -e /pp-state/crash-mod ]; then touch /run/pp-testbed-crash; systemctl restart --no-block xochitl.service; fi\"\n" > /run/x/etc/systemd/system/pp-agent-boot.service.d/90-test-crash.conf
        umount /run/x; mount -o remount,ro /'
    docker stop -t 30 "$C" > /dev/null
    state() { docker run --rm -v "$C-state:/s" busybox:1.36.1 sh -c "$1"; }
    crash_cycles() { # max: start, let it crash-reboot by itself, repeat
        local start
        for _ in $(seq 1 "$1"); do
            docker start "$C" > /dev/null; start=$(date +%s)
            while running; do
                [ $(($(date +%s) - start)) -lt 420 ] || { echo "  no crash reboot within 420 s"; docker stop -t 5 "$C" > /dev/null; return 1; }
                sleep 3
            done
            echo "  crash reboot after $(($(date +%s) - start)) s; $(state 'tail -n 1 /s/boots.log')"
            state 'test -e /s/spl-switched' && return 0
        done
        return 0
    }
    state 'echo 0 > /s/lpgpr/roota_errcnt; rm -f /s/spl-switched /s/crash-mod; touch /s/crash-early; echo phase-early >> /s/boots.log'
    crash_cycles 6 || true
    check "early crash: the boot ROM counter climbs past the limit (slot switch)" state 'test -e /s/spl-switched'
    state 'echo 0 > /s/lpgpr/roota_errcnt; rm -f /s/spl-switched /s/crash-early; touch /s/crash-mod; echo phase-after-sanity >> /s/boots.log'
    crash_cycles 3 || true
    check "after-sanity crash: no slot switch" state '! test -e /s/spl-switched'
    check "after-sanity crash: every boot counted 1, never more" state 'sed -n "/phase-after-sanity/,\$p" /s/boots.log | grep "ecnt=" | grep -v "ecnt=1\$" | grep -q . && exit 1 || exit 0'
    state 'sed -n "/phase-early/,\$p" /s/boots.log' > "$WORK/8-boots.log"
    state 'rm -f /s/crash-mod; echo 0 > /s/lpgpr/roota_errcnt'
    boot
    check "after the loops, verify still passes" inst --verify > /dev/null 2>&1
fi

echo
echo "device tests: $PASS passed, $FAILN failed (logs in $WORK)"
[ "$FAILN" = 0 ]
exit
}
