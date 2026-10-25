#!/usr/bin/env python3
"""Should `make publish` skip? Compare the live latest.json with ours.

    publish-check.py LIVE.json OURS.json

Prints why to skip, or nothing to go ahead. Exit 1 if LIVE is not a
manifest (an Access login page, say), so publishing stops loudly.

Skip when the live release is as new or newer (a re-run of an old CI job, or
a slow one finishing last, must not replace newer code), or when it was
built from the same inputs (a docs-only merge ships nothing).
"""
import json
import sys
from datetime import datetime


def inputs(m):
    return m.get("notes", "").partition(" inputs ")[2].split(" ")[0]


def main():
    try:
        live = json.load(open(sys.argv[1]))
        live_created = datetime.fromisoformat(live["created"])
    except (ValueError, KeyError, TypeError) as e:
        print(f"the live latest.json is not a manifest: {e}", file=sys.stderr)
        return 1
    ours = json.load(open(sys.argv[2]))
    if live_created >= datetime.fromisoformat(ours["created"]):
        print(f"live {live['id']} is as new or newer (created {live['created']}, ours {ours['created']})")
    elif inputs(ours) not in ("", "dirty") and inputs(live) == inputs(ours):
        print(f"live {live['id']} was built from the same inputs ({inputs(ours)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
