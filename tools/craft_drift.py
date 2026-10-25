"""Crafting drift check: record ONE real craft by Luis and compare it with the bot's emulation of
the same recipe (design doc section 19: "compare one real craft by Luis with the bot's emulation;
re-run after patches"). Read-only on the game side (mod/experiments/craft_drift.lua).

  .venv\\Scripts\\python.exe -m tools.craft_drift run            # arm, wait for Luis's craft, report
  .venv\\Scripts\\python.exe -m tools.craft_drift run --seconds 600   # longer window (processing stations)
  .venv\\Scripts\\python.exe -m tools.craft_drift report logs\\drift\\craft_drift_<ts>.jsonl   # re-analyse

What Luis does (one craft, nothing else in that window):
  * crafting station (bench, table, anvil ...): stand at it with the materials in his BACKPACK (not
    in a chest: the game also pulls from linked storage), craft one recipe once (any count).
  * processing station (Furnace, Kiln ...): put the ingredients and the fuel in, start it, wait
    for the outputs, take them out.
The watcher logs his inventory, the nearest stations' inventories and processing state, world items
around the stations, and the Server_CraftRecipe / Server_ToggleProcessing RPCs. The analysis takes
the net change of that whole system (player + station + items on the ground), so moving items
between them cancels out and only real consumption and production remain. The emulation's plan
comes from a fresh copy of mod/body/crafting.lua on the server (debug_run craft_drift plan).

Report: logs/drift/<build>_<ts>.report.json, exit code 0 = no drift, 1 = mismatch, 2 = nothing captured.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from collections import defaultdict
from pathlib import Path

from brain.paths import REPO_ROOT

BUILD = "26161880"
DRIFT_DIR = REPO_ROOT / "logs" / "drift"


# ------------------------------------------------------------------------------ pure analysis

def load_events(path: Path) -> list[dict]:
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def _system(player: dict, stations: dict) -> dict:
    tot: dict[str, int] = defaultdict(int)
    for k, v in (player or {}).items():
        tot[k] += v
    for st in stations.values():
        for inv in ((st or {}).get("inv") or {}).values():
            for k, v in (inv or {}).items():
                tot[k] += v
    return dict(tot)


def analyse(events: list[dict]) -> dict:
    """The real outcome: recipe, net consumed/produced over the window, timing."""
    player, stations = None, {}
    start_sys = None
    timeline = []  # (t, system counts)
    craft_hooks = [e for e in events if e.get("kind") == "hook" and e.get("hook") == "craft" and e.get("phase") == "pre"]
    station_recipe, station_id, run_start = None, None, None
    for e in events:
        k = e.get("kind")
        if k == "player":
            player = e.get("counts") or {}
        elif k == "station":
            stations[e["id"]] = e.get("state") or {}
            st = e.get("state") or {}
            if st.get("recipe"):
                station_recipe, station_id = st["recipe"], e["id"]
            if st.get("running") and run_start is None:
                run_start = e["t"]
        elif k == "hook" and e.get("hook") == "craft" and e.get("phase") == "pre" and e.get("counts") is not None:
            # the pre-hook snapshot is the exact state just before the craft
            player = e["counts"]
        else:
            continue
        if player is None:
            continue
        sysc = _system(player, stations)
        if start_sys is None:
            start_sys = sysc
        timeline.append((e["t"], sysc))
    if start_sys is None:
        return {"captured": False, "detail": "no player inventory snapshot"}
    end_sys = timeline[-1][1]
    keys = set(start_sys) | set(end_sys)
    net = {k: end_sys.get(k, 0) - start_sys.get(k, 0) for k in keys}
    consumed = {k: -v for k, v in net.items() if v < 0}
    produced = {k: v for k, v in net.items() if v > 0}
    res = {"captured": bool(consumed or produced), "consumed": consumed, "produced": produced,
           "events": len(events), "window_ms": timeline[-1][0] - timeline[0][0]}
    if craft_hooks:
        h = craft_hooks[0]
        res.update({"kind": "crafting", "recipe": h.get("recipe"), "count": h.get("count"), "bonus": h.get("bonus"),
                    "station_class": h.get("station_class"), "t_start": h["t"],
                    "craft_rpcs": [{"recipe": c.get("recipe"), "count": c.get("count")} for c in craft_hooks]})
    elif station_recipe:
        res.update({"kind": "processing", "recipe": station_recipe, "station_actor": station_id, "t_start": run_start})
    else:
        res["kind"] = None
    # timing: when did each produced item first rise, and first reach its final net gain? (Moving an
    # item between two watched places can show it twice for one sample: "reach", not "last rise".)
    first_up, last_up = {}, {}
    for t, sysc in timeline:
        for k, n in produced.items():
            gain = sysc.get(k, 0) - start_sys.get(k, 0)
            if gain > 0:
                first_up.setdefault(k, t)
            if gain >= n and k not in last_up:
                last_up[k] = t
    if res.get("t_start") is not None and first_up:
        t_first = min(first_up.values())
        t_last = max(last_up.values())
        res["seconds_to_first_output"] = round((t_first - res["t_start"]) / 1000.0, 2)
        res["seconds_to_last_output"] = round((t_last - res["t_start"]) / 1000.0, 2)
    return res


def crafts_from(real: dict, plan1: dict) -> int:
    """Number of crafts: the RPC's count for a crafting station, else produced / per-craft output."""
    if real.get("kind") == "crafting" and real.get("count"):
        return int(real["count"])
    per = {o["item"]: o["count"] for o in plan1.get("outputs") or []}
    for item, n in per.items():
        if real.get("produced", {}).get(item):
            return max(1, real["produced"][item] // max(1, n))
    return 1


def compare(real: dict, plan: dict, tolerance_s: float = 1.0, tolerance_frac: float = 0.25) -> dict:
    """Mismatches between Luis's real craft and the emulation's plan for the same recipe and count."""
    mism = []
    notes = []
    fuel_items = {o["item"] for o in ((plan.get("fuel") or {}).get("options") or [])}
    fixed_fuel = {o["item"]: o["count"] for o in ((plan.get("fuel") or {}).get("fixed") or [])}
    plan_in = {i["item"]: i["count"] for i in plan.get("inputs") or []}
    plan_out = {o["item"]: o["count"] for o in plan.get("outputs") or []}
    extra_ok = {x[0].rsplit(".", 1)[-1] for x in ((plan.get("extra_possible") or {}).get("items") or [])}
    cons, prod = dict(real.get("consumed") or {}), dict(real.get("produced") or {})
    for item, n in plan_in.items():
        got = cons.pop(item, 0)
        if got != n:
            mism.append({"what": "input", "item": item, "real": got, "emulated": n})
    for item, n in fixed_fuel.items():
        got = cons.pop(item, 0)
        if got != n:
            mism.append({"what": "fuel", "item": item, "real": got, "emulated": n})
    fuel_real = {k: cons.pop(k) for k in list(cons) if k in fuel_items}
    if fuel_items:
        opts = {o["item"]: o["count"] for o in plan["fuel"]["options"]}
        if not fuel_real:
            mism.append({"what": "fuel", "item": sorted(fuel_items), "real": 0, "emulated": "1+ of an accepted fuel",
                         "detail": "no fuel consumed in the real craft (station already burning?)"})
        for item, got in fuel_real.items():
            if got != opts.get(item):
                mism.append({"what": "fuel", "item": item, "real": got, "emulated": opts.get(item),
                             "detail": "fuel burn model (ceil(seconds / FuelValue)) differs"})
    for item, got in cons.items():
        mism.append({"what": "input", "item": item, "real": got, "emulated": 0, "detail": "consumed but not in the recipe"})
    for item, n in plan_out.items():
        got = prod.pop(item, 0)
        if got != n:
            mism.append({"what": "output", "item": item, "real": got, "emulated": n})
    for item, got in prod.items():
        if item in extra_ok:
            notes.append(f"extra item {item} x{got} (the recipe's ChanceToProduceExtraItems; emulation default extras=off)")
        else:
            mism.append({"what": "output", "item": item, "real": got, "emulated": 0, "detail": "produced but not in the recipe"})
    secs = real.get("seconds_to_last_output")
    if secs is not None and plan.get("seconds") is not None:
        tol = max(tolerance_s, tolerance_frac * plan["seconds"])
        if abs(secs - plan["seconds"]) > tol:
            mism.append({"what": "seconds", "real": secs, "emulated": round(plan["seconds"], 2),
                         "model": plan.get("seconds_model"), "tolerance": round(tol, 2)})
    elif secs is None:
        notes.append("timing not measured (no output rise after the start marker)")
    return {"ok": not mism, "mismatches": mism, "notes": notes}


# ------------------------------------------------------------------------------ live

def _client():
    from brain.bridge_client import BridgeClient
    from brain.transport import file_transport_pair
    brain_side, _ = file_transport_pair()
    return BridgeClient(brain_side)


def drift_run(client, args: dict, timeout: float = 30.0) -> dict:
    res = client.request("debug_run", {"module": "craft_drift", "args": args}, timeout=timeout)
    if not res.get("ok"):
        raise RuntimeError(f"debug_run craft_drift failed: {json.dumps(res)[:1500]}")
    return (res.get("data") or {}).get("result") or {}


def get_plan(client, recipe: str, count: int, station: str | None = None) -> dict:
    r = drift_run(client, {"action": "plan", "recipe": recipe, "count": count, "station": station})
    if not r.get("ok"):
        raise RuntimeError(f"no emulation plan for {recipe}: {r}")
    return r["plan"]


def report(client, jsonl: Path, build: str) -> tuple[int, dict]:
    events = load_events(jsonl)
    real = analyse(events)
    out = {"build": build, "events_file": jsonl.as_posix(), "real": real}
    if not real.get("captured") or not real.get("recipe"):
        out["verdict"] = "nothing_captured"
        return 2, out
    plan1 = get_plan(client, real["recipe"], 1)
    crafts = crafts_from(real, plan1)
    plan = get_plan(client, real["recipe"], crafts)
    out["crafts"] = crafts
    out["emulated"] = plan
    out["comparison"] = compare(real, plan)
    out["verdict"] = "match" if out["comparison"]["ok"] else "drift"
    return (0 if out["comparison"]["ok"] else 1), out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("run", "arm", "stop", "status", "report"))
    ap.add_argument("events", nargs="?", help="report: the craft_drift_<ts>.jsonl file")
    ap.add_argument("--build", default=BUILD)
    ap.add_argument("--seconds", type=float, default=300.0, help="watch window")
    ap.add_argument("--radius", type=float, default=12.0, help="stations within this many metres of Luis")
    ap.add_argument("--settle", type=float, default=8.0, help="seconds without new events that end the watch")
    a = ap.parse_args()
    client = _client()
    if a.cmd == "status":
        print(json.dumps(drift_run(client, {"action": "status"}), indent=1))
        return
    if a.cmd == "stop":
        print(json.dumps(drift_run(client, {"action": "stop"}), indent=1))
        return
    if a.cmd == "report":
        if not a.events:
            raise SystemExit("report needs the events file")
        code, out = report(client, Path(a.events), a.build)
        print(json.dumps(out, indent=1))
        sys.exit(code)
    DRIFT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    jsonl = DRIFT_DIR / f"craft_drift_{stamp}.jsonl"
    armed = drift_run(client, {"action": "arm", "seconds": a.seconds, "radius_m": a.radius, "out": jsonl.as_posix()})
    print(json.dumps(armed, indent=1))
    if a.cmd == "arm":
        return
    print("\nARMED. Luis: craft ONE recipe now (materials in your backpack; for a furnace/kiln put in the "
          "ingredients and fuel, start it, and take the outputs). Waiting...\n", flush=True)
    t_end = time.monotonic() + a.seconds
    last_n, last_change, seen_craft = -1, time.monotonic(), False
    while time.monotonic() < t_end:
        time.sleep(1.0)
        n = len(load_events(jsonl)) if jsonl.exists() else 0
        if n != last_n:
            last_n, last_change = n, time.monotonic()
        real = analyse(load_events(jsonl)) if n else {}
        if real.get("recipe") and real.get("produced"):
            seen_craft = True
        if seen_craft and time.monotonic() - last_change >= a.settle:
            break
    drift_run(client, {"action": "stop"})
    code, out = report(client, jsonl, a.build)
    rp = DRIFT_DIR / f"{a.build}_{stamp}.report.json"
    rp.write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(json.dumps(out.get("comparison") or out, indent=1))
    print(f"\nverdict: {out['verdict']}  ({rp})")
    sys.exit(code)


if __name__ == "__main__":
    main()
