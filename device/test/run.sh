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
#   PP_NAME=..., PP_PORT=...           container name (default pp-device-it), SSH port (3094)
#
# Scenario 9 runs the real pp-agent with the mods lane's real hooks and
# upstream's xovi/start and xovi/stock: triple-press toggle (KEY_POWER events
# written into a FIFO the agent reads as its power key), reboot = stock, and
# crash loops at install and at boot. Scenario 7 reinstalls over a
# crash-looping memfaultd; scenario 10 boots with /home locked behind a
# passcode, which only xochitl can ask for.
#
# Needs docker with arm64 emulation (binfmt), ssh, ssh-keygen, go (for
# pp-proxy and the agent), git, python3.
# Commands for the test bed are single-quoted on purpose: they expand there.
# shellcheck disable=SC2016
set -euo pipefail
{ # parse the whole file before running, so editing it mid-run is safe
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTFS=${1:-}
TAG=3.27.2.2
C=${PP_NAME:-pp-device-it}
PORT=${PP_PORT:-3094}
WORK=${PP_WORK:-$(mktemp -d)}
mkdir -p "$WORK"
PASS=0 FAILN=0 FAILED=()

ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAILN=$((FAILN + 1)); FAILED+=("$*"); echo "  FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
t() { printf '\n== %s\n' "$*"; }
# shellcheck disable=SC2317  # called through check()
logto() { # check "..." logto FILE CMD: CMD's output to FILE, the verdict on screen (and FILE's FAIL lines if it failed)
    local f=$1; shift; "$@" > "$f" 2>&1 && return 0
    grep '^FAIL' "$f" | head -n 10 | sed 's/^/       | /'; return 1
}

# ------------------------------------------------------------- images
if ! docker image inspect "pp-device-rootfs:$TAG" > /dev/null 2>&1; then
    [ -d "$ROOTFS/etc" ] || { echo "usage: $0 EXTRACTED_ROOTFS_DIR (needed once to build pp-device-rootfs:$TAG)" >&2; exit 2; }
    grep -q "IMG_VERSION=\"$TAG\"" "$ROOTFS/etc/os-release" || { echo "$ROOTFS is not $TAG" >&2; exit 2; }
    t "import $ROOTFS as pp-device-rootfs:$TAG (local only)"
    sudo tar --numeric-owner -C "$ROOTFS" -c . | docker import --platform linux/arm64 - "pp-device-rootfs:$TAG"
fi
docker build -q --platform linux/arm64 -t "pp-device-testbed:$TAG" "$HERE/testbed" > /dev/null
make -s -C "$REPO/agent" build > /dev/null   # the agent under test, fresh

# ------------------------------------------------------------- keys, bins
[ -f "$WORK/id" ] || ssh-keygen -q -t ed25519 -N '' -C pp-device-test -f "$WORK/id"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
export PP_SSH_OPTS="${SSHO[*]}"
dev() { # ssh to the test bed; under qemu load sshd can miss the banner timeout, so retry that (exit 255)
    local i rc
    for i in 1 2 3; do
        ssh "${SSHO[@]}" -i "$WORK/id" -p "$PORT" root@127.0.0.1 "$@" && return 0
        rc=$?
        [ "$rc" = 255 ] && [ "$i" != 3 ] && running || return "$rc"
        sleep 2
    done
}
inst() { "$REPO/device/install.sh" -p "$PORT" -i "$WORK/id" --key "$WORK/id.pub" "$@" root@127.0.0.1; }
ota_state() { # the stock OTA stack's view: lpgpr's update flag, swupdate's server, its journal
    dev "n=${1:-25}; "'echo "swu_status=$(cat /sys/devices/platform/lpgpr/swu_status 2>&1) at $(date -u +%T)"
        sed -n "s/^ *url *= */swupdate server: /p" /tmp/swupdate.cfg 2>/dev/null
        journalctl -b --no-pager -o short-monotonic -u swupdate.service -u update-engine.service -u swupdate-progress.service 2>/dev/null |
            grep -viE "token" | tail -n "$n"' 2>&1 | sed 's/^/   ota| /' || true
}
install_diag() { # LOG: why an install failed: its own verdict, then the test bed's side
    echo "  -- $(basename "$1"): FAIL/ERROR/WARN lines, then its last lines"
    grep -E '^(FAIL|ERROR|WARN)' "$1" | head -n 15 | sed 's/^/   log| /' || true
    tail -n 12 "$1" | sed 's/^/   end| /' || true
    echo "  -- test bed: OTA state, failed units, journal tail"
    ota_state 25
    dev 'systemctl --failed --no-legend --plain 2>&1 | head -n 10; journalctl -b --no-pager -o short-monotonic 2>/dev/null | tail -n 15' 2>&1 | sed 's/^/   tb | /' || true
}

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
diag() { # why the test bed is not up: its state, then its console (boot.sh and systemd log there)
    echo "  test bed: $(docker inspect -f '{{.State.Status}}, exit {{.State.ExitCode}} {{.State.Error}}' "$C" 2>&1)"
    docker logs --tail 80 "$C" 2>&1 | tr -d '\r' | sed 's/^/    console| /'
}
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
    # Ready = xochitl is up. (On a stock test bed systemd never reaches
    # "running": memfaultd can't run in a container, and swupdate waits for
    # it. On the tablet memfaultd runs.)
    # Also past "initializing" (basic.target): before it the /etc overlay
    # and the /etc/dropbear bind may not be up, and an install then breaks SSH.
    until st=$(docker exec "$C" systemctl is-system-running 2> /dev/null; true); [ "$st" != initializing ] && [ "$(docker exec "$C" systemctl is-active xochitl.service 2> /dev/null)" = active ]; do
        [ $(($(date +%s) - start)) -lt 400 ] || { echo "  boot: xochitl not up after 400 s (systemd: $st)"; diag; return 1; }
        running || { echo "  boot: container stopped"; diag; return 1; }
        sleep 3
    done
    until dev true 2> /dev/null; do
        [ $(($(date +%s) - start)) -lt 520 ] || { echo "  boot: no SSH after $(($(date +%s) - start)) s"; diag; return 1; }
        sleep 2
    done
    echo "  booted in $(($(date +%s) - start)) s ($st)"
}
reboot() { # clean reboot, the way `systemctl reboot` on the tablet does it
    dev 'systemctl reboot' 2> /dev/null || true
    local start; start=$(date +%s)
    while running; do [ $(($(date +%s) - start)) -lt 120 ] || docker stop -t 5 "$C" > /dev/null; sleep 2; done
    boot
}
# systemd as PID 1 in docker, on any host: boot.sh mounts (AppArmor's
# docker-default profile denies mount even with SYS_ADMIN, hence unconfined),
# and systemd runs its own subtree of the host's cgroup tree (host cgroup
# namespace: on cgroup v2 docker's default private one would show it the
# host's root through the rw bind mount, which it can't use).
echo "  docker $(docker version -f '{{.Server.Version}}' 2>&1), $(docker info -f 'cgroup v{{.CgroupVersion}} ({{.CgroupDriver}}), {{join .SecurityOptions " "}}' 2>&1)"
docker create --name "$C" --platform linux/arm64 --cap-add SYS_ADMIN \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined --cgroupns=host \
    --read-only -t -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$C-home:/home" -v "$C-data:/data" -v "$C-state:/pp-state" \
    -p "127.0.0.1:$PORT:22" --stop-signal SIGRTMIN+3 "pp-device-testbed:$TAG" > /dev/null
