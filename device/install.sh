#!/bin/bash
# Set up the tablet over SSH. Run from the repo on a computer plugged into the
# tablet by USB (or from the emulator host). Safe to re-run: every step checks
# first and only changes what is off.
#
#   device/install.sh [options] [user@]host
#
#     (no option)        freeze the OS, keep SSH off Wi-Fi, authorize keys,
#                        persist units, then verify
#     --verify           check only, change nothing; exit 1 on any FAIL
#     --uninstall        put the tablet's root fs back to stock
#     --key FILE         authorize this public key (repeatable). Default:
#                        ~/.ssh/id_ed25519.pub if it exists
#     --agent            also install pp-agent (agent/out/pp-agent-arm64;
#                        build with: make -C agent build)
#     --release-pub FILE Cedar's release public key (needed with --agent the
#                        first time)
#     --agent-json FILE  the tablet's agent.json (kept if one is there already)
#     --proxy            also install pp-proxy for self-hosted sync
#                        (server/out/pp-proxy-arm64: make -C server tablet-proxy)
#     -p PORT, -i KEY    passed to ssh. PP_SSH_OPTS adds more ssh options.
#                        PP_AGENT_BIN / PP_PROXY_BIN point at other builds.
#
# Over USB the tablet is root@10.11.99.1. The first connection asks for the
# root password shown on the tablet (Settings > Help > About > Copyrights and
# licenses); after --key, it never asks again.
# Commands for the tablet are single-quoted on purpose: they expand there.
# shellcheck disable=SC2016
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_BIN=${PP_AGENT_BIN:-$REPO/agent/out/pp-agent-arm64}
PROXY_BIN=${PP_PROXY_BIN:-$REPO/server/out/pp-proxy-arm64}
MODE=install AGENT="" PROXY="" RELEASE_PUB="" AGENT_JSON="" TARGET=""
KEYS=()
SSH=(ssh -o ServerAliveInterval=10 -o ConnectTimeout=10)
while [ $# -gt 0 ]; do
    case $1 in
    --verify) MODE=verify ;;
    --uninstall) MODE=uninstall ;;
    --key) KEYS+=("$2"); shift ;;
    --agent) AGENT=1 ;;
    --release-pub) RELEASE_PUB=$2; shift ;;
    --agent-json) AGENT_JSON=$2; shift ;;
    --proxy) PROXY=1 ;;
    -p) SSH+=(-p "$2"); shift ;;
    -i) SSH+=(-i "$2"); shift ;;
    -h | --help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) TARGET=$1 ;;
    esac
    shift
done
[ -n "$TARGET" ] || { echo "usage: device/install.sh [options] [user@]host (see --help)" >&2; exit 2; }
[ ${#KEYS[@]} -gt 0 ] || { [ -f "$HOME/.ssh/id_ed25519.pub" ] && KEYS=("$HOME/.ssh/id_ed25519.pub"); } || true
# shellcheck disable=SC2206
[ -n "${PP_SSH_OPTS:-}" ] && SSH+=(${PP_SSH_OPTS})

# One SSH connection for the whole run, so a password is asked at most once.
CM=$(mktemp -d)
trap 'ssh -o ControlPath="$CM/c" -O exit "$TARGET" 2>/dev/null || true; rm -rf "$CM"' EXIT
SSH+=(-o ControlMaster=auto -o ControlPath="$CM/c" -o ControlPersist=120)
on() { "${SSH[@]}" "$TARGET" "$@"; }
push() { # local-dir remote-dir: tar over ssh (no scp or sftp needed)
    tar -C "$1" -cf - . | on "rm -rf '$2' && mkdir -p '$2' && tar -xf - -C '$2'"
}
step() { printf '\n== %s\n' "$*"; }

step "connect to $TARGET"
for try in 1 2 3; do   # a USB link that just came up can reset the first try
    on 'echo "$(cat /sys/devices/soc0/machine 2>/dev/null || echo unknown device), OS $(. /etc/os-release; echo $IMG_VERSION)"' && break
    [ "$try" = 3 ] && { echo "cannot reach $TARGET over SSH" >&2; exit 1; }
    sleep 3
done

if [ "$MODE" = verify ]; then
    push "$REPO/device/tablet" /tmp/pp-device-verify
    on 'bash /tmp/pp-device-verify/pp-device.sh verify; rc=$?; rm -rf /tmp/pp-device-verify; exit $rc'
    exit $?
fi
if [ "$MODE" = uninstall ]; then
    on 'bash /home/root/paper-pure/device/pp-device.sh uninstall'
    exit $?
fi

step "authorize SSH keys"
for k in "${KEYS[@]}"; do
    key=$(head -n 1 "$k")
    case $key in ssh-*) ;; *) echo "$k is not an SSH public key" >&2; exit 1 ;; esac
    on "mkdir -p /home/root/.ssh && chmod 700 /home/root/.ssh && touch /home/root/.ssh/authorized_keys && chmod 600 /home/root/.ssh/authorized_keys && if grep -qxF '$key' /home/root/.ssh/authorized_keys; then echo 'key already there: $k'; else echo '$key' >> /home/root/.ssh/authorized_keys && echo 'CHANGE  key added: $k'; fi"
