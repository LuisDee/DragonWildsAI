"""Jump landings of the local planner, read from the client log (read only; no game, no model).

  .venv\\Scripts\\python.exe -m tools.jump_stats report                       # 14 Nov to now, split at 61412a5
  .venv\\Scripts\\python.exe -m tools.jump_stats report --since 2026-11-17T13:56:00Z
  .venv\\Scripts\\python.exe -m tools.jump_stats windows                      # s29 + s30 against s31 (same checkpoint)
  .venv\\Scripts\\python.exe -m tools.jump_stats places --top 10              # the worst places (5 m clusters)
  .venv\\Scripts\\python.exe -m tools.jump_stats course                       # jump-up spots for a model-free course
  .venv\\Scripts\\python.exe -m tools.jump_stats attacks                      # attacks that ended path_blocked (brain logs)
  .venv\\Scripts\\python.exe -m tools.jump_stats verdicts --since <iso>       # the per-jump line, once move.lua writes it

Sources
  logs/client/client.log            the mover's own lines (ISO second stamps):
      "move: local plan #N (why) at (x,y,z) toward (x,y,z)"     cm, capsule centre (feet = z - 88)
      "move: local path N pts [acts] ... stand=S ... pts=x,y,z ..."  m; x, y rounded to 1 m, z (floor) to 0.1 m
      "move: landed A cm from the jump's point (allowed B) and C cm off its height (allowed D)"  (since b59903c)
      "move: jump landing missed; re-planning from here" / "... the third failed jump of this approach ..."
      "move: jump takeoff not confirmed grounded; ..." / "move: taking off N cm from the jump's start ..."
      "move: stuck n=.. me=(x,y,z) ..."                            cm, a position sample
  client_io/events/traversal.jsonl  {"type":"self_edge","move":"jump|djump|drop","from":[..],"to":[..]} per landed jump
  logs/brain-live-*.jsonl           tool_result rows of `attack` (path_blocked, data.move.lp_fail)

The act letters of a path are the first letter of each point's act ("w" walk, "j" jump, "d" djump OR drop, "s"
superjump) or "l" for a leap. A "d" that rises is a double jump; one that falls is a drop.

One path holds at most one missed landing: a miss drops the path and plans again (move.lua steer_typed_jump). The
miss is put on the first jump-up edge of the path that has no self_edge (no confirmed landing). The legacy count of
PROGRESS 2026-11-17 13:56Z put it on the first edge lettered j or d that rises; both are reported.
"""
from __future__ import annotations

import argparse
import calendar
import glob
import json
import math
import re
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLIENT_LOG = ROOT / "logs" / "client" / "client.log"
TRAVERSAL = ROOT / "client_io" / "events" / "traversal.jsonl"
BRAIN_GLOB = str(ROOT / "logs" / "brain-live-*.jsonl")

HALF_H_CM = 88            # capsule half-height (DISCOVERIES: measured envelope)
STEP_CM = 45              # MaxStepHeight
STEP_TOL_CM = 65          # move.lua step_tol: max(step + 20, 60)
JUMP_CM = 164             # data/envelopes/Claude.json jump_up_m.stand
SLOPE_K = 0.9             # localplan: |dz| <= 0.9 x run is a provisional walk (a slope)
COMMIT_61412A5 = "2026-11-17T13:55:55Z"   # git: 2026-11-17 14:55:55 +0100
COMMIT_B59903C = "2026-11-16T10:34:33Z"   # the "landed" line exists from here
DEFAULT_SINCE = "2026-11-14T00:00:00Z"
# windows of Ratcatcher from rc_chain2 (PROGRESS 2026-11-17; brain log names are local time, UTC+1)
WINDOWS = {
    "s29": ("2026-11-17T11:39:00Z", "2026-11-17T12:07:00Z"),
    "s30": ("2026-11-17T12:14:00Z", "2026-11-17T12:47:00Z"),
    "s31": ("2026-11-17T13:56:00Z", "2026-11-17T14:25:00Z"),
}

