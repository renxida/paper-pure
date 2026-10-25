#!/bin/bash
# Rung 2 for the whole stack. Everything goes into the emulator the way it
# goes onto the tablet (device/install.sh with pp-agent and pp-proxy, mods as
# signed releases), against a local server (the server/ image: rmfakecloud +
# ppd, behind server/test/fakeaccess standing in for Cloudflare Access).
# Then it checks the OS freeze, sync both ways, OTA (good, broken, forged,
# tampered, wrong OS), the kill switches, reboot, and the status reports.
#
#   test/e2e/run.sh [--skip-build] [--keep]
#
#   --skip-build  reuse the docker images and mods/out if they exist (Go
#                 binaries are always rebuilt; they take seconds)
#   --keep        leave the server, the gate and the emulator as they are at
#                 the end (default: remove the server, `ppemu reset`)
#
# Env: PP_E2E_OUT   logs, screenshots, work files (default test/e2e/out)
#      PP_BUILD_CA  CA bundle for TLS-intercepting proxies (docker builds)
#      PP_E2E_PORT  ppd on 127.0.0.1:PORT, the gate on the docker bridge
#                   gateway at PORT+1 (default 3180)
#
# Starts from `ppemu reset`: it wipes the emulator's notebooks. One line per
# step: PASS, FAIL or SKIP. Exit 0 only if every step passes.
# Commands for the device are single-quoted on purpose: they expand there.
# Steps run through "step_$name", which shellcheck can't follow (SC2317).
# shellcheck disable=SC2016,SC2317
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SELF=$REPO/test/e2e/run.sh
OUT=${PP_E2E_OUT:-$REPO/test/e2e/out}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
W=$OUT/work LOGS=$OUT/logs SHOTS=$OUT/shots
PPEMU=$REPO/emu/bin/ppemu
KEY=$REPO/emu/.ppemu/id_ed25519
UI=http://127.0.0.1:7777
PORT=${PP_E2E_PORT:-3180}
SERVER=pp-e2e-server VOLUME=pp-e2e-data IMAGE=pp-e2e-server:local
OS=3.27.2.2
EMAIL=cedar@example.invalid
DOCS=/home/root/.local/share/remarkable/xochitl
PP=/home/root/paper-pure
BLOCKED='device\.cloud\.remarkable\.com|device\.memfault\.com|enterprise\.cloud\.remarkable\.com|remarkable-software\.s3'
export PP_SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

# name timeout(s) hard: a failed hard step skips the rest
STEPS="build:3600:1 emulator:900:1 server:300:1 install:600:1 freeze:600:0 sync:1200:0
ota:2400:0 killswitch:1200:0 reboot:1200:0 disable:600:0 status:300:0"

# ---------------------------------------------------------------- helpers

