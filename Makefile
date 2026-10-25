# paper-pure: one command per rung, plus release. docs/ci.md says what runs where.
#
#   make rung1     host tests, no emulator: go vet + tests, pytest, shellcheck,
#                  actionlint, node --check, arm64 cross-builds, hello golden
#   make proofs    component proofs in arm64 containers: agent, server (with
#                  the backup drill), wishes, device test bed (slow under qemu)
#   make rung2     the full-OS emulator end to end: test/e2e/run.sh, with
#                  E2E_ARGS="--skip-build --keep" passed through
#   make loop      rung1, then proofs, then rung2; stops at the first failure.
#                  This is what CI gates a merge on.
#   make release   build mods + apps, sign with PP_SIGNING_KEY -> out/feed/
#   make publish   upload out/feed/ to PP_FEED_URL through Cloudflare Access
#
# Logs: out/logs/<target>/<step>.log. Each target ends with one line per step.
# Behind a TLS-intercepting proxy: PP_BUILD_CA=/path/to/ca.pem make ...
SHELL := /bin/bash
MAKEFLAGS += --no-print-directory
.DEFAULT_GOAL := help

OUT    := out
LOGS   := $(OUT)/logs
# The OS we are frozen on, and its firmware: one source, emu/bin/ppemu.
PP_OS   := $(shell sed -n "s/^const DEFAULT_VERSION = '\(.*\)';/\1/p" emu/bin/ppemu)
SWU     := remarkable-production-image-$(PP_OS)-tatsu-public.swu
SWU_SHA := $(shell sed -n "s/^ *'$(PP_OS)': '\([0-9a-f]\{64\}\)',.*/\1/p" emu/bin/ppemu)
MIRROR  := https://remarkable-software.s3.us-east-2.amazonaws.com/
ACTIONLINT := github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
ifeq ($(origin RELEASE_ID),undefined)
RELEASE_ID := $(shell date -u +%Y%m%d-%H%M%S)-$(shell git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)
endif

# Recipe prelude. step NAME CMD...: CMD's output goes to $L/NAME.log, the
# verdict to one PASS/FAIL line (plus the log's tail on failure); returns
# CMD's status. summary: all the lines again, then exit 1 if any failed.
STEP = L=$(LOGS)/$@; rm -rf "$$L"; mkdir -p "$$L"; : > "$$L/summary"; \
  step() { local n=$$1 t=$$SECONDS r=PASS; shift; "$$@" > "$$L/$$n.log" 2>&1 || r=FAIL; \
    printf '%s  %-18s %5ss  %s\n' "$$r" "$$n" "$$((SECONDS - t))" "$$L/$$n.log" | tee -a "$$L/summary"; \
    [ $$r = PASS ] || { tail -n 40 "$$L/$$n.log" | sed 's/^/      | /'; return 1; }; }; \
  summary() { local f; f=$$(grep -c '^FAIL' "$$L/summary" || true); echo; cat "$$L/summary"; \
    echo "== $@: $$(grep -c '^PASS' "$$L/summary" || true) passed, $$f failed (logs in $$L)"; [ "$$f" = 0 ]; }; \
  need() { local t m=; for t; do command -v "$$t" > /dev/null || m="$$m $$t"; done; \
    [ -z "$$m" ] || { echo "$@: missing tools:$$m (see docs/ci.md)" >&2; exit 1; }; }

.PHONY: help rung1 proofs rung2 loop release publish clean \
        shellcheck actionlint node-check build-arm64 firmware firmware-info rootfs pack

help:
	@sed -n '2,14s/^# \{0,1\}//p' Makefile

$(OUT)/.gitignore:
	@mkdir -p $(OUT) && echo '*' > $@

# ---------------------------------------------------------------- rung 1
rung1: | $(OUT)/.gitignore
	@$(STEP); need go python3 shellcheck docker node git; \
	step agent        $(MAKE) -C agent test; \
	step server       $(MAKE) -C server test; \
	step wishes       $(MAKE) -C tools/wishes test; \
	step build-arm64  $(MAKE) build-arm64; \
	step shellcheck   $(MAKE) shellcheck; \
	step actionlint   $(MAKE) actionlint; \
	step node-check   $(MAKE) node-check; \
	step hello-golden env PP_TEST_OUT="$$L" apps/hello/test.sh; \
	summary

