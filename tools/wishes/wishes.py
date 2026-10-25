#!/usr/bin/env python3
"""wishes: turn handwritten wishes on the tablet into an inbox Claude can read.

A wish is any written page that is either
  - in a notebook named "Wishes" (or inside a folder named "Wishes"),
  - in a notebook tagged "wish", or
  - a page tagged "wish" in any notebook.

  wishes.py scan --rmfakecloud /data/rmfakecloud --inbox DIR   # the server's copy
  wishes.py scan --xochitl DIR --inbox DIR                     # a tablet or emulator folder
  wishes.py render PAGE.rm OUT.png [--svg OUT.svg]             # one page

scan writes one folder per new or changed page (page.png, page.svg, page.rm,
wish.json, issue.md), prints each folder's path, and remembers what it saw in
DIR/.wishes-state.json so the next run only emits what changed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import logging
import os
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

STATE_FILE = ".wishes-state.json"
PAGE_W, PAGE_H = 1404, 1872  # Paper Pure and rM2 page, in .rm units (1 unit = 1 screen px)


# --------------------------------------------------------------------- sources


@dataclass
class Doc:
    id: str
    meta: dict
    content: dict
    files: dict = field(default_factory=dict)  # name inside the doc ("<id>/<page>.rm") -> reader
    user: str = ""

    @property
    def name(self) -> str:
        return self.meta.get("visibleName", "")

    def read(self, name: str) -> bytes | None:
        r = self.files.get(name)
        return r() if r else None


def _json(b: bytes | None) -> dict:
    try:
        return json.loads(b) if b else {}
    except ValueError:
        return {}


def xochitl_docs(root: Path) -> list[Doc]:
    """A tablet's /home/root/.local/share/remarkable/xochitl, copied out."""
    docs = []
    for m in sorted(root.glob("*.metadata")):
        did = m.name[: -len(".metadata")]
        files = {}
        for p in (root / did).glob("*.rm") if (root / did).is_dir() else []:
            files[f"{did}/{p.name}"] = p.read_bytes
        docs.append(Doc(did, _json(m.read_bytes()), _json(_read(root / f"{did}.content")), files))
    return docs


def _read(p: Path) -> bytes | None:
    return p.read_bytes() if p.is_file() else None


def _parse_index(b: bytes) -> list[tuple[str, str, str]]:
    """Sync v3 index blob -> [(hash, type, name)]. Schema 3 or 4 (4 adds a summary line)."""
    lines = b.decode().splitlines()
    if not lines or lines[0] not in ("3", "4"):
        raise ValueError(f"unknown index schema {lines[:1]}")
    out = []
    for ln in lines[2:] if lines[0] == "4" else lines[1:]:
        if ln:
            h, typ, name, _sub, _size = ln.split(":")
            out.append((h, typ, name))
    return out


def rmfakecloud_docs(datadir: Path, user: str | None = None) -> list[Doc]:
    """rmfakecloud's DATADIR: users/<uid>/sync/ holds content-addressed blobs.

    sync/root names the root index; the root index lists one index per
    document; a document index lists its files (metadata, content, pages)."""
    docs = []
    for udir in sorted((datadir / "users").glob("*")):
        sync = udir / "sync"
        if (user and udir.name != user) or not (sync / "root").is_file():
            continue

        def blob(h: str, sync: Path = sync) -> bytes:
            b = (sync / h).read_bytes()
            if hashlib.sha256(b).hexdigest() != h:  # half-written, or not ours
                raise ValueError(f"blob {h} does not match its hash")
            return b

        root = (sync / "root").read_text().strip()
        for h, typ, did in _parse_index(blob(root)):
            if typ != "80000000":
                continue
            entries = {name: fh for fh, _t, name in _parse_index(blob(h))}
            meta_h, content_h = entries.get(f"{did}.metadata"), entries.get(f"{did}.content")
            files = {n: (lambda fh=fh: blob(fh)) for n, fh in entries.items() if n.endswith(".rm")}
            docs.append(Doc(did, _json(blob(meta_h)) if meta_h else {},
                            _json(blob(content_h)) if content_h else {}, files, udir.name))
    return docs


