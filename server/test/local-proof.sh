#!/bin/bash
# The local proof: the real pp-server image on 127.0.0.1:3080, no tunnel,
# with a fake Cloudflare Access gate on 127.0.0.1:3091 in front of it.
#
#   server/test/local-proof.sh
#   PP_BUILD_CA=/root/.ccr/ca-bundle.crt server/test/local-proof.sh   # behind a TLS-intercepting proxy
#   PP_SKIP_BUILD=1 ...    reuse pp-server:local
#   PP_WORK=dir ...        keep the work files there
#
# It: builds and starts the image, creates a user, checks rmfakecloud,
# uploads a PDF, signs a release with a throwaway key (agent lane's ppsign),
# publishes it, lets the real pp-agent fetch, verify and install it through
# the gate, receives its status report, pairs a "tablet" through pp-proxy
# (and checks pp-proxy on the tatsu userland), then runs the backup drill:
# backup, wipe the data volume, restore, diff, use it. Everything is torn
# down at the end, pass or fail.
set -euo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)"       # server/
AGENT="$(dirname "$S")/agent"
W="${PP_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/pp-server-proof.XXXXXX")}"
P=pp-server-proof                           # compose project (container, volume prefix)
BASE=http://127.0.0.1:3080                  # ppd, as cloudflared would see it
GATE=http://127.0.0.1:3091                  # fake Cloudflare Access in front of ppd
PXPORT=3092                                 # pp-proxy (443 on the tablet)
OS=3.27.2.2
USER_EMAIL=cedar@example.org

PASS=0
step() { printf '\n== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); echo "  ok: $*"; }
die()  { echo "  FAIL: $*" >&2; echo "  workdir kept: $W" >&2; exit 1; }
eq()   { if [ "$2" = "$3" ]; then ok "$1 = $3"; else die "$1: got '$2', want '$3'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1 has: $3" ;; *) die "$1: missing '$3' in: ${2:0:400}"; esac; }
jget() { python3 -I -c 'import json,sys; v=json.load(sys.stdin); [v:=v[k] if not k.isdigit() else v[int(k)] for k in sys.argv[1:]]; print(json.dumps(v) if not isinstance(v,str) else v)' "$@"; }

export PP_TEST_JWT PP_TEST_PUBLISH PP_TEST_RESTIC
PP_TEST_JWT=$(openssl rand -base64 48 | tr -d '\n')
PP_TEST_PUBLISH=$(openssl rand -hex 24)
PP_TEST_RESTIC=$(openssl rand -hex 24)
CF_ID="proof-tablet.access"
CF_SECRET=$(openssl rand -hex 32)
PW=$(openssl rand -hex 12)
export PP_TEST_BACKUP_AT=03:17
compose() { docker compose -p "$P" -f "$S/compose.yaml" -f "$S/compose.local.yaml" "$@"; }
app() { compose exec -T app "$@"; }
PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT
wait_healthy() {
    for _ in $(seq 120); do
        if curl -fsS "$BASE/pp/healthz" >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    compose logs --tail 50 >&2
    die "ppd /pp/healthz never went green"
}
data_sums() { # checksums of everything a backup must bring back
    app sh -c 'cd /data && find rmfakecloud pp -type f ! -path "pp/backup/*" -print0 | sort -z | xargs -0 sha256sum'
}

mkdir -p "$W"/{bin,keys,feed,tree,proxy,tablet/paper-pure/keys,fake/net/wlan0}

# ---- 0. build -------------------------------------------------------------
step "0. build (image, ppsign, pp-agent, pp-proxy, fake Access gate) in $W"
if [ -z "${PP_SKIP_BUILD:-}" ]; then
    docker build -q ${PP_BUILD_CA:+--secret "id=build_ca,src=$PP_BUILD_CA"} -t pp-server:local "$S" >/dev/null
