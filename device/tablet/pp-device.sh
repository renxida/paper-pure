#!/bin/bash
# pp-device: the tablet's own config. Runs ON the tablet, as root, from
# /home/root/paper-pure/device/ (device/install.sh puts it there).
#
#   pp-device.sh install          freeze the OS, keep SSH off Wi-Fi, persist our
#                                 units into the real root fs. Safe to re-run.
#   pp-device.sh verify           check all of that, change nothing. Exit 1 on FAIL.
#   pp-device.sh uninstall        put every root fs file we touched back to stock.
#   pp-device.sh persist PATH...  copy PATH as it is now (live) into the real root fs.
#   pp-device.sh restore PATH...  put PATH back to stock, live and in the root fs.
#
# Why "real root fs": in developer mode / is plain ext4, mounted read-only,
# and /etc is an overlay whose upper layer is tmpfs (var-volatile-etc.service).
# A plain write to /etc is gone at the next reboot. We remount / rw, bind-mount
# / somewhere (a non-recursive bind shows the ext4 under the overlay), write
# there, and write the same thing live so it takes effect now. Nothing else is
# unmounted, so SSH and the running system are left alone.
set -euo pipefail

FROZEN=3.27.2.2
PP=/home/root/paper-pure
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV=$PP/device
STOCK=$DEV/stock            # stock copy of every root fs path we changed
MANAGED=$DEV/managed.list   # the paths we manage, in the order we took them
LPGPR=/sys/devices/platform/lpgpr
WIFI_SSH_MARKER=/data/internal/rm_enable_ssh_wifi_marker
SYSD=/etc/systemd/system
BIND=/run/pp-device/root
# The OS update path: xochitl -> update-engine (D-Bus no.remarkable.update1)
# -> swupdate (socket-activated, suricatta) whose server config memfaultd
# writes. xochitl's Settings > General > Software > Updates switch enables
# or disables update-engine.service; masked, it stays off.
# memfault-attributes only feeds memfaultd; masked so it doesn't fail every boot.
UPDATE_UNITS="swupdate.service swupdate.socket update-engine.service memfaultd.service memfault-attributes.service"
# Root SSH on wlan0. Stock keeps it off unless the marker exists; masked, even
# `rm-ssh-over-wlan on` can't turn it on.
SSH_UNITS="dropbear-wlan.socket"
AGENT_UNITS="pp-agent-boot.service pp-agent.service pp-agent.timer pp-agent-tripletap.service"
# Units that can turn mods on (boot, triple-press, install), so they wait
# for rm-sanity (wait-sanity.conf).
WAIT_UNITS="pp-agent-boot.service pp-agent-tripletap.service pp-agent.service"

FAILS=0
say()  { printf '%-7s %s\n' "$1" "$2"; }
pass() { say PASS "$1"; }
fail() { say FAIL "$1"; FAILS=$((FAILS + 1)); }
info() { say INFO "$1"; }
chg()  { say CHANGE "$1"; }
die()  { say ERROR "$1" >&2; exit 1; }
have_systemd() { [ -d /run/systemd/system ] && [ "$(cat /proc/1/comm 2>/dev/null)" = systemd ]; }

# ---------------------------------------------------------------- real root fs
REAL=""        # prefix where the real root fs is visible ("" = same as live)
REAL_OPEN=""
ROOT_WAS_RO=""
root_is_ro() { awk '$2 == "/" { o = $4 } END { exit !(o ~ /^ro(,|$)/) }' /proc/mounts; }
real_open() { # rw|ro
    [ -n "$REAL_OPEN" ] && return 0
    if [ "$1" = rw ] && root_is_ro; then
        mount -o remount,rw / || die "cannot remount / read-write (is developer mode on?)"
        ROOT_WAS_RO=1
    fi
    if mountpoint -q /etc; then
        mkdir -p "$BIND"
        mountpoint -q "$BIND" || mount --bind / "$BIND"
        REAL=$BIND
    fi
    REAL_OPEN=$1
}
real_close() {
    [ -n "$REAL_OPEN" ] || return 0
    sync
    if [ -n "$REAL" ] && mountpoint -q "$BIND"; then umount "$BIND" || say WARN "could not unmount $BIND"; fi
    if [ -n "$ROOT_WAS_RO" ] && ! mount -o remount,ro / 2> /dev/null; then
        # EBUSY: an unlinked inode is still cached. Drop clean caches, retry.
        echo 2 > /proc/sys/vm/drop_caches 2> /dev/null || true
        mount -o remount,ro / || say WARN "/ stays read-write until the next reboot"
    fi
    REAL="" REAL_OPEN="" ROOT_WAS_RO=""
}
trap real_close EXIT

