r"""Rung 3 gate (docs/GOAL-2026-11-01.md, "Self-sufficient"): each item live on the dev world from ONE chat line,
graded against the same 4 bars as Rung 1. A thin layer over tools/rung1_gate.py (its leg sampler, bars, grading,
report and run loop): only the items, their setup and their checks live here.

Items (Luis's task from evals/baselines/luis_20261101_tasks.json in brackets; T_h = his recorded time):
  axe      "craft a stone axe"            [craft axe 11 s]      gain 1 Stone Logging Axe
  pickaxe  "make a stone pickaxe"         [make pickaxe 6 s]    gain 1 Stone Pickaxe
  chop     "chop about 13 logs"           [chop 47 s, 13 logs]  gain 13 Ash Logs
  mine     "mine about 10 stone"          [mine rock 15 s]      gain 10 Stone
  boil     "boil your dirty water"        [boil water 14 s]     gain 2 Clean Water (his "done": 2 boiled)
  cook     "cook your raw meat"           [cook 23 s]           gain 1 Steak
  thread   "spin some thread"             [animal fur to thread 21.8 s, 2 thread] gain 2 Coarse Thread
  spade    "make yourself a wooden spade" [make spade 47.1 s, thread first] gain 1 Wooden Spade
Each item starts where Luis stood when he began it (teleport fixture). Missing materials that are NOT the item under
test are granted as a dev fixture and listed in the row's note ("fixtures"); stations are the shared ones at the dev
base (he must say whose he used).

    .venv\Scripts\python.exe -m tools.rung3_gate plan
    .venv\Scripts\python.exe -m tools.rung3_gate run --confirm --only axe,pickaxe [--runs 3]
    .venv\Scripts\python.exe -m tools.rung3_gate report

Rows: logs/evals/rung3_gate.jsonl. The live lock owner is "rung3".
"""
from __future__ import annotations

import json
import re
import sys
import time

from tools import live_lock
from tools import rung1_gate as g

OUT = g.ROOT / "logs" / "evals" / "rung3_gate.jsonl"
WORLD = "dev_rung3"
ASH, STONE = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone"

# where Luis stood at each task's start (server recorder 2026-11-01, rec_20261101T123634Z), except where Claude's own
# house now stands (cells x 91.7-97.7, y 1845.6-1854.6; BUGS L46: a teleport in there boxes him in): axe, cook and the
# spinning wheel start outside it at Luis's distance from the same stations
# boil/cook start outside nav trap t227 (radius 8 m round (99.2, 1854.9), learned ~20:05Z): from inside it every walk
# first took its 37-point exit (window 11: 26 m walked to end 5 m away), which Luis never had to
SPOT = {"axe": [100.5, 1857.5, -31.0], "pickaxe": [98.97, 1860.57, -30.75], "chop": [118.18, 1868.42, -29.97],
        "mine": [106.92, 1851.47, -31.48], "boil": [109.0, 1855.0, -31.4], "cook": [109.0, 1855.0, -31.4],
        "wheel": [91.0, 1857.0, -31.0], "thread": [90.0, 1857.2, -31.0], "spade": [90.0, 1857.2, -31.0]}

