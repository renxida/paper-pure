"""Tests for wishes.py. Run: python -m pytest -q tools/wishes

testdata/xochitl is a real 3.27.2.2 xochitl folder, drawn in the emulator
(emu/, Oct 25 2026) with `ppemu draw` at known screen points:
  "Wishes"   p1  "ADD CLOCK" + a clock (pencil)            -> notebook rule
             p2  typed title "Dark mode", underline, moon   -> notebook rule, text anchors
  "Notebook" p1  "BIG ICONS", page tagged "wish"            -> page tag rule
             p2  "NO", untagged                             -> ignored
"""
import hashlib
import io
import json
import shutil
import sys
from pathlib import Path

import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import wishes  # noqa: E402

X = Path(__file__).parent / "testdata" / "xochitl"
WISHES, NOTEBOOK = "fd462152-8b8e-4a7e-9b33-32f313c35154", "64dbef73-9386-453b-8a0d-7270f9b0af1e"
W_P1, W_P2 = "32a1a76a-7cbf-4063-828d-06e7697a5343", "f12412d5-569f-4688-8a9b-e53c3e2ab887"
N_P1, N_P2 = "46e9adfe-c4e4-43d8-9cd4-b7451d573f1b", "bd65a43b-fbdb-4399-8f3b-6c4eb00b280e"


def png(page):
    return Image.open(io.BytesIO(wishes.to_png(page))).convert("L")


def ink_near(img, x, y, r=3):
    """True if any pixel within r px of (x, y) is dark."""
    return any(img.getpixel((i, j)) < 100 for i in range(x - r, x + r + 1) for j in range(y - r, y + r + 1))


def scan(src, inbox, **kw):
    return wishes.scan(wishes.xochitl_docs(src), inbox, "test", **kw)


# ----------------------------------------------------------------- rendering


def test_render_lands_where_the_pen_went():
    page = wishes.parse_page((X / WISHES / f"{W_P1}.rm").read_bytes())
    assert (len(page.strokes), page.size, page.unreadable, page.text) == (14, (1404, 1872), 0, [])
    img = png(page)
    assert img.size == (1404, 1872)
    # points passed to `ppemu draw` (screen px): A's feet and apex, K's end, the clock
    for x, y in [(260, 440), (305, 300), (350, 440), (1310, 440), (700, 580), (877, 760), (700, 640), (790, 810)]:
        assert ink_near(img, x, y), (x, y)
    for x, y in [(100, 100), (700, 1500), (1300, 1800), (305, 360)]:  # paper, incl. inside the A
        assert not ink_near(img, x, y, 1), (x, y)


def test_render_strokes_anchored_to_typed_text():
    page = wishes.parse_page((X / WISHES / f"{W_P2}.rm").read_bytes())
    assert [t[2] for t in page.text] == ["Dark mode"]
    assert len(page.strokes) == 2 and not page.blank
    img = png(page)
    # underline drawn 240,330 -> 560,328; moon starts at 875,830. Both strokes sit
    # in groups anchored to the end of the text, so this checks the anchor maths.
    for x, y in [(240, 330), (400, 336), (560, 328), (875, 830), (650, 700)]:
        assert ink_near(img, x, y), (x, y)
    assert not ink_near(img, 400, 450, 2)


def test_typed_text_only_page():
    from rmscene import scene_stream

    buf = io.BytesIO()
    scene_stream.write_blocks(buf, scene_stream.simple_text_document("Make the clock bigger"))
    page = wishes.parse_page(buf.getvalue())
    assert page.strokes == [] and not page.blank
    assert [t[2] for t in page.text] == ["Make the clock bigger"]
    assert png(page).getextrema()[0] < 100  # the text is drawn


def test_empty_page_is_blank():
    from rmscene import scene_stream

    buf = io.BytesIO()
    scene_stream.write_blocks(buf, scene_stream.simple_text_document(""))
    assert wishes.parse_page(buf.getvalue()).blank


def test_svg_has_every_stroke():
    page = wishes.parse_page((X / WISHES / f"{W_P1}.rm").read_bytes())
    svg = wishes.to_svg(page)
    assert svg.startswith("<svg") and svg.count("<polyline") == 14


def test_cli_render(tmp_path):
    out = tmp_path / "p.png"
    assert wishes.main(["render", str(X / NOTEBOOK / f"{N_P1}.rm"), str(out), "--svg", str(tmp_path / "p.svg")]) == 0
    assert Image.open(out).size == (1404, 1872) and (tmp_path / "p.svg").exists()


# ------------------------------------------------------------------ selection