fi
docker image inspect pp-server:local >/dev/null && ok "image pp-server:local"
(cd "$AGENT" && CGO_ENABLED=0 go build -trimpath -o "$W/bin/ppsign" ./cmd/ppsign && CGO_ENABLED=0 go build -trimpath -o "$W/bin/pp-agent" ./cmd/pp-agent)
(cd "$S" && go build -o "$W/bin/pp-proxy" ./tablet-proxy && go build -o "$W/bin/fakeaccess" ./test/fakeaccess)
ok "tools built"

# ---- 1. up ----------------------------------------------------------------
step "1. start the stack (no tunnel), check the prod shape has no ports"
eq "published ports in compose.yaml alone" "$(docker compose -f "$S/compose.yaml" config --format json | jget services app | grep -c '"published"' || true)" 0
# The nightly backup, scheduled two minutes out so step 7 sees the loop fire.
PP_TEST_BACKUP_AT=$(date -u -d '+2 min' +%H:%M)
compose up -d --no-build --quiet-pull 2>&1 | tail -n 2
wait_healthy
eq "host ports" "$(docker port "$(compose ps -q app)" | tr '\n' ' ')" "3080/tcp -> 127.0.0.1:3080 "
H=$(curl -fsS "$BASE/pp/healthz")
eq "healthz ok" "$(jget ok <<<"$H")" true
has "healthz" "$(jget rmfakecloud <<<"$H")" "Working"
logs=$(compose logs app)
has "entrypoint log" "$logs" "TUNNEL_TOKEN not set, no tunnel"
# shellcheck disable=SC2016 # expands inside the container
eq "rmfakecloud and ppd run as" "$(app bash -c 'for p in /proc/[0-9]*; do case $(cat $p/comm 2>/dev/null) in rmfakecloud|ppd) stat -c %U $p ;; esac; done' | sort | uniq -c | tr -s ' ' | tr -d '\n')" " 2 pp"

# ---- 2. user + rmfakecloud ------------------------------------------------
step "2. create the user, log in, upload a PDF"
has "entrypoint log" "$(compose logs app)" "NO USERS"
app rmfakecloud-cli setuser -u "$USER_EMAIL" -p "$PW" -a -s 2>&1 | tail -n 1
has "listusers" "$(app rmfakecloud-cli listusers 2>&1)" "$USER_EMAIL"
compose restart -t 10 app >/dev/null 2>&1   # rmfakecloud reads users at start (see entrypoint)
wait_healthy
TOKEN=$(curl -fsS -X POST "$BASE/ui/api/login" -H 'Content-Type: application/json' -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$PW\"}")
[ -n "$TOKEN" ] && ok "UI login returns a token"
has "rmfakecloud /health through ppd" "$(curl -fsS "$BASE/health")" "Working"
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$W/proof-notes.pdf"
up=$(curl -fsS -H "Authorization: Bearer $TOKEN" -F "file=@$W/proof-notes.pdf" "$BASE/ui/api/documents/upload")
has "upload" "$up" "proof-notes"
DOCS=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/ui/api/documents")
has "document list" "$DOCS" "proof-notes"

# ---- 3. fake Access gate --------------------------------------------------
step "3. fake Cloudflare Access on $GATE (service token required)"
"$W/bin/fakeaccess" -listen 127.0.0.1:3091 -upstream "$BASE" -id "$CF_ID" -secret "$CF_SECRET" 2> "$W/fakeaccess.log" &
PIDS+=($!)
for _ in $(seq 40); do curl -s -o /dev/null "$GATE/" && break; sleep 0.25; done
eq "no token" "$(curl -s -o /dev/null -w '%{http_code}' "$GATE/pp/healthz")" 403
eq "tablet token" "$(curl -s -o /dev/null -w '%{http_code}' -H "CF-Access-Client-Id: $CF_ID" -H "CF-Access-Client-Secret: $CF_SECRET" "$GATE/pp/healthz")" 200