done

step "copy device files to /home/root/paper-pure/device"
STAGE=$(mktemp -d)
cp "$REPO"/device/tablet/* "$STAGE/"
on 'mkdir -p /home/root/paper-pure/device'
tar -C "$STAGE" -cf - . | on 'tar -xf - -C /home/root/paper-pure/device'
rm -rf "$STAGE"

if [ -n "$AGENT" ]; then
    step "install pp-agent"
    B=$(mktemp -d)
    [ -f "$AGENT_BIN" ] || { echo "build it first: make -C agent build" >&2; exit 1; }
    cp "$AGENT_BIN" "$B/pp-agent"
    cp "$REPO/agent/install.sh" "$B/"
    mkdir -p "$B/systemd" && cp "$REPO"/agent/systemd/* "$B/systemd/"
    if [ -n "$RELEASE_PUB" ]; then cp "$RELEASE_PUB" "$B/release.pub.pem"
    elif on 'test -f /home/root/paper-pure/keys/release.pub.pem'; then
        on 'cat /home/root/paper-pure/keys/release.pub.pem' > "$B/release.pub.pem"
    else echo "--release-pub FILE is needed the first time" >&2; exit 1; fi
    [ -n "$AGENT_JSON" ] && cp "$AGENT_JSON" "$B/agent.json"
    push "$B" /home/root/paper-pure/.stage-agent
    rm -rf "$B"
    on 'cd /home/root/paper-pure/.stage-agent && sh install.sh; rc=$?; rm -rf /home/root/paper-pure/.stage-agent; exit $rc'
fi

if [ -n "$PROXY" ]; then
    step "install pp-proxy (runtime first; pp-device persists it below)"
    B=$(mktemp -d)
    [ -f "$PROXY_BIN" ] || { echo "build it first: make -C server tablet-proxy" >&2; exit 1; }
    cp "$PROXY_BIN" "$B/pp-proxy"
    cp "$REPO/server/tablet-proxy/pp-proxy.service" "$REPO/server/tablet-proxy/install.sh" "$B/"
    push "$B" /home/root/paper-pure/.stage-proxy
    rm -rf "$B"
    on 'set -e; test -f /home/root/paper-pure/agent.json || { echo "agent.json first (--agent --agent-json FILE)" >&2; exit 1; }
        mkdir -p /home/root/paper-pure/systemd
        cp /home/root/paper-pure/.stage-proxy/pp-proxy.service /home/root/paper-pure/systemd/
        cd /home/root/paper-pure/.stage-proxy && bash install.sh --runtime; cd /; rm -rf /home/root/paper-pure/.stage-proxy'
fi

step "freeze the OS, keep SSH private, persist units"
rc=0
on 'bash /home/root/paper-pure/device/pp-device.sh install' || rc=$?
case $rc in
0) ;;
255) # ssh's own failure: the link went away. pp-device outlives the session.
    echo "ERROR   the SSH connection dropped during the install. pp-device keeps going on the tablet and logs to"
    echo "        /home/root/paper-pure/device/install.log. Run device/install.sh again: it waits for that run, then finishes the job or confirms it."
    exit 1 ;;
*) echo "ERROR   pp-device install failed (exit $rc): its FAIL and ERROR lines above say why and what to do"; exit "$rc" ;;
esac

step "SSH still works on a fresh connection"
for try in 1 2 3; do   # a new connection; a busy tablet can be slow to answer
    "${SSH[@]}" -o ControlPath=none -o BatchMode=yes "$TARGET" true && { echo "PASS    fresh SSH connection (key auth)"; exit 0; }
    sleep 3
done
echo "FAIL    no fresh SSH connection with the key"
exit 1
