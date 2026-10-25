# tablet-proxy (`pp-proxy`)

How the tablet gets through Cloudflare Access. A static arm64 Go binary, stdlib only, about 6 MB. It lives next to `pp-agent` and is installed once, like the agent.

## The problem

Everything on the server sits behind Cloudflare Access. `pp-agent` is ours, so it just sends the tablet's service-token headers (`headers` in `agent.json`). Stock sync is not ours: `xochitl` and `rm-sync` talk to fixed reMarkable hostnames and can't add headers. We don't patch them (desiderata row 4: writing feel stays stock, and sync should work in stock mode too).

## The design

```
xochitl / rm-sync ──> my.remarkable.com:443 etc.
                      /etc/hosts: 127.0.0.1
                 ──> pp-proxy 127.0.0.1:443   TLS with a cert from a tablet-only CA
                 ──> https://pp.<domain>/...  + CF-Access-Client-Id / -Secret
                      Cloudflare Access ──> Tunnel ──> ppd ──> rmfakecloud
```

This is the same shape as rmfakecloud's own `rmfakecloud-proxy` (hosts file, local CA, local TLS proxy), with three changes:

1. **It adds the Access headers.** rmfakecloud-proxy can only do a client certificate.
2. **One credential, one file.** The server address and the token come from `agent.json` (`feed_url` gives `scheme://host`, `headers` gives the token). Rotating the token means editing one file and restarting two units.
3. **A tighter CA.** `pp-proxy gencert` makes the CA in memory, signs one cert for exactly the 13 cloud names, and never writes the CA key down. The CA also carries X.509 name constraints for those 13 names, and OpenSSL enforces them, so even a leaked key could not vouch for any other site (our server, a bank). rmfakecloud-proxy's CA signs `*.appspot.com`, `*.remarkable.com` and more, and keeps its key on disk.

It refuses any Host header that isn't one of the 13 names (421).

**Why a service token and not mTLS.** rmfakecloud's docs put Cloudflare in front with a client certificate checked by a WAF rule, because Access only does mTLS on Enterprise. That needs a second auth scheme, a WAF rule per hostname, a client cert in the agent (it has none), and it blocks the web UI that pairing needs. A service token works with one Access app, policies for humans and machines side by side, and the agent as it is. Revoke it in Zero Trust and the tablet is out, with nothing else touched.

## Commands

```
pp-proxy gencert      once: /home/root/paper-pure/proxy/{ca.crt,cert.pem,key.pem}
pp-proxy hosts        the /etc/hosts block
pp-proxy check        GET <server>/pp/healthz with the token; says if Access refused it
pp-proxy run          the service (pp-proxy.service)
```

Flags: `-config` (agent.json), `-dir`, `-listen` (127.0.0.1:443), `-upstream` (override), `-force`.

## Install (the device lane runs this)

Copy `out/pp-proxy-arm64` (as `pp-proxy`), `pp-proxy.service` and `install.sh` to the tablet, then:

```sh
bash install.sh --runtime   # this boot only (/etc overlay, /run). Safe first try
bash install.sh             # persistent: remount / rw, umount -R /etc, write the real /etc
bash install.sh --uninstall
```

What it writes:

| What | Where (persistent) | Runtime |
| --- | --- | --- |
| binary | `/home/root/paper-pure/bin/pp-proxy` | same |
| cert and key | `/home/root/paper-pure/proxy/` | same |
| CA trust | `/usr/local/share/ca-certificates/pp-proxy.crt`, then the tablet's own `update-ca-certificates` | appended to `/etc/ssl/certs/ca-certificates.crt` |
| names | `/etc/hosts`, between `# pp-proxy start` / `# pp-proxy end` | same, in the overlay |
| unit | `/etc/systemd/system/pp-proxy.service` + `multi-user.target.wants` | `/run/systemd/system` |