# Every shell script in the repo (by shebang), tracked or new, not ignored.
shellcheck:
	@files=$$(git ls-files -co --exclude-standard | while read -r f; do \
	  [ -f "$$f" ] && head -n 1 "$$f" | grep -qE '^#!.*\b(ba)?sh\b' && echo "$$f"; done); \
	shellcheck $$files && echo "shellcheck: $$(wc -w <<< "$$files") scripts clean"

# The CI workflow itself. actionlint needs a newer Go than go.mod pins, so
# let Go fetch that toolchain for this one command.
actionlint:
	@GOTOOLCHAIN=auto go run $(ACTIONLINT) && echo "actionlint: .github/workflows clean"

node-check:
	@files="emu/bin/ppemu $$(git ls-files -co --exclude-standard '*.mjs' '*.js')"; \
	for f in $$files; do node --check "$$f" || exit 1; done; echo "node --check: $$(wc -w <<< "$$files") files ok"

build-arm64:
	$(MAKE) -C agent build
	$(MAKE) -C server tablet-proxy

# ---------------------------------------------------------------- proofs
proofs: | $(OUT)/.gitignore
	@$(STEP); need docker go python3 ssh ssh-keygen git curl; \
	step rootfs            $(MAKE) rootfs && { \
	step agent-integration env PP_IMAGE=pp-agent-tatsu-rootfs:$(PP_OS) $(MAKE) -C agent integration; \
	step server-proof      $(MAKE) -C server proof; \
	step wishes-proof      $(MAKE) -C tools/wishes proof; \
	step device-testbed    device/test/run.sh; }; \
	summary

# reMarkable's firmware, for local use only: never committed, never uploaded.
firmware:
	@f=emu/firmware/$(SWU); \
	[ -n "$(SWU_SHA)" ] || { echo "firmware: no pinned sha256 for $(PP_OS) in emu/bin/ppemu" >&2; exit 1; }; \
	if [ ! -f "$$f" ]; then mkdir -p emu/firmware; \
	  echo "firmware: fetching $(SWU) from reMarkable's mirror (subject to reMarkable's terms)"; \
	  curl -fsSL --retry 3 -o "$$f.part" "$(MIRROR)$(SWU)" || { rm -f "$$f.part"; echo "firmware: download failed" >&2; exit 1; }; \
	  mv "$$f.part" "$$f"; fi; \
	have=$$(openssl dgst -sha256 -r "$$f" | cut -d' ' -f1); \
	[ "$$have" = "$(SWU_SHA)" ] || { rm -f "$$f"; echo "firmware: $$f sha256 $$have, want $(SWU_SHA); removed" >&2; exit 1; }; \
	echo "firmware: $$f sha256 ok"

firmware-info:
	@echo "name=$(SWU)"; echo "sha256=$(SWU_SHA)"

# The stock rootfs as docker images. One import (it checks reMarkable's update
# signature), three names: the emulator, device and agent lanes each look for
# their own, and the content is the same file for file.
rootfs:
	@if ! docker image inspect pp-emu-rootfs:$(PP_OS) > /dev/null 2>&1; then \
	  $(MAKE) firmware && emu/tools/import-rootfs.sh emu/firmware/$(SWU) || exit 1; fi; \
	for t in pp-device-rootfs pp-agent-tatsu-rootfs; do docker image inspect $$t:$(PP_OS) > /dev/null 2>&1 || \
	  docker tag pp-emu-rootfs:$(PP_OS) $$t:$(PP_OS) || exit 1; done; \
	echo "rootfs: pp-emu-rootfs, pp-device-rootfs, pp-agent-tatsu-rootfs at $(PP_OS)"

# ---------------------------------------------------------------- rung 2
rung2: | $(OUT)/.gitignore
	@[ -x test/e2e/run.sh ] || { echo "rung2: test/e2e/run.sh is missing" >&2; exit 1; }; \
	mkdir -p $(LOGS); set -o pipefail; test/e2e/run.sh $(E2E_ARGS) 2>&1 | tee $(LOGS)/rung2.log

