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

from brain import paths
from brain.board import Board, append_inbox
from brain.capability_gaps import default_path as gaps_path


def world_dir(world: str | None) -> Path:
    root = paths.state_dir() / "worlds"
    name = world or os.environ.get("DW_WORLD_GUID")
    if name:
        return root / name
    dirs = [d for d in root.glob("*") if d.is_dir()] if root.exists() else []
    if not dirs:
        raise SystemExit(f"no world folders under {root}; pass --world")
    return max(dirs, key=lambda d: (d / "goals.json").stat().st_mtime if (d / "goals.json").exists() else 0)


def _read_board(d: Path) -> Board:
    p = d / "goals.json"
    if not p.exists():
        return Board()
    return Board.model_validate(json.loads(p.read_text(encoding="utf-8")))


def cmd_list(d: Path, as_json: bool) -> int:
    b = _read_board(d)
    rows = [{"id": t.id, "status": t.status, "by": t.by, "task": t.text,
             "step": (t.next_step().title if t.next_step() else None), "collected": t.tallies or None,
             "why": t.end_reason, "current": t.id == b.current} for t in b.tasks]
    if as_json:
        print(json.dumps({"world": d.name, "paused": b.paused, "tasks": rows}, indent=1, ensure_ascii=False))
        return 0
    print(f"board ({d.name}){'  PAUSED: ' + str(b.paused.get('reason')) if b.paused else ''}")
    for r in rows:
        mark = "*" if r["current"] else " "
        extra = "".join(f"  [{k}: {r[k]}]" for k in ("step", "collected", "why") if r[k])
        print(f"{mark} {r['id']}  {r['status']:<14} {r['by']:<16} {r['task']}{extra}")
    pending = d / "board_inbox.jsonl"
    if pending.exists() and pending.stat().st_size > b.inbox_offset:
        print("  (commands waiting in the inbox for the brain to pick up)")
    return 0


def cmd_gaps(as_json: bool) -> int:
    p = gaps_path()
    rows = json.loads(p.read_text(encoding="utf-8")).get("gaps", []) if p.exists() else []
    rows = sorted(rows, key=lambda g: (g.get("kind") == "knowledge", -int(g.get("count") or 0)))  # backlog first
    if as_json:
        print(json.dumps(rows, indent=1, ensure_ascii=False))
        return 0
    for g in rows:
        last = (g.get("examples") or [{}])[-1]
        print(f"{int(g.get('count') or 0):>4}  {g.get('kind', '?'):<10} {g['primitive']:<32} "
              f"{'(tool exists: a claim) ' if g.get('tool_exists') else ''}{last.get('why') or ''}")
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
    print(f"queued for the brain ({d / 'board_inbox.jsonl'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