Then it restarts `pp-proxy`, stops `xochitl`, marks local notes `"synced": false` (what rmfakecloud's installer does before a first connection, so nothing local is treated as deleted), and starts `xochitl` again. `rm-sync` is bound to `xochitl`, so it restarts with it and picks up the new trust store.

Persisting uses the same trick rmfakecloud-proxy's installer uses on Ferrari, Chiappa and Tatsu (since its PR #32, Sep 2026): `mount -o remount,rw /` and `umount -R /etc`, because `/etc` is an overlay with a tmpfs upper. The script refuses to write if `/etc` is still an overlay after the umount.

**Sync is not a mod.** `pp-proxy.service` ignores `paper-pure/disable` and runs in stock mode. To cut sync off, revoke the token in Cloudflare, or `systemctl stop pp-proxy`.

**OS update hosts are not on the list** and must never be. Block them separately (device lane), for example with `0.0.0.0` entries. Names seen in the 3.27.2.2 rootfs: `device.cloud.remarkable.com` (memfaultd `base_url`, which also feeds swupdate's suricatta), `backtrace-proxy.cloud.remarkable.engineering` (crash uploads; this one is on our list, so rmfakecloud swallows them).

## Status

Verified in the emulator by `test/e2e` (Oct 25, 2026): `device/install.sh --proxy` (runtime install, then persisted by `pp-device.sh`), then the stock 3.27.2.2 UI paired with the code from rmfakecloud's web API and synced both ways. Every request pp-proxy saw, all 2xx, all on the list: `internal.cloud.remarkable.com` `/discovery/v1/endpoints`, `/integrations/v2/instances`; `local.appspot.com` (from discovery) `/token/json/2/device/new`, `/token/json/2/user/new`; `eu.tectonic.remarkable.com` `/sync/v4/root` (GET), `/sync/v3/root` (PUT), `/sync/v3/files/<hash>` (GET, PUT), `/sync/reports/v1`, `/report/v1`, the `/notifications/ws/json/1` websocket (a server-side upload reached the device within a second); `ping.remarkable.com` `/analytics/v2/events` (rmfakecloud swallows them). rm-sync uses Qt's HTTP backend (`UseCurlHttpBackend=false`) and trusts the CA from the bundle. It survived a reboot (persisted unit, hosts block and CA).

Verified (Oct 25, 2026, dev container):

- `go test -race ./tablet-proxy` passes. It covers: the cert verifies for all 13 names and for nothing else; with the CA key in hand, a cert for `pp.example.org`, `remarkable.com` or a look-alike fails with a name-constraint error; gencert writes exactly 3 files, the key 0600, no CA key, and refuses to overwrite; `agent.json` parsing (upstream from `feed_url`, unknown fields ignored); a PUT through real TLS reaches the upstream with the Access headers set, a client-forged `CF-Access-Client-Secret` replaced, the device's own `Authorization` kept, and `Host` set to the server; a foreign Host gets 421 and never reaches the upstream; a websocket upgrade passes through and carries data; the hosts block holds every name and no update host; the host's OpenSSL 3.0 agrees on all of this.
- Mutation check on a scratch copy: removing header injection, the host allowlist, the name constraints, the Host rewrite, the 0600 key mode, or the no-overwrite guard each makes a test fail.
- `test-tatsu.sh` (run by `../test/local-proof.sh`): PASS 18 on the real 3.27.2.2 tatsu userland (`pp-agent-tatsu-rootfs:3.27.2.2`, arm64 under qemu). The tablet's OpenSSL 3.2.6 accepts the cert and rejects a constraint-violating one ("permitted subtree violation"). `install.sh --runtime` runs twice cleanly with a fake systemctl: CA in the bundle once, 13 names in `/etc/hosts` once, the unit in `/run`, the expected systemctl calls, a fake note flipped to `"synced": false`, and `pp-proxy check` gets 200 through the fake Access gate. The tablet's own `update-ca-certificates` reports "1 added" for the persistent path. Then `openssl s_client`, resolving through the tablet's `/etc/hosts` and verifying against its system bundle, gets rmfakecloud's `Working, ...` for `my.remarkable.com`, `internal.cloud.remarkable.com` and `local.appspot.com`, and a foreign name fails verification.
- In `../test/local-proof.sh`, a simulated tablet pairs and syncs through `pp-proxy`: discovery, the one-time code from the web UI to `/token/json/2/device/new`, `/token/json/2/user/new`, `/sync/v3/root`, and the root index lists a PDF uploaded through the web UI.
- `systemd-analyze verify --root=<copy of the tatsu systemd tree>` on `pp-proxy.service`: clean, exit 0. A copy with a typo'd key was flagged.
- The paths `rm-sync` uses in 3.27.2.2 (`strings`: `/discovery/v1/endpoints`, `/sync/v3/*`, `/sync/v4/root`, `/token/json/2/device/new`, `/token/json/2/user/new`, `/token/json/3/device/delete`, `/sync/reports/v1`) all exist in the pinned rmfakecloud. It is built on libcurl, and xochitl on Qt; both verify through OpenSSL and the system bundle.

Not verified:

- Anything on the real tablet: the persistent install (`remount,rw /` under dm-verity, `umount -R /etc`), binding to :443 there. Real `xochitl` and `rm-sync` on 3.27.2.2 do sync through it in the emulator (below).
- Real Cloudflare: Access with a service token, the tunnel, websockets through it. The gate in the tests is a stand-in.
- Whether 3.27.2.2 contacts a name outside the 13 on the real tablet. In the emulator it didn't (below).
- `install.sh` persistent mode and `--uninstall` (shellcheck only).

Open questions for Cedar:

- OK to mark local notes `"synced": false` at install, as rmfakecloud recommends? On a tablet that was never paired, it should change nothing.
- Service tokens expire (you pick 1 year or non-expiring when you make one). One year plus a calendar reminder, or non-expiring?