docker start "$C" > /dev/null
w=0
until docker exec "$C" test -d /home/root/.ssh 2> /dev/null; do
    if ! running || [ $((w += 1)) -ge 300 ]; then echo "  first boot: test bed not up after $w s"; diag; exit 1; fi
    sleep 1
done
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
grep -E 'swu_status|update staged' <<< "$out" | sed 's/^/  stock verify: /' || true
check "stock test bed: preflight passes (no OS update staged)" grep -q 'PASS    no OS update staged' <<< "$out"
ota_state 8

t "2. install"
inst > "$WORK/2-install.log" 2>&1 && rc=0 || rc=$?
check "install exits 0" [ "$rc" = 0 ]
check "the test bed stayed up" alive
check "install ends with all checks passed" grep -q 'pp-device: all checks passed' "$WORK/2-install.log"
check "fresh SSH connection works after install" grep -q 'PASS    fresh SSH connection' "$WORK/2-install.log"
check "/ is read-only again" dev 'awk '\''$2=="/"{o=$4} END{exit !(o ~ /^ro/)}'\'' /proc/mounts'
check "no bind mount left behind" dev '! grep -q /run/pp-device/root /proc/mounts'
check "the /etc/dropbear host-key mount is still there" dev 'grep -q " /etc/dropbear " /proc/mounts'
# nsswitch tries systemd-resolved first. Where it runs (the tablet; the test
# bed on a native arm64 host) it answers our 0.0.0.0 line with no address;
# where it can't start (the test bed under qemu) glibc reads /etc/hosts and
# gets 0.0.0.0. Either way the name comes from our block: with no hosts line
# resolved would ask DNS, which fails differently.
check "device.cloud.remarkable.com resolves to 0.0.0.0 or to no address" dev '
    n=device.cloud.remarkable.com
    if wget -T 2 -O /dev/null "http://$n:9/" 2>&1 | grep -q -e "(0.0.0.0:9)" -e "remote host (0.0.0.0)"; then
        echo "  $n: 0.0.0.0 (/etc/hosts)"; exit 0; fi
    for t in A AAAA; do
        out=$(resolvectl query -t $t $n 2>&1); echo "  resolvectl $t: $out"
        case $out in *"does not have any RR of the requested type"*) ;; *) exit 1 ;; esac
    done'
