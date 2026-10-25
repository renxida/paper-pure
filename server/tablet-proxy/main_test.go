package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCertCoversCloudHostsOnly(t *testing.T) {
	ca, caKey, err := newCA()
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	der, _, err := newLeaf(ca, caKey, cloudHosts)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	for _, h := range cloudHosts {
		if _, err := leaf.Verify(x509.VerifyOptions{DNSName: h, Roots: roots}); err != nil {
			t.Errorf("%s: %v", h, err)
		}
	}
	if _, err := leaf.Verify(x509.VerifyOptions{DNSName: "pp.example.org", Roots: roots}); err == nil {
		t.Error("leaf verified for a name it doesn't carry")
	}
	// The name constraints: even with the CA key, a cert for another site
	// doesn't verify. (TestOpenSSLAgrees checks OpenSSL does the same.)
	for _, evil := range []string{"pp.example.org", "remarkable.com", "x.my.remarkable.com.evil.org"} {
		der, _, err := newLeaf(ca, caKey, []string{evil})
		if err != nil {
			t.Fatal(err)
		}
		bad, _ := x509.ParseCertificate(der)
		_, err = bad.Verify(x509.VerifyOptions{DNSName: evil, Roots: roots})
		if err == nil || !strings.Contains(err.Error(), "constraint") {
			t.Errorf("%s: want a name-constraint error, got %v", evil, err)
		}
	}
}

func TestGencertFiles(t *testing.T) {
	dir := t.TempDir()
	if err := gencert(dir, false); err != nil {
		t.Fatal(err)
	}
	if err := gencert(dir, false); err == nil {
		t.Fatal("gencert overwrote existing files")
	}
	if fi, _ := os.Stat(filepath.Join(dir, "key.pem")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("key.pem mode %v", fi.Mode())
	}
	b, _ := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if strings.Contains(string(b), "PRIVATE") || strings.Count(string(b), "BEGIN") != 1 {
		t.Fatal("ca.crt should hold exactly one certificate and no key")
	}
	matches, _ := filepath.Glob(filepath.Join(dir, "*"))
	if len(matches) != 3 {
		t.Fatalf("files: %v (no CA key may be written)", matches)
	}
	if _, err := tls.LoadX509KeyPair(filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")); err != nil {
		t.Fatal(err)
	}
}

func TestLoadConfig(t *testing.T) {
	p := filepath.Join(t.TempDir(), "agent.json")
	os.WriteFile(p, []byte(`{"feed_url":"https://pp.example.org/pp/releases/tatsu/","headers":{"CF-Access-Client-Id":"id"},"battery_floor":30}`), 0o600)
	c, err := loadConfig(p, "")
	if err != nil || c.upstream.String() != "https://pp.example.org" || c.headers["CF-Access-Client-Id"] != "id" {
		t.Fatalf("%v %+v", err, c)
	}
	if c, _ = loadConfig(p, "http://127.0.0.1:3080"); c.upstream.Host != "127.0.0.1:3080" {
		t.Fatalf("override: %v", c.upstream)
	}
	os.WriteFile(p, []byte(`{"headers":{}}`), 0o600)
	if _, err := loadConfig(p, ""); err == nil {
		t.Fatal("no feed_url and no -upstream should fail")
	}
}

// proxyChain starts upstream <- pp-proxy (real TLS, our cert) and returns a
// client that resolves every cloud host to the proxy and trusts only ca.crt,
// like the tablet after install.
func proxyChain(t *testing.T, upstream http.Handler) (*http.Client, string) {
	t.Helper()
	return proxyChainStatus(t, upstream, "")
}

