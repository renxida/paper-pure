package agent

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

func newHTTPClient(c Config) (*http.Client, error) {
	tr := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 20 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout:   20 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		ForceAttemptHTTP2:     true,
	}
	if c.CAFile != "" {
		pem, err := os.ReadFile(c.CAFile)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("%s: no certificates", c.CAFile)
		}
		tr.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return &http.Client{Transport: tr}, nil
}

func (a *Agent) newRequest(ctx context.Context, method, url string, body io.Reader) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "pp-agent/"+Version)
	for k, v := range a.cfg.Headers {
		req.Header.Set(k, v)
	}
	return req, nil
}

// getSmall fetches a small file (manifest, signature) into memory.
func (a *Agent) getSmall(ctx context.Context, url string) ([]byte, error) {
	req, err := a.newRequest(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

// download fetches url into part, resuming from whatever part already
// holds, then checks size and sha256. A bad file is deleted so the next run
// starts clean. An interrupted download is kept for the next run.
func (a *Agent) download(ctx context.Context, url, part string, size int64, sha string) error {
	var off int64
	if fi, err := os.Stat(part); err == nil {
		off = fi.Size()
	}
	if off > size {
		os.Remove(part)
		off = 0
	}
	if off < size {
		req, err := a.newRequest(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		if off > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", off))
		}
		resp, err := a.http.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		flags := os.O_WRONLY | os.O_CREATE
		switch {
		case resp.StatusCode == http.StatusPartialContent && off > 0:
			flags |= os.O_APPEND
			a.logf("resuming download at %d/%d bytes", off, size)
		case resp.StatusCode == http.StatusOK:
			flags |= os.O_TRUNC
			off = 0
		default:
			return fmt.Errorf("GET %s: %s", url, resp.Status)
		}
		f, err := os.OpenFile(part, flags, 0o644)
		if err != nil {
			return err
		}
		n, cerr := io.Copy(f, io.LimitReader(resp.Body, size-off))
		if err := f.Sync(); cerr == nil {
			cerr = err
		}
		if err := f.Close(); cerr == nil {
			cerr = err
		}
		if cerr != nil {
			return fmt.Errorf("download interrupted at %d/%d bytes (kept for resume): %w", off+n, size, cerr)
		}
		if off+n < size {
			return fmt.Errorf("download short at %d/%d bytes (kept for resume)", off+n, size)
		}
	}
	got, err := fileSHA256(part)
	if err != nil {
		return err
	}
	if got != sha {
		os.Remove(part)
		return fmt.Errorf("sha256 mismatch: got %s want %s (deleted)", got, sha)
	}
	return nil
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

var errNoFeed = errors.New("no feed_url configured")
