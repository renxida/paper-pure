# wishes: feature requests from the tablet

Desiderata row 9. Cedar writes a wish on the tablet; this turns it into a folder Claude can read: the page as a PNG, its metadata, and a draft issue. Claude reads the PNG itself. No handwriting service, no new vendor.

One Python file (`wishes.py`), two pinned libraries: [rmscene](https://github.com/ricklupton/rmscene) to read `.rm` v6 pages and Pillow to draw them.

## Filing a wish (Cedar)

Any of these makes a page a wish:

- Write on any page of a notebook named **Wishes**, or of any notebook inside a folder named **Wishes**.
- Tag a page `wish` (the tag icon at the bottom left of an open notebook), in any notebook.
- Tag a whole notebook `wish`.

Names and tags are case-insensitive. One wish per page is easiest. Write more on a page later and it comes through again as a new revision. Empty pages, deleted pages and anything in the trash are ignored.

## What Claude gets

```
inbox/
  index.json                                   every page picked up: key -> folder, revision, sha256
  2026-10-25-wishes-p1-32a1a76a/               <date written>-<notebook>-p<page>-<page id>
    page.png      the page, 1404x1872, white paper, strokes where the pen went
    page.svg      the same, as vectors
    page.rm       the raw page, so a better renderer can redo it later
    wish.json     notebook, page, why it counts, when written, typed text, sha256
    issue.md      draft issue body (Claude fills in the title and transcription)
  2026-10-25-wishes-p2-f12412d5-r2/            the same page after Cedar added to it
```

A page is keyed by notebook id and page id. `scan` emits it when it is new or its bytes changed, and never again otherwise.

### For Claude: from wish to change

1. Fetch `index.json`. Each folder's issue footer carries `wish <key> r<N>`; search the issues for the key to see what is already filed.
2. Read `page.png` (and any typed text in `issue.md`). Write the title and copy the words as written. Describe sketches in a line. If a word is unclear, ask Cedar; don't guess.
3. File the issue with the transcription only (`gh issue create --body-file issue.md`). The repo is public: never attach `page.png` or `page.rm`.
4. Then the usual loop: a failing test first, the change, rungs 1 and 2, ship over the air. The issue's checklist says so.

## Run it

```sh
cd tools/wishes
make venv      # .venv with the pinned rmscene, Pillow, pytest
make test      # 22 tests, ~20 s, plus shellcheck
make proof     # real rmfakecloud from the server image (make -C ../../server image), ~10 s; HASH_SCHEMA_VERSION=4 too
make emu       # scan the running emulator's notebooks into .inbox-emu/

.venv/bin/python wishes.py scan --rmfakecloud /data/rmfakecloud --inbox /data/pp/wishes [--user EMAIL]
.venv/bin/python wishes.py scan --xochitl ./xochitl --inbox ./inbox     # a copy of the tablet's folder
.venv/bin/python wishes.py render page.rm page.png --svg page.svg
```

`scan` prints one line per new folder on stdout and a summary on stderr. It exits 1 if a blob doesn't match its hash (rmfakecloud mid-write) or the format is unknown; the next run tries again. Options: `--notebook` (default `Wishes`), `--tag` (default `wish`).

## Where it should run (proposal, not built)

On the server, next to rmfakecloud, every 15 minutes:

```sh
wishes.py scan --rmfakecloud /data/rmfakecloud --inbox /data/pp/wishes
```

and ppd serves `GET /pp/wishes/<path>` read-only, the way it serves the release feed. Claude's `pp-claude` token then reads the wish pages and nothing else of Cedar's notes. Claude fetches on a schedule (a daily scheduled task) or when Cedar says "new wish".

What the server lane would add: Python and the two wheels to the image (site-packages is 35 MB; checked in `python:3.13-slim-trixie`, the server's Debian), a loop line in `entrypoint.sh`, and one read-only route in ppd. Not done here: `server/` belongs to another lane.

Alternatives considered: Claude logging in to rmfakecloud (sees every note, so no); the tablet agent uploading wish pages itself (a second copy of the selection logic in Go, so no).

## Handwriting recognition: MyScript or Claude?

rmfakecloud's handwriting recognition is a pass-through for the tablet's own "Convert to text": it signs the tablet's request with your MyScript key (`RMAPI_HWR_APPLICATIONKEY`, `RMAPI_HWR_HMAC`) and forwards it to `cloud.myscript.com` (`/convert/v1/handwriting`, `internal/hwr/client.go`). Using it for wishes would mean a MyScript account (free tier 2,000 recognitions a month, per rmfakecloud's docs), two more secrets, building MyScript's stroke JSON ourselves, and Cedar's handwriting going to one more company.

Claude reading `page.png` needs none of that, and it also reads sketches, arrows and UI mock-ups, which a text recognizer drops. **Verdict: skip MyScript.** It only comes back if Cedar wants the tablet's own "Convert to text" to work, which is a different wish.

## rmscene and rmc on 3.27.2.2

- **rmscene 0.8.0** (latest) reads every real page here: pencil, a second pen, typed text, strokes anchored to text, an empty page. It logs "Some data has not been read" because 3.27's `SceneInfo` block has extra bytes it doesn't know; `paper_size` still reads as 1404x1872 and no block is unreadable. `wishes.py` hides that log line, counts unreadable blocks, and warns in `issue.md` if any appear.
- **rmc 0.3.0** (latest) pins rmscene below 0.7 (installs 0.6.1) and still turns a 3.27.2.2 page into SVG (184 polylines). It has no PNG output (its PDF path needs Inkscape), so we don't use it. Our renderer is about 100 lines.

## Format facts (3.27.2.2, seen in the emulator)

- `.rm` v6 x is centred on the page, y from the top, 1 unit = 1 screen pixel on the Pure: screen x = x + 702.
- Tool ids seen: 14 (`PENCIL_2`, the default) and 17 (`FINELINER_2`).
- On a page with typed text, strokes sit in groups anchored to the "end of text" id (`0xFFFFFFFFFFFF`) with an x origin. rmc's paragraph heights (title 150) put them within 1 unit of xochitl.
- `.content` (`formatVersion` 2): `cPages.pages[]` has `id`, `idx.value` (fractional order key), `modifed` (sic, ms) and `deleted`; `pageTags` is `[{name, pageId, timestamp}]`; `tags` is the notebook's tags.
- A new empty page gets a 424-byte `.rm` once visited, so "blank" means "no strokes and no text", not "no file".
- rmfakecloud keeps sync in `DATADIR/users/<email>/sync/`. `root` holds the root index's name. A file blob is named by the sha256 of its bytes. An **index blob is named by sha256 over its entries' binary hashes sorted by name**, not by its own bytes. Root index schema 3 by default, 4 with `HASH_SCHEMA_VERSION=4` (adds a `0:.:<count>:<size>` line). Document indexes are schema 3.

## Status

### Verified (Oct 25 2026, this container)

- **Real pages from the emulator.** In `emu/` (stock 3.27.2.2 under qemu) I made a notebook named "Wishes" with the on-screen keyboard and drew "ADD CLOCK" and a clock with `ppemu draw` at known points (14 strokes). Then page 2 got typed text "Dark mode" (title style), a fineliner underline and a moon. A second notebook, "Notebook", got "BIG ICONS" on page 1, tagged `wish` in the tag panel, and "NO" on page 2, untagged. `ppemu pull` copied them out; they are `testdata/xochitl/` (our strokes, xochitl's file format; 52 KB).
- **Render matches xochitl.** `wishes.py render` on page 1, compared with `ppemu screenshot --scale 1` of the same page (toolbar cropped): 100% of xochitl's dark pixels are within 2 px of ours, and 100% of ours are within 2 px of xochitl's (99.2 to 100% within 1 px). Page 2's strokes, anchored to the typed text, are also 100% within 2 px both ways (98.6% within 1 px; the text itself is excluded because the fonts differ). Proof PNGs: `/tmp/claude-0/-home-user-paper-pure/06f32124-bc97-5f8b-9922-5528a40bd7c7/scratchpad/work-pp-wishes/render-wishes-p1.png` and `render-wishes-p2.png`.
- **`make test`: 22 passed** (~20 s) and shellcheck is clean. The tests cover rendering at the drawn points, anchored strokes, typed text, empty pages, SVG, the three selection rules, a folder named Wishes, deleted, blank and trashed pages, second scans, revisions, `index.json`, rmfakecloud trees in schema 3 and 4 with both index naming schemes, the `--user` filter, a half-written blob (exit 1), highlighter, pages longer than the screen, and the CLI.
- **Mutation check:** 17 mutations on a scratch copy, each one alone: no centring, no text anchors, no anchor x, no blob hash check, no tree hash for indexes, no state, deleted pages kept, no page tags, no notebook tag, no folder walk, no trash check, v4 header not skipped, blank pages emitted, no revision bump, case-sensitive tags, errors not caught, page order ignored. Every one makes a test fail. The first run missed "blank pages emitted", so `test_erased_page_is_skipped_until_written_again` was added.
- **`make proof` against real rmfakecloud: PASS 10**, with both `HASH_SCHEMA_VERSION=3` and `=4`. It runs rmfakecloud 3c6de006 from `pp-server:local` on 127.0.0.1:3094, creates a user, logs in through `/ui/api/login`, uploads both notebooks as `.rmdoc` through `/ui/api/documents/upload`, and checks that `/ui/api/documents` lists both. Then it scans rmfakecloud's DATADIR. Result: the same 3 pages with the same sha256 as scanning the xochitl folder, PNGs at 1404x1872, and a second scan with nothing new. Teardown leaves no `pp-wishes-*` container. The first run caught a real bug: index blobs are not named by their own sha256 (see Format facts).
- **Live in the emulator** (`make emu`, which is `ppemu pull` then scan): first 3 new; then nothing new; tagging Notebook p2 `wish` on the tablet gave 1 new (`notebook-p2`); drawing a star on Wishes p2 gave `wishes-p2-f12412d5-r2` with `previous` set. Adding an empty page 3 to Wishes gave "1 blank" and no folder.
- In a `python:3.13-slim-trixie` container (Debian 13.7, Python 3.13.17), `pip install rmscene==0.8.0 pillow==13.0.0` and then a scan of the fixtures gave the same 3 wishes. site-packages is 35 MB.
- Without the libraries, `python3 wishes.py render …` prints `run make venv` and exits 1.

### Not verified

- **Real tablet sync.** The proof fills rmfakecloud through its `.rmdoc` upload, which writes the tree with rmfakecloud's own code. A tablet writes through sync v3 PUTs from rm-sync. The tree format is the same by design, and the code accepts index blobs named either way, but no tablet or emulator rm-sync has synced here (the emulator has no network or sync).
- When the tablet syncs a page (on close, or periodically while open), so how fresh a wish is.
- Running on the server: no Python in `pp-server`, no ppd route, no schedule, no scheduled task for Claude.
- Highlighter, shader, eraser and colours on real pages: only synthetic strokes. Eraser strokes are painted white; whether 3.27 still stores erase-area strokes is unknown.
- Paper sizes other than 1404x1872. `paper_size` is read, so a Paper Pro page (1620x2160) should work, but none was tried.
- Claude transcribing real handwriting. The test pages use block capitals drawn by script.
- Page templates (lines, grid) are not drawn; the PNG is white paper.

### Open questions for Cedar

- **Public issues.** The repo is public, so an issue made from a wish is public. Post the transcription only (the plan), keep wishes in a private tracker, or keep the repo private?
- **Where it runs.** Server-side scan plus a read-only `/pp/wishes/` for the `pp-claude` token (recommended), at about 35 MB plus Python in the image. OK, or rather run it elsewhere?
- **Which marker:** the Wishes notebook, the `wish` page tag, or both (both work now)? Fewer rules is simpler; I'd keep both, since they cost 3 lines.
- **Revisions.** Writing more on a picked-up page makes `-r2`, and Claude updates the same issue. Or should a page be frozen once picked up, with new wishes going on a new page?
- **Fixtures.** `testdata/` holds notebooks drawn in the emulator: our strokes in xochitl's format, no reMarkable code. OK to keep in the repo?
- **Emulator state.** "Wishes" (3 pages) and "Notebook" (2 pages) are left on the shared emulator (`pp-emu-home`) so `make emu` has something to scan. Wipe them with `ppemu reset` if they get in the way.