TS_RX = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (.*)$")
PLAN_RX = re.compile(r"^move: local plan #(\d+) \(([^)]*)\) at \((-?\d+),(-?\d+),(-?\d+)\) toward \((-?\d+),(-?\d+),(-?\d+)\)")
PATH_RX = re.compile(r"^move: local path (\d+) pts \[(\w*)\].*?stand=([\d.]+)s.*? pts=(.*)$")
LANDED_RX = re.compile(r"^move: landed (\d+) cm from the jump's point \(allowed (\d+)\) and (\d+) cm off its height \(allowed (\d+)\)")
MISS_RX = re.compile(r"^move: (jump landing missed; re-planning from here|unreachable: no_route \(the third failed jump of this approach: jump landing missed\))")
TAKEOFF_FAIL_RX = re.compile(r"^move: jump takeoff not confirmed grounded; re-planning")
ROUTE_CHANGED_RX = re.compile(r"^move: jump route changed; re-planning")
TAKING_OFF_RX = re.compile(r"^move: taking off (\d+) cm from the jump's start")
STUCK_RX = re.compile(r"^move: stuck n=\d+ moved=\d+cm d=\d+ src=\w+ me=\((-?\d+),(-?\d+),(-?\d+)\)")
TRIP_RX = re.compile(r"^move: (trip: |arrived|unreachable|failed|stopped)")


