package release

import (
	"archive/tar"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Limits for unpacking. A release is glue and config, not a disk image.
const (
	MaxTotalBytes = 512 << 20
	MaxEntries    = 20000
)

// Pack writes srcDir as a reproducible tar.gz: sorted entries, uid/gid 0,
// one fixed mtime, only regular files, dirs and relative in-tree symlinks.
func Pack(srcDir string, w io.Writer, mtime time.Time) error {
	var paths []string
	err := filepath.WalkDir(srcDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == srcDir {
			return nil
		}
		paths = append(paths, p)
		return nil
	})
	if err != nil {
		return err
	}
	sort.Strings(paths)
	gz, _ := gzip.NewWriterLevel(w, gzip.BestCompression)
	tw := tar.NewWriter(gz)
	for _, p := range paths {
		rel, _ := filepath.Rel(srcDir, p)
		rel = filepath.ToSlash(rel)
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		hdr := &tar.Header{Name: rel, ModTime: mtime.UTC().Truncate(time.Second), Format: tar.FormatPAX}
		switch {
		case fi.Mode().IsDir():
			hdr.Typeflag, hdr.Name, hdr.Mode = tar.TypeDir, rel+"/", 0o755
		case fi.Mode().IsRegular():
			hdr.Typeflag, hdr.Size, hdr.Mode = tar.TypeReg, fi.Size(), 0o644
			if fi.Mode()&0o111 != 0 {
				hdr.Mode = 0o755
			}
		case fi.Mode()&fs.ModeSymlink != 0:
			target, err := os.Readlink(p)
			if err != nil {
				return err
			}
			if err := checkLink(rel, target); err != nil {
				return err
			}
			if err := staysInside(srcDir, rel); err != nil {
				return err
			}
			hdr.Typeflag, hdr.Linkname, hdr.Mode = tar.TypeSymlink, target, 0o777
		default:
			return fmt.Errorf("%s: only files, dirs and symlinks go in a release", rel)
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if hdr.Typeflag == tar.TypeReg {
			f, err := os.Open(p)
			if err != nil {
				return err
			}
			_, err = io.Copy(tw, f)
			f.Close()
			if err != nil {
				return err
			}
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gz.Close()
}

// cleanName returns the slash-separated in-tree name, or an error if the
// entry would land outside the tree.
func cleanName(name string) (string, error) {
	n := path.Clean(strings.TrimSuffix(name, "/"))
	if n == "." || n == "" || path.IsAbs(n) || n == ".." || strings.HasPrefix(n, "../") {
		return "", fmt.Errorf("unsafe path %q", name)
	}
	return n, nil
}

// checkLink rejects absolute symlinks and ones that climb out of the tree.
func checkLink(name, target string) error {
	if target == "" || path.IsAbs(target) {
		return fmt.Errorf("symlink %s -> %s: must be relative", name, target)
	}
	j := path.Clean(path.Join(path.Dir(name), target))
	if j == ".." || strings.HasPrefix(j, "../") {
		return fmt.Errorf("symlink %s -> %s: leaves the release", name, target)
	}
	return nil
}

// Extract unpacks a release tar.gz into dst, which must not exist yet.
// Anything that could write outside dst is refused. Symlinks are created
// last, so no entry can be written through one.
func Extract(r io.Reader, dst string) error {
	if err := os.Mkdir(dst, 0o755); err != nil {
		return err
	}
	gz, err := gzip.NewReader(r)
	if err != nil {
		return fmt.Errorf("gunzip: %w", err)
	}
	tr := tar.NewReader(gz)
	type link struct{ name, target string }
	var links []link
	var total int64
	for n := 0; ; n++ {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("tar: %w", err)
		}
		if n >= MaxEntries {
			return errors.New("too many entries")
		}
		name, err := cleanName(hdr.Name)
		if err != nil {
			return err
		}
		out := filepath.Join(dst, filepath.FromSlash(name))
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(out, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			total += hdr.Size
			if total > MaxTotalBytes {
				return errors.New("release too big")
			}
			if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
				return err
			}
			mode := os.FileMode(0o644)
			if hdr.Mode&0o111 != 0 {
				mode = 0o755
			}
			f, err := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
			if err != nil {
				return err
			}
			_, err = io.Copy(f, io.LimitReader(tr, hdr.Size))
			if err == nil {
				err = f.Sync()
			}
			if cerr := f.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				return err
			}
		case tar.TypeSymlink:
			if err := checkLink(name, hdr.Linkname); err != nil {
				return err
			}
			links = append(links, link{name, hdr.Linkname})
		default:
			return fmt.Errorf("%s: entry type %q not allowed", name, hdr.Typeflag)
		}
	}
	for _, l := range links {
		// The lexical check in checkLink only holds if no parent of the
		// link is itself a symlink.
		if err := noLinkInParents(dst, l.name); err != nil {
			return err
		}
		out := filepath.Join(dst, filepath.FromSlash(l.name))
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		if err := os.Symlink(l.target, out); err != nil {
			return err
		}
	}
	// Each link alone stays inside (checkLink), but one can lead through
	// another: d/up -> .., then x -> d/up/.. is the tree's parent.
	for _, l := range links {
		if err := staysInside(dst, l.name); err != nil {
			return err
		}
	}
	return nil
}

// staysInside follows the symlink root/name, and every symlink it leads
// through, one path element at a time, and fails if that ever climbs above
// root. Only paths inside root are looked at. A name that doesn't exist
// (a dangling link) ends the lookups; the rest is checked by name.
func staysInside(root, name string) error {
	dir := strings.Split(path.Dir(name), "/")
	if dir[0] == "." {
		dir = nil
	}
	target, err := os.Readlink(filepath.Join(root, filepath.FromSlash(name)))
	if err != nil {
		return err
	}
	todo := strings.Split(target, "/")
	exists := true
	for hops := 0; len(todo) > 0; {
		c := todo[0]
		todo = todo[1:]
		switch c {
		case "", ".":
			continue
		case "..":
			if len(dir) == 0 {
				return fmt.Errorf("symlink %s -> %s: leads out of the release", name, target)
			}
			dir = dir[:len(dir)-1]
			continue
		}
		dir = append(dir, c)
		if !exists {
			continue
		}
		fi, err := os.Lstat(filepath.Join(append([]string{root}, dir...)...))
		if errors.Is(err, fs.ErrNotExist) {
			exists = false
			continue
		}
		if err != nil {
			return err
		}
		if fi.Mode()&fs.ModeSymlink == 0 {
			continue
		}
		if hops++; hops > 40 {
			return fmt.Errorf("symlink %s: too many links", name)
		}
		t, err := os.Readlink(filepath.Join(append([]string{root}, dir...)...))
		if err != nil {
			return err
		}
		if path.IsAbs(t) {
			return fmt.Errorf("symlink %s leads through an absolute symlink", name)
		}
		dir = dir[:len(dir)-1]
		todo = append(strings.Split(t, "/"), todo...)
	}
	return nil
}

func noLinkInParents(dst, name string) error {
	parts := strings.Split(path.Dir(name), "/")
	cur := dst
	for _, p := range parts {
		if p == "." {
			continue
		}
		cur = filepath.Join(cur, p)
		fi, err := os.Lstat(cur)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if fi.Mode()&fs.ModeSymlink != 0 {
			return fmt.Errorf("symlink %s sits under another symlink", name)
		}
	}
	return nil
}
