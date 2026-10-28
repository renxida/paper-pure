# syntax=docker/dockerfile:1
# pp-server: the one container. rmfakecloud (sync), ppd (release feed,
# status intake, front door, wish pages and logs for Claude), cloudflared
# (the only way in), restic (nightly off-host backup) and the wish scanner
# (every 15 minutes). See README.md.
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
FROM cloudflare/cloudflared:2026.10.3@sha256:faa8e0a1475f137c910be6025f43c8e4092fdd35461b31e19fd1390657a1ff39 AS cloudflared

# The official Python image is Debian trixie-slim plus Python (about 45 MB),
# for the wish scanner (wishes/wishes.py). Its two libraries add about 20 MB.
FROM python:3.13.17-slim-trixie@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962
# No apt: the base already has the CA bundle, tzdata, setpriv (util-linux)
# and bash. The entrypoint is PID 1 and handles TERM.
RUN useradd --system --uid 10001 --home-dir /data --no-create-home --shell /usr/sbin/nologin pp
# Wheels only, each checked against the sha256 in requirements.txt.
COPY wishes/requirements.txt /tmp/wishes-requirements.txt
RUN --mount=type=secret,id=build_ca \
    if [ -f /run/secrets/build_ca ]; then export PIP_CERT=/run/secrets/build_ca; fi; \
    pip install --no-cache-dir --disable-pip-version-check --root-user-action=ignore \
      --require-hashes --only-binary=:all: -r /tmp/wishes-requirements.txt \
    && rm /tmp/wishes-requirements.txt
COPY --from=build /out/rmfakecloud /out/ppd /usr/local/bin/
COPY --from=restic /usr/bin/restic /usr/local/bin/restic
COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh backup/backup.sh backup/restore.sh scripts/rmfakecloud-cli wishes/wishes.py /usr/local/bin/
ENV PP_DATA=/data \
    BACKUP_AT=03:17 \
    TZ=UTC
VOLUME /data
# No EXPOSE: in production nothing listens outside the container.
# ppd listens on :3080 inside it; cloudflared dials out to Cloudflare.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