# ------------------------------------------------------------------- selection


def _names(tags) -> set[str]:
    """content.tags is a list of strings or of {"name": ...}."""
    return {(t.get("name", "") if isinstance(t, dict) else str(t)).lower() for t in tags or []}


def pages(doc: Doc) -> list[str]:
    """Live page ids in order. cPages (3.x) sorts by the fractional index idx.value."""
    cp = doc.content.get("cPages")
    if cp:
        live = [p for p in cp.get("pages", []) if not p.get("deleted")]
        return [p["id"] for p in sorted(live, key=lambda p: p.get("idx", {}).get("value", ""))]
    return list(doc.content.get("pages") or [])


def page_modified(doc: Doc, pid: str) -> int:
    for p in (doc.content.get("cPages") or {}).get("pages", []):
        if p.get("id") == pid and p.get("modifed"):  # sic, xochitl's spelling
            return int(p["modifed"])
    return int(doc.meta.get("lastModified") or 0)


def select(docs: list[Doc], notebook: str, tag: str) -> list[tuple[Doc, str, str]]:
    """[(doc, page_id, why)] for every page that counts as a wish."""
    by_id = {d.id: d for d in docs}
    nb, tag = notebook.lower(), tag.lower()

    def in_wishes(d: Doc) -> bool:
        seen = set()
        while d and d.id not in seen:
            seen.add(d.id)
            if d.name.lower() == nb:
                return True
            d = by_id.get(d.meta.get("parent", ""))
        return False

    def trashed(d: Doc) -> bool:
        seen = set()
        while d and d.id not in seen:
            seen.add(d.id)
            if d.meta.get("deleted") or d.meta.get("parent") == "trash":
                return True
            d = by_id.get(d.meta.get("parent", ""))
        return False

    out = []
    for d in docs:
        if d.meta.get("type") != "DocumentType" or trashed(d):
            continue
        whole = "notebook" if in_wishes(d) else "notebook tag" if tag in _names(d.content.get("tags")) else ""
        tagged = {t.get("pageId") for t in d.content.get("pageTags") or [] if str(t.get("name", "")).lower() == tag}
        for pid in pages(d):
            if whole or pid in tagged:
                out.append((d, pid, whole or "page tag"))
    return out


# ------------------------------------------------------------------- rendering

INK = {0: (0, 0, 0), 1: (144, 144, 144), 2: (255, 255, 255), 3: (251, 247, 25), 4: (0, 200, 0),
       5: (255, 192, 203), 6: (78, 105, 201), 7: (179, 62, 57), 8: (125, 125, 125), 9: (251, 247, 25),
       10: (161, 216, 125), 11: (139, 208, 229), 12: (183, 130, 205), 13: (247, 232, 81)}
HIGHLIGHTERS, SHADER, ERASERS = {5, 18}, {23}, {6, 8}
LINE_H = {1: 70, 2: 150, 3: 70, 4: 35, 5: 35, 6: 35, 7: 35}  # paragraph style -> height (rmc's numbers)
BULLET = {4: "- ", 5: "  - ", 6: "[ ] ", 7: "[x] "}
END = 0xFFFFFFFFFFFF  # special anchor ids: END - 1 = top of text, END = bottom of text


@dataclass
class Page:
    strokes: list  # [(tool, rgb, alpha, width, [(x, y), ...])] in page pixels
    text: list  # [(x, baseline y, str, font px)]
    size: tuple
    unreadable: int  # blocks rmscene could not parse; > 0 means the format moved

    @property
    def blank(self) -> bool:
        return not self.strokes and not any(t[2].strip() for t in self.text)


