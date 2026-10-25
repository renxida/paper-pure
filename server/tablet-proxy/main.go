// pp-proxy runs on the tablet. It is how stock sync (xochitl, rm-sync)
// reaches our server through Cloudflare Access without touching xochitl.
//
//	/etc/hosts sends the reMarkable cloud names to 127.0.0.1
//	pp-proxy answers TLS on 127.0.0.1:443 with a cert from a tablet-only CA
//	it forwards each request to the server, adding the tablet's Cloudflare
//	Access service-token headers, over normal public-CA TLS
//
// The server address and the token come from agent.json (feed_url and
// headers), so the tablet has one credential in one file. See README.md.
package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// cloudHosts are the names stock sync talks to (the list rmfakecloud-proxy
// uses on the Paper Pro and Pure). They go to 127.0.0.1 in /etc/hosts, the
// local cert covers exactly these, and the local CA may only sign these.
// OS update hosts are NOT here: they must be blocked, never proxied.
var cloudHosts = []string{
	"my.remarkable.com",
	"internal.cloud.remarkable.com",
	"local.appspot.com", // rmfakecloud's default STORAGE_URL host
	"ping.remarkable.com",
	"eu.tectonic.remarkable.com",
	"eu.internal.tctn.cloud.remarkable.com",
	"hwr-production-dot-remarkable-production.appspot.com",
	"service-manager-production-dot-remarkable-production.appspot.com",
	"backtrace-proxy.cloud.remarkable.engineering",
	"webapp-prod.cloud.remarkable.engineering",
	"dev.ping.remarkable.com",
	"dev.tectonic.remarkable.com",
	"dev.internal.cloud.remarkable.com",
}

const usage = `usage: pp-proxy [flags] COMMAND

  run      serve 127.0.0.1:443 for the reMarkable cloud names, forward to the server
  gencert  make the tablet-only CA and the local cert in -dir (once, at install)
  hosts    print the /etc/hosts block
  check    GET <server>/pp/healthz with the tablet's headers, print the answer

flags:
`

type config struct {
	upstream *url.URL
	headers  map[string]string
	caFile   string
}

func main() {
	agentCfg := flag.String("config", "/home/root/paper-pure/agent.json", "agent.json: feed_url gives the server, headers the token")
	dir := flag.String("dir", "/home/root/paper-pure/proxy", "holds ca.crt, cert.pem, key.pem")
	listen := flag.String("listen", "127.0.0.1:443", "listen address")
	up := flag.String("upstream", "", "server URL (default: scheme://host of feed_url)")
	force := flag.Bool("force", false, "gencert: replace existing files")
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage); flag.PrintDefaults() }
	flag.Parse()
	log.SetFlags(0)
	log.SetPrefix("pp-proxy: ")
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	var err error
	switch flag.Arg(0) {
	case "hosts":
		fmt.Print(hostsBlock())
	case "gencert":
		err = gencert(*dir, *force)
	case "run", "check":
		var cfg config
		if cfg, err = loadConfig(*agentCfg, *up); err != nil {
			break
		}
		if flag.Arg(0) == "check" {
			err = check(cfg)
			break
		}
		err = run(cfg, *dir, *listen)
	default:
		flag.Usage()
		os.Exit(2)
	}
	if err != nil {
		log.Fatal(err)
	}
}

func hostsBlock() string {
	var b strings.Builder
	b.WriteString("# pp-proxy start: stock sync goes to our server via 127.0.0.1:443\n")
	for _, h := range cloudHosts {
		fmt.Fprintf(&b, "127.0.0.1 %s\n", h)
	}
	b.WriteString("# pp-proxy end\n")
	return b.String()
}

// loadConfig reads only feed_url, headers and ca_file from agent.json and
// ignores the rest, so the agent owns that file's format.
func loadConfig(path, upstream string) (config, error) {
	var a struct {
		FeedURL string            `json:"feed_url"`
		Headers map[string]string `json:"headers"`
		CAFile  string            `json:"ca_file"`
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return config{}, err
	}
	if err := json.Unmarshal(b, &a); err != nil {
		return config{}, fmt.Errorf("%s: %v", path, err)
	}
	if upstream == "" {
		f, err := url.Parse(a.FeedURL)
		if err != nil || f.Host == "" {
			return config{}, fmt.Errorf("%s: no usable feed_url, and no -upstream", path)
		}
		upstream = f.Scheme + "://" + f.Host
	}
	u, err := url.Parse(upstream)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return config{}, fmt.Errorf("bad upstream %q", upstream)
	}
	return config{upstream: u, headers: a.Headers, caFile: a.CAFile}, nil
}

func transport(cfg config) (*http.Transport, error) {
	t := http.DefaultTransport.(*http.Transport).Clone()
	if cfg.caFile != "" {
		pem, err := os.ReadFile(cfg.caFile)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("%s: no certificates", cfg.caFile)
		}
		t.TLSClientConfig = &tls.Config{RootCAs: pool}
	}
	return t, nil
}

