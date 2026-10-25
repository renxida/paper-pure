# syntax=docker/dockerfile:1
# pp-server: the one container. rmfakecloud (sync), ppd (release feed,
# status intake, front door), cloudflared (the only way in) and restic
# (nightly off-host backup). See README.md.
#
# Every base image is pinned by digest and rmfakecloud by commit. Bump on
# purpose, in one commit, after the local proof passes (test/local-proof.sh).

# rmfakecloud master, 2026-10-19: v0.0.31 plus "return 412 instead of 500 on
# stale root generation in sync v3" (#506) and the Paper Pure docs (#447).
ARG RMFAKECLOUD_COMMIT=3c6de006bdc465bdc0aa14b4de8fac78b5096ee6

FROM node:22.23.4-trixie-slim@sha256:8eb619e402eaede1748a3c8173bffab391592812e85136452f781741c7242ddf AS ui
ARG RMFAKECLOUD_COMMIT
# BuildKit fetches the exact commit itself; no git in the image.
ADD --keep-git-dir=false https://github.com/ddvk/rmfakecloud.git#${RMFAKECLOUD_COMMIT} /src
WORKDIR /src/ui
# build_ca is optional and only for building behind a TLS-intercepting proxy
# (like the dev container): docker build --secret id=build_ca,src=bundle.crt
RUN --mount=type=secret,id=build_ca \
    if [ -f /run/secrets/build_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/build_ca; fi; \
    npm install -g pnpm@9.15.9 && pnpm install --frozen-lockfile && pnpm build

FROM golang:1.26.10-trixie@sha256:909771fef53e3dcb0950255f0c9a8b4728c3b841e61509c7b29b098de7ee02d4 AS build
ARG RMFAKECLOUD_COMMIT
COPY --from=ui /src /src
WORKDIR /src
RUN --mount=type=secret,id=build_ca \
    if [ -f /run/secrets/build_ca ]; then export SSL_CERT_FILE=/run/secrets/build_ca; fi; \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${RMFAKECLOUD_COMMIT}" \
      -o /out/rmfakecloud ./cmd/rmfakecloud
WORKDIR /pp
COPY go.mod ./
COPY ppd/ ./ppd/
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/ppd ./ppd

FROM restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510 AS restic
FROM cloudflare/cloudflared:2026.10.0@sha256:9b49eed8f62806d5d45ddf59ecefb5710429598ea6d3fcccd2af938f621b2b07 AS cloudflared

FROM debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /data --no-create-home --shell /usr/sbin/nologin pp
COPY --from=build /out/rmfakecloud /out/ppd /usr/local/bin/
COPY --from=restic /usr/bin/restic /usr/local/bin/restic
COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh backup/backup.sh backup/restore.sh scripts/rmfakecloud-cli /usr/local/bin/
ENV PP_DATA=/data \
    BACKUP_AT=03:17 \
    TZ=UTC
VOLUME /data
# No EXPOSE: in production nothing listens outside the container.
# ppd listens on :3080 inside it; cloudflared dials out to Cloudflare.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