# One path, both views. backup_once must run before the first write.
backup_once() {
    local p=$1
    grep -qxF -- "$p" "$MANAGED" 2>/dev/null && return 0
    mkdir -p "$DEV"
    if [ -e "$REAL$p" ] || [ -L "$REAL$p" ]; then
        mkdir -p "$STOCK$(dirname "$p")"
        cp -a "$REAL$p" "$STOCK$p"
    fi
    echo "$p" >> "$MANAGED"
}
views() { if [ -n "$REAL" ]; then echo "/ $REAL/"; else echo "/"; fi; }
write_file() { # src dst mode
    # An existing file is rewritten in place, never replaced: replacing would
    # unlink the old inode, the /etc overlay can hold it, and then
    # `mount -o remount,ro /` fails with EBUSY until reboot. In place also
    # works for a file that is itself a bind mount (/etc/hosts in docker).
    mkdir -p "$(dirname "$2")"
    if [ -L "$2" ] || [ -d "$2" ]; then rm -rf "$2"; fi
    cat "$1" > "$2"
    chmod "$3" "$2"
}
same_file() { [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2" && [ "$(stat -c %a "$2")" = "${3#0}" ]; }
set_file() { # path src mode
    local p=$1 v n=0
    backup_once "$p"
    for v in $(views); do
        same_file "$2" "$v${p#/}" "$3" && continue
        write_file "$2" "$v${p#/}" "$3"; n=1
    done
    if [ $n = 1 ]; then chg "$p"; fi
}
set_link() { # path target
    local p=$1 v n=0
    backup_once "$p"
    for v in $(views); do
        [ -L "$v${p#/}" ] && [ "$(readlink "$v${p#/}")" = "$2" ] && continue
        mkdir -p "$(dirname "$v${p#/}")"
        rm -rf "$v${p#/}"
        ln -s "$2" "$v${p#/}"; n=1
    done
    if [ $n = 1 ]; then chg "$p -> $2"; fi
}
# /etc/hosts holds blocks from several owners; each sits between
# a line starting "# NAME start" and the line "# NAME end". Replace one
# block in both views, keep everything else.
hosts_with_block() { # file name blockfile -> stdout
    sed "/^# $2 start/,/^# $2 end\$/d" "$1"
    [ -s "$3" ] && cat "$3"
    return 0
}
set_hosts_block() { # name blockfile
    local v n=0 tmp
    tmp=$(mktemp)
    backup_once /etc/hosts
    for v in $(views); do
        hosts_with_block "${v}etc/hosts" "$1" "$2" > "$tmp"
        cmp -s "$tmp" "${v}etc/hosts" && continue
        write_file "$tmp" "${v}etc/hosts" 0644; n=1
    done
    rm -f "$tmp"
    if [ $n = 1 ]; then chg "/etc/hosts: block '$1'"; fi
}
persist_path() { # copy live state of one path into the real root fs
    local p=$1
    [ -n "$REAL" ] || { info "$p: no /etc overlay here, live is already the root fs"; return 0; }
    backup_once "$p"
    if [ -L "$p" ]; then
        [ -L "$REAL$p" ] && [ "$(readlink "$REAL$p")" = "$(readlink "$p")" ] && return 0
        mkdir -p "$(dirname "$REAL$p")"; rm -rf "$REAL$p"; ln -s "$(readlink "$p")" "$REAL$p"
    elif [ -f "$p" ]; then
        same_file "$p" "$REAL$p" "$(stat -c %a "$p")" && return 0
        write_file "$p" "$REAL$p" "$(stat -c %a "$p")"
    elif [ ! -e "$p" ]; then
        [ -e "$REAL$p" ] || [ -L "$REAL$p" ] || return 0
        rm -f "$REAL$p"
    else
        die "$p: only files and symlinks can be persisted"
    fi
    chg "$p (persisted)"
}
restore_path() { # put one path back to stock in both views
    local p=$1 v d
    # Only what we changed: a path we never backed up has no stock copy,
    # and deleting it would delete a stock file.
    grep -qxF -- "$p" "$MANAGED" 2>/dev/null || die "$p: not managed by pp-device (never changed, nothing to restore)"
    for v in $(views); do
        d="$v${p#/}"
        if [ -f "$STOCK$p" ] && [ ! -L "$STOCK$p" ] && [ -f "$d" ] && [ ! -L "$d" ]; then
            cat "$STOCK$p" > "$d"; chmod "$(stat -c %a "$STOCK$p")" "$d"
        else
            rm -rf "$d"
            if [ -e "$STOCK$p" ] || [ -L "$STOCK$p" ]; then mkdir -p "$(dirname "$d")"; cp -a "$STOCK$p" "$d"; fi
        fi
    done
    if [ -f "$MANAGED" ]; then grep -vxF -- "$p" "$MANAGED" > "$MANAGED.new" || true; mv -f "$MANAGED.new" "$MANAGED"; fi
    rm -rf "${STOCK:?}$p"
    chg "$p (stock)"
}

# ---------------------------------------------------------------- checks
read_model() {
    local f
    for f in /sys/firmware/devicetree/base/model /proc/device-tree/model /sys/devices/soc0/machine; do
        [ -r "$f" ] && { tr -d '\0' < "$f"; return 0; }
    done
    return 0
}
# shellcheck disable=SC1091
os_version() { ( . /etc/os-release 2>/dev/null; echo "${IMG_VERSION:-unknown}" ); }
slot_dev() { realpath "/dev/disk/by-partlabel/root_$1" 2>/dev/null || true; }

preflight() { # strict before install; reports only in verify
    local mode=$1 m v
    m=$(read_model); v=$(os_version)
    if [ "$m" = "reMarkable Tatsu" ]; then pass "model: $m"; else fail "model: '$m', expected 'reMarkable Tatsu'"; fi
    if [ "$v" = "$FROZEN" ]; then pass "OS $v (frozen version)"; else fail "OS $v, frozen version is $FROZEN"; fi
    if grep -q 'root=/dev/dm-' /proc/cmdline 2>/dev/null; then
        fail "root is dm-verity (developer mode off): nothing can persist"
    fi
    if [ -d "$LPGPR" ]; then
        local sb swu
        sb=$(cat "$LPGPR/secboot" 2>/dev/null || echo "?")
        if [ "$sb" = unlocked ]; then pass "developer mode (secboot=unlocked)"; else fail "developer mode is off (secboot=$sb)"; fi
        if [ -r "$LPGPR/swu_status" ]; then
            swu=$(cat "$LPGPR/swu_status")
            if [ "$swu" = 0 ]; then pass "no OS update staged (swu_status=0)"
            else fail "swu_status=$swu: an OS update was installed or interrupted (1 installed, 3 failed, 7 in progress)"; fi
        else
            info "swu_status not readable here"
        fi
        [ -r "$LPGPR/root_part" ] && slot_checks
    else
        info "no $LPGPR: not a real tablet (emulator or test bed), slot checks skipped"
    fi
    if [ "$mode" = install ] && [ "$FAILS" -gt 0 ]; then die "preflight failed; nothing changed"; fi
    return 0
}
slot_checks() {
    local part next a other dev ver mnt
    part=$(cat "$LPGPR/root_part" 2>/dev/null || echo "?")
    info "running from root slot $part, errcnt=$(cat "$LPGPR/root${part}_errcnt" 2>/dev/null || echo '?')"
    if [ -r /sys/bus/mmc/devices/mmc0:0001/boot_part ] && command -v rootdev > /dev/null; then
        a=$(rootdev --active 2>/dev/null || true); next=$(rootdev --next-boot 2>/dev/null || true)
        if [ -n "$a" ] && [ "$a" = "$next" ]; then pass "next boot uses the running slot ($a)"
        else
            fail "next boot goes to '$next', not the running '$a': an update is waiting. To stay: root_part a -> 'mmc bootpart enable 1 0 /dev/mmcblk0boot0', b -> 'mmc bootpart enable 2 0 /dev/mmcblk0boot1' (human decision)"
        fi
    else
        info "boot slot selection not readable here"
    fi
    case $part in a) other=b ;; b) other=a ;; *) return 0 ;; esac
    dev=$(slot_dev "$other")
    [ -b "$dev" ] || return 0
    mnt=/run/pp-device/slot
    mkdir -p "$mnt"
    if mount -o ro,noload "$dev" "$mnt" 2>/dev/null; then
        # shellcheck disable=SC1091
        ver=$( (. "$mnt/etc/os-release" 2>/dev/null; echo "${IMG_VERSION:-unknown}") )
        umount "$mnt" || true
        info "other slot $other ($dev) holds OS $ver; a fallback would boot that, without our freeze"
    else
        info "other slot $other ($dev) could not be mounted read-only"
    fi
}

check_link() { # path target label: both views
    local p=$1 t=$2 v ok=1
    for v in $(views); do
        [ -L "$v${p#/}" ] && [ "$(readlink "$v${p#/}")" = "$t" ] || ok=0
    done
    if [ $ok = 1 ]; then pass "$3"; else fail "$3: $p is not -> $t (live and root fs)"; fi
}
check_file() { # path src label
    local p=$1 v ok=1
    for v in $(views); do cmp -s "$2" "$v${p#/}" || ok=0; done
    if [ $ok = 1 ]; then pass "$3"; else fail "$3: $p differs from $2 (live or root fs)"; fi
}
check_inactive() {
    have_systemd || return 0
    local s
    s=$(systemctl is-active "$1" 2>/dev/null || true)
    if [ "$s" = active ]; then fail "$1 is running"; else pass "$1 not running ($s)"; fi
}
resolves_to() { # name -> address the C library returns (via busybox wget's message)
    { wget -T 2 -O /dev/null "http://$1:9/" 2>&1 || true; } | sed -n 's/.*(\([0-9a-fA-F.:]*\):9).*/\1/p; s/.*remote host (\([0-9a-fA-F.:]*\)).*/\1/p' | head -n 1
}
no_address() { # name: systemd-resolved (the tablet's resolver) answers a 0.0.0.0 hosts line with "no address" (NODATA), for A and AAAA
    command -v resolvectl >/dev/null 2>&1 || return 1
    local t out
    for t in A AAAA; do
        out=$(resolvectl query -t "$t" "$1" 2>&1 || true)   # exits 1 on "no address"
        case $out in *'does not have any RR of the requested type'*) ;; *) return 1 ;; esac
    done
}

# ---------------------------------------------------------------- install
step_files() { # our own helpers, kept on /home (persistent)
    if [ "$HERE" != "$DEV" ]; then
        mkdir -p "$DEV"
        cp "$HERE/pp-device.sh" "$HERE/wait-sanity.sh" "$HERE/freeze.hosts" "$HERE/wait-sanity.conf" "$DEV/"
    fi
    chmod 0755 "$DEV/pp-device.sh" "$DEV/wait-sanity.sh"
}
step_agent() {
    local u
    for u in $WAIT_UNITS; do set_file "$SYSD/$u.d/10-pp-device.conf" "$HERE/wait-sanity.conf" 0644; done
    if [ ! -x "$PP/bin/pp-agent" ]; then info "pp-agent not installed; its units not persisted"; return 0; fi
    for u in $AGENT_UNITS; do
        [ -f "$PP/systemd/$u" ] || die "$PP/systemd/$u missing (run agent/install.sh first)"
        set_file "$SYSD/$u" "$PP/systemd/$u" 0644
    done
    set_link "$SYSD/multi-user.target.wants/pp-agent-boot.service" ../pp-agent-boot.service
    set_link "$SYSD/multi-user.target.wants/pp-agent-tripletap.service" ../pp-agent-tripletap.service
    set_link "$SYSD/timers.target.wants/pp-agent.timer" ../pp-agent.timer
}
proxy_ca_bundle() { # stdout: a bundle file's content with our CA appended once
    local ca=$PP/proxy/ca.crt
    cat "$1"
    grep -qF "$(sed -n 2p "$ca")" "$1" || cat "$ca"
}
step_proxy() {
    if [ ! -x "$PP/bin/pp-proxy" ]; then info "pp-proxy not installed; sync stays as it is"; return 0; fi
    local unit=$PP/systemd/pp-proxy.service tmp
    [ -f "$unit" ] || unit=/run/systemd/system/pp-proxy.service
    [ -f "$unit" ] || die "pp-proxy.service not found (run server/tablet-proxy/install.sh --runtime first)"
    [ -f "$PP/proxy/ca.crt" ] || die "$PP/proxy/ca.crt missing (pp-proxy gencert)"
    set_file "$SYSD/pp-proxy.service" "$unit" 0644
    set_link "$SYSD/multi-user.target.wants/pp-proxy.service" ../pp-proxy.service
    tmp=$(mktemp)
    "$PP/bin/pp-proxy" hosts > "$tmp"
    set_hosts_block "pp-proxy" "$tmp"
    proxy_ca_bundle "${REAL:-}/etc/ssl/certs/ca-certificates.crt" > "$tmp"
    set_file /etc/ssl/certs/ca-certificates.crt "$tmp" 0644
    rm -f "$tmp"
}

cmd_install() {
    echo "pp-device install ($(os_version), $(date -u +%FT%TZ))"
    preflight install
    step_files
    local u
    # Stop before masking: a daemon-reload that lands on a pending restart of
    # a now-masked unit (memfaultd crash-looping) aborted systemd 255's PID 1
    # in the test bed, and on the tablet PID 1 dying means a reboot.
    if have_systemd; then
        for u in $UPDATE_UNITS $SSH_UNITS; do systemctl stop "$u" 2>/dev/null || true; done
        for u in $UPDATE_UNITS $SSH_UNITS; do systemctl reset-failed "$u" 2>/dev/null || true; done
    fi
    real_open rw
    for u in $UPDATE_UNITS $SSH_UNITS; do set_link "$SYSD/$u" /dev/null; done
    set_hosts_block "paper-pure freeze" "$HERE/freeze.hosts"
    step_agent
    step_proxy
    real_close
    if [ -e "$WIFI_SSH_MARKER" ]; then rm -f "$WIFI_SSH_MARKER"; chg "removed $WIFI_SSH_MARKER (SSH over Wi-Fi off)"; fi
    if have_systemd; then
        systemctl daemon-reload
        [ -f "$SYSD/pp-agent.timer" ] && systemctl start pp-agent.timer
        [ -f "$SYSD/pp-agent-tripletap.service" ] && systemctl start pp-agent-tripletap.service
        [ -f "$SYSD/pp-proxy.service" ] && { systemctl is-active -q pp-proxy.service || systemctl start pp-proxy.service; }
    fi
    echo
    FAILS=0
    cmd_verify
}

cmd_verify() {
    echo "pp-device verify ($(date -u +%FT%TZ))"
    preflight verify
    real_open ro
    local u n a
    # Freeze, by setting and by unit. The Settings > General > Software >
    # Updates switch is update-engine.service itself: xochitl enables, starts,
    # stops and disables that unit over systemd's D-Bus API and shows the
    # switch on only when the unit is "enabled". Masked, it reads off and
    # can't be switched on.
    for u in $UPDATE_UNITS; do check_link "$SYSD/$u" /dev/null "masked: $u"; check_inactive "$u"; done
    if have_systemd; then
        u=$(systemctl is-enabled update-engine.service 2>/dev/null || true)
        if [ "$u" = masked ]; then pass "setting: Updates switch is off for good (update-engine.service is $u)"
        else fail "setting: update-engine.service is '$u', so the Updates switch can turn on"; fi
    fi
    # Nothing of ours may make xochitl wait: with a passcode set, /home
    # unlocks only once the passcode is typed into xochitl, and every unit of
    # ours needs /home. xochitl waiting past its 60 s JobTimeoutSec means
    # OnFailure=emergency.target, a reboot, every boot (device/README.md).
    if have_systemd; then
        n=$(systemctl list-dependencies --after --all --plain --no-legend xochitl.service 2>/dev/null | awk '$1 ~ /^pp-/ { print $1 }' | sort -u | tr '\n' ' ')
        if [ -z "$n" ]; then pass "xochitl waits for nothing of ours (it must start before /home unlocks)"
        else fail "xochitl is ordered after ${n% }: with a passcode set it would never start"; fi
    fi
    # Freeze, by network block.
    check_hosts_block "paper-pure freeze" "$HERE/freeze.hosts"
    while read -r n; do
        a=$(resolves_to "$n")
        if [ "$a" = 0.0.0.0 ]; then pass "resolves to 0.0.0.0: $n"
        elif [ -z "$a" ] && no_address "$n"; then pass "resolves to no address (systemd-resolved, A and AAAA): $n"
        else fail "$n resolves to '${a:-?}', not 0.0.0.0"; fi
    done < <(awk '$1 == "0.0.0.0" { print $2 }' "$HERE/freeze.hosts")
    # SSH stays private.
    if [ -e "$WIFI_SSH_MARKER" ]; then fail "SSH over Wi-Fi marker is present ($WIFI_SSH_MARKER)"; else pass "SSH over Wi-Fi marker absent"; fi
    for u in $SSH_UNITS; do check_link "$SYSD/$u" /dev/null "masked: $u"; check_inactive "$u"; done
    n=$(grep -c '^ssh-' /home/root/.ssh/authorized_keys 2>/dev/null || true)
    if [ "${n:-0}" -gt 0 ]; then pass "SSH keys authorized: $n"; else fail "no SSH key in /home/root/.ssh/authorized_keys"; fi
    # Boot hook and agent.
    for u in $WAIT_UNITS; do check_file "$SYSD/$u.d/10-pp-device.conf" "$HERE/wait-sanity.conf" "${u%.service} waits for rm-sanity"; done
    if [ -x "$PP/bin/pp-agent" ]; then
        for u in $AGENT_UNITS; do check_file "$SYSD/$u" "$PP/systemd/$u" "persisted: $u"; done
        check_link "$SYSD/multi-user.target.wants/pp-agent-boot.service" ../pp-agent-boot.service "enabled: pp-agent-boot.service"
        check_link "$SYSD/multi-user.target.wants/pp-agent-tripletap.service" ../pp-agent-tripletap.service "enabled: pp-agent-tripletap.service"
        check_link "$SYSD/timers.target.wants/pp-agent.timer" ../pp-agent.timer "enabled: pp-agent.timer"
        if have_systemd; then
            u=$(systemctl is-active pp-agent-tripletap.service 2>/dev/null || true)
            if [ "$u" != active ] && systemctl list-jobs --no-legend 2>/dev/null | grep -q pp-agent-tripletap; then u="queued (starts after rm-sanity)"; fi
            case $u in active | activating | queued*) pass "triple-press kill switch: pp-agent-tripletap is $u" ;;
            *) fail "triple-press kill switch: pp-agent-tripletap is $u (journalctl -u pp-agent-tripletap)" ;; esac
        fi
        [ -e "$PP/disable" ] && info "kill switch file is on: $PP/disable exists (mods stay off; triple-press only turns them off)"
    else
        info "pp-agent not installed"
    fi
    if [ -x "$PP/bin/pp-proxy" ]; then
        check_link "$SYSD/multi-user.target.wants/pp-proxy.service" ../pp-proxy.service "enabled: pp-proxy.service"
        local tmp; tmp=$(mktemp); "$PP/bin/pp-proxy" hosts > "$tmp"
        check_hosts_block "pp-proxy" "$tmp"; rm -f "$tmp"
        if grep -qF "$(sed -n 2p "$PP/proxy/ca.crt")" "${REAL:-}/etc/ssl/certs/ca-certificates.crt"; then pass "pp-proxy CA in the root fs bundle"
        else fail "pp-proxy CA missing from the root fs CA bundle"; fi
    else
        info "pp-proxy not installed"
    fi
    # Everything we persisted is the same live and in the root fs.
    check_managed
    real_close
    echo
    if [ "$FAILS" = 0 ]; then echo "pp-device: all checks passed"; else echo "pp-device: $FAILS check(s) failed"; fi
    [ "$FAILS" = 0 ]
}
check_hosts_block() { # name blockfile
    local v ok=1 got
    for v in $(views); do
        got=$(sed -n "/^# $1 start/,/^# $1 end\$/p" "${v}etc/hosts")
        [ "$got" = "$(cat "$2")" ] || ok=0
    done
    if [ $ok = 1 ]; then pass "/etc/hosts block '$1' (live and root fs)"; else fail "/etc/hosts block '$1' missing or stale (live or root fs)"; fi
}
check_managed() {
    [ -f "$MANAGED" ] || return 0
    [ -n "$REAL" ] || return 0
    local p bad=0
    while IFS= read -r p; do
        if [ -L "$p" ] || [ -L "$REAL$p" ]; then [ "$(readlink "$p")" = "$(readlink "$REAL$p")" ] || { bad=1; fail "drift: $p (live vs root fs)"; }
        elif [ -e "$p" ] || [ -e "$REAL$p" ]; then cmp -s "$p" "$REAL$p" || { bad=1; fail "drift: $p (live vs root fs)"; }
        fi
    done < "$MANAGED"
    [ $bad = 0 ] && pass "live matches the root fs for $(wc -l < "$MANAGED") managed paths"
    return 0
}

cmd_uninstall() {
    echo "pp-device uninstall"
    [ -f "$MANAGED" ] || { info "nothing to undo"; return 0; }
    real_open rw
    local p
    while read -r p; do restore_path "$p"; done < <(sed '1!G;h;$!d' "$MANAGED")
    real_close
    have_systemd && systemctl daemon-reload
    rm -f "$MANAGED"
    info "root fs is stock again. Update units come back at the next reboot."
    info "the Updates switch in Settings works again after the next reboot."
}

# Before basic.target the stock /etc overlay and the /etc/dropbear bind may
# not be up yet; writing then lands in the wrong layer (and can cost SSH).
wait_booted() {
    have_systemd || return 0
    local s=""
    for _ in $(seq 1 60); do
        s=$(systemctl is-system-running 2> /dev/null || true)
        [ "$s" = initializing ] || return 0
        sleep 2
    done
    die "the tablet is still booting (systemd: $s); try again in a minute"
}

main() {
    [ "$(id -u)" = 0 ] || die "run as root"
    wait_booted
    mkdir -p "$DEV" /run/pp-device
    exec 9> /run/pp-device/lock
    flock -n 9 || die "another pp-device is running"
    case "${1:-}" in
    install) cmd_install ;;
    verify) cmd_verify ;;
    uninstall) cmd_uninstall ;;
    persist) shift; real_open rw; for p in "$@"; do persist_path "$p"; done; real_close ;;
    restore) shift; real_open rw; for p in "$@"; do restore_path "$p"; done; real_close ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
}
main "$@"