func newHandler(cfg config) (http.Handler, error) {
	t, err := transport(cfg)
	if err != nil {
		return nil, err
	}
	allowed := map[string]bool{}
	for _, h := range cloudHosts {
		allowed[h] = true
	}
	rp := &httputil.ReverseProxy{
		Transport: t,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(cfg.upstream) // also sets Host to the server's name
			for k := range pr.Out.Header {
				if strings.HasPrefix(strings.ToLower(k), "cf-access-") {
					pr.Out.Header.Del(k)
				}
			}
			for k, v := range cfg.headers {
				pr.Out.Header.Set(k, v)
			}
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("upstream error: %s %s%s: %v", r.Method, r.Host, r.URL.Path, err)
			w.WriteHeader(http.StatusBadGateway)
		},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if !allowed[strings.ToLower(host)] {
			log.Printf("refused host %q %s %s", r.Host, r.Method, r.URL.Path)
			http.Error(w, "not a host pp-proxy serves", http.StatusMisdirectedRequest)
			return
		}
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, code: http.StatusOK}
		rp.ServeHTTP(sw, r)
		log.Printf("%s %s%s -> %d (%s)", r.Method, host, r.URL.Path, sw.code, time.Since(start).Round(time.Millisecond))
	}), nil
}

// statusWriter records the status for the log. Unwrap lets the reverse
// proxy reach Flush and Hijack (websocket upgrades) underneath.
type statusWriter struct {
	http.ResponseWriter
	code int
}

func (s *statusWriter) WriteHeader(code int)        { s.code = code; s.ResponseWriter.WriteHeader(code) }
func (s *statusWriter) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func run(cfg config, dir, listen string) error {
	h, err := newHandler(cfg)
	if err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem"))
	if err != nil {
		return fmt.Errorf("%v (run pp-proxy gencert first)", err)
	}
	srv := &http.Server{
		Addr:              listen,
		Handler:           h,
		ReadHeaderTimeout: 30 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ErrorLog:          log.New(io.Discard, "", 0), // TLS handshake noise from probes
	}
	log.Printf("listening on %s, forwarding to %s with %d header(s)", listen, cfg.upstream, len(cfg.headers))
	return srv.ListenAndServeTLS("", "")
}

func check(cfg config) error {
	t, err := transport(cfg)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, cfg.upstream.JoinPath("pp", "healthz").String(), nil)
	for k, v := range cfg.headers {
		req.Header.Set(k, v)
	}
	c := &http.Client{Transport: t, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(bufio.NewReader(resp.Body), 4096))
	fmt.Printf("%s %s\n%s\n", req.URL, resp.Status, strings.TrimSpace(string(b)))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("server answered %s (a 302 or 401/403 here usually means Cloudflare Access refused the token)", resp.Status)
	}
	return nil
}

// newCA makes the tablet-only CA. It may sign only cloudHosts (X.509 name
// constraints, which OpenSSL enforces), so even a leaked key can't vouch
// for any other site.
func newCA() (*x509.Certificate, *ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:                serial(),
		Subject:                     pkix.Name{CommonName: "pp-proxy tablet-only CA"},
		NotBefore:                   time.Now().Add(-time.Hour),
		NotAfter:                    time.Now().AddDate(20, 0, 0),
		IsCA:                        true,
		BasicConstraintsValid:       true,
		MaxPathLenZero:              true,
		KeyUsage:                    x509.KeyUsageCertSign,
		PermittedDNSDomainsCritical: true,
		PermittedDNSDomains:         cloudHosts,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	ca, err := x509.ParseCertificate(der)
	return ca, key, err
}

func newLeaf(ca *x509.Certificate, caKey *ecdsa.PrivateKey, names []string) (der []byte, key *ecdsa.PrivateKey, err error) {
	if key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader); err != nil {
		return nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject:      pkix.Name{CommonName: "pp-proxy"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(20, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     names,
	}
	der, err = x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
	return der, key, err
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	return n
}

// gencert writes ca.crt (goes into the tablet's trust store), cert.pem
// (leaf + CA) and key.pem. The CA key only ever lives in memory here.
func gencert(dir string, force bool) error {
	files := []string{"ca.crt", "cert.pem", "key.pem"}
	if !force {
		for _, f := range files {
			if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
				return fmt.Errorf("%s exists (use -force to replace; then reinstall ca.crt)", filepath.Join(dir, f))
			}
		}
	}
	ca, caKey, err := newCA()
	if err != nil {
		return err
	}
	leaf, key, err := newLeaf(ca, caKey, cloudHosts)
	if err != nil {
		return err
	}
	kder, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ca.Raw})
	certPEM := append(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf}), caPEM...)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: kder})
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	for name, b := range map[string][]byte{"ca.crt": caPEM, "cert.pem": certPEM, "key.pem": keyPEM} {
		mode := os.FileMode(0o644)
		if name == "key.pem" {
			mode = 0o600
		}
		if err := os.WriteFile(filepath.Join(dir, name), b, mode); err != nil {
			return err
		}
	}
	fmt.Printf("wrote %s/{ca.crt,cert.pem,key.pem}; the CA key was never written down\n", dir)
	return nil
}
