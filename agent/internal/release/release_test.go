package release

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testManifest() *Manifest {
	return &Manifest{
		Format: Format, ID: "r1", Device: "tatsu", Created: time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC),
		OSVersions: []string{"3.27.2.2"}, Size: 10, SHA256: strings.Repeat("a", 64),
	}
}

func keys(t *testing.T) ([]byte, []byte) {
	t.Helper()
	priv, pub, err := GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	return priv, pub
}

func TestSignVerify(t *testing.T) {
	privPEM, pubPEM := keys(t)
	priv, err := ParsePrivateKey(privPEM)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := ParsePublicKey(pubPEM)
	if err != nil {
		t.Fatal(err)
	}
	mb, _ := testManifest().Marshal()
	sig := Sign(priv, mb)
	m, err := Verify(pub, mb, sig)
	if err != nil || m.ID != "r1" {
		t.Fatalf("good signature rejected: %v", err)
	}

	tampered := bytes.Replace(mb, []byte("3.27.2.2"), []byte("3.27.2.3"), 1)
	if _, err := Verify(pub, tampered, sig); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("tampered manifest: got %v, want bad signature", err)
	}
	_, otherPub := keys(t)
	op, _ := ParsePublicKey(otherPub)
	if _, err := Verify(op, mb, sig); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("wrong key: got %v, want bad signature", err)
	}
	for _, junk := range []string{"", "not base64!", base64.StdEncoding.EncodeToString([]byte("short"))} {
		if _, err := Verify(pub, mb, []byte(junk)); !errors.Is(err, ErrBadSignature) {
			t.Fatalf("junk sig %q: got %v", junk, err)
		}
	}
}

func TestManifestValidate(t *testing.T) {
	bad := map[string]func(m *Manifest){
		"format":   func(m *Manifest) { m.Format = 2 },
		"id slash": func(m *Manifest) { m.ID = "../x" },
		"id dot":   func(m *Manifest) { m.ID = "." },
		"no os":    func(m *Manifest) { m.OSVersions = nil },
		"empty os": func(m *Manifest) { m.OSVersions = []string{""} },
		"sha":      func(m *Manifest) { m.SHA256 = "xyz" },
		"size":     func(m *Manifest) { m.Size = 0 },
		"device":   func(m *Manifest) { m.Device = "" },
		"created":  func(m *Manifest) { m.Created = time.Time{} },
	}
	for name, f := range bad {
		m := testManifest()
		f(m)
		if m.Validate() == nil {
			t.Errorf("%s: invalid manifest accepted", name)
		}
	}
	if !testManifest().SupportsOS("3.27.2.2") || testManifest().SupportsOS("3.27.1.0") || testManifest().SupportsOS("") {
		t.Fatal("SupportsOS is not exact match")
	}
	// Unknown fields are refused: a newer format must not half-parse.
	mb, _ := testManifest().Marshal()
	mb = bytes.Replace(mb, []byte(`"format": 1,`), []byte(`"format": 1, "surprise": true,`), 1)
	if _, err := ParseManifest(mb); err == nil {
		t.Fatal("unknown field accepted")
	}
}

// TestOpenSSLInterop: a signature can be checked with stock openssl, which
// the tablet also has.
func TestOpenSSLInterop(t *testing.T) {
	if _, err := exec.LookPath("openssl"); err != nil {
		t.Skip("no openssl")
	}
	dir := t.TempDir()
	privPEM, pubPEM := keys(t)
	priv, _ := ParsePrivateKey(privPEM)
	mb, _ := testManifest().Marshal()
	raw, _ := base64.StdEncoding.DecodeString(strings.TrimSpace(string(Sign(priv, mb))))
	os.WriteFile(filepath.Join(dir, "pub.pem"), pubPEM, 0o644)
	os.WriteFile(filepath.Join(dir, "m.json"), mb, 0o644)
	os.WriteFile(filepath.Join(dir, "m.sig"), raw, 0o644)
	out, err := exec.Command("openssl", "pkeyutl", "-verify", "-pubin", "-inkey", filepath.Join(dir, "pub.pem"),
		"-rawin", "-in", filepath.Join(dir, "m.json"), "-sigfile", filepath.Join(dir, "m.sig")).CombinedOutput()
	if err != nil {
		t.Fatalf("openssl verify: %v\n%s", err, out)
	}
}

func writeTree(t *testing.T, root string) {
	t.Helper()
	os.MkdirAll(filepath.Join(root, "hooks"), 0o755)
	os.MkdirAll(filepath.Join(root, "empty"), 0o755)
	os.WriteFile(filepath.Join(root, "hooks", "activate.sh"), []byte("#!/bin/sh\necho hi\n"), 0o755)
	os.WriteFile(filepath.Join(root, "data.txt"), []byte("data"), 0o600)
	os.Symlink("hooks/activate.sh", filepath.Join(root, "link"))
}

