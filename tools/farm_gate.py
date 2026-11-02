r"""Farm chain gate (rung 3, farming agent): Luis's farming scenario live on the dev world, one natural chat line per
leg, graded with tools/rung1_gate.py's bars (time, misses, longest stand, truthful). Rides tools/rung3_gate.py
(its gain check) and rung1_gate's run loop. No strategy in the lines: what he needs (thread, a wheel, seeds, water,
sleep or not) he works out himself (lookup, craft_plan, buildables, farm_plots).

Legs (run in this order; each starts where the last left him, no teleport, no material fixtures):
  tools    "get yourself a wooden spade and a watering can for the farm"  gain both (inventory)
  plant    "plant something in your farm plot and water it"               his own plot (farm_plots mine) grows a crop
                                                                          (growth.plant not Weeds) and is watered
  grow     "get that crop grown as fast as you can"                       his crop's growth.stage rises or it is ready
  harvest  "harvest your crop and keep it"                                gain 1+ of a crop item

    .venv\Scripts\python.exe -m tools.farm_gate plan
    .venv\Scripts\python.exe -m tools.farm_gate run --confirm --only tools [--runs 1]
    .venv\Scripts\python.exe -m tools.farm_gate report

Rows: logs/evals/farm_gate.jsonl; every farm_plots sample of his own plots is kept in the row (rec farm). Live lock
owner "rung3". T_h: Luis's recorded farm window (docs/BASELINES-2026-11-01-luis.md: 176 s to plant and tend 6
plots; 47.1 s spade) where one exists, else ungraded time.
"""
from __future__ import annotations

import json
import re
import sys
import time

from tools import live_lock
from tools import rung1_gate as g
from tools import rung3_gate as r3

OUT = g.ROOT / "logs" / "evals" / "farm_gate.jsonl"
WORLD = "dev_farm"
CROPS = r"potato|cabbage|wheat|flax|redberr|marrentill|harralander|kwuarm|onion|tomato|dwellberr"

# leg -> (line, check kind, target, Luis's time or None, deadline s)
LEGS = {
    "tools": ("claude, get yourself a wooden spade and a watering can for the farm", "r3_gain",
              {"name": "Wooden Spade and Wooden Watering Can", "rx": r"wooden spade|watering can", "n": 2}, None, 900),
    "plant": ("claude, plant something in your farm plot and water it", "farm",
              {"name": "a watered crop in his own plot", "goal": "planted"}, None, 600),
    "grow": ("claude, get that crop grown as fast as you can", "farm",
             {"name": "his crop a stage further on", "goal": "stage_up"}, None, 600),
    "harvest": ("claude, harvest your crop and keep it", "r3_gain", {"name": "crop", "rx": CROPS, "n": 1}, None, 300),
}
# every leg starts at his own roofed house (the build agent's run-6 house, plot 133 beside it), as Luis starts at his
# base: from the old dev base (108, 1845) he never learned of it (01:29Z window: built walls round an open-sky wheel)
HOUSE = [174.6, 1919.4, -30.9]
CTX: list = []  # the running leg's ctx (the farm check reads farm_plots through its bridge client)


def mine_plots(cli) -> list[dict]:
    r = cli.request("farm_plots", {"radius": 60}, timeout=15)
    return [{k: p.get(k) for k in ("id", "growth", "soil", "watered", "harvestable", "diseased", "distance_m")}
            for p in ((r.get("data") or {}).get("plots") or []) if p.get("mine")]


def _crop(p: dict) -> dict | None:
    gr = p.get("growth") or {}
    return gr if gr.get("plant") and gr.get("plant") != "Weeds" else None


def check_farm(rec: dict, rows: list[dict]):
    """Done (goal planted): one of HIS plots shows a crop (not weeds) and is watered. Done (goal stage_up): a crop of
    his is a stage further on than at the leg's start, or harvestable. Samples farm_plots every 3 s while the leg
    runs (kept in rec["farm"] for the judge and the report)."""
    st = rec.setdefault("farm", [])
    now = time.time()
    if CTX and (not st or now - st[-1][0] >= 3.0) and not rec.get("ended"):
        try:
            st.append([round(now, 1), mine_plots(CTX[0].cli)])
        except Exception:  # noqa: BLE001  (one failed read: try again next poll)
            pass
    goal = rec["target"]["goal"]
    base = {p["id"]: (_crop(p) or {}).get("stage") for p in (st[0][1] if st else [])}
    for t, ps in st:
        for p in ps:
            c = _crop(p)
            if goal == "planted" and c and p.get("watered"):
                return True, f"his plot {p['id']} grows {c['plant']} (stage {c['stage']} of {c['of']}), watered", t, {}
            if goal == "stage_up" and c and (p.get("harvestable") or (base.get(p["id"]) or 99) < (c.get("stage") or 0)):
                return True, (f"his {c['plant']} went from stage {base.get(p['id'])} to {c['stage']} of {c['of']}"
                              + (", ready to harvest" if p.get("harvestable") else "")), t, {}
    last = st[-1][1] if st else []
    return False, "his plots: " + ("; ".join(f"{p['id']} {(p.get('growth') or {}).get('plant') or p.get('soil')} "
                                             f"{(p.get('growth') or {}).get('stage')}/{(p.get('growth') or {}).get('of')}"
                                             f" watered={p.get('watered')}" for p in last) or "none read"), None, {}


g.cp.CHECK_HOOKS["farm"] = check_farm


def run_farm(ctx, leg: str) -> dict:
    line, kind, target, t_h, deadline = LEGS[leg]
    CTX[:] = [ctx]
    r3.place(ctx, HOUSE)
    time.sleep(2.0)
    before = mine_plots(ctx.cli)
    row = g.run_leg(ctx, {"id": leg, "kind": kind, "check_text": f"{target['name']}"}, line, dict(target),
                    deadline_s=deadline, sample=("me", "inv"))
    after = mine_plots(ctx.cli)
    rec = row.get("rec") or {}
    work = r3.processing_work(rec.get("t0") or time.time()) if leg == "tools" else None
    return g.finish(ctx, leg, [row], t_h, allowed=1, work=work,
                    note=f"fixture: placed outside his house {HOUSE}; his plots before {json.dumps(before)} after {json.dumps(after)}")


class _Lock:  # rung1_gate's run loop takes the lock as "rung1": this gate's owner is "rung3"
    held = staticmethod(lambda owner, wait_s=1800.0: live_lock.held("rung3", wait_s=wait_s))
    read = staticmethod(live_lock.read)


def main(argv=None) -> int:
    g.ITEMS[:] = list(LEGS)
    g.RUNNERS.clear()
    g.RUNNERS.update({k: (lambda ctx, k=k: run_farm(ctx, k)) for k in LEGS})
    g.OUT, g.WORLD, g.live_lock = OUT, WORLD, _Lock
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] == "plan":
        for k, v in LEGS.items():
            print(f"  {k:<8} {v[0]!r:<70} done: {v[2]['name']}; deadline {v[4]} s")
        print(f"live lock: {live_lock.read() or 'free'}; cost ~10-40 Haiku calls per leg (+ Director Sonnet on long jobs)")
        return 0
    if argv and argv[0] == "run" and "--world" not in argv:
        argv = [*argv, "--world", WORLD]
    return g.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