check "stock hosts lines kept" dev 'grep -q "^127.0.0.1.*localhost" /etc/hosts'
if ! grep -q 'pp-device: all checks passed' "$WORK/2-install.log"; then
    install_diag "$WORK/2-install.log"
    # Everything below builds on a frozen test bed.
    echo; echo "device tests: stopped after the first install ($PASS passed, $FAILN failed; logs in $WORK)"
    for f in "${FAILED[@]}"; do echo "  FAILED: $f"; done
    exit 1
fi

t "3. install again: nothing to change"
inst > "$WORK/3-install-again.log" 2>&1 && rc=0 || rc=$?
check "second install exits 0" [ "$rc" = 0 ]
[ "$rc" = 0 ] || install_diag "$WORK/3-install-again.log"
check "second install changes nothing" [ "$(grep -c '^CHANGE' "$WORK/3-install-again.log" || true)" = 0 ]

t "4. reboot: the freeze comes from the root fs, not the tmpfs overlay"
reboot
check "verify passes after reboot" logto "$WORK/4-verify-after-reboot.log" inst --verify
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
inst > "$WORK/5-repair.log" 2>&1 || install_diag "$WORK/5-repair.log"
check "install repairs both" logto "$WORK/5-verify-repaired.log" inst --verify
dev 'touch /data/internal/rm_enable_ssh_wifi_marker 2>/dev/null || { mkdir -p /data/internal; touch /data/internal/rm_enable_ssh_wifi_marker; }'
check "verify catches the SSH-over-Wi-Fi marker" bash -c "! $(printf '%q ' "$REPO/device/install.sh" -p "$PORT" -i "$WORK/id" --verify root@127.0.0.1) > /dev/null 2>&1"
inst > "$WORK/5-repair-marker.log" 2>&1
check "install removes it" dev '! test -e /data/internal/rm_enable_ssh_wifi_marker'
check "restore refuses a stock path pp-device never changed, and leaves it alone" dev '
    s=$(md5sum < /etc/issue)
    if bash /home/root/paper-pure/device/pp-device.sh restore /etc/issue; then exit 1; fi
    [ "$(md5sum < /etc/issue)" = "$s" ]'

t "6. pp-agent and pp-proxy: installed, persisted, and pp-agent-boot waits for rm-sanity"
KEYS="$WORK/agentkeys"
[ -f "$KEYS/release.pub.pem" ] || { mkdir -p "$KEYS"; "$REPO/agent/out/ppsign" keygen -out "$KEYS" > /dev/null; }
cat > "$WORK/agent.json" << 'EOF'
{"feed_url": "http://127.0.0.1:3098/releases/tatsu/", "status_url": "http://127.0.0.1:3098/pp/status/tatsu",
 "headers": {"CF-Access-Client-Id": "test.access", "CF-Access-Client-Secret": "test"},
 "battery_floor": 30, "boot_guard_max": 3, "power_key_device": "/home/root/pp-test/pwrkey"}