# ---- 4. release -----------------------------------------------------------
step "4. sign a release with a throwaway key and publish it"
"$W/bin/ppsign" keygen -out "$W/keys" >/dev/null
cp -a "$AGENT/example/release/." "$W/tree/"
"$W/bin/ppsign" pack -key "$W/keys/release.key.pem" -dir "$W/tree" -id proof1 -os "$OS" -out "$W/feed" -latest 2>/dev/null | sed 's/^/    /'
export PP_SERVER="$GATE" CF_ACCESS_CLIENT_ID="$CF_ID" CF_ACCESS_CLIENT_SECRET="$CF_SECRET"
eq "publish without the publish token" "$(curl -s -o /dev/null -w '%{http_code}' -T "$W/feed/latest.json" -H "CF-Access-Client-Id: $CF_ID" -H "CF-Access-Client-Secret: $CF_SECRET" "$GATE/pp/releases/tatsu/latest.json")" 403
PP_PUBLISH_TOKEN="$PP_TEST_PUBLISH" "$S/scripts/publish.sh" "$W/feed" proof1 --latest | sed 's/^/    /'
eq "served latest.json == signed bytes" "$(curl -fsS "$BASE/pp/releases/tatsu/latest.json" | sha256sum | cut -c1-64)" "$(sha256sum < "$W/feed/latest.json" | cut -c1-64)"
"$W/bin/ppsign" verify -pub "$W/keys/release.pub.pem" -manifest "$W/feed/proof1.json" | sed 's/^/    /'
eq "Range bytes=10- status" "$(curl -s -o "$W/range.part" -w '%{http_code}' -H 'Range: bytes=10-' "$BASE/pp/releases/tatsu/proof1.tar.gz")" 206
eq "Range bytes=10- body" "$(sha256sum < "$W/range.part" | cut -c1-64)" "$(tail -c +11 "$W/feed/proof1.tar.gz" | sha256sum | cut -c1-64)"

# ---- 5. agent -------------------------------------------------------------
step "5. the real pp-agent fetches, verifies, installs and reports through the gate"
T="$W/tablet/paper-pure"
cp "$W/keys/release.pub.pem" "$T/keys/release.pub.pem"
echo up > "$W/fake/net/wlan0/operstate"
printf 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\nwlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n' > "$W/fake/route"
echo 80 > "$W/fake/battery"; echo 0 > "$W/fake/charger"
printf 'IMG_VERSION="%s"\n' "$OS" > "$W/fake/os-release"
printf '#!/bin/sh\necho ActiveState=active\necho MainPID=1000\necho NRestarts=0\n' > "$W/fake/systemctl"; chmod +x "$W/fake/systemctl"
agentcfg() { # secret
    cat <<EOF
{
  "root": "$T",
  "feed_url": "$GATE/pp/releases/tatsu/",
  "status_url": "$GATE/pp/status",
  "headers": {"CF-Access-Client-Id": "$CF_ID", "CF-Access-Client-Secret": "$1"},
  "os_release": "$W/fake/os-release",
  "sys_class_net": "$W/fake/net",
  "proc_net_route": "$W/fake/route",
  "battery_capacity": "$W/fake/battery",
  "charger_online": "$W/fake/charger",
  "systemctl": "$W/fake/systemctl",
  "stable_seconds": 0
}
EOF
}
agentcfg wrong-secret > "$T/agent.json"
set +e; out=$("$W/bin/pp-agent" -config "$T/agent.json" update 2>&1); rc=$?; set -e
[ "$rc" != 0 ] && ok "with a revoked/wrong token the agent fails (rc=$rc)"
has "agent error" "$out" "403"
eq "nothing installed" "$(readlink "$T/current" || echo none)" none
agentcfg "$CF_SECRET" > "$T/agent.json"
chmod 600 "$T/agent.json"
"$W/bin/pp-agent" -config "$T/agent.json" update 2>&1 | tail -n 4 | sed 's/^/    | /'
eq "current" "$(readlink "$T/current")" releases/proof1
ST=$(curl -fsS "$BASE/pp/status/tatsu")
eq "server has the status: release" "$(jget release <<<"$ST")" proof1
eq "server has the status: os" "$(jget os_version <<<"$ST")" "$OS"
has "status log_tail" "$(jget log_tail <<<"$ST")" "proof1"
has "ppd log" "$(compose logs app)" 'status tatsu: os=3.27.2.2 release="proof1"'

