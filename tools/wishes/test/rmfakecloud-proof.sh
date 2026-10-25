#!/bin/bash
# Real-rmfakecloud proof: start rmfakecloud from the server image, upload the
# test notebooks as .rmdoc through its web API (the same path as the web UI),
# then scan its DATADIR and check we find the same wishes, byte for byte, as
# scanning the xochitl folder directly. Tears everything down on exit.
#
#   tools/wishes/test/rmfakecloud-proof.sh     (needs docker, curl, the venv)
#   PP_SERVER_IMAGE=...  image with /usr/local/bin/rmfakecloud (default pp-server:local,
#                        built by `make -C server image`)
#   PORT=3094            127.0.0.1 port for rmfakecloud while the proof runs
#   HASH_SCHEMA_VERSION=3|4   rmfakecloud's root index schema (its default is 3)
set -euo pipefail
cd "$(dirname "$0")/.."
IMG=${PP_SERVER_IMAGE:-pp-server:local}
PORT=${PORT:-3094}
PY=${PYTHON:-.venv/bin/python}
NAME=pp-wishes-rmfc-$$
W=$(mktemp -d)
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
die() { echo "FAIL $1" >&2; exit 1; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) die "$1: wanted '$3' in: $2" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else die "$1: got '$2', want '$3'"; fi; }
cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # rmfakecloud ran as root in the container; remove its files from a container too
    docker run --rm -v "$W:/w" --entrypoint /bin/rm "$IMG" -rf /w/data >/dev/null 2>&1 || true
    rm -rf "$W"
}
trap cleanup EXIT

docker image inspect "$IMG" >/dev/null 2>&1 || die "no image $IMG (make -C server image)"
[ -x "$PY" ] || die "no $PY (make venv)"
mkdir -p "$W/data"
run() { docker run --rm -v "$W/data:/data" -e DATADIR=/data --entrypoint rmfakecloud "$IMG" "$@"; }

# 1. a user, created before the server starts (rmfakecloud reads users at start)
PW=$(head -c 12 /dev/urandom | base64 | tr -dc a-zA-Z0-9)
run setuser -u wishes@example.invalid -p "$PW" -a -s >/dev/null 2>&1
has "user created" "$(run listusers 2>&1)" wishes@example.invalid

# 2. rmfakecloud on 127.0.0.1:$PORT
docker run -d --name "$NAME" -v "$W/data:/data" -e DATADIR=/data -e PORT=3000 \
    -e JWT_SECRET_KEY="$(head -c 32 /dev/urandom | base64)" -e RM_HTTPS_COOKIE=false \
    -e HASH_SCHEMA_VERSION="${HASH_SCHEMA_VERSION:-3}" \
    -p "127.0.0.1:$PORT:3000" --entrypoint rmfakecloud "$IMG" >/dev/null
for _ in $(seq 60); do curl -fsS --noproxy '*' "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
has "rmfakecloud up" "$(curl -fsS --noproxy '*' "http://127.0.0.1:$PORT/health")" Working
TOKEN=$(curl -fsS --noproxy '*' -X POST "http://127.0.0.1:$PORT/ui/api/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"wishes@example.invalid\",\"password\":\"$PW\"}")
[ -n "$TOKEN" ] || die "web login: no token"
ok "web login"

# 3. upload each test notebook as an .rmdoc (a zip of <id>.metadata, <id>.content, <id>/<page>.rm)
for m in testdata/xochitl/*.metadata; do
    id=$(basename "$m" .metadata)
    "$PY" -I -c 'import sys, zipfile, pathlib
src, out, did = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
with zipfile.ZipFile(out, "w") as z:
    for p in [src / f"{did}.metadata", src / f"{did}.content", *sorted((src / did).glob("*.rm"))]:
        z.write(p, p.relative_to(src).as_posix())' testdata/xochitl "$W/$id.rmdoc" "$id"
    up=$(curl -fsS --noproxy '*' -H "Authorization: Bearer $TOKEN" -F "file=@$W/$id.rmdoc" "http://127.0.0.1:$PORT/ui/api/documents/upload")
    has "upload $id" "$up" "$id"
done
docs=$(curl -fsS --noproxy '*' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/ui/api/documents")
case "$docs" in *Wishes*Notebook*|*Notebook*Wishes*) ok "rmfakecloud lists Wishes and Notebook" ;; *) die "documents: $docs" ;; esac
docker stop -t 5 "$NAME" >/dev/null

# 4. scan rmfakecloud's data dir (read it as ourselves: copy it out first)
docker run --rm -v "$W:/w" --entrypoint /bin/cp "$IMG" -r /w/data /w/copy
docker run --rm -v "$W:/w" --entrypoint /bin/chown "$IMG" -R "$(id -u):$(id -g)" /w/copy
echo "     sync tree: $(find "$W/copy/users" -path '*/sync/*' -type f | wc -l) files, root schema $(head -n 1 "$W/copy/users/"*/sync/"$(cat "$W"/copy/users/*/sync/root)")"
"$PY" -I wishes.py scan --rmfakecloud "$W/copy" --inbox "$W/inbox-rmfc" > "$W/rmfc.out"
"$PY" -I wishes.py scan --xochitl testdata/xochitl --inbox "$W/inbox-x" > "$W/x.out"
eq "3 wishes from rmfakecloud" "$(wc -l < "$W/rmfc.out")" 3
keys() { for d in "$1"/2*; do "$PY" -I -c 'import json,sys; w=json.load(open(sys.argv[1])); print(w["key"], w["sha256"], w["page"], w["why"])' "$d/wish.json"; done | sort; }
a=$(keys "$W/inbox-rmfc"); b=$(keys "$W/inbox-x")
if [ "$a" = "$b" ]; then ok "same pages, same bytes as the xochitl folder"; else die "differ: $a vs $b"; fi
while read -r l; do echo "     $l"; done <<< "$a"
for d in "$W"/inbox-rmfc/2*; do
    "$PY" -I -c 'import sys; from PIL import Image; assert Image.open(sys.argv[1]).size == (1404, 1872)' "$d/page.png"
done
ok "PNGs render"
"$PY" -I wishes.py scan --rmfakecloud "$W/copy" --inbox "$W/inbox-rmfc" > "$W/again.out" 2>&1
has "second scan: nothing new" "$(cat "$W/again.out")" "0 new, 3 unchanged"
if [ -n "${KEEP:-}" ]; then cp -r "$W/inbox-rmfc" "$KEEP"; echo "     inbox kept in $KEEP"; fi
[ "$pass" = 10 ] || die "expected 10 checks, got $pass"
echo "PASS $pass"
