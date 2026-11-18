"""Breadth: the untuned pass rate beside the tuned one, for every item of the goal (docs/GOAL-2026-11-17-long-jobs.md,
"Held-out"; CLAUDE.md "Breadth"). Read only: no game, no model, no network.

    .venv\\Scripts\\python.exe -m tools.breadth report
    .venv\\Scripts\\python.exe -m tools.breadth report -n 10 --root C:\\gameserver   # another checkout's logs

What counts as which:
  * untuned: every run of a held-out item, and the first three scored trials of every other item (the first three of
    anything new are scored before its trace is read). A first trial says "scored before trace read" only when its
    record carries first_three_blind (job_run writes it from 2026-11-18 on); older records say "unknown".
  * tuned: an item's scored trials after its first three, the newest n of them (-n, default 10, as the rates tools).
  * left out of both: void runs (the failure ledger's word that the harness was at fault), runs that do not count
    (a head start, an end state that could not be read) and probes (a run to the first step, not to the end). Their
    numbers are printed.

Sources, each read with its own tool's rules (nothing re-implemented): long jobs logs/evals/job_runs.jsonl
(tools/job_run.py scored, item_key, held_out); quests logs/evals/quest_runs.jsonl (tools/quest_run.py trials);
the lookup eval's result files logs/evals/lookup_enemies_eval-*.json (evals/lookup_enemies_eval.py --json: the held-out
half is one number, its cases are never opened here); jump landings, the jump course's summary rows in
logs/evals/travel_ladder.jsonl (tuned: the course the judge was worked on) against brain play in the client log over
the same code (tools/jump_untuned.play: untuned); the travel ladder's other journeys (no held-out set exists).
The held-out ask files are not read beyond data/jobs.json's held_out flag.
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIRST = 3  # the first three trials of anything new: job_run.TRACE_AFTER


@dataclass
class Src:
    """Every file this report reads, under one root (tests point it at a temp directory)."""
    root: Path

    def p(self, *parts: str) -> Path:
        return self.root.joinpath(*parts)

    @property
    def jobs_runs(self) -> Path:
        return self.p("logs", "evals", "job_runs.jsonl")

    @property
    def jobs_doc(self) -> Path:
        return self.p("data", "jobs.json")

    @property
    def quest_runs(self) -> Path:
        return self.p("logs", "evals", "quest_runs.jsonl")

    @property
    def ledger(self) -> Path:
        return self.p("docs", "failure_ledger.jsonl")

    @property
    def ladder(self) -> Path:
        return self.p("logs", "evals", "travel_ladder.jsonl")

    @property
    def lookup_glob(self) -> str:
        return str(self.p("logs", "evals", "lookup_enemies_eval-*.json"))

    @property
    def client_log(self) -> Path:
        return self.p("logs", "client", "client.log")

    @property
    def brain_glob(self) -> str:
        return str(self.p("logs", "brain-live-*.jsonl"))

    @property
    def traversal(self) -> Path:
        return self.p("client_io", "events", "traversal.jsonl")


def _jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def rate(oks: list[bool]) -> str:
    if not oks:
        return "-"
    k = sum(oks)
    return f"{k} of {len(oks)} = {100 * k / len(oks):.0f} %"


def day(run: str) -> str:
    """'20261117-195219' -> '11-17 19:52'."""
    m = re.match(r"(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})", str(run))
    return f"{m[2]}-{m[3]} {m[4]}:{m[5]}" if m else str(run)[:12]


def window(runs: list[str]) -> str:
    if not runs:
        return "-"
    lo, hi = min(runs), max(runs)
    return day(lo) if lo == hi else f"{day(lo)} to {day(hi)}"


def blind_of(rec: dict) -> str:
    if "first_three_blind" not in rec:
        return "blind unknown: record before the flag"
    return "scored before trace read" if rec["first_three_blind"] else "trace read before scoring"


# ------------------------------------------------------------------ split one item's scored trials
def split(item: str, trials: list[tuple[dict, bool]], held_out: bool, n: int) -> dict:
    """trials: (record, passed) oldest first, already without void, uncounted and probes."""
    first = trials[:FIRST]
    untuned = trials if held_out else first
    rest = [] if held_out else trials[FIRST:]
    tuned = rest[-n:] if n else rest
    return {"item": item, "held_out": held_out, "n_scored": len(trials),
            "tuned": [ok for _, ok in tuned], "tuned_runs": [r["run"] for r, _ in tuned],
            "untuned": [ok for _, ok in untuned], "untuned_runs": [r["run"] for r, _ in untuned],
            "first": [{"run": r["run"], "pass": ok, "blind": blind_of(r)} for r, ok in first]}


# ------------------------------------------------------------------ the sources
def jobs(src: Src, void: set[str], n: int) -> dict:
    from tools import job_run as jr
    recs = sorted(jr.all_runs(src.jobs_runs), key=lambda r: r["run"])
    try:
        doc = jr.load_jobs(src.jobs_doc)
    except (OSError, ValueError):
        doc = {"jobs": {}}
    held = {k: bool(v.get("held_out")) for k, v in (doc.get("jobs") or {}).items()}
    by: dict[str, list] = {k: [] for k in held}
    for r, ok in jr.scored(recs, void):
        by.setdefault(jr.item_key(r), []).append((r, ok))
    items = [split(k, ts, held.get(k.split(" / ")[0], False) or any(r.get("held_out") for r, _ in ts), n)
             for k, ts in by.items()]
    left = {"void": 0, "probes (to the first step)": 0, "not counted": 0, "unread end state": 0}
    for r in recs:  # each left-out record once, under the first reason that applies
        if r["run"] in void:
            left["void"] += 1
        elif r.get("until") == "first_step":
            left["probes (to the first step)"] += 1
        elif r.get("not_counted"):
            left["not counted"] += 1
        elif jr.not_counted(r):
            left["unread end state"] += 1
    return {"items": sorted(items, key=lambda i: (i["held_out"], i["item"])), "left": left, "runs": len(recs)}


def quests(src: Src, void: set[str], n: int) -> dict:
    from tools import quest_run as q
    recs = sorted(_jsonl(src.quest_runs), key=lambda r: r["run"])
    by: dict[str, list] = {}
    for r, ok in q.trials(recs, void):
        by.setdefault(q.item_key(r), []).append((r, ok))
    starts = [split(k, ts, False, n) for k, ts in sorted(by.items()) if not ts[0][0].get("checkpoint")]
    steps = [split(k, ts, False, n) for k, ts in sorted(by.items()) if ts[0][0].get("checkpoint")]
    left = {"void": 0, "probes (to a change of step)": 0, "not counted (head start)": 0}
    for r in recs:
        if r["run"] in void:
            left["void"] += 1
        elif r.get("until") != "complete":
            left["probes (to a change of step)"] += 1
        elif q.not_counted(r):
            left["not counted (head start)"] += 1
    return {"items": starts, "steps": steps, "left": left, "runs": len(recs)}


def lookup(src: Src) -> dict:
    files = sorted(glob.glob(src.lookup_glob), key=lambda f: Path(f).stat().st_mtime)
    if not files:
        return {"files": 0}
    f = Path(files[-1])
    try:
        d = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {"files": len(files), "file": f.name, "error": repr(exc)}
    t = (d.get("tuned") or {}).get("summary") or {}
    h = d.get("heldout") or {}
    m = re.search(r"(\d{8})(?:-(\d{6}))?", f.name)
    when = (f"{m[1][4:6]}-{m[1][6:]}" + (f" {m[2][:2]}:{m[2][2:4]}" if m[2] else "")) if m else \
        time.strftime("%m-%d %H:%M", time.gmtime(f.stat().st_mtime))
    return {"files": len(files), "file": f.name, "when": when, "tuned": (t.get("hits"), t.get("n")),
            "heldout": (h.get("hits"), h.get("n")), "heldout_blind": "cases" not in h}


def _iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def jumps(src: Src, since: str | None = None) -> dict:
    """Tuned: the newest jump course run (paths with a jump up, without a landing judged missed). Untuned: brain play
    over the same code, from that run's first leg on, and from the standstill press (8adf80f; older code too, for a
    count when the first window is thin). --jump-since replaces both."""
    from tools import jump_untuned as U
    rows = _jsonl(src.ladder)
    course = [r for r in rows if r.get("summary") and str(r.get("label", "")).startswith("jumpcourse")
              and isinstance(r.get("jump_course"), dict)]
    out: dict = {"course_runs": len(course), "play": []}
    wins: list[tuple[str, str]] = []
    if course:
        c = max(course, key=lambda r: r.get("ts") or 0)
        legs = [r["ts"] for r in rows if r.get("run") == c.get("run") and not r.get("summary")
                and isinstance(r.get("ts"), (int, float))]
        start = min(legs) if legs else c.get("ts")
        jc = c["jump_course"]
        jp, st = int(jc.get("jump_paths") or 0), int(jc.get("strike_paths") or 0)
        out.update(label=c.get("label"), run=c.get("run"), course_start=_iso(start),
                   tuned=[True] * (jp - st) + [False] * st)
        wins = [("brain play, same code", _iso(start)), ("brain play since 8adf80f", U.STANDSTILL)]
    if since:
        wins = [("brain play", since)]
    if wins:
        from tools import jump_stats as J
        try:
            first = min(s for _, s in wins)
            p = U.play(first, "9", False, client_log=src.client_log, brain_glob=src.brain_glob, ladder=src.ladder,
                       traversal=src.traversal)
            for name, s in sorted(wins, key=lambda w: w[1], reverse=True):
                jpaths = [x for x in p["kept"] if J.jump_path(x) and x.ts >= J.epoch(s)]
                out["play"].append({"name": name, "since": s, "untuned": [not x.miss for x in jpaths],
                                    "sessions": len({x._session for x in jpaths}),
                                    "last": _iso(max(x.ts for x in jpaths)) if jpaths else None})
        except Exception as exc:  # a client log this parser cannot read: the row says so, the report goes on
            out["play_error"] = repr(exc)[:160]
    return out


def travel(src: Src) -> dict:
    rows = [r for r in _jsonl(src.ladder) if r.get("summary") and (r.get("n") or 0) > 0
            and not str(r.get("label", "")).startswith(("jumpcourse", "djump"))]
    if not rows:
        return {}
    r = max(rows, key=lambda x: x.get("ts") or 0)
    return {"label": r.get("label"), "run": r.get("run"), "ok": int(r.get("ok") or 0), "n": int(r.get("n") or 0),
            "runs": len(rows)}


# ------------------------------------------------------------------ the report
def collect(src: Src, n: int = 10, jump_since: str | None = None) -> dict:
    from tools import failure_ledger
    void = failure_ledger.voided(src.ledger)
    return {"jobs": jobs(src, void, n), "quests": quests(src, void, n), "lookup": lookup(src),
            "jumps": jumps(src, jump_since), "travel": travel(src), "void_total": len(void), "n": n}


W = (34, 22, 22, 31)


def line(name: str, tuned: str, untuned: str, when: str) -> str:
    return f"  {name:<{W[0]}} {tuned:<{W[1]}} {untuned:<{W[2]}} {when}"


def render(d: dict) -> str:
    n = d["n"]
    out = [f"breadth report, {time.strftime('%Y-%m-%d %H:%MZ', time.gmtime())}",
           f"tuned = an item's scored trials after its first {FIRST} (newest {n or 'all'}); untuned = its first {FIRST}, "
           "and every run of a held-out item",
           f"  {'item':<{W[0]}} {'tuned':<{W[1]}} {'untuned':<{W[2]}} windows (tuned | untuned)"]
    j = d["jobs"]
    out.append("1 long jobs (tools/job_run.py)")
    tun, unt = [], []
    for i in j["items"]:
        name = i["item"] + ("  [held-out]" if i["held_out"] else "")
        out.append(line(name, "-" if i["held_out"] else rate(i["tuned"]), rate(i["untuned"]),
                        f"{window(i['tuned_runs'])} | {window(i['untuned_runs'])}"))
        tun += i["tuned"]
        unt += i["untuned"]
    held = [x for i in j["items"] if i["held_out"] for x in i["untuned"]]
    out.append(line("goal 1, all items", rate(tun), rate(unt), f"held-out alone: {rate(held) if held else '0 runs'}"))
    out.append(f"  left out of {j['runs']} records: " + ", ".join(f"{k} {v}" for k, v in j["left"].items()))
    js = d["jumps"]
    out.append("2 jump landings (paths with a jump up, without a landing judged missed)")
    if js.get("tuned") is not None:
        out.append(line(f"course '{js['label']}'", rate(js["tuned"]), "", f"{js['course_start'][5:16]}"))
    else:
        out.append(line("course", "no course run", "", ""))
    for pl in js.get("play") or []:
        out.append(line(pl["name"], "", rate(pl["untuned"]) if pl["untuned"] else "0 paths",
                        f"from {pl['since'][5:16]}" + (f" to {pl['last'][5:16]}, {pl['sessions']} sessions"
                                                       if pl["last"] else "")))
    if js.get("play_error"):
        out.append(f"  brain play unread: {js['play_error']}")
    lk = d["lookup"]
    out.append("3 lookup for enemies and vaults (evals/lookup_enemies_eval.py, offline)")
    if lk.get("tuned"):
        hb = "held-out cases never shown" if lk["heldout_blind"] else "held-out cases were shown (--show-heldout)"
        out.append(line("tuned half | held-out half", "{} of {}".format(*lk["tuned"]), "{} of {}".format(*lk["heldout"]),
                        f"{lk['when']} ({lk['file']}; {hb})"))
    else:
        out.append(line("tuned half | held-out half", "no result file", "-", lk.get("error", "")))
    out.append("4 capstone, a vault (Rung 6)")
    out.append(line("Crasorak Kara", "-", "0 runs", "its first three runs are held-out scores"))
    qd = d["quests"]
    out.append("quests (parked; tools/quest_run.py, from each quest's start)")
    for i in qd["items"]:
        out.append(line(i["item"], rate(i["tuned"]), rate(i["untuned"]),
                        f"{window(i['tuned_runs'])} | {window(i['untuned_runs'])}"))
    st_t = [x for i in qd["steps"] for x in i["tuned"]]
    st_u = [x for i in qd["steps"] for x in i["untuned"]]
    out.append(line(f"steps from checkpoints ({len(qd['steps'])} items)", rate(st_t), rate(st_u), "per item: quest_run rates"))
    out.append(f"  left out of {qd['runs']} records: " + ", ".join(f"{k} {v}" for k, v in qd["left"].items()))
    tv = d["travel"]
    out.append("travel ladder, rung 1 journeys (no held-out journeys exist)")
    if tv:
        out.append(line(f"newest run '{tv['label']}'", f"{tv['ok']} of {tv['n']} reached", "none recorded", day(tv["run"])))
    out.append(f"\nfirst {FIRST} scored trials of each item (long jobs, then quests):")
    for i in j["items"] + qd["items"]:
        if not i["first"]:
            out.append(f"  {i['item']}: no scored trial yet")
            continue
        out.append(f"  {i['item']}: " + "; ".join(f"{t['run']} {'PASS' if t['pass'] else 'FAIL'} ({t['blind']})"
                                                  for t in i["first"]))
    unknown = sum(1 for i in j["items"] + qd["items"] + qd["steps"] for t in i["first"] if t["blind"].startswith("unknown"))
    out.append(f"unknown whether scored before the trace was read: {unknown} first trials (records before "
               "first_three_blind; job_run writes it from now on, quest_run does not)")
    out.append(f"void runs in the failure ledger, all sources: {d['void_total']}")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    rp = sub.add_parser("report")
    rp.add_argument("-n", type=int, default=10, help="tuned: the newest n trials after the first three (0 = all)")
    rp.add_argument("--root", default=str(ROOT), help="the checkout whose logs and ledger are read")
    rp.add_argument("--jump-since", default=None, help="brain play from this ISO Z time (default: the newest course run)")
    rp.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    d = collect(Src(Path(a.root)), a.n, a.jump_since)
    print(json.dumps(d, default=str, indent=1) if a.json else render(d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
