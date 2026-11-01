"""Pickup ladder: pick up a natural cluster, body only, no model calls, scored against Luis's own pickups.

The travel ladder's harness (tools/travel_ladder.py: the dev teleport fixture, the debug-channel bridge client, the
fight wait) with pickup legs. Each leg: Claude is put beside a natural cluster where Luis picked in his recorded run
(evals/baselines/luis_20261101_tasks.json), the census says how many of the kind are there and available, then ONE
bridge `gather {resource, count}` on the debug channel, exactly as the brain sends it. Scored from the dev server's
read-only recorder (logs/recorder, tools/recorder_motion.py) over [request, result]:

  s_item     wall seconds / items of the kind gained (the request's clock: travel to the first item included)
  presses    interact presses per item gained; misses = presses with no inventory gain within 1.5 s
  on_move    share of presses made while moving (server pose v >= 0.3 m/s)
  moving_s / standing_s / longest_stand_s

Luis (docs/BASELINES-2026-11-01-luis.md, data/baselines/luis-2026-11-01.json family "pickup"): 1.12 s per item
(median unit), 1.04 presses per item, 85 of 97 presses on the move. Bar (1.5x): s_item <= 1.7, presses <= 2 per item
(at most 1 miss each), on_move >= 75 %.

  .venv\\Scripts\\python.exe -m tools.pickup_ladder --list
  .venv\\Scripts\\python.exe -m tools.pickup_ladder [--only sticks,stones] [--label after] [--no-sweep]
  .venv\\Scripts\\python.exe -m tools.pickup_ladder --score FROM TO      # re-score a window (epoch s) from the recorder

Refuses unless the client is on the local dev server and the live brain is not running (DevTarget.guard).
Rows: logs/evals/pickup_ladder.jsonl.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from tools import recorder_motion as rm
from tools import travel_ladder as tl

ROOT = tl.ROOT
OUT = ROOT / "logs" / "evals" / "pickup_ladder.jsonl"
WHO = "ClaudeDev"
LUIS_S_ITEM, LUIS_PRESSES, LUIS_ON_MOVE = 1.12, 1.04, 85 / 97
BAR_S_ITEM, BAR_PRESSES, BAR_ON_MOVE = 1.7, 2.0, 0.75
GATHER_WAIT_S = 200.0

# Starts: Luis's capsule-centre pose (metres) at his first press of each cluster (recorder rec_20261101T123634Z).
LEGS = [
    {"id": "sticks", "resource": "sticks", "match": "Spawner_AshBranch", "count": 8, "start": [46.98, 1816.24, -30.78],
     "luis": "sticks 12:40:41: 11 in 10 s, 13 presses, all on the move"},
    {"id": "stones", "resource": "loose_stones", "match": "Spawner_Stone", "count": 6, "start": [59.61, 1821.66, -30.76],
     "luis": "stones 12:40:58: 8 in 18 s, 10 presses, 4 on the move"},
    {"id": "rocks", "resource": "loose_stones", "match": "Spawner_Stone", "count": 6, "start": [88.69, 1891.3, -30.72],
     "luis": "gather rocks 12:45:06 (second patch): 8 in ~5 s, 7 of 8 on the move"},
    {"id": "cabbage", "resource": "cabbage", "match": "Spawner_Cabbage", "count": 5, "start": [388.11, 1721.42, -41.6],
     "luis": "pick up cabbage 12:54:39: 6 in 7 s, all on the move at 6.8 m/s"},
    {"id": "flax", "resource": "flax", "match": "Spawner_Flax", "count": 3, "start": [374.81, 1729.37, -40.3],
     "luis": "pick flax 12:53:35: 3 in 26 s, spread out"},
    # more natural patches Luis picked from (his presses clustered by place), started 3 m west of the patch centre
    {"id": "sticks_b", "resource": "sticks", "match": "Spawner_AshBranch", "count": 6, "start": [59.6, 1830.9, -30.4],
     "luis": "a 4-branch patch he swept at 62.6,1830.9"},
    {"id": "sticks_c", "resource": "sticks", "match": "Spawner_AshBranch", "count": 6, "start": [101.0, 1807.0, -30.4],
     "luis": "branches at 98.7,1810.7 and 107.0,1805.9 (4 + 3)"},
    {"id": "stones_c", "resource": "loose_stones", "match": "Spawner_Stone", "count": 6, "start": [156.2, 1901.0, -30.5],
     "luis": "a 6-stone patch at 159.2,1901.0"},
    {"id": "stones_d", "resource": "loose_stones", "match": "Spawner_Stone", "count": 4, "start": [134.19, 1876.33, -29.94],
     "luis": "gather rocks 12:45:06 (first patch, 4 at 137.2,1880.3)"},
    {"id": "cabbage_b", "resource": "cabbage", "match": "Spawner_Cabbage", "count": 4, "start": [466.8, 1696.3, -40.6],
     "luis": "a 4-cabbage patch at 469.8,1696.3"},
    {"id": "flax_b", "resource": "flax", "match": "Spawner_Flax", "count": 3, "start": [520.2, 1650.0, -31.8],
     "luis": "general gather 13:07: 3 flax at 524,1649 in 1.5 s, on the move at 6.8 m/s"},
    {"id": "berries", "resource": "redberries", "match": "RedberryBush", "count": 2, "min": 2, "start": [365.4, 1736.0, -41.3],
     "luis": "general gather 13:07: 2 redberry bushes at 361,1735 and 356,1740 in 1.5 s, on the move"},
]


def available_here(c, match: str, radius_m: float = 12.0) -> list[dict]:
    """Census rows of the kind within radius that read available (a picked spawner reads available = false)."""
    r = c.request("census", {"radius_m": radius_m, "max": 80}, timeout=20) or {}
    data = r.get("data") or {}
    rows = []
    for v in data.values():
        if isinstance(v, list):
            rows += [x for x in v if isinstance(x, dict) and match in str(x.get("class") or x.get("id") or "")]
    return [x for x in rows if x.get("available") is not False]


def score(lo: float, hi: float, item_hint: str | None = None, rec: rm.Recording | None = None) -> dict:
    """Recorder metrics for Claude over [lo, hi] (epoch s; the recorder may run up to 1 s early: widened by 1 s)."""
    rec = rec or rm.load_overlapping(ROOT / "logs" / "recorder", lo - 2, hi + 2)
    if rec is None:
        return {"error": "no recorder file over the window"}
    a, b = lo - 1.0, hi + 1.0
    presses = rec.presses(WHO, a, b)
    gained: dict[str, int] = {}
    for ts, delta in rec.inv.get(WHO) or []:
        if a <= ts <= b:
            for k, n in delta.items():
                if n > 0:
                    gained[k] = gained.get(k, 0) + n
    key = max(gained, key=gained.get) if gained else None
    if item_hint and item_hint in gained:
        key = item_hint
    items = gained.get(key, 0) if key else 0
    on_move = 0
    for p in presses:
        pose = rec.pose_at(WHO, p.ts)
        if pose and pose.v >= rm.V_MIN:
            on_move += 1
    hits = sum(p.outcome == "hit" for p in presses)
    mo = rec.motion(WHO, a, b)
    stands = rec.idle_segments(WHO, a, b, min_s=1.0)
    wall = hi - lo
    out = {"wall_s": round(wall, 1), "item": key, "items": items, "gained": gained,
           "s_item": round(wall / items, 2) if items else None,
           "presses": len(presses), "hits": hits, "misses": len(presses) - hits,
           "presses_per_item": round(len(presses) / items, 2) if items else None,
           "on_move": on_move, "on_move_share": round(on_move / len(presses), 2) if presses else None,
           "moving_s": mo["moving_s"], "standing_s": mo["standing_s"],
           "longest_stand_s": max((s.s for s in stands), default=0.0),
           "press_log": [{"t": round(p.ts - lo, 2), "cls": (p.target_class or "?").replace("BP_", "")[:28], "out": p.outcome,
                          "d": p.dist_m, "v": (rec.pose_at(WHO, p.ts).v if rec.pose_at(WHO, p.ts) else None)} for p in presses]}
    out["human_ok"] = bool(items and out["s_item"] <= BAR_S_ITEM and out["presses_per_item"] <= BAR_PRESSES
                           and (out["on_move_share"] or 0) >= BAR_ON_MOVE)
    return out


DUMP = tl.P["southeast"]   # open ground away from every leg's patch
KEEP = {"ITEM_Resources_Wood_Ash": 40, "ITEM_Resources_Stone": 20}  # the build agent's working stock stays


def unload(dev, c) -> dict | None:
    """Over his carry weight the game slows him to 0.6 x walk (2.7 m/s; DISCOVERIES "Movement ladder ... encumbrance"),
    which is not what this ladder measures: if encumbered, drop the ladder's own kinds (logs, stone, the crops) down to
    KEEP at DUMP. Returns what was dropped, or None when he was under the limit."""
    from tools.scenario_run import run_client_cmd
    r = (run_client_cmd(ROOT / "client_mod" / "commands" / "encumbrance_probe.lua", "encumbrance_probe", timeout=20) or {}).get("result") or {}
    if not r.get("IsEncumbered"):
        return None
    d = (c.request("inventory", {}, timeout=20) or {}).get("data") or {}
    cnt: dict[str, int] = {}
    for w in ("hotbar", "bag"):
        for it in d.get(w) or []:
            cnt[it["item"]] = cnt.get(it["item"], 0) + (it.get("count") or 1)
    tl.place(dev, c, DUMP)
    out = {}
    for item, n in sorted(cnt.items(), key=lambda kv: -kv[1]):
        if item in KEEP or any(k in item for k in ("Cabbage", "Flax", "Redberry")):
            extra = n - KEEP.get(item, 0)
            if extra > 0:
                rr = c.request("drop", {"item": item, "count": extra}, timeout=20) or {}
                out[item] = extra if rr.get("ok") else f"failed {rr.get('reason')}"
    return out


def run_leg(dev, leg: dict, sweep: bool = True) -> dict:
    c = tl.client()
    c.request("stop", {}, timeout=10)
    s = tl.place(dev, c, leg["start"])
    if tl.reflex_busy(c):
        s = tl.place(dev, c, leg["start"])
    avail = available_here(c, leg["match"])
    n = min(leg["count"], len(avail))
    row = {"leg": leg["id"], "resource": leg["resource"], "available": len(avail), "start": [round(x, 2) for x in s],
           "luis": leg["luis"], "sweep": sweep}
    if n < leg.get("min", 3):
        row.update(ok=None, error=f"only {len(avail)} {leg['match']} available within 12 m")
        return row
    args = {"resource": leg["resource"], "count": n, "radius": 15}
    if not sweep:
        args["sweep"] = False
    t0 = time.time()
    r = c.request("gather", args, timeout=GATHER_WAIT_S) or {}
    t1 = time.time()
    data = r.get("data") or {}
    time.sleep(2.5)  # the recorder's 5 Hz inventory poll and the 1.5 s press-outcome window
    sc = score(t0, t1)
    row.update(ok=bool(r.get("ok")), want=n, reason=r.get("reason"), detail=data.get("detail"),
               body_gathered=data.get("gathered"), body_presses=data.get("presses"), body_on_move=data.get("presses_on_move"),
               phase_log=data.get("phase_log"), ts=round(t0, 2), **sc)
    return row


def fmt(row: dict) -> str:
    if row.get("error"):
        return f"ERR  {row['leg']:8s} {row['error']}"
    mark = "H   " if row.get("human_ok") else ("DONE" if row.get("ok") else "FAIL")
    return (f"{mark} {row['leg']:8s} {row.get('items')}/{row.get('want')} in {row.get('wall_s')} s = {row.get('s_item')} s/item "
            f"(Luis {LUIS_S_ITEM}, bar {BAR_S_ITEM}); presses {row.get('presses')} ({row.get('presses_per_item')}/item, "
            f"{row.get('misses')} miss); on the move {row.get('on_move')}/{row.get('presses')} = {row.get('on_move_share')} "
            f"(bar {BAR_ON_MOVE}); move {row.get('moving_s')} / stand {row.get('standing_s')} s, longest stand "
            f"{row.get('longest_stand_s')} s  {row.get('reason') or ''} {row.get('detail') or ''}")[:400]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="")
    ap.add_argument("--label", default="run")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--no-sweep", action="store_true", help="the stop-and-press pickup (gather sweep=false), for an A/B")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--score", nargs=2, type=float, metavar=("FROM", "TO"))
    a = ap.parse_args()
    if a.score:
        print(json.dumps(score(*a.score), indent=1))
        return
    only = set(filter(None, a.only.split(",")))
    legs = [g for g in LEGS if not only or g["id"] in only]
    if a.list:
        for g in legs:
            print(f"{g['id']:8s} {g['resource']:13s} x{g['count']} at {g['start']}  Luis: {g['luis']}")
        return
    from evals.bench.devrun import default_dev
    dev = default_dev()
    dev.guard()
    run_id = time.strftime("%Y%m%d-%H%M%S")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for rep in range(a.repeat):
        for g in legs:
            try:
                dropped = unload(dev, tl.client())
                if dropped:
                    print(f"     unloaded at {DUMP} (encumbered): {dropped}", flush=True)
                row = run_leg(dev, g, sweep=not a.no_sweep)
            except Exception as x:  # infra failure: recorded, not counted as a body failure
                row = {"leg": g["id"], "ok": None, "error": repr(x)}
            row.update(run=run_id, label=a.label, head=tl.head(), rep=rep)
            rows.append(row)
            with OUT.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(row) + "\n")
            print(fmt(row), flush=True)
            for p in row.get("press_log") or []:
                print(f"     {p['t']:6.2f}s {p['cls']:28s} {p['out']:5s} d={p['d']} v={p['v']}", flush=True)
    done = [r for r in rows if r.get("items")]
    if done:
        items = sum(r["items"] for r in done)
        wall = sum(r["wall_s"] for r in done)
        pr = sum(r["presses"] for r in done)
        mv = sum(r["on_move"] for r in done)
        summary = {"summary": True, "run": run_id, "label": a.label, "head": tl.head(), "legs": len(done),
                   "human_ok": sum(1 for r in done if r.get("human_ok")), "items": items,
                   "s_item": round(wall / items, 2), "presses_per_item": round(pr / items, 2),
                   "on_move_share": round(mv / pr, 2) if pr else None, "ts": round(time.time(), 1)}
        with OUT.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(summary) + "\n")
        print(f"\n{a.label}: {summary['human_ok']}/{len(done)} legs to the human bar; {items} items, {summary['s_item']} s/item "
              f"(Luis {LUIS_S_ITEM}), {summary['presses_per_item']} presses/item (Luis {LUIS_PRESSES}), "
              f"{summary['on_move_share']} on the move (Luis {LUIS_ON_MOVE:.2f})")


if __name__ == "__main__":
    main()