log() { printf '%s %s\n' "$(date -u +%T)" "$*"; }
ok() { log "ok: $*"; }
die() { log "FAIL: $*"; exit 1; }
has() { case "$2" in *"$3"*) ok "$1: $3" ;; *) die "$1: no '$3' in: ${2:0:600}" ;; esac; }
hasnt() { case "$2" in *"$3"*) die "$1: found '$3' in: ${2:0:600}" ;; *) ok "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else die "$1: got '$2', want '$3'"; fi; }
jget() { python3 -I -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1:]: v = v[int(k)] if k.isdigit() else v.get(k, "")
print(v if isinstance(v, str) else json.dumps(v))' "$@"; }
dev() { # a command on the device, over SSH like the tablet's USB link
    # shellcheck disable=SC2086
    ssh -i "$KEY" -p 2222 $PP_SSH_OPTS -o ConnectTimeout=20 -o BatchMode=yes root@127.0.0.1 "$@"
}
until_ok() { # seconds description command...: poll every 3 s
    local end=$((SECONDS + $1)) what=$2; shift 2
    until "$@" >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$end" ] || die "timed out waiting for: $what"
        sleep 3
    done
    ok "$what"
}
tap() { log "tap $*: $("$PPEMU" tap "$@")"; }
shot() { "$PPEMU" screenshot "$SHOTS/$1.png" --scale "${2:-0.5}" >/dev/null && log "screenshot $SHOTS/$1.png"; }
px() { python3 -I "$REPO/test/e2e/pixels.py" "$@"; }
power3() { # triple-press: three presses 0.6 s apart, as a human would
    for _ in 1 2 3; do
        curl -fsS --noproxy '*' -X POST -H 'Content-Type: application/json' \
            -d '{"op":"key","key":"power","wait":false}' "$UI/api/gesture" >/dev/null
        sleep 0.6
    done
    log "triple-press sent"
}
agent() { dev "$PP/bin/pp-agent status"; }
xovi_maps() { # how many of xochitl's mappings are xovi.so ("none" if xochitl isn't running)
    dev 'p=$(systemctl show -P MainPID xochitl); if [ "${p:-0}" -gt 0 ]; then grep -c xovi.so /proc/$p/maps; else echo none; fi' 2>/dev/null || true
}
xovi_on() { local n; n=$(xovi_maps); [ -n "$n" ] && [ "$n" != none ] && [ "$n" -gt 0 ]; }
xovi_off() { [ "$(xovi_maps)" = 0 ]; }
live_is() { [ "$(agent | jget live)" = "$1" ]; }
emu_up() { # a step after a failed one may find the "tablet" rebooted (container stopped)
    if [ "$(docker inspect -f '{{.State.Running}}' pp-emu-tablet 2>/dev/null)" != true ]; then
        log "emulator not running; starting it"
        "$PPEMU" start
    fi
}
gate() { curl -fsS --noproxy '*' -H "CF-Access-Client-Id: $CFID" -H "CF-Access-Client-Secret: $CFSECRET" "$@"; }
web_token() {
    curl -fsS --noproxy '*' -X POST "$PPD/ui/api/login" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}"
}
dns_start() { # log every name the device's resolver is asked for, from now on
    dev 'mkdir -p /home/root/pp-e2e; systemctl stop pp-e2e-dns 2>/dev/null; systemd-run -q --unit=pp-e2e-dns -p StandardOutput=append:/home/root/pp-e2e/dns.log resolvectl monitor'
    ok "DNS monitor on the device (resolvectl monitor -> /home/root/pp-e2e/dns.log)"
}
dns_check() { # no blocked update host was looked up while the monitor ran
    local q
    q=$(dev 'cat /home/root/pp-e2e/dns.log 2>/dev/null' | grep -E '^→ Q:' || true)
    dev 'cat /home/root/pp-e2e/dns.log' > "$LOGS/dns-$1.log" 2>/dev/null || true
    log "device DNS queries so far: $(grep -c . <<<"$q" || true) ($(awk '{print $3}' <<<"$q" | sort -u | tr '\n' ' '))"
    if grep -qE "$BLOCKED" <<<"$q"; then die "an update host was looked up: $(grep -E "$BLOCKED" <<<"$q" | head -n 3)"; fi
    ok "no update host looked up (resolvectl monitor)"
}
device_install() { # the tablet's own installer, pointed at the emulator
    PP_PROXY_BIN=$W/bin/pp-proxy-arm64 "$REPO/device/install.sh" -p 2222 -i "$KEY" "$@" root@127.0.0.1
}
open_settings() { # from My files: side menu, Settings (General)
    tap 56 60
    tap 150 1812
}
updates_switch_off() { # Settings > General > Software, the Updates switch (device px 1068..1080, 460)
    local v
    v=$(px "$SHOTS/$1.png" 1068,460 1080,460 --scale 0.5)
    log "Updates switch pixels: $v (255 = off, 0 = on)"
    [ "$v" = "255 255" ]
}
build_hello() { # release-id dir: the hello app with this release id baked in
    local rcc
    rcc=$(command -v rcc || true)
    [ -n "$rcc" ] || [ ! -x /usr/lib/qt6/libexec/rcc ] || rcc=/usr/lib/qt6/libexec/rcc
    if [ -n "$rcc" ]; then
        RELEASE_ID=$1 RCC=$rcc "$REPO/apps/hello/build.sh" "$2"
    else   # no Qt on the host: the rung-1 image has rcc (apps/hello/test.sh builds it)
        mkdir -p "$2"
        docker run --rm -e RELEASE_ID="$1" -e RCC=/usr/lib/qt6/libexec/rcc -v "$REPO/apps/hello:/hello:ro" \
            -v "$2:/out" --entrypoint /hello/build.sh pp-mods-host:latest /out
    fi
}
release_tree() { # id [broken]: mods/out/release + hooks from source + hello built for this id
    local t=$W/tree-$1
    rm -rf "$t"
    cp -a "$REPO/mods/out/release" "$t"
    rm -rf "$t/hooks" "$t/checks"
    cp -r "$REPO/mods/release/hooks" "$REPO/mods/release/checks" "$t/"
    build_hello "$1" "$t/xovi/exthome/appload/paper-pure-hello" >/dev/null
    sed -i "2s/.*/release $1/" "$t/xovi/BUILDINFO"
    [ "${2:-}" != broken ] || rm "$t/xovi/extensions.d/appload.so"
    echo "$t"
}
publish() { # id: the feed files, through the gate, as CI would
    PP_SERVER=$GATE PP_PUBLISH_TOKEN=$PUB CF_ACCESS_CLIENT_ID=$CFID CF_ACCESS_CLIENT_SECRET=$CFSECRET \
        "$REPO/server/scripts/publish.sh" "$W/feed" "$1" --latest | sed 's/^/    /'
}
agent_update() { # what pp-agent.timer runs; blocks until the oneshot is done
    local t0=$SECONDS
    dev 'systemctl start pp-agent.service' || true
    log "pp-agent.service ran for $((SECONDS - t0)) s"
    agent > "$W/agent-status.json"
    log "agent: release=$(jget release < "$W/agent-status.json") live=$(jget live < "$W/agent-status.json") result=$(jget last_result < "$W/agent-status.json") error=$(jget last_error < "$W/agent-status.json" | cut -c1-200)"
}