# item -> (line, check name, check regex on the inventory's names, count, Luis's task, stock {item id: n},
#          tools the item needs carried {item id: 1}, deadline s)
ITEMS3 = {
    "axe": ("claude craft a stone axe", "Stone Logging Axe", r"logging axe", 1, "craft axe",
            {ASH: 8, STONE: 6}, {}, 90),
    "pickaxe": ("claude make a stone pickaxe", "Stone Pickaxe", r"^stone pickaxe$", 1, "make pickaxe",
                {ASH: 6, STONE: 8}, {}, 90),
    "chop": ("claude chop about 13 logs", "Ash Logs", r"^ash logs$", 13, "chop", {}, {"ITEM_Logging_Axe_Stone": 1}, 180),
    "mine": ("claude mine about 10 stone", "Stone", r"^stone$", 10, "mine rock", {}, {"ITEM_Pickaxe_Stone": 1}, 150),
    "boil": ("claude boil your dirty water", "Clean Water", r"^clean water$", 2, "boil water",
             {"ITEM_Consumable_Water_Dirty": 4, ASH: 2}, {}, 120),
    # cook: Raw Rat Meat (power level 1). ClaudeDev is Cooking 8: 5 of 5 Raw Farm Meat (power level 2, Luis's) burnt
    # (17:07Z, 17:40Z; wiki Culinary Confidence: power level 2 starts burning less only from Cooking 12). Done = any
    # cooked meat, not burnt
    "cook": ("claude cook your raw meat", "cooked meat", r"^(rat roast|fillet|steak|haunch|flank steak)$", 1, "cook",
             {"ITEM_Resources_Raw_Stringy_Meat": 3, ASH: 3}, {}, 120),
    # setup for thread/spade, not a Rung 3 item: Luis's wheel holds his fur in its only slot (never touched), so
    # Claude builds his own (it needs a roof: his house's ceiling); done = the wheel's 4 Flax spent, the station
    # census confirms it. Ungraded on time (Luis built his inside "make spade")
    # 18:03Z "build yourself a spinning wheel" put it under open sky (buildables said "Requires Shelter"); its menu
    # then never opened (18:4xZ). Setup line says where, as Luis would tell a new player
    # 21:0xZ "move one of your spinning wheels into your house" was answered truthfully: none of the three is this
    # character's (deconstruct:not_mine), so he offered to build one under the roof. The line asks for that
    "wheel": ("claude build yourself a spinning wheel inside your house, under the roof", "Flax", r"^flax$", 4, None,
              {ASH: 14, STONE: 2}, {}, 180),
    "spade": ("claude make yourself a wooden spade", "Wooden Spade", r"wooden spade", 1, "make spade",
              {ASH: 6, "ITEM_Resources_Flax": 1}, {}, 240),
    "thread": ("claude spin some thread", "Coarse Thread", r"coarse thread", 2, "animal fur to thread",
               {"ITEM_Resources_Flax": 2}, {}, 150),
}
ORDER = list(ITEMS3)  # spade before thread: his spade then starts from Flax, as Luis's did (spin, then craft)
# his first "cook" was scrapped ("kebbits dont drop meat"): the bar is the one he finished (12:57:59, 23 s)
T_H = {"cook": 23.0}
# the item under test he must not already carry (Luis had none; live 17:36Z: "make a stone pickaxe" with 2 in his bag
# read as "give him one"): dropped at DUMP, away from the base, before the item (fixture, in the row's note)
MADE = {"axe": "ITEM_Logging_Axe_Stone", "pickaxe": "ITEM_Pickaxe_Stone", "spade": "ITEM_Spade_T1_Wood"}
DUMP = [51.2, 1905.9, -33.9]  # the Temple Woods respawn point, 70 m from the base


def _bag(ctx) -> dict[str, int]:
    out: dict[str, int] = {}
    for r in ctx.stacks():
        k = str(r.get("item") or "")
        out[k] = out.get(k, 0) + int(r.get("count") or 1)
    return out


def stock(ctx, item: str, want: dict[str, int]) -> list[str]:
    """Grant the shortfall of each precondition (dev fixture); returns what was granted, for the row's note."""
    have, out = _bag(ctx), []
    for it, n in want.items():
        short = n - have.get(it, 0)
        if short > 0:
            cl_dev().setup("grant", purpose=f"rung3 gate {item}: precondition {it} (not the item under test)", item=it,
                           count=short)
            out.append(f"{it} x{short}")
    return out


def cl_dev():
    return g.cl._dev()