EOF
# The test bed has no power key: a FIFO stands in (scenario 9 writes events).
dev 'mkdir -p /home/root/pp-test && { [ -p /home/root/pp-test/pwrkey ] || mkfifo /home/root/pp-test/pwrkey; }'
[ -f "$WORK/pp-proxy-arm64" ] || (cd "$REPO/server" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$WORK/pp-proxy-arm64" ./tablet-proxy)
PP_PROXY_BIN="$WORK/pp-proxy-arm64" inst --agent --release-pub "$KEYS/release.pub.pem" --agent-json "$WORK/agent.json" --proxy > "$WORK/6-agent-proxy.log" 2>&1 && rc=0 || rc=$?
check "install with --agent --proxy exits 0" [ "$rc" = 0 ]
check "/ went back to read-only (no EBUSY)" bash -c "! grep -q 'stays read-write' '$WORK/6-agent-proxy.log'"
reboot
check "verify passes after reboot (agent and proxy included)" logto "$WORK/6-verify.log" inst --verify
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
check "pp-agent-tripletap (the triple-press kill switch) runs from the persisted unit" dev '
    for i in $(seq 1 40); do systemctl is-active -q pp-agent-tripletap.service && exit 0; sleep 3; done; exit 1'
check "pp-agent-tripletap started only after rm-sanity exited" dev '
    s=$(systemctl show -P ExecMainExitTimestampMonotonic rm-sanity.service)
    b=$(systemctl show -P ExecMainStartTimestampMonotonic pp-agent-tripletap.service)
    echo "rm-sanity exited at $s us, pp-agent-tripletap started at $b us"; [ "$s" -gt 0 ] && [ "$b" -gt "$s" ]'

t "7. uninstall puts the root fs back to stock; reinstall over a crash-looping memfaultd"
"$REPO/device/install.sh" -p "$PORT" -i "$WORK/id" --uninstall root@127.0.0.1 > "$WORK/7-uninstall.log" 2>&1
# Next boot: stock memfaultd is back, and here it crash-loops as fast as it
# can (boot.sh). A daemon-reload landing on its pending restart right after
# the mask once aborted systemd's PID 1; install now stops it first.
dev 'touch /pp-state/memfaultd-loop'
reboot
out=$(inst --verify 2>&1) && rc=0 || rc=$?
check "verify fails again (stock)" [ "$rc" = 1 ]
check "swupdate.service is enabled again (stock)" dev '[ "$(systemctl is-enabled swupdate.service)" = enabled ]'
check "no freeze block in /etc/hosts" dev '! grep -q "paper-pure freeze" /etc/hosts'
check "stock /etc/hosts lines still there" dev 'grep -q "^127.0.0.1.*localhost" /etc/hosts'
check "pp-agent-boot no longer enabled" dev '! test -e /etc/systemd/system/multi-user.target.wants/pp-agent-boot.service'
check "pp-agent-tripletap no longer enabled" dev '! test -e /etc/systemd/system/multi-user.target.wants/pp-agent-tripletap.service'
check "memfaultd is crash-looping before the reinstall" dev '
    a=$(systemctl show -P NRestarts memfaultd.service); sleep 10; b=$(systemctl show -P NRestarts memfaultd.service)
    echo "  memfaultd restarts: $a, 10 s later $b"; [ "$b" -gt "$a" ]'
inst > "$WORK/7-reinstall.log" 2>&1 && rc=0 || rc=$?
check "reinstall over the crash loop exits 0" [ "$rc" = 0 ]
[ "$rc" = 0 ] || install_diag "$WORK/7-reinstall.log"
check "the test bed stayed up (PID 1 survived the mask and reload)" alive
check "memfaultd was stopped before it was masked (inactive, not failed)" dev '
    s=$(systemctl is-active memfaultd.service); e=$(systemctl is-enabled memfaultd.service); echo "  memfaultd: $s, $e"
    [ "$s" = inactive ] && [ "$e" = masked ]'
dev 'rm -f /pp-state/memfaultd-loop'
check "and install brings it all back" logto "$WORK/7-verify-reinstalled.log" inst --verify

t "9. kill switch and crash loops: real pp-agent, real mods hooks, systemd 255"
# Test releases: mods/release/hooks/*.sh as shipped, upstream's xovi/start and
# xovi/stock at the pinned commit, a stub hashtab, and no xovi.so (ld.so skips
# a preload it can't find). fake-xochitl crashes when it runs with xovi
# preloaded and the live tree has xovi/crash ("slow": after 5 s, "fast": at once).
upstream_xovi_setup() { # DIR: upstream's start and stock at the versions.lock pin
    local url pin g f
    read -r url pin < <(awk '$1 == "rm-xovi-extensions" { print $2, $3 }' "$REPO/mods/versions.lock")
    g=$REPO/mods/.cache/git/rm-xovi-extensions
    git -C "$g" cat-file -e "$pin^{commit}" 2> /dev/null || { g=$WORK/rm-xovi-extensions; [ -d "$g/.git" ] || git clone -q "$url" "$g"; }
    mkdir -p "$1"
    for f in start stock; do git -C "$g" show "$pin:xovi-setup/$f" > "$1/$f"; done
}
mktree() { # ID [CRASH-MODE]
    local tr=$WORK/trees9/$1
    rm -rf "$tr"; mkdir -p "$tr/hooks" "$tr/checks" "$tr/xovi/services/xochitl.service" "$tr/xovi/paper-pure"
    cp "$REPO"/mods/release/hooks/*.sh "$tr/hooks/"
    cp "$WORK/xovi-setup/start" "$WORK/xovi-setup/stock" "$tr/xovi/"
    printf '[Service]\nEnvironment="PP_TEST_RELEASE=%s"\n' "$1" > "$tr/xovi/services/xochitl.service/pp-test.conf"
    printf '#!/bin/sh\necho "hashtab: stub (test bed)"\n' > "$tr/xovi/paper-pure/hashtab"
    if [ -n "${2:-}" ]; then echo "$2" > "$tr/xovi/crash"; fi
    cat > "$tr/checks/10-preload.sh" << 'EOF'
#!/bin/sh
# xochitl runs with this release's xovi drop-in (what xovi/start writes).
env=$(tr '\000' '\n' < "/proc/$(systemctl show -P MainPID xochitl.service)/environ")
echo "$env" | grep -qx 'LD_PRELOAD=/home/root/xovi/xovi.so' && echo "$env" | grep -qx "PP_TEST_RELEASE=$PP_RELEASE_ID"
EOF
    chmod +x "$tr"/hooks/*.sh "$tr"/checks/*.sh "$tr"/xovi/start "$tr"/xovi/stock "$tr"/xovi/paper-pure/hashtab
}
N9=0
publish9() { # ID: sign it, make it latest, copy the feed onto the test bed
    N9=$((N9 + 1))
    "$REPO/agent/out/ppsign" pack -key "$KEYS/release.key.pem" -dir "$WORK/trees9/$1" -id "$1" -os "$TAG" \
        -created "2026-10-25T12:$(printf %02d "$N9"):00Z" -out "$WORK/feed9/releases/tatsu" -latest > /dev/null
    tar -C "$WORK/feed9" -cf - . | dev 'rm -rf /home/root/pp-test/feed && mkdir -p /home/root/pp-test/feed && tar -xf - -C /home/root/pp-test/feed'
}
test_up() { # after every boot: the feed on the test bed itself, and no timer runs in between our steps
    dev 'systemctl stop pp-agent.timer
        systemctl is-active -q pp-test-feed || systemd-run -q --collect --unit pp-test-feed /home/root/pp-test/ppsign serve -dir /home/root/pp-test/feed -addr 127.0.0.1:3098'
}
pst() { # FIELD of `pp-agent status`
    dev /home/root/paper-pure/bin/pp-agent status | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1], ""); print(v if isinstance(v,str) else json.dumps(v))' "$1"
}
# shellcheck disable=SC2317
xenv() { dev 'tr "\000" "\n" < "/proc/$(systemctl show -P MainPID xochitl.service)/environ"'; }
# shellcheck disable=SC2317  # called through check()
preloaded() { # xochitl runs with the xovi drop-in of release $1
    local env
    env=$(xenv)
    grep -qx 'LD_PRELOAD=/home/root/xovi/xovi.so' <<< "$env" && grep -qx "PP_TEST_RELEASE=$1" <<< "$env"
}
# shellcheck disable=SC2317
stock_ui() { local env; env=$(xenv) && [ -n "$env" ] && ! grep -q '^LD_PRELOAD=' <<< "$env"; }
press() { # N quick presses on the stand-in power key, as the kernel reports them
    python3 -I -c '
import struct, sys, time
t = time.time()
for i in range(int(sys.argv[1])):
    s = t + 0.4 * i
    for typ, code, val in ((1, 116, 1), (0, 0, 0), (1, 116, 0), (0, 0, 0)):
        sys.stdout.buffer.write(struct.pack("<qqHHi", int(s), int(s % 1 * 1e6), typ, code, val))
' "$1" | docker exec -i "$C" sh -c 'cat > /home/root/pp-test/pwrkey'
}
# shellcheck disable=SC2317
wait_run() { # LAST_RUN TEXT: a pp-agent run newer than LAST_RUN ended with TEXT in its result
    local r=""
    for _ in $(seq 1 60); do
        if [ "$(pst last_run)" != "$1" ]; then r=$(pst last_result); case $r in *"$2"*) return 0 ;; esac; fi
        sleep 3
    done
    echo "  last_result: ${r:-?}"; return 1
}
# shellcheck disable=SC2317
agent_booted() { # pp-agent-boot has run this boot and the triple-press service is up
    dev 'for i in $(seq 1 100); do
        [ "$(systemctl show -P ExecMainExitTimestampMonotonic pp-agent-boot.service)" != 0 ] && systemctl is-active -q pp-agent-tripletap.service && exit 0
        sleep 3; done; exit 1'
}
boots() { dev 'wc -l < /pp-state/boots.log'; }
# shellcheck disable=SC2317
counter_ok() { # FROM-LINE: no slot switch, and every boot after that line counted 1
    ! dev 'test -e /pp-state/spl-switched' && ! dev 'cat /pp-state/boots.log' | sed -n "$(($1 + 1)),\$p" | grep 'ecnt=' | grep -qv 'ecnt=1$'
}
agent_json() { # EXTRA-JSON-FIELDS
    dev 'cat > /home/root/paper-pure/agent.json' << EOF
{"feed_url": "http://127.0.0.1:3098/releases/tatsu/", "status_url": "http://127.0.0.1:3098/status",
 "require_wifi": false, "battery_floor": 0, "stable_seconds": 15,
 "power_key_device": "/home/root/pp-test/pwrkey"$1}
EOF
    dev 'systemctl restart pp-agent-tripletap.service'
}

rm -rf "$WORK/trees9" "$WORK/feed9"; mkdir -p "$WORK/trees9" "$WORK/feed9/releases/tatsu"
upstream_xovi_setup "$WORK/xovi-setup"
mktree tb1; mktree tb2 slow; mktree tb3 fast
dev 'cat > /home/root/pp-test/ppsign && chmod +x /home/root/pp-test/ppsign' < "$REPO/agent/out/ppsign-arm64"
agent_json ""
test_up
publish9 tb1
dev 'systemctl start pp-agent.service' > /dev/null 2>&1 || true   # the real unit; a oneshot, so this waits
check "9a. pp-agent installs tb1 (real hooks, health check)" [ "$(pst committed)" = tb1 ]
check "9a. upstream's xovi/start drop-in reaches xochitl under systemd" preloaded tb1
check "9a. the drop-in is a tmpfs over the /etc overlay" dev 'grep -q " /etc/systemd/system/xochitl.service.d tmpfs " /proc/mounts'
check "9a. pp-agent marks mods live" [ "$(pst live)" = tb1 ]

r=$(pst last_run); press 3
check "9b. triple-press: mods off" wait_run "$r" "tripletap: mods off (tb1)"
check "9b. xochitl runs stock" stock_ui
check "9b. drop-in unmounted" dev '! grep -q " /etc/systemd/system/xochitl.service.d " /proc/mounts'
check "9b. live marker cleared" [ "$(pst live)" = "" ]
r=$(pst last_run); press 2; sleep 10
check "9c. two presses change nothing" [ "$(pst last_run)" = "$r" ]
press 3
check "9c. triple-press again: mods on, through activate and the health check" wait_run "$r" "tripletap: mods on (tb1)"
check "9c. xovi back in xochitl" preloaded tb1

t "9d. reboot returns stock (activate_on_boot defaults to false); triple-press brings mods back"
reboot
check "9d. pp-agent boot ran and the triple-press service is up" agent_booted
test_up
check "9d. pp-agent boot stayed stock" dev 'journalctl -b -u pp-agent-boot.service --no-pager | grep -q "activate_on_boot is off"'
check "9d. xochitl runs stock after the reboot" stock_ui
check "9d. pp-agent-tripletap started only after rm-sanity" dev '
    [ "$(systemctl show -P ExecMainStartTimestampMonotonic pp-agent-tripletap.service)" -gt "$(systemctl show -P ExecMainExitTimestampMonotonic rm-sanity.service)" ]'
r=$(pst last_run); press 3
check "9d. triple-press: mods on" wait_run "$r" "tripletap: mods on (tb1)"
check "9d. tb1 live" preloaded tb1

t "9e. install a release that crash-loops xochitl after 5 s: rolled back, no reboot"
n=$(boots)
publish9 tb2
dev 'systemctl start pp-agent.service' > /dev/null 2>&1 || true
check "9e. tb2 marked failed, tb1 still committed" [ "$(pst committed) $(pst failed)" = 'tb1 ["tb2"]' ]
check "9e. the health check caught it" grep -q "xochitl not stable" <<< "$(pst last_error)"
check "9e. tb1 is live again" preloaded tb1
check "9e. no reboot: same boot" [ "$(boots)" = "$n" ]
check "9e. rm-emergency never ran (start limit not hit)" dev '[ "$(systemctl show -P ExecMainStartTimestampMonotonic rm-emergency.service)" = 0 ]'
echo "  tb2 crashes before the rollback: $(dev 'journalctl -b -u xochitl.service --no-pager | grep -c "broken mod, crashing in 5 s"' || true)"

t "9f. install a release that crash-loops xochitl at once: rolled back either way"
n=$(boots)
publish9 tb3
dev 'systemctl start --no-block pp-agent.service'
start9=$(date +%s)
# Either pp-agent sees the first crash and rolls back, or the 4 starts are
# used up first: OnFailure=emergency.target, rm-emergency.sh reboots mid-check,
# and pp-agent boot finds Pending set and rolls back.
while running && [ $(($(date +%s) - start9)) -lt 300 ]; do
    f=$(pst failed 2> /dev/null) || true
    case $f in *tb3*) [ "$(pst pending 2> /dev/null)" = "" ] && sleep 10 && break ;; esac
    sleep 3
done
if running; then
    path="pp-agent rolled back before the start limit"
else
    path="the OS rebooted (rm-emergency), then pp-agent boot rolled back"
    echo "  test bed rebooted by itself after $(($(date +%s) - start9)) s"
    boot
    check "9f. after the emergency reboot, pp-agent boot ran" agent_booted
    test_up
    check "9f. pp-agent boot rolled tb3 back" dev 'journalctl -b -u pp-agent-boot.service --no-pager | grep -q "rolling back tb3"'
fi
echo "  path: $path"
check "9f. tb3 marked failed, tb1 committed, nothing pending" [ "$(pst committed) $(pst failed) $(pst pending)" = 'tb1 ["tb2", "tb3"] ' ]
check "9f. no slot switch, boot counter never above 1" counter_ok "$n"

t "9g. activate_on_boot=true and a mod that crash-loops at boot: that boot ends stock"
agent_json ', "activate_on_boot": true'
dev 'echo slow > /home/root/paper-pure/releases/tb1/xovi/crash'   # tb1 breaks (test only)
n=$(boots)
reboot
check "9g. pp-agent boot ran" agent_booted
test_up
check "9g. it activated tb1, saw the crash loop and went stock" dev 'journalctl -b -u pp-agent-boot.service --no-pager | grep -q "tb1 unhealthy at boot (1/3)"'
check "9g. xochitl runs stock" stock_ui
check "9g. the boot counted as unhealthy (guard 1/3)" [ "$(pst unhealthy_boots)" = 1 ]
check "9g. no emergency reboot: only ours, counter 1" bash -c '[ "$1" = "$2" ]' _ "$(boots)" "$((n + 1))"
check "9g. counter ok" counter_ok "$n"
dev 'rm /home/root/paper-pure/releases/tb1/xovi/crash'
agent_json ""

t "9h. the kill switch file: a triple-press only turns mods off, the update unit skips"
r=$(pst last_run); press 3
check "9h. (no file yet) triple-press: mods on" wait_run "$r" "tripletap: mods on (tb1)"
dev 'touch /home/root/paper-pure/disable'
r=$(pst last_run); press 3
check "9h. with the file: mods off" wait_run "$r" "tripletap: mods off (tb1)"
r=$(pst last_run); press 3
check "9h. with the file: a triple-press never turns mods on" wait_run "$r" "tripletap: mods already off"
check "9h. xochitl stock" stock_ui
check "9h. pp-agent.service skips while the file exists" dev 'systemctl start pp-agent.service; [ "$(systemctl show -P ConditionResult pp-agent.service)" = no ]'
dev 'rm -f /home/root/paper-pure/disable; systemctl stop pp-test-feed' || true

t "10. a passcode: /home stays locked until it is typed into xochitl, so xochitl must start without it"
# On the tablet homecryptor waits for the passcode, and only xochitl can ask
# for it. A unit of ours ordered before xochitl (pp-proxy had Before=xochitl
# and needs /home) made xochitl wait past its 60 s JobTimeoutSec:
# OnFailure=emergency.target rebooted the tablet at every boot, no UI ever.
# boot.sh's stand-in: home.mount waits for systemd-ask-password.
dex() { docker exec "$C" sh -c "$1"; }
docker exec "$C" touch /pp-state/passcode
n=$(dex 'wc -l < /pp-state/boots.log')
dev 'systemctl reboot' 2> /dev/null || true
start10=$(date +%s)
while running; do [ $(($(date +%s) - start10)) -lt 120 ] || docker stop -t 5 "$C" > /dev/null; sleep 2; done
docker start "$C" > /dev/null
start10=$(date +%s)
for _ in $(seq 1 60); do [ "$(dex 'systemctl is-active xochitl.service' 2> /dev/null)" = active ] && break; running || break; sleep 3; done
echo "  xochitl: $(dex 'systemctl is-active xochitl.service' 2>&1) after $(($(date +%s) - start10)) s, /home locked"
# Past xochitl's 60 s JobTimeoutSec, with margin: still up, no reboot.
while running && [ $(($(date +%s) - start10)) -lt 100 ]; do sleep 5; done
check "10. the test bed did not reboot (xochitl's start job did not time out)" alive
check "10. still the same boot" [ "$(dex 'wc -l < /pp-state/boots.log')" = "$((n + 1))" ]
check "10. xochitl runs while /home is locked" dex '[ "$(systemctl is-active xochitl.service)" = active ] && ! grep -q " /home " /proc/mounts'
check "10. our units wait for /home, xochitl does not" dex '
    j=$(systemctl list-jobs --no-legend); echo "$j" | grep -E "home.mount|pp-" | sed "s/^/   job: /"
    echo "$j" | grep -q "home.mount .*waiting" && echo "$j" | grep -q "pp-proxy.service .*waiting" && ! echo "$j" | grep -qE "[[:space:]]xochitl[.]service[[:space:]]"'
check "10. the console never says xochitl's start job timed out" bash -c "! docker logs --since $start10 $C 2>&1 | grep -q 'xochitl.service/start timed out'"
dex 'kill $(pidof systemd-ask-password)'   # the passcode, typed into xochitl
check "10. after the passcode: /home mounted, SSH back" dev 'grep -q " /home " /proc/mounts'
check "10. pp-proxy runs" dev 'for i in $(seq 1 40); do systemctl is-active -q pp-proxy.service && exit 0; sleep 3; done; exit 1'
check "10. pp-agent boot ran, after rm-sanity" agent_booted
check "10. verify passes (including: xochitl waits for nothing of ours)" logto "$WORK/10-verify.log" inst --verify
docker exec "$C" rm -f /pp-state/passcode
reboot

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
    check "after the loops, verify still passes" logto "$WORK/8-verify.log" inst --verify
fi

echo
echo "device tests: $PASS passed, $FAILN failed (logs in $WORK)"
for f in "${FAILED[@]}"; do echo "  FAILED: $f"; done
[ "$FAILN" = 0 ]
exit
}