func TestPackReproducibleAndRoundTrip(t *testing.T) {
	src := t.TempDir()
	writeTree(t, src)
	ts := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	var a, b bytes.Buffer
	if err := Pack(src, &a, ts); err != nil {
		t.Fatal(err)
	}
	if err := Pack(src, &b, ts); err != nil {
		t.Fatal(err)
	}
	if sha256.Sum256(a.Bytes()) != sha256.Sum256(b.Bytes()) {
		t.Fatal("pack is not reproducible")
	}
	dst := filepath.Join(t.TempDir(), "out")
	if err := Extract(bytes.NewReader(a.Bytes()), dst); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dst, "hooks", "activate.sh"))
	if err != nil || fi.Mode().Perm() != 0o755 {
		t.Fatalf("exec bit lost: %v %v", fi.Mode(), err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "data.txt")); string(b) != "data" {
		t.Fatal("content lost")
	}
	if l, _ := os.Readlink(filepath.Join(dst, "link")); l != "hooks/activate.sh" {
		t.Fatalf("symlink lost: %q", l)
	}
	if fi, err := os.Stat(filepath.Join(dst, "empty")); err != nil || !fi.IsDir() {
		t.Fatal("empty dir lost")
	}
	if err := Extract(bytes.NewReader(a.Bytes()), dst); err == nil {
		t.Fatal("extract into existing dir must fail")
	}
}

func TestPackRefusesEscapingSymlink(t *testing.T) {
	src := t.TempDir()
	os.Symlink("/etc/passwd", filepath.Join(src, "abs"))
	if err := Pack(src, &bytes.Buffer{}, time.Now()); err == nil {
		t.Fatal("absolute symlink packed")
	}
	// A chain: d/up -> .. is fine alone, escape -> d/up/.. is the tree's parent.
	src = t.TempDir()
	os.MkdirAll(filepath.Join(src, "d"), 0o755)
	os.Symlink("..", filepath.Join(src, "d", "up"))
	os.Symlink("d/up/..", filepath.Join(src, "escape"))
	err := Pack(src, &bytes.Buffer{}, time.Now())
	if err == nil || !strings.Contains(err.Error(), "leads out") {
		t.Fatalf("chained escaping symlink packed: %v", err)
	}
	// In-tree chains are fine: a -> d/up/d (d/up is the root again).
	os.Remove(filepath.Join(src, "escape"))
	os.Symlink("d/up/d", filepath.Join(src, "a"))
	os.Symlink("missing/../d", filepath.Join(src, "dangling"))
	if err := Pack(src, &bytes.Buffer{}, time.Now()); err != nil {
		t.Fatalf("in-tree chain refused: %v", err)
	}
}

type ent struct {
	name, link string
	typ        byte
	body       string
}

func mkTar(t *testing.T, ents ...ent) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, e := range ents {
		h := &tar.Header{Name: e.name, Linkname: e.link, Typeflag: e.typ, Mode: 0o644, Size: int64(len(e.body))}
		if e.typ != tar.TypeReg {
			h.Size = 0
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if e.typ == tar.TypeReg {
			tw.Write([]byte(e.body))
		}
	}
	tw.Close()
	gz.Close()
	return buf.Bytes()
}

func TestExtractRejectsEscapes(t *testing.T) {
	cases := map[string][]ent{
		"dotdot":          {{name: "../evil", typ: tar.TypeReg, body: "x"}},
		"nested dotdot":   {{name: "a/../../evil", typ: tar.TypeReg, body: "x"}},
		"absolute":        {{name: "/etc/evil", typ: tar.TypeReg, body: "x"}},
		"abs symlink":     {{name: "l", link: "/etc", typ: tar.TypeSymlink}},
		"climbing link":   {{name: "a/l", link: "../../etc", typ: tar.TypeSymlink}},
		"hardlink":        {{name: "h", link: "x", typ: tar.TypeLink}},
		"device":          {{name: "d", typ: tar.TypeChar}},
		"link under link": {{name: "d", link: ".", typ: tar.TypeSymlink}, {name: "d/up", link: "..", typ: tar.TypeSymlink}},
		"write via link":  {{name: "l", link: "sub", typ: tar.TypeSymlink}, {name: "l", typ: tar.TypeReg, body: "x"}},
		// Each link stays inside on its own; together they lead out.
		"chained links": {{name: "d/", typ: tar.TypeDir}, {name: "d/up", link: "..", typ: tar.TypeSymlink}, {name: "escape", link: "d/up/..", typ: tar.TypeSymlink}},
		"chain via dir": {{name: "a/b/", typ: tar.TypeDir}, {name: "a/b/top", link: "../..", typ: tar.TypeSymlink}, {name: "x", link: "a/b/top/../etc", typ: tar.TypeSymlink}},
	}
	for name, ents := range cases {
		dst := filepath.Join(t.TempDir(), "out")
		if err := Extract(bytes.NewReader(mkTar(t, ents...)), dst); err == nil {
			t.Errorf("%s: extracted, want refusal", name)
		}
	}
	// And a fine in-tree link still works.
	dst := filepath.Join(t.TempDir(), "out")
	ok := mkTar(t, ent{name: "a/f", typ: tar.TypeReg, body: "x"}, ent{name: "a/l", link: "f", typ: tar.TypeSymlink})
	if err := Extract(bytes.NewReader(ok), dst); err != nil {
		t.Fatalf("in-tree symlink refused: %v", err)
	}
}