def test_scan_picks_notebook_and_tagged_pages(tmp_path):
    new = scan(X, tmp_path)
    names = sorted(p.name for p in new)
    assert names == ["2026-10-25-notebook-p1-46e9adfe", "2026-10-25-wishes-p1-32a1a76a", "2026-10-25-wishes-p2-f12412d5"]
    for d in new:
        assert {f.name for f in d.iterdir()} == {"page.png", "page.svg", "page.rm", "wish.json", "issue.md"}
        w = json.loads((d / "wish.json").read_text())
        assert w["sha256"] == hashlib.sha256((d / "page.rm").read_bytes()).hexdigest()
        assert Image.open(d / "page.png").size == (1404, 1872)
        assert "page.png" in (d / "issue.md").read_text()
    whys = {json.loads((d / "wish.json").read_text())["page_id"]: json.loads((d / "wish.json").read_text())["why"] for d in new}
    assert whys == {W_P1: "notebook", W_P2: "notebook", N_P1: "page tag"}  # N_P2 is not a wish
    assert "> Dark mode" in (tmp_path / "2026-10-25-wishes-p2-f12412d5" / "issue.md").read_text()
    assert not list(tmp_path.glob(".tmp-*"))
    index = json.loads((tmp_path / "index.json").read_text())
    assert {k: v["dir"] for k, v in index.items()} == {f"{WISHES}/{W_P1}": names[1], f"{WISHES}/{W_P2}": names[2], f"{NOTEBOOK}/{N_P1}": names[0]}


def test_second_scan_emits_nothing(tmp_path):
    assert len(scan(X, tmp_path)) == 3
    assert scan(X, tmp_path) == []


def test_changed_page_is_a_new_revision(tmp_path):
    src = tmp_path / "x"
    shutil.copytree(X, src)
    first = scan(src, tmp_path / "inbox")
    shutil.copy(X / NOTEBOOK / f"{N_P2}.rm", src / WISHES / f"{W_P1}.rm")  # Cedar adds to the page
    new = scan(src, tmp_path / "inbox")
    assert [p.name for p in new] == ["2026-10-25-wishes-p1-32a1a76a-r2"]
    w = json.loads((new[0] / "wish.json").read_text())
    assert (w["revision"], w["previous"]) == (2, "2026-10-25-wishes-p1-32a1a76a")
    assert "Replaces `2026-10-25-wishes-p1-32a1a76a`" in (new[0] / "issue.md").read_text()
    assert all(p.exists() for p in first)  # r1 stays


def edit(path, **kv):
    d = json.loads(path.read_text())
    d.update(kv)
    path.write_text(json.dumps(d))


def test_blank_deleted_and_trashed_pages_are_skipped(tmp_path):
    src = tmp_path / "x"
    shutil.copytree(X, src)
    c = json.loads((src / f"{WISHES}.content").read_text())
    c["cPages"]["pages"].append({"id": "blank-page", "idx": {"value": "bc"}})  # no .rm: never written on
    c["cPages"]["pages"][1]["deleted"] = {"timestamp": "1:9", "value": 1}  # p2 deleted
    (src / f"{WISHES}.content").write_text(json.dumps(c))
    edit(src / f"{NOTEBOOK}.metadata", parent="trash")
    assert [p.name for p in scan(src, tmp_path / "inbox")] == ["2026-10-25-wishes-p1-32a1a76a"]


def test_folder_named_wishes_and_notebook_tag(tmp_path):
    src = tmp_path / "x"
    shutil.copytree(X, src)
    (src / "folder-1.metadata").write_text(json.dumps({"type": "CollectionType", "visibleName": "wishes", "parent": ""}))
    edit(src / f"{NOTEBOOK}.metadata", parent="folder-1")
    edit(src / f"{WISHES}.metadata", visibleName="Ideas")
    edit(src / f"{WISHES}.content", tags=[{"name": "Wish", "timestamp": 1}])
    got = {json.loads((d / "wish.json").read_text())["page_id"]: json.loads((d / "wish.json").read_text())["why"]
           for d in scan(src, tmp_path / "inbox")}
    assert got == {N_P1: "notebook", N_P2: "notebook", W_P1: "notebook tag", W_P2: "notebook tag"}


def test_other_names(tmp_path):
    assert scan(X, tmp_path / "a", notebook="Nope", tag="nope") == []
    assert len(scan(X, tmp_path / "b", notebook="Notebook", tag="nope")) == 2


# --------------------------------------------------------------- rmfakecloud


def make_sync(datadir: Path, src: Path, schema: str, uid="u1", index_names="tree") -> Path:
    """Write src (a xochitl folder) the way rmfakecloud stores sync v3:
    users/<uid>/sync/<sha256> blobs, one index per document, a root index, and
    sync/root naming the root index (internal/storage/fs, models/hashtree.go).
    Files are named by sha256 of their bytes; indexes by sha256 over their
    entries' hashes sorted by name ("tree"), or by their bytes ("content")."""
    sync = datadir / "users" / uid / "sync"
    sync.mkdir(parents=True)

    def put(b: bytes, index=False):
        if index and index_names == "tree":
            lines = b.decode().splitlines()
            ents = sorted((ln.split(":") for ln in lines[1 if lines[0] == "3" else 2:] if ln), key=lambda e: e[2])
            h = hashlib.sha256(b"".join(bytes.fromhex(e[0]) for e in ents)).hexdigest()
        else:
            h = hashlib.sha256(b).hexdigest()
        (sync / h).write_bytes(b)
        return h, len(b)

    docs, total = [], 0
    for m in sorted(src.glob("*.metadata")):
        did = m.name[: -len(".metadata")]
        files = [(f"{did}.metadata", m.read_bytes()), (f"{did}.content", (src / f"{did}.content").read_bytes())]
        files += [(f"{did}/{p.name}", p.read_bytes()) for p in sorted((src / did).glob("*.rm"))]
        lines, size = [], 0
        for name, b in files:
            h, n = put(b)
            lines.append(f"{h}:0:{name}:0:{n}")
            size += n
        ih, _ = put(("3\n" + "\n".join(lines) + "\n").encode(), True)
        docs.append(f"{ih}:80000000:{did}:{len(files)}:{size}")
        total += size
    head = "3\n" if schema == "3" else f"4\n0:.:{len(docs)}:{total}\n"
    rh, _ = put((head + "\n".join(docs) + "\n").encode(), True)
    (sync / "root").write_text(rh)
    return sync