# ---- 6. tablet sync path ----------------------------------------------------
step "6. stock sync path: pair and read the sync root through pp-proxy -> gate -> ppd -> rmfakecloud"
"$W/bin/pp-proxy" -dir "$W/proxy" gencert >/dev/null
"$W/bin/pp-proxy" -config "$T/agent.json" -dir "$W/proxy" -listen "127.0.0.1:$PXPORT" run 2> "$W/pp-proxy.log" &
PIDS+=($!)
tab() { # name path [curl args]: a request as xochitl/rm-sync makes it, trusting only the tablet CA
    local h=$1 p=$2; shift 2
    curl -fsS --noproxy "*" --resolve "$h:$PXPORT:127.0.0.1" --cacert "$W/proxy/ca.crt" "$@" "https://$h:$PXPORT$p"
}
for _ in $(seq 40); do tab local.appspot.com /health >/dev/null 2>&1 && break; sleep 0.25; done
has "discovery" "$(tab service-manager-production-dot-remarkable-production.appspot.com /discovery/v1/endpoints)" "local.appspot.com"
CODE=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/ui/api/newcode" | tr -d '"')
[ -n "$CODE" ] && ok "one-time pairing code from the web UI"
DEV=$(tab my.remarkable.com /token/json/2/device/new -X POST -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\",\"deviceDesc\":\"remarkable\",\"deviceID\":\"proof-tatsu\"}")
[ -n "$DEV" ] && ok "device token (pairing through the proxy)"
USR=$(tab my.remarkable.com /token/json/2/user/new -X POST -H "Authorization: Bearer $DEV")
[ -n "$USR" ] && ok "user token"
ROOT=$(tab internal.cloud.remarkable.com /sync/v3/root -H "Authorization: Bearer $USR")
RH=$(jget hash <<<"$ROOT")
[ -n "$RH" ] && ok "sync v3 root: generation $(jget generation <<<"$ROOT")"
DOCID=$(jget 0 ID <<<"$up")
has "root index lists the uploaded document" "$(tab internal.cloud.remarkable.com "/sync/v3/files/$RH" -H "Authorization: Bearer $USR")" "$DOCID"
eq "a name outside the cert" "$(curl -s --noproxy "*" -o /dev/null -w "%{http_code}" --resolve "evil.example.org:$PXPORT:127.0.0.1" --cacert "$W/proxy/ca.crt" "https://evil.example.org:$PXPORT/" || true)" 000
has "pp-proxy log" "$(cat "$W/pp-proxy.log")" "GET internal.cloud.remarkable.com/sync/v3/root -> 200"
if [ -z "${PP_SKIP_TATSU:-}" ]; then
    UPSTREAM="$GATE" CF_ID="$CF_ID" CF_SECRET="$CF_SECRET" PP_WORK="$W" "$S/tablet-proxy/test-tatsu.sh" | sed 's/^/    /'
    ok "pp-proxy on the tatsu userland (above)"
fi

