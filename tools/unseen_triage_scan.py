"""Scratch (2026-11-17 unseen triage): every match of a regex in the brain or client logs after a time, with the rows
around it, each cut short. Read only; no tests.

    .venv\\Scripts\\python.exe -m tools.unseen_triage_scan brain "REGEX" --since 2026-11-17T09:27:08Z [--after 3]
        [--before 0] [--max 20] [--kinds bridge_recv,tool_result] [--cut 300] [--grep REGEX2]

brain: the following rows are the next rows of the same file (optionally only of the listed kinds); a row is shown as
its time, its kind and a cut of the row from the match on (or from its start).
client: the following lines of logs/client/client.log (optionally only lines matching --grep).
"""
from __future__ import annotations

import argparse
import collections
import re
import sys

from tools.unseen import epoch, iso, lines, log_files


def show(at: float, line: str, rx: re.Pattern | None, cut: int) -> str:
    line = line.rstrip("\r\n")
    m = rx.search(line) if rx else None
    start = max(0, m.start() - 60) if m else 0
    kind = re.search(r'"kind": "(\w+)"', line[:200])
    head = f"{iso(at)} {kind.group(1) if kind else ''}"
    return f"{head} | {'...' if start else ''}{line[start:start + cut]}"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log", choices=("brain", "client"))
    ap.add_argument("look")
    ap.add_argument("--since", required=True)
    ap.add_argument("--until")
    ap.add_argument("--after", type=int, default=3)
    ap.add_argument("--before", type=int, default=0)
    ap.add_argument("--max", type=int, default=20)
    ap.add_argument("--kinds", help="following rows only of these kinds (brain)")
    ap.add_argument("--grep", help="following rows only when they match this")
    ap.add_argument("--cut", type=int, default=300)
    ap.add_argument("--count", action="store_true", help="only the count of matches per file")
    a = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    rx = re.compile(a.look)
    since = epoch(a.since)
    until = epoch(a.until) if a.until else float("inf")
    kinds = set(a.kinds.split(",")) if a.kinds else None
    grep = re.compile(a.grep) if a.grep else None
    shown = 0
    per_file = collections.Counter()
    for p in log_files(a.log):
        if p.stat().st_mtime <= since:
            continue
        prev = collections.deque(maxlen=a.before)
        pending = []  # [remaining, ...]
        for at, line in lines(p, a.log):
            if at <= since or at > until:
                continue
            for pnd in pending:
                if pnd[0] > 0:
                    k = re.search(r'"kind": "(\w+)"', line[:200])
                    if (not kinds or (k and k.group(1) in kinds)) and (not grep or grep.search(line)):
                        pnd[0] -= 1
                        print("      +", show(at, line, grep, a.cut))
            pending = [p_ for p_ in pending if p_[0] > 0]
            if rx.search(line):
                per_file[p.name] += 1
                if a.count:
                    continue
                if shown >= a.max:
                    continue
                shown += 1
                print(f"## {p.name}")
                for pat, pl in prev:
                    print("      -", show(pat, pl, None, a.cut))
                print("  MATCH", show(at, line, rx, a.cut))
                if a.after:
                    pending.append([a.after])
            if a.before:
                prev.append((at, line))
    total = sum(per_file.values())
    print(f"total {total} matches in {len(per_file)} files: " + ", ".join(f"{k}={v}" for k, v in per_file.most_common(12)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