def parse_page(rm: bytes) -> Page:
    from rmscene import scene_items as si
    from rmscene.scene_stream import SceneTree, UnreadableBlock, build_tree, read_blocks
    from rmscene.text import TextDocument

    logging.getLogger("rmscene").setLevel(logging.ERROR)  # "Some data has not been read": newer fields, harmless
    blocks = list(read_blocks(io.BytesIO(rm)))
    tree = SceneTree()
    build_tree(tree, blocks)
    info = getattr(tree, "scene_info", None)
    w, h = (getattr(info, "paper_size", None) or (PAGE_W, PAGE_H)) if info else (PAGE_W, PAGE_H)
    cx = w / 2  # .rm x is centred on the page; y is from the top

    # Strokes can be anchored to typed text. Same rule as rmc: text starts at
    # pos_y - 88 and each paragraph style has a fixed height. On a real 3.27.2.2
    # page this lands within 1 unit of where xochitl put the strokes.
    anchors, text = {}, []
    if tree.root_text is not None:
        t = tree.root_text
        y = t.pos_y - 88
        anchors[END - 1] = y
        for para in TextDocument.from_scene_item(t).contents:
            style = int(para.style.value)
            anchors[para.start_id] = y
            for span in para.contents:
                for k in span.i:
                    anchors[k] = y
            y += LINE_H.get(style, 70)
            text.append((t.pos_x + cx, y, BULLET.get(style, "") + str(para).strip(), 56 if style == 2 else 34))
        anchors[END] = y
    else:
        anchors[END - 1], anchors[END] = 0, h

    strokes = []

    def walk(g, dx: float, dy: float):
        if getattr(g, "anchor_id", None) is not None and g.anchor_origin_x is not None:
            a = g.anchor_id.value
            dx += g.anchor_origin_x.value
            dy += anchors.get(a, anchors.get(a.part2, 0) if a.part1 == 0 else 0)
        for child in g.children.values():
            if isinstance(child, si.Group):
                walk(child, dx, dy)
            elif isinstance(child, si.Line) and child.points:
                tool = int(child.tool)
                rgba = child.color_rgba
                rgb = tuple(rgba[:3]) if rgba else INK.get(int(child.color), (0, 0, 0))
                pts = [(p.x + dx + cx, p.y + dy) for p in child.points]
                width = sum(p.width for p in child.points) / len(child.points) / 4
                if tool in ERASERS:
                    rgb, alpha, width = (255, 255, 255), 255, max(width, 20)
                elif tool in HIGHLIGHTERS or tool in SHADER:
                    alpha, width = 90, max(width, 30)
                else:
                    alpha, width = 255, max(width * child.thickness_scale / 2, 2)
                strokes.append((tool, rgb, alpha, width, pts))

    walk(tree.root, 0.0, 0.0)
    return Page(strokes, text, (w, h), sum(isinstance(b, UnreadableBlock) for b in blocks))


def _canvas(page: Page) -> tuple[float, float, float, float]:
    """(x0, y0, w, h): the page, grown to fit anything drawn outside it."""
    xs = [x for s in page.strokes for x, _ in s[4]] + [0, page.size[0]]
    ys = [y for s in page.strokes for _, y in s[4]] + [0, page.size[1]]
    x0, y0 = min(xs) - 20 if min(xs) < 0 else 0, min(ys) - 20 if min(ys) < 0 else 0
    x1 = max(xs) + 20 if max(xs) > page.size[0] else page.size[0]
    y1 = max(ys) + 20 if max(ys) > page.size[1] else page.size[1]
    return x0, y0, x1 - x0, y1 - y0


