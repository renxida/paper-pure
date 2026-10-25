// ppsign makes and checks paper-pure releases. Runs on the build machine
// (CI or Cedar's laptop), never on the tablet. See agent/README.md.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"paper-pure/agent/internal/release"
)

const usage = `usage:
  ppsign keygen  -out DIR
  ppsign pack    -key KEY -dir TREE -os 3.27.2.2 [-os V]... -out FEED
                 [-id ID] [-device tatsu] [-expect-mapped S]... [-notes TEXT]
                 [-created RFC3339] [-latest]
  ppsign verify  -pub PUB -manifest FEED/ID.json [-tarball FILE]
  ppsign serve   -dir FEED [-addr 127.0.0.1:3090]     (dev and tests only)
`

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ",") }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

func main() {
	log.SetFlags(0)
	log.SetPrefix("ppsign: ")
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	args := os.Args[2:]
	var err error
	switch os.Args[1] {
	case "keygen":
		err = keygen(args)
	case "pack":
		err = pack(args)
	case "verify":
		err = verify(args)
	case "serve":
		err = serve(args)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		log.Fatal(err)
	}
}

func keygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	out := fs.String("out", ".", "directory for release.key.pem and release.pub.pem")
	fs.Parse(args)
	priv, pub, err := release.GenerateKey()
	if err != nil {
		return err
	}
	kp, pp := filepath.Join(*out, "release.key.pem"), filepath.Join(*out, "release.pub.pem")
	if _, err := os.Stat(kp); err == nil {
		return fmt.Errorf("%s exists; not overwriting a key", kp)
	}
	if err := os.MkdirAll(*out, 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(kp, priv, 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(pp, pub, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s (secret: password manager, never the repo)\nwrote %s (goes on the tablet as keys/release.pub.pem)\n", kp, pp)
	return nil
}

func pack(args []string) error {
	fs := flag.NewFlagSet("pack", flag.ExitOnError)
	key := fs.String("key", "", "private key PEM")
	dir := fs.String("dir", "", "release tree to pack")
	out := fs.String("out", "", "feed directory to write into")
	id := fs.String("id", "", "release id (default: created time, 20060102-150405)")
	device := fs.String("device", "tatsu", "device codename")
	notes := fs.String("notes", "", "free text")
	created := fs.String("created", "", "created time, RFC3339 (default: now)")
	latest := fs.Bool("latest", false, "also write latest.json + latest.json.sig")
	var oses, mapped multi
	fs.Var(&oses, "os", "exact OS version (IMG_VERSION) this was tested on; repeatable")
	fs.Var(&mapped, "expect-mapped", "substring that must be in xochitl's /proc/pid/maps; repeatable")
	fs.Parse(args)
	if *key == "" || *dir == "" || *out == "" || len(oses) == 0 {
		return fmt.Errorf("pack needs -key, -dir, -out and at least one -os")
	}
	priv, err := release.LoadPrivateKey(*key)
	if err != nil {
		return err
	}
	ct := time.Now().UTC().Truncate(time.Second)
	if *created != "" {
		if ct, err = time.Parse(time.RFC3339, *created); err != nil {
			return err
		}
	}
	if *id == "" {
		*id = ct.UTC().Format("20060102-150405")
	}
	if !release.ValidID(*id) {
		return fmt.Errorf("bad id %q (letters, digits, . _ -; max 64)", *id)
	}
	for _, h := range []string{"hooks/activate.sh", "hooks/deactivate.sh"} {
		if _, err := os.Stat(filepath.Join(*dir, h)); err != nil {
			fmt.Fprintf(os.Stderr, "ppsign: note: %s missing (treated as a no-op)\n", h)
		}
	}
	var tgz bytes.Buffer
	if err := release.Pack(*dir, &tgz, ct); err != nil {
		return err
	}
	sum := sha256.Sum256(tgz.Bytes())
	m := &release.Manifest{
		Format: release.Format, ID: *id, Device: *device, Created: ct.UTC(),
		OSVersions: oses, Size: int64(tgz.Len()), SHA256: hex.EncodeToString(sum[:]),
		ExpectMapped: mapped, Notes: *notes,
	}
	if err := m.Validate(); err != nil {
		return err
	}
	mb, err := m.Marshal()
	if err != nil {
		return err
	}
	sig := release.Sign(priv, mb)
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return err
	}
	files := map[string][]byte{m.Tarball(): tgz.Bytes(), *id + ".json": mb, *id + ".json.sig": sig}
	if *latest {
		files["latest.json"], files["latest.json.sig"] = mb, sig
	}
	// Tarball first, latest.json last: a feed reader never sees a manifest
	// whose tarball is missing.
	order := []string{m.Tarball(), *id + ".json", *id + ".json.sig", "latest.json.sig", "latest.json"}
	for _, name := range order {
		b, ok := files[name]
		if !ok {
			continue
		}
		if err := writeAtomic(filepath.Join(*out, name), b); err != nil {
			return err
		}
	}
	fmt.Printf("%s: %d bytes, sha256 %s, os %v%s\n", *id, m.Size, m.SHA256, oses, map[bool]string{true: ", now latest"}[*latest])
	return nil
}

func writeAtomic(p string, b []byte) error {
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func verify(args []string) error {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	pubPath := fs.String("pub", "", "public key PEM")
	mPath := fs.String("manifest", "", "manifest .json (signature at .json.sig)")
	tPath := fs.String("tarball", "", "tarball (default: <id>.tar.gz next to the manifest)")
	fs.Parse(args)
	if *pubPath == "" || *mPath == "" {
		return fmt.Errorf("verify needs -pub and -manifest")
	}
	pub, err := release.LoadPublicKey(*pubPath)
	if err != nil {
		return err
	}
	mb, err := os.ReadFile(*mPath)
	if err != nil {
		return err
	}
	sb, err := os.ReadFile(*mPath + ".sig")
	if err != nil {
		return err
	}
	m, err := release.Verify(pub, mb, sb)
	if err != nil {
		return err
	}
	if *tPath == "" {
		*tPath = filepath.Join(filepath.Dir(*mPath), m.Tarball())
	}
	f, err := os.Open(*tPath)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return err
	}
	if n != m.Size || hex.EncodeToString(h.Sum(nil)) != m.SHA256 {
		return fmt.Errorf("%s does not match the manifest (size %d vs %d)", *tPath, n, m.Size)
	}
	fmt.Printf("ok: %s for %s on OS %v, created %s\n", m.ID, m.Device, m.OSVersions, m.Created.Format(time.RFC3339))
	return nil
}

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	dir := fs.String("dir", ".", "feed directory")
	addr := fs.String("addr", "127.0.0.1:3090", "listen address")
	fs.Parse(args)
	files := http.FileServer(http.Dir(*dir))
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/status" {
			// Dev stand-in for the server's status endpoint: keep the last one.
			b, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
			os.WriteFile(filepath.Join(*dir, "last-status.json"), b, 0o644)
			log.Printf("POST /status %d bytes", len(b))
			w.WriteHeader(http.StatusNoContent)
			return
		}
		log.Printf("%s %s %s", r.Method, r.URL.Path, r.Header.Get("Range"))
		files.ServeHTTP(w, r)
	})
	log.Printf("serving %s on http://%s/", *dir, *addr)
	return http.ListenAndServe(*addr, h)
}