loop:
	@t=$$SECONDS; r=FAIL; \
	$(MAKE) rung1 && $(MAKE) proofs && $(MAKE) rung2 && r=PASS; \
	echo "== loop: $$r after $$((SECONDS - t))s (rung1, proofs, rung2; logs in $(LOGS))"; [ $$r = PASS ]

# ---------------------------------------------------------------- release
# PP_SIGNING_KEY: path to release.key.pem (ppsign keygen). Without it the
# release is built and packed with a throwaway key as a check, and nothing
# lands in out/feed/.
release: | $(OUT)/.gitignore
	@$(STEP); need docker go git openssl curl readelf; rm -rf $(OUT)/feed; \
	echo "release $(RELEASE_ID) for OS $(PP_OS)"; \
	{ step rootfs     $(MAKE) rootfs && \
	  step mods-build env RELEASE_ID=$(RELEASE_ID) mods/build.sh && \
	  step ppsign     $(MAKE) -C agent build && \
	  step pack       $(MAKE) pack ID=$(RELEASE_ID); }; \
	summary && if [ -f $(OUT)/feed/release-id ]; then \
	  echo "release: SIGNED $(RELEASE_ID) in $(OUT)/feed/ (next: make publish)"; \
	else echo "release: NOT SIGNED (no PP_SIGNING_KEY); built and pack-tested only"; fi

pack:
	@set -euo pipefail; id=$(ID); key=$${PP_SIGNING_KEY:-}; feed=$(OUT)/feed; \
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	if [ -z "$$key" ]; then echo "pack: no PP_SIGNING_KEY, using a throwaway key"; \
	  agent/out/ppsign keygen -out "$$tmp/k" > /dev/null; key=$$tmp/k/release.key.pem; feed=$$tmp/feed; fi; \
	openssl pkey -in "$$key" -pubout -out "$$tmp/pub.pem"; \
	agent/out/ppsign pack -key "$$key" -dir mods/out/release -id "$$id" -os $(PP_OS) \
	  -expect-mapped xovi.so -expect-mapped appload.so -notes "commit $$(git rev-parse HEAD)" -out "$$feed" -latest; \
	agent/out/ppsign verify -pub "$$tmp/pub.pem" -manifest "$$feed/latest.json"; \
	echo "$$id" > "$$feed/release-id"

# PP_FEED_URL is agent.json's feed_url: https://pp.<domain>/pp/releases/tatsu/.
# Also PP_PUBLISH_TOKEN, and PP_CF_ACCESS_CLIENT_ID/SECRET (the pp-ci token).
publish:
	@set -euo pipefail; feed=$(OUT)/feed; \
	[ -f "$$feed/release-id" ] || { echo "publish: no signed release in $$feed (make release with PP_SIGNING_KEY)" >&2; exit 1; }; \
	id=$$(cat "$$feed/release-id"); url=$${PP_FEED_URL:?publish: set PP_FEED_URL}; : "$${PP_PUBLISH_TOKEN:?publish: set PP_PUBLISH_TOKEN}"; \
	case $$url in http*://*/pp/releases/?*) ;; *) echo "publish: PP_FEED_URL should be https://pp.<domain>/pp/releases/<device>/" >&2; exit 1 ;; esac; \
	dev=$${url#*/pp/releases/}; \
	export PP_SERVER=$${url%%/pp/releases/*} PP_DEVICE=$${dev%%/*} \
	  CF_ACCESS_CLIENT_ID=$${PP_CF_ACCESS_CLIENT_ID:-} CF_ACCESS_CLIENT_SECRET=$${PP_CF_ACCESS_CLIENT_SECRET:-}; \
	server/scripts/publish.sh "$$feed" "$$id" --latest; \
	hdr=(); [ -z "$$CF_ACCESS_CLIENT_ID" ] || hdr=(-H "CF-Access-Client-Id: $$CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $$CF_ACCESS_CLIENT_SECRET"); \
	curl -fsS "$${hdr[@]}" "$${url%/}/latest.json" | cmp -s - "$$feed/latest.json" || \
	  { echo "publish: FAIL $${url%/}/latest.json is not what we signed (Access login page? see docs/ci.md)" >&2; exit 1; }; \
	echo "publish: PASS $$id is live at $${url%/}/latest.json"

clean:
	rm -rf $(OUT)
