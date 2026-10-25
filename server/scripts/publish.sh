#!/bin/bash
# Publish one release from a local feed dir (made by `ppsign pack`) to the
# server: tarball first, latest.json last, so the tablet never sees a
# manifest whose tarball isn't there yet.
#
#   publish.sh FEED_DIR ID [--latest]
#
# Env: PP_SERVER (https://pp.example.org), PP_PUBLISH_TOKEN, PP_DEVICE
# (default tatsu), and through Cloudflare Access CF_ACCESS_CLIENT_ID /
# CF_ACCESS_CLIENT_SECRET (the CI service token).
set -euo pipefail
FEED="${1:?feed dir}" ID="${2:?release id}" LATEST="${3:-}"
: "${PP_SERVER:?}" "${PP_PUBLISH_TOKEN:?}"
BASE="${PP_SERVER%/}/pp/releases/${PP_DEVICE:-tatsu}"
hdr=(-H "Authorization: Bearer $PP_PUBLISH_TOKEN")
if [ -n "${CF_ACCESS_CLIENT_ID:-}" ]; then
    hdr+=(-H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET:?}")
fi
files=("$ID.tar.gz" "$ID.json" "$ID.json.sig")
if [ "$LATEST" = --latest ]; then files+=(latest.json.sig latest.json); fi
for f in "${files[@]}"; do
    [ -f "$FEED/$f" ] || { echo "publish: missing $FEED/$f" >&2; exit 1; }
    curl -fsS --retry 3 -T "$FEED/$f" "${hdr[@]}" "$BASE/$f"
    echo "publish: $f"
done
