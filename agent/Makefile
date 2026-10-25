# paper-pure agent. Stdlib Go only; the tablet needs nothing installed.
VERSION ?= $(shell git describe --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X paper-pure/agent/internal/agent.Version=$(VERSION)
GOBUILD := CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)"

.PHONY: all build test integration check clean

all: build

build:
	GOOS=linux GOARCH=arm64 $(GOBUILD) -o out/pp-agent-arm64 ./cmd/pp-agent
	GOOS=linux GOARCH=arm64 $(GOBUILD) -o out/ppsign-arm64 ./cmd/ppsign
	$(GOBUILD) -o out/ppsign ./cmd/ppsign

test:
	go vet ./...
	go test -race -count=1 ./...

# arm64 binary in an arm64 container, fake /home, local feed server.
# PP_IMAGE=pp-agent-tatsu-rootfs:3.27.2.2 runs it on the real tatsu userland
# (make one with test/import-rootfs.sh).
integration: build
	test/integration.sh

check: test integration

clean:
	rm -rf out