def to_png(page: Page, ss: int = 2) -> bytes:
    from PIL import Image, ImageDraw, ImageFont

    x0, y0, w, h = _canvas(page)
    img = Image.new("RGB", (int(w * ss), int(h * ss)), "white")
    for tool, rgb, alpha, width, pts in page.strokes:
        layer = img if alpha == 255 else Image.new("RGBA", img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        xy = [((x - x0) * ss, (y - y0) * ss) for x, y in pts]
        r = width * ss / 2
        fill = rgb if alpha == 255 else rgb + (alpha,)
        if len(xy) > 1:
            d.line(xy, fill=fill, width=max(1, round(width * ss)), joint="curve")
        for x, y in (xy[0], xy[-1]):  # round caps
            d.ellipse((x - r, y - r, x + r, y + r), fill=fill)
        if layer is not img:
            img = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
    d = ImageDraw.Draw(img)
    for x, y, s, size in page.text:
        d.text(((x - x0) * ss, (y - y0 - 4) * ss), s, fill="black", anchor="ls",
               font=ImageFont.load_default(size=size * ss))
    img = img.resize((int(w), int(h)), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, "PNG", optimize=True)
    return out.getvalue()


def to_svg(page: Page) -> str:
    x0, y0, w, h = _canvas(page)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
           f'viewBox="{x0:.0f} {y0:.0f} {w:.0f} {h:.0f}">',
           f'<rect x="{x0:.0f}" y="{y0:.0f}" width="{w:.0f}" height="{h:.0f}" fill="white"/>']
    for _tool, rgb, alpha, width, pts in page.strokes:
        p = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        out.append(f'<polyline points="{p}" fill="none" stroke="rgb{rgb}" stroke-opacity="{alpha / 255:.2f}" '
                   f'stroke-width="{width:.1f}" stroke-linecap="round" stroke-linejoin="round"/>')
    for x, y, s, size in page.text:
        s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        out.append(f'<text x="{x:.0f}" y="{y - 4:.0f}" font-family="sans-serif" font-size="{size}">{s}</text>')
    return "\n".join(out + ["</svg>", ""])


# ------------------------------------------------------------------------ scan


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40] or "untitled"


def _utc(ms: int) -> dt.datetime:
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc)


def issue_md(w: dict) -> str:
    typed = "\n".join(f"> {ln}" for ln in w["text"].splitlines() if ln.strip())
    prev = f" Replaces `{w['previous']}` (the page changed after it was picked up)." if w["previous"] else ""
    return f"""<!-- Draft issue body from tools/wishes. Claude fills in the title and the transcription. -->
# Wish: (one-line title, from the page)

From the tablet: "{w['notebook']}", page {w['page']} of {w['pages']} ({w['why']}), last written {w['written']}.{prev}

## What Cedar wrote

(Claude: read `page.png` next to this file and copy the words here as written. Describe any sketch in a line or two. If a word is unclear, ask Cedar; don't guess.)
{f'''
Typed on the page:

{typed}
''' if typed else ''}
## Done when

- [ ] A failing test shows the wish isn't met yet
- [ ] The change passes rungs 1 and 2 (host, emulator)
- [ ] It reached the tablet over the air

<sub>wish `{w['key']}` r{w['revision']}, picked up {w['picked_up']} from {w['source']}. The page image stays in the inbox; it is not posted.</sub>
"""


