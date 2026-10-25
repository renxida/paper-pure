# pp-server. `make test` is seconds; `make proof` is the whole local proof
# (build, run, agent, tablet path, backup drill, teardown), a few minutes.
# Behind a TLS-intercepting proxy: PP_BUILD_CA=/path/to/ca-bundle.crt make proof
.PHONY: test image proof tablet-proxy clean

test:
	go vet ./...
	go test -race -count=1 ./...
	shellcheck entrypoint.sh backup/*.sh scripts/publish.sh scripts/rmfakecloud-cli tablet-proxy/*.sh test/*.sh

CA_FLAG = --secret id=build_ca,src=$(PP_BUILD_CA)
image:
	docker build $(if $(PP_BUILD_CA),$(CA_FLAG)) -t pp-server:local .

proof:
	test/local-proof.sh

tablet-proxy:
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o out/pp-proxy-arm64 ./tablet-proxy

clean:
	rm -rf out