@pytest.mark.parametrize("schema,names", [("3", "tree"), ("4", "tree"), ("4", "content")])
def test_rmfakecloud_tree(tmp_path, schema, names):
    make_sync(tmp_path / "data", X, schema, index_names=names)
    a = {(w := json.loads((d / "wish.json").read_text()))["key"]: w["sha256"] for d in scan(X, tmp_path / "a")}
    new = wishes.scan(wishes.rmfakecloud_docs(tmp_path / "data"), tmp_path / "b", "test")
    b = {(w := json.loads((d / "wish.json").read_text()))["key"]: w["sha256"] for d in new}
    assert a == b and len(b) == 3
    assert {json.loads((d / "wish.json").read_text())["user"] for d in new} == {"u1"}


def test_rmfakecloud_user_filter(tmp_path):
    make_sync(tmp_path / "data", X, "3", uid="cedar")
    assert wishes.rmfakecloud_docs(tmp_path / "data", "someone-else") == []
    assert len(wishes.rmfakecloud_docs(tmp_path / "data", "cedar")) == 2


def test_rmfakecloud_bad_blob_fails_the_run(tmp_path, capsys):
    sync = make_sync(tmp_path / "data", X, "3")
    page = (X / WISHES / f"{W_P1}.rm").read_bytes()
    (sync / hashlib.sha256(page).hexdigest()).write_bytes(page[:100])  # half-written
    rc = wishes.main(["scan", "--rmfakecloud", str(tmp_path / "data"), "--inbox", str(tmp_path / "inbox")])
    assert rc == 1 and "does not match its hash" in capsys.readouterr().err


def test_cli_scan_prints_paths(tmp_path, capsys):
    assert wishes.main(["scan", "--xochitl", str(X), "--inbox", str(tmp_path)]) == 0
    out = capsys.readouterr()
    assert len(out.out.split()) == 3 and "3 new" in out.err


def test_erased_page_is_skipped_until_written_again(tmp_path, capsys):
    from rmscene import scene_stream

    src = tmp_path / "x"
    shutil.copytree(X, src)
    buf = io.BytesIO()
    scene_stream.write_blocks(buf, scene_stream.simple_text_document(""))
    (src / WISHES / f"{W_P1}.rm").write_bytes(buf.getvalue())  # an .rm with nothing on it
    assert W_P1[:8] not in " ".join(p.name for p in scan(src, tmp_path / "inbox"))
    assert "1 blank" in capsys.readouterr().err
    shutil.copy(X / WISHES / f"{W_P1}.rm", src / WISHES / f"{W_P1}.rm")
    assert [p.name for p in scan(src, tmp_path / "inbox")] == ["2026-10-25-wishes-p1-32a1a76a"]


def test_highlighter_is_see_through_and_long_pages_grow():
    hl = (18, (251, 247, 25), 90, 30, [(100, 100), (500, 100)])
    pen = (14, (0, 0, 0), 255, 4, [(100, 200), (500, 200), (500, 5000)])
    img = Image.open(io.BytesIO(wishes.to_png(wishes.Page([hl, pen], [], (1404, 1872), 0)))).convert("RGB")
    assert img.size == (1404, 5020)  # grown to fit the stroke that runs off the page
    r, g, b = img.getpixel((300, 100))
    assert r > 200 and g > 200 and b < 230  # a light yellow wash, not ink
    assert img.getpixel((300, 200)) == (0, 0, 0) and img.getpixel((500, 4900))[0] < 50


def test_issue_warns_when_rmscene_skipped_parts():
    w = {"text": "", "previous": None, "notebook": "Wishes", "page": 1, "pages": 1, "why": "notebook",
         "written": "x", "key": "a/b", "revision": 1, "picked_up": "y", "source": "z", "unreadable_blocks": 2}
    assert "2 part(s) of this page" in wishes.issue_md(w)
    assert "part(s)" not in wishes.issue_md(dict(w, unreadable_blocks=0))


def test_real_empty_page_is_blank():
    # xochitl 3.27.2.2 writes a 424-byte .rm for a new page nobody wrote on
    page = wishes.parse_page((X.parent / "empty-page.rm").read_bytes())
    assert page.blank and page.unreadable == 0