func proxyChainStatus(t *testing.T, upstream http.Handler, status string) (*http.Client, string) {
	t.Helper()
	up := httptest.NewServer(upstream)
	t.Cleanup(up.Close)
	dir := t.TempDir()
	if err := gencert(dir, false); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "agent.json")
	os.WriteFile(p, []byte(`{"feed_url":"`+up.URL+`/pp/releases/tatsu/","headers":{"CF-Access-Client-Id":"tablet.access","CF-Access-Client-Secret":"s3cret"}}`), 0o600)
	cfg, err := loadConfig(p, "")
	if err != nil {
		t.Fatal(err)
	}
	cfg.status = status
	h, err := newHandler(cfg)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := tls.LoadX509KeyPair(filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	px := httptest.NewUnstartedServer(h)
	px.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	px.StartTLS()
	t.Cleanup(px.Close)
	caPEM, _ := os.ReadFile(filepath.Join(dir, "ca.crt"))
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(caPEM)
	addr := px.Listener.Addr().String()
	dial := func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}, DialContext: dial}}
	return client, addr
}

func TestForwardsWithAccessHeaders(t *testing.T) {
	var got *http.Request
	var body string
	client, _ := proxyChain(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		b, _ := io.ReadAll(r.Body)
		body = string(b)
		fmt.Fprint(w, "ok from server")
	}))
	req, _ := http.NewRequest("PUT", "https://my.remarkable.com/sync/v3/root?x=1", strings.NewReader(`{"generation":1}`))
	req.Header.Set("Authorization", "Bearer device-token")
	req.Header.Set("CF-Access-Client-Secret", "forged-by-client")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || string(b) != "ok from server" {
		t.Fatalf("%d %q", resp.StatusCode, b)
	}
	if got.Method != "PUT" || got.URL.RequestURI() != "/sync/v3/root?x=1" || body != `{"generation":1}` {
		t.Fatalf("server saw %s %s %q", got.Method, got.URL.RequestURI(), body)
	}
	if got.Header.Get("CF-Access-Client-Id") != "tablet.access" || got.Header.Get("CF-Access-Client-Secret") != "s3cret" {
		t.Fatalf("access headers: %v", got.Header)
	}
	if got.Header.Get("Authorization") != "Bearer device-token" {
		t.Fatal("the device's own rmfakecloud token must pass through")
	}
	if strings.Contains(got.Host, "remarkable") {
		t.Fatalf("Host %q: must be the server's name, or Cloudflare can't route it", got.Host)
	}
}

func TestRefusesOtherHosts(t *testing.T) {
	called := false
	client, _ := proxyChain(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true }))
	// TLS already fails for names outside the cert...
	if _, err := client.Get("https://updates.cloud.remarkable.engineering/"); err == nil {
		t.Fatal("TLS accepted a name outside the cert")
	}
	// ...and a right SNI with a wrong Host header is refused by the handler.
	req, _ := http.NewRequest("GET", "https://my.remarkable.com/", nil)
	req.Host = "device.cloud.remarkable.com"
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMisdirectedRequest || called {
		t.Fatalf("got %d, upstream called=%v", resp.StatusCode, called)
	}
}

func TestWebsocketUpgradePassesThrough(t *testing.T) {
	_, addr := proxyChain(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Upgrade") != "websocket" || r.Header.Get("CF-Access-Client-Id") != "tablet.access" {
			http.Error(w, "want an upgrade with access headers", 400)
			return
		}
		conn, brw, err := http.NewResponseController(w).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		brw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
		brw.Flush()
		line, _ := brw.ReadString('\n')
		brw.WriteString("echo:" + line)
		brw.Flush()
	}))
	conn, err := tls.Dial("tcp", addr, &tls.Config{ServerName: "internal.cloud.remarkable.com", InsecureSkipVerify: true, NextProtos: []string{"http/1.1"}})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	fmt.Fprint(conn, "GET /notifications/ws/json/1 HTTP/1.1\r\nHost: internal.cloud.remarkable.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil || resp.StatusCode != 101 {
		t.Fatalf("upgrade: %v %v", err, resp)
	}
	fmt.Fprint(conn, "ping\n")
	line, err := br.ReadString('\n')
	if err != nil || line != "echo:ping\n" {
		t.Fatalf("after upgrade: %q %v", line, err)
	}
}

