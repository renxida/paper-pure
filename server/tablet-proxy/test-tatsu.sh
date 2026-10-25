#!/bin/bash
# pp-proxy on the tablet's own userland: the static arm64 binary in the
# 3.27.2.2 tatsu rootfs image (qemu), installing its CA with the tablet's own
# update-ca-certificates and checked with the tablet's own OpenSSL 3.2.6.
#
#   UPSTREAM=http://127.0.0.1:3091 CF_ID=.. CF_SECRET=.. tablet-proxy/test-tatsu.sh
#
# UPSTREAM must answer /health like rmfakecloud (test/local-proof.sh runs
# the server and a fake Cloudflare Access gate, then calls this). The image
# comes from agent/test/import-rootfs.sh and is never pushed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${PP_TATSU_IMAGE:-pp-agent-tatsu-rootfs:3.27.2.2}"
UPSTREAM="${UPSTREAM:-http://127.0.0.1:3091}"
PORT="${PP_PROXY_PORT:-3093}"   # the tablet uses 443; host networking here, so a free port
W="${PP_WORK:-$(mktemp -d)}/tatsu"
NAME="pp-server-tatsu-$$"
PASS=0
ok()  { PASS=$((PASS + 1)); echo "  ok: $*"; }
die() { echo "  FAIL: $*" >&2; exit 1; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
dx() { docker exec "$NAME" "$@"; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "SKIP: no $IMAGE (agent/test/import-rootfs.sh builds it)"; exit 0; }
rm -rf "$W"; mkdir -p "$W/home/paper-pure/bin" "$W/certs"
(cd "$HERE/.." && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$W/home/paper-pure/bin/pp-proxy" ./tablet-proxy)
(cd "$HERE/.." && PP_CERT_OUT="$W/certs" go test -count=1 -run TestOpenSSLAgrees ./tablet-proxy >/dev/null)
cat > "$W/home/paper-pure/agent.json" <<EOF
{"feed_url": "$UPSTREAM/pp/releases/tatsu/",
 "headers": {"CF-Access-Client-Id": "${CF_ID:?}", "CF-Access-Client-Secret": "${CF_SECRET:?}"}}
EOF

echo "== pp-proxy in $IMAGE (arm64, qemu)"
docker run -d --name "$NAME" --platform linux/arm64 --network host \
    -v "$W/home:/home/root" -v "$W/certs:/certs:ro" "$IMAGE" sleep 100000 >/dev/null
eq() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else die "$1: got '$2', want '$3'"; fi; }
eq "arch" "$(dx uname -m)" aarch64
P=/home/root/paper-pure/bin/pp-proxy

out=$(dx openssl version); case "$out" in "OpenSSL 3.2.6"*) ok "tablet $out" ;; *) die "openssl: $out" ;; esac
if out=$(dx openssl verify -CAfile /certs/ca.pem -verify_hostname my.remarkable.com /certs/good.pem 2>&1); then
    ok "tablet OpenSSL accepts the local cert"
else
    die "$out"
fi
if out=$(dx openssl verify -CAfile /certs/ca.pem -verify_hostname pp.example.org /certs/evil.pem 2>&1); then
    die "tablet OpenSSL accepted a cert outside the CA's name constraints: $out"
fi
case "$out" in *subtree*) ok "tablet OpenSSL enforces the name constraints ($(echo "$out" | grep -o 'permitted subtree violation' | head -n 1))" ;; *) die "$out" ;; esac

dx "$P" gencert >/dev/null
eq "files gencert wrote (no CA key)" "$(dx sh -c 'ls /home/root/paper-pure/proxy | tr "\n" " "')" "ca.crt cert.pem key.pem "
# What the device lane does on the real tablet (there, into the real rootfs
# under the /etc overlay): trust ca.crt with the tablet's own tool.
out=$(dx sh -c 'mkdir -p /usr/local/share/ca-certificates && cp /home/root/paper-pure/proxy/ca.crt /usr/local/share/ca-certificates/pp-proxy.crt && update-ca-certificates 2>&1')
case "$out" in *"1 added"*) ok "update-ca-certificates: 1 added" ;; *) die "update-ca-certificates: $out" ;; esac
dx sh -c "$P hosts >> /etc/hosts"
eq "cloud names in /etc/hosts" "$(dx grep -c '^127.0.0.1 .*\(remarkable\|appspot\)' /etc/hosts)" 13

dx sh -c "$P -listen 127.0.0.1:$PORT run > /tmp/proxy.log 2>&1 &"
for _ in $(seq 60); do dx sh -c "echo | openssl s_client -connect 127.0.0.1:$PORT >/dev/null 2>&1" && break; sleep 0.5; done

req() { # name: GET /health as stock sync would, verified against the system trust store
    dx sh -c "printf 'GET /health HTTP/1.1\r\nHost: $1\r\nConnection: close\r\n\r\n' | \
        openssl s_client -quiet -ign_eof -connect $1:$PORT -servername $1 -verify_hostname $1 \
        -verify_return_error -CAfile /etc/ssl/certs/ca-certificates.crt 2>&1"
}
for h in my.remarkable.com internal.cloud.remarkable.com local.appspot.com; do
    out=$(req "$h")
    case "$out" in *"Working"*) ok "$h resolves via /etc/hosts, TLS verifies with the system bundle, rmfakecloud answers: $(echo "$out" | grep -o 'Working[^\r]*' | head -n 1)" ;;
        *) die "$h: $out" ;; esac
done
if dx sh -c "echo | openssl s_client -connect 127.0.0.1:$PORT -servername pp.example.org -verify_hostname pp.example.org -verify_return_error -CAfile /etc/ssl/certs/ca-certificates.crt >/dev/null 2>&1"; then
    die "TLS verified for a name the proxy must not serve"
fi
ok "a foreign name fails TLS verification"
log=$(dx cat /tmp/proxy.log)
case "$log" in *"GET my.remarkable.com/health -> 200"*) ok "proxy log: GET my.remarkable.com/health -> 200" ;; *) die "proxy log: $log" ;; esac
echo "PASS $PASS"