def processing_work(t0: float):
    """A stand while a station he started is running is work: from his first ProcessingStation toggle rpc to the end
    of the window (the scorer's stand bar otherwise reads 10 s of cooking as idle)."""
    def work(a, b):
        from tools import recorder_io as rio
        try:
            rec = rio.load(since=t0 - 2, until=b + 2)
        except Exception:  # noqa: BLE001
            return False
        who = rec.canon(g.WHO)
        tog = [r["ts"] for r in rec.rpcs(who, t0 - 1, b + 1) if r.get("rpc") == "toggle"] if who else []
        return bool(tog) and min(tog) <= a + 1.0
    return work


def gather_work(a, b) -> bool:
    """Chopping / mining: a stand is work while his gather job swings (client gather events in the stand)."""
    from tools import obs
    rows = [r for r in obs.jsonl(g.ROOT / "client_io" / "events" / "gather.jsonl") if a - 1 <= float(r.get("ts") or 0) <= b + 1]
    return any(r.get("phase") in ("swing", "aim", "settle", "collect") or r.get("type") == "gather_progress" for r in rows)


def check_gain3(rec: dict, rows: list[dict]):
    """Rung 1's gain check, worded for making things, plus his whole bag delta over the window, so the truth judge
    can check every claim (live 17:07Z: "both steaks came out burnt" was judged false; the facts lacked the burnt
    steaks)."""
    done, how, when, m = g.check_gain(rec, rows)
    how = how.replace("picked up", "gained")
    inv = rec.get("inv") or []
    if len(inv) >= 2:
        a, b = inv[0][1], inv[-1][1]
        delta = {k: b.get(k, 0) - a.get(k, 0) for k in set(a) | set(b) if b.get(k, 0) != a.get(k, 0)}
        if delta:
            how += "; his bag over the window: " + ", ".join(f"{v:+d} {k}" for k, v in sorted(delta.items(), key=lambda kv: kv[1]))
            m["bag_delta"] = delta
    return done, how, when, m


def check_spent3(rec: dict, rows: list[dict]):
    """Done when he has spent n of the item (a build's cost left his bag), with the bag delta for the judge."""
    tg = rec["target"]
    rx = re.compile(tg["rx"], re.I)
    inv = rec.get("inv") or []
    def held(c):
        return sum(v for k, v in c.items() if rx.search(k))
    top = held(inv[0][1]) if inv else 0  # the most he held so far: a refund (deconstruct) then a rebuild counts too
    when, used = None, 0
    for t, c in inv[1:]:
        top = max(top, held(c))
        used = top - held(c)
        if used >= tg["n"]:
            when = t
            break
    done, how, _, m = check_gain3({**rec, "target": {**tg, "n": 10 ** 9}}, rows)
    how = f"spent {used} {tg['name']} (the build's cost, {tg['n']})" + how[how.find(";"):] if ";" in how else         f"spent {used} {tg['name']} (the build's cost, {tg['n']})"
    return when is not None, how, when, m


g.cp.CHECK_HOOKS["r3_gain"] = check_gain3
g.cp.CHECK_HOOKS["r3_spent"] = check_spent3
PROBED: list[str] = []