func TestHostsBlockMatchesCert(t *testing.T) {
	block := hostsBlock()
	for _, h := range cloudHosts {
		if !strings.Contains(block, "127.0.0.1 "+h+"\n") {
			t.Errorf("hosts block misses %s", h)
		}
	}
	for _, bad := range []string{"device.cloud.remarkable.com", "updates", "memfault"} {
		if strings.Contains(block, bad) {
			t.Errorf("hosts block must not send %s to the proxy", bad)
		}
	}
}

// TestOpenSSLAgrees checks that OpenSSL, which xochitl (Qt) and rm-sync
// (libcurl) verify with, accepts the local cert and enforces the CA's name
// constraints. PP_CERT_OUT=dir keeps the files so test-tatsu.sh can run
// the tablet's own OpenSSL 3.2.6 on them too.
func TestOpenSSLAgrees(t *testing.T) {
	openssl, err := exec.LookPath("openssl")
	if err != nil {
		t.Skip("no openssl")
	}
	dir := os.Getenv("PP_CERT_OUT")
	if dir == "" {
		dir = t.TempDir()
	}
	ca, caKey, err := newCA()
	if err != nil {
		t.Fatal(err)
	}
	good, _, _ := newLeaf(ca, caKey, cloudHosts)
	evil, _, _ := newLeaf(ca, caKey, []string{"pp.example.org"})
	for name, der := range map[string][]byte{"ca.pem": ca.Raw, "good.pem": good, "evil.pem": evil} {
		os.WriteFile(filepath.Join(dir, name), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	}
	verify := func(leaf, host string) (string, error) {
		out, err := exec.Command(openssl, "verify", "-CAfile", filepath.Join(dir, "ca.pem"),
			"-verify_hostname", host, filepath.Join(dir, leaf)).CombinedOutput()
		return string(out), err
	}
	for _, h := range []string{"my.remarkable.com", "local.appspot.com", "eu.tectonic.remarkable.com"} {
		if out, err := verify("good.pem", h); err != nil {
			t.Errorf("good cert for %s: %v %s", h, err, out)
		}
	}
	if out, err := verify("good.pem", "evil.example.com"); err == nil {
		t.Errorf("good cert verified for a foreign name: %s", out)
	}
	out, err := verify("evil.pem", "pp.example.org")
	if err == nil || !strings.Contains(out, "subtree") {
		t.Errorf("evil cert: want a permitted-subtree violation, got %v %s", err, out)
	}
}

func TestSyncHealthFile(t *testing.T) {
	status := filepath.Join(t.TempDir(), "run", "sync.json")
	client, _ := proxyChainStatus(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token/json/2/user/new" {
			http.Error(w, "Access refused", http.StatusForbidden)
			return
		}
		fmt.Fprint(w, "ok")
	}), status)
	type file struct {
		Since     time.Time  `json:"since"`
		LastOK    *time.Time `json:"last_ok"`
		OK        int        `json:"ok"`
		Errors    int        `json:"errors"`
		LastError *syncError `json:"last_error"`
	}
	read := func() file {
		var h file
		b, err := os.ReadFile(status)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(b, &h); err != nil {
			t.Fatalf("%v: %s", err, b)
		}
		return h
	}
	if h := read(); h.Since.IsZero() || h.LastOK != nil || h.Errors != 0 {
		t.Fatalf("at start: %+v", h)
	}
	get := func(u string) {
		resp, err := client.Get(u)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
	get("https://ping.remarkable.com/analytics/v2/events") // not sync: not counted
	if h := read(); h.OK != 0 {
		t.Fatalf("analytics counted as sync: %+v", h)
	}
	get("https://eu.tectonic.remarkable.com/sync/v4/root")
	h := read()
	if h.OK != 1 || h.LastOK == nil || h.Errors != 0 {
		t.Fatalf("after a sync: %+v", h)
	}
	get("https://my.remarkable.com/token/json/2/user/new")
	h = read()
	if h.Errors != 1 || h.LastError == nil || h.LastError.Code != 403 || h.LastError.Path != "my.remarkable.com/token/json/2/user/new" {
		t.Fatalf("after a refusal: %+v %+v", h, h.LastError)
	}
}