# ---------------------------------------------------------------- steps

step_build() {
    (cd "$REPO/agent" && make -s build)
    ok "agent: pp-agent-arm64, ppsign"
    mkdir -p "$W/bin"
    (cd "$REPO/server" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$W/bin/pp-proxy-arm64" ./tablet-proxy \
        && CGO_ENABLED=0 go build -o "$W/bin/fakeaccess" ./test/fakeaccess)
    ok "pp-proxy (arm64), fakeaccess (the stand-in for Cloudflare Access)"
    if [ -z "$SKIP_BUILD" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        docker build -q ${PP_BUILD_CA:+--secret "id=build_ca,src=$PP_BUILD_CA"} -t "$IMAGE" "$REPO/server" >/dev/null
    fi
    ok "server image $IMAGE"
    if [ -z "$SKIP_BUILD" ] || [ ! -d "$REPO/mods/out/release" ]; then
        PP_BUILD_CA=${PP_BUILD_CA:-} "$REPO/mods/build.sh"
    fi
    [ -f "$REPO/mods/out/release/xovi/extensions.d/appload.so" ] || die "mods/out/release has no appload.so"
    ok "mods/out/release ($(sed -n 2p "$REPO/mods/out/release/xovi/BUILDINFO"))"
    if [ -z "$SKIP_BUILD" ] || ! docker image inspect "pp-emu-tatsu:$OS" >/dev/null 2>&1; then
        "$PPEMU" setup
    fi
    ok "emulator image pp-emu-tatsu:$OS"
    make -s -C "$REPO/tools/wishes" venv
    ok "tools/wishes venv"
    build_hello probe "$W/hello-probe" >/dev/null
    ok "hello builds (rcc)"
}

step_emulator() {
    "$PPEMU" reset
    "$PPEMU" start
    "$PPEMU" skip-setup
    shot emulator-myfiles 0.25
    has "systemd" "$(dev 'systemctl is-system-running' || true)" "ing"   # running or degraded (swupdate fails here)
    eq "OS" "$(dev '. /etc/os-release; echo $IMG_VERSION')" "$OS"
    eq "Wi-Fi as xochitl sees it" "$(dev 'systemctl is-active wpa_supplicant rmemu-network1 | tr "\n" " "')" "active active "
    has "networkd OnlineState" "$(dev 'busctl get-property org.freedesktop.network1 /org/freedesktop/network1 org.freedesktop.network1.Manager OnlineState')" online
}

step_server() {
    local gw
    gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
    {
        echo "JWT=$(openssl rand -base64 48 | tr -d '\n')"
        echo "PUB=$(openssl rand -hex 24)"
        echo "CFID=e2e-tablet.access"
        echo "CFSECRET=$(openssl rand -hex 32)"
        echo "PW=$(openssl rand -hex 12)"
        echo "PPD=http://127.0.0.1:$PORT"
        echo "GATE=http://$gw:$((PORT + 1))"
    } > "$W/env"
    chmod 600 "$W/env"
    # shellcheck disable=SC1091
    . "$W/env"
    docker rm -f "$SERVER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    docker run -d --name "$SERVER" -p "127.0.0.1:$PORT:3080" -v "$VOLUME:/data" -e JWT_SECRET_KEY="$JWT" \
        -e PP_PUBLISH_TOKEN="$PUB" -e RM_HTTPS_COOKIE=false -e TUNNEL_TOKEN= "$IMAGE" >/dev/null
    until_ok 60 "ppd up on 127.0.0.1:$PORT" curl -fsS --noproxy '*' "$PPD/pp/healthz"
    docker exec "$SERVER" rmfakecloud-cli setuser -u "$EMAIL" -p "$PW" -a -s 2>&1 | tail -n 1
    docker restart -t 10 "$SERVER" >/dev/null   # rmfakecloud reads users at start
    until_ok 60 "ppd up again, user $EMAIL" curl -fsS --noproxy '*' "$PPD/pp/healthz"
    [ -n "$(web_token)" ] && ok "web login"
    if [ -f "$W/fakeaccess.pid" ]; then kill "$(cat "$W/fakeaccess.pid")" 2>/dev/null || true; fi
    setsid nohup "$W/bin/fakeaccess" -listen "${GATE#http://}" -upstream "$PPD" -id "$CFID" -secret "$CFSECRET" \
        > "$LOGS/fakeaccess.log" 2>&1 < /dev/null &
    echo $! > "$W/fakeaccess.pid"
    until_ok 20 "gate (fake Cloudflare Access) on $GATE" curl -s --noproxy '*' -o /dev/null "$GATE/"
    eq "gate, no token" "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "$GATE/pp/healthz")" 403
    eq "gate, tablet token" "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H "CF-Access-Client-Id: $CFID" -H "CF-Access-Client-Secret: $CFSECRET" "$GATE/pp/healthz")" 200
    has "the device reaches the gate (and is refused without the token)" "$(dev "wget -q -O /dev/null $GATE/pp/healthz 2>&1" || true)" 403
}

step_install() {
    rm -rf "$W/keys" "$W/feed"
    "$REPO/agent/out/ppsign" keygen -out "$W/keys" >/dev/null
    cat > "$W/agent.json" <<EOF
{
  "feed_url": "$GATE/pp/releases/tatsu/",
  "status_url": "$GATE/pp/status",
  "headers": {"CF-Access-Client-Id": "$CFID", "CF-Access-Client-Secret": "$CFSECRET"}
}
EOF
    device_install --key "$KEY.pub" --agent --release-pub "$W/keys/release.pub.pem" --agent-json "$W/agent.json" --proxy \
        > "$LOGS/device-install.log" 2>&1 || { tail -n 30 "$LOGS/device-install.log"; die "device/install.sh"; }
    grep -E '^(FAIL|CHANGE)' "$LOGS/device-install.log" | sed 's/^/    /' || true
    has "device/install.sh --agent --proxy" "$(cat "$LOGS/device-install.log")" "pp-device: all checks passed"
    has "SSH after install" "$(cat "$LOGS/device-install.log")" "PASS    fresh SSH connection"
    eq "units" "$(dev 'systemctl is-active pp-proxy pp-agent-tripletap pp-agent.timer | tr "\n" " "')" "active active active "
    has "pp-proxy check (through the gate)" "$(dev "$PP/bin/pp-proxy check" 2>&1)" "200"
}

step_freeze() {
    device_install --verify > "$LOGS/verify-1.log" 2>&1 || { grep FAIL "$LOGS/verify-1.log"; die "device/install.sh --verify"; }
    local v
    v=$(cat "$LOGS/verify-1.log")
    for u in update-engine.service swupdate.service swupdate.socket memfaultd.service; do has "verify" "$v" "PASS    masked: $u"; done
    has "verify" "$v" "PASS    setting: Updates switch is off for good"
    for n in device.cloud.remarkable.com device.memfault.com enterprise.cloud.remarkable.com remarkable-software.s3.us-east-2.amazonaws.com; do
        has "verify" "$v" ": $n"
    done
    hasnt "verify" "$v" "FAIL"
    eq "update-engine never started this boot" "$(dev 'systemctl show -P ActiveEnterTimestampMonotonic update-engine.service')" 0
    # Settings > General > Software (unpaired layout), then try to turn updates on.
    open_settings
    tap 880 568
    shot freeze-software
    if updates_switch_off freeze-software; then ok "Settings > Software: Updates off"; else die "Updates switch is not off"; fi
    local since
    since=$(date -u '+%Y-%m-%d %H:%M:%S')
    tap 1096 460
    sleep 5
    shot freeze-software-tapped
    has "switching Updates on fails" "$(dev "journalctl --since '$since' -u xochitl --no-pager")" "Error when enabling update engine"
    eq "update-engine after the tap" "$(dev 'echo $(systemctl is-enabled update-engine) $(systemctl is-active update-engine)' || true)" "masked inactive"
    tap 56 56
    tap 56 56
    shot freeze-back 0.25
    hasnt "journal: no update host named" "$(dev 'journalctl -b --no-pager' | grep -E "$BLOCKED" || true)" "remarkable"
    dns_start
}

step_sync() {
    local token code
    token=$(web_token)
    # Pair the stock UI with our server: Settings > General > Account > Pair,
    # the one-time code from rmfakecloud's web UI, typed on the keyboard.
    open_settings
    tap 880 284
    tap 1082 276
    shot sync-pair-page
    code=$(curl -fsS --noproxy '*' -H "Authorization: Bearer $token" "$PPD/ui/api/newcode" | tr -d '"')
    [[ $code =~ ^[a-z]{8}$ ]] || die "pairing code '$code' is not 8 letters"
    log "pairing code $code"
    local r1=qwertyuiop r2=asdfghjkl r3=zxcvbnm c i p
    for ((i = 0; i < ${#code}; i++)); do   # the on-screen keyboard, one key per letter
        c=${code:i:1}
        if [[ $r1 == *$c* ]]; then p=${r1%%"$c"*}; tap $((138 + ${#p} * 125)) 1412
        elif [[ $r2 == *$c* ]]; then p=${r2%%"$c"*}; tap $((200 + ${#p} * 125)) 1536
        else p=${r3%%"$c"*}; tap $((326 + ${#p} * 125)) 1660; fi
    done
    until_ok 90 "paired: the device has a device token" dev 'grep -q "^DeviceToken=." /home/root/.config/remarkable/xochitl.conf'
    shot sync-paired
    has "rmfakecloud took the code" "$(docker logs "$SERVER" 2>&1)" "Got code $code"
    until_ok 120 "first sync through pp-proxy (GET /sync/v4/root)" dev 'journalctl -u pp-proxy --no-pager | grep -q "sync/v4/root -> 200"'
    tap 56 56
    tap 56 56
    # Write in a new notebook, close it, and find the page on the server.
    tap 700 1716
    tap 644 1324
    tap 1326 56
    tap 1216 504   # the first-visit tooltip
    log "draw: $("$PPEMU" draw 650,1500 800,1300 950,1550 1100,1300 1250,1500)"
    log "draw: $("$PPEMU" draw 700,1700 1200,1700)"
    shot sync-notebook
    tap 1348 56
    local id page sha
    id=$(dev "grep -l '\"visibleName\": \"Notebook\"' $DOCS/*.metadata | head -n 1" | xargs -r basename | sed 's/\.metadata$//')
    [ -n "$id" ] || die "no notebook on the device"
    page=$(dev "ls $DOCS/$id/*.rm" | head -n 1)
    sha=$(dev "sha256sum $page" | cut -d' ' -f1)
    log "notebook $id, page $(basename "$page"), sha256 $sha"
    sync_has() { docker exec "$SERVER" test -f "/data/rmfakecloud/users/$EMAIL/sync/$1"; }
    until_ok 180 "the page's exact bytes are in rmfakecloud (blob $sha)" sync_has "$sha"
    rm -rf "$W/rmfc" "$W/inbox"
    docker cp "$SERVER:/data/rmfakecloud" "$W/rmfc" >/dev/null
    "$REPO/tools/wishes/.venv/bin/python" "$REPO/tools/wishes/wishes.py" scan --rmfakecloud "$W/rmfc" --inbox "$W/inbox" --notebook Notebook
    local png
    png=$(find "$W/inbox" -name page.png | head -n 1)
    [ -n "$png" ] || die "tools/wishes found no page"
    cp "$png" "$SHOTS/sync-rendered-from-server.png"
    eq "rendered from the server copy: drawn points" "$(px "$png" 800,1300 950,1550 1100,1300 950,1700 --radius 4)" "0 0 0 0"
    eq "rendered from the server copy: blank paper" "$(px "$png" 300,300 300,1500 1300,300)" "255 255 255"
    # The other way: a document uploaded on the server shows up on the device.
    printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$W/e2e-from-server.pdf"
    has "upload in the web UI" "$(curl -fsS --noproxy '*' -H "Authorization: Bearer $token" -F "file=@$W/e2e-from-server.pdf" "$PPD/ui/api/documents/upload")" e2e-from-server
    until_ok 120 "the server's document is on the device" dev "grep -q e2e-from-server $DOCS/*.metadata"
    "$PPEMU" wait --idle 3000 --timeout 30000 >/dev/null || true
    shot sync-myfiles
    hasnt "pp-proxy refused nothing" "$(dev 'journalctl -u pp-proxy --no-pager' | grep -E ' -> [45][0-9][0-9] ' || true)" " -> "
}

step_ota() {
    local stamp good bad forged tampered wrongos t
    stamp=$(date -u +%m%d%H%M)
    good=e2e-$stamp-good bad=e2e-$stamp-broken forged=e2e-$stamp-forged tampered=e2e-$stamp-tampered wrongos=e2e-$stamp-wrongos
    echo "$good" > "$W/good-release"
    mkdir -p "$W/feed"
    pack() { "$REPO/agent/out/ppsign" pack -key "$1" -dir "$2" -id "$3" -os "$4" -expect-mapped xovi.so -expect-mapped appload.so -out "$W/feed" -latest >/dev/null; }

    # 1. A good release from mods/ + apps/hello, signed with the key the device trusts.
    t=$(release_tree "$good")
    pack "$W/keys/release.key.pem" "$t" "$good" "$OS"
    publish "$good"
    agent_update
    eq "installed" "$(jget release < "$W/agent-status.json")" "$good"
    eq "live" "$(jget live < "$W/agent-status.json")" "$good"
    has "result" "$(jget last_result < "$W/agent-status.json")" "installed"
    has "xovi status" "$(dev /home/root/xovi/paper-pure/status)" "mapped appload.so"
    local smoke
    smoke=$("$REPO/mods/emu-smoke.sh" "$SHOTS/ota-hello" 2>&1) || { echo "$smoke"; die "mods/emu-smoke.sh"; }
    has "hello shows the new release" "$smoke" "release $good"

    # 2. A broken release (no appload.so): installs, fails its health check, rolls back.
    t=$(release_tree "$bad" broken)
    pack "$W/keys/release.key.pem" "$t" "$bad" "$OS"
    publish "$bad"
    agent_update
    eq "after the broken release, current" "$(jget release < "$W/agent-status.json")" "$good"
    has "result" "$(jget last_result < "$W/agent-status.json")" "rolled back"
    has "failed list" "$(jget failed < "$W/agent-status.json")" "$bad"
    has "agent log" "$(dev "cat $PP/state/agent.log")" "has not loaded \"appload.so\""
    eq "live again" "$(jget live < "$W/agent-status.json")" "$good"
    until_ok 60 "xovi back on with $good" xovi_on

    # 3. Signed with a key the device doesn't trust: refused, nothing downloaded.
    "$REPO/agent/out/ppsign" keygen -out "$W/keys-forged" >/dev/null
    pack "$W/keys-forged/release.key.pem" "$(release_tree "$forged")" "$forged" "$OS"
    publish "$forged"
    agent_update
    eq "forged: current" "$(jget release < "$W/agent-status.json")" "$good"
    has "forged: refused" "$(jget last_error < "$W/agent-status.json")" "signature"
    eq "forged: not downloaded" "$(dev "ls $PP/releases $PP/downloads 2>/dev/null | grep -c $forged" || true)" 0

    # 4. Tampered after signing (one byte of the tarball flipped, same size): refused.
    # (Bytes appended after the signed size are never read: the agent stops at "size".)
    pack "$W/keys/release.key.pem" "$(release_tree "$tampered")" "$tampered" "$OS"
    python3 -I -c 'import sys; b = bytearray(open(sys.argv[1], "rb").read()); b[len(b) // 2] ^= 0xff; open(sys.argv[1], "wb").write(b)' "$W/feed/$tampered.tar.gz"
    publish "$tampered"
    agent_update
    eq "tampered: current" "$(jget release < "$W/agent-status.json")" "$good"
    has "tampered: refused" "$(jget last_error < "$W/agent-status.json")" "sha256"
    eq "tampered: not unpacked" "$(dev "ls $PP/releases | grep -c $tampered" || true)" 0

    # 5. Signed, but for another OS version: refused.
    pack "$W/keys/release.key.pem" "$(release_tree "$wrongos")" "$wrongos" 3.27.3.0
    publish "$wrongos"
    agent_update
    eq "wrong OS: current" "$(jget release < "$W/agent-status.json")" "$good"
    has "wrong OS: refused" "$(jget last_error < "$W/agent-status.json")" "3.27.3.0"
    eq "mods still live after the refusals" "$(jget live < "$W/agent-status.json")" "$good"
}

step_killswitch() {
    emu_up
    local good
    good=$(cat "$W/good-release")
    live_is "$good" || die "mods are not live ($good) before the test"
    local since
    since=$(date -u '+%Y-%m-%d %H:%M:%S')
    power3
    until_ok 240 "triple-press: mods off (live marker gone)" live_is ""
    until_ok 120 "triple-press: xochitl runs stock" xovi_off
    has "tripletap log" "$(dev "journalctl -u pp-agent-tripletap --since '$since' --no-pager")" "3 presses"
    "$PPEMU" wait --idle 3000 --timeout 60000 >/dev/null || true
    shot killswitch-off 0.25
    power3
    until_ok 400 "triple-press again: mods on ($good, health-checked)" live_is "$good"
    until_ok 60 "xochitl has xovi again" xovi_on
    has "agent result" "$(agent | jget last_result)" "$good"
    "$PPEMU" wait --idle 3000 --timeout 60000 >/dev/null || true
    shot killswitch-on 0.25
}

step_reboot() {
    emu_up
    local good
    good=$(cat "$W/good-release")
    xovi_on || log "note: mods were not on before the reboot"
    dns_check before-reboot
    "$PPEMU" reboot
    until_ok 300 "pp-agent-boot ran (after rm-sanity)" dev 'journalctl -b -u pp-agent-boot --no-pager | grep -q Finished'
    has "boot is stock by default" "$(dev "journalctl -b -u pp-agent-boot --no-pager")" "activate_on_boot is off"
    if xovi_off; then ok "xochitl runs stock after the reboot"; else die "xovi is loaded after a reboot ($(xovi_maps))"; fi
    eq "still installed, not live" "$(agent | jget release) $(agent | jget live)" "$good "
    device_install --verify > "$LOGS/verify-2.log" 2>&1 || { grep FAIL "$LOGS/verify-2.log"; die "--verify after reboot"; }
    ok "freeze and units survive the reboot (--verify all PASS)"
    open_settings
    tap 880 444   # Software, paired layout
    shot reboot-software
    if updates_switch_off reboot-software; then ok "Settings > Software: Updates off after the reboot"; else die "Updates switch is on after the reboot"; fi
    tap 56 56
    tap 56 56
    eq "pp-proxy after the reboot" "$(dev 'systemctl is-active pp-proxy')" active
    local token
    token=$(web_token)
    printf '%%PDF-1.4\n%%%%EOF\n' > "$W/e2e-after-reboot.pdf"
    curl -fsS --noproxy '*' -H "Authorization: Bearer $token" -F "file=@$W/e2e-after-reboot.pdf" "$PPD/ui/api/documents/upload" >/dev/null
    until_ok 180 "sync after the reboot: a new server document reaches the device" dev "grep -q e2e-after-reboot $DOCS/*.metadata"
    shot reboot-myfiles 0.25
    dns_start
}

step_disable() {
    emu_up
    dev "touch $PP/disable"
    live_is "" || die "mods should be off before this step"
    local since
    since=$(date -u '+%Y-%m-%d %H:%M:%S')
    power3
    sleep 20
    has "triple-press with the disable file" "$(dev "journalctl -u pp-agent-tripletap --since '$since' --no-pager")" "3 presses"
    if live_is ""; then ok "mods stay off (the file wins)"; else die "mods came on despite $PP/disable"; fi
    if xovi_off; then ok "xochitl stock"; else die "xovi loaded despite $PP/disable"; fi
    dev 'systemctl start pp-agent.service' || true
    eq "pp-agent.service skipped" "$(dev 'systemctl show -P ConditionResult pp-agent.service')" no
    eq "status says disabled" "$(agent | jget disabled)" true
    dev "rm $PP/disable"
    eq "file removed" "$(agent | jget disabled)" false
    "$PPEMU" wait --idle 3000 --timeout 60000 >/dev/null || true
}

step_status() {
    local good s
    good=$(cat "$W/good-release")
    eq "status without the token" "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "$GATE/pp/status/tatsu")" 403
    s=$(gate "$GATE/pp/status/tatsu?n=100")
    echo "$s" > "$LOGS/status-history.json"
    log "reports kept: $(python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$s")"
    eq "latest report: release" "$(jget 0 release <<<"$s")" "$good"
    eq "latest report: os" "$(jget 0 os_version <<<"$s")" "$OS"
    has "latest report: log tail" "$(jget 0 log_tail <<<"$s")" "result:"
    local results
    results=$(python3 -I -c 'import json,sys
for r in json.load(sys.stdin): print(r.get("last_result", ""), "|", r.get("last_error", "")[:160])' <<<"$s")
    echo "$results" > "$LOGS/status-results.txt"
    has "a report says installed" "$results" "installed $good"
    has "a report says rolled back" "$results" "rolled back"
    has "a report says forged" "$results" "signature"
    has "a report says tampered" "$results" "sha256"
    has "a report says wrong OS" "$results" "3.27.3.0"
    has "ppd log" "$(docker logs "$SERVER" 2>&1)" "status tatsu: os=$OS release=\"$good\""
    dns_check end
}

cleanup() {
    if [ -f "$W/fakeaccess.pid" ]; then kill "$(cat "$W/fakeaccess.pid")" 2>/dev/null || true; rm -f "$W/fakeaccess.pid"; fi
    docker rm -f "$SERVER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    "$PPEMU" reset >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- main

if [ "${1:-}" = --step ]; then   # one step, run by the loop below under timeout(1)
    SKIP_BUILD=${PP_E2E_SKIP_BUILD:-}
    mkdir -p "$W" "$LOGS" "$SHOTS"
    # shellcheck disable=SC1091
    [ ! -f "$W/env" ] || . "$W/env"
    "step_$2"
    exit 0
fi

SKIP_BUILD="" KEEP=""
for a in "$@"; do
    case $a in
    --skip-build) SKIP_BUILD=1 ;;
    --keep) KEEP=1 ;;
    -h | --help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $a (see --help)" >&2; exit 2 ;;
    esac
done
rm -rf "$LOGS" "$SHOTS"
mkdir -p "$W" "$LOGS" "$SHOTS"
export PP_E2E_SKIP_BUILD=$SKIP_BUILD PP_E2E_OUT=$OUT
echo "e2e: logs and screenshots in $OUT"
failed=0 skip=""
for s in $STEPS; do
    IFS=: read -r name limit hard <<<"$s"
    if [ -n "$skip" ]; then printf 'SKIP  %-10s (%s failed)\n' "$name" "$skip"; continue; fi
    t0=$SECONDS
    if timeout -k 30 "$limit" "$SELF" --step "$name" > "$LOGS/$name.log" 2>&1; then
        printf 'PASS  %-10s %4ds\n' "$name" $((SECONDS - t0))
    else
        rc=$?
        why=$(grep -E 'FAIL' "$LOGS/$name.log" | tail -n 1 | cut -c1-200)
        [ "$rc" != 124 ] || why="timed out after ${limit}s"
        printf 'FAIL  %-10s %4ds  %s  (log: %s)\n' "$name" $((SECONDS - t0)) "${why:-exit $rc}" "$LOGS/$name.log"
        failed=$((failed + 1))
        [ "$hard" = 0 ] || skip=$name
    fi
done
docker logs "$SERVER" > "$LOGS/server.log" 2>&1 || true
docker logs pp-emu-tablet > "$LOGS/emulator-console.log" 2>&1 || true
if [ -z "$KEEP" ]; then cleanup; echo "e2e: server removed, emulator reset (--keep to leave them)"; fi
if [ "$failed" = 0 ] && [ -z "$skip" ]; then echo "e2e: all steps passed"; exit 0; fi
echo "e2e: $failed step(s) failed"
exit 1