def epoch(iso: str) -> float:
    return float(calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")))


def iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


@dataclass
class Edge:
    k: int                 # index of the landing point in the path (0-based; the takeoff point is k - 1)
    letter: str
    a: tuple               # takeoff point (m, floor)
    b: tuple               # landing point (m, floor)

    @property
    def rise_cm(self) -> float:
        return round((self.b[2] - self.a[2]) * 100.0, 1)

    @property
    def run_cm(self) -> float:
        return round(math.hypot(self.b[0] - self.a[0], self.b[1] - self.a[1]) * 100.0, 1)

    @property
    def kind(self) -> str:
        if self.letter == "d":
            return "djump" if self.rise_cm > 0 else "drop"
        return {"j": "jump", "l": "leap", "s": "superjump", "w": "walk"}.get(self.letter, self.letter)

    @property
    def is_jump_up(self) -> bool:
        return self.kind in ("jump", "leap", "superjump", "djump") and self.rise_cm > 0

    @property
    def slope_range(self) -> bool:
        """A rise the planner would first offer as a slope walk (|dz| <= 0.9 x run): a jump here exists because
        verify() found the profile step-like (the midpoint test, or the quarters of 61412a5) or a hop."""
        return abs(self.rise_cm) <= SLOPE_K * self.run_cm

    def band(self) -> str:
        c = self.rise_cm
        return "under 65 cm" if c < 65 else ("65 to 120 cm" if c < 120 else ("120 to 165 cm" if c <= 165 else "over 165 cm"))


@dataclass
class Path_:
    ts: float
    acts: str
    pts: list
    stand_s: float
    at: tuple | None = None          # plan start, capsule centre, cm
    why: str = ""
    end_ts: float | None = None
    miss: dict | None = None         # {"ts", "third", "landed": (off, allowed, dz, tol) | None, "after": pos | None}
    takeoff_fail: int = 0
    route_changed: int = 0
    taking_off: list = field(default_factory=list)
    landed_keys: set = field(default_factory=set)   # (from, to) rounded, confirmed by self_edge

    def edges(self) -> list[Edge]:
        out = []
        for k in range(1, min(len(self.pts), len(self.acts))):
            out.append(Edge(k, self.acts[k], self.pts[k - 1], self.pts[k]))
        return out

    def jump_ups(self) -> list[Edge]:
        return [e for e in self.edges() if e.is_jump_up]

    def legacy_first(self) -> Edge | None:
        for e in self.edges():
            if e.letter in "jd" and e.rise_cm > 0:
                return e
        return None

    def miss_edge(self) -> Edge | None:
        """The jump-up edge the miss belongs to: the first with no confirmed landing; with the landed line and a
        position sample just after, the edge whose landing point lies at the logged distance is preferred."""
        if not self.miss:
            return None
        cands = [e for e in self.jump_ups() if key(e.a, e.b) not in self.landed_keys]
        if not cands:
            cands = [e for e in self.edges() if e.letter in "jdls" and key(e.a, e.b) not in self.landed_keys]
        if not cands:
            return None
        lan, pos = self.miss.get("landed"), self.miss.get("after")
        if lan and pos and len(cands) > 1:
            return min(cands, key=lambda e: abs(math.hypot(pos[0] - e.b[0] * 100, pos[1] - e.b[1] * 100) - lan[0]))
        return cands[0]

    def standing_start(self, e: Edge) -> bool:
        """The jump is the path's first edge: he stood still while it was planned and takes off from a standstill."""
        return e.k == 1


def key(a, b) -> tuple:
    return (round(a[0]), round(a[1]), round(a[2], 1), round(b[0]), round(b[1]), round(b[2], 1))


def parse_pts(s: str) -> list[tuple]:
    out = []
    for p in s.split():
        q = p.split(",")
        if len(q) == 3:
            try:
                out.append((float(q[0]), float(q[1]), float(q[2])))
            except ValueError:
                pass
    return out


def parse_lines(lines, since: str = DEFAULT_SINCE, until: str = "9") -> list[Path_]:
    """Paths (local plans that verified) with the jump lines that followed each, from client.log lines."""
    paths: list[Path_] = []
    cur: Path_ | None = None
    last_plan = None
    pending_miss = None        # a miss waiting for a position sample (the next plan or stuck line within 3 s)
    for raw in lines:
        m = TS_RX.match(raw.rstrip("\n"))
        if not m:
            continue
        stamp, text = m.group(1), m.group(2)
        if stamp < since or stamp > until or not text.startswith("move: "):
            continue
        ts = epoch(stamp)
        if pending_miss is not None and ts - pending_miss["ts"] > 3:
            pending_miss = None
        pm = PLAN_RX.match(text)
        if pm:
            last_plan = (int(pm.group(3)), int(pm.group(4)), int(pm.group(5))), pm.group(2), ts
            if pending_miss is not None:
                pending_miss["after"] = last_plan[0]
                pending_miss = None
            continue
        sm = STUCK_RX.match(text)
        if sm:
            if pending_miss is not None:
                pending_miss["after"] = (int(sm.group(1)), int(sm.group(2)), int(sm.group(3)))
                pending_miss = None
            continue
        pa = PATH_RX.match(text)
        if pa:
            if cur is not None and cur.end_ts is None:
                cur.end_ts = ts
            cur = Path_(ts=ts, acts=pa.group(2), pts=parse_pts(pa.group(4)), stand_s=float(pa.group(3)))
            if last_plan and ts - last_plan[2] < 15:
                cur.at, cur.why = last_plan[0], last_plan[1]
            paths.append(cur)
            continue
        if cur is None:
            continue
        lm = LANDED_RX.match(text)
        if lm:
            cur.miss = cur.miss or {}
            cur.miss["landed"] = tuple(int(lm.group(i)) for i in range(1, 5))
            continue
        mm = MISS_RX.match(text)
        if mm:
            d = cur.miss if (cur.miss and "ts" not in cur.miss) else {}
            if cur.miss and "ts" in cur.miss:
                continue  # one miss per path
            d.update(ts=ts, third="third" in mm.group(1))
            d.setdefault("landed", None)
            d.setdefault("after", None)
            cur.miss = d
            cur.end_ts = ts
            pending_miss = d
            continue
        if TAKEOFF_FAIL_RX.match(text):
            cur.takeoff_fail += 1
            continue
        if ROUTE_CHANGED_RX.match(text):
            cur.route_changed += 1
            continue
        tm = TAKING_OFF_RX.match(text)
        if tm:
            cur.taking_off.append(int(tm.group(1)))
            continue
        if TRIP_RX.match(text) and cur.end_ts is None:
            cur.end_ts = ts
    # a "landed" line with no miss line after it (cannot happen in move.lua; kept honest)
    for p in paths:
        if p.miss is not None and "ts" not in p.miss:
            p.miss = None
    return paths


def load_self_edges(path: Path = TRAVERSAL) -> list[dict]:
    out = []
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with fh:
        for line in fh:
            if '"self_edge"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if isinstance(d.get("from"), list) and isinstance(d.get("to"), list) and isinstance(d.get("ts"), (int, float)):
                out.append(d)
    return out


def attach_self_edges(paths: list[Path_], edges: list[dict]) -> None:
    """Mark each path's edges whose landing the body confirmed (traversal.jsonl self_edge) inside the path's time."""
    by_key = defaultdict(list)
    for d in edges:
        by_key[key(d["from"], d["to"])].append(float(d["ts"]))
    for i, p in enumerate(paths):
        hi = p.end_ts if p.end_ts is not None else (paths[i + 1].ts if i + 1 < len(paths) else p.ts + 120)
        for e in p.edges():
            k = key(e.a, e.b)
            if any(p.ts - 1 <= t <= hi + 2 for t in by_key.get(k, ())):
                p.landed_keys.add(k)


def jump_path(p: Path_) -> bool:
    return bool(p.jump_ups())


def legacy_counts(paths: list[Path_]) -> tuple[int, int]:
    """PROGRESS 2026-11-17 13:56Z count: paths with an edge lettered j or d that rises, and those with a miss."""
    n = sum(1 for p in paths if p.legacy_first())
    k = sum(1 for p in paths if p.legacy_first() and p.miss)
    return k, n


def outcomes(paths: list[Path_]) -> list[dict]:
    """One row per jump-up edge planned: kind, rise, run, place, outcome (landed / missed / not_reached)."""
    rows = []
    for p in paths:
        me = p.miss_edge()
        for e in p.jump_ups():
            k = key(e.a, e.b)
            if k in p.landed_keys:
                out = "landed"
            elif me is not None and me.k == e.k:
                out = "missed"
            else:
                out = "not_reached"
            row = {"pid": id(p), "ts": p.ts, "day": iso(p.ts)[:10], "kind": e.kind, "rise_cm": e.rise_cm, "run_cm": e.run_cm,
                   "band": e.band(), "slope_range": e.slope_range, "standing": p.standing_start(e), "k": e.k,
                   "a": e.a, "b": e.b, "outcome": out, "after_61412a5": iso(p.ts) >= COMMIT_61412A5}
            if out == "missed" and p.miss:
                lan = p.miss.get("landed")
                if lan:
                    row.update(off_cm=lan[0], allowed_cm=lan[1], dz_abs_cm=lan[2])
                pos = p.miss.get("after")
                if pos:
                    feet = pos[2] - HALF_H_CM
                    row["after_pos"] = (pos[0] / 100, pos[1] / 100, round(feet / 100, 2))
                    row["signed_dz_cm"] = round(feet - e.b[2] * 100)
                    row["after_vs_takeoff_dz_cm"] = round(feet - e.a[2] * 100)
                row["third"] = p.miss.get("third", False)
            rows.append(row)
    return rows


def classify_miss(r: dict) -> str:
    """What a missed landing was, from the landed line and the position sample after it (signed height)."""
    if "off_cm" not in r and "signed_dz_cm" not in r:
        return "unmeasured"
    if "signed_dz_cm" in r:
        s = r["signed_dz_cm"]
        if s <= -STEP_TOL_CM and r.get("after_vs_takeoff_dz_cm", 0) < STEP_TOL_CM:
            return "fell short (back at the takeoff level)"
        if abs(s) < STEP_TOL_CM:
            return "on the level, beyond the allowed distance"
        if s >= STEP_TOL_CM:
            return "above the point (slope or a higher shelf)"
        return "between takeoff and point heights"
    if r["dz_abs_cm"] < STEP_TOL_CM:
        return "on the level, beyond the allowed distance"
    if r["dz_abs_cm"] <= max(STEP_TOL_CM, SLOPE_K * r["off_cm"]):
        return "off height, within a walkable slope of the point"
    return "off height and away (unsigned)"


RULES = ("as judged now", "A: a rise over the step (45 cm) gets the 130 cm ledge window",
         "B: A, and on the point's level (under 65 cm off) within 250 cm",
         "C: B, and a strike only when he came down no higher than the takeoff + the step")


def strike_under(r: dict, rule: int) -> bool:
    """Would this missed landing still be a strike under rule 0..3? Unknown values count as a strike (conservative)."""
    if r["outcome"] != "missed":
        return False
    if rule == 0:
        return True
    off, allowed, dz = r.get("off_cm"), r.get("allowed_cm"), r.get("dz_abs_cm")
    if off is not None:
        if allowed == 45 and r["rise_cm"] > STEP_CM and off < 130 and dz < STEP_TOL_CM:
            return False
        if rule >= 2 and dz < STEP_TOL_CM and off < 250:
            return False
    elif rule >= 2 and "signed_dz_cm" in r and abs(r["signed_dz_cm"]) < STEP_TOL_CM:
        return False
    if rule >= 3 and "after_vs_takeoff_dz_cm" in r and r["after_vs_takeoff_dz_cm"] > STEP_CM:
        return False
    return True


def rule_table(paths: list[Path_]) -> list[str]:
    """Paths with a jump up that hold a strike under each landing rule (the goal's measure is this share)."""
    jp = [p for p in paths if jump_path(p)]
    by_ts = defaultdict(list)
    for r in outcomes(jp):
        by_ts[r["pid"]].append(r)
    out = ["| landing rule | paths with a strike |", "|---|---|"]
    for i, name in enumerate(RULES):
        k = sum(1 for p in jp if any(strike_under(r, i) for r in by_ts[id(p)]))
        out.append(f"| {name} | {pct(k, len(jp))} |")
    return out


def pct(k: int, n: int) -> str:
    return f"{k} of {n} ({100.0 * k / n:.0f} %)" if n else f"{k} of 0"


def cluster(points: list[tuple], radius_m: float = 5.0) -> list[dict]:
    """Greedy leader clustering in 2D: each point joins the first cluster whose centre is within radius_m."""
    cl: list[dict] = []
    for pt in points:
        x, y = pt[0], pt[1]
        for c in cl:
            if math.hypot(c["x"] - x, c["y"] - y) <= radius_m:
                c["members"].append(pt)
                n = len(c["members"])
                c["x"] += (x - c["x"]) / n
                c["y"] += (y - c["y"]) / n
                break
        else:
            cl.append({"x": x, "y": y, "members": [pt]})
    return cl


def places(rows: list[dict], top: int = 10, radius_m: float = 5.0) -> list[dict]:
    pts = [(r["b"][0], r["b"][1], r["b"][2], r) for r in rows]
    out = []
    for c in cluster(pts, radius_m):
        rs = [m[3] for m in c["members"]]
        miss = sum(1 for r in rs if r["outcome"] == "missed")
        land = sum(1 for r in rs if r["outcome"] == "landed")
        zs = sorted(r["b"][2] for r in rs)
        out.append({"x": round(c["x"], 1), "y": round(c["y"], 1), "z": zs[len(zs) // 2], "planned": len(rs),
                    "missed": miss, "landed": land, "rise_med_cm": sorted(r["rise_cm"] for r in rs)[len(rs) // 2],
                    "from": rs[0]["a"], "to": rs[0]["b"], "days": sorted({r["day"] for r in rs})})
    out.sort(key=lambda d: (-d["missed"], -d["planned"]))
    return out[:top]


def load(since: str, until: str = "9", log: Path = CLIENT_LOG) -> list[Path_]:
    with open(log, encoding="utf-8", errors="replace") as fh:
        paths = parse_lines(fh, since, until)
    attach_self_edges(paths, load_self_edges())
    return paths


def summary(paths: list[Path_], label: str) -> list[str]:
    rows = outcomes(paths)
    jp = [p for p in paths if jump_path(p)]
    lk, ln = legacy_counts(paths)
    out = [f"## {label}",
           f"paths {len(paths)}; with a jump up {len(jp)}; with a landing judged missed {pct(sum(1 for p in jp if p.miss), len(jp))}",
           f"legacy count (first j/d edge that rises): {pct(lk, ln)}",
           f"misses not on any jump-up edge (hop or leap on the level): {sum(1 for p in paths if p.miss and not jump_path(p))}",
           f"approaches ended on a third miss: {sum(1 for p in paths if p.miss and p.miss.get('third'))}",
           f"takeoff not grounded: {sum(p.takeoff_fail for p in paths)}; route changed in flight: {sum(p.route_changed for p in paths)};"
           f" 'taking off where I stand': {sum(len(p.taking_off) for p in paths)}"]
    tried = [r for r in rows if r["outcome"] != "not_reached"]
    out.append(f"jump-up edges planned {len(rows)}; tried (landed or missed) {len(tried)}; missed {pct(sum(1 for r in tried if r['outcome'] == 'missed'), len(tried))}")
    out.append("| split | tried | judged missed | a strike under rule C (fell back) |")
    out.append("|---|---|---|---|")
    diag = lambda r: r["run_cm"] > 120
    for name, f in [("kind jump", lambda r: r["kind"] == "jump"), ("kind djump", lambda r: r["kind"] == "djump"),
                    ("jump, diagonal", lambda r: r["kind"] == "jump" and diag(r)),
                    ("jump, cardinal", lambda r: r["kind"] == "jump" and not diag(r)),
                    ("djump, diagonal", lambda r: r["kind"] == "djump" and diag(r)),
                    ("djump, cardinal", lambda r: r["kind"] == "djump" and not diag(r)),
                    ("rise under 65 cm", lambda r: r["band"] == "under 65 cm"),
                    ("rise 65 to 120 cm", lambda r: r["band"] == "65 to 120 cm"),
                    ("rise 120 to 165 cm", lambda r: r["band"] == "120 to 165 cm"),
                    ("rise over 165 cm", lambda r: r["band"] == "over 165 cm"),
                    ("in slope range (rise <= 0.9 x run)", lambda r: r["slope_range"]),
                    ("above slope range", lambda r: not r["slope_range"]),
                    ("from a standstill (first edge of the path)", lambda r: r["standing"]),
                    ("with a run-up (later edge)", lambda r: not r["standing"]),
                    ("diagonal (run > 1.2 m)", lambda r: r["run_cm"] > 120),
                    ("cardinal (run <= 1.2 m)", lambda r: r["run_cm"] <= 120)]:
        s = [r for r in tried if f(r)]
        out.append(f"| {name} | {len(s)} | {pct(sum(1 for r in s if r['outcome'] == 'missed'), len(s))} | "
                   f"{pct(sum(1 for r in s if strike_under(r, 3)), len(s))} |")
    ms = [r for r in tried if r["outcome"] == "missed"]
    kinds = Counter(classify_miss(r) for r in ms)
    out.append("what the misses were: " + "; ".join(f"{v} {k}" for k, v in kinds.most_common()))
    sd = sorted(r["signed_dz_cm"] for r in ms if "signed_dz_cm" in r)
    if sd:
        out.append(f"signed height after the miss (feet minus the point's floor, cm; n={len(sd)}): median {sd[len(sd) // 2]}, "
                   f"below -65 {sum(1 for x in sd if x <= -65)}, within 65 {sum(1 for x in sd if -65 < x < 65)}, above 65 {sum(1 for x in sd if x >= 65)}")
    out += rule_table(paths)
    return out


def cmd_report(a) -> None:
    paths = load(a.since, a.until)
    before = [p for p in paths if iso(p.ts) < COMMIT_61412A5]
    after = [p for p in paths if iso(p.ts) >= COMMIT_61412A5]
    lines = summary(before, f"before 61412a5 ({a.since} to {COMMIT_61412A5})")
    lines += [""] + summary(after, f"after 61412a5 ({COMMIT_61412A5} to {a.until})")
    days = sorted({iso(p.ts)[:10] for p in paths})
    lines += ["", "| day | paths with a jump up | with a landing judged missed |", "|---|---|---|"]
    for d in days:
        jp = [p for p in paths if iso(p.ts)[:10] == d and jump_path(p)]
        lines.append(f"| {d} | {len(jp)} | {pct(sum(1 for p in jp if p.miss), len(jp))} |")
    print("\n".join(lines))


def cmd_windows(a) -> None:
    allp = load("2026-11-17T00:00:00Z")
    for group, names in (("s29 + s30 (before)", ("s29", "s30")), ("s31 (after)", ("s31",))):
        ps = [p for p in allp if any(WINDOWS[n][0] <= iso(p.ts) <= WINDOWS[n][1] for n in names)]
        print("\n".join(summary(ps, group)))
        print()


def cmd_places(a) -> None:
    rows = outcomes(load(a.since, a.until))
    rows = [r for r in rows if r["outcome"] != "not_reached"]
    print(f"| x | y | z (floor) | tried | missed | landed | median rise cm | an edge (from -> to) | days |")
    print("|---|---|---|---|---|---|---|---|---|")
    for c in places(rows, a.top, a.radius):
        print(f"| {c['x']} | {c['y']} | {c['z']} | {c['planned']} | {c['missed']} | {c['landed']} | {c['rise_med_cm']} | "
              f"{c['from']} -> {c['to']} | {', '.join(d[5:] for d in c['days'])} |")


def course_spots(paths: list[Path_], top: int = 8, radius_m: float = 5.0) -> list[dict]:
    """For each of the worst places: a start where he stood on the low side 3 to 20 m before the jump (a plan's own
    position, capsule centre, m; else the first point of a path through it, floor + 0.88 m) and a goal on the upper
    side (the end point of a path through it that lies at least at the landing's level, floor + 0.88 m)."""
    rows = [r for r in outcomes(paths) if r["outcome"] != "not_reached"]
    worst = places(rows, top, radius_m)
    hh = HALF_H_CM / 100
    out = []
    for c in worst:
        starts, firsts, goals = [], [], []
        for p in paths:
            for e in p.jump_ups():
                if math.hypot(e.b[0] - c["x"], e.b[1] - c["y"]) > radius_m:
                    continue
                if p.at:
                    s = (p.at[0] / 100, p.at[1] / 100, p.at[2] / 100)
                    dd = math.hypot(s[0] - e.b[0], s[1] - e.b[1])
                    if 3 <= dd <= 20 and s[2] - hh < e.b[2] - 0.6:
                        starts.append((dd, s))
                f0 = p.pts[0]
                if math.hypot(f0[0] - e.b[0], f0[1] - e.b[1]) >= 2 and f0[2] < e.b[2] - 0.6:
                    firsts.append((f0[0], f0[1], round(f0[2] + hh, 2)))
                end = p.pts[-1]
                if end[2] >= e.b[2] - 0.3:
                    goals.append((end[0], end[1], round(end[2] + hh, 2)))
        starts.sort()
        start, src = None, None
        if starts:
            start, src = starts[len(starts) // 2][1], "plan position"
        elif firsts:
            start, src = Counter(firsts).most_common(1)[0][0], "a path's first point"
        out.append({"place": (c["x"], c["y"], c["z"]), "missed": c["missed"], "tried": c["planned"],
                    "rise_med_cm": c["rise_med_cm"], "start": start, "start_src": src,
                    "goal": Counter(goals).most_common(1)[0][0] if goals else None})
    return out


def cmd_course(a) -> None:
    for i, s in enumerate(course_spots(load(a.since, a.until), a.top, a.radius), 1):
        st = [round(v, 2) for v in s["start"]] if s["start"] else None
        print(f"jump_{i}: place {s['place']} missed {s['missed']} of {s['tried']} (median rise {s['rise_med_cm']} cm); "
              f"start {st} ({s['start_src']}); goal {list(s['goal']) if s['goal'] else None}")


def scan_attacks(files: list[str], since_ts: float) -> dict:
    """attack results in brain logs: total, ended path_blocked, and those whose move says a landing was missed."""
    total, blocked, jumpy = 0, [], []
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"tool_result"' not in line or '"tool": "attack"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("kind") != "tool_result" or d.get("tool") != "attack" or float(d.get("ts", 0)) < since_ts:
                    continue
                total += 1
                res = d.get("result") or {}
                if res.get("reason") == "path_blocked":
                    mv = ((res.get("data") or {}).get("move") or {})
                    blocked.append((iso(float(d["ts"])), str(mv.get("lp_fail"))[:80]))
                    if "landing" in str(mv.get("lp_fail")):
                        jumpy.append(iso(float(d["ts"])))
    return {"attacks": total, "path_blocked": blocked, "after_missed_landing": jumpy}


def cmd_attacks(a) -> None:
    since = epoch(a.since)
    files = [f for f in sorted(glob.glob(BRAIN_GLOB)) if Path(f).stat().st_mtime >= since]
    r = scan_attacks(files, since)
    print(f"attacks {r['attacks']}; ended path_blocked {len(r['path_blocked'])}; of them after a missed landing {len(r['after_missed_landing'])}")
    for t, why in r["path_blocked"]:
        print(f"  {t} lp_fail={why}")


VERDICT_RX = re.compile(r"^move: jump verdict=(\w+) (.*)$")
KV_RX = re.compile(r"(\w+)=(\([^)]*\)|\S+)")


def parse_verdict(text: str) -> dict | None:
    """The per-jump line proposed in docs/research/2026-11-17-jump-landings.md (move.lua jump_landing_line):
    'move: jump verdict=missed why=far act=jump rise=120 run=141 ... floor=-830 floor_nz=0.93'. Numbers become
    floats, '(x,y,z)' becomes a tuple, '-' becomes None, 'A@B' stays text."""
    m = VERDICT_RX.match(text)
    if not m:
        return None
    d: dict = {"verdict": m.group(1)}
    for k, val in KV_RX.findall(m.group(2)):
        if val == "-":
            d[k] = None
        elif val.startswith("("):
            try:
                d[k] = tuple(float(x) for x in val.strip("()").split(","))
            except ValueError:
                d[k] = val
        else:
            try:
                d[k] = float(val)
            except ValueError:
                d[k] = val
    return d


def verdict_rows(lines, since: str = DEFAULT_SINCE, until: str = "9") -> list[dict]:
    out = []
    for raw in lines:
        m = TS_RX.match(raw.rstrip("\n"))
        if not m or m.group(1) < since or m.group(1) > until:
            continue
        d = parse_verdict(m.group(2))
        if d:
            d["iso"] = m.group(1)
            out.append(d)
    return out


def cmd_verdicts(a) -> None:
    with open(CLIENT_LOG, encoding="utf-8", errors="replace") as fh:
        rows = verdict_rows(fh, a.since, a.until)
    if not rows:
        print("no 'move: jump verdict=' lines in the window (the log line is not in move.lua yet?)")
        return
    n = len(rows)
    print(f"jumps {n}: " + "; ".join(f"{v} {k}" for k, v in Counter(r['verdict'] for r in rows).most_common()))
    print("why: " + "; ".join(f"{v} {k}" for k, v in Counter(str(r.get('why')) for r in rows).most_common()))
    fell = [r for r in rows if isinstance(r.get("feet_dz"), float) and r["feet_dz"] <= -STEP_TOL_CM]
    print(f"came down 65 cm or more below the point: {pct(len(fell), n)}")
    def med(xs):
        xs = sorted(x for x in xs if isinstance(x, float))
        return xs[len(xs) // 2] if xs else None
    for name, f in (("landed", lambda r: r["verdict"] == "landed"), ("missed", lambda r: r["verdict"] == "missed"),
                    ("fell back", lambda r: r in fell)):
        s = [r for r in rows if f(r)]
        print(f"{name:9s} n={len(s):3d} median v0h {med(r.get('v0h') for r in s)} toward {med(r.get('toward') for r in s)} "
              f"takeoff_off {med(r.get('takeoff_off') for r in s)} air {med(r.get('air') for r in s)} apex {med(r.get('apex') for r in s)} "
              f"floor_nz {med(r.get('floor_nz') for r in s)}")
    for name, f in (("diagonal", lambda r: (r.get("run") or 0) > 120), ("cardinal", lambda r: (r.get("run") or 0) <= 120)):
        s = [r for r in rows if f(r)]
        print(f"{name}: missed {pct(sum(1 for r in s if r['verdict'] == 'missed'), len(s))}, fell back {pct(sum(1 for r in s if r in fell), len(s))}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("report", "windows", "places", "course", "attacks", "verdicts"))
    ap.add_argument("--since", default=DEFAULT_SINCE)
    ap.add_argument("--until", default="9")
    ap.add_argument("--top", type=int, default=10)
    ap.add_argument("--radius", type=float, default=5.0)
    a = ap.parse_args()
    {"report": cmd_report, "windows": cmd_windows, "places": cmd_places, "course": cmd_course,
     "attacks": cmd_attacks, "verdicts": cmd_verdicts}[a.cmd](a)


if __name__ == "__main__":
    main()
