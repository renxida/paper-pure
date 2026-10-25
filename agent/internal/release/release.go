// Package release is the release format shared by ppsign (packs and signs)
// and pp-agent (verifies and unpacks). The whole format is:
//
//	<id>.tar.gz     the release tree (hooks/, checks/, whatever the mods need)
//	<id>.json       the manifest below, as exact bytes
//	<id>.json.sig   base64 of the ed25519 signature over <id>.json
//
// Keys are standard PEM (PKCS#8 private, PKIX public), so openssl can check a
// signature too. See agent/README.md.
package release

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"time"
)

// Format is the only manifest format version the agent understands.
const Format = 1

// Manifest describes one release. The tarball is always <ID>.tar.gz next to
// the manifest, so the manifest does not carry a file name.
type Manifest struct {
	Format  int       `json:"format"`
	ID      string    `json:"id"`
	Device  string    `json:"device"`
	Created time.Time `json:"created"`
	// OSVersions lists every IMG_VERSION this release was tested on. Exact
	// strings only: no ranges, because "between" was never tested.
	OSVersions []string `json:"os_versions"`
	Size       int64    `json:"size"`
	SHA256     string   `json:"sha256"`
	// ExpectMapped: substrings that must show up in xochitl's
	// /proc/<pid>/maps after activation (e.g. "xovi.so", "appload.so").
	ExpectMapped []string `json:"expect_mapped,omitempty"`
	Notes        string   `json:"notes,omitempty"`
}

var idRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
var shaRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ValidID reports whether id is safe to use as a directory name.
func ValidID(id string) bool { return idRe.MatchString(id) }

// Tarball is the file name of the release tarball.
func (m *Manifest) Tarball() string { return m.ID + ".tar.gz" }

// Validate checks the manifest is well formed. It says nothing about whether
// it fits this device; the agent checks that.
func (m *Manifest) Validate() error {
	switch {
	case m.Format != Format:
		return fmt.Errorf("manifest format %d, want %d", m.Format, Format)
	case !ValidID(m.ID):
		return fmt.Errorf("bad release id %q", m.ID)
	case m.Device == "":
		return errors.New("manifest has no device")
	case len(m.OSVersions) == 0:
		return errors.New("manifest has no os_versions")
	case m.Created.IsZero():
		return errors.New("manifest has no created time")
	case m.Size <= 0:
		return errors.New("manifest has no size")
	case !shaRe.MatchString(m.SHA256):
		return fmt.Errorf("bad sha256 %q", m.SHA256)
	}
	for _, v := range m.OSVersions {
		if v == "" {
			return errors.New("empty os version")
		}
	}
	return nil
}

// SupportsOS reports whether the release was tested on this exact OS version.
func (m *Manifest) SupportsOS(v string) bool { return v != "" && slices.Contains(m.OSVersions, v) }

// Marshal returns the canonical manifest bytes ppsign signs.
func (m *Manifest) Marshal() ([]byte, error) {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// ParseManifest decodes and validates manifest bytes. Only call it on bytes
// whose signature has already been checked.
func ParseManifest(b []byte) (*Manifest, error) {
	var m Manifest
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("parse manifest: %w", err)
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return &m, nil
}

// ---- keys -------------------------------------------------------------

// GenerateKey returns a fresh key pair as PEM.
func GenerateKey() (privPEM, pubPEM []byte, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	p8, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return nil, nil, err
	}
	pk, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return nil, nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: p8}),
		pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pk}), nil
}

// ParsePrivateKey reads a PKCS#8 PEM ed25519 private key.
func ParsePrivateKey(b []byte) (ed25519.PrivateKey, error) {
	blk, _ := pem.Decode(b)
	if blk == nil || blk.Type != "PRIVATE KEY" {
		return nil, errors.New("not a PEM PRIVATE KEY")
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil, err
	}
	priv, ok := k.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("private key is not ed25519")
	}
	return priv, nil
}

// ParsePublicKey reads a PKIX PEM ed25519 public key.
func ParsePublicKey(b []byte) (ed25519.PublicKey, error) {
	blk, _ := pem.Decode(b)
	if blk == nil || blk.Type != "PUBLIC KEY" {
		return nil, errors.New("not a PEM PUBLIC KEY")
	}
	k, err := x509.ParsePKIXPublicKey(blk.Bytes)
	if err != nil {
		return nil, err
	}
	pub, ok := k.(ed25519.PublicKey)
	if !ok {
		return nil, errors.New("public key is not ed25519")
	}
	return pub, nil
}

// LoadPublicKey reads a public key file.
func LoadPublicKey(path string) (ed25519.PublicKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParsePublicKey(b)
}

// LoadPrivateKey reads a private key file.
func LoadPrivateKey(path string) (ed25519.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParsePrivateKey(b)
}

// ---- signatures ---------------------------------------------------------

// Sign returns the .sig file contents for manifest bytes.
func Sign(priv ed25519.PrivateKey, manifest []byte) []byte {
	sig := ed25519.Sign(priv, manifest)
	return []byte(base64.StdEncoding.EncodeToString(sig) + "\n")
}

// ErrBadSignature means the manifest was not signed by the trusted key.
var ErrBadSignature = errors.New("bad signature")

// Verify checks sigFile (base64) over manifest and, only if it is good,
// parses the manifest.
func Verify(pub ed25519.PublicKey, manifest, sigFile []byte) (*Manifest, error) {
	sig, err := base64.StdEncoding.DecodeString(string(bytes.TrimSpace(sigFile)))
	if err != nil || len(sig) != ed25519.SignatureSize {
		return nil, ErrBadSignature
	}
	if !ed25519.Verify(pub, manifest, sig) {
		return nil, ErrBadSignature
	}
	return ParseManifest(manifest)
}