def scan(docs: list[Doc], inbox: Path, source: str, notebook: str = "Wishes", tag: str = "wish",
         now: dt.datetime | None = None) -> list[Path]:
    now = now or dt.datetime.now(dt.timezone.utc)
    inbox.mkdir(parents=True, exist_ok=True)
    state_path = inbox / STATE_FILE
    state = _json(_read(state_path))
    new, blank, same = [], 0, 0
    for doc, pid, why in select(docs, notebook, tag):
        rm = doc.read(f"{doc.id}/{pid}.rm")
        if rm is None:  # xochitl writes no .rm for a page nobody wrote on
            blank += 1
            continue
        key, sha = f"{doc.id}/{pid}", hashlib.sha256(rm).hexdigest()
        seen = state.get(key)
        if seen and seen["sha256"] == sha:
            same += 1
            continue
        page = parse_page(rm)
        if page.blank:
            blank += 1
            continue
        order = pages(doc)
        rev = seen["revision"] + 1 if seen else 1
        written = _utc(page_modified(doc, pid))
        name = f"{written:%Y-%m-%d}-{_slug(doc.name)}-p{order.index(pid) + 1}-{pid[:8]}" + (f"-r{rev}" if rev > 1 else "")
        w = {"key": key, "revision": rev, "previous": seen["dir"] if seen else None, "source": source,
             "user": doc.user, "doc_id": doc.id, "notebook": doc.name, "page_id": pid, "why": why,
             "page": order.index(pid) + 1, "pages": len(order), "written": f"{written:%Y-%m-%d %H:%M} UTC",
             "picked_up": f"{now:%Y-%m-%dT%H:%MZ}", "sha256": sha, "strokes": len(page.strokes),
             "text": "\n".join(t[2] for t in page.text).strip(), "unreadable_blocks": page.unreadable}
        tmp = Path(tempfile.mkdtemp(prefix=".tmp-", dir=inbox))
        (tmp / "page.rm").write_bytes(rm)
        (tmp / "page.png").write_bytes(to_png(page))
        (tmp / "page.svg").write_text(to_svg(page))
        (tmp / "wish.json").write_text(json.dumps(w, indent=2) + "\n")
        (tmp / "issue.md").write_text(issue_md(w))
        os.chmod(tmp, 0o755)
        dest = inbox / name
        if dest.exists():  # a crash after the rename but before the state write
            shutil.rmtree(dest)
        tmp.rename(dest)
        state[key] = {"sha256": sha, "revision": rev, "dir": name, "at": w["picked_up"]}
        _write_json(state_path, state)
        new.append(dest)
    print(f"wishes: {len(new)} new, {same} unchanged, {blank} blank", file=sys.stderr)
    return new


def _write_json(path: Path, obj) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


# ------------------------------------------------------------------------- cli


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="wishes", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan", help="emit new or changed wish pages into the inbox")
    src = s.add_mutually_exclusive_group(required=True)
    src.add_argument("--rmfakecloud", type=Path, metavar="DATADIR", help="rmfakecloud's DATADIR (has users/)")
    src.add_argument("--xochitl", type=Path, metavar="DIR", help="a copy of the tablet's xochitl folder")
    s.add_argument("--user", help="only this rmfakecloud user id (folder name under users/)")
    s.add_argument("--inbox", type=Path, required=True)
    s.add_argument("--notebook", default="Wishes", help='notebook or folder name (default "Wishes")')
    s.add_argument("--tag", default="wish", help='page or notebook tag (default "wish")')
    r = sub.add_parser("render", help="render one .rm page")
    r.add_argument("rm", type=Path)
    r.add_argument("png", type=Path)
    r.add_argument("--svg", type=Path)
    a = ap.parse_args(argv)

    if a.cmd == "render":
        page = parse_page(a.rm.read_bytes())
        a.png.write_bytes(to_png(page))
        if a.svg:
            a.svg.write_text(to_svg(page))
        print(f"{a.png}: {len(page.strokes)} strokes, {page.size[0]}x{page.size[1]}"
              + (f", {page.unreadable} unreadable blocks" if page.unreadable else ""))
        return 0

    if a.rmfakecloud and not (a.rmfakecloud / "users").is_dir():
        ap.error(f"{a.rmfakecloud} has no users/ folder; pass rmfakecloud's DATADIR")
    if a.xochitl and not a.xochitl.is_dir():
        ap.error(f"{a.xochitl} is not a folder")
    try:
        if a.rmfakecloud:
            docs, source = rmfakecloud_docs(a.rmfakecloud, a.user), f"rmfakecloud {a.rmfakecloud}"
        else:
            docs, source = xochitl_docs(a.xochitl), f"xochitl {a.xochitl}"
        for p in scan(docs, a.inbox, source, a.notebook, a.tag):
            print(p, flush=True)
    except (OSError, ValueError) as e:  # a blob mid-write, a format we don't know: retry next run
        print(f"wishes: error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
