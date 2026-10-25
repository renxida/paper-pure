#!/usr/bin/env python3
"""Stand-in for the tablet's rm-sync in the local proof: lay out the sync v3
blobs a tablet uploads for the notebooks in a xochitl folder.

  tablet-sync.py XOCHITL OLD_ROOT_INDEX OUT_DIR    prints the new root index's hash

OUT_DIR gets one file per blob, named by its hash: each file (sha256 of its
bytes), one index per notebook, and a new root index that keeps
OLD_ROOT_INDEX's entries. Index blobs are named the way rm-sync names them on
3.27.2.2 (and rmfakecloud's models.HashEntries): sha256 over the entries'
binary hashes, sorted by name. Schema 3, as the tablet writes it.
"""
import hashlib
import sys
from pathlib import Path


def index(entries):
    """[(hash, type, name, subfiles, size)] -> (blob name, blob bytes)"""
    entries = sorted(entries, key=lambda e: e[2])
    body = "3\n" + "".join(":".join(e) + "\n" for e in entries)
    return hashlib.sha256(b"".join(bytes.fromhex(e[0]) for e in entries)).hexdigest(), body.encode()


def main(xochitl: Path, old_root: Path, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    lines = old_root.read_text().splitlines()
    root = {}
    for ln in lines[2:] if lines[0] == "4" else lines[1:]:  # schema 4 adds a summary line
        if ln:
            e = tuple(ln.split(":"))
            root[e[2]] = e
    for meta in sorted(xochitl.glob("*.metadata")):
        did = meta.stem
        entries = []
        for f in [meta, xochitl / f"{did}.content", *sorted((xochitl / did).glob("*.rm"))]:
            b = f.read_bytes()
            h = hashlib.sha256(b).hexdigest()
            (out / h).write_bytes(b)
            entries.append((h, "0", f.relative_to(xochitl).as_posix(), "0", str(len(b))))
        name, body = index(entries)
        (out / name).write_bytes(body)
        root[did] = (name, "80000000", did, str(len(entries)), str(sum(int(e[4]) for e in entries)))
    name, body = index(list(root.values()))
    (out / name).write_bytes(body)
    print(name)


if __name__ == "__main__":
    main(*map(Path, sys.argv[1:4]))