def probe(ctx, item: str) -> None:
    """Once per process, inside the lock: what he can see and make here (stations and whose, unlocks, plots, spells),
    saved for the report (logs/evals/rung3_probe.jsonl)."""
    if PROBED:
        return
    PROBED.append(item)
    out = {"ts": round(time.time(), 1), "item": item}
    for tool, args in (("stations", {"radius": 40}), ("farm_plots", {"radius": 60}), ("spells", {}),
                       ("buildables", {"about": "farming plot"}), ("buildables", {"about": "spinning wheel"}),
                       ("recipes", {"item": "Coarse Thread"}), ("recipes", {"item": "Wooden Spade"})):
        try:
            r = ctx.cli.request(tool, args, timeout=20)
            out[f"{tool}:{json.dumps(args)}"] = r.get("data") if isinstance(r, dict) else r
        except Exception as exc:  # noqa: BLE001
            out[f"{tool}:{json.dumps(args)}"] = {"error": repr(exc)}
    out["bag"] = _bag(ctx)
    with open(OUT.parent / "rung3_probe.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(out, default=str) + "\n")


def place(ctx, spot) -> None:
    """Teleport there; a fight in progress (a reflex holds the pawn: live 17:35Z, a runt left by the previous window)
    is waited out first, and a failed placement is retried once after it."""
    from tools import travel_ladder as tl
    dev = cl_dev()
    for i in range(2):
        tl.reflex_busy(ctx.cli, 60.0)
        try:
            tl.place(dev, ctx.cli, spot, harness_brain=True)
            return
        except RuntimeError:
            if i:
                raise
            ctx.cli.request("stop", {}, timeout=10)


def shed(ctx, item: str) -> list[str]:
    """Drop the carried copies of the item under test at DUMP (fixture), so he starts as Luis did: without one."""
    it = MADE.get(item)
    n = _bag(ctx).get(it, 0) if it else 0
    if n <= 0:
        return []
    place(ctx, DUMP)
    r = ctx.cli.request("drop", {"item": it, "count": n}, timeout=30)
    left = _bag(ctx).get(it, 0)
    if left:
        raise RuntimeError(f"could not drop his {n} {it} before the item: {r}")
    return [f"dropped his {n} {it} at the respawn point"]


def run3(ctx, item: str) -> dict:
    line, name, rx, n, task, want, tools_, deadline = ITEMS3[item]
    shed_note = shed(ctx, item)
    place(ctx, SPOT[item])
    probe(ctx, item)
    fixtures = shed_note + stock(ctx, item, {**want, **tools_})
    time.sleep(2.0)
    kind, text = ("r3_spent", f"he builds it (spends {n} {name})") if item == "wheel" else         ("r3_gain", f"he gains {n} {name} (inventory)")
    row = g.run_leg(ctx, {"id": item, "kind": kind, "check_text": text}, line,
                    {"name": name, "rx": rx, "n": n}, deadline_s=deadline, sample=("me", "inv"))
    if item == "wheel":
        try:
            st = (ctx.cli.request("stations", {"radius": 40}, timeout=20).get("data") or {}).get("stations") or []
        except Exception:  # noqa: BLE001
            st = []
        wheels = [(w.get("id"), w.get("position"), (w.get("state") or {}).get("resources")) for w in st
                  if w.get("station") == "Spinning Wheel"]
        return g.finish(ctx, item, [row], None, allowed=1,
                        note=f"setup (ungraded time); wheels now {wheels}; fixtures: {', '.join(fixtures) or 'none'}")
    t_h = T_H.get(item) or g.luis_task_s(task)
    work = processing_work(row["rec"]["t0"]) if item in ("boil", "cook", "thread", "spade") else \
        gather_work if item in ("chop", "mine") else None
    return g.finish(ctx, item, [row], t_h, allowed=1, work=work,
                    note=f"Luis '{task}' {t_h} s; fixtures: {', '.join(fixtures) or 'none'}")


class _Lock:  # rung1_gate's run loop takes the lock as "rung1": this gate's owner is "rung3"
    held = staticmethod(lambda owner, wait_s=1800.0: live_lock.held("rung3", wait_s=wait_s))
    read = staticmethod(live_lock.read)


def main(argv=None) -> int:
    g.ITEMS[:] = ORDER
    g.RUNNERS.clear()
    g.RUNNERS.update({k: (lambda ctx, k=k: run3(ctx, k)) for k in ORDER})
    g.OUT, g.WORLD, g.live_lock = OUT, WORLD, _Lock
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] == "plan":
        for k, v in ITEMS3.items():
            t_h = T_H.get(k) or (g.luis_task_s(v[4]) if v[4] else None)
            print(f"  {k:<8} {v[0]!r:<42} {v[3]} {v[1]:<18} T_h {t_h or 'setup'} s ({v[4] or 'setup'})")
        print(f"live lock: {live_lock.read() or 'free'}; cost ~2-6 Haiku calls per item + 1 judge call")
        return 0
    if argv and argv[0] == "run" and "--world" not in argv:
        argv = [*argv, "--world", WORLD]
    return g.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
