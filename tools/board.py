r"""The task board from the command line (docs/design/director.md section 2.1; main assigns tasks here).

    .venv\Scripts\python.exe -m tools.board add "<what to do, in plain words>" [--first] [--open] [--world W]
    .venv\Scripts\python.exe -m tools.board list [--world W] [--json]
    .venv\Scripts\python.exe -m tools.board cancel <task id> [--reason "..."] [--world W]
    .venv\Scripts\python.exe -m tools.board gaps [--json]

The running brain is the only writer of goals.json: add/cancel append a line to the world's board_inbox.jsonl,
which the brain ingests on its next tick (exactly once). list and gaps only read. The world is --world, else
DW_WORLD_GUID, else the world folder under logs/state/worlds whose goals.json changed last.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from brain import paths, worlds
from brain.board import ENDED, GOALS_NAME, INBOX_NAME, BoardOps, BoardStore, append_inbox
from brain.capability_gaps import GapLog


def world_dir(world: str | None) -> Path:
    root = paths.state_dir() / "worlds"
    name = worlds.sanitize(world or os.environ.get("DW_WORLD_GUID"))
    if name:
        return root / name
    dirs = [d for d in root.glob("*") if d.is_dir()] if root.exists() else []
    if not dirs:
        raise SystemExit(f"no world folders under {root}; pass --world")
    return max(dirs, key=lambda d: (d / GOALS_NAME).stat().st_mtime if (d / GOALS_NAME).exists() else 0)


def cmd_list(d: Path, as_json: bool) -> int:
    store = BoardStore(d, readonly=True)  # never writes, quarantines or creates anything
    b = store.board
    view = BoardOps(store).brief(limit=50)  # the same view the Controller's board() tool shows
    ended = [{"id": t.id, "status": t.status, "by": t.by, "task": t.text, "why": t.end_reason,
              "collected": t.tallies or None} for t in b.tasks if t.status in ENDED][-10:]
    if as_json:
        print(json.dumps({"world": d.name, **view, "ended": ended}, indent=1, ensure_ascii=False))
        return 0
    print(f"board ({d.name}){'  PAUSED: ' + str(b.paused.get('reason')) if b.paused else ''}")
    for r in view["tasks"] + ended:
        mark = "*" if r["id"] == b.current else " "
        extra = "".join(f"  [{k}: {r[k]}]" for k in ("step", "collected", "why", "asked") if r.get(k))
        print(f"{mark} {r['id']}  {r['status']:<14} {r['by']:<16} {r['task']}{extra}")
    pending = d / INBOX_NAME
    if pending.exists() and pending.stat().st_size > b.inbox_offset:
        print("  (commands waiting in the inbox for the brain to pick up)")
    return 0


def cmd_gaps(as_json: bool) -> int:
    rows = GapLog().backlog()  # what to build next, most counted first (claims about existing tools left out)
    if as_json:
        print(json.dumps(rows, indent=1, ensure_ascii=False))
        return 0
    for g in rows:
        last = (g.get("examples") or [{}])[-1]
        print(f"{int(g.get('count') or 0):>4}  {g.get('kind', '?'):<10} {g['primitive']:<32} {last.get('why') or ''}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="tools.board", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("text")
    a.add_argument("--first", action="store_true", help="put it next, before the queue")
    a.add_argument("--open", action="store_true", help="an open-ended task (no fixed end)")
    a.add_argument("--world")
    lst = sub.add_parser("list")
    lst.add_argument("--world")
    lst.add_argument("--json", action="store_true")
    c = sub.add_parser("cancel")
    c.add_argument("id")
    c.add_argument("--reason", default="")
    c.add_argument("--world")
    g = sub.add_parser("gaps")
    g.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if args.cmd == "gaps":
        return cmd_gaps(args.json)
    d = world_dir(args.world)
    if args.cmd == "list":
        return cmd_list(d, args.json)
    d.mkdir(parents=True, exist_ok=True)
    if args.cmd == "add":
        append_inbox(d, {"op": "add", "text": args.text, "when": "next" if args.first else "later",
                         "kind": "open" if args.open else "specific"})
    else:
        append_inbox(d, {"op": "cancel", "id": args.id, "reason": args.reason})
    print(f"queued for the brain ({d / INBOX_NAME})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
