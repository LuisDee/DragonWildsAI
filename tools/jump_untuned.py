"""Jump landings in real (brain-run) play, the untuned figure beside the jump course's (read only; no game, no model).

  .venv\\Scripts\\python.exe -m tools.jump_untuned                 # periods of 2026-11-17 (run-up, judge, standstill)
  .venv\\Scripts\\python.exe -m tools.jump_untuned --since 2026-11-14T00:00:00Z

Counting is travel_ladder.jump_course_summary's, per path (tools/jump_stats.py): a path with a jump up
(jump_stats.jump_path), with a strike (a landing judged missed: path.miss), with a real fall (any jump-up edge a strike
under rule C: jump_stats.strike_under(o, 3)). Only the client log's paths inside a brain session (a logs/brain-live-*.jsonl
file's first to last stamped row, +30 s) are counted, and none inside a jump course window (travel_ladder.jsonl labels
`jumpcourse-*`, first row - 120 s to last row's end + 60 s). Paths of one session are not independent: read the
intervals as a lower bound on the uncertainty.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from collections import Counter

from tools import jump_stats as J
from tools.ab import wilson

ROOT = J.ROOT
LADDER = ROOT / "logs" / "evals" / "travel_ladder.jsonl"
# the boundaries: git commit stamps (the client hot-loads move.lua; the first log line each change writes agrees)
RUNUP = "2026-11-17T18:33:04Z"        # 3932462 run-up points at the landing ("turning to the landing first" 18:33:34Z)
JUDGE_OVER = "2026-11-17T18:51:57Z"   # 874f73d why=over (first why=over 18:52:45Z)
JUDGE_ALL = "2026-11-17T19:16:14Z"    # efd12e3 why=above: the whole judge (874f73d, ee6a78b, efd12e3)
STANDSTILL = "2026-11-17T19:56:52Z"   # 8adf80f press from a near standstill (first "slowing for a jump up" 20:25:36Z)
P0_SINCE = J.COMMIT_61412A5           # the planner as it is since 61412a5


def brain_spans(since_ts: float) -> list[tuple[float, float, str]]:
    out = []
    for f in sorted(glob.glob(J.BRAIN_GLOB)):
        if os.path.getmtime(f) < since_ts:
            continue
        lo = hi = None
        with open(f, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                if not ln.startswith('{"ts"'):
                    continue
                try:
                    t = float(json.loads(ln)["ts"])
                except (ValueError, KeyError, TypeError):
                    continue
                lo = t if lo is None else min(lo, t)
                hi = t if hi is None else max(hi, t)
        if lo is not None and hi >= since_ts:
            out.append((lo - 2.0, hi + 30.0, os.path.basename(f)))
    return out


def course_spans() -> list[tuple[float, float, str]]:
    span: dict[str, list[float]] = {}
    try:
        fh = open(LADDER, encoding="utf-8", errors="replace")
    except OSError:
        return []
    with fh:
        for ln in fh:
            try:
                r = json.loads(ln)
            except ValueError:
                continue
            lab, t = str(r.get("label")), r.get("ts")
            if not lab.startswith("jumpcourse") or not isinstance(t, (int, float)):
                continue
            s = float(r.get("s") or 0)
            x = span.setdefault(lab, [t, t + s])
            x[0], x[1] = min(x[0], t), max(x[1], t + s)
    return [(a - 120.0, b + 60.0, k) for k, (a, b) in span.items()]


def inside(t: float, spans) -> str | None:
    for lo, hi, name in spans:
        if lo <= t <= hi:
            return name
    return None


def ci(k: int, n: int) -> str:
    if not n:
        return f"{k} of 0"
    lo, hi = wilson(k, n)
    return f"{k} of {n} = {100 * k / n:.0f} % (95 %: {100 * lo:.0f} to {100 * hi:.0f} %)"


def tally(paths: list[J.Path_], verdicts: list[dict]) -> dict:
    jp = [p for p in paths if J.jump_path(p)]
    strike = [p for p in jp if p.miss]
    fall = [p for p in jp if any(J.strike_under(o, 3) for o in J.outcomes([p]))]
    return {"paths": len(paths), "jump_paths": len(jp), "strike": len(strike), "fall": len(fall),
            "verdicts": Counter(v["verdict"] for v in verdicts),
            "why": Counter(f"{v['verdict']}/{v.get('why')}" for v in verdicts),
            "fast_press": sum(1 for v in verdicts if isinstance(v.get("v0h"), float) and v["v0h"] > 100
                              and v.get("act") == "jump" and (v.get("rise") or 0) > 0),
            "sessions": Counter(p._session for p in paths if J.jump_path(p)),
            "strike_at": [J.iso(p.ts) for p in strike], "fall_at": [J.iso(p.ts) for p in fall]}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--since", default=P0_SINCE)
    ap.add_argument("--until", default="9")
    ap.add_argument("--outside", action="store_true",
                    help="count the paths outside every brain session and course window instead (harness walks: a trial's "
                         "walk to its start place, fixtures); model-free but not tuned")
    a = ap.parse_args()
    since_ts = J.epoch(a.since)
    brains, courses = brain_spans(since_ts), course_spans()
    with open(J.CLIENT_LOG, encoding="utf-8", errors="replace") as fh:
        lines = [ln for ln in fh if ln[:20] >= a.since and ln[:20] <= a.until]
    paths = J.parse_lines(lines, a.since, a.until)
    J.attach_self_edges(paths, J.load_self_edges())
    verdicts = J.verdict_rows(lines, a.since, a.until)
    kept, dropped_course, dropped_nobrain = [], 0, 0
    for p in paths:
        if inside(p.ts, courses):
            dropped_course += 1
            continue
        s = inside(p.ts, brains)
        if bool(s) == a.outside:
            dropped_nobrain += 1
            continue
        p._session = s or "outside"
        kept.append(p)
    vk = [v for v in verdicts if not inside(J.epoch(v["iso"]), courses)
          and bool(inside(J.epoch(v["iso"]), brains)) != a.outside]
    periods = [(f"before the run-up ({a.since} to {RUNUP})", a.since, RUNUP),
               (f"run-up, before the whole judge ({RUNUP} to {JUDGE_ALL})", RUNUP, JUDGE_ALL),
               (f"whole judge, before the standstill press ({JUDGE_ALL} to {STANDSTILL})", JUDGE_ALL, STANDSTILL),
               (f"after the standstill press ({STANDSTILL} on)", STANDSTILL, "9"),
               (f"after the run-up, all ({RUNUP} on)", RUNUP, "9")]
    print(f"client-log paths {len(paths)}: kept ({'outside brain play' if a.outside else 'brain play'}) {len(kept)}; "
          f"in a jump course window {dropped_course}; left out {dropped_nobrain}")
    for name, lo, hi in periods:
        ps = [p for p in kept if lo <= J.iso(p.ts) < hi]
        vs = [v for v in vk if lo <= v["iso"] < hi]
        t = tally(ps, vs)
        print(f"\n## {name}")
        print(f"paths {t['paths']}; with a jump up {t['jump_paths']}")
        print(f"  with a strike (judged missed): {ci(t['strike'], t['jump_paths'])}")
        print(f"  with a real fall (rule C):     {ci(t['fall'], t['jump_paths'])}")
        print(f"  verdict lines: {dict(t['verdicts'])}; why: {dict(t['why'])}; single jumps up pressed over 100 cm/s: {t['fast_press']}")
        if len(t["sessions"]) <= 8:
            print(f"  jump paths by session: {dict(t['sessions'])}")
        else:
            print(f"  jump paths in {len(t['sessions'])} sessions")
        if t["strike_at"] and len(t["strike_at"]) <= 12:
            print(f"  strikes at {', '.join(t['strike_at'])}")
        if t["fall_at"] and len(t["fall_at"]) <= 12:
            print(f"  falls at {', '.join(t['fall_at'])}")


if __name__ == "__main__":
    main()
