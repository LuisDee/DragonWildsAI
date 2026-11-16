"""The failure ledger: every failed live run gets ONE row naming the first thing that went wrong, so fixes go by count
and not by whichever cause the last run showed (docs/RETRO-2026-11-16-workflow.md; the error-analysis loop of
hamel.dev/blog/posts/evals-faq: note the first failure of each trace, group, count, fix the biggest).

    .venv\\Scripts\\python.exe -m tools.failure_ledger scan --since 20261116     # add the failed quest runs not in it yet
    .venv\\Scripts\\python.exe -m tools.failure_ledger tag RUN [RUN ...] --class harness --cause "..." [--void] [--fix abc1234]
    .venv\\Scripts\\python.exe -m tools.failure_ledger report                    # causes by count, open ones first

class: model (he chose wrong), skill (a body tool failed or was slow), harness (the run or the grader was at fault),
game (the game did something we do not understand yet), unknown. --void: the run was the harness's fault and says
nothing about him; a void run is left out of every pass rate and streak (tools/quest_run.py rates). The ledger is
docs/failure_ledger.jsonl (committed: logs/ is not).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "docs" / "failure_ledger.jsonl"
CLASSES = ("model", "skill", "harness", "game", "unknown")


def rows(path: Path | None = None) -> list[dict]:
    path = path or LEDGER  # read at call time: tests point LEDGER elsewhere
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _write(rs: list[dict], path: Path | None = None) -> None:
    (path or LEDGER).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rs), encoding="utf-8", newline="\n")


def voided(path: Path | None = None) -> set[str]:
    """The runs that say nothing about him (the harness's fault): left out of every rate and streak."""
    return {r["run"] for r in rows(path) if r.get("void")}


def first_wrong(rec: dict, v: dict) -> tuple[float, str]:
    """(seconds into the run, what) of the first thing that went wrong in a failed run: the earliest miss or stand
    over 5 s of a bar it failed (one miss is inside the bar: alone it is not what failed the run), else why it ended
    undone, else the bar it missed. Numbers are left out of `what` so alike failures group under one name."""
    bars = v.get("bars") or {}
    ev = []
    if not bars.get("misses", True) or not rec.get("done"):
        ev += [(float(m.get("t") or 0), f"miss: {m['tool']} {m.get('reason')}") for m in v.get("misses") or []]
    if not bars.get("stands", True):
        ev += [(float(i.get("from") or 0), "stand over 5 s" + (" to the end" if i.get("to_end") else ""))
               for i in rec.get("idle_over_5s") or []]
    if ev:
        return min(ev)
    wall = float(rec.get("wall_s") or 0)
    if not rec.get("done"):
        return wall, f"not done: {rec.get('ended')}"
    return wall, "bar: " + ", ".join(k for k, ok in bars.items() if not ok)


def scan(recs: list[dict], verdict, not_counted, since: str = "", path: Path | None = None) -> list[dict]:
    """Add one row for each failed, counted run that has none yet; returns the new rows."""
    have = rows(path)
    seen = {r["run"] for r in have}
    new = []
    for rec in recs:
        if rec["run"] < since or rec["run"] in seen or not_counted(rec):
            continue
        v = verdict(rec)
        if v["pass"]:
            continue
        at, what = first_wrong(rec, v)
        new.append({"run": rec["run"], "item": f"quest: {rec.get('quest')}", "character": rec.get("character"),
                    "checkpoint": rec.get("checkpoint"), "bars": [k for k, ok in v["bars"].items() if not ok],
                    "at_s": round(at, 1), "first_wrong": what, "class": None, "cause": None, "void": False, "fix": None})
    if new:
        _write(have + new, path)
    return new


def tag(runs: list[str], cls: str | None, cause: str | None, void: bool, fix: str | None, path: Path | None = None) -> int:
    rs = rows(path)
    hit = [r for r in rs if r["run"] in runs]
    for r in hit:
        r.update({k: x for k, x in (("class", cls), ("cause", cause), ("fix", fix)) if x})
        r["void"] = r.get("void") or void
    _write(rs, path)
    return len(hit)


def counts(rs: list[dict]) -> list[dict]:
    """Causes by count, the ones with no fix first: [{class, cause, n, open, items, runs}]. An untagged row groups
    under what first went wrong in it."""
    by: dict[tuple, dict] = {}
    for r in rs:
        key = (r.get("class") or "untagged", r.get("cause") or r.get("first_wrong"))
        g = by.setdefault(key, {"class": key[0], "cause": key[1], "n": 0, "open": 0, "void": 0, "items": Counter(), "runs": []})
        g["n"] += 1
        g["open"] += 0 if r.get("fix") else 1
        g["void"] += 1 if r.get("void") else 0
        g["items"][re.sub(r"^quest: ", "", str(r.get("item")))] += 1
        g["runs"].append(r["run"])
    return sorted(by.values(), key=lambda g: (-g["open"], -g["n"]))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--since", default="", help="only runs from this run id on (20261116)")
    t = sub.add_parser("tag")
    t.add_argument("runs", nargs="+")
    t.add_argument("--class", dest="cls", choices=CLASSES)
    t.add_argument("--cause")
    t.add_argument("--void", action="store_true")
    t.add_argument("--fix", help="the commit that fixed it")
    sub.add_parser("report")
    a = ap.parse_args(argv)
    if a.cmd == "scan":
        from tools import quest_run as q
        recs = [json.loads(line) for line in q.OUT.read_text(encoding="utf-8").splitlines() if line.strip()]
        new = scan(recs, q.verdict, q.not_counted, a.since)
        for r in new:
            print(f"{r['run']} {r['item']:<24} {r['at_s']:>6}s {r['first_wrong']}")
        print(f"{len(new)} new row(s); {len(rows())} in the ledger")
    elif a.cmd == "tag":
        print(f"tagged {tag(a.runs, a.cls, a.cause, a.void, a.fix)} row(s)")
    else:
        rs = rows()
        print(f"{len(rs)} failed runs in the ledger, {sum(1 for r in rs if not r.get('class'))} untagged, "
              f"{sum(1 for r in rs if r.get('void'))} void")
        print(f"{'n':>3} {'open':>4}  {'class':<9} cause (items)")
        for g in counts(rs):
            items = ", ".join(f"{k} x{n}" for k, n in g["items"].most_common())
            print(f"{g['n']:>3} {g['open']:>4}  {g['class']:<9} {g['cause']}  ({items}){'  VOID' if g['void'] else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