# ---- 7. backup drill ----------------------------------------------------------
step "7. backup drill: the scheduled backup fires, then wipe, restore, diff, use"
has "entrypoint log" "$(compose logs app)" "backup: next run $(date -u +%F) $PP_TEST_BACKUP_AT:00 UTC"
for _ in $(seq 200); do curl -fsS "$BASE/pp/backup" 2>/dev/null | grep -q '"ok":true' && break; sleep 1; done
has "the scheduled run (log)" "$(compose logs app)" "backup: ok"
app backup.sh 2>&1 | tail -n 1 | sed 's/^/    | /'   # and a manual one, from a root shell
eq "repo files not owned by pp (root shell runs re-exec as pp)" "$(app find /backup/repo ! -user pp | wc -l | tr -d ' ')" 0
eq "snapshots" "$(app setpriv --reuid=pp --regid=pp --init-groups env RESTIC_CACHE_DIR=/tmp/restic-cache restic snapshots --json | jget 1 tags 0)" nightly
B=$(curl -fsS "$BASE/pp/backup")
eq "last backup ok" "$(jget ok <<<"$B")" true
SNAP=$(jget summary snapshot_id <<<"$B")
ok "snapshot ${SNAP:0:8}, $(jget summary total_files_processed <<<"$B") files"
eq "healthz carries the backup" "$(curl -fsS "$BASE/pp/healthz" | jget backup ok)" true
if docker run --rm -v "${P}_backup:/b:ro" --entrypoint grep pp-server:local -rlqa -e "$USER_EMAIL" -e proof-notes /b; then
    die "plaintext found in the restic repo"
fi
ok "repo is encrypted (no user email or file name in plaintext)"
data_sums > "$W/before.sums"
[ -s "$W/before.sums" ] && ok "$(wc -l < "$W/before.sums") files checksummed before"

compose rm -fs app >/dev/null 2>&1
docker volume rm "${P}_data" >/dev/null
ok "data volume deleted (the disaster)"
compose up -d --no-build 2>&1 | tail -n 1
wait_healthy
eq "fresh server has no users" "$(app rmfakecloud-cli listusers 2>&1 | grep -c "$USER_EMAIL" || true)" 0
eq "fresh server has no status" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/pp/status/tatsu")" 404

app restore.sh latest 2>&1 | grep -E '^restore:' | sed 's/^/    | /'
compose restart -t 10 app >/dev/null 2>&1
wait_healthy
has "entrypoint applied the restore" "$(compose logs app)" "applying staged restore"
data_sums > "$W/after.sums"
if diff -u "$W/before.sums" "$W/after.sums" > "$W/sums.diff"; then
    ok "all $(wc -l < "$W/after.sums") files identical after restore (sha256)"
else
    die "restore differs: $(head -n 20 "$W/sums.diff")"
fi
TOKEN2=$(curl -fsS -X POST "$BASE/ui/api/login" -H 'Content-Type: application/json' -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$PW\"}")
has "restored: login + documents" "$(curl -fsS -H "Authorization: Bearer $TOKEN2" "$BASE/ui/api/documents")" "proof-notes"
eq "restored: tablet status" "$(curl -fsS "$BASE/pp/status/tatsu" | jget release)" proof1
eq "restored: feed" "$(curl -fsS "$BASE/pp/releases/tatsu/latest.json" | sha256sum | cut -c1-64)" "$(sha256sum < "$W/feed/latest.json" | cut -c1-64)"
eq "restored: the paired tablet's token still syncs" "$(tab internal.cloud.remarkable.com /sync/v3/root -H "Authorization: Bearer $USR" | jget hash)" "$RH"
"$W/bin/pp-agent" -config "$T/agent.json" report >/dev/null 2>&1
eq "restored: agent reports again" "$(curl -fsS "$BASE/pp/status/tatsu?n=5" | jget 0 release)" proof1
eq "restored files owned by pp" "$(app find /data/rmfakecloud ! -user pp | wc -l | tr -d ' ')" 0

# ---- 8. down --------------------------------------------------------------
step "8. tear down"
cleanup
PIDS=()
eq "containers left" "$(docker ps -a --filter "name=^${P}" --filter name=pp-server-tatsu -q | wc -l | tr -d ' ')" 0
eq "volumes left" "$(docker volume ls -q --filter "name=^${P}_" | wc -l | tr -d ' ')" 0
echo
echo "PASS $PASS"
